# egress-proxy

Shared egress gateway for Docker caller networks.

One container, `egress-gateway`, joins each **caller network** (an internal Docker network
whose containers have no other way out) and proxies its traffic with
[smokescreen](https://github.com/stripe/smokescreen) v0.1.0 under that network's policy. A
caller is identified by the network its request arrives on; there are no tokens. This
version serves one caller network, `workers` (Docker network `egress-workers`), in
denylist mode. Other repos find the gateway through the [label contract](docs/label-contract.md).

Contents: `Dockerfile` (smokescreen pinned by SHA-256, base images pinned by digest, the
Rust entrypoint in `gateway/`, the `HEALTHCHECK`), `compose.yaml`, `config.example.yaml`.
There is no management command: the gateway applies its config at start.

## Setup

1. Copy the example config and edit it:
   `mkdir -p ~/.egress && cp config.example.yaml ~/.egress/config.local.yaml`
2. From this checkout: `docker compose up -d --build`

The start command is idempotent: run it again (or after pulling a new version of this
repo) and it changes only what changed. `restart: unless-stopped` brings the gateway back
after a crash, a Docker Desktop restart, or a Mac restart (with Docker Desktop set to start
at login).

## Commands

| Task | Command |
| --- | --- |
| Start or upgrade | `docker compose up -d --build` |
| Apply a config change | `docker compose restart gateway` |
| Health | `docker ps --filter name=egress-gateway` (status column), `docker inspect --format '{{json .State.Health}}' egress-gateway` |
| Logs (config errors name the network and key) | `docker logs egress-gateway` |
| Stop | `docker compose stop` |

A config change takes effect only on restart; until then the gateway reports `unhealthy`.
A restart drops every in-flight connection on every caller network; callers keep their
proxy settings and need no restart. After the Mac joins another network (e.g. a new
Wi-Fi), restart the gateway.

## Policy

The config (`~/.egress/config.local.yaml`, mounted read-only) has one section per caller
network; see `config.example.yaml`. Its network keys must be exactly the networks
`compose.yaml` attaches the gateway to.

- **denylist**: public destinations are allowed; denied are the floor
  `0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12,
  192.168.0.0/16, ::/128, ::1/128, fc00::/7, fe80::/10`, the addresses of
  `host.docker.internal`, the gateway's own addresses, and the section's `deny_ranges`.
  IPv4-mapped IPv6 addresses are judged as their IPv4 address. smokescreen resolves names
  itself and checks the resulting address.
- **allowlist**: only the listed domains (or `*.domain` globs) are allowed, and the floor
  still applies.

The gateway cannot see the Mac's network interfaces: LAN ranges in RFC 1918 space are in
the floor, but add the Mac's public IPv4 address and any global IPv6 prefix to
`deny_ranges` yourself.

## Health

The image's `HEALTHCHECK` runs `/gateway health` every 15 s. It fails when the running
policy differs from the one the mounted config now gives, when a network's proxy port does
not answer, when its deny probe is not denied, or when its allow probe is denied. The
probes test smokescreen's decision, not reachability, so the gateway stays healthy while
the Mac is offline.

## Isolation

- The proxy port is not published; only callers on a caller network reach it.
- Each caller network is `internal`: without the gateway, its containers have no egress
  and no external DNS (fail closed).
- The gateway runs as UID 65532 with a read-only root filesystem, no capabilities and no
  Docker socket; the config is mounted read-only.
- Containers on the same caller network can still reach each other directly.

The gateway's networks and container (`egress-gateway`, `egress-workers`, `egress-uplink`)
do not collide with mini-op's `mini-op`, `mini-op-net` and `mini-op-proxy`.

## Development

- Entrypoint: `cd gateway && cargo fmt --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked`.
- Repo lint: `tests/check-repo.sh` (no dependency on ensemble or mini-op, pinned images
  and actions, no keychain crates).
- Docker end-to-end: `tests/integration.sh` runs in CI only (Linux; it restarts the
  Docker daemon and uses a throwaway Docker client config).
- CI (`.github/workflows/ci.yml`) runs the jobs `rust`, `lint` and `integration` on every
  pull request. Make all three required status checks for `main` in the repo's branch
  protection settings.

## Manual checks (Mac)

CI covers crashes and a Docker daemon restart; check these on the Mac once per release:

1. Restart Docker Desktop: `docker ps --filter name=egress-gateway` shows `(healthy)`
   again within a minute.
2. Restart the Mac (Docker Desktop starts at login): the same.
