#!/usr/bin/env bash
# Self-test of the install entry, egress-install, and the installer, install.sh (CI `lint`
# job): runs the unmodified scripts, and the start.sh the installer installs, against a
# fake `docker` and `gh` (and fake `chmod`, `mv` and `sleep` that only add the hooks the kill
# tests need) on PATH, so no Docker daemon, registry or credential is ever reached:
# DOCKER_HOST points at a socket that does not exist.
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
export FAKE=$work/fake
mkdir -p "$work/bin" "$work/fast" "$DOCKER_CONFIG" "$FAKE"
mkfifo "$FAKE/hold"
REAL_CP=$(command -v cp)
REAL_CHMOD=$(command -v chmod)
REAL_MV=$(command -v mv)
export REAL_CP REAL_CHMOD REAL_MV

# The fake docker. State and scenario live in $FAKE:
#   calls          every call, with the EGRESS_IMAGE it saw
#   label          the image's org.opencontainers.image.version label (none: <no value>)
#   running        the image `compose up` last started (what inspect reports)
#   health         the container's health (default healthy)
#   up_fails       `compose up` fails
#   block_start    start.sh's first docker call blocks on the hold fifo
#   image_missing  `image inspect` of the image fails, until a pull succeeds
#   pull_err       the pull fails with this error; pull_config, helper_out and
#                  token_files record its client config, what the credential helper
#                  answered and the files under TMPDIR holding the token
#   egress/        the image's /egress, as `docker cp` copies it
#   daemon_down    `docker version` fails (no daemon)
#   cp_fails       `docker cp` fails
cat >"$work/bin/docker" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
echo "EGRESS_IMAGE=${EGRESS_IMAGE:-} $*" >>"$FAKE/calls"
block() {
  : >"$FAKE/blocked"
  read -r _ <"$FAKE/hold" || true
  exit 1
}
case $1 in
  image)
    [[ ! -f $FAKE/image_missing ]] || exit 1
    if [[ $3 == --format ]]; then
      cat "$FAKE/label" 2>/dev/null || echo "<no value>"
    elif [[ -f $FAKE/block_start ]]; then
      block
    fi
    ;;
  inspect)
    [[ -f $FAKE/running ]] || exit 1
    printf '%s\n%s\n' "$(cat "$FAKE/health" 2>/dev/null || echo healthy)" "$(cat "$FAKE/running")"
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
  create) echo cid1 ;;
  cp)
    if [[ -f $FAKE/cp_fails ]]; then
      echo "Error response from daemon: write $3/install.sh: no space left on device" >&2
      exit 1
    fi
    "$REAL_CP" -R "$FAKE/egress/." "$3"
    ;;
  context) echo my-context ;;
  compose)
    if [[ " $* " == *" up "* ]]; then
      [[ ! -f $FAKE/up_fails ]] || exit 1
      echo "$EGRESS_IMAGE" >"$FAKE/running"
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
  rm -f "$FAKE/running" "$FAKE/health" "$FAKE/up_fails" "$FAKE/calls"
}
out() { cat "$work/out"; }
tree() { (cd "$dir" && find . -exec ls -ld {} + | sort) 2>/dev/null || true; }
record() { sed -n "s/^$1=//p" "$dir/state/installed"; }
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
is "$got" "README.md config.example.yaml config.local.yaml start.sh state verify-egress" || bad+="top level: $got; "
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
  "$(st is "$(cat "$dir/state/runtime/image") $(cat "$FAKE/running")" "$(image a) $(image a)")"
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
  state/runtime/egress-install state/runtime/install.sh state/installed state/compose.networks.yaml; do
  head=$(sed -n '1,8p' "$dir/$f")
  for want in "$dir/$f: " "enerated by" "do not edit" "config.local.yaml"; do
    like "$head" "$want" || bad+="$f lacks '$want'; "
  done
done
for f in start.sh verify-egress state/runtime/egress-install state/runtime/install.sh; do
  is "$(sed -n 1p "$dir/$f")" '#!/usr/bin/env bash' || bad+="$f: the #! line is not first; "
done
like "$(sed -n 1p "$dir/README.md")" "<!-- " || bad+="README.md does not start with an HTML comment"
check headers "$bad" "$(st is "$bad" "")"
check readme_version "$(head -5 "$dir/README.md")" \
  "$(st grep -qF "egress-proxy 1.0.0, image \`$(image a)\`" "$dir/README.md")"

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

# -------- Failures --------
cp "$dir/state/installed" "$work/record.before"
echo starting >"$FAKE/health"
install 1.3.0 d
check not_healthy "exit $rc: $(out)" "$(st like "$rc $(out)" \
  "6 install.sh: egress-proxy 1.3.0 ($(digest d)) did not become healthy within 120 s; see docker logs egress-proxy")"
cmp -s "$dir/state/installed" "$work/record.before" || fail not_healthy "the state record changed"
# Until S5's rollback, the new set stays active.
is "$(cat "$dir/state/runtime/version")" 1.3.0 || fail not_healthy "the active set is $(cat "$dir/state/runtime/version")"
rm -f "$FAKE/health"

touch "$FAKE/up_fails"
install 1.3.0 d
check start_fails "exit $rc: $(out)" \
  "$(st like "$rc $(out)" "7 install.sh: the start command failed (exit 1) for egress-proxy 1.3.0")"
cmp -s "$dir/state/installed" "$work/record.before" || fail start_fails "the state record changed"
rm -f "$FAKE/up_fails"

fresh format
install 1.0.0 a
sed 's/^format=1$/format=2/' "$dir/state/installed" >"$work/record.2"
cp "$work/record.2" "$dir/state/installed"
before=$(tree)
install 1.1.0 b
check format_higher "exit $rc: $(out)" \
  "$(st like "$rc $(out)" "1 install.sh: $dir/state/installed has format 2; this installer knows format 1; nothing was changed")"
is "$(tree)" "$before" || fail format_higher "$dir changed"

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
  v=$(cat "$dir/state/runtime/version")
  like " $* " " $v " || echo "active version $v"
  for f in $LINKS; do
    [[ -f $dir/$f && $(readlink "$dir/$f") == "state/runtime/$f" ]] || echo "$f does not resolve into state/runtime"
  done
  grep -qF "egress-proxy $v, image" "$dir/README.md" || echo "README.md is not version $v's"
  grep -qF "for version $v " "$dir/start.sh" || echo "start.sh is not version $v's"
  rm -f "$FAKE/running"
  if ! PATH="$work/bin:$PATH" "$dir/start.sh" >"$work/start.out" 2>&1; then
    echo "start.sh failed: $(cat "$work/start.out")"
  elif ! is "$(cat "$FAKE/running")" "$(cat "$dir/state/runtime/image")"; then
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
  is "$rc $(cat "$dir/state/runtime/version") $(record current_version)" "0 1.1.0 1.1.0" ||
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
