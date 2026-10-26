//! `proxy drift`: whether the running policy still matches the mounted config. start.sh
//! runs it with `docker compose exec` and restarts the proxy on [`DIFFERS`], so a config
//! edit applies without a manual restart. Read-only, like `proxy health`.

use crate::cli::Opts;
use crate::config;
use crate::facts;
use crate::policy::{self, Drift};

/// The exit code for a running policy that a restart would change. Not 1, which docker
/// itself exits with when it cannot exec.
pub const DIFFERS: u8 = 3;

/// Prints one line per network; returns 0 when every running policy matches, [`DIFFERS`]
/// when one differs or cannot be read or the running networks differ, and 2 when it
/// cannot tell: not started yet (it is starting with this config) or a config error.
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
            let mut code = 0;
            for (key, outcome) in &outcomes {
                println!("{}", outcome.message(key, &opts.config));
                if !matches!(outcome, Drift::Matches) {
                    code = DIFFERS;
                }
            }
            code
        }
        Err(e) => {
            println!("{e}");
            DIFFERS
        }
    }
}
