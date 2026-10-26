#!/usr/bin/env bash
# Self-test of verify-egress (CI `lint` job): runs the unmodified script against a fake
# `docker` (and fake host tools) on PATH, so no Docker daemon, registry credential or
# keychain is ever reached: DOCKER_HOST points at a socket that does not exist.
# Prints `ok <case>` or `FAIL <case>: <detail>`; exits 1 if any case fails.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

status=0
ok() { echo "ok $1"; }
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  status=1
}

export DOCKER_HOST=unix://$work/nonexistent.sock
export DOCKER_CONFIG=$work/docker
mkdir -p "$work/bin" "$DOCKER_CONFIG"

# The fake docker. State and scenario live in $FAKE:
#   ids        containers matching the contract label (default: px1)
#   health     "<running> <health>" (default: true healthy)
#   plan       the plan `proxy plan` prints; plan.rc and plan.err make it fail
#   answers    "<url>\t<write-out>\t<exit>" lines overriding curl's answer for a URL, or
#              "<proxy> <url>\t…" for that URL through that proxy only
#   open       host:port targets a CONNECT tunnel reaches
#   body       when present, curl also writes a body and a token-like line
#   calls      every call, with the DOCKER_CONFIG and DOCKER_HOST it saw
#   image_user, image_id, image_missing   what `docker image inspect` reports
#   rows       what the tool container prints; tool_run the `docker run` of it
#   pxlog      "<unix time>\t<line>" lines `docker logs --since --until` of the proxy serves
cat >"$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "DOCKER_CONFIG=${DOCKER_CONFIG:-} DOCKER_HOST=${DOCKER_HOST:-} $*" >>"$FAKE/calls"
network_key() { sed -E 's/.*windroc\.egress\.network\.([a-z0-9-]+)\.(name|proxy).*/\1/' <<<"$1"; }
peer_ip() {
  case $1 in
    egress-workers) echo 172.31.1.5 ;;
    *) echo 172.31.2.5 ;;
  esac
}
fake_curl() {
  local container=$1 url x="" p="" write="" arg prev=""
  shift
  for arg in "$@"; do
    case $prev in
      -x) x=$arg ;;
      -w) write=$arg ;;
    esac
    [[ $arg == -p ]] && p=yes
    prev=$arg
    url=$arg
  done
  if [[ -f $FAKE/body ]]; then
    echo "SECRET-BODY-0123 token=sk-ant-SELFTEST" >&2
  fi
  local line
  line=$(awk -F '\t' -v u="$url" -v xu="$x $url" '$1 == xu || $1 == u { print; exit }' "$FAKE/answers" 2>/dev/null || true)
  if [[ -n $line ]]; then
    printf '%s' "$(cut -f 2 <<<"$line")"
    exit "$(cut -f 3 <<<"$line")"
  fi
  if [[ -n $x && -n $p ]]; then
    local target=${url#http://}
    target=${target%/}
    if grep -qxF "$target" "$FAKE/open" 2>/dev/null; then
      printf '200 200'
      exit 0
    fi
    printf '407 000'
    exit 56
  elif [[ -n $x && $x == "${PROXY:-http://egress-proxy-workers:4750}" ]]; then
    printf '200 200'
    exit 0
  elif [[ -z $x && $url == http://172.31.*:8080/ ]]; then
    local own
    own=$(cat "$FAKE/c/$container")
    if [[ $url == "http://$(peer_ip "$own"):8080/" ]]; then
      printf '000404'
      exit 0
    fi
  fi
  [[ $write == *' '* ]] && printf '000 000' || printf '000000'
  exit 7
}
case $1 in
  context) echo unix:///fake-context.sock ;;
  image)
    [[ ! -f $FAKE/image_missing ]] || exit 1
    case $4 in
      *'.Config.User'*) cat "$FAKE/image_user" 2>/dev/null || echo 1000:1000 ;;
      *'{{.Id}}'*) cat "$FAKE/image_id" 2>/dev/null || echo sha256:feedc0de0123456789abcdef ;;
    esac
    ;;
  wait) echo 0 ;;
  logs)
    if [[ $2 == --since ]]; then
      awk -F '\t' -v s="$3" -v e="$5" '$1 >= s && $1 <= e { print $2 }' "$FAKE/pxlog" 2>/dev/null || true
    else
      cat "$FAKE/rows" 2>/dev/null || true
    fi
    ;;
  ps) cat "$FAKE/ids" 2>/dev/null || echo px1 ;;
  inspect)
    fmt=$3 id=$4
    case $fmt in
      *'{{.Name}}'*) echo /egress-proxy ;;
      *'"windroc.egress.contract"'*) echo 1 ;;
      *'.State.Running'*) cat "$FAKE/health" 2>/dev/null || echo "true healthy" ;;
      *'"windroc.egress.networks"'*) echo "mini-op,workers" ;;
      *'.name"'*) echo "egress-$(network_key "$fmt")" ;;
      *'.proxy"'*) echo "http://egress-proxy-$(network_key "$fmt"):4750" ;;
      *'.Config.Image'*) echo egress-proxy-image ;;
      *IPAddress*) peer_ip "$(cat "$FAKE/c/$id")" ;;
      *) echo "fake docker: unknown inspect $fmt" >&2; exit 1 ;;
    esac
    ;;
  network) echo true ;;
  run)
    n=$(($(cat "$FAKE/n" 2>/dev/null || echo 0) + 1))
    echo "$n" >"$FAKE/n"
    prev=""
    for arg in "$@"; do
      [[ $prev == --network ]] && net=$arg
      prev=$arg
    done
    mkdir -p "$FAKE/c"
    echo "$net" >"$FAKE/c/c$n"
    [[ " $* " != *" --entrypoint sh "* ]] || echo "$*" >"$FAKE/tool_run"
    echo "c$n"
    ;;
  exec)
    container=$2
    shift 2
    case $1 in
      /proxy)
        if [[ -f $FAKE/plan.rc ]]; then
          cat "$FAKE/plan.err" >&2
          exit "$(cat "$FAKE/plan.rc")"
        fi
        cat "$FAKE/plan"
        ;;
      curl) shift; fake_curl "$container" "$@" ;;
      nslookup) exit "$(cat "$FAKE/nslookup.rc" 2>/dev/null || echo 1)" ;;
      true) [[ ! -f $FAKE/probe_gone ]] ;;
      *) echo "fake docker: unknown exec $1" >&2; exit 1 ;;
    esac
    ;;
  rm) ;;
  *) echo "fake docker: unknown command $1" >&2; exit 1 ;;
