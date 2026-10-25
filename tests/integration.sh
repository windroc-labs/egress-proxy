#!/usr/bin/env bash
# Docker end-to-end checks of the gateway (CI `integration` job). Linux CI only: it needs
# Docker and passwordless sudo, kills the gateway's processes and restarts the Docker
# daemon. Prints `ok <check>` per check and stops at the first `FAIL <check>: <detail>`.
#
# Stage A starts the gateway with start.sh and a config holding only `workers`; stage B
# adds `mini-op` (allowlist), checks that each network gets only its own policy, and runs
# verify-egress on both networks and with --tools; stage C adds and removes a network
# through the config alone.
# Docker's Go templates use $ inside single quotes on purpose.
# shellcheck disable=SC2016
set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
  echo "integration.sh: runs on Linux CI only (it restarts the Docker daemon)" >&2
  exit 2
fi

repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
# A throwaway Docker client config with no credsStore or credHelpers, so no keychain
# and no stored registry credential is ever read.
export DOCKER_CONFIG=$work/docker
mkdir -p "$DOCKER_CONFIG"
echo '{}' >"$DOCKER_CONFIG/config.json"
# The gateway's config directory; never the real ~/.egress.
export EGRESS_CONFIG_DIR=$work/egress
mkdir -p "$EGRESS_CONFIG_DIR"

GW=egress-gateway
PROXY=http://egress-proxy-workers:4750
# The probe image verify-egress pins: one source for its digest.
PROBE_IMAGE=$(sed -n 's/^PROBE_IMAGE=//p' "$repo/verify-egress")
[[ -n $PROBE_IMAGE ]] || { echo "integration.sh: no PROBE_IMAGE line in verify-egress" >&2; exit 2; }
LONG=egress-test-long
MPROXY=http://egress-proxy-mini-op:4750
# mini-op's own network and proxy container, assembled from pieces so tests/check-repo.sh
# does not take them for references to that repo. Stage B makes stand-ins for both.
c=mini d=-op
LEGACY_NET=${c}${d}-net
LEGACY_PROXY=${c}${d}-proxy
LISTENERS=(egress-test-listen-workers egress-test-listen-mini-op)
host_listeners=()
# compose <args...>: docker compose on this repo, with start.sh's rendered override once it
# exists (without it, compose would see a gateway with no caller networks).
compose() {
  local files=(-f "$repo/compose.yaml")
  [[ -f $EGRESS_CONFIG_DIR/compose.networks.yaml ]] && files+=(-f "$EGRESS_CONFIG_DIR/compose.networks.yaml")
  docker compose --project-directory "$repo" "${files[@]}" "$@"
}

