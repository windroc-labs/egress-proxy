//! Command line of the image's entrypoint. Not a management command: the image runs
//! `proxy run`, its `HEALTHCHECK` runs `proxy health`, only start.sh runs
//! `proxy compose`, in a throwaway container with `--network none`, and `proxy drift`,
//! read-only, with `docker compose exec` in the proxy, and `proxy rules`, read-only, the
//! same way; only verify-egress runs `proxy plan`, read-only, with `docker exec` in the
//! proxy.

use std::net::IpAddr;
use std::path::PathBuf;

use ipnet::IpNet;

use crate::facts::Resolver;
use crate::plan::HostFacts;

pub const USAGE: &str = "usage: proxy [run|health|compose|drift|rules] [--config <path>] [--run-dir <dir>] [--smokescreen <path>] [--port <n>] [--resolve <host>=<ip>[,<ip>...]]...\n       proxy plan <key> --listener-port <n> [--host-addr <ip>/<len>]... [--default-gateway <ip>]... [--config <path>] [--run-dir <dir>]";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Run,
    Health,
    /// Print the compose override for the config's caller networks.
    Compose,
    /// Print verify-egress's checks for one caller network.
    Plan,
    /// Exit 3 when the running policy differs from the config.
    Drift,
    /// Print each caller network's rules in effect.
    Rules,
}

#[derive(Debug, Clone)]
pub struct Opts {
    pub mode: Mode,
    pub config: PathBuf,
    pub run_dir: PathBuf,
    pub smokescreen: PathBuf,
    pub port: u16,
    /// Fixed answers for name resolution; tests only, the image never passes them.
    pub resolver: Resolver,
    /// The advertised caller networks, unparsed: the `EGRESS_NETWORKS` environment
    /// variable, which compose.yaml sets next to the labels.
    pub advertised: Option<String>,
    /// `plan` only: the caller network to plan for, and the host's facts.
    pub plan_key: Option<String>,
    pub host: HostFacts,
}

impl Default for Opts {
    fn default() -> Opts {
        Opts {
            mode: Mode::Run,
            config: PathBuf::from("/etc/egress/config.local.yaml"),
            run_dir: PathBuf::from("/run/egress"),
            smokescreen: PathBuf::from("/smokescreen"),
            port: 4750,
            resolver: Resolver::default(),
            advertised: None,
            plan_key: None,
            host: HostFacts::default(),
        }
    }
}

