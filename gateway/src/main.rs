use std::process::ExitCode;

use gateway::cli::{self, Mode};
use gateway::{health, plan, render, supervise};

fn main() -> ExitCode {
    let opts = match cli::parse_args(
        std::env::args().skip(1),
        std::env::var("EGRESS_NETWORKS").ok(),
    ) {
        Ok(opts) => opts,
        Err(e) => {
            eprintln!("gateway: {e}\n{}", cli::USAGE);
            return ExitCode::from(2);
        }
    };
    let code = match opts.mode {
        Mode::Run => supervise::run(&opts),
        Mode::Health => health::run(&opts),
        Mode::Compose => render::run(&opts),
        Mode::Plan => plan::run(&opts),
    };
    ExitCode::from(code)
}
