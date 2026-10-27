#!/usr/bin/env bash
# tests/install-integration.sh <image repo> <version> <digest> <registry container>
#
# End-to-end check of the install entry (CI `image` job, after it published the image to
# its local registry): egress-install installs that image by digest into a temp directory,
# with real Docker, a throwaway Docker client config and no gh login. A docker shim logs
# every call and refuses any build. <registry container> is the registry's container,
# stopped to take the registry offline, then started again for the upgrades: images built
# FROM the installed one with other version labels, one never healthy, pushed there. Last,
# a source-checkout install (the v0.5.0 layout) migrates, once rolled back, once for good.
# Linux CI only: it starts the proxy and its networks. Prints `ok <check>` per check and
# stops at the first `FAIL <check>: <detail>`.
set -euo pipefail

if [[ $(uname -s) != Linux ]]; then
  echo "install-integration.sh: runs on Linux CI only" >&2
  exit 2
fi
if (($# != 4)); then
  echo "usage: tests/install-integration.sh <image repo> <version> <digest> <registry container>" >&2
  exit 2
fi
repo=$(cd "$(dirname "$0")/.." && pwd)
image_repo=$1 version=$2 digest=$3 registry=$4
image=$image_repo@$digest
PX=egress-proxy

work=$(mktemp -d)
dir=$work/egress
export TMPDIR=$work/tmp
mkdir -p "$TMPDIR" "$work/bin" "$work/docker"
# A throwaway Docker client config: no credsStore, credHelpers or stored login.
export DOCKER_CONFIG=$work/docker
echo '{}' >"$DOCKER_CONFIG/config.json"
real_docker=$(command -v docker)
# The shim: logs every call; any build fails the run, but the source checkout's own (its
# start.sh builds from its directory under $work/legacy).
cat >"$work/bin/docker" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$work/docker.log"
case " \$* " in
  *" --project-directory $work/legacy/current "* | *" --project-directory $work/legacy/versions/"*) ;;
  *" build "* | *" buildx "*)
    echo "install-integration.sh: a build ran: docker \$*" >&2
    exit 99
    ;;
esac
exec "$real_docker" "\$@"
EOF
# No gh login on this machine.
printf '#!/usr/bin/env bash\necho "gh: not logged in" >&2\nexit 1\n' >"$work/bin/gh"
chmod +x "$work/bin/docker" "$work/bin/gh"
export PATH=$work/bin:$PATH
export EGRESS_IMAGE_REPO=$image_repo

