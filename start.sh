#!/usr/bin/env bash
# The egress proxy's start command: start, upgrade, or apply a config change (an added or
# removed caller network, or a policy edit). Idempotent: with the same checkout and config
# it changes nothing and restarts nothing.
#
# The config's sections are the only list of caller networks. Compose cannot read them, so
# this renders a compose override from them with the proxy image itself (`proxy
# compose`, which validates the config) and starts compose with it. The override lives next
# to the config, outside the checkout, so another egress version renders the same networks.
#
# Exit codes: 0 started; 2 no config or a config error (the error names the network and
# key); any other: the failing docker command's. On a config error the override and the
# running proxy are left as they were; an upgrade removes the old project's container
# before `up`, so a failing `up` leaves no proxy running.
set -euo pipefail

repo=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
config_dir=${EGRESS_CONFIG_DIR:-$HOME/.egress}

if [[ ! -f $config_dir/config.local.yaml ]]; then
  echo "start.sh: $config_dir/config.local.yaml not found; copy config.example.yaml there (README.md)" >&2
  exit 2
fi
# Absolute: compose.yaml mounts this directory, and compose resolves a relative path
# against the project directory, not ours.
config_dir=$(CDPATH='' cd -- "$config_dir" && pwd)
export EGRESS_CONFIG_DIR=$config_dir
override=$config_dir/compose.networks.yaml

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

# An install from before the rename to proxy runs as compose project egress, which this
# project does not manage: remove its container before this one starts, since two
# containers holding one alias would make the new one resolve the old one's address and
# exit. The caller networks stay.
old=$(docker ps -aq --filter label=com.docker.compose.project=egress --filter label=windroc.egress.contract)
if [[ -n $old ]]; then
  echo "start.sh: removing the proxy container of the old compose project egress" >&2
  # A read loop, not mapfile: the Mac's bash is 3.2.
  while read -r id; do
    docker rm -f "$id" >/dev/null
  done <<<"$old"
fi

"${base[@]}" -f "$override" up -d

# A policy edit within the sections changes no compose file, so compose keeps the running
# container: restart it when its running policy differs from the config (`proxy drift`
# exits 3). A container compose just created or started reads this config itself.
rc=0
"${base[@]}" -f "$override" exec -T proxy /proxy drift >/dev/null 2>&1 || rc=$?
if ((rc == 3)); then
  echo "start.sh: the running policy differs from the config; restarting the proxy" >&2
  "${base[@]}" -f "$override" restart proxy
fi
