//! The local config (`~/.egress/config.local.yaml`): parsing and validation.
//!
//! The YAML is read as an untyped value and checked by hand, so every error names the
//! network and key it is about.

use std::collections::BTreeMap;
use std::fmt;
use std::net::{IpAddr, Ipv6Addr};
use std::path::{Path, PathBuf};

use ipnet::{IpNet, Ipv6Net};
use serde_yaml::{Mapping, Value};

/// The only config format version this gateway knows.
pub const FORMAT_VERSION: u64 = 1;

const TOP_KEYS: &[&str] = &["version", "networks"];
const NETWORK_KEYS: &[&str] = &[
    "mode",
    "deny_ranges",
    "allow",
    "exceptions",
    "health",
    "verify",
];
/// The compose key of the gateway's own way out; its Docker name would collide.
const RESERVED_KEY: &str = "uplink";
const HEALTH_KEYS: &[&str] = &["allow_probe", "deny_probe"];
const VERIFY_KEYS: &[&str] = &["deny_targets"];
const DEFAULT_DENY_PROBE: &str = "169.254.169.254:80";
const DEFAULT_DENYLIST_ALLOW_PROBE: &str = "example.com:443";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub networks: BTreeMap<String, Network>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Network {
    pub mode: Mode,
    /// Ranges added to the deny floor.
    pub deny_ranges: Vec<IpNet>,
    /// Allowed domains or `*.domain` globs (allowlist only).
    pub allow: Vec<String>,
    /// Destinations opened through the deny rules, sorted and deduplicated.
    pub exceptions: Vec<HostPort>,
    pub health: Health,
    /// Extra targets verify-egress expects denied, sorted and deduplicated. Policy and
    /// health never read them.
    pub verify_deny_targets: Vec<HostPort>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Denylist,
    Allowlist,
}

impl fmt::Display for Mode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Mode::Denylist => "denylist",
            Mode::Allowlist => "allowlist",
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Health {
    /// A target the network's policy allows.
    pub allow_probe: HostPort,
    /// A target the network's policy denies.
    pub deny_probe: HostPort,
}

/// A `host:port` or `[v6]:port` target.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct HostPort {
    pub host: String,
    pub port: u16,
}

impl HostPort {
    pub fn parse(text: &str) -> Option<HostPort> {
        let (host, port) = text.rsplit_once(':')?;
        let port: u16 = port.parse().ok().filter(|p| *p != 0)?;
        let host = match host.strip_prefix('[') {
            Some(rest) => rest
                .strip_suffix(']')?
                .parse::<Ipv6Addr>()
                .ok()?
                .to_string(),
            None if host.contains(':') => return None,
            None if host.is_empty() => return None,
            None => host.to_string(),
        };
        Some(HostPort { host, port })
    }

    /// The host as a canonical IP address (IPv4-mapped IPv6 as IPv4), or `None` for a name.
    pub fn ip(&self) -> Option<IpAddr> {
        self.host.parse::<IpAddr>().ok().map(|ip| ip.to_canonical())
    }
}

impl fmt::Display for HostPort {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.host.contains(':') {
            write!(f, "[{}]:{}", self.host, self.port)
        } else {
            write!(f, "{}:{}", self.host, self.port)
        }
    }
}

/// The Docker network of caller network `key`.
pub fn network_name(key: &str) -> String {
    format!("egress-{key}")
}

/// The listen alias of caller network `key`: the gateway's DNS name on it.
pub fn listen_alias(key: &str) -> String {
    format!("egress-proxy-{key}")
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConfigError {
    pub path: PathBuf,
    pub network: Option<String>,
    pub problem: String,
}

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "config {}: ", self.path.display())?;
        if let Some(network) = &self.network {
            write!(f, "network {network}: ")?;
        }
        f.write_str(&self.problem)
    }
}

impl std::error::Error for ConfigError {}