esac
FAKE
# Fake host tools: a Linux host with one LAN address and a default gateway.
cat >"$work/bin/uname" <<'FAKE'
#!/usr/bin/env bash
echo "${FAKE_UNAME:-Linux}"
FAKE
cat >"$work/bin/ip" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "-4 route show default") echo "default via 10.1.0.1 dev eth0 proto dhcp" ;;
  "-6 route show default") ;;
  "-o addr show")
    echo "1: lo    inet 127.0.0.1/8 scope host lo"
    echo "2: eth0    inet 10.1.0.4/16 brd 10.1.255.255 scope global eth0"
    echo "2: eth0    inet6 2001:db8:1::4/64 scope global"
    ;;
esac
FAKE
cat >"$work/bin/route" <<'FAKE'
#!/usr/bin/env bash
case "$*" in
  "-n get default") printf '   route to: default\n    gateway: 192.168.1.1\n  interface: en0\n' ;;
  "-n get -inet6 default") printf '   route to: default\n    gateway: fe80::1%%en0\n' ;;
esac
FAKE
cat >"$work/bin/ifconfig" <<'FAKE'
#!/usr/bin/env bash
cat <<'OUT'
lo0: flags=8049<UP,LOOPBACK,RUNNING,MULTICAST> mtu 16384
	inet 127.0.0.1 netmask 0xff000000
	inet6 ::1 prefixlen 128
en0: flags=8863<UP,BROADCAST,SMART,RUNNING,SIMPLEX,MULTICAST> mtu 1500
	inet6 fe80::1c2b:3d4e:5f60:7182%en0 prefixlen 64 secured scopeid 0x4
	inet 192.168.1.20 netmask 0xffffff00 broadcast 192.168.1.255
	inet6 2001:db8:1:2::20 prefixlen 64 autoconf secured
OUT
FAKE
chmod +x "$work/bin/"*

