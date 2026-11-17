#!/usr/bin/env bash
# Self-test of the install entry, egress-install, and the installer, install.sh (CI `lint`
# job): runs the unmodified scripts, and the start.sh the installer installs, against a
# fake `docker` and `gh` (and fake `chmod`, `mv` and `sleep` that only add the hooks the kill
# tests need) on PATH, so no Docker daemon, registry or credential is ever reached:
# DOCKER_HOST points at a socket that does not exist.
# Prints `ok <case>` or `FAIL <case>: <detail>`; exits 1 if any case fails.
set -euo pipefail
# Byte order for sort, on macOS too.
export LC_ALL=C
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
export FAKE=$work/fake
# The fake proxy's default rules report.
export RULES=$'network workers (fake report)\n    0.0.0.0/8'
mkdir -p "$work/bin" "$work/fast" "$DOCKER_CONFIG" "$FAKE"
mkfifo "$FAKE/hold"
REAL_CP=$(command -v cp)
REAL_CHMOD=$(command -v chmod)
REAL_MV=$(command -v mv)
export REAL_CP REAL_CHMOD REAL_MV

# The fake docker. State and scenario live in $FAKE:
#   calls          every call, with the EGRESS_IMAGE it saw
#   label          the image's org.opencontainers.image.version label (none: <no value>)
#   contract       the image's io.windroc.egress-proxy.contract label (default 1)
#   label.<digest>, health.<digest>, up_fails.<digest>, egress.<digest>/
#                  label, health, up_fails and egress/ for the image of that digest only
#   running        the image `compose up` last started (what inspect reports)
#   health         the container's health (default healthy)
#   created        the image of the last `docker create`
#   images         the image IDs `docker images` lists, one per line (an image's ID is
#                  sha256:id-<its reference>); `image rm` removes one from it
#   rm_fails       image IDs `image rm` refuses (in use by a container)
#   logs           what `docker logs` prints
#   run_state, run_health, run_contract
#                  what the running-proxy check sees of the container: running (default
#                  true), health (default: health's), windroc.egress.contract (default 1)
#   run_label, run_repodigests
#                  the running container image's version label (default <no value>) and
#                  its RepoDigests, space-separated (default none)
#   up_fails       `compose up` fails
#   block_start    start.sh's first docker call blocks on the hold fifo
#   image_missing  `image inspect` of the image fails, until a pull succeeds
#   pull_err       the pull fails with this error; pull_config, helper_out and
#                  token_files record its client config, what the credential helper
#                  answered and the files under TMPDIR holding the token
#   egress/        the image's /egress, as `docker cp` copies it
#   daemon_down    `docker version` fails (no daemon)
#   cp_fails       `docker cp` fails
#   rules          what `proxy rules` prints (default: RULES below)
#   rules_fail     `proxy rules` fails as a proxy that has not started does
#   rules_block    `proxy rules` blocks on the hold fifo
#   legacy.<name>  what `docker images <name>` lists for a locally built image name
#                  (egress-proxy, egress-proxy-proxy, egress-gateway): `<repo:tag> <id>`
#                  lines; `image rm` of either removes the line
#   in_use         image references a container uses: `ps --filter ancestor=` lists one
#                  (`rm -f`, the container's removal, removes running)
#   hosts          every call's DOCKER_HOST|DOCKER_CONTEXT
#   render/        what start.sh copied into its render container (a remote install);
#                  `start -a` of it prints the override, or fails when its config holds BAD
#   volume/        the volume egress-config, as start.sh's helper container filled it
#   platform       the daemon's Server.Os/Server.Arch (default linux/amd64)
#   loaded/        the archive the last `docker load -i` read; load_id the image ID it
#                  gave its tag (its config digest), which `image inspect {{.Id}}` reports;
#                  load_fails makes the load fail
cat >"$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "EGRESS_IMAGE=${EGRESS_IMAGE:-} $*" >>"$FAKE/calls"
echo "${DOCKER_HOST:-}|${DOCKER_CONTEXT:-}" >>"$FAKE/hosts"
block() {
  : >"$FAKE/blocked"
  read -r _ <"$FAKE/hold" || true
  exit 1
}
# or <name> <default>: the scenario file $FAKE/<name>, else <default>.
or() { cat "$FAKE/$1" 2>/dev/null || echo "$2"; }
# of <name> <image>: the scenario file name for <image>: <name>.<digest> if it exists. A
# remote install names the image <repo>:sha256-<hex>.
of() {
  local d=${2##*@}
  [[ $2 != *:sha256-* ]] || d=sha256:${2##*:sha256-}
  if [[ -e $FAKE/$1.$d ]]; then echo "$1.$d"; else echo "$1"; fi
}
case $1 in
  images)
    case ${!#} in
      egress-proxy | egress-proxy-proxy | egress-gateway) or "legacy.${!#}" "" ;;
      *) or images "" ;;
    esac
    ;;
  rm) [[ " $* " == *" rcid "* || " $* " == *" hcid "* ]] || rm -f "$FAKE/running" ;;
  ps)
    if grep -qxF "${!##ancestor=}" "$FAKE/in_use" 2>/dev/null; then echo cid; fi
    ;;
  image)
    [[ ! -f $FAKE/image_missing ]] || exit 1
    if [[ $2 == rm ]]; then
      ! grep -qxF "$3" "$FAKE/rm_fails" 2>/dev/null || exit 1
      grep -vxF "$3" "$FAKE/images" >"$FAKE/images.new" || true
      "$REAL_MV" "$FAKE/images.new" "$FAKE/images"
      for f in "$FAKE"/legacy.*; do
        [[ -f $f ]] || continue
        awk -v r="$3" '$1 != r && $2 != r' "$f" >"$f.new"
        "$REAL_MV" "$f.new" "$f"
      done
    elif [[ $3 == --format ]]; then
      case $4 in
        '{{.Id}}') if [[ -f $FAKE/load_id ]]; then cat "$FAKE/load_id"; else echo "sha256:id-$5"; fi ;;
        # The running proxy's image (`inspect`'s ID below).
        *RepoDigests*) printf '%s|%s\n' "$(or run_label "<no value>")" "$(or run_repodigests "")" ;;
        *egress-proxy.contract*) printf '%s|%s\n' "$(or "$(of label "$5")" "<no value>")" "$(or contract 1)" ;;
        *) or "$(of label "$5")" "<no value>" ;;
      esac
    elif [[ -f $FAKE/block_start ]]; then
      block
    fi
    ;;
  inspect)
    [[ -f $FAKE/running ]] || exit 1
    if [[ $3 == '{{.Image}}'* ]]; then
      # The running-proxy check: its image ID, state, health and contract label.
      printf 'sha256:id-%s|%s|%s|%s\n' "$(cat "$FAKE/running")" "$(or run_state true)" \
        "$(or run_health "$(or health healthy)")" "$(or run_contract 1)"
      exit 0
    fi
    printf '%s\n%s\n' "$(or "$(of health "$(cat "$FAKE/running")")" healthy)" "$(cat "$FAKE/running")"
    printf '%s\n' windroc.egress.contract=1 windroc.egress.networks=workers \
      windroc.egress.network.workers.name=egress-workers \
      windroc.egress.network.workers.proxy=http://egress-proxy-workers:4750
    ;;
  run)
    printf 'services:\n  proxy:\n    networks:\n      workers: {}\nnetworks:\n  workers:\n    name: "egress-workers"\n    external: true\n'
    ;;
  network)
    if [[ $2 == inspect ]]; then
      if [[ $4 == *EnableIPv6* ]]; then echo "false false"; else echo true; fi
    fi
    ;;
  pull)
    rm -rf "$FAKE/pull_config"
    "$REAL_CP" -R "$DOCKER_CONFIG" "$FAKE/pull_config"
    if grep -qF '"credHelpers":{"ghcr.io":"egress-gh"}' "$DOCKER_CONFIG/config.json"; then
      echo ghcr.io | docker-credential-egress-gh get >"$FAKE/helper_out"
    fi
    grep -rlF "$FAKE_TOKEN" "$TMPDIR" >"$FAKE/token_files" 2>/dev/null || true
    if [[ -f $FAKE/pull_err ]]; then
      cat "$FAKE/pull_err" >&2
      exit 1
    fi
    rm -f "$FAKE/image_missing"
    echo "$3"
    ;;
  version)
    [[ ! -f $FAKE/daemon_down ]] || exit 1
    [[ $* != *Server.Os* ]] || or platform linux/amd64
    ;;
  load)
    if [[ -f $FAKE/load_fails ]]; then
      echo "Error response from daemon: no space left on device" >&2
      exit 1
    fi
    rm -rf "${FAKE:?}/loaded"
    mkdir -p "$FAKE/loaded"
    tar -xf "${!#}" -C "$FAKE/loaded"
    sed -E 's/.*"Config": *"blobs\/sha256\/([0-9a-f]{64})".*/sha256:\1/' "$FAKE/loaded/manifest.json" >"$FAKE/load_id"
    rm -f "$FAKE/image_missing"
    ;;
  create)
    if [[ ${!#} == compose ]]; then
      echo rcid
    elif [[ " $* " == *" -v egress-config:/etc/egress "* ]]; then
      echo hcid
    else
      echo "$4" >"$FAKE/created"
      echo cid1
    fi
    ;;
  start)
    if grep -q BAD "$FAKE/render/config.local.yaml" 2>/dev/null; then
      echo "proxy: config /etc/egress/config.local.yaml: network workers: BAD" >&2
      exit 2
    fi
    printf 'services:\n  proxy:\n    networks:\n      workers: {}\nnetworks:\n  workers:\n    name: "egress-workers"\n    external: true\n'
    ;;
  volume) ;;
  logs) or logs "" ;;
  cp)
    case $3 in
      rcid:* | hcid:*)
        d=$FAKE/volume
        [[ $3 != rcid:* ]] || d=$FAKE/render
        rm -rf "${d:?}"
        mkdir -p "$d"
        "$REAL_CP" -R "${2%/.}/." "$d"
        exit 0
        ;;
    esac
    if [[ -f $FAKE/cp_fails ]]; then
      echo "Error response from daemon: write $3/install.sh: no space left on device" >&2
      exit 1
    fi
    "$REAL_CP" -R "$FAKE/$(of egress "$(cat "$FAKE/created")")/." "$3"
    ;;
  context) echo my-context ;;
  compose)
    if [[ " $* " == *" up "* ]]; then
      [[ ! -f $FAKE/$(of up_fails "$EGRESS_IMAGE") ]] || exit 1
      echo "$EGRESS_IMAGE" >"$FAKE/running"
    elif [[ " $* " == *" /proxy rules "* ]]; then
      [[ ! -f $FAKE/rules_block ]] || block
      if [[ -f $FAKE/rules_fail ]]; then
        echo "proxy: not started: x" >&2
        exit 1
      fi
      if [[ -f $FAKE/rules ]]; then cat "$FAKE/rules"; else printf '%s\n' "$RULES"; fi
    fi
    ;;
esac
exit 0
FAKE
# chmod and mv: the real ones, unless the scenario blocks them (block_chmod: every chmod,
# which the installer runs while it writes the new runtime set;
# block_mv: the rename of the new state/runtime link).
cat >"$work/bin/chmod" <<'FAKE'
#!/usr/bin/env bash
if [[ -f $FAKE/block_chmod ]]; then
  : >"$FAKE/blocked"
  read -r _ <"$FAKE/hold" || true
  exit 1
fi
exec "$REAL_CHMOD" "$@"
FAKE
cat >"$work/bin/mv" <<'FAKE'
#!/usr/bin/env bash
if [[ -f $FAKE/block_mv && $* == *.runtime.tmp.* ]]; then
  : >"$FAKE/blocked"
  read -r _ <"$FAKE/hold" || true
  exit 1
fi
exec "$REAL_MV" "$@"
FAKE
# The fake gh: logged in to github.com, unless gh_logged_out; gh_calls logs every call.
export FAKE_TOKEN=gho_SELFTESTselftestSELFTESTselftest0123
cat >"$work/bin/gh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE/gh_calls"
[[ ! -f $FAKE/gh_logged_out ]] || exit 1
case "$1 $2" in
  "auth token") printf '%s\n' "$FAKE_TOKEN" ;;
  "api user") echo octo ;;
esac
FAKE
chmod +x "$work/bin/gh"
# The installer's health wait polls 60 times, 2 s apart: no waiting here.
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/fast/sleep"
chmod +x "$work/bin/docker" "$work/bin/chmod" "$work/bin/mv" "$work/fast/sleep"

# The image's /egress, as egress-install copies it out.
files=$work/files
mkdir -p "$files"
for f in start.sh verify-egress compose.yaml compose.remote.yaml config.example.yaml config.default.yaml install.sh egress-install; do
  if [[ -f $repo/$f ]]; then
    "$REAL_CP" -p "$repo/$f" "$files/$f"
  else
    printf '#!/usr/bin/env bash\nexit 0\n' >"$files/$f"
  fi
