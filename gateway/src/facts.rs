//! Facts the entrypoint learns at start and records, so health can regenerate the
//! running policy without asking DNS again.

use std::collections::BTreeMap;
use std::net::{IpAddr, ToSocketAddrs};
use std::path::Path;
use std::thread::sleep;
use std::time::{Duration, Instant};

use ipnet::IpNet;
use serde::{Deserialize, Serialize};

use crate::config::{Config, HostPort, listen_alias};

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
    /// Each exception host name (not IP literals) and the canonical addresses it resolved
    /// to, sorted and deduplicated.
    pub exceptions: BTreeMap<String, Vec<IpAddr>>,
    /// Each caller network's subnet, from the gateway's interface on it.
    pub subnets: BTreeMap<String, IpNet>,
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

    /// The canonical addresses of `host`, sorted and deduplicated; `None` when it does not
    /// resolve.
    fn lookup_canonical(&self, host: &str) -> Option<Vec<IpAddr>> {
        let mut addrs: Vec<IpAddr> = self
            .lookup(host)?
            .into_iter()
            .map(|a| a.to_canonical())
            .collect();
        addrs.sort();
        addrs.dedup();
        (!addrs.is_empty()).then_some(addrs)
    }
}

/// Learns each configured network's listen IP and subnet, `host.docker.internal`, the
/// gateway's own addresses and the exceptions' addresses.
pub fn gather(config: &Config, port: u16, resolver: &Resolver) -> Result<Facts, String> {
    gather_with(config, port, resolver, &interfaces()?)
}

/// [`gather`] with the gateway's interface addresses given.
pub fn gather_with(
    config: &Config,
    port: u16,
    resolver: &Resolver,
    interfaces: &[IpNet],
) -> Result<Facts, String> {
    let mut own_addrs: Vec<IpAddr> = interfaces.iter().map(IpNet::addr).collect();
    own_addrs.sort();
    own_addrs.dedup();
    let mut networks = BTreeMap::new();
    let mut subnets = BTreeMap::new();
    for network in config.networks.keys() {
        let alias = listen_alias(network);
        let ip = resolve_listen_ip(&alias, resolver, &own_addrs)
            .map_err(|problem| format!("network {network}: {problem}"))?;
        let subnet = interfaces
            .iter()
            .find(|i| i.addr() == ip)
            .expect("own_addrs come from interfaces")
            .trunc();
        networks.insert(network.clone(), ip);
        subnets.insert(network.clone(), subnet);
    }
    let mut host_docker_internal = resolver.lookup(HOST_DOCKER_INTERNAL).unwrap_or_default();
    host_docker_internal.sort();
    host_docker_internal.dedup();
    let exceptions = resolve_exceptions(config, resolver, &own_addrs, &subnets)?;
    Ok(Facts {
        port,
        networks,
        host_docker_internal,
        own_addrs,
        exceptions,
        subnets,
    })
}

/// Resolves every exception host name once and refuses any exception address that is the
/// gateway's or on a caller network: either would let a caller through to another network.
fn resolve_exceptions(
    config: &Config,
    resolver: &Resolver,
    own: &[IpAddr],
    subnets: &BTreeMap<String, IpNet>,
) -> Result<BTreeMap<String, Vec<IpAddr>>, String> {
    let mut resolved: BTreeMap<String, Vec<IpAddr>> = BTreeMap::new();
    for (key, network) in &config.networks {
        for exception in &network.exceptions {
            let addrs = match exception.ip() {
                Some(ip) => vec![ip],
                None => match resolved.get(&exception.host) {
                    Some(addrs) => addrs.clone(),
                    None => {
                        let addrs =
                            resolver.lookup_canonical(&exception.host).ok_or_else(|| {
                                format!(
                                    "network {key}: exceptions: cannot resolve {}",
                                    exception.host
                                )
                            })?;
                        resolved.insert(exception.host.clone(), addrs.clone());
                        addrs
                    }
                },
            };
            for ip in addrs {
                refuse_exception_addr(exception, ip, own, subnets)
                    .map_err(|problem| format!("network {key}: exceptions: {problem}"))?;
            }
        }
    }
    Ok(resolved)
}

