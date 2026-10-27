#!/usr/bin/env bash
# Self-test of the installer, install.sh (CI `lint` job): runs the unmodified script, and
# the start.sh it installs, against a fake `docker` (and fake `cp`, `mv` and `sleep`
# that only add the hooks the kill tests need) on PATH, so no Docker daemon, registry or
# credential is ever reached: DOCKER_HOST points at a socket that does not exist.
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
REAL_MV=$(command -v mv)
export REAL_CP REAL_MV

# The fake docker. State and scenario live in $FAKE:
#   calls          every call, with the EGRESS_IMAGE it saw
#   label          the image's org.opencontainers.image.version label (none: <no value>)
#   running        the image `compose up` last started (what inspect reports)
#   health         the container's health (default healthy)
#   up_fails       `compose up` fails
#   block_start    start.sh's first docker call blocks on the hold fifo
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
  compose)
    if [[ " $* " == *" up "* ]]; then
      [[ ! -f $FAKE/up_fails ]] || exit 1
      echo "$EGRESS_IMAGE" >"$FAKE/running"
    fi
    ;;
esac
exit 0
FAKE
# cp and mv: the real ones, unless the scenario blocks them (block_cp: every cp;
# block_mv: the rename of the new state/runtime link).
cat >"$work/bin/cp" <<'FAKE'
#!/usr/bin/env bash
if [[ -f $FAKE/block_cp ]]; then
  : >"$FAKE/blocked"
  read -r _ <"$FAKE/hold" || true
  exit 1
fi
exec "$REAL_CP" "$@"
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
# The installer's health wait polls 60 times, 2 s apart: no waiting here.
printf '#!/usr/bin/env bash\nexit 0\n' >"$work/fast/sleep"
chmod +x "$work/bin/docker" "$work/bin/cp" "$work/bin/mv" "$work/fast/sleep"

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
for f in README.md start.sh verify-egress config.example.yaml state/runtime/compose.yaml state/installed state/compose.networks.yaml; do
  head=$(sed -n '1,8p' "$dir/$f")
  for want in "$dir/$f: " "enerated by" "do not edit" "config.local.yaml"; do
    like "$head" "$want" || bad+="$f lacks '$want'; "
  done
done
is "$(sed -n 1p "$dir/start.sh")$(sed -n 1p "$dir/verify-egress")" '#!/usr/bin/env bash#!/usr/bin/env bash' ||
  bad+="a script's #! line is not first; "
like "$(sed -n 1p "$dir/README.md")" "<!-- " || bad+="README.md does not start with an HTML comment"
check headers "$bad" "$(st is "$bad" "")"
check readme_version "$(head -5 "$dir/README.md")" \
  "$(st grep -qF "egress-proxy 1.0.0, image \`$(image a)\`" "$dir/README.md")"

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
killed killed_mid_write block_cp
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

exit "$status"
