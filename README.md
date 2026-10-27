# egress-proxy

Shared egress proxy for Docker caller networks.

One container, `egress-proxy` (compose project `egress-proxy`), joins each **caller
network** (an internal Docker network whose containers have no other way out) and proxies
its traffic with
[smokescreen](https://github.com/stripe/smokescreen) v0.1.0 under that network's policy. A
caller is identified by the network its request arrives on; there are no tokens. The caller
networks are the sections of the local config, e.g. `workers` (denylist) and `mini-op`
(allowlist); each gets only its own policy. Other repos find the proxy through the
[label contract](docs/label-contract.md).

Contents: `Dockerfile` (smokescreen pinned by SHA-256, base images pinned by digest, the
Rust entrypoint in `proxy/`, the `HEALTHCHECK`, and the runtime files in `/egress`),
`egress-install` (the install entry) and `install.sh` (the installer the image ships),
`compose.yaml`, `start.sh`, `config.example.yaml`, `config.default.yaml`,
`verify-egress`. There is no management command: the proxy applies its config at start,
`start.sh` is the start command, and `verify-egress` only checks.

## Setup

1. Install the published image by its digest:
   `egress-install --version X.Y.Z --digest sha256:<digest>`, with the version and the
   index digest from the GitHub Release `vX.Y.Z` ([Release](#release)). It installs into
   `~/.egress` (`--dir <path>` for another directory) and ends with
   `egress-proxy X.Y.Z (sha256:…) installed in ~/.egress; start command: ~/.egress/start.sh`.
2. To change the policy, edit `~/.egress/config.local.yaml` ([Policy](#policy)), then run
   `~/.egress/start.sh`.

`egress-install` comes from a checkout of this repo at the tag `vX.Y.Z`, from a copy a
caller's installer ships, or, after a first install, from
`~/.egress/state/runtime/egress-install`. The installer it runs comes from the image, so
the install is only as trusted as the digest: take it from the Release of the tag, or from
a caller that pins it, never from a tag lookup.

`egress-install` changes nothing until it has the image:

- The image already on the machine (by digest): no network, GitHub login or registry is
  needed, e.g. to reinstall the same version offline.
- Else it pulls the image by digest, never by tag. The package is private: the pull uses
  the machine's GitHub login, `gh`, whose account must be able to read the package
  `ghcr.io/windroc-labs/egress-proxy`, with scope `read:packages`
  (`gh auth refresh -h github.com -s read:packages`). A credential helper in a throwaway
  Docker client config asks `gh` at pull time, so the token is never written to a file or
  printed, and the Docker login is left alone.

It then copies the image's `/egress` out and runs its `install.sh`, which:

1. checks the running proxy, `egress-proxy`, and changes nothing when it serves another
   [label contract](docs/label-contract.md) (exit 10) or when it is a newer version to
   keep: healthy, of the same contract, with a higher version label, and published, i.e.
   pulled by the digest `~/.egress/state/installed` names as current (a local build, even
   tagged `ghcr.io/windroc-labs/egress-proxy:<higher>`, is replaced). Keeping it, it says
   so and exits 0. A newer version is never downgraded, so callers pinning an older one
   share the newest;
2. writes the runtime files as one set under `~/.egress/state/` and switches the
   top-level files to it with one rename, so a killed install leaves the old set or the
   new one, never a mix;
3. writes the default config (`config.default.yaml`) when `config.local.yaml` does not
   exist, and never changes an existing one;
4. runs `~/.egress/start.sh` and waits up to 120 s for the proxy to be healthy with the
   [label contract](docs/label-contract.md)'s labels. If the start command fails or the
   proxy is not healthy in time, it prints the proxy's last 20 log lines and rolls back:
   the previous version's own `egress-install` (kept in its runtime set) reinstalls that
   version from its image, with its runtime files and its `start.sh`, and the install
   exits 11 naming the version that failed. With no previous version (a first install,
   or a reinstall of the current one) the new version is left as it is (exit 6 or 7).
   Callers' connections drop once more for the rollback;
5. records the version, digest and image as current, and the one before as previous, in
   `~/.egress/state/installed`;
6. removes the other `ghcr.io/windroc-labs/egress-proxy` images, so only the current and
   the previous one stay (`docker images ghcr.io/windroc-labs/egress-proxy`). An image a
   container still uses stays too. A rollback leaves this to the next install.

An install from source checkouts, as callers' installers made it before the image (e.g.
ensemble v0.5.0: `~/.egress/versions/<commit>/`, `~/.egress/current` linking to it), is
migrated by the same command. `config.local.yaml` is kept byte for byte, and the caller
networks and the callers on them stay. Once the new version is healthy, the install removes
`versions/`, `current`, the old `compose.networks.yaml` and the locally built images
`egress-proxy`, `egress-proxy-proxy` and `egress-gateway` that no container uses, and prints
the new start command, `~/.egress/start.sh` (`current/start.sh` is gone). If the new version
does not start or is not healthy, the install removes the new files, runs the checkout's own
`start.sh` to bring the old proxy back, keeps the old files, and exits 11 (9 if the old
proxy does not come back either). Only that exact layout is migrated: a `current` or
`versions` of another shape is left as found and never run.

| Exit code | Meaning |
| --- | --- |
| 0 | installed, or a newer, healthy running proxy kept instead of downgrading |
| 1 | another failure, e.g. the image's files could not be copied out, or `state/installed` has a newer format |
| 2 | usage, or Docker is not running or not reachable |
| 3 | no access to the image: the message names the GitHub login and scope needed |
| 4 | the pull failed: the message names the image, digest and registry; the running proxy keeps running |
| 5 | the image is not that version, has no contract label, or has no installer |
| 6 | the proxy was not healthy within 120 s (`docker logs egress-proxy`), with no previous version to roll back to (or in a rollback): the version being installed is left as it is |
| 7 | the start command failed, with no previous version to roll back to (or in a rollback): the version being installed is left as it is |
| 8 | the installer does not know the `--interface` this `egress-install` speaks |
| 9 | the version being installed did not start or was not healthy, and the rollback to the previous version (migrating a source-checkout install: to it, with its start.sh) failed too |
| 10 | the running proxy serves another label contract: nothing was changed; the message names both versions and contracts |
| 11 | the version being installed did not start or was not healthy; rolled back to the previous version (migrating a source-checkout install: to it, with its start.sh), which is healthy |

Codes 2–5 and 10 leave `~/.egress` and the running proxy as they were.

`~/.egress` then holds only:

| Path | Written by | What it is |
| --- | --- | --- |
| `config.local.yaml` | you (the installer writes the default once) | the only file to edit |
| `README.md` | the installer, every install | each file's use, the commands, the installed version and digest |
| `start.sh` | the installer | the start command |
| `verify-egress` | the installer | checks a caller network's allows and denies ([Verify](#verify)) |
| `config.example.yaml` | the installer | every config option, with examples |
| `effective-policy.txt` | `start.sh`, at every start | each network's rules in effect: the floor, the start-time addresses and the config |
| `state/` | the installer and `start.sh` | the runtime set, the compose file, the rendered networks file, the installed versions; never edit |

Every generated file starts with a comment saying so. `start.sh` runs the installed image
by digest and never builds or pulls: it renders `state/compose.networks.yaml` (one caller
network per config section: the attachments, `EGRESS_NETWORKS` and the labels) with the
image, creates the networks that do not exist yet (each `egress-<key>` internal, and
`egress-uplink`; compose uses them as external), and runs `docker compose up -d` with it.
It is idempotent: running it again changes nothing. Never run a bare
`docker compose up`: without the rendered file the proxy has no caller networks and exits
2 (fail closed). `restart: unless-stopped` brings the proxy back after a crash, a Docker
Desktop restart, or a Mac restart (with Docker Desktop set to start at login), from the
image on the machine.

## Commands

| Task | Command |
| --- | --- |
| Install, reinstall or upgrade | `egress-install --version X.Y.Z --digest sha256:<digest>` |
| Start, or apply a config change (idempotent) | `~/.egress/start.sh` |
| See each network's rules in effect | printed by `~/.egress/start.sh`; the last start's in `~/.egress/effective-policy.txt` |
| Health | `docker ps --filter name=egress-proxy` (status column), `docker inspect --format '{{json .State.Health}}' egress-proxy` |
| Logs (config errors name the network and key) | `docker logs egress-proxy` |
| Stop | `docker stop egress-proxy` |
| Check a caller network's allows and denies ([Verify](#verify)) | `~/.egress/verify-egress <network>` |
| Check how a worker image's tools behave behind the proxy | `~/.egress/verify-egress --tools <image>` |

A config change takes effect when `~/.egress/start.sh` runs: it restarts the proxy when the
running policy differs from the config, and otherwise leaves it running. Until then the
proxy reports `unhealthy`, and a restart with sections that differ from the attached
networks exits 2 with `run ./start.sh`.
Each run then prints each network's rules in effect ([Policy](#policy): the mode, the
floor, the addresses of `host.docker.internal` and the proxy, `deny_ranges`, `allow`, and
each exception with the addresses resolved at that start) and writes them to
`effective-policy.txt`; a `docker restart` does not rewrite that file.
A restart drops every in-flight connection on every caller network; callers keep their
proxy settings and need no restart. After the Mac joins another network (e.g. a new
Wi-Fi), restart the proxy: `docker restart egress-proxy`.

## Policy

The config (`~/.egress/config.local.yaml`, mounted read-only) has one section per caller
network; see `config.example.yaml`. Section `<key>` is Docker network `egress-<key>`,
where the proxy's alias is `egress-proxy-<key>` and its proxy URL
`http://egress-proxy-<key>:4750`. Key `uplink` is reserved (the proxy's own network
`egress-uplink`). These names and the container's, `egress-proxy`, do not collide with
mini-op's `mini-op`, `mini-op-net` and `mini-op-proxy`. Removing a section detaches the
proxy; its Docker network stays until `docker network rm egress-<key>`.

- **denylist**: public destinations are allowed; denied are the floor
  `0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12,
  192.168.0.0/16, ::/128, ::1/128, fc00::/7, fe80::/10`, the addresses of
  `host.docker.internal`, the proxy's own addresses, and the section's `deny_ranges`.
  IPv4-mapped IPv6 addresses are judged as their IPv4 address. smokescreen resolves names
  itself and checks the resulting address.
- **allowlist**: only the listed domains (or `*.domain` globs) are allowed, and the floor
  still applies.
- **exceptions** (either mode): `host:port` entries allowed even though a deny rule covers
  their address, e.g. `host.docker.internal:11434` for Ollama on `workers`, or the mini's
  ssh port on `mini-op`. The proxy resolves each name at start and opens only that port
  of the addresses it had then (smokescreen `allow_addresses`), for every caller on that
  network; after a name's address changes, restart the proxy (`docker restart
  egress-proxy`). In allowlist mode the ACL,
  which has no ports, lists those start-time addresses, not the name: callers connect to
  the address (a CONNECT by name is denied), and a later DNS answer opens nothing. There
  an exception must be an address a deny rule covers (e.g. a LAN address); list public
  hosts under `allow`. A name that does not resolve, that resolves to the proxy or into
  a caller network's subnet, or (allowlist) to an address no deny rule covers, stops the
  start.

The proxy cannot see the Mac's network interfaces: LAN ranges in RFC 1918 space are in
the floor, but add the Mac's public IPv4 address and any global IPv6 prefix to
`deny_ranges` yourself (and in `verify.deny_targets`, so [verify-egress](#verify) checks
it).

## Health

The image's `HEALTHCHECK` runs `/proxy health` every 15 s. It fails when the running
policy differs from the one the mounted config now gives, when a network's proxy port does
not answer, when its deny probe is not denied, or when its allow probe is denied. The
probes test smokescreen's decision, not reachability, so the proxy stays healthy while
the Mac is offline.

## Isolation

- The proxy port is not published; only callers on a caller network reach it.
- Each caller network is `internal`: without the proxy, its containers have no egress
  and no external DNS (fail closed).
- The proxy runs as UID 65532 with a read-only root filesystem, no capabilities and no
  Docker socket; the config is mounted read-only.
- Each network's smokescreen listens only on the proxy's address on that network, with
  that network's policy: a caller gets no other network's allows, cannot reach the proxy
  listeners on other networks, and cannot reach containers on other caller networks.
- That isolation assumes callers without `NET_RAW` or `NET_ADMIN` (ensemble's workers run
  with `--cap-drop ALL`). The proxy's networks share one network stack, and Linux accepts
  a packet for any of its addresses on any interface, so a caller able to send raw frames
  could reach the proxy's listener on another network. Never grant those capabilities to
  a caller.
- Containers on the same caller network can still reach each other directly.

## Verify

`verify-egress <network>` checks one caller network's policy from a probe container on
`egress-<network>` (a pinned curl image), against targets it discovers at run time. Nothing
it probes is written in this repo: the proxy computes the checks (`proxy plan`, run
read-only with `docker exec`) from its config and start facts, plus what verify-egress
learns on the host (its interface addresses with their prefixes, its default gateways) and
a listener it opens on the host's `127.0.0.1` for the run. It needs a healthy proxy and
`python3` on the host (for the listener), and uses a throwaway Docker client config, so no
registry credential or keychain is read.
On macOS the first run raises "Allow Python to find devices on local networks?", and
`host_listener` fails until it is allowed.

| Check | Probe | Passes when |
| --- | --- | --- |
| `proxy_found`, `proxy_contract`, `proxy_healthy`, `network_advertised`, `network_internal` | the label contract and Docker health | exactly one proxy, contract 1, healthy, `<network>` advertised, its Docker network internal |
| `host_listener` | curl on the host to the listener | it answers |
| `plan` | `proxy plan` | the proxy printed the checks; it refuses while the running policy differs from the config (run `start.sh`) |
| `proxy_deny` | CONNECT through the network's proxy | 407: one address per deny-floor range, `169.254.169.254`, `[::ffff:127.0.0.1]`, `host.docker.internal` (by name and address), the proxy's own addresses, the host's addresses and one more address in each of their prefixes, its default gateways, the host listener, each `deny_ranges` range, each `verify.deny_targets` entry, `localtest.me` (a public name for 127.0.0.1), a public host (allowlist), and the other networks' exceptions (where this network's policy denies their addresses) and allows |
| `proxy_allow` | an https request through the proxy | CONNECT 200 and an HTTP answer (any status): `example.com` (denylist) or each non-glob `allow` entry (allowlist) |
| `exception_open`, `exception_other_port` | CONNECT through the proxy | each exception reaches its target (200), and the next port of that host is denied (407) where this network's policy denies that address. In allowlist mode a named exception is probed at the addresses the proxy resolved at start |
| `direct_none`, `cross_none` | curl without the proxy | no connection: `1.1.1.1`, `example.com`, the host listener, the host's IPv4 addresses and gateways; the other networks' proxy listeners, by address and alias |
| `dns_none` | `nslookup example.com`, also against `1.1.1.1` | no answer |
| `peer_control`, `peer_none` | a listener verify-egress starts on each other caller network | it answers from its own network and not from `<network>` |

A deny proves the policy, not the target: the proxy's 407 comes before it dials, so a
target that would reject the host anyway (such as a NAS that rejects the mini) still
counts only through that 407.

Output: `ok <check> <target> <observed>` or `FAIL <check> <target>: <observed>, want
<expected>` per check, then `all <n> checks passed` or `<m> of <n> checks failed:
<checks>`. Only status codes and exit codes are read; response bodies are discarded. Exit
codes: 0 all passed, 1 a check failed, 2 usage or no Docker context or `python3`.

`verify.deny_targets` (per network, `host:port` entries, see `config.example.yaml`) adds
deny checks without changing the policy: list LAN hosts that matter, and the Mac's public
IPv4 address, which verify-egress cannot discover behind NAT.

`verify-egress --tools <image>` runs each tool of the [worker tool table](docs/worker-tools.md)
in one container of `<image>` (local only, non-root) on `egress-workers`, with the proxy
variables a worker gets, and prints that table's rows with the image's ID and today's date.

Acceptance runs on the test Mac mini through mini-op, never on a developer's Mac: there
run `~/.egress/verify-egress workers`, `~/.egress/verify-egress mini-op` and
`~/.egress/verify-egress --tools <worker image>`, and record the tool rows in `docs/worker-tools.md`.

## Development

Running from a checkout is for development only: `./start.sh` there builds the image
`egress-proxy` from the checkout and runs it with the config in `$EGRESS_CONFIG_DIR`
(default `~/.egress`; first `mkdir -p <dir> && cp config.example.yaml
<dir>/config.local.yaml`). It is the same container, `egress-proxy`, so it replaces an
installed proxy until `~/.egress/start.sh` runs again. It also upgrades an install from
before the rename to proxy (compose project `egress`, container `egress-gateway`): it
removes the old container, then starts `egress-proxy` in compose project `egress-proxy` on
the same networks, with the same labels and aliases; callers attached to the networks stay
attached. Then remove by hand the old images, `docker image rm egress-gateway
egress-proxy-proxy`, and in a checkout where you built the entrypoint, `rm -rf gateway`
(its ignored build output).

- Entrypoint: `cd proxy && cargo fmt --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked`.
- Repo lint: `tests/check-repo.sh`; its comments describe each check.
- verify-egress: `tests/verify-egress-selftest.sh` runs it against a fake `docker` (no
  daemon).
- Install entry and installer: `tests/install-selftest.sh` runs `egress-install` and
  `install.sh` against a fake `docker` and `gh` (no daemon).
- Docker end-to-end: `tests/integration.sh` runs in CI only (Linux; it restarts the
  Docker daemon and uses a throwaway Docker client config), from a checkout's `start.sh`.
  `tests/install-integration.sh` runs in CI's `image` job: it installs the image that job
  published to its local registry by digest.
- Release steps (`.github/release_image.py`): `python3 -B -m unittest discover -s .github -p 'test_*.py'`
  (requires `PyYAML==6.0.2`); no Docker or registry.
- CI (`.github/workflows/ci.yml`) runs on every pull request and push to `main`, and as
  the first job of every release.
  Set `CI` as the only required status check in the `main` branch ruleset. It aggregates
  `rust`, `lint`, `macos` (every script parsed, and the install self-test run, with
  macOS's own bash 3.2 and BSD tools), `integration` and `image`, and fails if any dependency fails, is cancelled
  or is skipped. `image` runs the release path against a local registry: it builds both
  platforms (`.github/actions/build-image`, arm64 under QEMU), checks the layout and
  publishes it as version `0.0.0`, then installs it from there. When adding a job, add it to `ci.needs`; the `lint` job
  checks completeness with `.github/check_ci_needs.py` (requires `PyYAML==6.0.2`).

## Release

A release is the image `ghcr.io/windroc-labs/egress-proxy:X.Y.Z` for `linux/amd64` and
`linux/arm64`, plus the GitHub Release `vX.Y.Z` that gives its index digest. Install and pin
it by that digest, never by the tag ([Setup](#setup)).

1. Merge the change to `main`.
2. Tag that `main` commit and push the tag: `git tag vX.Y.Z <commit> && git push origin vX.Y.Z`.

The version is semver for the image (`vX.Y.Z` only; no pre-release suffix) and is
independent of the label contract version, which changes only per
[docs/label-contract.md](docs/label-contract.md#versioning); the Release notes give both.

`.github/workflows/release.yml` then runs, each job only if the previous one passed:

| Job | Permissions | Does |
| --- | --- | --- |
| `checks` | read | all of CI (`ci.yml`) |
| `prepare` | read | fails unless the tag is `vX.Y.Z` on a commit in `main`, the Release does not exist and the version is not in GHCR yet |
| `build` | read | builds both platforms into an OCI layout with the [image labels](docs/label-contract.md#image-labels), and checks every layer and the image history: no source, tests, `.git`, build output or credential |
| `publish` | write | checks the layout again, copies exactly those bytes to GHCR (`skopeo copy --preserve-digests`), verifies the registry's digest and labels, and creates the Release |

A published version never changes: a tag pushed again for an existing version fails in
`prepare` and leaves GHCR as it was; ship a fix as a new version. If `publish` fails after
the push but before the Release exists, use "Re-run failed jobs" within a day (while the
`build` job's layout artifact is kept): `publish` checks the same layout again, accepts the
tag because it already holds exactly that digest, and creates the Release. "Re-run all
jobs" fails in `prepare`, since the version is then in GHCR; after that day, create the
Release by hand from the digest GHCR shows.

Who may publish is set by a tag ruleset, which the repo's owner keeps: target `v*` tags,
restrict creation, updates and deletion, with only the owner on the bypass list. Without
it, anyone with write access could tag a commit; the `main` check in `prepare` catches a
wrong commit but is not a control, since the tagged commit's own `release.yml` runs.

## Manual checks (Mac)

CI covers crashes and a Docker daemon restart; check these on the Mac once per release:

1. Restart Docker Desktop: `docker ps --filter name=egress-proxy` shows `(healthy)`
   again within a minute.
2. Restart the Mac (Docker Desktop starts at login): the same.