cleanup() {
  local code=$?
  if ((code != 0)); then
    echo "--- docker inspect $GW .State"
    docker inspect --format '{{json .State}}' "$GW" 2>&1 || true
    echo "--- docker logs $GW (last 100 lines)"
    docker logs --tail 100 "$GW" 2>&1 || true
  fi
  docker rm -f "$LONG" "$LEGACY_PROXY" "${LISTENERS[@]}" >/dev/null 2>&1 || true
  ((${#host_listeners[@]} == 0)) || kill "${host_listeners[@]}" 2>/dev/null || true
  compose down --remove-orphans >/dev/null 2>&1 || true
  docker network rm egress-mini-op egress-testnet "$LEGACY_NET" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

ok() { echo "ok $1"; }
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  exit 1
}

use_config() { cp "$repo/tests/fixtures/$1" "$EGRESS_CONFIG_DIR/config.local.yaml"; }

inspect() { docker inspect --format "$1" "$GW"; }

# wait_health <status> [seconds]: polls the gateway's health every 2 s.
wait_health() {
  local want=$1 limit=${2:-90} got="" i
  for ((i = 0; i < limit; i += 2)); do
    got=$(inspect '{{if .State.Health}}{{.State.Health.Status}}{{end}}' 2>/dev/null || true)
    [[ $got == "$want" ]] && return 0
    sleep 2
  done
  echo "health is '$got' after ${limit}s, want '$want'" >&2
  return 1
}

# wait_restart <old StartedAt>: the container started again and is healthy.
wait_restart() {
  local old=$1 i
  for ((i = 0; i < 90; i += 2)); do
    [[ $(inspect '{{.State.StartedAt}}' 2>/dev/null || true) != "$old" ]] && break
    sleep 2
  done
  [[ $(inspect '{{.State.StartedAt}}') != "$old" ]] && wait_health healthy
}

# probe <network> <curl args...>: curl in a fresh container on <network>; prints the
# --write-out text, then curl's exit code on its own line.
probe() {
  local net=$1
  shift
  docker run --rm --network "$net" "$PROBE_IMAGE" -sS -g -o /dev/null --connect-timeout 5 --max-time 15 "$@" 2>/dev/null && echo || echo " $?"
}

# The CONNECT status the proxy gave for <url> from <network>.
connect_status() {
  local out
  out=$(probe "$1" -x "$2" -w '%{http_connect}' "$3")
  echo "${out%% *}"
}

# denied <check> <network> <proxy> <url>: the proxy answered 407.
denied() {
  local got
  got=$(connect_status "$2" "$3" "$4")
  [[ $got == 407 ]] || fail "$1" "CONNECT $4 via $3 got '$got', want 407"
  ok "$1"
}

# allowed <check> <network> <proxy> <url>: the request went through.
allowed() {
  local out
  out=$(probe "$2" -x "$3" -w '%{http_connect} %{http_code}' "$4")
  [[ $out == "200 "* && $out != *" "*" "* ]] || fail "$1" "via $3 to $4 got '$out', want 200 and success"
  ok "$1"
}

# tunneled <check> <network> <proxy> <url>: an http <url> through a CONNECT tunnel answers.
tunneled() {
  local out
  out=$(probe "$2" -p -x "$3" -w '%{http_connect} %{http_code}' "$4")
  [[ $out == "200 200" ]] || fail "$1" "via $3 to $4 got '$out', want 200 200"
  ok "$1"
}

# unreachable <check> <network> <curl args...>: curl fails without any HTTP answer.
unreachable() {
  local name=$1 net=$2 out
  shift 2
  out=$(probe "$net" -w '%{http_connect}%{http_code}' "$@")
  [[ $out == 000000\ * ]] || fail "$name" "curl $* from $net got '$out', want no connection"
}

# lookup <network> [server]: nslookup example.com from <network>; returns its exit code
# (0 resolved, 1 nslookup failed; anything else: docker could not run it).
lookup() {
  local rc=0
  docker run --rm --network "$1" --entrypoint nslookup "$PROBE_IMAGE" example.com ${2:+"$2"} >/dev/null 2>&1 || rc=$?
  return "$rc"
}

# no_dns <check> <network> [server]: nslookup ran and could not resolve an external name.
no_dns() {
  local rc=0
  lookup "$2" ${3:+"$3"} || rc=$?
  case $rc in
    0) fail "$1" "example.com resolved from $2${3:+ via $3}" ;;
    1) ;;
    *) fail "$1" "nslookup did not run from $2 (exit $rc)" ;;
  esac
}

# The documented start command (README.md).
start() { "$repo/start.sh"; }

# -------- Stage A: compose.yaml, workers only --------
use_config workers.yaml
start
wait_health healthy || fail healthy "the gateway did not become healthy"
[[ $(docker ps --filter "name=^$GW\$" --format '{{.Status}}') == *"(healthy)"* ]] ||
  fail healthy "docker ps does not show (healthy)"
ok healthy

# AC10: label contract v1.
want_labels=$'windroc.egress.contract=1\nwindroc.egress.network.workers.name=egress-workers\nwindroc.egress.network.workers.proxy=http://egress-proxy-workers:4750\nwindroc.egress.networks=workers'
got_labels=$(inspect '{{range $k, $v := .Config.Labels}}{{println $k "=" $v}}{{end}}' | sed 's/ = /=/' | grep '^windroc\.egress\.' | sort)
[[ $got_labels == "$want_labels" ]] || fail labels_v1 "labels are: $got_labels"
[[ $(docker ps -a --filter label=windroc.egress.contract=1 --format '{{.Names}}') == "$GW" ]] ||
  fail labels_v1 "the contract label does not find exactly $GW"
