# Label contract, version 1

The only interface between the egress gateway and the tools that start caller containers
(e.g. ensemble's broker): labels on the gateway container, plus Docker health. A consumer
uses nothing else and never probes the gateway itself.

## Labels

| Label | Value in this version of compose.yaml |
| --- | --- |
| `windroc.egress.contract` | `1`, this contract's version |
| `windroc.egress.networks` | comma-separated network keys: `workers` |
| `windroc.egress.network.<key>.name` | the Docker network a caller joins: `egress-workers` |
| `windroc.egress.network.<key>.proxy` | the proxy URL for callers on that network: `http://egress-proxy-workers:4750` |

Every key in `windroc.egress.networks` has both `.name` and `.proxy` labels. The proxy URL
uses the gateway's alias on that network, so it stays the same when the gateway restarts.

## Consumer rules

Before starting a caller on network `<key>`:

1. Find the gateway: `docker ps -a --filter label=windroc.egress.contract --format '{{.ID}}'`.
   Exactly one container must match.
2. Its `windroc.egress.contract` must be a version the consumer knows (`1`).
3. It must be running and healthy: `docker inspect` shows `State.Running` `true` and
   `State.Health.Status` `healthy` (`starting` and `unhealthy` both mean no).
4. `windroc.egress.networks` must list `<key>`, with its `.name` and `.proxy` labels present.
5. The network named by `.name` must be internal (`docker network inspect` `Internal`
   `true`) and have the gateway attached.

If any rule fails, refuse to start the caller; never fall back to another network. Then
attach the caller only to that network and point its proxy settings (`HTTP_PROXY`,
`HTTPS_PROXY` and the lower-case pair) at the `.proxy` URL.

Never mount `~/.egress`, the egress checkout or the Docker socket into a caller container:
a caller that can edit them controls the gateway's next policy or build.

## Versioning

A change that breaks a rule or a label's meaning bumps `windroc.egress.contract`; a
consumer that does not know the new version refuses to start callers. Adding a network
key is not a breaking change.
