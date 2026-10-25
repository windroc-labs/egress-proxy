//! Facts the entrypoint learns at start and records, so health can regenerate the
//! running policy without asking DNS again.

use std::collections::BTreeMap;
use std::net::{IpAddr, ToSocketAddrs};
use std::path::Path;
use std::thread::sleep;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

use crate::config::Config;

pub const HOST_DOCKER_INTERNAL: &str = "host.docker.internal";
const ALIAS_WAIT: Duration = Duration::from_secs(10);
const ALIAS_RETRY: Duration = Duration::from_millis(500);

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Facts {
    /// The port every network's smokescreen listens on.
    pub port: u16,
    /// Each network's listen IP: the gateway's address on that network.
    pub networks: BTreeMap<String, IpAddr>,
    /// What `host.docker.internal` resolved to (empty when it did not resolve).
    pub host_docker_internal: Vec<IpAddr>,
    /// The gateway's own interface addresses.
    pub own_addrs: Vec<IpAddr>,
}

/// The listen alias of a caller network: the gateway's DNS name on it.
pub fn listen_alias(network: &str) -> String {
    format!("egress-proxy-{network}")
}

/// Name resolution, with fixed answers for the names given by `--resolve` (tests only).
/// A fixed answer still has to pass the own-address check.
#[derive(Debug, Clone, Default)]
pub struct Resolver {
    pub overrides: BTreeMap<String, Vec<IpAddr>>,
}

impl Resolver {
    fn lookup(&self, host: &str) -> Option<Vec<IpAddr>> {
        if let Some(fixed) = self.overrides.get(host) {
            return Some(fixed.clone());
        }
        let addrs: Vec<IpAddr> = (host, 0).to_socket_addrs().ok()?.map(|a| a.ip()).collect();
        (!addrs.is_empty()).then_some(addrs)
    }
}

/// Learns each configured network's listen IP, `host.docker.internal` and the
/// gateway's own addresses.
pub fn gather(config: &Config, port: u16, resolver: &Resolver) -> Result<Facts, String> {
    let own_addrs = own_addrs()?;
    let mut networks = BTreeMap::new();
    for network in config.networks.keys() {
        let alias = listen_alias(network);
        let ip = resolve_listen_ip(&alias, resolver, &own_addrs)
            .map_err(|problem| format!("network {network}: {problem}"))?;
        networks.insert(network.clone(), ip);
    }
    let mut host_docker_internal = resolver.lookup(HOST_DOCKER_INTERNAL).unwrap_or_default();
    host_docker_internal.sort();
    host_docker_internal.dedup();
    Ok(Facts {
        port,
        networks,
        host_docker_internal,
        own_addrs,
    })
}

fn resolve_listen_ip(alias: &str, resolver: &Resolver, own: &[IpAddr]) -> Result<IpAddr, String> {
    let deadline = Instant::now() + ALIAS_WAIT;
    let addrs = loop {
        if let Some(addrs) = resolver.lookup(alias) {
            break addrs;
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "cannot resolve {alias}; the gateway is not attached to that network (see compose.yaml)"
            ));
        }
        sleep(ALIAS_RETRY);
    };
    let pick = addrs
        .iter()
        .find(|a| a.is_ipv4())
        .or_else(|| addrs.first())
        .copied()
        .expect("lookup returns at least one address");
    if !own.contains(&pick) {
        return Err(format!(
            "{alias} resolves to {pick}, which is not this container's address"
        ));
    }
    Ok(pick)
}

fn own_addrs() -> Result<Vec<IpAddr>, String> {
    let ifaddrs = nix::ifaddrs::getifaddrs()
        .map_err(|e| format!("cannot list the container's addresses: {e}"))?;
    let mut addrs: Vec<IpAddr> = ifaddrs
        .filter_map(|ifa| {
            let addr = ifa.address?;
            if let Some(v4) = addr.as_sockaddr_in() {
                Some(IpAddr::V4(v4.ip()))
            } else {
                addr.as_sockaddr_in6().map(|v6| IpAddr::V6(v6.ip()))
            }
        })
        .collect();
    addrs.sort();
    addrs.dedup();
    Ok(addrs)
}

/// Writes the facts as JSON.
pub fn write(path: &Path, facts: &Facts) -> std::io::Result<()> {
    let json = serde_json::to_string_pretty(facts).expect("facts serialize");
    crate::files::write_private(path, &json)
}

/// Reads facts written by [`write`].
pub fn read(path: &Path) -> Result<Facts, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::parse;

    fn config(keys: &[&str]) -> Config {
        let mut text = String::from("version: 1\nnetworks:\n");
        for k in keys {
            text.push_str(&format!("  {k}:\n    mode: denylist\n"));
        }
        parse(Path::new("/c.yaml"), &text).unwrap()
    }

    fn resolver(pairs: &[(&str, &[&str])]) -> Resolver {
        Resolver {
            overrides: pairs
                .iter()
                .map(|(h, ips)| {
                    (
                        h.to_string(),
                        ips.iter().map(|i| i.parse().unwrap()).collect(),
                    )
                })
                .collect(),
        }
    }

    #[test]
    fn overrides_give_listen_ips_and_host_docker_internal() {
        let r = resolver(&[
            ("egress-proxy-workers", &["::1", "127.0.0.1"]),
            (
                "host.docker.internal",
                &["192.168.65.254", "192.168.65.254"],
            ),
        ]);
        let facts = gather(&config(&["workers"]), 4750, &r).unwrap();
        assert_eq!(facts.port, 4750);
        assert_eq!(
            facts.networks["workers"],
            "127.0.0.1".parse::<IpAddr>().unwrap()
        );
        assert_eq!(
            facts.host_docker_internal,
            vec!["192.168.65.254".parse::<IpAddr>().unwrap()]
        );
        assert!(facts.own_addrs.contains(&"127.0.0.1".parse().unwrap()));
    }

    #[test]
    fn empty_override_means_unresolved() {
        let r = resolver(&[
            ("egress-proxy-workers", &["127.0.0.1"]),
            ("host.docker.internal", &[]),
        ]);
        let facts = gather(&config(&["workers"]), 4750, &r).unwrap();
        assert!(facts.host_docker_internal.is_empty());
    }

    #[test]
    fn foreign_address_is_refused() {
        let r = resolver(&[("egress-proxy-workers", &["192.0.2.1"])]);
        let err = resolve_listen_ip("egress-proxy-workers", &r, &["127.0.0.1".parse().unwrap()])
            .unwrap_err();
        assert_eq!(
            err,
            "egress-proxy-workers resolves to 192.0.2.1, which is not this container's address"
        );
    }

    #[test]
    fn round_trips_as_json() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("facts.json");
        let facts = Facts {
            port: 4750,
            networks: [("workers".to_string(), "172.20.0.2".parse().unwrap())].into(),
            host_docker_internal: vec!["192.168.65.254".parse().unwrap()],
            own_addrs: vec!["127.0.0.1".parse().unwrap()],
        };
        write(&path, &facts).unwrap();
        assert_eq!(read(&path).unwrap(), facts);
    }
}
