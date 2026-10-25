#!/usr/bin/env bash
# Self-test of tests/check-repo.sh (CI `lint` job): runs the unmodified script on copies of
# this repo's tracked files, so its failure paths are checked, not only its `ok` path.
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

# tree <name>: a fresh git tree holding a copy of every tracked file; prints its path.
tree() {
  local dir=$work/$1
  mkdir -p "$dir"
  git -C "$repo" ls-files -z | (cd "$repo" && xargs -0 cp --parents -t "$dir")
  git -C "$dir" init -q
  echo "$dir"
}

# run_check <dir>: check-repo.sh's output, then its exit code on the last line.
run_check() {
  local rc=0 out
  out=$(git -C "$1" add -A && "$1/tests/check-repo.sh" 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$out" "$rc"
}

# expect_only_failure <case> <dir> <FAIL line>: that line is the only failure, exit 1.
expect_only_failure() {
  local out
  out=$(run_check "$2")
  if ! grep -qxF "$3" <<<"$out"; then
    fail "$1" "no '$3' in: $out"
  elif [[ $(grep -c '^FAIL ' <<<"$out") != 1 ]]; then
    fail "$1" "other checks failed too: $out"
  elif [[ $(tail -n 1 <<<"$out") != exit=1 ]]; then
    fail "$1" "want exit 1: $out"
  else
    ok "$1"
  fi
}

# The unchanged copy passes, so the cases below fail only for what they change.
out=$(run_check "$(tree control)")
if [[ $(tail -n 1 <<<"$out") == exit=0 ]]; then ok control; else fail control "$out"; fi

dir=$(tree no_labels)
grep -v 'windroc\.egress\.' "$repo/compose.yaml" >"$dir/compose.yaml"
expect_only_failure no_labels "$dir" "FAIL labels_documented: no windroc.egress.* labels found in compose.yaml"

dir=$(tree no_compose)
rm "$dir/compose.yaml"
expect_only_failure no_compose "$dir" "FAIL labels_documented: no windroc.egress.* labels found in compose.yaml"

exit "$status"