/// Reads and validates the config at `path`.
pub fn load(path: &Path) -> Result<Config, ConfigError> {
    let text = std::fs::read_to_string(path).map_err(|e| ConfigError {
        path: path.to_path_buf(),
        network: None,
        problem: format!("cannot read: {e}"),
    })?;
    parse(path, &text)
}

/// Validates config `text`; `path` only labels errors.
pub fn parse(path: &Path, text: &str) -> Result<Config, ConfigError> {
    let fail = |network: Option<&str>, problem: String| ConfigError {
        path: path.to_path_buf(),
        network: network.map(str::to_string),
        problem,
    };
    let value: Value =
        serde_yaml::from_str(text).map_err(|e| fail(None, format!("not valid YAML: {e}")))?;
    let top = value
        .as_mapping()
        .ok_or_else(|| fail(None, "want a mapping with keys version and networks".into()))?;
    check_keys(top, TOP_KEYS, "").map_err(|p| fail(None, p))?;

    match top.get("version") {
        None => return Err(fail(None, "missing key version".into())),
        Some(Value::Number(n)) if n.as_u64() == Some(FORMAT_VERSION) => {}
        Some(Value::Number(n)) => {
            return Err(fail(
                None,
                format!("version {n} is not supported (known: {FORMAT_VERSION})"),
            ));
        }
        Some(Value::String(s)) => {
            return Err(fail(
                None,
                format!("version: want the number {FORMAT_VERSION}, got the string \"{s}\""),
            ));
        }
        Some(v) => {
            return Err(fail(
                None,
                format!(
                    "version: want the number {FORMAT_VERSION}, got {}",
                    scalar_text(v)
                ),
            ));
        }
    }

    let networks = match top.get("networks") {
        None => return Err(fail(None, "missing key networks".into())),
        Some(Value::Mapping(m)) => m,
        Some(_) => {
            return Err(fail(
                None,
                "networks: want a mapping of network key to section".into(),
            ));
        }
    };
    if networks.is_empty() {
        return Err(fail(None, "networks is empty".into()));
    }

    let mut out = BTreeMap::new();
    for (key, section) in networks {
        let key = match key.as_str() {
            Some(k) if valid_network_key(k) => k,
            _ => {
                return Err(fail(
                    None,
                    format!(
                        "network key {} is invalid (want [a-z][a-z0-9-]{{0,30}})",
                        scalar_text(key)
                    ),
                ));
            }
        };
        if key == RESERVED_KEY {
            return Err(fail(
                None,
                format!(
                    "network key {key} is reserved (the gateway's own network {})",
                    network_name(key)
                ),
            ));
        }
        let network = parse_network(section).map_err(|p| fail(Some(key), p))?;
        out.insert(key.to_string(), network);
    }
    Ok(Config { networks: out })
}

/// Checks that the config serves exactly the networks the gateway advertises.
pub fn check_advertised(
    path: &Path,
    config: &Config,
    advertised: &[String],
) -> Result<(), ConfigError> {
    let mut want: Vec<&str> = advertised.iter().map(String::as_str).collect();
    want.sort_unstable();
    want.dedup();
    let have: Vec<&str> = config.networks.keys().map(String::as_str).collect();
    if have == want {
        return Ok(());
    }
    Err(ConfigError {
        path: path.to_path_buf(),
        network: None,
        problem: format!(
            "networks [{}] differ from the gateway's networks [{}]; run ./start.sh",
            have.join(", "),
            want.join(", ")
        ),
    })
}

/// Loads the config at `path` and checks it serves exactly the networks in
/// `advertised` (the unparsed `EGRESS_NETWORKS`).
pub fn load_served(path: &Path, advertised: Option<&str>) -> Result<Config, String> {
    let advertised = parse_advertised(advertised)?;
    let config = load(path).map_err(|e| e.to_string())?;
    check_advertised(path, &config, &advertised).map_err(|e| e.to_string())?;
    Ok(config)
}

