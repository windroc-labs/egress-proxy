//! `proxy rules`: each caller network's rules in effect, from the running proxy's start
//! facts and the config. start.sh runs it with `docker compose exec` after a start,
//! prints it and writes it to effective-policy.txt. Read-only, like `proxy drift`.

use std::fmt::Write as _;
use std::net::SocketAddr;

use crate::cli::Opts;
use crate::config::{self, Config, Mode, listen_alias, network_name};
use crate::drift::DIFFERS;
use crate::facts::{self, Facts, HOST_DOCKER_INTERNAL};
use crate::policy::{self, DENY_FLOOR, Drift};

/// Prints the rules in effect; returns 0, 2 when it cannot tell (not started yet or a
/// config error) and [`DIFFERS`] when the running policy is not the config's, so it never
/// reports rules that are not in force.
pub fn run(opts: &Opts) -> u8 {
    let facts = match facts::read(&opts.run_dir.join("facts.json")) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("proxy: not started: {e}");
            return 2;
        }
    };
    let config = match config::load_served(&opts.config, opts.advertised.as_deref()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("proxy: {e}");
            return 2;
        }
    };
    match policy::drift(&config, &facts, &opts.run_dir) {
        Ok(outcomes) => {
            let stale: Vec<String> = outcomes
                .iter()
                .filter(|(_, outcome)| !matches!(outcome, Drift::Matches))
                .map(|(key, outcome)| outcome.message(key, &opts.config))
                .collect();
            if !stale.is_empty() {
                for line in stale {
                    eprintln!("proxy: {line}");
                }
                return DIFFERS;
            }
        }
        Err(e) => {
            eprintln!("proxy: {e}");
            return DIFFERS;
        }
    }
    print!("{}", render(&config, &facts));
    0
}

/// The rules report: one block per network in key order, separated by an empty line.
pub fn render(config: &Config, facts: &Facts) -> String {
    let mut out = String::new();
    for (i, (key, network)) in config.networks.iter().enumerate() {
        if i > 0 {
            out.push('\n');
        }
        let _ = writeln!(
            out,
            "network {key} (Docker network {}, proxy http://{}:{})",
            network_name(key),
            listen_alias(key),
            facts.port
        );
        out.push_str(match network.mode {
            Mode::Denylist => {
                "  mode: denylist: every destination is allowed except the denied ones below\n"
            }
            Mode::Allowlist => {
                "  mode: allowlist: only the domains under allow and the exceptions are allowed; the denied ranges still apply\n"
            }
        });
        list(
            &mut out,
            "denied, the built-in floor (every network, both modes)",
            DENY_FLOOR.iter().map(|r| r.to_string()),
        );
        if facts.host_docker_internal.is_empty() {
            let _ = writeln!(out, "  denied, {HOST_DOCKER_INTERNAL}: does not resolve");
        } else {
            let _ = writeln!(
                out,
                "  denied, {HOST_DOCKER_INTERNAL}: {}",
                joined(facts.host_docker_internal.iter().map(|ip| ip.to_string()))
            );
        }
        let _ = writeln!(
            out,
            "  denied, the proxy's own addresses: {}",
            joined(facts.own_addrs.iter().map(|ip| ip.to_string()))
        );
        list(
            &mut out,
            "denied, deny_ranges",
            network.deny_ranges.iter().map(|r| r.to_string()),
        );
        list(&mut out, "allow", network.allow.iter().cloned());
        let exceptions = network.exceptions.iter().map(|e| {
            let addrs = policy::exception_addrs(e, facts)
                .into_iter()
                .map(|ip| SocketAddr::new(ip, e.port).to_string());
            format!("{e} -> {}", joined(addrs))
        });
        if network.exceptions.is_empty() {
            out.push_str("  exceptions: none\n");
        } else {
            list(
                &mut out,
                "exceptions (allowed although denied above; addresses resolved at this start)",
                exceptions,
            );
        }
    }
    out
}

/// `  <label>: none`, or `  <label>:` and one `    <item>` line per item.
fn list(out: &mut String, label: &str, items: impl Iterator<Item = String>) {
    let mut items = items.peekable();
    if items.peek().is_none() {
        let _ = writeln!(out, "  {label}: none");
        return;
    }
    let _ = writeln!(out, "  {label}:");
    for item in items {
        let _ = writeln!(out, "    {item}");
    }
}

fn joined(items: impl Iterator<Item = String>) -> String {
    items.collect::<Vec<_>>().join(", ")
}

#[cfg(test)]
mod tests {
    use std::collections::{BTreeMap, BTreeSet};
    use std::path::Path;

    use ipnet::IpNet;

    use std::net::IpAddr;

    use super::*;

    fn config(text: &str) -> Config {
        config::parse(Path::new("/c.yaml"), text).unwrap()
    }

    fn facts() -> Facts {
        Facts {
            port: 4750,
            networks: BTreeMap::from([
                ("workers".to_string(), "172.20.0.2".parse().unwrap()),
                ("api".to_string(), "172.21.0.2".parse().unwrap()),
            ]),
            host_docker_internal: vec!["192.168.65.254".parse().unwrap()],
            own_addrs: vec![
                "127.0.0.1".parse().unwrap(),
                "172.20.0.2".parse().unwrap(),
                "172.21.0.2".parse().unwrap(),
            ],
            exceptions: BTreeMap::new(),
            subnets: BTreeMap::new(),
        }
    }

