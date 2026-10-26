# Label contract, version 1

The only interface between the egress proxy and the tools that start caller containers
(e.g. ensemble's broker): labels on the proxy container, plus Docker health. A consumer
uses nothing else and never probes the proxy itself.

## Labels

| Label | Value |
| --- | --- |
| `windroc.egress.contract` | `1`, this contract's version (set in compose.yaml) |
| `windroc.egress.networks` | comma-separated network keys, sorted, e.g. `mini-op,workers` |
| `windroc.egress.network.<key>.name` | the Docker network a caller joins: `egress-<key>` |
| `windroc.egress.network.<key>.proxy` | the proxy URL for callers on that network: `http://egress-proxy-<key>:4750` |

The network keys are the sections of the proxy's local config (`~/.egress/config.local.yaml`);
`./start.sh` renders the networks and per-network labels from them, so they always match the
networks the proxy is attached to. Every key in `windroc.egress.networks` has both `.name`
and `.proxy` labels. The proxy URL uses the proxy's alias on that network, so it stays the
same when the proxy restarts.

## Consumer rules

Before starting a caller on network `<key>`:

1. Find the proxy: `docker ps -a --filter label=windroc.egress.contract --format '{{.ID}}'`.
   Exactly one container must match.
2. Its `windroc.egress.contract` must be a version the consumer knows (`1`).
3. It must be running and healthy: `docker inspect` shows `State.Running` `true` and
   `State.Health.Status` `healthy` (`starting` and `unhealthy` both mean no).
4. `windroc.egress.networks` must list `<key>`, with its `.name` and `.proxy` labels present.
5. The network named by `.name` must be internal (`docker network inspect` `Internal`
   `true`) and have the proxy attached.

If any rule fails, refuse to start the caller; never fall back to another network. Then
attach the caller only to that network and point its proxy settings (`HTTP_PROXY`,
`HTTPS_PROXY` and the lower-case pair) at the `.proxy` URL.

Never mount `~/.egress`, the egress checkout or the Docker socket into a caller container:
a caller that can edit them controls the proxy's next policy or build.

## Versioning

A change that breaks a rule or a label's meaning bumps `windroc.egress.contract`; a
consumer that does not know the new version refuses to start callers. Adding a network
key, or a change in the order of `windroc.egress.networks`, is not a breaking change.