/// Parses `EGRESS_NETWORKS`: comma-separated network keys.
pub fn parse_advertised(value: Option<&str>) -> Result<Vec<String>, String> {
    let value = value.ok_or("EGRESS_NETWORKS is not set (./start.sh sets it)")?;
    let keys: Vec<String> = value
        .split(',')
        .map(str::trim)
        .filter(|k| !k.is_empty())
        .map(str::to_string)
        .collect();
    if keys.is_empty() {
        return Err("EGRESS_NETWORKS is empty (./start.sh sets it)".into());
    }
    if let Some(bad) = keys.iter().find(|k| !valid_network_key(k)) {
        return Err(format!(
            "EGRESS_NETWORKS: network key {bad} is invalid (want [a-z][a-z0-9-]{{0,30}})"
        ));
    }
    Ok(keys)
}

fn parse_network(section: &Value) -> Result<Network, String> {
    let section = section
        .as_mapping()
        .ok_or("want a mapping with keys mode, deny_ranges, allow, exceptions, health, verify")?;
    check_keys(section, NETWORK_KEYS, "")?;

    let mode = match section.get("mode") {
        None => return Err("missing key mode".into()),
        Some(Value::String(s)) if s == "denylist" => Mode::Denylist,
        Some(Value::String(s)) if s == "allowlist" => Mode::Allowlist,
        Some(v) => {
            return Err(format!(
                "mode: want denylist or allowlist, got {}",
                scalar_text(v)
            ));
        }
    };

    let deny_ranges = string_list(section, "deny_ranges")?
        .unwrap_or_default()
        .iter()
        .map(|r| parse_deny_range(r))
        .collect::<Result<Vec<_>, _>>()?;

    let allow = match (mode, string_list(section, "allow")?) {
        (Mode::Denylist, Some(_)) => return Err("allow: only for mode allowlist".into()),
        (Mode::Denylist, None) => Vec::new(),
        (Mode::Allowlist, None) => return Err("missing key allow".into()),
        (Mode::Allowlist, Some(list)) if list.is_empty() => return Err("allow: is empty".into()),
        (Mode::Allowlist, Some(list)) => {
            for entry in &list {
                check_allow_entry(entry)?;
            }
            list
        }
    };

    let mut exceptions = string_list(section, "exceptions")?
        .unwrap_or_default()
        .iter()
        .map(|e| parse_exception(e))
        .collect::<Result<Vec<_>, _>>()?;
    exceptions.sort();
    exceptions.dedup();

    let health = parse_health(section.get("health"), mode, &allow)?;
    let verify_deny_targets = parse_verify(section.get("verify"))?;
    Ok(Network {
        mode,
        deny_ranges,
        allow,
        exceptions,
        health,
        verify_deny_targets,
    })
}

/// The `verify` mapping: verify-egress's extra deny targets.
fn parse_verify(value: Option<&Value>) -> Result<Vec<HostPort>, String> {
    let verify = match value {
        None => return Ok(Vec::new()),
        Some(Value::Mapping(m)) => m,
        Some(_) => return Err("verify: want a mapping with key deny_targets".into()),
    };
    check_keys(verify, VERIFY_KEYS, "verify.")?;
    let mut targets = string_list(verify, "deny_targets")
        .map_err(|e| format!("verify.{e}"))?
        .unwrap_or_default()
        .iter()
        .map(|t| {
            host_port_entry(t).ok_or_else(|| format!("verify.deny_targets: {t} is not host:port"))
        })
        .collect::<Result<Vec<_>, _>>()?;
    targets.sort();
    targets.dedup();
    Ok(targets)
}