done

REPO=ghcr.io/windroc/egress-proxy
# digest <char>: a digest of 64 times <char>.
digest() { printf 'sha256:%s' "$(printf "%064d" 0 | tr 0 "$1")"; }
image() { echo "$REPO@$(digest "$1")"; }

dir=""
rc=0
# install <version> <digest char> [args...]: runs install.sh into $dir; output in
# $work/out, exit code in $rc.
install() {
  echo "$1" >"$FAKE/label"
  rc=0
  PATH="$work/fast:$work/bin:$PATH" bash "$files/install.sh" --interface 1 --version "$1" \
    --digest "$(digest "$2")" --dir "$dir" --image "$(image "$2")" --files "$files" "${@:3}" \
    >"$work/out" 2>&1 || rc=$?
}
# install_killed <version> <digest char>: starts install.sh in the background (its own
# process, so $! is the installer), waits until a fake tool blocks it, SIGKILLs it, then
# releases the blocked tool. Sets $rc to 0 if the installer reached the block.
install_killed() {
  local pid i
  echo "$1" >"$FAKE/label"
  rm -f "$FAKE/blocked"
  PATH="$work/fast:$work/bin:$PATH" bash "$files/install.sh" --interface 1 --version "$1" \
    --digest "$(digest "$2")" --dir "$dir" --image "$(image "$2")" --files "$files" \
    >"$work/out" 2>&1 &
  pid=$!
  for ((i = 0; i < 100; i++)); do
    [[ -f $FAKE/blocked ]] && break
    sleep 0.1
  done
  kill -9 "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$FAKE"/block_*
  rc=1
  if [[ -f $FAKE/blocked ]]; then
    rc=0
    echo >"$FAKE/hold"
    # Let the released tool exit before anything is checked.
    sleep 0.3
  fi
}
fresh() {
  dir=$work/egress-$1
  rm -f "$FAKE/running" "$FAKE/health" "$FAKE/up_fails" "$FAKE/calls" "$FAKE/contract" "$FAKE"/run_* \
    "$FAKE"/label.* "$FAKE"/health.* "$FAKE"/up_fails.* "$FAKE/logs" "$FAKE/images" "$FAKE/rm_fails" \
    "$FAKE"/legacy.* "$FAKE/in_use" "$FAKE/old_start" "$FAKE/old_start_rc" "$FAKE/old_start_image"
  rm -rf "${FAKE:?}"/egress.* "${FAKE:?}/render" "${FAKE:?}/volume"
  rm -f "${FAKE:?}/hosts"
}
out() { cat "$work/out"; }
tree() { (cd "$dir" && find . -exec ls -ld {} + | sort) 2>/dev/null || true; }
record() { sed -n "s/^$1=//p" "$dir/state/installed"; }
# val <file>: a runtime set data file's values, its lines not starting with #.
val() { sed '/^#/d' "$1"; }
sets() { find "$dir/state" -maxdepth 1 -type d -name 'runtime.*' | wc -l | tr -d ' '; }
sha() { cksum <"$1"; }
LINKS="README.md start.sh verify-egress config.example.yaml"

# check <case> <detail> <status>: ok when <status> is 0, else FAIL with <detail>.
check() {
  if (($3 == 0)); then ok "$1"; else fail "$1" "$2"; fi
}
# st <test...>: the status of a test command, without tripping set -e.
st() {
  local s=0
  "$@" || s=$?
  echo "$s"
}
is() { [[ $1 == "$2" ]]; }
like() { [[ $1 == *"$2"* ]]; }
gone() { [[ ! -e $1 ]]; }

# -------- Exit codes --------
# install.sh's header and README.md's Setup table list the same codes in the same words.
# header_codes: the header's list, one `<code> <text>` line per code, continuations joined.
header_codes() {
  awk '/^# Exit codes/ { on = 1; next }
    !on { next }
    /^#   [0-9]/ {
      if (n++) print line
      sub(/^# +/, "")
      code = $1
      sub(/^[0-9]+ +/, "")
      line = code " " $0
      next
    }
    n && /^#       / { sub(/^# +/, ""); line = line " " $0; next }
    n { exit }
    END { if (n) print line }' "$repo/install.sh"
}
# readme_codes: README.md's exit-code table, one `<code> <text>` line per row.
readme_codes() {
  awk '/^\| Exit code \| Meaning \|$/ { on = 1; next }
    on && !/^\|/ { exit }
    on && /^\| [0-9]/ {
      sub(/^\| /, "")
      sub(/ \|$/, "")
      code = $1
      sub(/^[0-9]+ \| /, "")
      print code " " $0
    }' "$repo/README.md"
}
h=$(header_codes) r=$(readme_codes)
got="$(cut -d' ' -f1 <<<"$h" | xargs) | $(cut -d' ' -f1 <<<"$r" | xargs)"
check exit_codes_match "codes: $got; diff: $(diff <(echo "$h") <(echo "$r") || true)" \
  "$(st is "$got:$h" "0 1 2 3 4 5 6 7 8 9 10 11 | 0 1 2 3 4 5 6 7 8 9 10 11:$r")"

# -------- Arguments --------
fresh usage
rc=0
PATH="$work/fast:$work/bin:$PATH" bash "$files/install.sh" >"$work/out" 2>&1 || rc=$?
check usage "exit $rc: $(out)" "$(st is "$rc:$(gone "$dir" && echo gone)" "2:gone")"
like "$(out)" "usage: install.sh --interface 1 " || fail usage "$(out)"

install 1.0.0 a --interface 2
check interface_unknown "exit $rc: $(out)" \
  "$(st like "$rc $(out) $(gone "$dir" && echo gone)" "8 install.sh: interface 2 is not supported (supported: 1)")"
gone "$dir" || fail interface_unknown "$dir was created"

echo 9.9.9 >"$FAKE/label"
rc=0
PATH="$work/fast:$work/bin:$PATH" bash "$files/install.sh" --interface 1 --version 1.0.0 --digest "$(digest a)" \
  --dir "$dir" --image "$(image a)" --files "$files" >"$work/out" 2>&1 || rc=$?
check wrong_version "exit $rc: $(out)" "$(st like "$rc $(out)" "5 install.sh: $(image a) is version 9.9.9, not 1.0.0")"
gone "$dir" || fail wrong_version "$dir was created"

# -------- First install --------
fresh first
install 1.0.0 a --future-option x
check first_install "exit $rc: $(out)" "$rc"
check option_unknown "$(out)" "$(st like "$(out)" "ignoring unknown option --future-option")"
check installed_message "$(out)" \
  "$(st like "$(out)" "egress-proxy 1.0.0 ($(digest a)) installed in $dir; start command: $dir/start.sh")"

bad=""
got=$(cd "$dir" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort | xargs)
is "$got" "README.md config.example.yaml config.local.yaml effective-policy.txt start.sh state verify-egress" || bad+="top level: $got; "
got=$(cd "$dir/state" && find . -mindepth 1 -maxdepth 1 | sed -e 's|^\./||' -e 's/^runtime\..*/runtime.X/' | sort | xargs)
is "$got" "compose.networks.yaml installed runtime runtime.X" || bad+="state: $got; "
for f in $LINKS; do
  is "$(readlink "$dir/$f")" "state/runtime/$f" || bad+="$f is not a link into state/runtime; "
done
got=$(find "$dir" \( -name '*.rs' -o -name Dockerfile -o -name Cargo.toml -o -name tests -o -name proxy -o -name .github \) -print)
is "$got" "" || bad+="source files: $got"
check layout "$bad" "$(st is "$bad" "")"

got="$(record format) $(record current_version) $(record current_digest) $(record current_image) $(record current_runtime) [$(record previous_digest)]"
check state_record "$(cat "$dir/state/installed")" \
  "$(st is "$got" "1 1.0.0 $(digest a) $(image a) $(readlink "$dir/state/runtime") []")"
check runs_pinned_image "running $(cat "$FAKE/running")" \
  "$(st is "$(val "$dir/state/runtime/image") $(cat "$FAKE/running")" "$(image a) $(image a)")"
check no_build "$(grep -E ' (build|buildx)( |$)| compose .*build' "$FAKE/calls" || true)" \
  "$(st is "$(grep -cE ' (build|buildx)( |$)| compose .*build' "$FAKE/calls" || true)" 0)"

bad=""
cmp -s "$dir/config.local.yaml" "$repo/config.default.yaml" || bad+="not the default config; "
grep -q effective-policy.txt "$dir/config.local.yaml" || bad+="no effective-policy.txt; "
grep -q config.example.yaml "$dir/config.local.yaml" || bad+="no config.example.yaml; "
check default_config "$bad" "$(st is "$bad" "")"

# Headers: what it is, who generated it, do not edit, edit config.local.yaml instead.
bad=""
for f in README.md start.sh verify-egress config.example.yaml state/runtime/compose.yaml state/runtime/config.default.yaml \
  state/runtime/egress-install state/runtime/install.sh state/installed state/compose.networks.yaml \
  effective-policy.txt state/runtime/links state/runtime/image state/runtime/version state/runtime/digest; do
  head=$(sed -n '1,8p' "$dir/$f")
  for want in "$dir/$f: " "enerated by" "do not edit" "config.local.yaml"; do
    like "$head" "$want" || bad+="$f lacks '$want'; "
  done
done
for f in start.sh verify-egress state/runtime/egress-install state/runtime/install.sh; do
  is "$(sed -n 1p "$dir/$f")" '#!/usr/bin/env bash' || bad+="$f: the #! line is not first; "