cleanup() {
  local code=$?
  if ((code != 0)); then
    echo "--- docker inspect $PX .State"
    "$real_docker" inspect --format '{{json .State}}' "$PX" 2>&1 || true
    echo "--- docker logs $PX (last 50 lines)"
    "$real_docker" logs --tail 50 "$PX" 2>&1 || true
  fi
  "$real_docker" rm -f "$PX" egress-test-caller egress-test-gateway >/dev/null 2>&1 || true
  "$real_docker" network rm egress-workers egress-uplink >/dev/null 2>&1 || true
  "$real_docker" start "$registry" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

ok() { echo "ok $1"; }
fail() {
  printf 'FAIL %s: %s\n' "$1" "$2"
  exit 1
}
inspect() { docker inspect --format "$1" "$PX"; }
# wait_health: up to 120 s for the proxy to be healthy.
wait_health() {
  local i
  for ((i = 0; i < 60; i++)); do
    [[ $(inspect '{{.State.Health.Status}}' 2>/dev/null) == healthy ]] && return 0
    sleep 2
  done
  return 1
}
# tree: every path under the install with its type, size and checksum.
tree() {
  (cd "$dir" && find . | sort | while read -r p; do
    if [[ -L $p ]]; then
      echo "$p -> $(readlink "$p")"
    elif [[ -f $p ]]; then
      echo "$p $(cksum <"$p")"
    else
      echo "$p/"
    fi
  done)
}

# NFR-1: the version's tag now names another image; only the digest decides.
other=$(docker inspect --format '{{.Image}}' "$registry")
docker tag "$other" "$image_repo:$version"
docker push -q "$image_repo:$version" >/dev/null
docker image rm "$image_repo:$version" >/dev/null
docker image rm "$image" >/dev/null 2>&1 || true
docker image inspect "$image" >/dev/null 2>&1 && fail tag_moved "$image is still on this machine"

rc=0
"$repo/egress-install" --version "$version" --digest "$digest" --dir "$dir" || rc=$?
((rc == 0)) || fail install_pulls "egress-install exited $rc"
grep -qxF "pull -q $image" "$work/docker.log" || fail install_pulls "no pull of $image: $(grep pull "$work/docker.log" || true)"
grep -E "^pull .*:$version\$" "$work/docker.log" && fail tag_moved "pulled by tag"
ok install_pulls

[[ $(inspect '{{.Config.Image}}') == "$image" ]] || fail container_image "$PX runs $(inspect '{{.Config.Image}}')"
[[ $(inspect '{{.State.Health.Status}}') == healthy ]] || fail container_image "$PX is $(inspect '{{.State.Health.Status}}')"
ok container_image
[[ $(inspect '{{index .Config.Labels "org.opencontainers.image.version"}}') == "$version" ]] ||
  fail tag_moved "$PX runs version $(inspect '{{index .Config.Labels "org.opencontainers.image.version"}}')"
ok tag_moved

for want in "current_version=$version" "current_digest=$digest" "current_image=$image"; do
  grep -qxF "$want" "$dir/state/installed" || fail state_record "no $want: $(cat "$dir/state/installed")"
done
ok state_record

got=$(cd "$dir" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort | xargs)
[[ $got == "README.md config.example.yaml config.local.yaml effective-policy.txt start.sh state verify-egress" ]] || fail layout "$got"
got=$(find "$dir" \( -name '*.rs' -o -name Dockerfile -o -name Cargo.toml -o -name Cargo.lock -o -name tests -o -name proxy -o -name .github \) -print)
[[ -z $got ]] || fail layout "source files: $got"
grep -q "egress-proxy $version, image \`$image\`" "$dir/README.md" || fail layout "README.md: $(head -5 "$dir/README.md")"
ok layout

# FR-17, FR-18: the installed start.sh wrote the rules in effect, naming this version.
grep -qF "for egress-proxy $version (image $image);" "$dir/effective-policy.txt" ||
  fail rules_file "$(sed -n 2p "$dir/effective-policy.txt")"
grep -q '^network workers ' "$dir/effective-policy.txt" || fail rules_file "$(cat "$dir/effective-policy.txt")"
ok rules_file

# FR-7: a config change applied by the start command: no build, the same image.
started=$(inspect '{{.State.StartedAt}}')
printf '    deny_ranges: [198.51.100.0/24]\n' >>"$dir/config.local.yaml"
"$dir/start.sh"
[[ $(inspect '{{.State.StartedAt}}') != "$started" ]] || fail config_change "start.sh did not apply the change"
wait_health || fail config_change "not healthy after the change"
[[ $(inspect '{{.Config.Image}}') == "$image" ]] || fail config_change "$PX runs $(inspect '{{.Config.Image}}')"
grep -qxF '    198.51.100.0/24' "$dir/effective-policy.txt" || fail config_change "the rules file lacks the new deny range"
ok config_change
grep -E '(^| )(build|buildx)( |$)' "$work/docker.log" && fail no_build "a build ran"
ok no_build

# FR-13: the registry offline, no gh login: reinstalling the same version works.
docker stop "$registry" >/dev/null
pulls=$(grep -c '^pull ' "$work/docker.log" || true)
rc=0
"$repo/egress-install" --version "$version" --digest "$digest" --dir "$dir" || rc=$?
((rc == 0)) || fail offline_reinstall "egress-install exited $rc"
[[ $(grep -c '^pull ' "$work/docker.log" || true) == "$pulls" ]] || fail offline_reinstall "it pulled"
wait_health || fail offline_reinstall "not healthy"
[[ $(inspect '{{.Config.Image}}') == "$image" ]] || fail offline_reinstall "$PX runs $(inspect '{{.Config.Image}}')"
ok offline_reinstall

# FR-14: another digest, with the registry offline: nothing changes.
absent=sha256:$(printf '%064d' 1)
before=$(tree)
running=$(inspect '{{.Id}} {{.State.StartedAt}}')
rc=0
err=$("$repo/egress-install" --version "$version" --digest "$absent" --dir "$dir" 2>&1) || rc=$?
((rc == 4)) || fail pull_fails_unchanged "egress-install exited $rc: $err"
[[ $err == *"cannot pull $image_repo@$absent from registry ${image_repo%%/*}"* && $err == *"keeps running"* ]] ||
  fail pull_fails_unchanged "$err"
[[ $(tree) == "$before" ]] || fail pull_fails_unchanged "$dir changed"
[[ $(inspect '{{.Id}} {{.State.StartedAt}}') == "$running" ]] || fail pull_fails_unchanged "the proxy changed"
[[ $(inspect '{{.State.Health.Status}}') == healthy ]] || fail pull_fails_unchanged "the proxy is not healthy"
[[ -z $(find "$TMPDIR" -mindepth 1 -print) ]] || fail pull_fails_unchanged "temp files left: $(find "$TMPDIR" -mindepth 1)"
ok pull_fails_unchanged

# -------- Upgrades: old images, no downgrade, rollback (FR-9, FR-10, FR-12) --------
docker start "$registry" >/dev/null
for ((i = 0; i < 30; i++)); do
  curl -sf "http://${image_repo%%/*}/v2/" >/dev/null && break
  sleep 1
done
# derive <version> [unhealthy]: pushes an image built FROM the installed one, with version
# label <version> (unhealthy: and a health check that always fails), then removes it here,
# so an install pulls it by digest. Prints its digest. Built with the real docker (the
# shim refuses builds) on the docker-driver builder `default`: the job's buildx builder
# runs in a container, where localhost:5000 is not the registry, and keeps no images.
derive() {
  local ctx=$work/derive-$1 ref=$image_repo:$1 pushed
  mkdir -p "$ctx"
  {
    echo "FROM $image"
    echo "LABEL org.opencontainers.image.version=$1"
    if [[ ${2:-} == unhealthy ]]; then
      echo 'HEALTHCHECK --interval=2s --timeout=2s --start-period=0s --retries=1 CMD ["/proxy", "no-such-command"]'
    fi
  } >"$ctx/Dockerfile"
  "$real_docker" buildx build --builder default --load -q -t "$ref" "$ctx" >/dev/null
  "$real_docker" push -q "$ref" >/dev/null
  pushed=$("$real_docker" image inspect --format '{{index .RepoDigests 0}}' "$ref")
  "$real_docker" image rm "$ref" >/dev/null
  echo "${pushed#*@}"
}
d1=$(derive 0.0.1)
d2=$(derive 0.0.2)
d3=$(derive 0.0.3)
d4=$(derive 0.0.4 unhealthy)

# FR-10: three upgrades leave the current and the previous image.
for vd in "0.0.1 $d1" "0.0.2 $d2" "0.0.3 $d3"; do
  read -r v d <<<"$vd"
  rc=0
  "$repo/egress-install" --version "$v" --digest "$d" --dir "$dir" || rc=$?
  ((rc == 0)) || fail cleanup "the install of $v exited $rc"
done
[[ $(inspect '{{.Config.Image}}') == "$image_repo@$d3" ]] || fail cleanup "$PX runs $(inspect '{{.Config.Image}}')"
got=$(docker images --no-trunc --format '{{.ID}}' "$image_repo")
want=$(for d in "$d2" "$d3"; do docker image inspect --format '{{.Id}}' "$image_repo@$d"; done | sort | xargs)
[[ $(sort <<<"$got" | xargs) == "$want" ]] || fail cleanup "docker images $image_repo: $(docker images --digests "$image_repo")"
for d in versions current; do
  [[ ! -e $dir/$d && ! -L $dir/$d ]] || fail cleanup "$dir/$d exists"
done
ok cleanup

# FR-12: the running, healthy, published 0.0.3 is kept over 0.0.2.
running=$(inspect '{{.Id}} {{.State.StartedAt}}')
rc=0
out=$("$repo/egress-install" --version 0.0.2 --digest "$d2" --dir "$dir" 2>&1) || rc=$?
((rc == 0)) || fail keep_newer "egress-install exited $rc: $out"
[[ $out == *"kept the running egress-proxy 0.0.3 ($d3), newer than 0.0.2"* ]] || fail keep_newer "$out"
[[ $(inspect '{{.Id}} {{.State.StartedAt}}') == "$running" ]] || fail keep_newer "the proxy changed"
grep -qxF "current_digest=$d3" "$dir/state/installed" || fail keep_newer "$(cat "$dir/state/installed")"
ok keep_newer

# FR-9: 0.0.4 never becomes healthy: back to 0.0.3, healthy, and exit 11.
rc=0
out=$("$repo/egress-install" --version 0.0.4 --digest "$d4" --dir "$dir" 2>&1) || rc=$?
((rc == 11)) || fail rollback "egress-install exited $rc: $out"
[[ $out == *"egress-proxy 0.0.4 ($d4) did not become healthy within 120 s"* ]] || fail rollback "$out"
[[ $out == *"rolled back to egress-proxy 0.0.3 ($d3), which is healthy; egress-proxy 0.0.4 was not installed; see docker logs egress-proxy" ]] ||
  fail rollback "$out"
[[ $(inspect '{{.Config.Image}}') == "$image_repo@$d3" ]] || fail rollback "$PX runs $(inspect '{{.Config.Image}}')"
[[ $(inspect '{{.State.Health.Status}}') == healthy ]] || fail rollback "$PX is $(inspect '{{.State.Health.Status}}')"
grep -qxF "current_digest=$d3" "$dir/state/installed" || fail rollback "$(cat "$dir/state/installed")"
grep -qF "for egress-proxy 0.0.3 (image $image_repo@$d3);" "$dir/effective-policy.txt" ||
  fail rollback "$(sed -n 2p "$dir/effective-policy.txt")"
ok rollback

# -------- A source-checkout install: the migration (FR-11) --------
# The layout callers' installers made before the image (v0.5.0): the checkout of commit
# 122d7454 in versions/<commit>/, current linking to it, the config beside them, and the
# proxy built from the checkout by its start.sh. The stand-in checkout is
# tests/fixtures/v050-egress (that commit's start.sh and compose.yaml) with a Dockerfile
# FROM 0.0.3 in place of the Rust build, adding a layer of its own as a source build does:
# without one the build is 0.0.3's image, which the migrated proxy uses, and stays. Its
# builds run on the docker-driver builder, as derive's do.
export BUILDX_BUILDER=default
legacy=$work/legacy
commit=122d7454d738db4a9b7e0c4a89d2cfa5ff564339
checkout=$legacy/versions/$commit
mkdir -p "$checkout"
cp "$repo/tests/fixtures/v050-egress/start.sh" "$repo/tests/fixtures/v050-egress/compose.yaml" "$checkout/"
echo "$commit" >"$checkout/COMMIT"
printf 'FROM %s\nCOPY COMMIT /v050-commit\n' "$image_repo@$d3" >"$checkout/Dockerfile"
ln -s "$checkout" "$legacy/current"
# Readable by the proxy's user: Docker Desktop maps a 0600 file, Linux does not.
printf 'version: 1\nnetworks:\n  workers:\n    mode: denylist\n' >"$legacy/config.local.yaml"
chmod 0644 "$legacy/config.local.yaml"
conf=$(sha256sum "$legacy/config.local.yaml")
rc=0
EGRESS_CONFIG_DIR=$legacy bash "$legacy/current/start.sh" || rc=$?
((rc == 0)) || fail migrate "the source checkout's start.sh exited $rc"
wait_health || fail migrate "the source checkout's proxy is not healthy"
[[ $(inspect '{{.Config.Image}}') == egress-proxy ]] || fail migrate "$PX runs $(inspect '{{.Config.Image}}')"
# An older build's name for the same image, and an image of the old name egress-gateway
# that a (stopped) container uses.
docker tag egress-proxy egress-proxy-proxy
printf 'FROM %s\nCOPY gateway.Dockerfile /gateway\n' "$image_repo@$d3" >"$work/gateway.Dockerfile"
"$real_docker" buildx build --builder default --load -q -t egress-gateway -f "$work/gateway.Dockerfile" "$work" >/dev/null
docker create --name egress-test-gateway egress-gateway >/dev/null
# A caller on the workers network, attached before the migration, from the probe image
# verify-egress pins.
PROBE_IMAGE=$(sed -n 's/^PROBE_IMAGE=//p' "$repo/verify-egress")
[[ -n $PROBE_IMAGE ]] || fail migrate_callers "no PROBE_IMAGE line in verify-egress"
docker run -d --name egress-test-caller --network egress-workers --entrypoint sleep "$PROBE_IMAGE" 3600 >/dev/null
nets() { docker network inspect --format '{{.Id}}' egress-workers egress-uplink; }
nets_before=$(nets)
# caller_ok: the caller still runs, on egress-workers, which has the same ID.
caller_ok() {
  [[ $(docker inspect --format '{{.State.Running}} {{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' egress-test-caller) == "true egress-workers " &&
    $(nets) == "$nets_before" ]]
}
caller_ok || fail migrate_callers "the caller is not on egress-workers"

# 0.0.4 never becomes healthy: back to the checkout's start.sh, the old files kept.
rc=0
out=$("$repo/egress-install" --version 0.0.4 --digest "$d4" --dir "$legacy" 2>&1) || rc=$?
((rc == 11)) || fail migrate_rollback "egress-install exited $rc: $out"
[[ $out == *"install.sh: rolled back to the source-checkout install ($checkout/start.sh), which is healthy; egress-proxy 0.0.4 was not installed; see docker logs egress-proxy" ]] ||
  fail migrate_rollback "$out"
[[ $(inspect '{{.Config.Image}}') == egress-proxy && $(inspect '{{.State.Health.Status}}') == healthy ]] ||
  fail migrate_rollback "$PX runs $(inspect '{{.Config.Image}}'), $(inspect '{{.State.Health.Status}}')"
[[ $(readlink "$legacy/current") == "$checkout" && -f $checkout/start.sh && $(sha256sum "$legacy/config.local.yaml") == "$conf" ]] ||
  fail migrate_rollback "the source checkout changed: $(ls -la "$legacy")"
got=$(cd "$legacy" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort | xargs)
[[ $got == "compose.networks.yaml config.local.yaml current versions" ]] || fail migrate_rollback "$got"
caller_ok || fail migrate_rollback "the caller lost egress-workers"
ok migrate_rollback

# 0.0.3: the migration.
rc=0
out=$("$repo/egress-install" --version 0.0.3 --digest "$d3" --dir "$legacy" 2>&1) || rc=$?
((rc == 0)) || fail migrate "egress-install exited $rc: $out"
[[ $(inspect '{{.Config.Image}}') == "$image_repo@$d3" && $(inspect '{{.State.Health.Status}}') == healthy ]] ||
  fail migrate "$PX runs $(inspect '{{.Config.Image}}'), $(inspect '{{.State.Health.Status}}')"
[[ $(sha256sum "$legacy/config.local.yaml") == "$conf" ]] || fail migrate "the config changed"
got=$(cd "$legacy" && find . -mindepth 1 -maxdepth 1 | sed 's|^\./||' | sort | xargs)
[[ $got == "README.md config.example.yaml config.local.yaml effective-policy.txt start.sh state verify-egress" ]] ||
  fail migrate "$got"
[[ $out == *"install.sh: migrated the source-checkout install: removed $legacy/versions and $legacy/current and "*" locally built image(s); the start command is now $legacy/start.sh, not current/start.sh"* ]] ||
  fail migrate "$out"
ok migrate
[[ -z $(docker images -q egress-proxy) && -z $(docker images -q egress-proxy-proxy) ]] ||
  fail migrate_images "left: $(docker images egress-proxy) $(docker images egress-proxy-proxy)"
[[ -n $(docker images -q egress-gateway) ]] || fail migrate_images "egress-gateway, which a container uses, is gone"
ok migrate_images
caller_ok || fail migrate_callers "the caller lost egress-workers"
rc=0
"$legacy/verify-egress" workers || rc=$?
((rc == 0)) || fail migrate_callers "verify-egress workers exited $rc"
ok migrate_callers

echo "all checks passed"