fn parse_health(value: Option<&Value>, mode: Mode, allow: &[String]) -> Result<Health, String> {
    let empty = Mapping::new();
    let health = match value {
        None => &empty,
        Some(Value::Mapping(m)) => m,
        Some(_) => return Err("health: want a mapping with keys allow_probe, deny_probe".into()),
    };
    check_keys(health, HEALTH_KEYS, "health.")?;
    let probe = |key: &str| -> Result<Option<HostPort>, String> {
        match health.get(key) {
            None => Ok(None),
            Some(Value::String(s)) => HostPort::parse(s)
                .map(Some)
                .ok_or_else(|| format!("health.{key}: want host:port, got {s}")),
            Some(v) => Err(format!(
                "health.{key}: want host:port, got {}",
                scalar_text(v)
            )),
        }
    };
    let deny_probe = probe("deny_probe")?
        .unwrap_or_else(|| HostPort::parse(DEFAULT_DENY_PROBE).expect("valid default"));
    let allow_probe = match (probe("allow_probe")?, mode) {
        (Some(p), _) => p,
        (None, Mode::Denylist) => {
            HostPort::parse(DEFAULT_DENYLIST_ALLOW_PROBE).expect("valid default")
        }
        (None, Mode::Allowlist) => allow
            .iter()
            .find(|entry| !entry.starts_with("*."))
            .map(|host| HostPort {
                host: host.clone(),
                port: 443,
            })
            .ok_or("health.allow_probe: required when every allow entry is a glob")?,
    };
    Ok(Health {
        allow_probe,
        deny_probe,
    })
}

fn parse_deny_range(text: &str) -> Result<IpNet, String> {
    let net: IpNet = text
        .parse()
        .map_err(|_| format!("deny_ranges: {text} is not a CIDR range"))?;
    let net = net.trunc();
    let mapped: Ipv6Net = "::ffff:0:0/96".parse().expect("valid range");
    if let IpNet::V6(v6) = net
        && (mapped.contains(&v6) || v6.contains(&mapped))
    {
        return Err(format!(
            "deny_ranges: {text} overlaps ::ffff:0:0/96, which smokescreen would apply to every IPv4 address"
        ));
    }
    Ok(net)
}

/// An exception: `host:port` or `[v6]:port`, the host an IP address or a domain, which is
/// lower-cased (smokescreen's ACL refuses a domain not in its normalized form).
fn parse_exception(entry: &str) -> Result<HostPort, String> {
    host_port_entry(entry).ok_or_else(|| format!("exceptions: {entry} is not host:port"))
}

/// A `host:port` entry whose host is an IP address or a domain, lower-cased.
fn host_port_entry(entry: &str) -> Option<HostPort> {
    HostPort::parse(entry)
        .filter(|hp| hp.host.parse::<IpAddr>().is_ok() || valid_domain(&hp.host))
        .map(|hp| HostPort {
            host: hp.host.to_ascii_lowercase(),
            ..hp
        })
}

fn check_allow_entry(entry: &str) -> Result<(), String> {
    if entry.contains(':') {
        return Err(format!(
            "allow: host:port entries go under exceptions ({entry})"
        ));
    }
    if valid_domain(entry.strip_prefix("*.").unwrap_or(entry)) {
        Ok(())
    } else {
        Err(format!("allow: {entry} is not a domain or *.domain glob"))
    }
}

fn valid_domain(name: &str) -> bool {
    !name.is_empty()
        && name.split('.').all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && label.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')
                && !label.starts_with('-')
                && !label.ends_with('-')
        })
}

fn string_list(map: &Mapping, key: &str) -> Result<Option<Vec<String>>, String> {
    let Some(value) = map.get(key) else {
        return Ok(None);
    };
    let items = value
        .as_sequence()
        .ok_or_else(|| format!("{key}: want a list"))?;
    items
        .iter()
        .map(|item| match item {
            Value::String(s) => Ok(s.clone()),
            other => Err(format!("{key}: want strings, got {}", scalar_text(other))),
        })
        .collect::<Result<Vec<_>, _>>()
        .map(Some)
}

fn check_keys(map: &Mapping, known: &[&str], prefix: &str) -> Result<(), String> {
    for key in map.keys() {
        match key.as_str() {
            Some(k) if known.contains(&k) => {}
            _ => return Err(format!("unknown key {prefix}{}", scalar_text(key))),
        }
    }
    Ok(())
}

