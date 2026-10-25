# egress-proxy

Shared egress gateway for Docker caller networks.

One container, `egress-gateway`, joins each **caller network** (an internal Docker network
whose containers have no other way out) and proxies its traffic with
[smokescreen](https://github.com/stripe/smokescreen) v0.1.0 under that network's policy. A
caller is identified by the network its request arrives on; there are no tokens. The caller
networks are the sections of the local config, e.g. `workers` (denylist) and `mini-op`
(allowlist); each gets only its own policy. Other repos find the gateway through the
[label contract](docs/label-contract.md).

Contents: `Dockerfile` (smokescreen pinned by SHA-256, base images pinned by digest, the
Rust entrypoint in `gateway/`, the `HEALTHCHECK`), `compose.yaml`, `start.sh`,
`config.example.yaml`. There is no management command: the gateway applies its config at
start, and `start.sh` is the start command.

## Setup

1. Copy the example config and edit it:
   `mkdir -p ~/.egress && cp config.example.yaml ~/.egress/config.local.yaml`
2. From this checkout: `./start.sh`

`start.sh` builds the image, renders `~/.egress/compose.networks.yaml` (one caller network
per config section: the attachments, `EGRESS_NETWORKS` and the labels) with the image, and
runs `docker compose up -d` with it. It is idempotent: running it again changes nothing.
Run it after pulling a new version of this repo, or from another checkout: the networks
come from the config, so they stay. Never run a bare `docker compose up`: without the
rendered file the gateway has no caller networks and exits 2 (fail closed).
`restart: unless-stopped` brings the gateway back after a crash, a Docker Desktop restart,
or a Mac restart (with Docker Desktop set to start at login).

## Commands

| Task | Command |
| --- | --- |
| Start, upgrade, add or remove a caller network (idempotent) | `./start.sh` |
| Apply a policy change within existing sections | `docker compose restart gateway` |
| Health | `docker ps --filter name=egress-gateway` (status column), `docker inspect --format '{{json .State.Health}}' egress-gateway` |
| Logs (config errors name the network and key) | `docker logs egress-gateway` |
| Stop | `docker compose stop` |

A config change takes effect only on restart (or `./start.sh` for an added or removed
section); until then the gateway reports `unhealthy`, and a restart with sections that
differ from the attached networks exits 2 with `run ./start.sh`.
A restart drops every in-flight connection on every caller network; callers keep their
proxy settings and need no restart. After the Mac joins another network (e.g. a new
Wi-Fi), restart the gateway.

## Policy

The config (`~/.egress/config.local.yaml`, mounted read-only) has one section per caller
network; see `config.example.yaml`. Section `<key>` is Docker network `egress-<key>`,
where the gateway's alias is `egress-proxy-<key>` and its proxy
`http://egress-proxy-<key>:4750`. Key `uplink` is reserved (the gateway's own network
`egress-uplink`). These names do not collide with mini-op's `mini-op`, `mini-op-net` and
`mini-op-proxy`. Removing a section detaches the gateway; its Docker network stays until
`docker network rm egress-<key>`.

- **denylist**: public destinations are allowed; denied are the floor
  `0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12,
  192.168.0.0/16, ::/128, ::1/128, fc00::/7, fe80::/10`, the addresses of
  `host.docker.internal`, the gateway's own addresses, and the section's `deny_ranges`.
  IPv4-mapped IPv6 addresses are judged as their IPv4 address. smokescreen resolves names
  itself and checks the resulting address.
- **allowlist**: only the listed domains (or `*.domain` globs) are allowed, and the floor
  still applies.
- **exceptions** (either mode): `host:port` entries allowed even though a deny rule covers
  their address, e.g. `host.docker.internal:11434` for Ollama on `workers`, or the mini's
  ssh port on `mini-op`. The gateway resolves each name at start and opens only that port
  of the addresses it had then (smokescreen `allow_addresses`), for every caller on that
  network; after a name's address changes, restart the gateway. In allowlist mode the ACL,
  which has no ports, lists those start-time addresses, not the name: callers connect to
  the address (a CONNECT by name is denied), and a later DNS answer opens nothing. There
  an exception must be an address a deny rule covers (e.g. a LAN address); list public
  hosts under `allow`. A name that does not resolve, that resolves to the gateway or into
  a caller network's subnet, or (allowlist) to an address no deny rule covers, stops the
  start.

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
- Each network's smokescreen listens only on the gateway's address on that network, with
  that network's policy: a caller gets no other network's allows, cannot reach the proxy
  listeners on other networks, and cannot reach containers on other caller networks.
- That isolation assumes callers without `NET_RAW` or `NET_ADMIN` (ensemble's workers run
  with `--cap-drop ALL`). The gateway's networks share one network stack, and Linux accepts
  a packet for any of its addresses on any interface, so a caller able to send raw frames
  could reach the gateway's listener on another network. Never grant those capabilities to
  a caller.
- Containers on the same caller network can still reach each other directly.

## Development

- Entrypoint: `cd gateway && cargo fmt --check && cargo clippy --all-targets --locked -- -D warnings && cargo test --locked`.
- Repo lint: `tests/check-repo.sh`; its comments describe each check.
- Docker end-to-end: `tests/integration.sh` runs in CI only (Linux; it restarts the
  Docker daemon and uses a throwaway Docker client config).
- CI (`.github/workflows/ci.yml`) runs on every pull request and push to `main`.
  Set `CI` as the only required status check in the `main` branch ruleset. It aggregates
  `rust`, `lint` and `integration`, and fails if any dependency fails, is cancelled or is
  skipped. When adding a job, add it to `ci.needs`; the `lint` job checks completeness
  with `.github/check_ci_needs.py` (requires `PyYAML==6.0.2`).

## Manual checks (Mac)

CI covers crashes and a Docker daemon restart; check these on the Mac once per release:

1. Restart Docker Desktop: `docker ps --filter name=egress-gateway` shows `(healthy)`
   again within a minute.
2. Restart the Mac (Docker Desktop starts at login): the same.
