#!/usr/bin/env bash
# The egress proxy's installer, shipped in the image as /egress/install.sh. Only
# egress-install runs it, from the files it copied out of the image (README.md, Setup):
#
#   install.sh --interface 1 --version X.Y.Z --digest sha256:<64 hex> --dir <dir>
#              --image <repo>@<digest> --files <dir of the image's /egress>
#
# It writes the image's runtime files to <dir> as one runtime set, writes the default
# config when there is none, runs the start command, waits for the proxy to be healthy and
# records the installed version. First it checks the running proxy (FR-12): one of
# another label contract stops the install; a healthy one of a higher version, published
# (pulled by the digest <dir>'s record names) and of the same contract is kept, not
# downgraded. A version that does not become healthy is rolled back (FR-9): the previous
# version's own install entry, state/<its runtime set>/egress-install, reinstalls it.
# After a successful install it removes the repo's images other than the current and the
# previous one (FR-10). Layout of <dir>:
#
#   config.local.yaml          the user's config; written once, never replaced
#   README.md, start.sh, verify-egress, config.example.yaml
#                              symlinks into state/runtime
#   state/runtime              symlink to the active runtime set, runtime.<suffix>
#   state/runtime.<suffix>/    one version's files; `links` lists the top-level names,
#                              `image`, `version` and `digest` (written last: the set is
#                              complete) name its image. These four have the generated-file
#                              header too: their values are their lines not starting with #
#   state/installed            the last healthy install: current and previous version,
#                              digest, image and runtime set (format 1)
#   state/compose.networks.yaml   start.sh's rendered override
#
# One rename of state/runtime switches every top-level runtime file at once, so a killed
# install leaves either the old set or the new one active, never a mix.
#
# Handoff contract, interface 1 (egress-install of any version drives this): every
# option takes exactly one value; later interfaces add only optional options; unknown
# options are ignored with a warning. EGRESS_INSTALL_ROLLBACK=1 in the environment (which
# egress-install passes on) marks a rollback: install the given version, newer running
# proxy or not; older installers ignore it.
#
# Exit codes, shared with egress-install; README.md's Setup lists the same codes in the
# same words (tests/install-selftest.sh compares them):
#   0   installed, or a newer, healthy running proxy kept instead of downgrading
#   1   another failure, e.g. the image's files could not be copied out, or
#       `state/installed` has a newer format
#   2   usage, or Docker is not running or not reachable
#   3   no access to the image: the message names the GitHub login and scope needed
#   4   the pull failed: the message names the image, digest and registry; the running
#       proxy keeps running
#   5   the image is not that version, has no contract label, or has no installer
#   6   the proxy was not healthy within 120 s (`docker logs egress-proxy`), with no
#       previous version to roll back to (or in a rollback): the version being installed
#       is left as it is
#   7   the start command failed, with no previous version to roll back to (or in a
#       rollback): the version being installed is left as it is
#   8   the installer does not know the `--interface` this `egress-install` speaks
#   9   the version being installed did not start or was not healthy, and the rollback to
#       the previous version (migrating a source-checkout install: to it, with its
#       start.sh) failed too
#   10  the running proxy serves another label contract: nothing was changed; the message
#       names both versions and contracts
#   11  the version being installed did not start or was not healthy; rolled back to the
#       previous version (migrating a source-checkout install: to it, with its start.sh),
#       which is healthy
#
# Runs on macOS's bash 3.2 and on Linux.
set -euo pipefail
# Bash 5.2 would expand & in ${x//pattern/replacement}; a path may hold one.
shopt -u patsub_replacement 2>/dev/null || true

usage() {
  echo "usage: install.sh --interface 1 --version X.Y.Z --digest sha256:<64 hex> --dir <path> --image <repo>@<digest> --files <dir>" >&2
  exit 2
}
die() {
  local code=$1
  shift
  echo "install.sh: $*" >&2
  exit "$code"
}