    const WORKERS: &str = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n";

    fn floor_lines() -> String {
        DENY_FLOOR.iter().map(|r| format!("    {r}\n")).collect()
    }

    #[test]
    fn render_lists_the_floor() {
        let got = render(&config(WORKERS), &facts());
        for range in DENY_FLOOR {
            assert!(
                got.lines().any(|l| l == format!("    {range}")),
                "{range} missing from\n{got}"
            );
        }
    }

    #[test]
    fn render_denylist() {
        let c = config(
            "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    deny_ranges: [203.0.113.7/32, 10.0.0.0/8]\n",
        );
        let want = format!(
            "network workers (Docker network egress-workers, proxy http://egress-proxy-workers:4750)\n\
             \x20 mode: denylist: every destination is allowed except the denied ones below\n\
             \x20 denied, the built-in floor (every network, both modes):\n\
             {}\
             \x20 denied, host.docker.internal: 192.168.65.254\n\
             \x20 denied, the proxy's own addresses: 127.0.0.1, 172.20.0.2, 172.21.0.2\n\
             \x20 denied, deny_ranges:\n\
             \x20   203.0.113.7/32\n\
             \x20   10.0.0.0/8\n\
             \x20 allow: none\n\
             \x20 exceptions: none\n",
            floor_lines()
        );
        assert_eq!(render(&c, &facts()), want);
    }

    #[test]
    fn render_allowlist() {
        let c = config(
            "version: 1\nnetworks:\n  api:\n    mode: allowlist\n    allow: [example.com, \"*.example.org\"]\n  workers:\n    mode: denylist\n",
        );
        let got = render(&c, &facts());
        let want_api = format!(
            "network api (Docker network egress-api, proxy http://egress-proxy-api:4750)\n\
             \x20 mode: allowlist: only the domains under allow and the exceptions are allowed; the denied ranges still apply\n\
             \x20 denied, the built-in floor (every network, both modes):\n\
             {}\
             \x20 denied, host.docker.internal: 192.168.65.254\n\
             \x20 denied, the proxy's own addresses: 127.0.0.1, 172.20.0.2, 172.21.0.2\n\
             \x20 denied, deny_ranges: none\n\
             \x20 allow:\n\
             \x20   example.com\n\
             \x20   *.example.org\n\
             \x20 exceptions: none\n\
             \nnetwork workers (",
            floor_lines()
        );
        assert!(got.starts_with(&want_api), "{got}");
        assert_eq!(got.matches("\nnetwork ").count(), 1, "{got}");
    }

    #[test]
    fn render_empty_lists() {
        let got = render(&config(WORKERS), &facts());
        for line in [
            "  denied, deny_ranges: none",
            "  allow: none",
            "  exceptions: none",
        ] {
            assert!(got.lines().any(|l| l == line), "{line} missing from\n{got}");
        }
    }

    #[test]
    fn render_hdi_unresolved() {
        let mut f = facts();
        f.host_docker_internal.clear();
        let got = render(&config(WORKERS), &f);
        assert!(
            got.lines()
                .any(|l| l == "  denied, host.docker.internal: does not resolve"),
            "{got}"
        );
    }

    #[test]
    fn render_exceptions() {
        let c = config(
            "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    exceptions: [host.docker.internal:11434, \"192.168.1.20:22\", nas.lan:445]\n",
        );
        let mut f = facts();
        f.exceptions = BTreeMap::from([
            (
                "host.docker.internal".to_string(),
                vec!["192.168.65.254".parse().unwrap()],
            ),
            (
                "nas.lan".to_string(),
                vec!["192.168.1.30".parse().unwrap(), "fd00::30".parse().unwrap()],
            ),
        ]);
        let got = render(&c, &f);
        let want = "  exceptions (allowed although denied above; addresses resolved at this start):\n\
                    \x20   192.168.1.20:22 -> 192.168.1.20:22\n\
                    \x20   host.docker.internal:11434 -> 192.168.65.254:11434\n\
                    \x20   nas.lan:445 -> 192.168.1.30:445, [fd00::30]:445\n";
        assert!(got.ends_with(want), "{got}");
    }

    #[test]
    fn render_covers_deny_ranges() {
        let c = config(
            "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    deny_ranges: [203.0.113.0/24, 10.0.0.0/8]\n",
        );
        let network = &c.networks["workers"];
        let f = facts();
        let got = render(&c, &f);
        // Every address or range the report lists as denied.
        let mut listed = BTreeSet::new();
        let mut denied = false;
        for line in got.lines().skip(2) {
            if let Some(item) = line.strip_prefix("    ") {
                if denied {
                    listed.insert(item.parse::<IpNet>().unwrap());
                }
                continue;
            }
            let (label, items) = line.trim_start().split_once(':').unwrap();
            denied = label.starts_with("denied, ");
            let items = items.trim();
            if denied && !["", "none", "does not resolve"].contains(&items) {
                for item in items.split(", ") {
                    listed.insert(IpNet::from(item.parse::<IpAddr>().unwrap()));
                }
            }
        }
        let want: BTreeSet<IpNet> = policy::deny_ranges(network, &f).into_iter().collect();
        assert_eq!(listed, want);
    }
}
