#!/usr/bin/env bash
# Repo lint (CI `lint` job): no reference to the sibling repos outside the docs (NFR-3),
# every base image and action pinned, no keychain or platform-TLS crates in the proxy,
# and the docs and the Dockerfile agreeing with the files they describe (labels, worker
# tool rows).
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

# The two names, assembled from pieces so this file does not match itself. The bare
# `mini-op` is a caller network key; its repo, paths and container names are references.
a=ensem b=ble c=mini d=-op
none_found no_sibling_repo_refs git grep -nIiE "${a}${b}|/${c}${d}|${c}${d}/|${c}${d}-(net|proxy)" -- . ':!docs/' ':!README.md'

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
none_found no_keychain_crates grep -nE '^name = "(security-framework|security-framework-sys|native-tls|keyring|rustls-platform-verifier)"$' proxy/Cargo.lock

# The image builds the entrypoint with the toolchain CI tests it with.
channel=$(sed -nE 's/^channel = "([^"]+)"$/\1/p' rust-toolchain.toml)
if [[ -n $channel ]] && grep -qE "^FROM rust:${channel//./\\.}-" Dockerfile; then
  ok rust_version_matches
else
  fail rust_version_matches "Dockerfile's rust image is not rust-toolchain.toml's channel '${channel}'"
fi

# Every label compose.yaml sets is documented in the label contract, with its value
# (per-network labels with <key> in place of the network key; an alias value is skipped).
missing="" found=0
while read -r key value; do
  found=$((found + 1))
  doc_key=$(sed -E 's/^windroc\.egress\.network\.[a-z0-9-]+\./windroc.egress.network.<key>./' <<<"$key")
  value=${value#\"}
  value=${value%\"}
  grep -qF "\`$doc_key\`" docs/label-contract.md || missing+="$key (as $doc_key); "
  [[ $value == \** ]] || grep -qF "\`$value\`" docs/label-contract.md || missing+="$key value $value; "
done < <(sed -nE 's/^[[:space:]]+(windroc\.egress\.[^:]+):[[:space:]]*(.*)$/\1 \2/p' compose.yaml)
if ((found == 0)); then
  fail labels_documented "no windroc.egress.* labels found in compose.yaml"
elif [[ -n $missing ]]; then
  fail labels_documented "$missing"
else
  ok labels_documented
fi

# The worker tool rows in verify-egress (`row '<tool>' <expected> [reach]` lines) and the
# Results table in docs/worker-tools.md list the same tools with the same expected
# results, in the same order.
script_rows=$(sed -nE "s/^row '(.+)' (works|fails|unknown)( reach)?$/\1|\2/p" verify-egress 2>/dev/null || true)
doc_rows=$(sed -nE '/^## Results/,$ s/^\| ([^|]+) \| (works|fails|unknown) \|.*/\1|\2/p' docs/worker-tools.md 2>/dev/null || true)
if [[ -z $script_rows ]]; then
  fail tool_rows_documented "no row lines in verify-egress"
elif [[ $script_rows == "$doc_rows" ]]; then
  ok tool_rows_documented
else
  n=0 detail=""
  while true; do
    n=$((n + 1))
    s=$(sed -n "${n}p" <<<"$script_rows")
    d=$(sed -n "${n}p" <<<"$doc_rows")
    if [[ $s != "$d" ]]; then
      detail="row $n: verify-egress '${s:-none}', docs/worker-tools.md '${d:-none}'"
      break
    fi
  done
  fail tool_rows_documented "$detail"
fi

exit "$status"
