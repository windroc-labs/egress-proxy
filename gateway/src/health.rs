//! `gateway health`, the image's `HEALTHCHECK`: the running policy still matches the
//! mounted config, and each network's proxy answers its probes as its policy says.

use std::io::{self, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpStream};
use std::thread;
use std::time::Duration;

use crate::cli::Opts;
use crate::config::{self, HostPort, Network};
use crate::facts::{self, Facts};
use crate::policy;

const CONNECT_TIMEOUT: Duration = Duration::from_secs(2);
/// smokescreen denies before it dials, so a deny arrives at once; an allowed target
/// may still be connecting when this runs out.
const PROBE_WAIT: Duration = Duration::from_secs(3);
const DENIED: u16 = 407;
const RESTART: &str = "restart the gateway (docker compose restart gateway)";

struct Line {
    ok: bool,
    text: String,
}

fn ok(text: String) -> Line {
    Line { ok: true, text }
}

fn fail(text: String) -> Line {
    Line { ok: false, text }
}

/// Prints one line per check; returns 0 when all pass, else 1.
pub fn run(opts: &Opts) -> u8 {
    let lines = check(opts);
    for line in &lines {
        println!("{} {}", if line.ok { "ok" } else { "FAIL" }, line.text);
    }
    if lines.iter().all(|l| l.ok) { 0 } else { 1 }
}

fn check(opts: &Opts) -> Vec<Line> {
    let facts = match facts::read(&opts.run_dir.join("facts.json")) {
        Ok(f) => f,
        Err(e) => return vec![fail(format!("not started: {e}"))],
    };
    let advertised = std::env::var("EGRESS_NETWORKS").ok();
    let config = match config::load_served(&opts.config, advertised.as_deref()) {
        Ok(c) => c,
        Err(e) => return vec![fail(e)],
    };
    let configured: Vec<&str> = config.networks.keys().map(String::as_str).collect();
    let running: Vec<&str> = facts.networks.keys().map(String::as_str).collect();
    if configured != running {
        return vec![fail(format!(
            "networks [{}] differ from the running networks [{}]; {RESTART}",
            configured.join(", "),
            running.join(", ")
        ))];
    }

    let mut lines = Vec::new();
    for (key, network) in &config.networks {
        lines.push(policy_line(opts, key, network, &facts));
    }
    let probed: Vec<Vec<Line>> = thread::scope(|scope| {
        let handles: Vec<_> = config
            .networks
            .iter()
            .map(|(key, network)| {
                let ip = facts.networks[key];
                scope.spawn(move || probe_network(key, network, ip, facts.port))
            })
            .collect();
        handles
            .into_iter()
            .map(|h| h.join().expect("probe thread"))
            .collect()
    });
    lines.extend(probed.into_iter().flatten());
    lines
}

fn policy_line(opts: &Opts, key: &str, network: &Network, facts: &Facts) -> Line {
    let want = policy::generate(key, network, facts.networks[key], facts, &opts.run_dir);
    match policy::read_running(&opts.run_dir, key) {
        Ok(running) if running == want => ok(format!(
            "network {key}: running policy matches {}",
            opts.config.display()
        )),
        Ok(_) => fail(format!(
            "network {key}: running policy differs from {}; {RESTART}",
            opts.config.display()
        )),
        Err(e) => fail(format!(
            "network {key}: cannot read the running policy: {e}"
        )),
    }
}

fn probe_network(key: &str, network: &Network, ip: IpAddr, port: u16) -> Vec<Line> {
    let proxy = SocketAddr::new(ip, port);
    if let Err(e) = TcpStream::connect_timeout(&proxy, CONNECT_TIMEOUT) {
        return vec![fail(format!(
            "network {key}: cannot connect to the proxy at {proxy}: {e}"
        ))];
    }
    let deny = &network.health.deny_probe;
    let deny_line = match connect_status(proxy, deny) {
        Ok(Some(DENIED)) => ok(format!(
            "network {key}: deny probe {deny} denied (status 407)"
        )),
        Ok(Some(code)) => fail(format!(
            "network {key}: deny probe {deny} was not denied (status {code})"
        )),
        Ok(None) => fail(format!(
            "network {key}: deny probe {deny} was not denied (no answer in {}s)",
            PROBE_WAIT.as_secs()
        )),
        Err(e) => fail(format!("network {key}: deny probe {deny}: {e}")),
    };
    let allow = &network.health.allow_probe;
    let allow_line = match connect_status(proxy, allow) {
        Ok(Some(DENIED)) => fail(format!(
            "network {key}: allow probe {allow} was denied (status 407)"
        )),
        Ok(Some(code)) => ok(format!(
            "network {key}: allow probe {allow} not denied (status {code})"
        )),
        Ok(None) => ok(format!(
            "network {key}: allow probe {allow} not denied (no answer in {}s; still connecting)",
            PROBE_WAIT.as_secs()
        )),
        Err(e) => fail(format!("network {key}: allow probe {allow}: {e}")),
    };
    vec![deny_line, allow_line]
}

/// Sends `CONNECT target` to the proxy; returns the response status, or `None` when no
/// status line arrived within [`PROBE_WAIT`].
fn connect_status(proxy: SocketAddr, target: &HostPort) -> io::Result<Option<u16>> {
    let mut stream = TcpStream::connect_timeout(&proxy, CONNECT_TIMEOUT)?;
    stream.set_read_timeout(Some(PROBE_WAIT))?;
    stream.set_write_timeout(Some(PROBE_WAIT))?;
    write!(
        stream,
        "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n"
    )?;
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    while !line.ends_with(b"\n") && line.len() < 256 {
        match stream.read(&mut byte) {
            Ok(0) => {
                return Err(io::Error::new(
                    io::ErrorKind::UnexpectedEof,
                    "the proxy closed the connection without a status",
                ));
            }
            Ok(_) => line.push(byte[0]),
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                return Ok(None);
            }
            Err(e) => return Err(e),
        }
    }
    let text = String::from_utf8_lossy(&line);
    text.split_whitespace()
        .nth(1)
        .filter(|_| text.starts_with("HTTP/"))
        .and_then(|code| code.parse().ok())
        .map(Some)
        .ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                format!("not an HTTP status line: {}", text.trim_end()),
            )
        })
}
