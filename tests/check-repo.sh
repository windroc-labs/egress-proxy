#!/usr/bin/env bash
# Repo lint (CI `lint` job): no reference to the sibling repos outside the docs (NFR-3),
# every base image and action pinned, no keychain or platform-TLS crates in the gateway.
# Prints `ok <check>` or `FAIL <check>: <detail>`; exits 1 if any check fails.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
ok() { echo "ok $1"; }
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  status=1
}

# The two names, assembled from pieces so this file does not match itself.
a=ensem b=ble c=mini d=-op
if hits=$(git grep -nIiE "${a}${b}|${c}${d}" -- . ':!docs/' ':!README.md'); then
  fail no_sibling_repo_refs "$hits"
else
  ok no_sibling_repo_refs
fi

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

if hits=$(grep -niE '^#[[:space:]]*syntax[[:space:]]*=' Dockerfile); then
  fail no_syntax_directive "$hits"
else
  ok no_syntax_directive
fi

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
if hits=$(grep -nE '^name = "(security-framework|security-framework-sys|native-tls|keyring|rustls-platform-verifier)"$' gateway/Cargo.lock); then
  fail no_keychain_crates "$hits"
else
  ok no_keychain_crates
fi

exit "$status"
