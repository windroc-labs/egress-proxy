//! `gateway plan <key>`: the checks verify-egress runs from a probe on caller network
//! `<key>`, one `<name>\t<method>\t<target>` line each. verify-egress runs it with
//! `docker exec` in the running gateway, which holds the config and its start facts; the
//! host facts (the Mac's addresses, default gateways and the host listener's port) come
//! from the command line. Read-only, like `gateway health`.

use std::fmt;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr};

use ipnet::IpNet;

use crate::cli::Opts;
use crate::config::{self, Config, HostPort, Mode, Network, listen_alias};
use crate::facts::{self, Facts, HOST_DOCKER_INTERNAL};
use crate::health::RESTART;
use crate::policy::{self, DENY_FLOOR, Drift};

/// What verify-egress learns on the host.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct HostFacts {
    /// The host's interface addresses with their prefix lengths.
    pub addrs: Vec<IpNet>,
    pub gateways: Vec<IpAddr>,
    /// The port of the listener verify-egress opens on the host's 127.0.0.1.
    pub listener_port: u16,
}

/// How verify-egress probes a target and what it must see (README.md, Verify).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Method {
    /// An https URL through the proxy: CONNECT 200 and an HTTP status 200-399.
    ProxyAllow,
    /// A `host:port` through the proxy: CONNECT 200.
    ProxyOpen,
    /// A `host:port` through the proxy: CONNECT 407.
    ProxyDeny,
    /// A URL without the proxy: no connection.
    DirectNone,
    /// A URL, or `<proxy-url> <url>`, on another caller network: no connection.
    CrossNone,
    /// `name` or `name@server`: the lookup fails.
    DnsNone,
}

impl fmt::Display for Method {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Method::ProxyAllow => "proxy_allow",
            Method::ProxyOpen => "proxy_open",
            Method::ProxyDeny => "proxy_deny",
            Method::DirectNone => "direct_none",
            Method::CrossNone => "cross_none",
            Method::DnsNone => "dns_none",
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Check {
    pub name: &'static str,
    pub method: Method,
    pub target: String,
}

impl fmt::Display for Check {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}\t{}\t{}", self.name, self.method, self.target)
    }
}

/// The public test endpoints the checks use.
const PUBLIC_HTTPS: &str = "example.com";
const PUBLIC_DENY_CANDIDATES: &[&str] = &["example.com", "www.wikipedia.org"];
const PUBLIC_IP: &str = "1.1.1.1";
/// A public name that resolves to 127.0.0.1 (FR-8).
const PRIVATE_RESOLUTION: &str = "localtest.me";
const METADATA: &str = "169.254.169.254:80";
const MAPPED_LOOPBACK: &str = "[::ffff:127.0.0.1]:443";
const DENY_PORT: u16 = 443;

