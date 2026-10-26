use std::process::ExitCode;

use proxy::cli::{self, Mode};
use proxy::{drift, health, plan, render, supervise};

fn main() -> ExitCode {
    let opts = match cli::parse_args(
        std::env::args().skip(1),
        std::env::var("EGRESS_NETWORKS").ok(),
    ) {
        Ok(opts) => opts,
        Err(e) => {
            eprintln!("proxy: {e}\n{}", cli::USAGE);
            return ExitCode::from(2);
        }
    };
    let code = match opts.mode {
        Mode::Run => supervise::run(&opts),
        Mode::Health => health::run(&opts),
        Mode::Compose => render::run(&opts),
        Mode::Plan => plan::run(&opts),
        Mode::Drift => drift::run(&opts),
    };
    ExitCode::from(code)
}