PLAN=$(printf '%s\n' \
  $'proxy_deny\tproxy_deny\t10.0.0.1:443' \
  $'proxy_allow\tproxy_allow\thttps://example.com/' \
  $'exception_open\tproxy_open\thost.docker.internal:11434' \
  $'exception_other_port\tproxy_deny\thost.docker.internal:11435' \
  $'cross_none\tcross_none\thttp://172.21.0.2:4750/' \
  $'cross_none\tcross_none\thttp://172.21.0.2:4750 https://example.com/' \
  $'direct_none\tdirect_none\thttps://1.1.1.1/' \
  $'dns_none\tdns_none\texample.com' \
  $'dns_none\tdns_none\texample.com@1.1.1.1')
# 7 preconditions (proxy_found .. plan), the 9 plan checks, peer_control and peer_none.
TOTAL=18

# scenario <name>: a fresh $FAKE with the passing defaults.
scenario() {
  FAKE=$work/fake-$1
  mkdir -p "$FAKE"
  printf '%s\n' "$PLAN" >"$FAKE/plan"
  echo host.docker.internal:11434 >"$FAKE/open"
  export FAKE
}

# run <args...>: verify-egress's combined output, then its exit code on the last line.
run() {
  local rc=0 out
  out=$(PATH="$work/bin:$PATH" "$repo/verify-egress" "$@" 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$out" "$rc"
}

expect() {
  local name=$1 out=$2 want_exit=$3
  shift 3
  local line
  [[ $(tail -n 1 <<<"$out") == "exit=$want_exit" ]] || {
    fail "$name" "want exit $want_exit: $out"
    return
  }
  for line in "$@"; do
    grep -qxF -- "$line" <<<"$out" || {
      fail "$name" "no line '$line' in: $out"
      return
    }
  done
  ok "$name"
}

curl_calls() { grep -c ' exec [^ ]* curl ' "$FAKE/calls" || true; }

scenario all_pass
out=$(run workers)
expect all_pass "$out" 0 \
  "ok proxy_healthy egress-proxy healthy" \
  "ok proxy_deny 10.0.0.1:443 connect=407" \
  "ok proxy_allow https://example.com/ connect=200 http=200" \
  "ok exception_open host.docker.internal:11434 connect=200" \
  "ok cross_none http://172.21.0.2:4750 https://example.com/ no connection (curl exit 7)" \
  "ok dns_none example.com@1.1.1.1 no resolution" \
  "ok peer_control http://172.31.2.5:8080/ answers on egress-mini-op" \
  "ok peer_none http://172.31.2.5:8080/ no connection (curl exit 7)" \
  "all $TOTAL checks passed"

# The listener is gone once verify-egress has exited.
port=$(sed -nE 's/.*--listener-port ([0-9]+).*/\1/p' "$FAKE/calls" | head -n 1)
if [[ -z $port ]]; then
  fail listener_removed "no --listener-port in the plan call"
elif curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$port/"; then
  fail listener_removed "127.0.0.1:$port still answers"
else
  ok listener_removed
fi

# Linux host facts reach the plan call.
if grep -qF -- "--host-addr 10.1.0.4/16" "$FAKE/calls" &&
  grep -qF -- "--host-addr 2001:db8:1::4/64" "$FAKE/calls" &&
  grep -qF -- "--default-gateway 10.1.0.1" "$FAKE/calls"; then
  ok linux_host_facts
else
  fail linux_host_facts "$(grep ' exec px1 ' "$FAKE/calls")"
fi

# Every docker call saw the throwaway client config and the pinned endpoint.
if grep -v "^DOCKER_CONFIG=/[^ ]*/docker DOCKER_HOST=unix://$work/nonexistent.sock " "$FAKE/calls" | grep -q . ||
  grep -qF "DOCKER_CONFIG=$DOCKER_CONFIG " "$FAKE/calls"; then
  fail docker_config_throwaway "$(head -n 3 "$FAKE/calls")"
else
  ok docker_config_throwaway
fi

scenario context_endpoint
out=$(DOCKER_HOST='' run workers)
if [[ $(tail -n 1 <<<"$out") == exit=0 ]] && grep -q '^DOCKER_CONFIG=[^ ]* DOCKER_HOST= context inspect' "$FAKE/calls" &&
  ! grep -v ' context inspect' "$FAKE/calls" | grep -qv 'DOCKER_HOST=unix:///fake-context.sock '; then
  ok context_endpoint
else
  fail context_endpoint "$out"
fi

scenario darwin_host_facts
out=$(FAKE_UNAME=Darwin run workers)
if [[ $(tail -n 1 <<<"$out") == exit=0 ]] &&
  grep -qF -- "--default-gateway 192.168.1.1 --default-gateway fe80::1 --host-addr 127.0.0.1/8 --host-addr ::1/128 --host-addr fe80::1c2b:3d4e:5f60:7182/64 --host-addr 192.168.1.20/24 --host-addr 2001:db8:1:2::20/64" "$FAKE/calls"; then
  ok darwin_host_facts
else
  fail darwin_host_facts "$out $(grep ' exec px1 ' "$FAKE/calls" || true)"
fi

scenario mismatch_named
printf 'http://10.0.0.1:443/\t200 200\t0\n' >"$FAKE/answers"
out=$(run workers)
expect mismatch_named "$out" 1 \
  "FAIL proxy_deny 10.0.0.1:443: connect=200, want connect=407" \
  "1 of $TOTAL checks failed: proxy_deny"

# An allowed site that answers 404 at its root was still reached.
scenario allow_any_answer
printf 'http://egress-proxy-workers:4750 https://example.com/\t200 404\t0\n' >"$FAKE/answers"
out=$(run workers)
expect allow_any_answer "$out" 0 "ok proxy_allow https://example.com/ connect=200 http=404"

scenario allow_no_answer
printf 'http://egress-proxy-workers:4750 https://example.com/\t200 000\t35\n' >"$FAKE/answers"
out=$(run workers)
expect allow_no_answer "$out" 1 "FAIL proxy_allow https://example.com/: connect=200 http=000, want connect=200 and an HTTP answer"

scenario exception_not_answering
printf 'http://host.docker.internal:11434/\t502 000\t56\n' >"$FAKE/answers"
out=$(run workers)
expect exception_not_answering "$out" 1 \
  "FAIL exception_open host.docker.internal:11434: connect=502: target did not answer; start it or remove the exception, want connect=200"

scenario direct_connected
printf 'https://1.1.1.1/\t000200\t0\n' >"$FAKE/answers"
out=$(run workers)
expect direct_connected "$out" 1 "FAIL direct_none https://1.1.1.1/: connected (codes 000200), want no connection"

scenario probe_gone
printf 'proxy_deny\tproxy_deny\t10.0.0.1:443\ndns_none\tdns_none\texample.com\n' >"$FAKE/plan"
touch "$FAKE/probe_gone"
out=$(run workers)
expect probe_gone "$out" 1 "FAIL dns_none example.com: the probe is not running, want no resolution"

scenario dns_resolved
echo 0 >"$FAKE/nslookup.rc"
out=$(run workers)
expect dns_resolved "$out" 1 "FAIL dns_none example.com: resolved, want no resolution"

scenario no_body_no_token
touch "$FAKE/body"
printf 'http://egress-proxy-workers:4750 https://example.com/\tSECRET-BODY-0123 200 200\t0\n' >"$FAKE/answers"
out=$(EGRESS_SELFTEST_TOKEN=sk-ant-SELFTEST-TOKEN run workers)
if [[ $out == *SECRET-BODY* || $out == *sk-ant-SELFTEST* ]]; then
  fail no_body_no_token "$out"
elif ! grep -qxF "FAIL proxy_allow https://example.com/: the probe did not run curl, want connect=200 and an HTTP answer" <<<"$out"; then
  fail no_body_no_token "unparseable curl output is not reported as such: $out"
else
  ok no_body_no_token
fi

scenario unhealthy_stops
echo "true unhealthy" >"$FAKE/health"
out=$(run workers)
expect unhealthy_stops "$out" 1 \
  "FAIL proxy_healthy egress-proxy: running/health 'true unhealthy', want true healthy" \
  "1 of 3 checks failed: proxy_healthy"
[[ $(curl_calls) == 0 ]] || fail unhealthy_stops "probes ran"

scenario two_proxies
printf 'px1\ngw2\n' >"$FAKE/ids"
out=$(run workers)
expect two_proxies "$out" 1 "FAIL proxy_found label windroc.egress.contract: 2 containers, want exactly one"

scenario unknown_network
out=$(run other)
expect unknown_network "$out" 1 "FAIL network_advertised other: networks 'mini-op,workers', want other among them"

scenario old_proxy
echo 2 >"$FAKE/plan.rc"
printf 'proxy: unknown option plan\nusage: proxy ...\n' >"$FAKE/plan.err"
out=$(run workers)
expect old_proxy "$out" 1 "FAIL plan egress-proxy: the proxy image has no plan mode; run ./start.sh, want a plan"

# An image from before the rename to proxy has no /proxy to exec.
scenario pre_rename_image
echo 126 >"$FAKE/plan.rc"
echo 'OCI runtime exec failed: exec failed: unable to start container process: exec: "/proxy": stat /proxy: no such file or directory: unknown' >"$FAKE/plan.err"
out=$(run workers)
expect pre_rename_image "$out" 1 "FAIL plan egress-proxy: the proxy image has no plan mode; run ./start.sh, want a plan"

scenario drift_message
echo 2 >"$FAKE/plan.rc"
echo "proxy: network workers: running policy differs from /etc/egress/config.local.yaml; run ./start.sh" >"$FAKE/plan.err"
out=$(run workers)
expect drift_message "$out" 1 "FAIL plan egress-proxy: proxy: network workers: running policy differs from /etc/egress/config.local.yaml; run ./start.sh, want a plan"

# malformed <case> <plan line> <reason>: the line fails `plan` before any probe runs.
malformed() {
  scenario "$1"
  printf '%s\n' "$2" >"$FAKE/plan"
  out=$(run workers)
  expect "$1" "$out" 1 "FAIL plan line 1: $3, want <name> <method> <target>"
  [[ $(curl_calls) == 0 ]] || fail "$1" "probes ran"
}
malformed leading_dash $'proxy_deny\tproxy_deny\t-K/x' "a target element starts with - or is empty"
malformed cross_dash $'cross_none\tcross_none\thttp://a:1 -K/x' "a target element starts with - or is empty"
malformed dns_dash $'dns_none\tdns_none\texample.com@-port=1' "a target element starts with - or is empty"
malformed unknown_method $'x\tbogus\tt' "unknown method"
malformed two_fields $'a\tproxy_deny' "not three tab-separated fields"
malformed four_fields $'a\tproxy_deny\tt\textra' "not three tab-separated fields"

# -------- --tools --------
today=$(date -u +%Y-%m-%d)
allow_line() { printf '%s\t{"level":"info","msg":"CANONICAL-PROXY-DECISION","allow":%s,"requested_host":"%s:443","inbound_remote_addr":"%s:40000"}\n' "$1" "$2" "$3" "$4"; }

scenario tools_results
{
  printf 'curl\t100\t101\t0\n'
  printf 'wget\t110\t111\t0\n'
  printf 'npm\t120\t121\t0\n'
  printf 'gh\t130\t131\t1\n'
  printf 'Claude Code\t140\t141\t1\n'
  printf 'Node fetch\t150\t151\t1\n'
  printf 'apt-get\t160\t161\t100\n'
  printf 'ssh\t170\t170\tmissing\n'
  printf 'QUIC / HTTP/3\t171\t171\tnohttp3\n'
  printf 'Node http\t172\t173\tSECRET-BODY-0123\n'
  printf 'self-resolving program\t180\t181\t0\n'
  printf 'pip\t190\t191\ttimeout\n'
  printf 'uv\t200\t201\t2\n'
  printf 'Node fetch, NODE_USE_ENV_PROXY=1\t210\t211\t1\n'
  printf 'bogus\t1\t2\t0\n'
  printf 'SECRET-BODY-0123 token=sk-ant-SELFTEST\n'
} >"$FAKE/rows"
{
  allow_line 101 true example.com 172.31.1.5
  allow_line 115 true example.com 172.31.1.5
  allow_line 120 true registry.npmjs.org 172.31.9.9
  allow_line 131 true api.github.com 172.31.1.5
  allow_line 141 false api.anthropic.com 172.31.1.5
  allow_line 160 true deb.debian.org 172.31.1.5
  printf '161\tSECRET-BODY-0123 token=sk-ant-SELFTEST\n'
  allow_line 181 true example.com 172.31.1.5
  allow_line 190 true pypi.org 172.31.1.5
  allow_line 200 true example.com 172.31.1.5
  allow_line 211 true example.com 172.31.1.5
} >"$FAKE/pxlog"
out=$(EGRESS_SELFTEST_TOKEN=sk-ant-SELFTEST-TOKEN run --tools worker:test)
expect tools_results "$out" 0 \
  "ok tools_image worker:test user 1000, id sha256:feedc0de0123456789abcdef" \
  "| Tool | Expected | Result | Image ID | Date |" \
  "| curl | works | works | sha256:feedc0de0123456789abcdef | $today |" \
  "| wget | works | fails: no proxy used | sha256:feedc0de0123456789abcdef | $today |" \
  "| npm | works | fails: no proxy used | sha256:feedc0de0123456789abcdef | $today |" \
  "| gh | works | works | sha256:feedc0de0123456789abcdef | $today |" \
  "| Claude Code | works | fails: no proxy used | sha256:feedc0de0123456789abcdef | $today |" \
  "| Node fetch | fails | fails: no proxy used | sha256:feedc0de0123456789abcdef | $today |" \
  "| apt-get | works | fails: exit 100 | sha256:feedc0de0123456789abcdef | $today |" \
  "| ssh | fails | not in image | sha256:feedc0de0123456789abcdef | $today |" \
  "| QUIC / HTTP/3 | fails | could not run: no HTTP/3 in curl | sha256:feedc0de0123456789abcdef | $today |" \
  "| Node http | fails | could not run: no runtime | sha256:feedc0de0123456789abcdef | $today |" \
  "| self-resolving program | fails | works | sha256:feedc0de0123456789abcdef | $today |" \
  "| pip | works | fails: timed out | sha256:feedc0de0123456789abcdef | $today |" \
  "| uv | works | fails: no proxy used | sha256:feedc0de0123456789abcdef | $today |" \
  "| Node fetch, NODE_USE_ENV_PROXY=1 | works | fails: exit 1 | sha256:feedc0de0123456789abcdef | $today |" \
  "differs from expected: self-resolving program, Node fetch, NODE_USE_ENV_PROXY=1, wget, pip, uv, npm, apt-get, Claude Code"
[[ $out != *SECRET-BODY* && $out != *sk-ant-SELFTEST* ]] || fail tools_no_body_no_token "$out"
[[ $(grep -c '^| ' <<<"$out") == 33 ]] || fail tools_results "want a header, a separator and 31 rows: $out"
grep -q '^could not run: .*QUIC / HTTP/3.*Node http' <<<"$out" || fail tools_results "could not run line: $out"
run_args=$(cat "$FAKE/tool_run" 2>/dev/null || true)
# The docker options: everything before the image and its script.
run_args=${run_args%% --entrypoint sh *}
for want in "--pull never" "--network egress-workers" "--cap-drop ALL" "--security-opt no-new-privileges" \
  "-e HTTP_PROXY=http://egress-proxy-workers:4750" "-e https_proxy=http://egress-proxy-workers:4750" \
  "-e NO_PROXY=localhost,127.0.0.1,::1" "-e no_proxy=localhost,127.0.0.1,::1"; do
  [[ " $run_args " == *" $want "* ]] || fail tools_run_args "no '$want' in: $run_args"
done
[[ " $run_args " != *" -v "* && " $run_args " != *" --mount "* ]] || fail tools_run_args "a mount: $run_args"
[[ " $run_args " != *" --rm "* ]] || fail tools_run_args "--rm: the container must outlive its run for docker logs"
ok tools_run_args

scenario tools_root_user
echo 0:0 >"$FAKE/image_user"
out=$(run --tools worker:test)
expect tools_root_user "$out" 1 "FAIL tools_image worker:test: image runs as root, want a non-root user"

scenario tools_root_id
echo root >"$FAKE/rows"
out=$(run --tools worker:test)
expect tools_root_id "$out" 1 "FAIL tools_image worker:test: image runs as root, want a non-root user"

scenario tools_not_local
touch "$FAKE/image_missing"
out=$(run --tools worker:test)
expect tools_not_local "$out" 1 "FAIL tools_image worker:test: image worker:test is not local, want a local image"
[[ ! -f $FAKE/tool_run ]] || fail tools_not_local "the tool container ran"

scenario usage
for args in "" "a b" "--bogus" "Bad_Key" "--tools" "--tools -x" "--tools a b"; do
  # shellcheck disable=SC2086 # word splitting builds each argument list
  out=$(run $args)
  if [[ $(tail -n 1 <<<"$out") != exit=2 || $out != *"usage: verify-egress"* ]]; then
    fail usage "args '$args': $out"
  fi
done
[[ ! -s $FAKE/calls ]] || fail usage "docker was called"
ok usage

exit "$status"
