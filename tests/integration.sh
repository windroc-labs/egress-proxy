#!/usr/bin/env bash
# Docker end-to-end checks of the gateway (CI `integration` job). Linux CI only: it needs
# Docker and passwordless sudo, kills the gateway's processes and restarts the Docker
# daemon. Prints `ok <check>` per check and stops at the first `FAIL <check>: <detail>`.
#
# Stage A runs the base compose.yaml (the `workers` network only); stage B adds
# tests/compose.test.yaml (a second network, in allowlist mode).
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
PROBE_IMAGE=curlimages/curl:8.16.0@sha256:463eaf6072688fe96ac64fa623fe73e1dbe25d8ad6c34404a669ad3ce1f104b6
LONG=egress-test-long
compose_files=(-f "$repo/compose.yaml")

compose() { docker compose --project-directory "$repo" "${compose_files[@]}" "$@"; }

cleanup() {
  local code=$?
  if ((code != 0)); then
    echo "--- docker inspect $GW .State"
    docker inspect --format '{{json .State}}' "$GW" 2>&1 || true
    echo "--- docker logs $GW (last 100 lines)"
    docker logs --tail 100 "$GW" 2>&1 || true
  fi
  docker rm -f "$LONG" >/dev/null 2>&1 || true
  compose down --remove-orphans >/dev/null 2>&1 || true
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

# unreachable <check> <network> <curl args...>: curl fails without any HTTP answer.
unreachable() {
  local name=$1 net=$2 out
  shift 2
  out=$(probe "$net" -w '%{http_connect}%{http_code}' "$@")
  [[ $out == 000000\ * ]] || fail "$name" "curl $* from $net got '$out', want no connection"
}

# no_dns <check> <network> [server]: an external name does not resolve.
no_dns() {
  if docker run --rm --network "$2" --entrypoint nslookup "$PROBE_IMAGE" example.com ${3:+"$3"} >/dev/null 2>&1; then
    fail "$1" "example.com resolved from $2${3:+ via $3}"
  fi
}

# The documented start command (README.md).
start() { compose build --quiet && compose up -d --quiet-pull; }

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

# AC3 (NFR-1): with the gateway stopped, the network has no way out.
compose stop
unreachable fail_closed egress-workers -x "$PROXY" https://example.com/
unreachable fail_closed egress-workers https://example.com/
unreachable fail_closed egress-workers https://1.1.1.1/
no_dns fail_closed egress-workers
no_dns fail_closed egress-workers 8.8.8.8
ok fail_closed
compose up -d --quiet-pull
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
expect_start_error networks_mismatch_logged "networks [api, workers] differ from the gateway's networks [workers]"
use_config workers.yaml
compose restart gateway
wait_health healthy || fail missing_key_logged "not healthy again after the config was fixed"

# AC5: the Docker daemon restarts.
sudo systemctl restart docker
for ((i = 0; i < 60; i++)); do docker info >/dev/null 2>&1 && break; sleep 1; done
wait_health healthy || fail restarts_after_daemon_restart "not back to healthy"
ok restarts_after_daemon_restart

# -------- Stage B: compose.yaml + tests/compose.test.yaml --------
compose_files+=(-f "$repo/tests/compose.test.yaml")
use_config two-networks.yaml
start
wait_health healthy || fail allowlist_allows "the two-network gateway did not become healthy"
allowed allowlist_allows egress-testallow http://egress-proxy-testallow:4750 https://example.com/
denied allowlist_denies egress-testallow http://egress-proxy-testallow:4750 https://www.wikipedia.org/
allowed workers_unaffected egress-workers "$PROXY" https://www.wikipedia.org/

echo "all checks passed"
