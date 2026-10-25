#!/usr/bin/env bash
# The egress gateway's start command: start, upgrade, or apply an added or removed caller
# network. Idempotent: with the same checkout and config it changes nothing.
#
# The config's sections are the only list of caller networks. Compose cannot read them, so
# this renders a compose override from them with the gateway image itself (`gateway
# compose`, which validates the config) and starts compose with it. The override lives next
# to the config, outside the checkout, so another egress version renders the same networks.
#
# Exit codes: 0 started; 2 no config or a config error (the error names the network and
# key); any other: the failing docker command's. On failure the override and the running
# gateway are left as they were.
set -euo pipefail

repo=$(cd "$(dirname "$0")" && pwd)
config_dir=${EGRESS_CONFIG_DIR:-$HOME/.egress}
# compose.yaml mounts this directory.
export EGRESS_CONFIG_DIR=$config_dir
override=$config_dir/compose.networks.yaml

if [[ ! -f $config_dir/config.local.yaml ]]; then
  echo "start.sh: $config_dir/config.local.yaml not found; copy config.example.yaml there (README.md)" >&2
  exit 2
fi

base=(docker compose --project-directory "$repo" -f "$repo/compose.yaml")

# Build first: when `up` builds the image itself, compose 2.38 leaves the container without
# its image label and recreates it on the next `up`.
"${base[@]}" build
image=$("${base[@]}" config --images)

tmp=$(mktemp "$config_dir/.compose.networks.XXXXXX")
trap 'rm -f "$tmp"' EXIT
docker run --rm --pull never --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true -v "$config_dir:/etc/egress:ro" \
  "$image" compose >"$tmp" || exit $?
mv "$tmp" "$override"

"${base[@]}" -f "$override" up -d
