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
cat >"$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "EGRESS_IMAGE=${EGRESS_IMAGE:-} $*" >>"$FAKE/calls"
block() {
  : >"$FAKE/blocked"
  read -r _ <"$FAKE/hold" || true
  exit 1
}
# or <name> <default>: the scenario file $FAKE/<name>, else <default>.
or() { cat "$FAKE/$1" 2>/dev/null || echo "$2"; }
# of <name> <image>: the scenario file name for <image>: <name>.<digest> if it exists.
of() { if [[ -e $FAKE/$1.${2##*@} ]]; then echo "$1.${2##*@}"; else echo "$1"; fi; }
case $1 in
  images)
    case ${!#} in
      egress-proxy | egress-proxy-proxy | egress-gateway) or "legacy.${!#}" "" ;;
      *) or images "" ;;
    esac
    ;;
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
        '{{.Id}}') echo "sha256:id-$5" ;;
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
  version) [[ ! -f $FAKE/daemon_down ]] || exit 1 ;;
  create)
    echo "$4" >"$FAKE/created"
    echo cid1
    ;;
  logs) or logs "" ;;
  cp)
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
for f in start.sh verify-egress compose.yaml config.example.yaml config.default.yaml install.sh egress-install; do
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
    "$FAKE"/legacy.* "$FAKE/in_use" "$FAKE/old_start" "$FAKE/old_start_rc"
  rm -rf "$FAKE"/egress.*
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
# (image egress-proxy), or exits $FAKE/old_start_rc.
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
if ((rc == 0)); then echo egress-proxy >"$FAKE/running"; fi
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
install 1.1.0 b
bad=""
is "$rc" 0 || bad+="exit $rc; "
is "$(top)" "$LAYOUT" || bad+="top: $(top); "
is "$(config_id)" "$conf" || bad+="config changed; "
is "$(grep -cxF "$(migrated_line 0)" "$work/out" || true)" 1 || bad+="no migrated line; "
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
check bs_usage "exit $rc: $(err)" "$(st is "$rc $(err)" "2 usage: egress-install --version X.Y.Z --digest sha256:<64 hex> [--dir <path>]")"
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

exit "$status"