fn refuse_exception_addr(
    exception: &HostPort,
    ip: IpAddr,
    own: &[IpAddr],
    subnets: &BTreeMap<String, IpNet>,
) -> Result<(), String> {
    if ip.is_loopback() || ip.is_unspecified() || own.contains(&ip) {
        return Err(format!(
            "{exception} resolves to {ip}, an address of the gateway itself"
        ));
    }
    match subnets.iter().find(|(_, net)| net.contains(&ip)) {
        Some((other, _)) => Err(format!(
            "{exception} resolves to {ip}, an address on caller network {other}"
        )),
        None => Ok(()),
    }
}

fn resolve_listen_ip(alias: &str, resolver: &Resolver, own: &[IpAddr]) -> Result<IpAddr, String> {
    let deadline = Instant::now() + ALIAS_WAIT;
    let addrs = loop {
        if let Some(addrs) = resolver.lookup(alias) {
            break addrs;
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "cannot resolve {alias}; the gateway is not attached to that network (run ./start.sh)"
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

/// The container's interface addresses with their prefix lengths; an address without a
/// netmask counts as a single host.
fn interfaces() -> Result<Vec<IpNet>, String> {
    let ifaddrs = nix::ifaddrs::getifaddrs()
        .map_err(|e| format!("cannot list the container's addresses: {e}"))?;
    Ok(ifaddrs
        .filter_map(|ifa| {
            let addr = ifa.address?;
            let mask = ifa.netmask;
            if let Some(v4) = addr.as_sockaddr_in() {
                let prefix = mask
                    .and_then(|m| {
                        m.as_sockaddr_in()
                            .map(|m| m.ip().to_bits().count_ones() as u8)
                    })
                    .unwrap_or(32);
                IpNet::new(IpAddr::V4(v4.ip()), prefix).ok()
            } else {
                let v6 = addr.as_sockaddr_in6()?;
                let prefix = mask
                    .and_then(|m| {
                        m.as_sockaddr_in6()
                            .map(|m| m.ip().to_bits().count_ones() as u8)
                    })
                    .unwrap_or(128);
                IpNet::new(IpAddr::V6(v6.ip()), prefix).ok()
            }
        })
        .collect())
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

    /// A config of denylist networks, each with the given exceptions.
    fn config_with(sections: &[(&str, &[&str])]) -> Config {
        let mut text = String::from("version: 1\nnetworks:\n");
        for (k, exceptions) in sections {
            text.push_str(&format!("  {k}:\n    mode: denylist\n"));
            if !exceptions.is_empty() {
                let quoted: Vec<String> = exceptions.iter().map(|e| format!("\"{e}\"")).collect();
                text.push_str(&format!("    exceptions: [{}]\n", quoted.join(", ")));
            }
        }
        parse(Path::new("/c.yaml"), &text).unwrap()
    }

    /// The gateway's interfaces: loopback, plus one address on each caller network.
    fn interfaces() -> Vec<IpNet> {
        ["127.0.0.1/8", "::1/128", "172.20.0.2/16", "172.21.0.2/16"]
            .iter()
            .map(|n| n.parse().unwrap())
            .collect()
    }

    fn two_networks_resolver(extra: &[(&str, &[&str])]) -> Resolver {
        let mut pairs: Vec<(&str, &[&str])> = vec![
            ("egress-proxy-workers", &["172.20.0.2"]),
            ("egress-proxy-mini-op", &["172.21.0.2"]),
            ("host.docker.internal", &["192.168.65.254"]),
        ];
        pairs.extend_from_slice(extra);
        resolver(&pairs)
    }

    fn gather_two(workers: &[&str], extra: &[(&str, &[&str])]) -> Result<Facts, String> {
        gather_with(
            &config_with(&[("workers", workers), ("mini-op", &[])]),
            4750,
            &two_networks_resolver(extra),
            &interfaces(),
        )
    }

    #[test]
    fn subnets_recorded() {
        let facts = gather_two(&[], &[]).unwrap();
        assert_eq!(facts.subnets["workers"].to_string(), "172.20.0.0/16");
        assert_eq!(facts.subnets["mini-op"].to_string(), "172.21.0.0/16");
        assert!(facts.exceptions.is_empty());
        assert_eq!(facts.own_addrs.len(), 4);
    }

    #[test]
    fn own_addrs_come_from_interfaces() {
        let err = gather_with(
            &config_with(&[("workers", &[])]),
            4750,
            &resolver(&[
                ("egress-proxy-workers", &["172.20.0.2"]),
                ("host.docker.internal", &[]),
            ]),
            &["172.20.0.2/16".parse().unwrap()],
        );
        assert!(err.is_ok());
        let err = gather_with(
            &config_with(&[("workers", &[])]),
            4750,
            &resolver(&[("egress-proxy-workers", &["172.30.0.2"])]),
            &interfaces(),
        )
        .unwrap_err();
        assert_eq!(
            err,
            "network workers: egress-proxy-workers resolves to 172.30.0.2, which is not this container's address"
        );
    }

    #[test]
    fn exception_resolution() {
        let facts = gather_two(
            &[
                "host.docker.internal:11434",
                "nas.lan:8080",
                "192.168.1.20:11434",
            ],
            &[("nas.lan", &["192.168.1.30", "192.168.1.9", "192.168.1.30"])],
        )
        .unwrap();
        let want: BTreeMap<String, Vec<IpAddr>> = [
            (
                "host.docker.internal".to_string(),
                vec!["192.168.65.254".parse().unwrap()],
            ),
            (
                "nas.lan".to_string(),
                vec![
                    "192.168.1.9".parse().unwrap(),
                    "192.168.1.30".parse().unwrap(),
                ],
            ),
        ]
        .into();
        assert_eq!(facts.exceptions, want);
    }

    #[test]
    fn exception_resolution_is_canonical() {
        let facts = gather_two(&["nas.lan:8080"], &[("nas.lan", &["::ffff:192.168.1.9"])]).unwrap();
        assert_eq!(
            facts.exceptions["nas.lan"],
            vec!["192.168.1.9".parse::<IpAddr>().unwrap()]
        );
    }

    #[test]
    fn exception_own_address_refused() {
        for (entry, extra, ip) in [
            ("127.0.0.1:8080", None, "127.0.0.1"),
            ("127.0.0.2:8080", None, "127.0.0.2"),
            ("[::1]:8080", None, "::1"),
            ("0.0.0.0:8080", None, "0.0.0.0"),
            ("egress-proxy-mini-op:4750", None, "172.21.0.2"),
            ("me.lan:22", Some(("me.lan", "172.20.0.2")), "172.20.0.2"),
        ] {
            let extra: Vec<(&str, &[&str])> = match &extra {
                Some((h, a)) => vec![(*h, std::slice::from_ref(a))],
                None => vec![],
            };
            let err = gather_two(&[entry], &extra).unwrap_err();
            assert_eq!(
                err,
                format!(
                    "network workers: exceptions: {entry} resolves to {ip}, an address of the gateway itself"
                )
            );
        }
    }

    #[test]
    fn exception_mapped_loopback_refused() {
        let err = gather_two(&["[::ffff:127.0.0.1]:8080"], &[]).unwrap_err();
        assert_eq!(
            err,
            "network workers: exceptions: [::ffff:127.0.0.1]:8080 resolves to 127.0.0.1, an address of the gateway itself"
        );
    }

    #[test]
    fn exception_caller_subnet_refused() {
        let err = gather_two(&["box.mini:22"], &[("box.mini", &["172.21.0.7"])]).unwrap_err();
        assert_eq!(
            err,
            "network workers: exceptions: box.mini:22 resolves to 172.21.0.7, an address on caller network mini-op"
        );
        let err = gather_two(&["172.20.0.9:22"], &[]).unwrap_err();
        assert_eq!(
            err,
            "network workers: exceptions: 172.20.0.9:22 resolves to 172.20.0.9, an address on caller network workers"
        );
    }

    #[test]
    fn exception_unresolved_refused() {
        let err = gather_two(&["nas.lan:8080"], &[("nas.lan", &[])]).unwrap_err();
        assert_eq!(err, "network workers: exceptions: cannot resolve nas.lan");
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
            exceptions: [(
                "nas.lan".to_string(),
                vec!["192.168.1.9".parse().unwrap(), "fd00::1".parse().unwrap()],
            )]
            .into(),
            subnets: [("workers".to_string(), "172.20.0.0/16".parse().unwrap())].into(),
        };
        write(&path, &facts).unwrap();
        assert_eq!(read(&path).unwrap(), facts);
    }
}