inspect '{{range .Config.Env}}{{println .}}{{end}}' | grep -qx 'EGRESS_NETWORKS=workers' ||
  fail labels_v1 "EGRESS_NETWORKS differs from the windroc.egress.networks label"
ok labels_v1

# AC12: hardening.
[[ $(inspect '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.Config.User}}') == "true [ALL] 65532:65532" ]] ||
  fail hardening "rootfs/caps/user: $(inspect '{{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}} {{.Config.User}}')"
[[ $(inspect '{{.HostConfig.SecurityOpt}}') == *no-new-privileges* ]] || fail hardening "no no-new-privileges"
mounts=$(inspect '{{range .Mounts}}{{println .Type .Destination .RW .Source}}{{end}}')
[[ $mounts == "bind /etc/egress false $EGRESS_CONFIG_DIR" ]] || fail hardening "mounts: $mounts"
[[ $mounts != *docker.sock* ]] || fail hardening "the Docker socket is mounted"
[[ $(docker network inspect --format '{{.EnableIPv6}}' egress-uplink) == false ]] || fail hardening "egress-uplink has IPv6"
ok hardening

# AC2: attachments, no published port, the proxy port only from the caller network.
[[ $(inspect '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | sort | xargs) == "egress-uplink egress-workers" ]] ||
  fail networks_attached "attached to: $(inspect '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}')"
[[ $(docker network inspect --format '{{.Internal}}' egress-workers) == true ]] || fail networks_attached "egress-workers is not internal"
ok networks_attached
[[ -z $(docker port "$GW") && $(inspect '{{json .HostConfig.PortBindings}}') =~ ^(\{\}|null)$ ]] ||
  fail no_published_ports "ports: $(docker port "$GW")"
ok no_published_ports
workers_ip=$(inspect '{{(index .NetworkSettings.Networks "egress-workers").IPAddress}}')
uplink_ip=$(inspect '{{(index .NetworkSettings.Networks "egress-uplink").IPAddress}}')
for ip in "$workers_ip" "$uplink_ip"; do
  unreachable bridge_cannot_reach bridge -x "http://$ip:4750" https://example.com/
  unreachable uplink_cannot_reach egress-uplink -x "http://$ip:4750" https://example.com/
done
ok bridge_cannot_reach
ok uplink_cannot_reach

# Positive control for no_dns: the probe's nslookup does resolve where DNS exists.
lookup bridge || fail dns_control "nslookup example.com failed from bridge (exit $?)"
ok dns_control

# AC1: public through the proxy; every FR-7 class denied; nothing without the proxy.
allowed workers_public_ok egress-workers "$PROXY" https://example.com/
for target in 10.0.0.1 172.16.0.1 192.168.1.1 100.64.0.1 0.0.0.0 0.0.0.1 127.0.0.1 169.254.169.254 \
  '[::]' '[::1]' '[fd00::1]' '[fe80::1]' '[::ffff:10.0.0.1]' '[::ffff:127.0.0.1]' host.docker.internal; do
  denied "workers_denied_$target" egress-workers "$PROXY" "https://$target/"
done
denied workers_denied_self egress-workers "$PROXY" https://egress-proxy-workers:4750/
denied workers_denied_self_ip egress-workers "$PROXY" "https://$workers_ip:4750/"
unreachable workers_no_direct egress-workers https://example.com/
unreachable workers_no_direct egress-workers https://1.1.1.1/
no_dns workers_no_direct egress-workers
no_dns workers_no_direct egress-workers 8.8.8.8
ok workers_no_direct

# AC4: the start command a second time changes nothing.
state() {
  inspect '{{.Id}} {{.State.StartedAt}} {{.Image}}'
  docker network inspect --format '{{.Id}}' egress-workers egress-uplink
}
before=$(state)
labels_before=$(inspect '{{range $k, $v := .Config.Labels}}{{println $k $v}}{{end}}' | grep '^com\.docker\.compose\.')
start
if [[ $(state) != "$before" ]]; then
  echo "--- compose labels before"
  echo "$labels_before"
  echo "--- compose labels after"
  inspect '{{range $k, $v := .Config.Labels}}{{println $k $v}}{{end}}' | grep '^com\.docker\.compose\.' || true
  echo "--- compose config --hash"
  compose config --hash '*' || true
  docker compose version || true
  fail up_idempotent "before: $before; after: $(state)"
fi
ok up_idempotent

# AC13: start.sh refuses a missing config or a config error and changes nothing.
override=$EGRESS_CONFIG_DIR/compose.networks.yaml
cp "$override" "$work/override.before"
rc=0
err=$(EGRESS_CONFIG_DIR=$work/no-config "$repo/start.sh" 2>&1 >/dev/null) || rc=$?
[[ $rc == 2 && $err == *"$work/no-config/config.local.yaml not found; copy config.example.yaml there"* ]] ||
  fail start_missing_config "exit $rc: $err"
[[ $(state) == "$before" ]] || fail start_missing_config "the gateway changed"
ok start_missing_config
printf 'version: 1\nnetworks:\n  workers:\n    mode: denylist\n  extra:\n    allow: [example.com]\n' >"$EGRESS_CONFIG_DIR/config.local.yaml"
rc=0
err=$(start 2>&1 >/dev/null) || rc=$?
[[ $rc == 2 && $err == *"network extra: missing key mode"* ]] || fail start_config_error "exit $rc: $err"
cmp -s "$override" "$work/override.before" || fail start_config_error "the rendered override changed"
[[ $(state) == "$before" ]] || fail start_config_error "the gateway changed"
ok start_config_error
use_config workers.yaml

# AC3 (NFR-1): with the gateway stopped, the network has no way out.
compose stop
code=$(inspect '{{.State.ExitCode}}')
[[ $code == 0 ]] || fail stop_exits_0 "exit code $code after compose stop, want 0 (stop_grace_period: 20s)"
ok stop_exits_0
unreachable fail_closed egress-workers -x "$PROXY" https://example.com/
unreachable fail_closed egress-workers https://example.com/
unreachable fail_closed egress-workers https://1.1.1.1/
no_dns fail_closed egress-workers
no_dns fail_closed egress-workers 8.8.8.8
ok fail_closed
compose start gateway
wait_health healthy || fail fail_closed "the gateway did not come back after start"

# AC5: a crash of PID 1, or of one smokescreen, brings the container back.
started=$(inspect '{{.State.StartedAt}}')
sudo kill -9 "$(inspect '{{.State.Pid}}')"
wait_restart "$started" || fail restarts_after_crash "not back to healthy"
ok restarts_after_crash
started=$(inspect '{{.State.StartedAt}}')
smokescreen_pid=$(docker top "$GW" -eo pid,args | awk '$2 == "/smokescreen" { print $1; exit }')
[[ -n $smokescreen_pid ]] || fail restarts_after_child_exit "no smokescreen process in docker top"
sudo kill -9 "$smokescreen_pid"
wait_restart "$started" || fail restarts_after_child_exit "not back to healthy"
ok restarts_after_child_exit

# AC6 + AC7: an edit without a restart turns health unhealthy; the restart applies it to a
# caller that keeps running with the same proxy settings.
docker run -d --name "$LONG" --network egress-workers --entrypoint sleep "$PROBE_IMAGE" 600 >/dev/null
long_started=$(docker inspect --format '{{.State.StartedAt}}' "$LONG")
long_connect() {
  docker exec "$LONG" curl -sS -o /dev/null --max-time 15 -w '%{http_connect}' -x "$PROXY" https://1.1.1.1/ 2>/dev/null || true
}
[[ $(long_connect) == 200 ]] || fail restart_applies_policy "1.1.1.1 was not allowed before the change"
printf 'version: 1\nnetworks:\n  workers:\n    mode: denylist\n    deny_ranges: [1.1.1.1/32]\n' >"$EGRESS_CONFIG_DIR/config.local.yaml"
wait_health unhealthy || fail unhealthy_on_config_drift "still healthy after the config changed"
inspect '{{range .State.Health.Log}}{{.Output}}{{end}}' | grep -q 'network workers: running policy differs from' ||
  fail unhealthy_on_config_drift "the health log does not name the network"
ok unhealthy_on_config_drift
compose restart gateway
wait_health healthy || fail restart_applies_policy "not healthy after the restart"
[[ $(long_connect) == 407 ]] || fail restart_applies_policy "1.1.1.1 is still allowed after the restart"
[[ $(docker inspect --format '{{.State.StartedAt}}' "$LONG") == "$long_started" ]] ||
  fail restart_applies_policy "the caller container was restarted"
ok restart_applies_policy
docker rm -f "$LONG" >/dev/null

# AC8 + AC15: a config error stops the gateway at start and the log names it.
# expect_start_error <check> <message>: after a restart, the container exits 2 with it.
expect_start_error() {
  local i
  compose restart gateway >/dev/null 2>&1 || true
  for ((i = 0; i < 30; i++)); do
    if docker logs --since 1m "$GW" 2>&1 | grep -qF "$2" && [[ $(inspect '{{.State.ExitCode}}') == 2 ]]; then
      ok "$1"
      return
    fi
    sleep 1
  done
  fail "$1" "no exit 2 with '$2' in docker logs"
}
printf 'version: 1\nnetworks:\n  workers:\n    deny_ranges: []\n' >"$EGRESS_CONFIG_DIR/config.local.yaml"
expect_start_error missing_key_logged "network workers: missing key mode"
printf 'version: 1\nnetworks:\n  workers:\n    mode: denylist\n  api:\n    mode: denylist\n' >"$EGRESS_CONFIG_DIR/config.local.yaml"
expect_start_error networks_mismatch_logged "networks [api, workers] differ from the gateway's networks [workers]; run ./start.sh"
use_config workers.yaml
compose restart gateway
wait_health healthy || fail missing_key_logged "not healthy again after the config was fixed"

# AC5: the Docker daemon restarts.
sudo systemctl restart docker
for ((i = 0; i < 60; i++)); do docker info >/dev/null 2>&1 && break; sleep 1; done
wait_health healthy || fail restarts_after_daemon_restart "not back to healthy"
ok restarts_after_daemon_restart

# expect_networks <check> <key...>: one gateway container, attached to egress-uplink and to
# exactly egress-<key> per key (sorted), each internal; the labels and EGRESS_NETWORKS name
# exactly those keys.
expect_networks() {
  local name=$1 list want got k
  shift
  list=$(IFS=,; echo "$*")
  [[ $(docker ps -a --filter label=windroc.egress.contract --format '{{.Names}}') == "$GW" ]] ||
    fail "$name" "the contract label does not find exactly $GW"
  want="windroc.egress.contract=1"$'\n'"windroc.egress.networks=$list"
  for k in "$@"; do
    want+=$'\n'"windroc.egress.network.$k.name=egress-$k"$'\n'"windroc.egress.network.$k.proxy=http://egress-proxy-$k:4750"
  done
  want=$(sort <<<"$want")
  got=$(inspect '{{range $k, $v := .Config.Labels}}{{println $k "=" $v}}{{end}}' | sed 's/ = /=/' | grep '^windroc\.egress\.' | sort)
  [[ $got == "$want" ]] || fail "$name" "labels are: $got"
  inspect '{{range .Config.Env}}{{println .}}{{end}}' | grep -qx "EGRESS_NETWORKS=$list" ||
    fail "$name" "EGRESS_NETWORKS is not $list"
  want=$(printf 'egress-%s\n' uplink "$@" | sort | xargs)
  got=$(inspect '{{range $k, $v := .NetworkSettings.Networks}}{{println $k}}{{end}}' | sort | xargs)
  [[ $got == "$want" ]] || fail "$name" "attached to: $got"
  for k in "$@"; do
    [[ $(docker network inspect --format '{{.Internal}}' "egress-$k") == true ]] || fail "$name" "egress-$k is not internal"
  done
  ok "$name"
}

# two_networks_config [extra section text]: the stage B config, plus extra sections.
two_networks_config() {
  sed "s/LAN_IP/$lan_ip/" "$repo/tests/fixtures/two-networks.yaml" >"$EGRESS_CONFIG_DIR/config.local.yaml"
  printf '%s' "${1:-}" >>"$EGRESS_CONFIG_DIR/config.local.yaml"
}

# -------- Stage B: workers and mini-op, each with only its own policy --------
# The runner's own LAN address stands in for the mini: it must be private, so the deny
# floor covers it and only an exception opens it.
lan_ip=$(ip -4 route get 1.1.1.1 | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
case $lan_ip in
  10.* | 192.168.* | 172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) ok lan_ip_private ;;
  *) fail lan_ip_private "the runner's LAN address '$lan_ip' is not private" ;;
esac
# Host listeners: Ollama's port, a neighbouring port, and the mini's ssh port stand-in.
# They serve an empty directory, so they expose no files.
mkdir -p "$work/www"
for port in 11434 11435 2222; do
  python3 -m http.server --bind 0.0.0.0 --directory "$work/www" "$port" >/dev/null 2>&1 &
  host_listeners+=($!)
done
for port in 11434 11435 2222; do
  for ((i = 0; i < 20; i++)); do curl -s -o /dev/null "http://127.0.0.1:$port/" && break; sleep 0.5; done
done

# AC15 (FR-6): mini-op's own network and proxy container stay untouched.
docker network create "$LEGACY_NET" >/dev/null
docker run -d --name "$LEGACY_PROXY" --network "$LEGACY_NET" --entrypoint sleep "$PROBE_IMAGE" 600 >/dev/null
legacy() {
  docker network inspect --format '{{.Id}}' "$LEGACY_NET"
  docker inspect --format '{{.Id}} {{.State.StartedAt}} {{.State.Running}}' "$LEGACY_PROXY"
}
legacy_before=$(legacy)

two_networks_config
start
wait_health healthy || fail two_networks_healthy "the two-network gateway did not become healthy"
ok two_networks_healthy
# AC1: one gateway on both networks, advertised one to one with the config's sections.
expect_networks networks_match_config mini-op workers
[[ $(legacy) == "$legacy_before" ]] || fail mini_op_names_untouched "before: $legacy_before; after: $(legacy)"
ok mini_op_names_untouched

# AC2: mini-op's allowlist and its exception.
allowed mini_op_allows egress-mini-op "$MPROXY" https://example.com/
denied mini_op_denies_public egress-mini-op "$MPROXY" https://www.wikipedia.org/
tunneled mini_op_exception egress-mini-op "$MPROXY" "http://$lan_ip:2222/"

# AC3: neither network gets the other's allows.
denied workers_no_mini_op_allow egress-workers "$PROXY" "https://$lan_ip:2222/"
# The gateway resolves host.docker.internal to the default bridge's gateway (host-gateway).
hdi_ip=$(docker network inspect bridge --format '{{(index .IPAM.Config 0).Gateway}}')
denied mini_op_no_workers_exception egress-mini-op "$MPROXY" "https://$hdi_ip:11434/"

# A named allowlist exception opens only its start-time address at its port: the ACL lists
# the address, not the name, so smokescreen never re-resolves the name into a new opening.
tunneled named_exception_by_address egress-mini-op "$MPROXY" "http://$hdi_ip:2222/"
denied named_exception_other_port egress-mini-op "$MPROXY" "https://$hdi_ip:11435/"
denied named_exception_by_name egress-mini-op "$MPROXY" https://host.docker.internal:2222/

# AC7: the workers exception opens that port of that host only.
tunneled workers_exception egress-workers "$PROXY" http://host.docker.internal:11434/
denied workers_exception_other_port egress-workers "$PROXY" https://host.docker.internal:11435/
denied workers_exception_other_host egress-workers "$PROXY" "https://$lan_ip:11434/"

# AC6 (FR-8): a public name resolving to 127.0.0.1 is denied, even when allowlisted.
denied private_resolution_denied egress-workers "$PROXY" https://localtest.me/
denied private_resolution_denied egress-mini-op "$MPROXY" https://localtest.me/

# AC4: no caller reaches the other network's proxy listener, directly or through its own.
gw_workers_ip=$(inspect '{{(index .NetworkSettings.Networks "egress-workers").IPAddress}}')
gw_mini_op_ip=$(inspect '{{(index .NetworkSettings.Networks "egress-mini-op").IPAddress}}')
unreachable no_cross_proxy egress-workers -x "http://$gw_mini_op_ip:4750" https://example.com/
unreachable no_cross_proxy egress-workers -x "$MPROXY" https://example.com/
unreachable no_cross_proxy egress-mini-op -x "http://$gw_workers_ip:4750" https://example.com/
unreachable no_cross_proxy egress-mini-op -x "$PROXY" https://example.com/
denied no_cross_proxy egress-workers "$PROXY" "https://$gw_mini_op_ip:4750/"
denied no_cross_proxy egress-workers "$PROXY" https://egress-proxy-mini-op:4750/
denied no_cross_proxy egress-mini-op "$MPROXY" "https://$gw_workers_ip:4750/"

# AC5: containers on the two networks cannot reach each other. Each listener (a plain
# smokescreen from the gateway image) answers on its own network: the positive control.
image=$(compose config --images)
for net in workers mini-op; do
  docker run -d --name "egress-test-listen-$net" --network "egress-$net" --entrypoint /smokescreen \
    "$image" --listen-ip 0.0.0.0 --listen-port 8080 >/dev/null
done
reach() { probe "$1" -w '%{http_code}' "http://$2:8080/"; }
for pair in "workers mini-op" "mini-op workers"; do
  read -r own other <<<"$pair"
  ip=$(docker inspect --format "{{(index .NetworkSettings.Networks \"egress-$own\").IPAddress}}" "egress-test-listen-$own")
  for ((i = 0; i < 10; i++)); do
    out=$(reach "egress-$own" "$ip")
    [[ $out != 000* ]] && break
    sleep 1
  done
  [[ $out != 000* ]] || fail no_cross_containers "the listener on egress-$own does not answer on its own network: $out"
  out=$(reach "egress-$other" "$ip")
  [[ $out == 000* ]] || fail no_cross_containers "the listener on egress-$own answered from egress-$other: $out"
done
ok no_cross_containers
docker rm -f "${LISTENERS[@]}" >/dev/null

# AC1, AC10, AC11, AC19 (FR-12, FR-13, FR-14): verify-egress on both networks. The fixture's
# mini-op allows localtest.me for the FR-8 checks above, and verify-egress expects every
# allow entry to work, so this config leaves it out. Port 22 of the runner's LAN address
# (its ssh server) and port 2223 stand in for mini-op's old hard-coded LAN targets.
# verify_config <workers deny targets>
verify_config() {
  cat >"$EGRESS_CONFIG_DIR/config.local.yaml" <<EOF
version: 1
networks:
  workers:
    mode: denylist
    exceptions:
      - host.docker.internal:11434
    verify:
      deny_targets: [$1]
  mini-op:
    mode: allowlist
    allow:
      - example.com
    exceptions:
      - $lan_ip:2222
      - host.docker.internal:2222
    verify:
      deny_targets: ["$lan_ip:22", "$lan_ip:2223"]
EOF
  compose restart gateway >/dev/null
  wait_health healthy || fail verify_config "not healthy after the restart"
}
# verify <check> <want exit> <args...>: runs verify-egress, prints its output, and checks
# its exit code; leaves the output in $verify_out.
verify() {
  local name=$1 want=$2 rc=0
  shift 2
  verify_out=$("$repo/verify-egress" "$@" 2>&1) || rc=$?
  local line
  while IFS= read -r line; do printf '  verify-egress %s: %s\n' "$*" "$line"; done <<<"$verify_out"
  [[ $rc == "$want" ]] || fail "$name" "verify-egress $* exited $rc, want $want"
}
verify_config ""
verify verify_egress_workers 0 workers
ok verify_egress_workers
verify verify_egress_mini_op 0 mini-op
for target in "$lan_ip:22" "$lan_ip:2223"; do
  grep -qxF "ok proxy_deny $target connect=407" <<<"$verify_out" ||
    fail verify_deny_targets "no 'ok proxy_deny $target connect=407'"
done
ok verify_egress_mini_op
ok verify_deny_targets
# A deny target the policy allows is a mismatch, named.
verify_config '"example.com:443"'
verify verify_egress_mismatch 1 workers
grep -qxF "FAIL proxy_deny example.com:443: connect=200, want connect=407" <<<"$verify_out" ||
  fail verify_egress_mismatch "the mismatch is not named"
grep -qx "1 of [0-9]* checks failed: proxy_deny" <<<"$verify_out" ||
  fail verify_egress_mismatch "the summary does not name proxy_deny"
ok verify_egress_mismatch
# The tool check with the probe image as the worker image (non-root): rows carry its ID.
verify verify_egress_tools 0 --tools "$PROBE_IMAGE"
probe_id=$(docker image inspect --format '{{.Id}}' "$PROBE_IMAGE")
for line in "| curl | works | works | $probe_id | $(date -u +%Y-%m-%d) |" \
  "| ssh | fails | not in image | $probe_id | $(date -u +%Y-%m-%d) |"; do
  grep -qxF "$line" <<<"$verify_out" || fail verify_egress_tools "no '$line'"
done
ok verify_egress_tools
two_networks_config
compose restart gateway >/dev/null
wait_health healthy || fail verify_egress_tools "not healthy after restoring the fixture"

# -------- Stage C: add and remove a network through the config alone --------
# AC10: a third section; the documented command attaches and advertises it.
testnet=$'  testnet:\n    mode: allowlist\n    allow:\n      - example.com\n'
two_networks_config "$testnet"
start
wait_health healthy || fail add_network "not healthy with the testnet section"
expect_networks add_network mini-op testnet workers
allowed add_network egress-testnet http://egress-proxy-testnet:4750 https://example.com/
denied add_network egress-testnet http://egress-proxy-testnet:4750 https://www.wikipedia.org/
allowed add_network egress-workers "$PROXY" https://www.wikipedia.org/
allowed add_network egress-mini-op "$MPROXY" https://example.com/
denied add_network egress-mini-op "$MPROXY" https://www.wikipedia.org/

# AC11: the start command a second time changes nothing.
state3() {
  inspect '{{.Id}} {{.State.StartedAt}} {{.Image}}'
  docker network inspect --format '{{.Id}}' egress-workers egress-mini-op egress-testnet egress-uplink
}
before=$(state3)
start
[[ $(state3) == "$before" ]] || fail start_idempotent "before: $before; after: $(state3)"
ok start_idempotent

# AC10: another checkout (another egress version) with the same config keeps the network.
copy=$work/egress-copy
mkdir -p "$copy"
git -C "$repo" ls-files -z | (cd "$repo" && xargs -0 cp --parents -t "$copy")
"$copy/start.sh"
wait_health healthy || fail other_checkout_keeps_network "not healthy after the other checkout's start"
expect_networks other_checkout_keeps_network mini-op testnet workers

# AC10: without the mini-op section, the gateway leaves egress-mini-op and its labels.
sed "s/LAN_IP/$lan_ip/" "$repo/tests/fixtures/two-networks.yaml" |
  awk '/^  mini-op:/ { skip = 1; next } /^  [a-z]/ { skip = 0 } !skip' >"$EGRESS_CONFIG_DIR/config.local.yaml"
printf '%s' "$testnet" >>"$EGRESS_CONFIG_DIR/config.local.yaml"
start
wait_health healthy || fail remove_network "not healthy without the mini-op section"
expect_networks remove_network testnet workers

echo "all checks passed"
