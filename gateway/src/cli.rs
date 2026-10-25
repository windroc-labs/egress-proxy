//! Command line of the image's entrypoint. Not a management command: the image runs
//! `gateway run`, and its `HEALTHCHECK` runs `gateway health`.

use std::net::IpAddr;
use std::path::PathBuf;

use crate::facts::Resolver;

pub const USAGE: &str = "usage: gateway [run|health] [--config <path>] [--run-dir <dir>] [--smokescreen <path>] [--port <n>] [--resolve <host>=<ip>[,<ip>...]]...";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Run,
    Health,
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
        _ => {}
    }
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
            other => return Err(format!("unknown option {other}")),
        }
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
}