/// Parses the arguments; `advertised` is the value of `EGRESS_NETWORKS`.
pub fn parse_args<I: IntoIterator<Item = String>>(
    args: I,
    advertised: Option<String>,
) -> Result<Opts, String> {
    let mut opts = Opts {
        advertised,
        ..Opts::default()
    };
    let mut args = args.into_iter().peekable();
    match args.peek().map(String::as_str) {
        Some("run") => {
            args.next();
        }
        Some("health") => {
            opts.mode = Mode::Health;
            args.next();
        }
        Some("compose") => {
            opts.mode = Mode::Compose;
            args.next();
        }
        Some("drift") => {
            opts.mode = Mode::Drift;
            args.next();
        }
        Some("rules") => {
            opts.mode = Mode::Rules;
            args.next();
        }
        Some("plan") => {
            opts.mode = Mode::Plan;
            args.next();
            match args.next_if(|a| !a.starts_with('-')) {
                Some(key) => opts.plan_key = Some(key),
                None => return Err("plan needs a network key".into()),
            }
        }
        _ => {}
    }
    let plan = opts.mode == Mode::Plan;
    let mut listener_port = None;
    while let Some(arg) = args.next() {
        let mut value = || args.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--config" => opts.config = value()?.into(),
            "--run-dir" => opts.run_dir = value()?.into(),
            "--smokescreen" => opts.smokescreen = value()?.into(),
            "--port" => {
                let v = value()?;
                opts.port = v
                    .parse()
                    .ok()
                    .filter(|p| *p != 0)
                    .ok_or_else(|| format!("--port: {v} is not a port"))?;
            }
            "--resolve" => {
                let v = value()?;
                let (host, ips) = v
                    .split_once('=')
                    .ok_or_else(|| format!("--resolve: want host=ip[,ip...], got {v}"))?;
                let ips = ips
                    .split(',')
                    .filter(|s| !s.is_empty())
                    .map(|s| s.parse::<IpAddr>())
                    .collect::<Result<Vec<_>, _>>()
                    .map_err(|_| format!("--resolve: bad address in {v}"))?;
                opts.resolver.overrides.insert(host.to_string(), ips);
            }
            "--host-addr" if plan => {
                let v = value()?;
                let net = v
                    .parse::<IpNet>()
                    .map_err(|_| format!("--host-addr: want ip/len, got {v}"))?;
                opts.host.addrs.push(net);
            }
            "--default-gateway" if plan => {
                let v = value()?;
                let ip = v
                    .parse::<IpAddr>()
                    .map_err(|_| format!("--default-gateway: {v} is not an address"))?;
                opts.host.gateways.push(ip);
            }
            "--listener-port" if plan => {
                let v = value()?;
                listener_port = Some(
                    v.parse::<u16>()
                        .ok()
                        .filter(|p| *p != 0)
                        .ok_or_else(|| format!("--listener-port: {v} is not a port"))?,
                );
            }
            other => return Err(format!("unknown option {other}")),
        }
    }
    if plan {
        opts.host.listener_port = listener_port.ok_or("plan needs --listener-port")?;
    }
    Ok(opts)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(args: &[&str]) -> Result<Opts, String> {
        parse_args(args.iter().map(|s| s.to_string()), Some("workers".into()))
    }

    #[test]
    fn defaults() {
        let opts = parse(&[]).unwrap();
        assert_eq!(opts.mode, Mode::Run);
        assert_eq!(opts.config, PathBuf::from("/etc/egress/config.local.yaml"));
        assert_eq!(opts.run_dir, PathBuf::from("/run/egress"));
        assert_eq!(opts.smokescreen, PathBuf::from("/smokescreen"));
        assert_eq!(opts.port, 4750);
        assert!(opts.resolver.overrides.is_empty());
        assert_eq!(opts.advertised.as_deref(), Some("workers"));
    }

    #[test]
    fn options() {
        let opts = parse(&[
            "health",
            "--config",
            "/c",
            "--run-dir",
            "/r",
            "--port",
            "1",
            "--resolve",
            "a=127.0.0.1,::1",
            "--resolve",
            "b=",
        ])
        .unwrap();
        assert_eq!(opts.mode, Mode::Health);
        assert_eq!(opts.config, PathBuf::from("/c"));
        assert_eq!(opts.run_dir, PathBuf::from("/r"));
        assert_eq!(opts.port, 1);
        assert_eq!(opts.resolver.overrides["a"].len(), 2);
        assert!(opts.resolver.overrides["b"].is_empty());
    }

    #[test]
    fn errors() {
        assert_eq!(parse(&["--bogus"]).unwrap_err(), "unknown option --bogus");
        assert_eq!(parse(&["--port"]).unwrap_err(), "--port needs a value");
        assert_eq!(
            parse(&["--port", "0"]).unwrap_err(),
            "--port: 0 is not a port"
        );
        assert!(
            parse(&["--resolve", "x"])
                .unwrap_err()
                .starts_with("--resolve: want")
        );
        assert!(
            parse(&["--resolve", "x=nope"])
                .unwrap_err()
                .starts_with("--resolve: bad")
        );
        assert_eq!(parse(&["status"]).unwrap_err(), "unknown option status");
    }

    #[test]
    fn plan_mode() {
        let opts = parse(&[
            "plan",
            "mini-op",
            "--host-addr",
            "192.168.1.20/24",
            "--host-addr",
            "2001:db8::20/64",
            "--default-gateway",
            "192.168.1.1",
            "--listener-port",
            "50123",
        ])
        .unwrap();
        assert_eq!(opts.mode, Mode::Plan);
        assert_eq!(opts.plan_key.as_deref(), Some("mini-op"));
        assert_eq!(opts.host.addrs.len(), 2);
        assert_eq!(
            opts.host.gateways,
            ["192.168.1.1".parse::<IpAddr>().unwrap()]
        );
        assert_eq!(opts.host.listener_port, 50123);
    }

    #[test]
    fn plan_errors() {
        assert_eq!(parse(&["plan"]).unwrap_err(), "plan needs a network key");
        assert_eq!(
            parse(&["plan", "--listener-port", "1"]).unwrap_err(),
            "plan needs a network key"
        );
        assert_eq!(
            parse(&["plan", "workers"]).unwrap_err(),
            "plan needs --listener-port"
        );
        assert_eq!(
            parse(&[
                "plan",
                "workers",
                "--listener-port",
                "1",
                "--host-addr",
                "x"
            ])
            .unwrap_err(),
            "--host-addr: want ip/len, got x"
        );
        assert_eq!(
            parse(&[
                "plan",
                "workers",
                "--listener-port",
                "1",
                "--default-gateway",
                "x"
            ])
            .unwrap_err(),
            "--default-gateway: x is not an address"
        );
        for mode in ["run", "health", "compose", "drift", "rules"] {
            for opt in ["--host-addr", "--default-gateway", "--listener-port"] {
                assert_eq!(
                    parse(&[mode, opt, "1"]).unwrap_err(),
                    format!("unknown option {opt}"),
                    "{mode}"
                );
            }
        }
    }

    #[test]
    fn compose_mode() {
        assert_eq!(parse(&["compose"]).unwrap().mode, Mode::Compose);
    }

    #[test]
    fn rules_mode() {
        let opts = parse(&["rules", "--config", "/c", "--run-dir", "/r"]).unwrap();
        assert_eq!(opts.mode, Mode::Rules);
        assert_eq!(opts.config, PathBuf::from("/c"));
        assert_eq!(opts.run_dir, PathBuf::from("/r"));
    }

    #[test]
    fn drift_mode() {
        let opts = parse(&["drift", "--config", "/c", "--run-dir", "/r"]).unwrap();
        assert_eq!(opts.mode, Mode::Drift);
        assert_eq!(opts.config, PathBuf::from("/c"));
        assert_eq!(opts.run_dir, PathBuf::from("/r"));
    }
}
