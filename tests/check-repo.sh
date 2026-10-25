#!/usr/bin/env bash
# Repo lint (CI `lint` job): no reference to the sibling repos outside the docs (NFR-3),
# every base image and action pinned, no keychain or platform-TLS crates in the gateway,
# and the docs and the Dockerfile agreeing with the files they describe.
# Prints `ok <check>` or `FAIL <check>: <detail>`; exits 1 if any check fails.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
ok() { echo "ok $1"; }
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  status=1
}

# none_found <check> <search command...>: the search (grep-like: 0 found, 1 none, other
# exit = error) finds nothing.
none_found() {
  local name=$1 hits rc=0
  shift
  hits=$("$@") || rc=$?
  case $rc in
    0) fail "$name" "$hits" ;;
    1) ok "$name" ;;
    *) fail "$name" "$1 exited $rc" ;;
  esac
}

# The two names, assembled from pieces so this file does not match itself.
a=ensem b=ble c=mini d=-op
none_found no_sibling_repo_refs git grep -nIiE "${a}${b}|${c}${d}" -- . ':!docs/' ':!README.md'

# Every FROM names an earlier stage or an image pinned by digest. A FROM using
# ${TARGETARCH} must name a stage for each architecture the Dockerfile supports.
if unpinned=$(awk '
  toupper($1) == "FROM" {
    image = $2
    # "@sha256:" and 64 hex digits; no {64}: mawk has no interval expressions.
    if ((match(image, /@sha256:[0-9a-f]+$/) && RLENGTH == 72) || (image in stage)) ok = 1
    else if (index(image, "${TARGETARCH}")) {
      amd = image; arm = image
      sub(/\$\{TARGETARCH\}/, "amd64", amd); sub(/\$\{TARGETARCH\}/, "arm64", arm)
      ok = (amd in stage) && (arm in stage)
    } else ok = 0
    if (!ok) print FILENAME ":" FNR ": " $0
    if (toupper($3) == "AS") stage[$4] = 1
  }' Dockerfile) && [[ -z $unpinned ]]; then
  ok from_pinned
else
  fail from_pinned "${unpinned:-cannot read Dockerfile}"
fi

none_found no_syntax_directive grep -niE '^#[[:space:]]*syntax[[:space:]]*=' Dockerfile

# Every `uses:` in a workflow is pinned to a full commit SHA.
unpinned=""
for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
  [[ -f $wf ]] || continue
  unpinned+=$(grep -nE '^[[:space:]-]*uses:' "$wf" | grep -vE 'uses:[[:space:]]*[^[:space:]@]+@[0-9a-f]{40}([[:space:]]|$)' | sed "s|^|$wf:|" || true)
done
if [[ -n $unpinned ]]; then
  fail uses_pinned "$unpinned"
else
  ok uses_pinned
fi

# Tests must never reach the macOS keychain or Security API: no crate that links them.
none_found no_keychain_crates grep -nE '^name = "(security-framework|security-framework-sys|native-tls|keyring|rustls-platform-verifier)"$' gateway/Cargo.lock

# The image builds the entrypoint with the toolchain CI tests it with.
channel=$(sed -nE 's/^channel = "([^"]+)"$/\1/p' rust-toolchain.toml)
if [[ -n $channel ]] && grep -qE "^FROM rust:${channel//./\\.}-" Dockerfile; then
  ok rust_version_matches
else
  fail rust_version_matches "Dockerfile's rust image is not rust-toolchain.toml's channel '${channel}'"
fi

# Every label compose.yaml sets is documented in the label contract, with its value
# (per-network labels with <key> in place of the network key; an alias value is skipped).
missing=""
while read -r key value; do
  doc_key=$(sed -E 's/^windroc\.egress\.network\.[a-z0-9-]+\./windroc.egress.network.<key>./' <<<"$key")
  value=${value#\"}
  value=${value%\"}
  grep -qF "\`$doc_key\`" docs/label-contract.md || missing+="$key (as $doc_key); "
  [[ $value == \** ]] || grep -qF "\`$value\`" docs/label-contract.md || missing+="$key value $value; "
done < <(sed -nE 's/^[[:space:]]+(windroc\.egress\.[^:]+):[[:space:]]*(.*)$/\1 \2/p' compose.yaml)
if [[ -n $missing ]]; then
  fail labels_documented "$missing"
else
  ok labels_documented
fi

exit "$status"
