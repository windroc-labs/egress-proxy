//! `proxy run`: generate every network's policy, start one smokescreen per network,
//! and supervise them as PID 1.

use std::io;
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

use nix::errno::Errno;
use nix::sys::signal::{SigSet, SigmaskHow, Signal, kill, sigprocmask};
use nix::sys::wait::{WaitPidFlag, WaitStatus, waitpid};
use nix::unistd::Pid;

use crate::cli::Opts;
use crate::config::{self, Config};
use crate::facts::{self, Facts};
use crate::policy;

const STOP_GRACE: Duration = Duration::from_secs(10);

struct Child {
    network: String,
    pid: Pid,
    alive: bool,
}

/// Runs the proxy; returns the process exit code: 0 after SIGTERM or SIGINT, 1 when
/// a smokescreen exits or cannot start, 2 on a config or environment error.
pub fn run(opts: &Opts) -> u8 {
    // Block first, so a SIGTERM during start (alias lookups can take 10 s) waits for
    // sigwait instead of being dropped: PID 1 ignores signals left at their default.
    // Children get the default mask back before exec.
    let mut mask = SigSet::empty();
    for sig in [Signal::SIGCHLD, Signal::SIGTERM, Signal::SIGINT] {
        mask.add(sig);
    }
    if let Err(e) = mask.thread_block() {
        eprintln!("proxy: cannot block signals: {e}");
        return 1;
    }

    let config = match config::load_served(&opts.config, opts.advertised.as_deref()) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("proxy: {e}");
            return 2;
        }
    };
    let facts = match prepare(opts, &config) {
        Ok(f) => f,
        Err(e) => {
            eprintln!("proxy: {e}");
            return 1;
        }
    };

    let mut children = Vec::new();
    for (key, network) in &config.networks {
        let policy_file = policy::network_dir(&opts.run_dir, key).join("config.yaml");
        let mut cmd = Command::new(&opts.smokescreen);
        cmd.arg("--config-file")
            .arg(&policy_file)
            .stdin(Stdio::null());
        // SAFETY: sigprocmask is async-signal-safe.
        unsafe {
            cmd.pre_exec(|| {
                sigprocmask(SigmaskHow::SIG_SETMASK, Some(&SigSet::empty()), None)
                    .map_err(io::Error::from)
            });
        }
        match cmd.spawn() {
            Ok(child) => {
                eprintln!(
                    "proxy: network {key} ({}) listening on {}:{}",
                    network.mode, facts.networks[key], facts.port
                );
                children.push(Child {
                    network: key.clone(),
                    pid: Pid::from_raw(child.id() as i32),
                    alive: true,
                });
            }
            Err(e) => {
                eprintln!(
                    "proxy: network {key}: cannot start {}: {e}",
                    opts.smokescreen.display()
                );
                return stop(&mut children, 1);
            }
        }
    }

    loop {
        match mask.wait() {
            Ok(Signal::SIGCHLD) => {
                if let Some((network, how)) = reap(&mut children).into_iter().next() {
                    eprintln!("proxy: network {network}: smokescreen exited ({how}); stopping");
                    return stop(&mut children, 1);
                }
            }
            Ok(sig) => {
                eprintln!("proxy: {sig}; stopping");
                return stop(&mut children, 0);
            }
            Err(e) => {
                eprintln!("proxy: sigwait: {e}; stopping");
                return stop(&mut children, 1);
            }
        }
    }
}

fn prepare(opts: &Opts, config: &Config) -> Result<Facts, String> {
    let facts = facts::gather(config, opts.port, &opts.resolver)?;
    policy::check_exceptions(config, &facts)?;
    policy::write_all(&opts.run_dir, config, &facts)?;
    let path = opts.run_dir.join("facts.json");
    facts::write(&path, &facts).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(facts)
}

/// Reaps every exited child; returns the supervised ones that exited, with how.
fn reap(children: &mut [Child]) -> Vec<(String, String)> {
    let mut exited = Vec::new();
    loop {
        let (pid, how) = match waitpid(None, Some(WaitPidFlag::WNOHANG)) {
            Ok(WaitStatus::Exited(pid, code)) => (pid, format!("exit code {code}")),
            Ok(WaitStatus::Signaled(pid, sig, _)) => (pid, format!("signal {sig}")),
            Ok(WaitStatus::StillAlive) | Err(Errno::ECHILD) => return exited,
            Ok(_) => continue,
            Err(Errno::EINTR) => continue,
            Err(_) => return exited,
        };
        if let Some(child) = children.iter_mut().find(|c| c.pid == pid && c.alive) {
            child.alive = false;
            exited.push((child.network.clone(), how));
        }
    }
}

/// Stops every live child (SIGTERM, then SIGKILL after the grace period) and returns
/// `code`.
fn stop(children: &mut [Child], code: u8) -> u8 {
    for child in children.iter().filter(|c| c.alive) {
        let _ = kill(child.pid, Signal::SIGTERM);
    }
    let deadline = Instant::now() + STOP_GRACE;
    loop {
        reap(children);
        if !children.iter().any(|c| c.alive) {
            return code;
        }
        if Instant::now() >= deadline {
            break;
        }
        sleep(Duration::from_millis(50));
    }
    for child in children.iter_mut().filter(|c| c.alive) {
        let _ = kill(child.pid, Signal::SIGKILL);
        let _ = waitpid(child.pid, None);
        child.alive = false;
    }
    code
}
