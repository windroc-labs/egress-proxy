//! `proxy drift`: whether the running policy still matches the mounted config. start.sh
//! runs it with `docker compose exec` and restarts the proxy on [`DIFFERS`], so a config
//! edit applies without a manual restart. Read-only, like `proxy health`.
//!
//! [`read`] is the one read of the rules in force, shared with `proxy rules`.

use std::path::PathBuf;

use crate::cli::Opts;
use crate::config::{self, Config};
use crate::facts::{self, Facts};
use crate::policy::{self, Drift};

/// The exit code for a running policy that a restart would change. Not 1, which docker
/// itself exits with when it cannot exec.
pub const DIFFERS: u8 = 3;

/// What decides whether the config's rules are in force: the running proxy's start facts,
/// the served config and each network's running policy against it. `proxy drift` and
/// `proxy rules` read it only with [`read`], so they never disagree.
pub struct InForce {
    pub facts: Facts,
    pub config: Config,
    /// The config's path, which the drift messages name.
    pub config_path: PathBuf,
    pub drift: Result<Vec<(String, Drift)>, String>,
}

impl InForce {
    /// Why the config's rules are not in force, one line each; empty when they are.
    pub fn stale(&self) -> Vec<String> {
        match &self.drift {
            Ok(outcomes) => outcomes
                .iter()
                .filter(|(_, outcome)| !matches!(outcome, Drift::Matches))
                .map(|(key, outcome)| outcome.message(key, &self.config_path))
                .collect(),
            Err(e) => vec![e.clone()],
        }
    }
}

/// Reads [`InForce`]. `Err` when it cannot tell: not started yet (no start facts) or a
/// config error. Prints nothing.
pub fn read(opts: &Opts) -> Result<InForce, String> {
    let facts =
        facts::read(&opts.run_dir.join("facts.json")).map_err(|e| format!("not started: {e}"))?;
    let config = config::load_served(&opts.config, opts.advertised.as_deref())?;
    let drift = policy::drift(&config, &facts, &opts.run_dir);
    Ok(InForce {
        facts,
        config,
        config_path: opts.config.clone(),
        drift,
    })
}

/// Prints one line per network; returns 0 when every running policy matches, [`DIFFERS`]
/// when one differs or cannot be read or the running networks differ, and 2 when it
/// cannot tell: not started yet (it is starting with this config) or a config error.
pub fn run(opts: &Opts) -> u8 {
    let in_force = match read(opts) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("proxy: {e}");
            return 2;
        }
    };
    match &in_force.drift {
        Ok(outcomes) => {
            for (key, outcome) in outcomes {
                println!("{}", outcome.message(key, &in_force.config_path));
            }
        }
        Err(e) => println!("{e}"),
    }
    if in_force.stale().is_empty() {
        0
    } else {
        DIFFERS
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::io;

    use super::*;

    const TWO: &str =
        "version: 1\nnetworks:\n  workers:\n    mode: denylist\n  api:\n    mode: denylist\n";

    fn in_force(drift: Result<Vec<(String, Drift)>, String>) -> InForce {
        let config_path = PathBuf::from("/c.yaml");
        InForce {
            facts: Facts {
                port: 4750,
                networks: BTreeMap::new(),
                host_docker_internal: Vec::new(),
                own_addrs: Vec::new(),
                exceptions: BTreeMap::new(),
                subnets: BTreeMap::new(),
            },
            config: config::parse(&config_path, TWO).unwrap(),
            config_path,
            drift,
        }
    }

    #[test]
    fn stale_none_when_matching() {
        let got = in_force(Ok(vec![
            ("api".to_string(), Drift::Matches),
            ("workers".to_string(), Drift::Matches),
        ]));
        assert_eq!(got.stale(), Vec::<String>::new());
    }

    #[test]
    fn stale_lists_each_stale_network() {
        let got = in_force(Ok(vec![
            ("api".to_string(), Drift::Differs),
            ("cache".to_string(), Drift::Matches),
            (
                "workers".to_string(),
                Drift::Unreadable(io::Error::other("gone")),
            ),
        ]));
        assert_eq!(
            got.stale(),
            vec![
                "network api: running policy differs from /c.yaml; run ./start.sh".to_string(),
                "network workers: cannot read the running policy: gone".to_string(),
            ]
        );
    }

    #[test]
    fn stale_networks_differ() {
        let got = in_force(Err("networks [api] differ".to_string()));
        assert_eq!(got.stale(), vec!["networks [api] differ".to_string()]);
    }
}
