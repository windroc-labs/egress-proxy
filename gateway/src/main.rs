use std::process::ExitCode;

use gateway::cli::{self, Mode};
use gateway::supervise;

fn main() -> ExitCode {
    let opts = match cli::parse_args(std::env::args().skip(1)) {
        Ok(opts) => opts,
        Err(e) => {
            eprintln!("gateway: {e}\n{}", cli::USAGE);
            return ExitCode::from(2);
        }
    };
    let code = match opts.mode {
        Mode::Run => supervise::run(&opts),
        Mode::Health => {
            eprintln!("gateway: health is not available yet");
            2
        }
    };
    ExitCode::from(code)
}