/// The checks for caller network `key`, in a fixed order. Pure.
pub fn plan(
    key: &str,
    config: &Config,
    facts: &Facts,
    host: &HostFacts,
) -> Result<Vec<Check>, String> {
    let network = config
        .networks
        .get(key)
        .ok_or_else(|| format!("network {key} is not in the config"))?;
    let mut checks = Checks {
        network,
        facts,
        list: Vec::new(),
    };

    // Deny rules: one address per floor range, the special addresses, the gateway, the
    // host, the section's own ranges and the extra deny targets.
    for range in DENY_FLOOR {
        let net: IpNet = range.parse().expect("valid floor range");
        checks.deny("proxy_deny", at(first_host(&net), DENY_PORT));
    }
    checks.deny("proxy_deny", HostPort::parse(METADATA).expect("valid"));
    checks.deny(
        "proxy_deny",
        HostPort::parse(MAPPED_LOOPBACK).expect("valid"),
    );
    checks.deny("proxy_deny", named(HOST_DOCKER_INTERNAL, DENY_PORT));
    for ip in &facts.host_docker_internal {
        checks.deny("proxy_deny", at(*ip, DENY_PORT));
    }
    for ip in facts.own_addrs.iter().chain(facts.networks.values()) {
        checks.deny("proxy_deny", at(*ip, facts.port));
    }
    for ip in host_targets(host) {
        checks.deny("proxy_deny", at(ip, DENY_PORT));
    }
    for ip in &host.gateways {
        checks.deny("proxy_deny", at(*ip, DENY_PORT));
    }
    checks.deny(
        "proxy_deny",
        named(HOST_DOCKER_INTERNAL, host.listener_port),
    );
    for range in &network.deny_ranges {
        checks.deny("proxy_deny", at(first_host(range), DENY_PORT));
    }
    for target in &network.verify_deny_targets {
        checks.deny("proxy_deny", target.clone());
    }

    // The mode's own allows and denies.
    match network.mode {
        Mode::Denylist => checks.push("proxy_allow", Method::ProxyAllow, https(PUBLIC_HTTPS)),
        Mode::Allowlist => {
            for entry in network.allow.iter().filter(|e| !e.starts_with("*.")) {
                checks.push("proxy_allow", Method::ProxyAllow, https(entry));
            }
            if let Some(public) = PUBLIC_DENY_CANDIDATES
                .iter()
                .find(|h| !allowed_by(&network.allow, h))
            {
                checks.deny("proxy_deny", named(public, DENY_PORT));
            }
        }
    }
    // Resolves to loopback, so denied even when allowed by name.
    checks.push(
        "proxy_deny",
        Method::ProxyDeny,
        named(PRIVATE_RESOLUTION, DENY_PORT).to_string(),
    );

    // Each exception: its port opens, the next port of the same host stays denied.
    for exception in &network.exceptions {
        for target in exception_targets(network, exception, facts) {
            let other = HostPort {
                port: if target.port == u16::MAX {
                    target.port - 1
                } else {
                    target.port + 1
                },
                ..target.clone()
            };
            checks.push("exception_open", Method::ProxyOpen, target.to_string());
            checks.deny("exception_other_port", other);
        }
    }

    // Other caller networks: their listeners stay out of reach, their allows stay theirs.
    for (other_key, other) in config.networks.iter().filter(|(k, _)| *k != key) {
        if let Some(ip) = facts.networks.get(other_key) {
            let proxy = format!("http://{}", at(*ip, facts.port));
            checks.push("cross_none", Method::CrossNone, format!("{proxy}/"));
            checks.push(
                "cross_none",
                Method::CrossNone,
                format!("{proxy} {}", https(PUBLIC_HTTPS)),
            );
        }
        let alias = format!("http://{}:{}", listen_alias(other_key), facts.port);
        checks.push("cross_none", Method::CrossNone, format!("{alias}/"));
        for exception in &other.exceptions {
            for target in exception_targets(other, exception, facts) {
                checks.deny("proxy_deny", target);
            }
        }
        if network.mode == Mode::Allowlist {
            for entry in other.allow.iter().filter(|e| !e.starts_with("*.")) {
                if !allowed_by(&network.allow, entry) {
                    checks.deny("proxy_deny", named(entry, DENY_PORT));
                }
            }
        }
    }

    // No way out without the proxy.
    for url in [
        https(PUBLIC_IP),
        https(PUBLIC_HTTPS),
        format!(
            "http://{}/",
            named(HOST_DOCKER_INTERNAL, host.listener_port)
        ),
    ] {
        checks.push("direct_none", Method::DirectNone, url);
    }
    let direct_ips: Vec<IpAddr> = host
        .gateways
        .iter()
        .copied()
        .chain(host_addrs(host).filter(IpAddr::is_ipv4))
        .collect();
    for ip in direct_ips {
        checks.push(
            "direct_none",
            Method::DirectNone,
            format!("https://{}/", at(ip, DENY_PORT)),
        );
    }
    checks.push("dns_none", Method::DnsNone, PUBLIC_HTTPS.to_string());
    checks.push(
        "dns_none",
        Method::DnsNone,
        format!("{PUBLIC_HTTPS}@{PUBLIC_IP}"),
    );
    Ok(checks.list)
}

struct Checks<'a> {
    network: &'a Network,
    facts: &'a Facts,
    list: Vec<Check>,
}