done
like "$(sed -n 1p "$dir/README.md")" "<!-- " || bad+="README.md does not start with an HTML comment; "
got="$(val "$dir/state/runtime/links" | xargs) | $(val "$dir/state/runtime/image") $(val "$dir/state/runtime/version") $(val "$dir/state/runtime/digest")"
is "$got" "$LINKS | $(image a) 1.0.0 $(digest a)" || bad+="data file values: $got"
check headers "$bad" "$(st is "$bad" "")"
check readme_version "$(head -5 "$dir/README.md")" \
  "$(st grep -qF "egress-proxy 1.0.0, image \`$(image a)\`" "$dir/README.md")"
# The reinstall row names the outcomes besides an install: keep-newer (FR-12), rollback (FR-9).
row=$(grep -F '| Reinstall, or install another version' "$dir/README.md" || true)
want="exit 0 also when it keeps a newer, healthy running proxy instead of downgrading;"
want+=" exit 11 when the new version did not start or was not healthy and it rolled back to the previous one"
check readme_outcomes "$row" "$(st like "$row" "$want")"

# -------- The rules in effect (FR-17, FR-18) --------
rules=$dir/effective-policy.txt
# rules_body: the rules file past its 4-line header and the empty line after it.
rules_body() { tail -n +6 "$rules"; }
time_re='^# Generated by start\.sh at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z for '
bad=""
like "$(out)" "$RULES" || bad+="the install did not print the rules; "
like "$(out)" "start.sh: the rules in effect are also in $rules" || bad+="no pointer to $rules; "
is "$(sed -n 1p "$rules")" "# $rules: the rules in effect for each caller network." || bad+="line 1: $(sed -n 1p "$rules"); "
[[ $(sed -n 2p "$rules") =~ $time_re ]] || bad+="line 2: $(sed -n 2p "$rules"); "
like "$(sed -n 2p "$rules")" "for egress-proxy 1.0.0 (image $(image a));" || bad+="line 2: $(sed -n 2p "$rules"); "
like "$(sed -n 4p "$rules")" "$dir/config.local.yaml, then run $dir/start.sh." || bad+="line 4: $(sed -n 4p "$rules"); "
is "$(sed -n 5p "$rules")" "" || bad+="line 5 is not empty; "
is "$(rules_body)" "$RULES" || bad+="body: $(rules_body); "
check rules_file "$bad" "$(st is "$bad" "")"

printf 'network workers (changed)\n' >"$FAKE/rules"
rc=0
PATH="$work/bin:$PATH" "$dir/start.sh" >"$work/out" 2>&1 || rc=$?
rm -f "$FAKE/rules"
bad=""
is "$rc" 0 || bad+="exit $rc: $(out); "
is "$(rules_body)" "network workers (changed)" || bad+="body: $(rules_body); "
is "$(find "$dir" -name '.effective-policy.txt.*')" "" || bad+="temp files left; "
check rules_rewritten "$bad" "$(st is "$bad" "")"

# An image without a version label (a checkout build) reads as a development build.
mv "$FAKE/label" "$work/label.saved"
rc=0
PATH="$work/bin:$PATH" "$dir/start.sh" >"$work/out" 2>&1 || rc=$?
mv "$work/label.saved" "$FAKE/label"
check rules_no_version "exit $rc: $(sed -n 2p "$rules")" \
  "$(st like "$rc $(sed -n 2p "$rules")" "0 # Generated by start.sh at ")"
like "$(sed -n 2p "$rules")" "for egress-proxy development build (image $(image a));" ||
  fail rules_no_version "$(sed -n 2p "$rules")"

# A start that fails before the proxy runs leaves the rules file as it was.
before=$(sha "$rules")
touch "$FAKE/up_fails"
rc=0
PATH="$work/bin:$PATH" "$dir/start.sh" >"$work/out" 2>&1 || rc=$?
rm -f "$FAKE/up_fails"
check rules_kept_on_failure "exit $rc; $(out)" "$(st is "$((rc != 0)) $(sha "$rules")" "1 $before")"

touch "$FAKE/rules_fail"
: >"$FAKE/calls"
rc=0
PATH="$work/fast:$work/bin:$PATH" "$dir/start.sh" >"$work/out" 2>"$work/err" || rc=$?
rm -f "$FAKE/rules_fail"
bad=""
is "$rc" 0 || bad+="exit $rc: $(cat "$work/err"); "
like "$(cat "$work/err")" "start.sh: the proxy did not report its rules within 30 s (not started: x); see docker logs egress-proxy" ||
  bad+="stderr: $(cat "$work/err"); "
is "$(rules_body)" "No rules reported within 30 s of this start: not started: x. See docker logs egress-proxy, then run start.sh again." ||
  bad+="body: $(rules_body); "
[[ $(sed -n 2p "$rules") =~ $time_re ]] || bad+="line 2: $(sed -n 2p "$rules"); "
is "$(grep -c '/proxy rules' "$FAKE/calls" || true)" 30 || bad+="$(grep -c '/proxy rules' "$FAKE/calls" || true) tries, want 30; "
check rules_unavailable "$bad" "$(st is "$bad" "")"

# A start killed while it waits for the rules (no EXIT trap runs) leaves its temp file in
# state/, not in the top level (FR-15).
touch "$FAKE/rules_block"
rm -f "$FAKE/blocked"
PATH="$work/bin:$PATH" "$dir/start.sh" >"$work/out" 2>&1 &
pid=$!
for ((i = 0; i < 100; i++)); do
  [[ -f $FAKE/blocked ]] && break
  sleep 0.1
done
kill -9 "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
rm -f "$FAKE/rules_block"
bad=""
if [[ -f $FAKE/blocked ]]; then
  echo >"$FAKE/hold"
  sleep 0.3
else
  bad+="start.sh never asked for the rules: $(out); "
fi
top_level=$( (cd "$dir" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort | xargs))
is "$top_level" "README.md config.example.yaml config.local.yaml effective-policy.txt start.sh state verify-egress" ||
  bad+="top level: $top_level; "
is "$(find "$dir/state" -maxdepth 1 -name '.effective-policy.txt.*' | wc -l | tr -d ' ')" 1 ||
  bad+="state/: $( (cd "$dir/state" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort | xargs)); "
check rules_killed "$bad" "$(st is "$bad" "")"
rm -f "$dir"/.effective-policy.txt.* "$dir/state"/.effective-policy.txt.* "$dir/state"/.rules.err.*

# An existing install is left as it was by a refused argument or image.
before=$(tree)
install 1.1.0 b --interface 2
is "$rc $(tree)" "8 $before" || fail interface_unknown "exit $rc; on an existing install: $(out)"
echo 9.9.9 >"$FAKE/label"
rc=0
PATH="$work/fast:$work/bin:$PATH" bash "$files/install.sh" --interface 1 --version 1.1.0 --digest "$(digest b)" \
  --dir "$dir" --image "$(image b)" --files "$files" >"$work/out" 2>&1 || rc=$?
is "$rc $(tree)" "5 $before" || fail wrong_version "exit $rc; on an existing install: $(out)"

# -------- Upgrade, reinstall --------
printf '\n# my edit\n' >>"$dir/config.local.yaml"
before=$(sha "$dir/config.local.yaml")
install 1.1.0 b
check config_kept "exit $rc: $(out)" "$(st is "$rc $(sha "$dir/config.local.yaml")" "0 $before")"
check readme_rewritten "$(head -5 "$dir/README.md")" \
  "$(st is "$(grep -cF "egress-proxy 1.1.0, image \`$(image b)\`" "$dir/README.md") $(grep -cF "$(digest a)" "$dir/README.md")" "1 0")"
check upgrade_record "sets $(sets): $(cat "$dir/state/installed")" \
  "$(st is "$(record current_version) $(record previous_version) $(record previous_digest) $(sets)" "1.1.0 1.0.0 $(digest a) 2")"
install 1.1.0 b
check reinstall_keeps_previous "exit $rc, sets $(sets): $(cat "$dir/state/installed")" \
  "$(st is "$rc $(record current_version) $(record previous_version) $(sets)" "0 1.1.0 1.0.0 2")"
install 1.2.0 c
bad=""
is "$rc $(record previous_version) $(sets)" "0 1.1.0 2" || bad+="exit $rc, sets $(sets): $(cat "$dir/state/installed"); "
[[ -d $dir/state/$(record previous_runtime) && -d $dir/state/$(record current_runtime) ]] || bad+="a recorded set is gone"
check old_sets_pruned "$bad" "$(st is "$bad" "")"

# -------- Old images (FR-10) --------
# images_left: the fake's image IDs, as the references they stand for.
images_left() { sed 's/^sha256:id-//' "$FAKE/images" | sort -u | xargs; }
fresh cleanup
install 1.0.0 a
install 1.1.0 b
# A third version, a local build tagged into the repo, and the new one.
printf 'sha256:id-%s\n' "$(image a)" "$(image b)" "$REPO:9.9.9" "$(image b)" "$(image c)" >"$FAKE/images"
: >"$FAKE/calls"
install 1.2.0 c
bad=""
is "$rc" 0 || bad+="exit $rc; "
is "$(images_left)" "$(image b) $(image c)" || bad+="left: $(images_left); "
like "$(out)" "install.sh: removed 2 old egress-proxy image(s)" || bad+="no removed line; "
grep -qF " images --no-trunc --format {{.ID}} $REPO" "$FAKE/calls" || bad+="docker images not by repo: $(grep ' images ' "$FAKE/calls" || true); "
grep -q ' image rm -f' "$FAKE/calls" && bad+="forced removal; "
for d in versions current; do [[ -e $dir/$d || -L $dir/$d ]] && bad+="$dir/$d exists; "; done
check cleanup "$bad: $(out)" "$(st is "$bad" "")"

# An image a container uses (or another repo references) stays; the install succeeds.
fresh cleanup_rm_fails
install 1.0.0 a
install 1.1.0 b
printf 'sha256:id-%s\n' "$(image a)" "$(image b)" "$(image c)" >"$FAKE/images"
echo "sha256:id-$(image a)" >"$FAKE/rm_fails"
install 1.2.0 c
check cleanup_rm_fails "exit $rc, left $(images_left): $(out)" \
  "$(st is "$rc $(images_left) $(grep -c 'old egress-proxy image' "$work/out" || true)" "0 $(image a) $(image b) $(image c) 0")"

# -------- Failures and the rollback (FR-9, NFR-6) --------
# old_image <digest char> <version> [<files dir>]: the image of that digest is version
# <version>, and ships <files dir> (default: this repo's) as its /egress.
old_image() {
  echo "$2" >"$FAKE/label.$(digest "$1")"
  mkdir -p "$FAKE/egress.$(digest "$1")"
  "$REAL_CP" -R "${3:-$files}/." "$FAKE/egress.$(digest "$1")"
}
LOGS_HEAD="install.sh: the last 20 lines of docker logs egress-proxy:"
# rolled_back <case> <code> <failed version> <its digest char> <cause line> <previous version> <its digest char>
# With no $FAKE/logs the proxy printed nothing (it never started): no log lines either.
rolled_back() {
  local bad=""
  is "$rc" "$2" || bad+="exit $rc; "
  grep -qxF "$5" "$work/out" || bad+="no cause line; "
  if [[ -e $FAKE/logs ]]; then
    like "$(out)" "$LOGS_HEAD"$'\nproxy: no route' || bad+="no log lines; "
  else
    like "$(out)" "$LOGS_HEAD" && bad+="log lines of a proxy that never started; "
  fi
  is "$(tail -n 1 "$work/out")" "install.sh: rolled back to egress-proxy $6 ($(digest "$7")), which is healthy; egress-proxy $3 was not installed; see docker logs egress-proxy" ||
    bad+="last line: $(tail -n 1 "$work/out"); "
  is "$(cat "$FAKE/running") $(record current_version) $(record current_digest) $(val "$dir/state/runtime/version")" \
    "$(image "$7") $6 $(digest "$7") $6" || bad+="running $(cat "$FAKE/running"), active $(val "$dir/state/runtime/version"): $(cat "$dir/state/installed"); "
  # The previous version's installer pruned the failed version's runtime set.
  is "$(grep -lx "$3" "$dir"/state/runtime.*/version || true)" "" || bad+="the $3 runtime set is left; "
  check "$1" "$bad: $(out)" "$(st is "$bad" "")"
}

# The install above: 1.2.0 (digest c) current, 1.1.0 previous.
old_image c 1.2.0
echo "proxy: no route" >"$FAKE/logs"
echo starting >"$FAKE/health.$(digest d)"
printf 'sha256:id-%s\n' "$(image a)" "$(image b)" "$(image c)" "$(image d)" >"$FAKE/images"
: >"$FAKE/calls"
install 1.3.0 d
grep -E ' images | image rm ' "$FAKE/calls" && fail rollback_no_cleanup "a rollback removed images"
rolled_back rollback 11 1.3.0 d \
  "install.sh: egress-proxy 1.3.0 ($(digest d)) did not become healthy within 120 s; see docker logs egress-proxy" 1.2.0 c
is "$(record previous_version)" 1.1.0 || fail rollback "previous: $(record previous_version)"
grep -qF "for egress-proxy 1.2.0 (image $(image c));" "$dir/effective-policy.txt" ||
  fail rollback "the rules file is not 1.2.0's: $(sed -n 2p "$dir/effective-policy.txt")"
rm -f "$FAKE/health.$(digest d)"

touch "$FAKE/up_fails.$(digest d)"
install 1.3.0 d
rolled_back rollback_start_fails 11 1.3.0 d \
  "install.sh: the start command failed (exit 1) for egress-proxy 1.3.0 ($(digest d)); see docker logs egress-proxy" 1.2.0 c
rm -f "$FAKE/logs"
install 1.3.0 d
rolled_back rollback_never_started 11 1.3.0 d \
  "install.sh: the start command failed (exit 1) for egress-proxy 1.3.0 ($(digest d)); see docker logs egress-proxy" 1.2.0 c
echo "proxy: no route" >"$FAKE/logs"
rm -f "$FAKE/up_fails.$(digest d)"

# no_rollback <case> <code> <message>: exit <code> with <message>, no rollback.
no_rollback() {
  local bad=""
  is "$rc" "$2" || bad+="exit $rc; "
  like "$(out)" "$3" || bad+="no '$3'; "
  like "$(out)" "rolling back" && bad+="it rolled back; "
  check "$1" "$bad: $(out)" "$(st is "$bad" "")"
}
fresh not_healthy_first_install
echo starting >"$FAKE/health"
install 1.0.0 a
no_rollback not_healthy_first_install 6 \
  "install.sh: egress-proxy 1.0.0 ($(digest a)) did not become healthy within 120 s; see docker logs egress-proxy"

fresh start_fails_first_install
touch "$FAKE/up_fails"
install 1.0.0 a
no_rollback start_fails_first_install 7 \
  "install.sh: the start command failed (exit 1) for egress-proxy 1.0.0 ($(digest a)); see docker logs egress-proxy"
like "$(out)" "$LOGS_HEAD" && fail start_fails_first_install "log lines of a proxy that never started: $(out)"

fresh not_healthy_reinstall
install 1.0.0 a
old_image a 1.0.0
echo starting >"$FAKE/health"
install 1.0.0 a
no_rollback not_healthy_reinstall 6 "did not become healthy within 120 s"

fresh rollback_mode
install 1.0.0 a
old_image a 1.0.0
echo starting >"$FAKE/health.$(digest b)"
EGRESS_INSTALL_ROLLBACK=1 install 1.1.0 b
no_rollback rollback_mode 6 "did not become healthy within 120 s"

fresh rollback_fails
install 1.0.0 a
old_image a 1.0.0
echo starting >"$FAKE/health"
install 1.1.0 b
check rollback_fails "exit $rc: $(out)" "$(st is "$rc $(tail -n 1 "$work/out")" \
  "9 install.sh: rolling back to egress-proxy 1.0.0 ($(digest a)) failed (exit 6); see docker logs egress-proxy")"

# NFR-6: version 1.0.0 shipped the S3 installer, interface 1, with no rollback and no
# rules file (S4). A newer installer rolls back through that version's own install entry,
# and leaves no rules file behind that 1.0.0's start.sh would not rewrite.
s3=$work/s3-files
mkdir -p "$s3"
"$REAL_CP" -p "$files"/* "$s3/"
"$REAL_CP" -p "$repo/tests/fixtures/s3-egress/install.sh" "$repo/tests/fixtures/s3-egress/egress-install" \
  "$repo/tests/fixtures/s3-egress/start.sh" "$s3/"
fresh rollback_s3_entry
echo 1.0.0 >"$FAKE/label"
rc=0
PATH="$work/fast:$work/bin:$PATH" bash "$s3/install.sh" --interface 1 --version 1.0.0 --digest "$(digest a)" \
  --dir "$dir" --image "$(image a)" --files "$s3" >"$work/out" 2>&1 || rc=$?
is "$rc" 0 || fail rollback_s3_entry "the S3 install: exit $rc: $(out)"
old_image a 1.0.0 "$s3"
echo "proxy: no route" >"$FAKE/logs"
echo starting >"$FAKE/health.$(digest b)"
install 1.1.0 b
rolled_back rollback_s3_entry 11 1.1.0 b \
  "install.sh: egress-proxy 1.1.0 ($(digest b)) did not become healthy within 120 s; see docker logs egress-proxy" 1.0.0 a
gone "$dir/effective-policy.txt" || fail rollback_s3_entry "1.1.0's rules file is left: $(sed -n 2p "$dir/effective-policy.txt")"
grep -qF "egress-proxy 1.0.0, image" "$dir/README.md" || fail rollback_s3_entry "README.md is not 1.0.0's"

# The previous version's runtime set has no egress-install: the rollback runs this image's
# own, handing it the repo of the recorded image, the previous version, digest and dir.
fb=$work/fallback-files
mkdir -p "$fb"
"$REAL_CP" -p "$files"/* "$fb/"
cat >"$fb/egress-install" <<'ENTRY'
#!/usr/bin/env bash
echo "EGRESS_IMAGE_REPO=$EGRESS_IMAGE_REPO EGRESS_INSTALL_ROLLBACK=$EGRESS_INSTALL_ROLLBACK $*" >"$FAKE/entry_call"
ENTRY
fresh rollback_entry_fallback
rm -f "$FAKE/entry_call"
echo 1.0.0 >"$FAKE/label"
rc=0
PATH="$work/fast:$work/bin:$PATH" bash "$files/install.sh" --interface 1 --version 1.0.0 --digest "$(digest a)" \
  --dir "$dir" --image "localhost:5000/egress-proxy@$(digest a)" --files "$files" >"$work/out" 2>&1 || rc=$?
is "$rc" 0 || fail rollback_entry_fallback "the 1.0.0 install: exit $rc: $(out)"
rm "$dir/state/$(record current_runtime)/egress-install"
echo 1.1.0 >"$FAKE/label"
echo starting >"$FAKE/health.$(digest b)"
rc=0
PATH="$work/fast:$work/bin:$PATH" bash "$fb/install.sh" --interface 1 --version 1.1.0 --digest "$(digest b)" \
  --dir "$dir" --image "$(image b)" --files "$fb" >"$work/out" 2>&1 || rc=$?
check rollback_entry_fallback "exit $rc: $(cat "$FAKE/entry_call" 2>/dev/null): $(out)" "$(st is "$rc $(cat "$FAKE/entry_call" 2>/dev/null)" \
  "11 EGRESS_IMAGE_REPO=localhost:5000/egress-proxy EGRESS_INSTALL_ROLLBACK=1 --version 1.0.0 --digest $(digest a) --dir $dir")"

fresh format
install 1.0.0 a
sed 's/^format=1$/format=2/' "$dir/state/installed" >"$work/record.2"
cp "$work/record.2" "$dir/state/installed"
before=$(tree)
install 1.1.0 b
check format_higher "exit $rc: $(out)" \
  "$(st like "$rc $(out)" "1 install.sh: $dir/state/installed has format 2; this installer knows format 1; nothing was changed")"
is "$(tree)" "$before" || fail format_higher "$dir changed"

fresh no_contract_label_image
echo "<no value>" >"$FAKE/contract"
install 1.0.0 a
check no_contract_label_image "exit $rc: $(out)" \
  "$(st is "$rc $(out)" "5 install.sh: $(image a) has no label contract version (io.windroc.egress-proxy.contract)")"
gone "$dir" || fail no_contract_label_image "$dir was created"

# -------- A running proxy (FR-12) --------
# running_newer <case>: version 1.2.0 (digest c) installed and running, healthy, published:
# its image has the RepoDigest the record names. Then the scenario's tweaks, and an
# install of 1.1.0 (digest b).
running_newer() {
  fresh "$1"
  install 1.2.0 c
  is "$rc" 0 || fail "$1" "the first install: $(out)"
  echo 1.2.0 >"$FAKE/run_label"
  echo "$REPO@$(digest c)" >"$FAKE/run_repodigests"
}
# only_inspected: since $FAKE/calls was emptied, install.sh only inspected.
only_inspected() { is "$(grep -vE '^EGRESS_IMAGE=[^ ]* (image inspect|inspect) ' "$FAKE/calls" || true)" ""; }
# replaced <case>: the install of 1.1.0 replaced the running 1.2.0.
replaced() {
  check "$1" "exit $rc, running $(cat "$FAKE/running"): $(out)" \
    "$(st is "$rc $(cat "$FAKE/running") $(record current_version)" "0 $(image b) 1.1.0")"
}

running_newer keep_newer
before=$(tree)
: >"$FAKE/calls"
install 1.1.0 b
bad=""
is "$rc $(out)" "0 install.sh: kept the running egress-proxy 1.2.0 ($(digest c)), newer than 1.1.0; nothing was changed" ||
  bad+="exit $rc: $(out); "
is "$(tree)" "$before" || bad+="$dir changed; "
is "$(cat "$FAKE/running")" "$(image c)" || bad+="running $(cat "$FAKE/running"); "
only_inspected || bad+="calls: $(cat "$FAKE/calls"); "
check keep_newer "$bad" "$(st is "$bad" "")"

for health in unhealthy starting none; do
  running_newer "newer_unhealthy_$health"
  if [[ $health == none ]]; then : >"$FAKE/run_health"; else echo "$health" >"$FAKE/run_health"; fi
  install 1.1.0 b
  replaced "newer_unhealthy_$health"
done
running_newer newer_stopped
echo false >"$FAKE/run_state"
install 1.1.0 b
replaced newer_stopped

# A local build tagged into the repo: no RepoDigest (classic image store), or one the
# record does not name (containerd image store, or installed from another directory).
running_newer newer_local_build
: >"$FAKE/run_repodigests"
install 1.1.0 b
replaced newer_local_build
running_newer newer_repodigest_not_recorded
echo "$REPO@$(digest f)" >"$FAKE/run_repodigests"
install 1.1.0 b
replaced newer_repodigest_not_recorded
running_newer newer_other_repo
echo "localhost:5000/egress-proxy@$(digest c)" >"$FAKE/run_repodigests"
install 1.1.0 b
replaced newer_other_repo

n=0
for label in "<no value>" 1.2 1.1.0 1.0.9 0.9.9 01.2.0; do
  n=$((n + 1))
  running_newer "newer_label_$n"
  echo "$label" >"$FAKE/run_label"
  install 1.1.0 b
  replaced "newer_label_$n ($label)"
done
# Numeric, not text, order: 1.10.0 is newer than 1.9.0.
running_newer newer_numeric
echo 1.10.0 >"$FAKE/run_label"
install 1.9.0 b
check newer_numeric "exit $rc: $(out)" "$(st like "$rc $(out)" "0 install.sh: kept the running egress-proxy 1.10.0")"

running_newer contract_differs
echo 2 >"$FAKE/run_contract"
before=$(tree)
: >"$FAKE/calls"
install 1.1.0 b
bad=""
is "$rc $(out)" "10 install.sh: the running egress-proxy 1.2.0 serves label contract 2, and egress-proxy 1.1.0 serves contract 1; nothing was changed (to replace it: docker rm -f egress-proxy, then install again)" ||
  bad+="exit $rc: $(out); "
is "$(tree)" "$before" || bad+="$dir changed; "
only_inspected || bad+="calls: $(cat "$FAKE/calls"); "
check contract_differs "$bad" "$(st is "$bad" "")"
# Whatever its health or version.
running_newer contract_differs_unhealthy
echo 2 >"$FAKE/run_contract"
echo unhealthy >"$FAKE/run_health"
echo "<no value>" >"$FAKE/run_label"
install 1.1.0 b
check contract_differs_unhealthy "exit $rc: $(out)" \
  "$(st like "$rc $(out)" "10 install.sh: the running egress-proxy unknown version serves label contract 2")"

running_newer no_contract_label
echo "<no value>" >"$FAKE/run_contract"
install 1.1.0 b
replaced no_contract_label

# A rollback (EGRESS_INSTALL_ROLLBACK=1) installs what it is told, newer proxy or not.
running_newer rollback_mode_no_keep
EGRESS_INSTALL_ROLLBACK=1 install 1.1.0 b
replaced rollback_mode_no_keep

# -------- Killed installs (FR-8) --------
# complete_set <case> <versions...>: every top-level runtime file resolves into the one
# active, complete runtime set, of one of <versions>, and start.sh runs its image. Prints
# what is wrong, nothing when it holds.
complete_set() {
  local v f
  if [[ ! -f $dir/state/runtime/digest ]]; then
    echo "the active set is incomplete"
    return
  fi
  v=$(val "$dir/state/runtime/version")
  like " $* " " $v " || echo "active version $v"
  for f in $LINKS; do
    [[ -f $dir/$f && $(readlink "$dir/$f") == "state/runtime/$f" ]] || echo "$f does not resolve into state/runtime"
  done
  grep -qF "egress-proxy $v, image" "$dir/README.md" || echo "README.md is not version $v's"
  grep -qF "for version $v " "$dir/start.sh" || echo "start.sh is not version $v's"
  rm -f "$FAKE/running"
  if ! PATH="$work/bin:$PATH" "$dir/start.sh" >"$work/start.out" 2>&1; then
    echo "start.sh failed: $(cat "$work/start.out")"
  elif ! is "$(cat "$FAKE/running")" "$(val "$dir/state/runtime/image")"; then
    echo "start.sh ran $(cat "$FAKE/running")"
  fi
}
# killed <case> <block>: on a version 1.0.0 install, an install of 1.1.0 is killed where
# <block> holds it; then the set is checked and 1.1.0 installed again.
killed() {
  local bad=""
  fresh "$1"
  install 1.0.0 a
  is "$rc" 0 || bad+="first install: $(out); "
  touch "$FAKE/$2"
  install_killed 1.1.0 b
  is "$rc" 0 || bad+="the install never reached the block; "
  bad+=$(complete_set 1.0.0 1.1.0)
  install 1.1.0 b
  is "$rc $(val "$dir/state/runtime/version") $(record current_version)" "0 1.1.0 1.1.0" ||
    bad+="the next install: exit $rc: $(out); "
  is "$(find "$dir" -name '*.tmp.*')" "" || bad+="temp files left: $(find "$dir" -name '*.tmp.*'); "
  bad+=$(complete_set 1.1.0)
  check "$1" "$bad" "$(st is "$bad" "")"
}
killed killed_mid_write block_chmod
killed killed_before_switch block_mv
killed killed_after_switch block_start

fresh killed_first_install
touch "$FAKE/block_mv"
install_killed 1.0.0 a
bad=""
is "$rc" 0 || bad+="the install never reached the block; "
gone "$dir/state/runtime" || bad+="state/runtime exists after a kill before the switch; "
install 1.0.0 a
is "$rc" 0 || bad+="the next install: exit $rc: $(out); "
bad+=$(complete_set 1.0.0)
check killed_first_install "$bad" "$(st is "$bad" "")"

# -------- Runtime set data files --------
# top: the top-level names of $dir.
top() { (cd "$dir" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort | xargs); }
TOP="README.md config.example.yaml config.local.yaml effective-policy.txt start.sh state verify-egress"
# stale_link: the active set gains a top-level name, extra.txt, that the next set lacks.
stale_link() {
  echo extra.txt >>"$dir/state/runtime/links"
  : >"$dir/state/runtime/extra.txt"
  ln -s state/runtime/extra.txt "$dir/extra.txt"
}

# An upgrade reads the active set's links past its header.
fresh links_header_upgrade
install 1.0.0 a
stale_link
install 1.1.0 b
bad=""
is "$rc" 0 || bad+="exit $rc: $(out); "
is "$(top)" "$TOP" || bad+="top level: $(top); "
bad+=$(complete_set 1.1.0)
check links_header_upgrade "$bad" "$(st is "$bad" "")"

# -------- A source-checkout install (FR-11) --------
# checkout_install: makes $dir a source-checkout install, the layout callers' installers
# made before the image (v0.5.0): commit $COMMIT checked out in versions/, current
# linking to it by absolute path, a download left over, the old start.sh's output beside
# a 0600 config. Its start.sh logs its run to $FAKE/old_start, then starts the old proxy
# (image egress-proxy, or $FAKE/old_start_image), or exits $FAKE/old_start_rc.
COMMIT=0123456789abcdef0123456789abcdef01234567
OLD_CONFIG=$'version: 1\nnetworks:\n  workers:\n    mode: denylist'
checkout_install() {
  local v=$dir/versions/$COMMIT
  mkdir -p "$v" "$dir/versions/.download.x"
  echo "$COMMIT" >"$v/COMMIT"
  cat >"$v/start.sh" <<'OLD'
#!/usr/bin/env bash
echo "EGRESS_CONFIG_DIR=${EGRESS_CONFIG_DIR:-} $0" >>"$FAKE/old_start"
rc=$(cat "$FAKE/old_start_rc" 2>/dev/null || echo 0)
if ((rc == 0)); then cat "$FAKE/old_start_image" 2>/dev/null >"$FAKE/running" || echo egress-proxy >"$FAKE/running"; fi
exit "$rc"
OLD
  "$REAL_CHMOD" 0755 "$v/start.sh"
  ln -s "$v" "$dir/current"
  printf '%s\n' "$OLD_CONFIG" >"$dir/config.local.yaml"
  "$REAL_CHMOD" 0600 "$dir/config.local.yaml"
  echo "# the old start.sh's override" >"$dir/compose.networks.yaml"
  echo "# a killed old start's temp file" >"$dir/.compose.networks.abc123"
}
# config_id: the config's checksum, and whether its mode is still 0600.
config_id() { echo "$(sha "$dir/config.local.yaml") $(find "$dir/config.local.yaml" -perm 0600 | wc -l | tr -d ' ')"; }
LAYOUT="README.md config.example.yaml config.local.yaml effective-policy.txt start.sh state verify-egress"
# migrated_line [<shown dir>]: the line a migration prints, with <n> images removed.
migrated_line() {
  echo "install.sh: migrated the source-checkout install: removed $dir/versions and $dir/current and $1 locally built image(s); the start command is now ${2:-$dir}/start.sh, not current/start.sh"
}
# checkout_kept: versions/, current and the config are as checkout_install made them.
checkout_kept() {
  [[ -L $dir/current && $(readlink "$dir/current") == "$dir/versions/$COMMIT" && -f $dir/versions/$COMMIT/start.sh &&
    -d $dir/versions/.download.x && $(config_id) == "$conf" ]]
}

fresh migrate
mkdir -p "$dir"
checkout_install
conf=$(config_id)
install 1.0.0 a
bad=""
is "$rc" 0 || bad+="exit $rc; "
is "$(config_id)" "$conf" || bad+="config: $(config_id), was $conf; "
is "$(top)" "$LAYOUT" || bad+="top: $(top); "
is "$(cat "$FAKE/running") $(record current_version) $(record current_digest) $(record previous_digest)" \
  "$(image a) 1.0.0 $(digest a) " || bad+="running $(cat "$FAKE/running"): $(cat "$dir/state/installed"); "
grep -qxF "$(migrated_line 0)" "$work/out" || bad+="no migrated line; "
[[ ! -e $FAKE/old_start ]] || bad+="the old start.sh ran; "
check migrate "$bad: $(out)" "$(st is "$bad" "")"

# Old images: every named row no container uses, by name, or by ID when untagged; never forced.
fresh migrate_images
mkdir -p "$dir"
checkout_install
printf '%s\n' "egress-proxy:latest sha256:id-old1" "egress-proxy:<none> sha256:id-old2" >"$FAKE/legacy.egress-proxy"
echo "egress-proxy-proxy:latest sha256:id-old3" >"$FAKE/legacy.egress-proxy-proxy"
echo "egress-gateway:latest sha256:id-old4" >"$FAKE/legacy.egress-gateway"
echo egress-gateway:latest >"$FAKE/in_use"
echo "sha256:id-$(image a)" >"$FAKE/images"
: >"$FAKE/calls"
install 1.0.0 a
bad=""
is "$rc" 0 || bad+="exit $rc; "
is "$(cat "$FAKE"/legacy.* | xargs)" "egress-gateway:latest sha256:id-old4" || bad+="left: $(cat "$FAKE"/legacy.* | xargs); "
grep -qF " image rm sha256:id-old2" "$FAKE/calls" || bad+="the untagged one not by ID; "
grep -q ' image rm -f' "$FAKE/calls" && bad+="forced removal; "
is "$(images_left)" "$(image a)" || bad+="images: $(images_left); "
grep -qxF "$(migrated_line 3)" "$work/out" || bad+="no migrated line; "
check migrate_images "$bad: $(out)" "$(st is "$bad" "")"
fresh migrate_images_rm_fails
mkdir -p "$dir"
checkout_install
echo "egress-proxy:latest sha256:id-old1" >"$FAKE/legacy.egress-proxy"
echo egress-proxy:latest >"$FAKE/rm_fails"
install 1.0.0 a
check migrate_images_rm_fails "exit $rc: $(out)" \
  "$(st is "$rc $(grep -cxF "$(migrated_line 0)" "$work/out" || true) $(gone "$dir/versions" && echo gone)" "0 1 gone")"

# The start command as the user types it, ~/.egress/start.sh, once, on stdout.
fresh migrate_message
home=$work/home-migrate tilde='~'
dir=$home/.egress
mkdir -p "$dir"
checkout_install
echo 1.0.0 >"$FAKE/label"
rc=0
HOME=$home PATH="$work/fast:$work/bin:$PATH" bash "$files/install.sh" --interface 1 --version 1.0.0 \
  --digest "$(digest a)" --dir "$dir" --image "$(image a)" --files "$files" >"$work/out" 2>"$work/stderr" || rc=$?
check migrate_message "exit $rc: $(out)" \
  "$(st is "$rc $(grep -cxF "$(migrated_line 0 "$tilde/.egress")" "$work/out" || true)" "0 1")"

# A migration killed after its record: the next install finishes it, the old start.sh untouched.
fresh migrate_resumed
install 1.0.0 a
checkout_install
conf=$(config_id)
echo "egress-proxy:latest sha256:id-old1" >"$FAKE/legacy.egress-proxy"
install 1.1.0 b
bad=""
is "$rc" 0 || bad+="exit $rc; "
is "$(top)" "$LAYOUT" || bad+="top: $(top); "
is "$(config_id)" "$conf" || bad+="config changed; "
is "$(cat "$FAKE/legacy.egress-proxy")" "" || bad+="old image left; "
is "$(grep -cxF "$(migrated_line 1)" "$work/out" || true)" 1 || bad+="no migrated line; "
check migrate_resumed "$bad: $(out)" "$(st is "$bad" "")"

# Entries named current or versions without the source-checkout shape are left alone.
# checkout_tree: every path under current and versions, with link targets and checksums.
checkout_tree() {
  (cd "$dir" && { find current versions 2>/dev/null || true; } | sort | while read -r p; do
    if [[ -L $p ]]; then echo "$p -> $(readlink "$p")"; elif [[ -f $p ]]; then echo "$p $(cksum <"$p")"; else echo "$p/"; fi
  done)
}
# foreign <case> <entries named in the message>: the install succeeded, left them as
# $before holds them and said so.
foreign() {
  local bad=""
  is "$rc" 0 || bad+="exit $rc; "
  grep -qxF "install.sh: left $2 as found: not a source-checkout install" "$work/out" || bad+="no left line; "
  like "$(out)" "migrated the source-checkout install" && bad+="it migrated; "
  [[ ! -e $FAKE/old_start ]] || bad+="the old start.sh ran; "
  is "$(checkout_tree)" "$before" || bad+="changed: $(checkout_tree | xargs); "
  check "$1" "$bad: $(out)" "$(st is "$bad" "")"
}
fresh migrate_foreign_current
mkdir -p "$dir/current"
echo mine >"$dir/current/notes.txt"
before=$(checkout_tree)
install 1.0.0 a
foreign migrate_foreign_current "$dir/current"
fresh migrate_foreign_current_elsewhere
mkdir -p "$dir" "$work/elsewhere/$COMMIT"
ln -s "$work/elsewhere/$COMMIT" "$dir/current"
before=$(checkout_tree)
install 1.0.0 a
foreign migrate_foreign_current_elsewhere "$dir/current"
n=0
for extra in notes.txt symlink ..x; do
  n=$((n + 1))
  fresh "migrate_foreign_versions_$n"
  mkdir -p "$dir"
  checkout_install
  case $extra in
    notes.txt | ..x) echo mine >"$dir/versions/$extra" ;;
    symlink) ln -s "$work/elsewhere/$COMMIT" "$dir/versions/fedcba9876543210fedcba9876543210fedcba98" ;;
  esac
  before=$(checkout_tree)
  install 1.0.0 a
  foreign "migrate_foreign_versions_$n ($extra)" "$dir/current and $dir/versions"
done

# A rollback install, and an install refused for another contract, leave it all.
fresh migrate_rollback_mode
mkdir -p "$dir"
checkout_install
conf=$(config_id)
EGRESS_INSTALL_ROLLBACK=1 install 1.0.0 a
check migrate_rollback_mode "exit $rc: $(out)" \
  "$(st is "$rc $(checkout_kept && echo kept) $(grep -c 'migrated the source-checkout' "$work/out" || true)" "0 kept 0")"
fresh migrate_contract_differs
mkdir -p "$dir"
checkout_install
conf=$(config_id)
before=$(tree)
echo egress-proxy >"$FAKE/running"
echo 2 >"$FAKE/run_contract"
install 1.0.0 a
check migrate_contract_differs "exit $rc: $(out)" "$(st is "$rc $(is "$(tree)" "$before" && echo same)" "10 same")"
fresh migrate_refused_image
mkdir -p "$dir"
checkout_install
before=$(tree)
echo "<no value>" >"$FAKE/contract"
install 1.0.0 a
rm -f "$FAKE/contract"
check migrate_refused_image "exit $rc: $(out)" "$(st is "$rc $(is "$(tree)" "$before" && echo same)" "5 same")"
# A newer, published proxy kept: nothing changes, the checkout included.
fresh migrate_keep_newer
install 1.2.0 c
checkout_install
conf=$(config_id)
echo 1.2.0 >"$FAKE/run_label"
echo "$REPO@$(digest c)" >"$FAKE/run_repodigests"
install 1.1.0 b
check migrate_keep_newer "exit $rc: $(out)" \
  "$(st is "$rc $(checkout_kept && echo kept) $(grep -c 'migrated the source-checkout' "$work/out" || true)" "0 kept 0")"

# -------- A failed migration: back to the source checkout (FR-11) --------
OLD_START=""
# migrate_failed <case> <code> <cause line> <last line>: exit <code> after <cause line>, the
# checkout kept as it was, the image layout's files gone and no image removed.
migrate_failed() {
  local bad="" old
  is "$rc" "$2" || bad+="exit $rc; "
  grep -qxF "$3" "$work/out" || bad+="no cause line; "
  grep -qxF "install.sh: rolling back to the source-checkout install: $OLD_START" "$work/out" || bad+="no rolling-back line; "
  is "$(tail -n 1 "$work/out")" "$4" || bad+="last line: $(tail -n 1 "$work/out"); "
  old=$(cat "$FAKE/old_start" 2>/dev/null || true)
  is "$old" "EGRESS_CONFIG_DIR=$dir $OLD_START" || bad+="old start: $old; "
  checkout_kept || bad+="the checkout changed; "
  is "$(top)" ".compose.networks.abc123 compose.networks.yaml config.local.yaml current versions" || bad+="top: $(top); "
  grep -qE ' rm -f egress-proxy$' "$FAKE/calls" || bad+="the failed container was not removed; "
  grep -qE ' image rm ' "$FAKE/calls" && bad+="an image was removed; "
  check "$1" "$bad: $(out)" "$(st is "$bad" "")"
}
# failed_migration <case>: a source-checkout install, and its old proxy's last log line.
failed_migration() {
  fresh "$1"
  mkdir -p "$dir"
  checkout_install
  conf=$(config_id)
  OLD_START=$dir/versions/$COMMIT/start.sh
  echo "proxy: no route" >"$FAKE/logs"
  echo "egress-proxy:latest sha256:id-old1" >"$FAKE/legacy.egress-proxy"
  : >"$FAKE/calls"
}
NOT_HEALTHY="install.sh: egress-proxy 1.0.0 ($(digest a)) did not become healthy within 120 s; see docker logs egress-proxy"
failed_migration migrate_rollback
echo starting >"$FAKE/health.$(digest a)"
install 1.0.0 a
migrate_failed migrate_rollback 11 "$NOT_HEALTHY" \
  "install.sh: rolled back to the source-checkout install ($OLD_START), which is healthy; egress-proxy 1.0.0 was not installed; see docker logs egress-proxy"
is "$(cat "$FAKE/running")" egress-proxy || fail migrate_rollback "running $(cat "$FAKE/running")"

failed_migration migrate_rollback_start_fails
touch "$FAKE/up_fails.$(digest a)"
install 1.0.0 a
migrate_failed migrate_rollback_start_fails 11 \
  "install.sh: the start command failed (exit 1) for egress-proxy 1.0.0 ($(digest a)); see docker logs egress-proxy" \
  "install.sh: rolled back to the source-checkout install ($OLD_START), which is healthy; egress-proxy 1.0.0 was not installed; see docker logs egress-proxy"

failed_migration migrate_rollback_fails
echo starting >"$FAKE/health.$(digest a)"
echo 3 >"$FAKE/old_start_rc"
install 1.0.0 a
migrate_failed migrate_rollback_fails 9 "$NOT_HEALTHY" \
  "install.sh: rolling back to the source-checkout install ($OLD_START) failed (exit 3); see docker logs egress-proxy"

failed_migration migrate_rollback_not_healthy
echo starting >"$FAKE/health.$(digest a)"
echo starting >"$FAKE/health.egress-proxy"
install 1.0.0 a
migrate_failed migrate_rollback_not_healthy 9 "$NOT_HEALTHY" \
  "install.sh: rolling back to the source-checkout install ($OLD_START) failed (not healthy within 120 s); see docker logs egress-proxy"

# The old start.sh left this version running: not the old proxy, so not healthy.
failed_migration migrate_rollback_same_image
touch "$FAKE/up_fails.$(digest a)"
image a >"$FAKE/old_start_image"
install 1.0.0 a
migrate_failed migrate_rollback_same_image 9 \
  "install.sh: the start command failed (exit 1) for egress-proxy 1.0.0 ($(digest a)); see docker logs egress-proxy" \
  "install.sh: rolling back to the source-checkout install ($OLD_START) failed (not healthy within 120 s); see docker logs egress-proxy"

# No start.sh to go back to: as a first install, the new version is left as it is.
failed_migration migrate_no_old_start
rm "$dir/versions/$COMMIT/start.sh"
echo starting >"$FAKE/health.$(digest a)"
install 1.0.0 a
no_rollback migrate_no_old_start 6 "$NOT_HEALTHY"
[[ -L $dir/current && -d $dir/versions/$COMMIT && -L $dir/start.sh ]] || fail migrate_no_old_start "top: $(top)"

# Foreign entries: never run, as a first install.
fresh migrate_foreign_rollback
mkdir -p "$dir/current"
cat >"$dir/current/start.sh" <<'FOREIGN'
#!/usr/bin/env bash
touch "$FAKE/old_start"
FOREIGN
echo starting >"$FAKE/health.$(digest a)"
install 1.0.0 a
no_rollback migrate_foreign_rollback 6 "$NOT_HEALTHY"
[[ ! -e $FAKE/old_start && -f $dir/current/start.sh ]] || fail migrate_foreign_rollback "the foreign start.sh ran, or is gone"

# Once an image install is recorded, a failure rolls back to it, not to the checkout.
fresh migrate_resumed_rollback
install 1.0.0 a
old_image a 1.0.0
checkout_install
conf=$(config_id)
echo starting >"$FAKE/health.$(digest b)"
install 1.1.0 b
bad=""
is "$rc $(tail -n 1 "$work/out")" "11 install.sh: rolled back to egress-proxy 1.0.0 ($(digest a)), which is healthy; egress-proxy 1.1.0 was not installed; see docker logs egress-proxy" ||
  bad+="exit $rc; "
[[ ! -e $FAKE/old_start ]] || bad+="the old start.sh ran; "
checkout_kept || bad+="the rollback install removed the checkout; "
check migrate_resumed_rollback "$bad: $(out)" "$(st is "$bad" "")"

# -------- A remote install: install.sh and start.sh (README.md › Remote Docker host) --------
TGT=ssh://admin@pc.example:2222
# ref <digest char>: the image's name on the target.
ref() { echo "$REPO:sha256-$(digest "$1" | sed 's/^sha256://')"; }
# hosts_ok: every docker call since $FAKE/hosts was emptied went to the target, no context.
hosts_ok() { is "$(sort -u "$FAKE/hosts")" "$TGT|"; }
# rstart [env...]: the installed start.sh, output in $work/out, exit code in $rc.
rstart() {
  rc=0
  env "$@" PATH="$work/fast:$work/bin:$PATH" "$dir/start.sh" >"$work/out" 2>&1 || rc=$?
}

fresh remote_install
DOCKER_CONTEXT=hostile install 1.0.0 a --docker-host "$TGT"
bad=""
is "$rc" 0 || bad+="exit $rc; "
is "$(val "$dir/state/docker-host")" "$TGT" || bad+="state/docker-host: $(cat "$dir/state/docker-host" 2>/dev/null); "
hosts_ok || bad+="hosts: $(sort -u "$FAKE/hosts" | xargs); "
is "$(cat "$FAKE/running") $(val "$dir/state/runtime/image") $(record current_image)" "$(ref a) $(ref a) $(image a)" ||
  bad+="running $(cat "$FAKE/running"), runtime image $(val "$dir/state/runtime/image"), record $(record current_image); "
grep -E ' pull |--pull always| (build|buildx)( |$)|-v /|:/etc/egress:ro' "$FAKE/calls" && bad+="a pull, build or bind mount; "
grep -qF ' volume create egress-config' "$FAKE/calls" || bad+="no volume create; "
grep ' compose ' "$FAKE/calls" | grep -qvF "$dir/state/runtime/compose.remote.yaml" && bad+="compose without compose.remote.yaml; "
cmp -s "$FAKE/volume/config.local.yaml" "$dir/config.local.yaml" || bad+="the volume does not hold the config; "
like "$(out)" "egress-proxy 1.0.0 ($(digest a)) installed in $dir; start command: $dir/start.sh" || bad+="no installed message; "
check remote_install "$bad: $(out)" "$(st is "$bad" "")"

bad=""
grep -qF "| Logs (config errors name the network and key) | \`docker --host $TGT logs egress-proxy\` |" "$dir/README.md" || bad+="logs row; "
grep -qF "| Health | \`docker --host $TGT inspect" "$dir/README.md" || bad+="health row; "
grep -qF "image \`$(image a)\`, on the Docker host $TGT" "$dir/README.md" || bad+="installed line; "
check remote_readme "$bad: $(sed -n '1,30p' "$dir/README.md")" "$(st is "$bad" "")"

rm -f "${FAKE:?}/hosts"
rstart DOCKER_HOST=tcp://hostile:1234 DOCKER_CONTEXT=hostile
check remote_start_env "exit $rc, hosts $(sort -u "$FAKE/hosts" | xargs): $(out)" "$(st is "$rc $(hosts_ok && echo ok)" "0 ok")"

before=$(sha "$FAKE/volume/config.local.yaml")
"$REAL_CP" "$dir/config.local.yaml" "$work/config.saved"
echo "# BAD" >>"$dir/config.local.yaml"
: >"$FAKE/calls"
rstart
bad=""
is "$rc" 2 || bad+="exit $rc; "
like "$(out)" "config /etc/egress/config.local.yaml: network workers: BAD" || bad+="no config error; "
is "$(sha "$FAKE/volume/config.local.yaml")" "$before" || bad+="the volume changed; "
grep -E ' volume | up ' "$FAKE/calls" && bad+="it went on; "
is "$(find "$dir/state" -maxdepth 1 -name '.config.*')" "" || bad+="a staged config is left; "
check remote_config_error_unchanged "$bad: $(out)" "$(st is "$bad" "")"

mv "$dir/config.local.yaml" "$work/config.bad"
: >"$FAKE/calls"
rstart
check remote_config_missing "exit $rc, calls $(cat "$FAKE/calls"): $(out)" \
  "$(st is "$rc $(wc -l <"$FAKE/calls" | tr -d ' ')" "2 0")"
"$REAL_CP" "$work/config.saved" "$dir/config.local.yaml"

"$REAL_CP" "$dir/state/docker-host" "$work/target.saved"
echo 'ssh://pc;id' >"$dir/state/docker-host"
: >"$FAKE/calls"
rstart
check remote_bad_target "exit $rc, calls $(cat "$FAKE/calls"): $(out)" \
  "$(st like "$rc $(wc -l <"$FAKE/calls" | tr -d ' ') $(out)" "2 0 start.sh: $dir/state/docker-host is not ssh://")"
"$REAL_CP" "$work/target.saved" "$dir/state/docker-host"

before=$(tree)
install 1.1.0 b
check remote_dir_needs_target "exit $rc: $(out)" \
  "$(st like "$rc $(out)" "2 install.sh: $dir is a remote install (state/docker-host)")"
is "$(tree)" "$before" || fail remote_dir_needs_target "$dir changed"

# The same downgrade rule: a published newer version is kept, judged by the image ID of the
# recorded digest's tag (a loaded image has no RepoDigests).
fresh remote_keep_newer
install 1.2.0 c --docker-host "$TGT"
echo 1.2.0 >"$FAKE/run_label"
: >"$FAKE/calls"
install 1.1.0 b --docker-host "$TGT"
check remote_keep_newer "exit $rc, running $(cat "$FAKE/running"): $(out)" "$(st is "$rc $(cat "$FAKE/running") $(out)" \
  "0 $(ref c) install.sh: kept the running egress-proxy 1.2.0 ($(digest c)), newer than 1.1.0; nothing was changed")"
echo "$REPO:9.9.9" >"$FAKE/running"
install 1.1.0 b --docker-host "$TGT"
check remote_replaces_unpublished "exit $rc, running $(cat "$FAKE/running"): $(out)" \
  "$(st is "$rc $(cat "$FAKE/running")" "0 $(ref b)")"

fresh remote_cleanup
install 1.0.0 a --docker-host "$TGT"
install 1.1.0 b --docker-host "$TGT"
printf 'sha256:id-%s\n' "$(ref a)" "$(ref b)" "$REPO:9.9.9" "$(ref c)" >"$FAKE/images"
install 1.2.0 c --docker-host "$TGT"
check remote_cleanup "exit $rc, left $(images_left): $(out)" "$(st is "$rc $(images_left)" "0 $(ref b) $(ref c)")"

# The same rollback rule: the previous version's own egress-install, from its runtime set,
# reinstalls it on the recorded target.
fresh remote_rollback
install 1.0.0 a --docker-host "$TGT"
install 1.1.0 b --docker-host "$TGT"
old_image b 1.1.0
echo starting >"$FAKE/health.$(digest c)"
rm -f "${FAKE:?}/hosts"
install 1.2.0 c --docker-host "$TGT"
bad=""
is "$rc" 11 || bad+="exit $rc; "
is "$(tail -n 1 "$work/out")" "install.sh: rolled back to egress-proxy 1.1.0 ($(digest b)), which is healthy; egress-proxy 1.2.0 was not installed; see docker logs egress-proxy" ||
  bad+="last line: $(tail -n 1 "$work/out"); "
is "$(cat "$FAKE/running") $(record current_version) $(val "$dir/state/docker-host")" "$(ref b) 1.1.0 $TGT" ||
  bad+="running $(cat "$FAKE/running"): $(cat "$dir/state/installed"); "
hosts_ok || bad+="hosts: $(sort -u "$FAKE/hosts" | xargs); "
check remote_rollback "$bad: $(out)" "$(st is "$bad" "")"
rm -f "${FAKE:?}/health.$(digest c)"

# The caller's docker: whatever `docker` is first on PATH, here a wrapper.
fresh remote_docker_wrapper
mkdir -p "$work/wrap"
cat >"$work/wrap/docker" <<WRAP
#!/usr/bin/env bash
echo "\$*" >>"\$FAKE/wrapped"
exec "$work/bin/docker" "\$@"
WRAP
chmod +x "$work/wrap/docker"
rm -f "$FAKE/wrapped"
echo 1.0.0 >"$FAKE/label"
rc=0
PATH="$work/wrap:$work/fast:$work/bin:$PATH" bash "$files/install.sh" --interface 1 --version 1.0.0 \
  --digest "$(digest a)" --dir "$dir" --image "$(image a)" --files "$files" --docker-host "$TGT" >"$work/out" 2>&1 || rc=$?
check remote_docker_wrapper "exit $rc, $(wc -l <"$FAKE/calls") calls, $(wc -l <"$FAKE/wrapped" 2>/dev/null) wrapped: $(out)" \
  "$(st is "$rc $(wc -l <"$FAKE/calls")" "0 $(wc -l <"$FAKE/wrapped" 2>/dev/null)")"

# -------- egress-install --------
# The image's installer, for these cases: records its arguments, exits install_rc.
mkdir -p "$FAKE/egress" "$work/tmpdir"
cat >"$FAKE/egress/install.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >"$FAKE/handoff"
exit "$(cat "$FAKE/install_rc" 2>/dev/null || echo 0)"
FAKE
# bootstrap <version> <digest> [args...]: runs egress-install into $dir with TMPDIR
# $work/tmpdir; stdout in $work/out, stderr in $work/err, exit code in $rc.
bootstrap() {
  rc=0
  TMPDIR=$work/tmpdir PATH="$work/fast:$work/bin:$PATH" bash "$repo/egress-install" --version "$1" \
    --digest "$2" --dir "$dir" "${@:3}" >"$work/out" 2>"$work/err" || rc=$?
}
err() { cat "$work/err"; }
reset() {
  dir=$work/egress-$1
  rm -rf "$FAKE/pull_config"
  rm -f "$FAKE"/{image_missing,pull_err,gh_logged_out,handoff,helper_out,gh_calls,calls,token_files,install_rc,daemon_down,cp_fails}
}
D=$(digest e)
IMG=$REPO@$D
# no_temp: egress-install left nothing in TMPDIR.
no_temp() { is "$(find "$work/tmpdir" -mindepth 1 -print)" ""; }

reset bs_usage
bootstrap 1.0 "$D"
check bs_usage "exit $rc: $(err)" "$(st is "$rc $(err)" "2 usage: egress-install --version X.Y.Z --digest sha256:<64 hex> [--dir <path>] [--docker-host ssh://<host>]")"
bootstrap 1.0.0 sha256:abc
is "$rc" 2 || fail bs_usage "a short digest: exit $rc"

reset present_no_gh
bootstrap 1.0.0 "$D"
want="--interface 1 --version 1.0.0 --digest $D --dir $dir --image $IMG --files $work/tmpdir/"
bad=""
is "$rc" 0 || bad+="exit $rc: $(err); "
like "$(cat "$FAKE/handoff" 2>/dev/null)" "$want" || bad+="handoff: $(cat "$FAKE/handoff" 2>/dev/null); "
is "$(grep -c ' pull ' "$FAKE/calls" || true)" 0 || bad+="it pulled; "
[[ ! -f $FAKE/gh_calls ]] || bad+="it called gh: $(cat "$FAKE/gh_calls"); "
no_temp || bad+="temp files left"
check present_no_gh "$bad" "$(st is "$bad" "")"

reset handoff_exit
echo 6 >"$FAKE/install_rc"
bootstrap 1.0.0 "$D"
check handoff_exit "exit $rc" "$(st is "$rc" 6)"

reset gh_helper
touch "$FAKE/image_missing"
mkdir -p "$DOCKER_CONFIG/contexts"
bootstrap 1.0.0 "$D"
bad=""
is "$rc" 0 || bad+="exit $rc: $(err); "
is "$(cat "$FAKE/pull_config/config.json" 2>/dev/null)" '{"currentContext":"my-context","credHelpers":{"ghcr.io":"egress-gh"}}' ||
  bad+="config.json: $(cat "$FAKE/pull_config/config.json" 2>/dev/null); "
is "$(readlink "$FAKE/pull_config/contexts")" "$DOCKER_CONFIG/contexts" || bad+="contexts not kept; "
is "$(cat "$FAKE/helper_out" 2>/dev/null)" "{\"ServerURL\":\"ghcr.io\",\"Username\":\"octo\",\"Secret\":\"$FAKE_TOKEN\"}" ||
  bad+="helper answered: $(cat "$FAKE/helper_out" 2>/dev/null); "
is "$(cat "$FAKE/token_files")" "" || bad+="token in files under TMPDIR: $(cat "$FAKE/token_files"); "
grep -rqF "$FAKE_TOKEN" "$FAKE/pull_config" && bad+="token in the pull's client config; "
like "$(out)$(err)" "$FAKE_TOKEN" && bad+="token in the output; "
like "$(cat "$FAKE/handoff" 2>/dev/null)" "--image $IMG " || bad+="no handoff after the pull; "
no_temp || bad+="temp files left"
check gh_helper "$bad" "$(st is "$bad" "")"
rmdir "$DOCKER_CONFIG/contexts"

reset gh_helper_other_registry
touch "$FAKE/image_missing"
EGRESS_IMAGE_REPO=localhost:5000/egress-proxy bootstrap 1.0.0 "$D"
bad=""
is "$rc" 0 || bad+="exit $rc: $(err); "
is "$(cat "$FAKE/pull_config/config.json" 2>/dev/null)" '{"currentContext":"my-context"}' ||
  bad+="config.json: $(cat "$FAKE/pull_config/config.json" 2>/dev/null); "
[[ ! -f $FAKE/gh_calls ]] || bad+="it called gh: $(cat "$FAKE/gh_calls"); "
like "$(cat "$FAKE/handoff" 2>/dev/null)" "--image localhost:5000/egress-proxy@$D " || bad+="handoff: $(cat "$FAKE/handoff" 2>/dev/null)"
check gh_helper_other_registry "$bad" "$(st is "$bad" "")"

reset no_access
touch "$FAKE/image_missing" "$FAKE/gh_logged_out"
echo "Error response from daemon: Head \"https://ghcr.io/v2/windroc/egress-proxy/manifests/$D\": denied" >"$FAKE/pull_err"
bootstrap 1.0.0 "$D"
want="egress-install: no access to $REPO: needs a GitHub login (gh auth login) whose account can read the package $REPO, with scope read:packages (gh auth refresh -h github.com -s read:packages); nothing was changed"
bad=""
is "$rc $(err)" "3 $want" || bad+="exit $rc: $(err); "
gone "$dir" || bad+="$dir was created; "
[[ ! -f $FAKE/handoff ]] || bad+="the installer ran; "
no_temp || bad+="temp files left"
check no_access "$bad" "$(st is "$bad" "")"

reset pull_fails
touch "$FAKE/image_missing"
echo "Error response from daemon: Get \"https://ghcr.io/v2/\": dial tcp: lookup ghcr.io: no such host" >"$FAKE/pull_err"
bootstrap 1.0.0 "$D"
bad=""
is "$rc" 4 || bad+="exit $rc; "
like "$(err)" "egress-install: cannot pull $IMG from registry ghcr.io (Error response from daemon: Get" || bad+="$(err); "
like "$(err)" "nothing was changed and the running proxy, if any, keeps running" || bad+="$(err); "
gone "$dir" || bad+="$dir was created; "
[[ ! -f $FAKE/handoff ]] || bad+="the installer ran; "
no_temp || bad+="temp files left"
check pull_fails "$bad" "$(st is "$bad" "")"

reset pull_fails_digest_401
D401=sha256:$(printf '401403%058d' 0)
touch "$FAKE/image_missing"
echo "Error response from daemon: Get \"https://ghcr.io/v2/windroc/egress-proxy/manifests/$D401\": net/http: TLS handshake timeout" >"$FAKE/pull_err"
bootstrap 1.0.0 "$D401"
check pull_fails_digest_401 "exit $rc: $(err)" "$(st like "$rc $(err)" "4 egress-install: cannot pull $REPO@$D401 from registry ghcr.io")"

reset daemon_down
touch "$FAKE/daemon_down"
bootstrap 1.0.0 "$D"
bad=""
is "$rc $(err)" "2 egress-install: Docker is not running or not reachable (docker version failed); nothing was changed" ||
  bad+="exit $rc: $(err); "
is "$(grep -c ' pull ' "$FAKE/calls" || true)" 0 || bad+="it pulled; "
[[ ! -f $FAKE/handoff ]] || bad+="the installer ran"
check daemon_down "$bad" "$(st is "$bad" "")"

reset cp_fails
touch "$FAKE/cp_fails"
bootstrap 1.0.0 "$D"
check cp_fails "exit $rc: $(err)" "$(st like "$rc $(err)" "1 egress-install: cannot copy /egress out of $IMG: Error response from daemon: write")"
[[ ! -f $FAKE/handoff ]] || fail cp_fails "the installer ran"

reset no_installer
rm "$FAKE/egress/install.sh"
bootstrap 1.0.0 "$D"
check no_installer "exit $rc: $(err)" "$(st is "$rc $(err)" "5 egress-install: $IMG has no installer (/egress/install.sh)")"

# -------- egress-install --docker-host (README.md › Remote Docker host) --------
# A fake registry on 127.0.0.1: one multi-arch image (linux/amd64 and linux/arm64, one tiny
# layer each), its index digest in reg_digest, each config digest in reg_cfg_<arch>. It logs
# "<path> <Authorization>" per request in reg_log. Scenarios: reg_deny (403 for manifests),
# reg_auth (a bearer token from its /token is required), reg_realm (the token realm it
# names instead of its own /token), reg_redirect (blobs answer 307 to /redirected/<digest>),
# reg_corrupt (a layer's bytes differ from its digest).
cat >"$work/registry.py" <<'PY'
import gzip, hashlib, http.server, io, json, os, sys, tarfile

fake, port_file = sys.argv[1:3]
blobs, manifests = {}, {}


def put(store, data):
    d = "sha256:" + hashlib.sha256(data).hexdigest()
    store[d] = data
    return d


entries = []
for arch in ("amd64", "arm64"):
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as tar:
        body = ("hello " + arch).encode()
        info = tarfile.TarInfo("hello")
        info.size = len(body)
        tar.addfile(info, io.BytesIO(body))
    layer = gzip.compress(raw.getvalue(), mtime=0)
    config = json.dumps({"architecture": arch, "os": "linux", "config": {"Labels": {}},
                         "rootfs": {"type": "layers", "diff_ids": ["sha256:" + hashlib.sha256(raw.getvalue()).hexdigest()]}}).encode()
    cd, ld = put(blobs, config), put(blobs, layer)
    with open(os.path.join(fake, "reg_cfg_" + arch), "w") as f:
        f.write(cd)
    man = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
                      "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": cd, "size": len(config)},
                      "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar+gzip", "digest": ld, "size": len(layer)}]}).encode()
    entries.append({"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": put(manifests, man),
                    "size": len(man), "platform": {"architecture": arch, "os": "linux"}})
index = json.dumps({"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": entries}).encode()
with open(os.path.join(fake, "reg_digest"), "w") as f:
    f.write(put(manifests, index))


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, data=b"", ctype="application/octet-stream", headers=()):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        auth = self.headers.get("Authorization", "-")
        with open(os.path.join(fake, "reg_log"), "a") as f:
            f.write("%s %s\n" % (self.path, auth))
        on = lambda name: os.path.exists(os.path.join(fake, name))
        if self.path.startswith("/token"):
            return self.send(200, b'{"token": "regtoken"}', "application/json")
        if self.path.startswith("/redirected/"):
            return self.send(200, blobs[self.path.rsplit("/", 1)[1]])
        if on("reg_auth") and auth != "Bearer regtoken":
            url = "http://127.0.0.1:%d/token" % self.server.server_port
            if on("reg_realm"):
                with open(os.path.join(fake, "reg_realm")) as f:
                    url = f.read().strip()
            realm = 'Bearer realm="%s",service="fake",scope="repository:egress-proxy:pull"' % url
            return self.send(401, b"{}", "application/json", [("WWW-Authenticate", realm)])
        kind, _, d = self.path.rpartition("/")
        if kind.endswith("/manifests") and d in manifests:
            if on("reg_deny"):
                return self.send(403, b"{}", "application/json")
            return self.send(200, manifests[d], json.loads(manifests[d])["mediaType"])
        if kind.endswith("/blobs") and d in blobs:
            if on("reg_redirect"):
                return self.send(307, b"", headers=[("Location", "/redirected/" + d)])
            data = blobs[d]
            if on("reg_corrupt") and json.loads(manifests[entries[0]["digest"]])["layers"][0]["digest"] == d:
                data = data[:-1] + b"x"
            return self.send(200, data)
        self.send(404, b"{}", "application/json")


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
with open(port_file + ".tmp", "w") as f:
    f.write(str(server.server_port))
os.rename(port_file + ".tmp", port_file)
server.serve_forever()
PY
python3 -I "$work/registry.py" "$FAKE" "$work/reg_port" &
reg_pid=$!
trap 'kill "$reg_pid" 2>/dev/null || true; rm -rf "${work:?}"' EXIT
for _ in $(seq 1 50); do [[ -f $work/reg_port ]] && break; sleep 0.1; done
REG=127.0.0.1:$(cat "$work/reg_port")/egress-proxy
RD=$(cat "$FAKE/reg_digest")
RREF=$REG:sha256-${RD#sha256:}
# The image's /egress again (no_installer above removed its installer), with the overlay a
# remote install needs.
cat >"$FAKE/egress/install.sh" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >"$FAKE/handoff"
exit "$(cat "$FAKE/install_rc" 2>/dev/null || echo 0)"
FAKE
cp "$repo/compose.remote.yaml" "$FAKE/egress/"
handoff() { cat "$FAKE/handoff" 2>/dev/null || true; }
# rreset <case>: reset, no image on the target, and the registry's default scenario.
rreset() {
  reset "$1"
  rm -rf "${FAKE:?}/loaded"
  rm -f "${FAKE:?}"/{load_id,load_fails,platform,reg_log,reg_deny,reg_auth,reg_realm,reg_redirect,reg_corrupt,hosts}
  touch "$FAKE/image_missing"
}
# rbootstrap <args...>: bootstrap of the registry's image (repo $REG).
rbootstrap() { EGRESS_IMAGE_REPO=$REG DOCKER_CONTEXT=hostile bootstrap 1.0.0 "$RD" "$@"; }
# not_loaded: nothing reached the target's image store, the installer did not run, and the
# install directory was not created.
not_loaded() { [[ ! -d $FAKE/loaded && ! -f $FAKE/handoff && ! -e $dir ]]; }

rreset remote_fetch_load
rbootstrap --docker-host "$TGT"
bad=""
is "$rc" 0 || bad+="exit $rc: $(err); "
like "$(handoff)" "--image $REG@$RD --files $work/tmpdir/" || bad+="handoff: $(handoff); "
like "$(handoff)" " --docker-host $TGT" || bad+="no --docker-host in the handoff; "
hosts_ok || bad+="hosts: $(sort -u "$FAKE/hosts" | xargs); "
grep -qF " load -q -i $work/tmpdir/" "$FAKE/calls" || bad+="no load: $(grep load "$FAKE/calls" || true); "
grep -qF " create --pull never $RREF" "$FAKE/calls" || bad+="the files not from $RREF; "
grep -E ' pull |--pull always' "$FAKE/calls" && bad+="the target pulled; "
[[ ! -f $FAKE/gh_calls ]] || bad+="gh ran for $REG: $(cat "$FAKE/gh_calls"); "
got=$(cd "$FAKE/loaded" 2>/dev/null && find . -type f | sed 's|^\./||' | sed 's|blobs/sha256/[0-9a-f]*$|blob|' | sort | uniq -c | xargs)
is "$got" "3 blob 1 index.json 1 manifest.json 1 oci-layout" || bad+="archive: $got; "
like "$(cat "$FAKE/loaded/manifest.json" 2>/dev/null)" "\"RepoTags\": [\"$RREF\"]" || bad+="manifest.json: $(cat "$FAKE/loaded/manifest.json" 2>/dev/null); "
like "$(cat "$FAKE/loaded/index.json" 2>/dev/null)" "\"io.containerd.image.name\": \"$RREF\"" || bad+="index.json names; "
is "$(cat "$FAKE/load_id" 2>/dev/null)" "$(cat "$FAKE/reg_cfg_amd64")" || bad+="not the amd64 config; "
no_temp || bad+="temp files left"
check remote_fetch_load "$bad" "$(st is "$bad" "")"

rreset remote_image_present
rm -f "${FAKE:?}/image_missing"
rbootstrap --docker-host "$TGT"
check remote_image_present "exit $rc, registry $(cat "$FAKE/reg_log" 2>/dev/null): $(err)" \
  "$(st is "$rc $(grep -c ' load ' "$FAKE/calls" || true) $(cat "$FAKE/reg_log" 2>/dev/null)" "0 0 ")"

rreset remote_platform
echo linux/arm64 >"$FAKE/platform"
rbootstrap --docker-host "$TGT"
check remote_platform "exit $rc: $(err)" "$(st is "$rc $(cat "$FAKE/load_id" 2>/dev/null)" "0 $(cat "$FAKE/reg_cfg_arm64")")"
rreset remote_platform_missing
echo linux/s390x >"$FAKE/platform"
rbootstrap --docker-host "$TGT"
check remote_platform_missing "exit $rc: $(err)" \
  "$(st like "$rc $(not_loaded && echo none) $(err)" "4 none egress-install: cannot fetch $REG@$RD for linux/s390x from registry ${REG%%/*} (no linux/s390x image in")"

rreset remote_auth_token
touch "$FAKE/reg_auth"
rbootstrap --docker-host "$TGT"
bad=""
is "$rc" 0 || bad+="exit $rc: $(err); "
grep -q "/manifests/$RD Bearer regtoken" "$FAKE/reg_log" || bad+="no bearer request: $(cat "$FAKE/reg_log"); "
grep '^/token' "$FAKE/reg_log" | grep -q Basic && bad+="credentials sent to a non-ghcr realm; "
[[ ! -f $FAKE/gh_calls ]] || bad+="gh ran for $REG; "
check remote_auth_token "$bad" "$(st is "$bad" "")"

# The ghcr.io path: egress-install's own fetch program, run with urlopen pointed at the fake
# registry for https://ghcr.io and https://elsewhere.example (a patched stdlib call; the
# program is unchanged). With a gh login, only the https ghcr.io realm gets the Basic
# credential, a blob redirect carries no credential, and the token is in no argv, file or
# output; with none, the token request is anonymous.
cat >"$work/ghcr-fetch.py" <<'PY'
import sys, urllib.request

port, entry = sys.argv[1:3]
src = open(entry).read().split("IFS= read -r -d '' FETCH <<'PY' || true\n", 1)[1].split("\nPY\n", 1)[0]
real = urllib.request.urlopen


def urlopen(req, *args, **kwargs):
    for origin in ("https://ghcr.io/", "https://elsewhere.example/"):
        if req.full_url.startswith(origin):
            req.full_url = "http://127.0.0.1:%s/%s" % (port, req.full_url[len(origin):])
    return real(req, *args, **kwargs)


urllib.request.urlopen = urlopen
sys.argv = ["fetch"] + sys.argv[3:]
exec(compile(src, "egress-install FETCH", "exec"), {"__name__": "__main__"})
PY
# gfetch <case> <realm> [logged_out]: the fetch of ghcr.io/windroc/egress-proxy@$RD into
# $work/gf, with a gh that logs its arguments (logged_out: no gh login); exit code in $rc.
gfetch() {
  rreset "$1"
  touch "$FAKE/reg_auth" "$FAKE/reg_redirect"
  echo "$2" >"$FAKE/reg_realm"
  if [[ ${3:-} == logged_out ]]; then touch "$FAKE/gh_logged_out"; fi
  rm -rf "${work:?}/gf"
  mkdir -p "$work/gf"
  rc=0
  PATH="$work/bin:$PATH" python3 -I "$work/ghcr-fetch.py" "$(cat "$work/reg_port")" "$repo/egress-install" \
    ghcr.io/windroc/egress-proxy "$RD" linux/amd64 "ghcr.io/windroc/egress-proxy:sha256-${RD#sha256:}" \
    "$work/gf/image.tar" >"$work/out" 2>"$work/err" || rc=$?
}
basic=$(printf 'octo:%s' "$FAKE_TOKEN" | base64 | tr -d '\n')
gfetch remote_fetch_ghcr_token https://ghcr.io/token
bad=""
is "$rc $(out)" "0 $(cat "$FAKE/reg_cfg_amd64") $(grep -o 'sha256:[0-9a-f]*' "$work/out" | tail -n 1)" || bad+="exit $rc: $(out) $(err); "
grep -qxF "/token?service=fake&scope=repository%3Aegress-proxy%3Apull Basic $basic" "$FAKE/reg_log" || bad+="no Basic token request: $(grep '^/token' "$FAKE/reg_log" || true); "
grep -q "^/v2/windroc/egress-proxy/manifests/$RD Bearer regtoken$" "$FAKE/reg_log" || bad+="no bearer manifest request; "
grep -q '^/redirected/' "$FAKE/reg_log" || bad+="no blob redirect; "
grep '^/redirected/' "$FAKE/reg_log" | grep -v ' -$' && bad+="a credential followed a redirect; "
grep -F "$FAKE_TOKEN" "$FAKE/gh_calls" && bad+="the token in gh's argv; "
grep -rlF "$FAKE_TOKEN" "$work/gf" && bad+="the token in a file; "
grep -F "$FAKE_TOKEN" "$work/out" "$work/err" && bad+="the token in the output; "
check remote_fetch_ghcr_token "$bad" "$(st is "$bad" "")"

gfetch remote_fetch_other_realm https://elsewhere.example/token
check remote_fetch_other_realm "exit $rc, $(grep '^/token' "$FAKE/reg_log" || true), gh $(cat "$FAKE/gh_calls" 2>/dev/null || true): $(err)" \
  "$(st is "$rc $(grep '^/token' "$FAKE/reg_log" | awk '{ print $2 }') $([[ -f $FAKE/gh_calls ]] || echo nogh)" "0 - nogh")"

gfetch remote_fetch_no_gh_login https://ghcr.io/token logged_out
check remote_fetch_no_gh_login "exit $rc, $(grep '^/token' "$FAKE/reg_log" || true): $(err)" \
  "$(st is "$rc $(grep '^/token' "$FAKE/reg_log" | awk '{ print $2 }')" "0 -")"
rm -f "${FAKE:?}/gh_logged_out"

rreset remote_no_access
touch "$FAKE/reg_deny"
rbootstrap --docker-host "$TGT"
check remote_no_access "exit $rc: $(err)" \
  "$(st like "$rc $(not_loaded && echo none) $(err)" "3 none egress-install: no access to $REG: needs a GitHub login")"

rreset remote_fetch_fails
touch "$FAKE/reg_corrupt"
rbootstrap --docker-host "$TGT"
check remote_fetch_fails "exit $rc: $(err)" \
  "$(st like "$rc $(not_loaded && echo none) $(no_temp && echo clean) $(err)" "4 none clean egress-install: cannot fetch $REG@$RD for linux/amd64 from registry ${REG%%/*} (layer sha256:")"
grep -q 'does not match its digest' "$work/err" || fail remote_fetch_fails "$(err)"

rreset remote_load_fails
touch "$FAKE/load_fails"
rbootstrap --docker-host "$TGT"
check remote_load_fails "exit $rc: $(err)" \
  "$(st is "$rc $([[ -f $FAKE/handoff ]] || echo none) $(err)" "1 none egress-install: cannot load $RREF on $TGT: Error response from daemon: no space left on device")"

rreset remote_on_local_dir
mkdir -p "$dir/state"
: >"$dir/state/installed"
rbootstrap --docker-host "$TGT"
check remote_on_local_dir "exit $rc, calls $(cat "$FAKE/calls" 2>/dev/null): $(err)" "$(st is "$rc $([[ -s $FAKE/calls ]] || echo nocalls) $(err)" \
  "2 nocalls egress-install: $dir holds a local install; install the remote one into another directory (--dir <path>); nothing was changed")"

for h in tcp://pc:2375 'ssh://pc;id' 'ssh://' 'ssh://pc/x' 'ssh://a b'; do
  rreset remote_bad_host
  rbootstrap --docker-host "$h"
  is "$rc $([[ -s $FAKE/calls ]] || echo nocalls)" "2 nocalls" || fail remote_bad_host "$h: exit $rc: $(err)"
done
ok remote_bad_host

rreset remote_recorded_target
mkdir -p "$dir/state"
printf '# generated\n%s\n' "$TGT" >"$dir/state/docker-host"
rbootstrap
check remote_recorded_target "exit $rc, hosts $(sort -u "$FAKE/hosts" | xargs): $(err)" \
  "$(st like "$rc $(hosts_ok && echo ok) $(handoff)" "0 ok --interface 1")"
like "$(handoff)" "--docker-host $TGT" || fail remote_recorded_target "handoff: $(handoff)"

rreset remote_new_target
mkdir -p "$dir/state"
printf '# generated\n%s\n' "$TGT" >"$dir/state/docker-host"
rbootstrap --docker-host ssh://pc-tailnet
check remote_new_target "exit $rc, hosts $(sort -u "$FAKE/hosts" | xargs): $(err)" \
  "$(st like "$rc $(sort -u "$FAKE/hosts" | xargs) $(handoff)" "0 ssh://pc-tailnet| --interface 1")"

rreset remote_old_version
rm -f "${FAKE:?}/egress/compose.remote.yaml"
rbootstrap --docker-host "$TGT"
check remote_old_version "exit $rc: $(err)" "$(st is "$rc $([[ -f $FAKE/handoff || -e $dir ]] || echo none) $(err)" \
  "5 none egress-install: egress-proxy 1.0.0 cannot be installed on a remote Docker host (its image has no compose.remote.yaml); install a version that supports it")"
cp "$repo/compose.remote.yaml" "$FAKE/egress/"

rreset remote_daemon_down
touch "$FAKE/daemon_down"
rbootstrap --docker-host "$TGT"
check remote_daemon_down "exit $rc: $(err)" \
  "$(st is "$rc $(err)" "2 egress-install: Docker on $TGT is not running or not reachable (docker version failed); nothing was changed")"

exit "$status"