interface="" version="" digest="" dir="" image="" files=""
while (($# > 0)); do
  (($# >= 2)) || usage
  case $1 in
    --interface) interface=$2 ;;
    --version) version=$2 ;;
    --digest) digest=$2 ;;
    --dir) dir=$2 ;;
    --image) image=$2 ;;
    --files) files=$2 ;;
    --*) echo "install.sh: ignoring unknown option $1" >&2 ;;
    *) usage ;;
  esac
  shift 2
done
[[ -n $interface ]] || usage
[[ $interface == 1 ]] ||
  die 8 "interface $interface is not supported (supported: 1); use the egress-install of version ${version:-this image}"
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || usage
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || usage
[[ -n $dir && $image == *"@$digest" && -n $files ]] || usage

# The runtime set's files (each copied with a header) and its top-level links.
FILES="start.sh verify-egress config.example.yaml compose.yaml config.default.yaml egress-install install.sh"
LINKS="README.md start.sh verify-egress config.example.yaml"
for f in $FILES; do
  [[ -f $files/$f ]] || die 1 "$files/$f is missing"
done

# -------- Checks before any change --------
labels=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}|{{index .Config.Labels "io.windroc.egress-proxy.contract"}}' "$image" 2>/dev/null) ||
  labels=""
label=${labels%%|*} contract=""
[[ $labels == *'|'* ]] && contract=${labels#*|}
[[ $label == "<no value>" ]] && label=""
[[ $contract == "<no value>" ]] && contract=""
[[ $label == "$version" ]] || die 5 "$image is version ${label:-none}, not $version"
[[ -n $contract ]] || die 5 "$image has no label contract version (io.windroc.egress-proxy.contract)"

state=$dir/state
record=$state/installed
# record_get <key>: the value of <key> in the state record, or empty.
record_get() {
  [[ -f $record ]] || return 0
  sed -n "s/^$1=//p" "$record" | head -n 1
}
format=$(record_get format)
if [[ -n $format ]] && ! [[ $format =~ ^[0-9]+$ && $format -le 1 ]]; then
  die 1 "$record has format $format; this installer knows format 1; nothing was changed"
fi

# The last healthy install's digest, read once: nothing writes the record before Record.
cur_digest=$(record_get current_digest)
# The rollback target (FR-9): the last healthy install, unless it is this digest.
rb_version=$(record_get current_version)
rb_digest=$cur_digest
rb_image=$(record_get current_image)
rb_runtime=$(record_get current_runtime)
[[ $rb_digest != "$digest" ]] || rb_digest=""

# -------- A source-checkout install (FR-11) --------
# Callers' installers before the image (the v0.5.0 layout) kept source checkouts in
# versions/<commit>/ (and downloads in versions/.download.*), linked current to
# <dir>/versions/<commit>, and ran EGRESS_CONFIG_DIR=<dir> versions/<commit>/start.sh,
# which builds the image egress-proxy (earlier checkouts: egress-proxy-proxy,
# egress-gateway) and writes compose.networks.yaml here. Only that shape is migrated:
# anything else named current or versions is never deleted, followed or run.
hex40='^[0-9a-f]{40}$'
# checkout_signature: <dir>'s current and versions, whichever exist, are a source-checkout
# install's. Sets old_commit to current's commit when its checkout has a start.sh.
checkout_signature() {
  local e target commit real
  old_commit=""
  if [[ -e $dir/versions || -L $dir/versions ]]; then
    [[ -d $dir/versions && ! -L $dir/versions ]] || return 1
    for e in "$dir"/versions/* "$dir"/versions/.[!.]* "$dir"/versions/..?*; do
      [[ -e $e || -L $e ]] || continue
      [[ ${e##*/} == .download.* ]] && continue
      [[ ${e##*/} =~ $hex40 && -d $e && ! -L $e ]] || return 1
    done
  fi
  if [[ -e $dir/current || -L $dir/current ]]; then
    [[ -L $dir/current ]] || return 1
    target=$(readlink "$dir/current")
    commit=${target##*/}
    [[ $commit =~ $hex40 ]] || return 1
    real=$(CDPATH='' cd -P -- "$dir" && pwd)
    case $target in
      "$dir/versions/$commit" | "$real/versions/$commit" | "versions/$commit") ;;
      *) [[ -e $dir/current && $dir/current -ef $dir/versions/$commit ]] || return 1 ;;
    esac
    if [[ -d $dir/versions/$commit && ! -L $dir/versions/$commit &&
      -f $dir/versions/$commit/start.sh && ! -L $dir/versions/$commit/start.sh ]]; then
      old_commit=$commit
    fi
  fi
  return 0
}
# checkout: a source-checkout install is here; migrating: this install replaces it, with no
# image install recorded yet (a failure goes back to it); old_start: its start.sh, set
# once <dir> is absolute.
checkout="" migrating="" old_commit="" old_start=""
if [[ -e $dir/current || -L $dir/current || -e $dir/versions || -L $dir/versions ]]; then
  if checkout_signature; then
    checkout=yes
    if [[ -z $cur_digest && ${EGRESS_INSTALL_ROLLBACK:-} != 1 ]]; then migrating=yes; fi
  else
    old_commit="" found=""
    for e in current versions; do
      if [[ -e $dir/$e || -L $dir/$e ]]; then found+="${found:+ and }$dir/$e"; fi
    done
    echo "install.sh: left $found as found: not a source-checkout install"
  fi
fi

# -------- The running proxy (FR-12) --------
# A rollback installs the version it is given, so it skips this check: the newer version
# it replaces may have turned healthy late.
semver='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
# newer <a> <b>: version <a> is higher than version <b> (both X.Y.Z).
newer() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  ((a1 > b1 || (a1 == b1 && (a2 > b2 || (a2 == b2 && a3 > b3)))))
}
if [[ ${EGRESS_INSTALL_ROLLBACK:-} != 1 ]] &&
  running=$(docker inspect --format '{{.Image}}|{{.State.Running}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}|{{index .Config.Labels "windroc.egress.contract"}}' egress-proxy 2>/dev/null); then
  IFS='|' read -r r_id r_running r_health r_contract <<<"$running"
  [[ $r_contract == "<no value>" ]] && r_contract=""
  r_image=$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.version"}}|{{range .RepoDigests}}{{.}} {{end}}' "$r_id" 2>/dev/null) ||
    r_image=""
  r_version=${r_image%%|*} r_digests=""
  [[ $r_image == *'|'* ]] && r_digests=${r_image#*|}
  [[ $r_version == "<no value>" ]] && r_version=""
  if [[ -n $r_contract && $r_contract != "$contract" ]]; then
    die 10 "the running egress-proxy ${r_version:-unknown version} serves label contract $r_contract, and egress-proxy $version serves contract $contract; nothing was changed (to replace it: docker rm -f egress-proxy, then install again)"
  fi
  # Published: pulled by the digest this directory's record names. A RepoDigest alone is
  # not enough: Docker's containerd image store gives a retagged local build one too.
  if [[ $r_running == true && $r_health == healthy && $r_contract == "$contract" && -n $cur_digest && " $r_digests " == *" ${image%@*}@$cur_digest "* &&
    $r_version =~ $semver ]] && newer "$r_version" "$version"; then
    echo "install.sh: kept the running egress-proxy $r_version ($cur_digest), newer than $version; nothing was changed"
    exit 0
  fi
fi

# -------- The new runtime set --------
mkdir -p "$state"
dir=$(CDPATH='' cd -- "$dir" && pwd)
state=$dir/state
record=$state/installed
[[ -z $old_commit ]] || old_start=$dir/versions/$old_commit/start.sh

# Leftovers of a killed install: temp links, and incomplete sets other than the active one.
active=""
[[ -L $state/runtime ]] && active=$(readlink "$state/runtime")
rm -f "$state"/.runtime.tmp.* "$state"/.installed.tmp.* "$dir/.config.local.yaml.tmp."*
for f in $LINKS; do rm -f "$dir/.$f.tmp."*; done
for d in "$state"/runtime.*; do
  [[ -d $d && ! -L $d ]] || continue
  [[ ${d##*/} == "$active" || -f $d/digest ]] || rm -rf "$d"
done

new=$(mktemp -d "$state/runtime.XXXXXX")
chmod 0755 "$new"
base=${new##*/}

# header <comment prefix> <file name> <what it is>: the generated-file header.
header() {
  printf '%s %s/%s: %s\n' "$1" "$dir" "$2" "$3"
  printf '%s Generated by the egress-proxy installer for version %s (%s);\n' "$1" "$version" "$digest"
  printf '%s do not edit it: the next install replaces it. To change the policy, edit\n' "$1"
  printf '%s %s/config.local.yaml, then run %s/start.sh.\n' "$1" "$dir" "$dir"
}

# put <name> <what it is> [<path shown in the header>]: copies <name> from the image's
# files into the new set with a header, after its `#!` line if it has one.
put() {
  local src=$files/$1 dst=$new/$1 shown=${3:-$1} first=""
  IFS= read -r first <"$src" || true
  {
    if [[ $first == '#!'* ]]; then
      printf '%s\n' "$first"
      header '#' "$shown" "$2"
      tail -n +2 "$src"
    else
      header '#' "$shown" "$2"
      cat "$src"
    fi
  } >"$dst"
  chmod "$([[ -x $src ]] && echo 0755 || echo 0644)" "$dst"
}
put start.sh "the egress proxy's start command: starts the proxy, or applies a change of config.local.yaml"
put verify-egress "checks a caller network's allows and denies: verify-egress <network>"
put config.example.yaml "an example of config.local.yaml, with every option"
put compose.yaml "the proxy's compose file; start.sh runs it with the caller networks it renders" \
  state/runtime/compose.yaml
put config.default.yaml "the default config, copied to config.local.yaml when there is none" \
  state/runtime/config.default.yaml
put egress-install "the install entry of this version: reinstall or install another version with it" \
  state/runtime/egress-install
put install.sh "the installer of this version, run by egress-install" state/runtime/install.sh

# read -d '', not $(cat <<EOF): bash 3.2 misparses quotes in a here-document inside $(...).
IFS= read -r -d '' readme <<'EOF' || true
# @DIR@: the egress proxy

Installed: egress-proxy @VERSION@, image `@IMAGE@`.

The proxy runs as the container `egress-proxy` from that image, pinned by its digest; it
needs no network, GitHub login or registry to start or restart.

## Files

| File | What it is |
| --- | --- |
| `config.local.yaml` | The proxy's config, one section per caller network: the only file to edit. Run `start.sh` after a change. |
| `config.example.yaml` | Every config option, with examples. |
| `start.sh` | The start command: starts the proxy, or applies a change of `config.local.yaml`. |
| `verify-egress` | Checks a caller network's allows and denies from a probe container on it. |
| `effective-policy.txt` | The rules in effect per network, rewritten by `start.sh` at every start. |
| `README.md` | This file, rewritten at every install. |
| `state/` | The active runtime set (`state/runtime`), the compose files, the rendered network file and the installed versions and digests (`state/installed`). Never edit it. |

## Commands

| Task | Command |
| --- | --- |
| Start, or apply a config change | `@DIR@/start.sh` |
| Check a caller network | `@DIR@/verify-egress <network>` |
| Health | `docker inspect --format '{{.State.Health.Status}}' egress-proxy` |
| Logs (config errors name the network and key) | `docker logs egress-proxy` |
| Stop | `docker stop egress-proxy` |
| Reinstall, or install another version (exit 0 also when it keeps a newer, healthy running proxy instead of downgrading; exit 11 when the new version did not start or was not healthy and it rolled back to the previous one) | `@DIR@/state/runtime/egress-install --version X.Y.Z --digest sha256:<digest> --dir @DIR@` |

Install only a version and digest from the GitHub Release of its tag (or one a caller's
installer pins).
EOF
readme=${readme%$'\n'}
readme=${readme//@DIR@/$dir}
readme=${readme//@VERSION@/$version}
readme=${readme//@IMAGE@/$image}
{
  header '' README.md "what each file here is, the commands, and the installed version" |
    sed -e '1s/^ /<!-- /' -e '2,$s/^ /     /' -e '$s/$/ -->/'
  echo
  printf '%s\n' "$readme"
} >"$new/README.md"
chmod 0644 "$new/README.md"

{
  header '#' state/runtime/links "the top-level files that link into this runtime set, one per line"
  for f in $LINKS; do echo "$f"; done
} >"$new/links"
{
  header '#' state/runtime/image "the image this runtime set runs, pinned by its digest; start.sh runs it"
  printf '%s\n' "$image"
} >"$new/image"
{
  header '#' state/runtime/version "the egress-proxy version of this runtime set"
  printf '%s\n' "$version"
} >"$new/version"
# Last: a set with a digest file is complete.
{
  header '#' state/runtime/digest "the image digest of this runtime set; written last, it marks the set complete"
  printf '%s\n' "$digest"
} >"$new/digest"

# -------- Switch --------
# values <file>: a runtime set data file's values, its lines not starting with #.
values() { sed '/^#/d' "$1"; }
# replace <src> <dst>: renames <src> over <dst> in one rename(2), also when <dst> is a
# symlink to a directory (GNU mv -T, BSD mv -h).
replace() {
  if mv --version >/dev/null 2>&1; then
    mv -Tf "$1" "$2"
  else
    mv -hf "$1" "$2"
  fi
}
# link_top <name>: <dir>/<name> becomes the symlink state/runtime/<name>.
link_top() {
  local want=state/runtime/$1
  [[ -L $dir/$1 && $(readlink "$dir/$1") == "$want" ]] && return 0
  ln -s "$want" "$dir/.$1.tmp.$$"
  replace "$dir/.$1.tmp.$$" "$dir/$1"
}
old_links=""
[[ -n $active && -f $state/runtime/links ]] && old_links=$(values "$state/runtime/links")
new_links=$(values "$new/links")
# Names the active set also has resolve into whichever set is active: link them first.
for f in $LINKS; do
  if grep -qxF "$f" <<<"$old_links"; then link_top "$f"; fi
done
ln -s "$base" "$state/.runtime.tmp.$$"
replace "$state/.runtime.tmp.$$" "$state/runtime"
for f in $LINKS; do link_top "$f"; done
# A name only the old set had would now dangle.
for f in $old_links; do
  grep -qxF "$f" <<<"$new_links" && continue
  if [[ -L $dir/$f && $(readlink "$dir/$f") == state/runtime/* ]]; then rm -f "$dir/$f"; fi
done

# -------- Config, start, health --------
if [[ ! -e $dir/config.local.yaml && ! -L $dir/config.local.yaml ]]; then
  # The image's own copy: the one in the runtime set has the generated-file header.
  cp "$files/config.default.yaml" "$dir/.config.local.yaml.tmp.$$"
  # The proxy reads it as another user (UID 65532) through the read-only mount.
  chmod 0644 "$dir/.config.local.yaml.tmp.$$"
  mv "$dir/.config.local.yaml.tmp.$$" "$dir/config.local.yaml"
  echo "install.sh: wrote the default config $dir/config.local.yaml"
fi

# proxy_up <image> <same|other>: the proxy is healthy, has every label of the contract, and
# runs <image> (same) or any other image (other).
proxy_up() {
  local out health img labels nets k
  out=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{end}}
{{.Config.Image}}
{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}
{{end}}' egress-proxy 2>/dev/null) || return 1
  health=$(sed -n 1p <<<"$out")
  img=$(sed -n 2p <<<"$out")
  labels=$(sed -n '3,$p' <<<"$out")
  [[ $health == healthy ]] || return 1
  if [[ $2 == same ]]; then [[ $img == "$1" ]] || return 1; else [[ $img != "$1" ]] || return 1; fi
  grep -q '^windroc\.egress\.contract=.' <<<"$labels" || return 1
  nets=$(sed -n 's/^windroc\.egress\.networks=//p' <<<"$labels")
  [[ -n $nets ]] || return 1
  for k in ${nets//,/ }; do
    grep -qF "windroc.egress.network.$k.name=egress-" <<<"$labels" || return 1
    grep -qF "windroc.egress.network.$k.proxy=http" <<<"$labels" || return 1
  done
}
# healthy <image>: the proxy is up and runs <image>.
healthy() { proxy_up "$1" same; }
# old_healthy: the proxy is up and runs another image than this version's: a source
# checkout's local build.
old_healthy() { proxy_up "$image" other; }
# wait_healthy <check> [<args>...]: up to 120 s for the check to hold, polling every 2 s.
wait_healthy() {
  local i
  for ((i = 0; i < 60; i++)); do
    if "$@"; then return 0; fi
    sleep 2
  done
  return 1
}

# rollback_checkout: back to the source-checkout install this one was migrating. Removes the
# image layout's files first, so every outcome leaves the checkout layout, and the failed
# container (the old compose project may name its own), then runs the checkout's start.sh
# as its installer did: exit 11 once the old proxy is healthy, else 9.
rollback_checkout() {
  local f rc=0
  echo "install.sh: rolling back to the source-checkout install: $old_start" >&2
  for f in $LINKS; do
    if [[ -L $dir/$f && $(readlink "$dir/$f") == state/runtime/* ]]; then rm -f "$dir/$f"; fi
  done
  rm -f "$dir/effective-policy.txt"
  rm -rf "$state"
  docker rm -f egress-proxy >/dev/null 2>&1 || true
  EGRESS_CONFIG_DIR=$dir bash "$old_start" </dev/null >&2 || rc=$?
  ((rc == 0)) ||
    die 9 "rolling back to the source-checkout install ($old_start) failed (exit $rc); see docker logs egress-proxy"
  wait_healthy old_healthy ||
    die 9 "rolling back to the source-checkout install ($old_start) failed (not healthy within 120 s); see docker logs egress-proxy"
  die 11 "rolled back to the source-checkout install ($old_start), which is healthy; egress-proxy $version was not installed; see docker logs egress-proxy"
}

# failed <code> <message>: this version did not come up. Says so with the proxy's last log
# lines (a rollback replaces the container, and its logs with it), then rolls back to the
# previous version through that version's own install entry (interface 1, NFR-6), or, when
# migrating, to the source-checkout install, unless this is a rollback or there is no
# previous version: exit 11 when it is healthy again, 9 when the rollback failed too, else
# <code>.
failed() {
  local code=$1 logs entry rc=0
  echo "install.sh: $2" >&2
  logs=$(docker logs --tail 20 egress-proxy 2>&1) || logs=""
  if [[ -n $logs ]]; then
    echo "install.sh: the last 20 lines of docker logs egress-proxy:" >&2
    printf '%s\n' "$logs" >&2
  fi
  [[ -z $migrating || -z $old_start ]] || rollback_checkout
  [[ ${EGRESS_INSTALL_ROLLBACK:-} != 1 && -n $rb_digest ]] || exit "$code"
  entry=$state/$rb_runtime/egress-install
  # Safe: an entry only gets the image; that version's own install.sh runs, over interface 1.
  [[ -n $rb_runtime && -f $entry ]] || entry=$files/egress-install
  echo "install.sh: rolling back to egress-proxy $rb_version ($rb_digest)" >&2
  # This version's rules file: the previous start.sh rewrites it, or (before S4) has none.
  rm -f "$dir/effective-policy.txt"
  EGRESS_IMAGE_REPO=${rb_image%@*} EGRESS_INSTALL_ROLLBACK=1 \
    bash "$entry" --version "$rb_version" --digest "$rb_digest" --dir "$dir" || rc=$?
  ((rc == 0)) ||
    die 9 "rolling back to egress-proxy $rb_version ($rb_digest) failed (exit $rc); see docker logs egress-proxy"
  die 11 "rolled back to egress-proxy $rb_version ($rb_digest), which is healthy; egress-proxy $version was not installed; see docker logs egress-proxy"
}

rc=0
"$dir/start.sh" || rc=$?
((rc == 0)) || failed 7 "the start command failed (exit $rc) for egress-proxy $version ($digest); see docker logs egress-proxy"

wait_healthy healthy "$image" ||
  failed 6 "egress-proxy $version ($digest) did not become healthy within 120 s; see docker logs egress-proxy"

# -------- Record --------
if [[ -n $cur_digest && $cur_digest != "$digest" ]]; then
  prev=current
else
  prev=previous
fi
p_version=$(record_get "${prev}_version")
p_digest=$(record_get "${prev}_digest")
p_image=$(record_get "${prev}_image")
p_runtime=$(record_get "${prev}_runtime")
{
  header '#' state/installed "the installed egress-proxy versions: the current one (the last healthy install) and the previous one"
  echo "format=1"
  echo "current_version=$version"
  echo "current_digest=$digest"
  echo "current_image=$image"
  echo "current_runtime=$base"
  echo "previous_version=$p_version"
  echo "previous_digest=$p_digest"
  echo "previous_image=$p_image"
  echo "previous_runtime=$p_runtime"
} >"$state/.installed.tmp.$$"
mv -f "$state/.installed.tmp.$$" "$record"

for d in "$state"/runtime.*; do
  [[ -d $d && ! -L $d ]] || continue
  [[ ${d##*/} == "$base" || ${d##*/} == "$p_runtime" ]] || rm -rf "$d"
done

# -------- Old images (FR-10) --------
# Only the current and previous images stay. Without -f, docker keeps an image a container
# uses or another repo references. A rollback leaves cleaning up to the next install.
if [[ ${EGRESS_INSTALL_ROLLBACK:-} != 1 ]]; then
  keep=" "
  for ref in "$image" "$p_image"; do
    [[ -z $ref ]] || keep+="$(docker image inspect --format '{{.Id}}' "$ref" 2>/dev/null || true) "
  done
  removed=0
  for id in $(docker images --no-trunc --format '{{.ID}}' "${image%@*}" 2>/dev/null | sort -u); do
    [[ $keep != *" $id "* ]] || continue
    if docker image rm "$id" >/dev/null 2>&1; then removed=$((removed + 1)); fi
  done
  ((removed == 0)) || echo "install.sh: removed $removed old egress-proxy image(s)"
fi

# -------- The source-checkout install (FR-11) --------
# Once this version is healthy and recorded: the checkouts, the old start.sh's output here,
# and the locally built images no container uses (by name; untagged ones by ID; never
# forced). A kill in here leaves a recorded install, and the next one finishes this.
if [[ -n $checkout && ${EGRESS_INSTALL_ROLLBACK:-} != 1 ]]; then
  rm -f "$dir/current"
  rm -rf "$dir/versions"
  rm -f "$dir/compose.networks.yaml" "$dir"/.compose.networks.*
  removed=0
  for name in egress-proxy egress-proxy-proxy egress-gateway; do
    while read -r ref id; do
      [[ -n $ref ]] || continue
      [[ $ref != *':<none>' ]] || ref=$id
      users=$(docker ps -aq --filter "ancestor=$ref" 2>/dev/null) || continue
      [[ -z $users ]] || continue
      if docker image rm "$ref" >/dev/null 2>&1; then removed=$((removed + 1)); fi
    done < <(docker images --no-trunc --format '{{.Repository}}:{{.Tag}} {{.ID}}' "$name" 2>/dev/null || true)
  done
  # As the user types it: ~/.egress/start.sh.
  shown=$dir tilde='~'
  if [[ -n ${HOME:-} && $HOME != / && $dir == "${HOME%/}"/* ]]; then shown=$tilde/${dir#"${HOME%/}"/}; fi
  echo "install.sh: migrated the source-checkout install: removed $dir/versions and $dir/current and $removed locally built image(s); the start command is now $shown/start.sh, not current/start.sh"
fi

echo "egress-proxy $version ($digest) installed in $dir; start command: $dir/start.sh"