impl Checks<'_> {
    fn push(&mut self, name: &'static str, method: Method, target: String) {
        let check = Check {
            name,
            method,
            target,
        };
        if !self.list.contains(&check) {
            self.list.push(check);
        }
    }

    /// A deny check, unless one of the network's exceptions opens `target`.
    fn deny(&mut self, name: &'static str, target: HostPort) {
        if !opened_by_exception(self.network, self.facts, &target) {
            self.push(name, Method::ProxyDeny, target.to_string());
        }
    }
}

/// Whether an exception of `network` opens `target`: the same port and the same name or
/// canonical address.
fn opened_by_exception(network: &Network, facts: &Facts, target: &HostPort) -> bool {
    network.exceptions.iter().any(|e| {
        e.port == target.port
            && (e.host == target.host
                || target
                    .ip()
                    .is_some_and(|ip| policy::exception_addrs(e, facts).contains(&ip)))
    })
}

/// Where to probe an exception: in allowlist mode the ACL lists its start-time addresses,
/// so a named one is probed at each; otherwise as written.
fn exception_targets(network: &Network, exception: &HostPort, facts: &Facts) -> Vec<HostPort> {
    if network.mode == Mode::Allowlist && exception.ip().is_none() {
        policy::exception_addrs(exception, facts)
            .into_iter()
            .map(|ip| at(ip, exception.port))
            .collect()
    } else {
        vec![exception.clone()]
    }
}

/// smokescreen's rule: `*.d` matches every subdomain of `d`, not `d` itself.
pub fn allowed_by(allow: &[String], host: &str) -> bool {
    allow.iter().any(|entry| match entry.strip_prefix("*.") {
        Some(domain) => host
            .strip_suffix(domain)
            .is_some_and(|rest| rest.ends_with('.') && rest.len() > 1),
        None => entry == host,
    })
}

/// The host's own addresses worth probing: not loopback, link-local or unspecified (the
/// floor covers those classes).
fn host_addrs(host: &HostFacts) -> impl Iterator<Item = IpAddr> + '_ {
    host.addrs
        .iter()
        .map(IpNet::addr)
        .filter(|ip| !(ip.is_loopback() || ip.is_unspecified() || is_link_local(ip)))
}

/// The host's addresses plus one other address in each of their prefixes.
fn host_targets(host: &HostFacts) -> Vec<IpAddr> {
    let mut out = Vec::new();
    for net in &host.addrs {
        let ip = net.addr();
        if ip.is_loopback() || ip.is_unspecified() || is_link_local(&ip) {
            continue;
        }
        out.push(ip);
        let wide_enough = match net {
            IpNet::V4(n) => n.prefix_len() <= 30,
            IpNet::V6(n) => n.prefix_len() <= 126,
        };
        if wide_enough {
            let first = first_host(&net.trunc());
            out.push(if first == ip {
                nth_host(&net.trunc(), 2)
            } else {
                first
            });
        }
    }
    out
}

fn is_link_local(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_link_local(),
        IpAddr::V6(v6) => (v6.segments()[0] & 0xffc0) == 0xfe80,
    }
}

/// The first host address of `net`: its network address plus one, or the address itself
/// for a single-address range.
fn first_host(net: &IpNet) -> IpAddr {
    nth_host(net, 1)
}

fn nth_host(net: &IpNet, n: u8) -> IpAddr {
    match net {
        IpNet::V4(v4) if v4.prefix_len() < 32 => {
            IpAddr::V4(Ipv4Addr::from(u32::from(v4.network()) + u32::from(n)))
        }
        IpNet::V6(v6) if v6.prefix_len() < 128 => {
            IpAddr::V6(Ipv6Addr::from(u128::from(v6.network()) + u128::from(n)))
        }
        other => other.addr(),
    }
}

fn at(ip: IpAddr, port: u16) -> HostPort {
    HostPort {
        host: ip.to_canonical().to_string(),
        port,
    }
}

fn named(host: &str, port: u16) -> HostPort {
    HostPort {
        host: host.to_string(),
        port,
    }
}

fn https(host: &str) -> String {
    format!("https://{host}/")
}