pub fn valid_network_key(key: &str) -> bool {
    let mut chars = key.chars();
    matches!(chars.next(), Some('a'..='z'))
        && key.len() <= 31
        && chars.all(|c| matches!(c, 'a'..='z' | '0'..='9' | '-'))
}

fn scalar_text(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => "null".into(),
        other => serde_yaml::to_string(other)
            .map(|s| s.trim_end().to_string())
            .unwrap_or_else(|_| "?".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_ok(text: &str) -> Config {
        parse(Path::new("/c.yaml"), text).expect("valid config")
    }

    fn parse_err(text: &str) -> String {
        parse(Path::new("/c.yaml"), text)
            .expect_err("invalid config")
            .to_string()
    }

    const WORKERS: &str = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n";

    #[test]
    fn denylist_defaults() {
        let config = parse_ok(WORKERS);
        let workers = &config.networks["workers"];
        assert_eq!(workers.mode, Mode::Denylist);
        assert!(workers.deny_ranges.is_empty());
        assert!(workers.allow.is_empty());
        assert_eq!(workers.health.allow_probe.to_string(), "example.com:443");
        assert_eq!(workers.health.deny_probe.to_string(), "169.254.169.254:80");
    }

    #[test]
    fn allowlist_with_probes_and_ranges() {
        let config = parse_ok(
            "version: 1\nnetworks:\n  api:\n    mode: allowlist\n    allow: [\"*.example.org\", example.com]\n    deny_ranges: [203.0.113.7/32, \"2001:db8::/32\"]\n    health:\n      deny_probe: \"[2001:db8::1]:443\"\n",
        );
        let api = &config.networks["api"];
        assert_eq!(api.mode, Mode::Allowlist);
        assert_eq!(api.allow, vec!["*.example.org", "example.com"]);
        assert_eq!(api.health.allow_probe.to_string(), "example.com:443");
        assert_eq!(api.health.deny_probe.to_string(), "[2001:db8::1]:443");
        assert_eq!(api.deny_ranges.len(), 2);
    }

    #[test]
    fn deny_range_host_bits_are_cleared() {
        let config = parse_ok(
            "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    deny_ranges: [198.51.100.9/24]\n",
        );
        assert_eq!(
            config.networks["workers"].deny_ranges[0].to_string(),
            "198.51.100.0/24"
        );
    }

    #[test]
    fn errors_name_network_and_key() {
        let cases = [
            (
                "",
                "config /c.yaml: want a mapping with keys version and networks",
            ),
            ("version: [", "config /c.yaml: not valid YAML"),
            ("networks: {}\n", "config /c.yaml: missing key version"),
            (
                "version: 2\nnetworks: {}\n",
                "config /c.yaml: version 2 is not supported (known: 1)",
            ),
            (
                "version: \"1\"\nnetworks: {}\n",
                "config /c.yaml: version: want the number 1, got the string \"1\"",
            ),
            (
                "version: [1]\nnetworks: {}\n",
                "config /c.yaml: version: want the number 1, got",
            ),
            ("version: 1\n", "config /c.yaml: missing key networks"),
            (
                "version: 1\nnetworks: {}\n",
                "config /c.yaml: networks is empty",
            ),
            (
                "version: 1\nnetworks: []\n",
                "config /c.yaml: networks: want a mapping of network key to section",
            ),
            (
                "version: 1\nnetworks: {}\nextra: 1\n",
                "config /c.yaml: unknown key extra",
            ),
            (
                "version: 1\nnetworks:\n  Workers: {mode: denylist}\n",
                "config /c.yaml: network key Workers is invalid (want [a-z][a-z0-9-]{0,30})",
            ),
            (
                "version: 1\nnetworks:\n  uplink: {mode: denylist}\n",
                "config /c.yaml: network key uplink is reserved (the gateway's own network egress-uplink)",
            ),
            (
                "version: 1\nnetworks:\n  workers: {}\n",
                "config /c.yaml: network workers: missing key mode",
            ),
            (
                "version: 1\nnetworks:\n  workers: 3\n",
                "config /c.yaml: network workers: want a mapping with keys mode, deny_ranges, allow, exceptions, health, verify",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, exceptions: \"a.b:1\"}\n",
                "config /c.yaml: network workers: exceptions: want a list",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, exceptions: [11434]}\n",
                "config /c.yaml: network workers: exceptions: want strings, got 11434",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, exceptions: [host.docker.internal]}\n",
                "config /c.yaml: network workers: exceptions: host.docker.internal is not host:port",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, exceptions: [\"host.docker.internal:0\"]}\n",
                "config /c.yaml: network workers: exceptions: host.docker.internal:0 is not host:port",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, exceptions: [\"*.lan:22\"]}\n",
                "config /c.yaml: network workers: exceptions: *.lan:22 is not host:port",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, exceptions: [\"a_b:22\"]}\n",
                "config /c.yaml: network workers: exceptions: a_b:22 is not host:port",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, exceptions: [\"::1:22\"]}\n",
                "config /c.yaml: network workers: exceptions: ::1:22 is not host:port",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: open}\n",
                "config /c.yaml: network workers: mode: want denylist or allowlist, got open",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, port: 1}\n",
                "config /c.yaml: network workers: unknown key port",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, deny_ranges: [10.0.0.0]}\n",
                "config /c.yaml: network workers: deny_ranges: 10.0.0.0 is not a CIDR range",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, deny_ranges: \"10.0.0.0/8\"}\n",
                "config /c.yaml: network workers: deny_ranges: want a list",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, deny_ranges: [\"::ffff:10.0.0.0/104\"]}\n",
                "config /c.yaml: network workers: deny_ranges: ::ffff:10.0.0.0/104 overlaps ::ffff:0:0/96",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, deny_ranges: [\"::/0\"]}\n",
                "config /c.yaml: network workers: deny_ranges: ::/0 overlaps ::ffff:0:0/96",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, allow: [example.com]}\n",
                "config /c.yaml: network workers: allow: only for mode allowlist",
            ),
            (
                "version: 1\nnetworks:\n  api: {mode: allowlist}\n",
                "config /c.yaml: network api: missing key allow",
            ),
            (
                "version: 1\nnetworks:\n  api: {mode: allowlist, allow: []}\n",
                "config /c.yaml: network api: allow: is empty",
            ),
            (
                "version: 1\nnetworks:\n  api: {mode: allowlist, allow: [\"example.com:22\"]}\n",
                "config /c.yaml: network api: allow: host:port entries go under exceptions (example.com:22)",
            ),
            (
                "version: 1\nnetworks:\n  api: {mode: allowlist, allow: [\"a.*.com\"]}\n",
                "config /c.yaml: network api: allow: a.*.com is not a domain or *.domain glob",
            ),
            (
                "version: 1\nnetworks:\n  api: {mode: allowlist, allow: [\"*.example.com\"]}\n",
                "config /c.yaml: network api: health.allow_probe: required when every allow entry is a glob",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, health: {deny_probe: nope}}\n",
                "config /c.yaml: network workers: health.deny_probe: want host:port, got nope",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, health: {probe: \"a:1\"}}\n",
                "config /c.yaml: network workers: unknown key health.probe",
            ),
        ];
        for (text, want) in cases {
            let got = parse_err(text);
            assert!(
                got.starts_with(want),
                "config {text:?}: got {got:?}, want {want:?}"
            );
        }
    }

    const EXAMPLE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../config.example.yaml");

    #[test]
    fn example_config_is_valid() {
        let config = load(Path::new(EXAMPLE)).unwrap();
        assert_eq!(config.networks.keys().collect::<Vec<_>>(), ["workers"]);
        assert_eq!(config.networks["workers"].mode, Mode::Denylist);
    }

    /// The example with every commented example block (between `# example:` and
    /// `# end example`) uncommented: one `# ` removed from each line.
    fn uncomment_examples(text: &str) -> (String, usize) {
        let mut out = String::new();
        let (mut inside, mut blocks) = (false, 0);
        for line in text.lines() {
            let body = line.trim_start();
            if body.starts_with("# example:") {
                inside = true;
                blocks += 1;
                continue;
            }
            if body == "# end example" {
                inside = false;
                continue;
            }
            if inside {
                let indent = &line[..line.len() - body.len()];
                let rest = body.strip_prefix("# ").or_else(|| body.strip_prefix('#'));
                out.push_str(indent);
                out.push_str(rest.expect("example lines are commented"));
            } else {
                out.push_str(line);
            }
            out.push('\n');
        }
        assert!(!inside, "unterminated example block");
        (out, blocks)
    }

    #[test]
    fn example_blocks_are_valid() {
        let text = std::fs::read_to_string(EXAMPLE).unwrap();
        let (text, blocks) = uncomment_examples(&text);
        assert_eq!(blocks, 5, "example blocks in config.example.yaml");
        let config = parse(Path::new(EXAMPLE), &text).unwrap_or_else(|e| panic!("{e}\n{text}"));
        let workers = &config.networks["workers"];
        assert_eq!(workers.deny_ranges.len(), 2);
        assert_eq!(
            workers.exceptions,
            [HostPort::parse("host.docker.internal:11434").unwrap()]
        );
        assert_eq!(workers.health.allow_probe.to_string(), "example.com:443");
        assert_eq!(workers.health.deny_probe.to_string(), "169.254.169.254:80");
        // Documentation addresses only (TEST-NET-2, 2001:db8::/32).
        assert_eq!(
            workers.verify_deny_targets,
            [
                HostPort::parse("198.51.100.20:22").unwrap(),
                HostPort::parse("[2001:db8::20]:443").unwrap()
            ]
        );
        let mini_op = &config.networks["mini-op"];
        assert_eq!(mini_op.mode, Mode::Allowlist);
        assert_eq!(
            mini_op.allow,
            [
                "api.anthropic.com",
                "claude.ai",
                "claude.com",
                "platform.claude.com"
            ]
        );
        // A documentation address (TEST-NET-1), never a real LAN address.
        assert_eq!(
            mini_op.exceptions,
            [HostPort::parse("192.0.2.10:22").unwrap()]
        );
    }

    #[test]
    fn missing_file_is_named() {
        let err = load(Path::new("/nonexistent/egress/config.local.yaml")).unwrap_err();
        assert!(
            err.to_string()
                .starts_with("config /nonexistent/egress/config.local.yaml: cannot read: "),
            "{err}"
        );
    }

    #[test]
    fn networks_mismatch() {
        let config = parse_ok(WORKERS);
        let path = Path::new("/c.yaml");
        assert!(check_advertised(path, &config, &["workers".into()]).is_ok());
        let err = check_advertised(path, &config, &["workers".into(), "api".into()]).unwrap_err();
        assert_eq!(
            err.to_string(),
            "config /c.yaml: networks [workers] differ from the gateway's networks [api, workers]; run ./start.sh"
        );
    }

    #[test]
    fn advertised_list() {
        assert_eq!(
            parse_advertised(Some("workers, api")).unwrap(),
            vec!["workers", "api"]
        );
        assert_eq!(
            parse_advertised(None).unwrap_err(),
            "EGRESS_NETWORKS is not set (./start.sh sets it)"
        );
        assert_eq!(
            parse_advertised(Some(" , ")).unwrap_err(),
            "EGRESS_NETWORKS is empty (./start.sh sets it)"
        );
        assert!(
            parse_advertised(Some("Bad"))
                .unwrap_err()
                .contains("invalid")
        );
    }

    #[test]
    fn exceptions_parsed() {
        let config = parse_ok(
            "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    exceptions: [\"NAS.Lan:8080\", \"host.docker.internal:11434\", \"192.168.1.20:11434\", \"[fd00::1]:22\", \"nas.lan:8080\"]\n",
        );
        let got: Vec<String> = config.networks["workers"]
            .exceptions
            .iter()
            .map(HostPort::to_string)
            .collect();
        assert_eq!(
            got,
            [
                "192.168.1.20:11434",
                "[fd00::1]:22",
                "host.docker.internal:11434",
                "nas.lan:8080"
            ]
        );
        assert!(parse_ok(WORKERS).networks["workers"].exceptions.is_empty());
        let api = parse_ok(
            "version: 1\nnetworks:\n  api:\n    mode: allowlist\n    allow: [example.com]\n    exceptions: [\"192.0.2.10:22\"]\n",
        );
        assert_eq!(
            api.networks["api"].exceptions[0].to_string(),
            "192.0.2.10:22"
        );
    }

    #[test]
    fn verify_deny_targets_parsed() {
        let config = parse_ok(
            "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    verify:\n      deny_targets: [\"198.51.100.7:22\", \"[2001:db8::7]:443\", \"NAS.Lan:5000\", \"198.51.100.7:22\"]\n  api:\n    mode: allowlist\n    allow: [example.com]\n    verify: {deny_targets: [\"192.0.2.20:80\"]}\n",
        );
        let got: Vec<String> = config.networks["workers"]
            .verify_deny_targets
            .iter()
            .map(HostPort::to_string)
            .collect();
        assert_eq!(
            got,
            ["198.51.100.7:22", "[2001:db8::7]:443", "nas.lan:5000"]
        );
        assert_eq!(
            config.networks["api"].verify_deny_targets,
            [HostPort::parse("192.0.2.20:80").unwrap()]
        );
        assert!(
            parse_ok(WORKERS).networks["workers"]
                .verify_deny_targets
                .is_empty()
        );
    }

    #[test]
    fn verify_errors() {
        let cases = [
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, verify: {other: []}}\n",
                "config /c.yaml: network workers: unknown key verify.other",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, verify: {deny_targets: [nope]}}\n",
                "config /c.yaml: network workers: verify.deny_targets: nope is not host:port",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, verify: [\"a.b:1\"]}\n",
                "config /c.yaml: network workers: verify: want a mapping with key deny_targets",
            ),
            (
                "version: 1\nnetworks:\n  workers: {mode: denylist, verify: {deny_targets: \"a.b:1\"}}\n",
                "config /c.yaml: network workers: verify.deny_targets: want a list",
            ),
        ];
        for (text, want) in cases {
            let got = parse_err(text);
            assert!(
                got.starts_with(want),
                "config {text:?}: got {got:?}, want {want:?}"
            );
        }
    }

    #[test]
    fn exception_ip() {
        let ip = |s: &str| HostPort::parse(s).unwrap().ip();
        assert_eq!(ip("192.0.2.1:1"), Some("192.0.2.1".parse().unwrap()));
        assert_eq!(ip("[::ffff:10.0.0.1]:1"), Some("10.0.0.1".parse().unwrap()));
        assert_eq!(ip("nas.lan:1"), None);
    }

    #[test]
    fn names() {
        assert_eq!(listen_alias("mini-op"), "egress-proxy-mini-op");
        assert_eq!(network_name("mini-op"), "egress-mini-op");
    }

    #[test]
    fn host_port_forms() {
        assert_eq!(HostPort::parse("a.b:80").unwrap().to_string(), "a.b:80");
        assert_eq!(HostPort::parse("[::1]:80").unwrap().to_string(), "[::1]:80");
        for bad in ["a.b", "a.b:0", "a.b:x", "::1:80", ":80", "[zz]:80"] {
            assert!(HostPort::parse(bad).is_none(), "{bad}");
        }
    }
}