/// Prints the plan for `opts.plan_key`; returns 0, or 2 when it cannot be made.
pub fn run(opts: &Opts) -> u8 {
    match make(opts) {
        Ok(checks) => {
            for check in checks {
                println!("{check}");
            }
            0
        }
        Err(e) => {
            eprintln!("gateway: {e}");
            2
        }
    }
}

fn make(opts: &Opts) -> Result<Vec<Check>, String> {
    let key = opts.plan_key.as_deref().ok_or("plan needs a network key")?;
    let config = config::load_served(&opts.config, opts.advertised.as_deref())?;
    let facts =
        facts::read(&opts.run_dir.join("facts.json")).map_err(|e| format!("not started: {e}"))?;
    let outcomes =
        policy::drift(&config, &facts, &opts.run_dir).map_err(|e| format!("{e}; {RESTART}"))?;
    for (network, outcome) in outcomes {
        match outcome {
            Drift::Matches => {}
            Drift::Differs => {
                return Err(format!(
                    "network {network}: running policy differs from the config; {RESTART}"
                ));
            }
            Drift::Unreadable(e) => {
                return Err(format!(
                    "network {network}: cannot read the running policy: {e}"
                ));
            }
        }
    }
    plan(key, &config, &facts, &opts.host)
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::path::Path;

    use super::*;
    use crate::config::parse;

    fn config(text: &str) -> Config {
        parse(Path::new("/c.yaml"), text).unwrap()
    }

    fn facts() -> Facts {
        Facts {
            port: 4750,
            networks: BTreeMap::from([
                ("workers".to_string(), "172.20.0.2".parse().unwrap()),
                ("mini-op".to_string(), "172.21.0.2".parse().unwrap()),
            ]),
            host_docker_internal: vec!["192.168.65.254".parse().unwrap()],
            own_addrs: vec![
                "127.0.0.1".parse().unwrap(),
                "172.18.0.2".parse().unwrap(),
                "172.20.0.2".parse().unwrap(),
                "172.21.0.2".parse().unwrap(),
            ],
            exceptions: BTreeMap::from([(
                "host.docker.internal".to_string(),
                vec!["192.168.65.254".parse().unwrap()],
            )]),
            subnets: BTreeMap::new(),
        }
    }

    fn host() -> HostFacts {
        HostFacts {
            addrs: vec![
                "192.168.1.20/24".parse().unwrap(),
                "127.0.0.1/8".parse().unwrap(),
                "fe80::1/64".parse().unwrap(),
                "2001:db8:1:2::20/64".parse().unwrap(),
                "198.51.100.9/32".parse().unwrap(),
            ],
            gateways: vec!["192.168.1.1".parse().unwrap()],
            listener_port: 50123,
        }
    }

    const TWO: &str = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    exceptions: [\"host.docker.internal:11434\"]\n    deny_ranges: [203.0.113.0/24]\n    verify: {deny_targets: [\"198.51.100.30:5000\"]}\n  mini-op:\n    mode: allowlist\n    allow: [api.anthropic.com, claude.ai, \"*.claude.com\"]\n    exceptions: [\"192.168.1.30:22\", \"host.docker.internal:2222\"]\n";

    fn lines(key: &str) -> Vec<String> {
        plan(key, &config(TWO), &facts(), &host())
            .unwrap()
            .iter()
            .map(Check::to_string)
            .collect()
    }

    fn has(lines: &[String], line: &str) -> bool {
        lines.iter().any(|l| l == line)
    }

    #[test]
    fn denylist_plan_covers_floor_and_specials() {
        let got = lines("workers");
        for target in [
            "0.0.0.1:443",
            "10.0.0.1:443",
            "100.64.0.1:443",
            "127.0.0.1:443",
            "169.254.0.1:443",
            "172.16.0.1:443",
            "192.168.0.1:443",
            "[::]:443",
            "[::1]:443",
            "[fc00::1]:443",
            "[fe80::1]:443",
            "169.254.169.254:80",
            "[::ffff:127.0.0.1]:443",
            "host.docker.internal:443",
            "192.168.65.254:443",
            "172.18.0.2:4750",
            "172.21.0.2:4750",
            "host.docker.internal:50123",
            "203.0.113.1:443",
            "198.51.100.30:5000",
        ] {
            assert!(
                has(&got, &format!("proxy_deny\tproxy_deny\t{target}")),
                "{target} in {got:#?}"
            );
        }
    }

    #[test]
    fn host_facts_targets() {
        let got = lines("workers");
        for target in [
            "192.168.1.20:443",
            "192.168.1.1:443",
            "[2001:db8:1:2::20]:443",
            "[2001:db8:1:2::1]:443",
            "198.51.100.9:443",
        ] {
            assert!(
                has(&got, &format!("proxy_deny\tproxy_deny\t{target}")),
                "{target} in {got:#?}"
            );
        }
        // The prefix's first host is the gateway here; a NIC on it gets the second.
        let mut on_first = host();
        on_first.addrs = vec!["10.1.0.1/16".parse().unwrap()];
        let checks = plan("workers", &config(TWO), &facts(), &on_first).unwrap();
        let targets: Vec<&str> = checks.iter().map(|c| c.target.as_str()).collect();
        assert!(targets.contains(&"10.1.0.2:443"), "{targets:?}");
        // Loopback and link-local NIC addresses are left to the floor; a /32 adds nothing.
        assert!(!has(&got, "proxy_deny\tproxy_deny\t[fe80::2]:443"));
        assert!(!has(&got, "proxy_deny\tproxy_deny\t198.51.100.10:443"));
        assert!(
            !got.iter()
                .any(|l| l.starts_with("direct_none") && l.contains("127.0.0.1"))
        );
    }

    #[test]
    fn exception_target_not_denied() {
        let mut c = config(TWO);
        c.networks.get_mut("workers").unwrap().exceptions =
            vec![HostPort::parse("192.168.1.20:443").unwrap()];
        let checks = plan("workers", &c, &facts(), &host()).unwrap();
        assert!(
            !checks
                .iter()
                .any(|ch| ch.method == Method::ProxyDeny && ch.target == "192.168.1.20:443")
        );
        assert!(checks.iter().any(|ch| ch.name == "exception_open"
            && ch.method == Method::ProxyOpen
            && ch.target == "192.168.1.20:443"));
        // host.docker.internal:11434 opens the recorded address at that port too.
        let got = lines("workers");
        assert!(!has(&got, "proxy_deny\tproxy_deny\t192.168.65.254:11434"));
    }

    #[test]
    fn direct_and_dns_checks() {
        for key in ["workers", "mini-op"] {
            let got = lines(key);
            for line in [
                "direct_none\tdirect_none\thttps://1.1.1.1/",
                "direct_none\tdirect_none\thttps://example.com/",
                "direct_none\tdirect_none\thttp://host.docker.internal:50123/",
                "direct_none\tdirect_none\thttps://192.168.1.1:443/",
                "direct_none\tdirect_none\thttps://192.168.1.20:443/",
                "direct_none\tdirect_none\thttps://198.51.100.9:443/",
                "dns_none\tdns_none\texample.com",
                "dns_none\tdns_none\texample.com@1.1.1.1",
            ] {
                assert!(has(&got, line), "{key}: {line} in {got:#?}");
            }
        }
    }

    #[test]
    fn denylist_mode_checks() {
        let got = lines("workers");
        assert!(has(&got, "proxy_allow\tproxy_allow\thttps://example.com/"));
        assert!(has(&got, "proxy_deny\tproxy_deny\tlocaltest.me:443"));
    }

    #[test]
    fn allowlist_mode_checks() {
        let got = lines("mini-op");
        assert!(has(
            &got,
            "proxy_allow\tproxy_allow\thttps://api.anthropic.com/"
        ));
        assert!(has(&got, "proxy_allow\tproxy_allow\thttps://claude.ai/"));
        assert!(!got.iter().any(|l| l.contains("*.claude.com")));
        assert!(has(&got, "proxy_deny\tproxy_deny\texample.com:443"));
        assert!(has(&got, "proxy_deny\tproxy_deny\tlocaltest.me:443"));
        assert!(
            !got.iter()
                .any(|l| l.starts_with("proxy_allow\tproxy_allow\thttps://example.com"))
        );
        // With example.com allowed, the public deny check takes the next candidate.
        let c = config(
            "version: 1\nnetworks:\n  api:\n    mode: allowlist\n    allow: [example.com, localtest.me]\n",
        );
        let f = Facts {
            networks: BTreeMap::from([("api".to_string(), "172.22.0.2".parse().unwrap())]),
            ..facts()
        };
        let got: Vec<String> = plan("api", &c, &f, &host())
            .unwrap()
            .iter()
            .map(Check::to_string)
            .collect();
        assert!(has(&got, "proxy_deny\tproxy_deny\twww.wikipedia.org:443"));
        assert!(has(&got, "proxy_deny\tproxy_deny\tlocaltest.me:443"));
    }

    #[test]
    fn glob_rule() {
        let allow = vec!["*.claude.com".to_string(), "claude.ai".to_string()];
        assert!(allowed_by(&allow, "api.claude.com"));
        assert!(!allowed_by(&allow, "claude.com"));
        assert!(!allowed_by(&allow, "xclaude.com"));
        assert!(allowed_by(&allow, "claude.ai"));
        assert!(!allowed_by(&allow, "www.claude.ai"));
    }

    #[test]
    fn exception_checks() {
        let got = lines("workers");
        assert!(has(
            &got,
            "exception_open\tproxy_open\thost.docker.internal:11434"
        ));
        assert!(has(
            &got,
            "exception_other_port\tproxy_deny\thost.docker.internal:11435"
        ));
        // Allowlist: a named exception is probed at its recorded address, not by name.
        let got = lines("mini-op");
        assert!(has(&got, "exception_open\tproxy_open\t192.168.1.30:22"));
        assert!(has(
            &got,
            "exception_other_port\tproxy_deny\t192.168.1.30:23"
        ));
        assert!(has(&got, "exception_open\tproxy_open\t192.168.65.254:2222"));
        assert!(has(
            &got,
            "exception_other_port\tproxy_deny\t192.168.65.254:2223"
        ));
        assert!(!has(
            &got,
            "exception_open\tproxy_open\thost.docker.internal:2222"
        ));
        // The last port steps down.
        let c = config(
            "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    exceptions: [\"10.9.9.9:65535\"]\n",
        );
        let f = Facts {
            networks: BTreeMap::from([("workers".to_string(), "172.20.0.2".parse().unwrap())]),
            ..facts()
        };
        let checks = plan("workers", &c, &f, &host()).unwrap();
        assert!(
            checks
                .iter()
                .any(|ch| ch.name == "exception_other_port" && ch.target == "10.9.9.9:65534")
        );
    }

    #[test]
    fn cross_network_checks() {
        let got = lines("workers");
        for line in [
            "cross_none\tcross_none\thttp://172.21.0.2:4750/",
            "cross_none\tcross_none\thttp://172.21.0.2:4750 https://example.com/",
            "cross_none\tcross_none\thttp://egress-proxy-mini-op:4750/",
            "proxy_deny\tproxy_deny\t192.168.1.30:22",
            "proxy_deny\tproxy_deny\t192.168.65.254:2222",
        ] {
            assert!(has(&got, line), "{line} in {got:#?}");
        }
        let got = lines("mini-op");
        for line in [
            "cross_none\tcross_none\thttp://172.20.0.2:4750/",
            "cross_none\tcross_none\thttp://172.20.0.2:4750 https://example.com/",
            "cross_none\tcross_none\thttp://egress-proxy-workers:4750/",
            "proxy_deny\tproxy_deny\thost.docker.internal:11434",
        ] {
            assert!(has(&got, line), "{line} in {got:#?}");
        }
    }

    #[test]
    fn unknown_key_errors() {
        let err = plan("other", &config(TWO), &facts(), &host()).unwrap_err();
        assert_eq!(err, "network other is not in the config");
    }

    #[test]
    fn no_leading_dash() {
        for key in ["workers", "mini-op"] {
            for check in plan(key, &config(TWO), &facts(), &host()).unwrap() {
                for part in check.target.split([' ', '@']) {
                    assert!(!part.starts_with('-'), "{check}");
                }
                assert_eq!(check.to_string().split('\t').count(), 3, "{check}");
            }
        }
    }
}
