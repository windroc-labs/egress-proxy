//! `proxy health` as a process, against running state written by the library and an
//! in-process fake proxy.

use std::collections::BTreeMap;
use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::thread;
use std::time::{Duration, Instant};

use proxy::config;
use proxy::facts::{self, Facts};
use proxy::policy;

const WORKERS: &str = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n";

#[derive(Clone, Copy)]
enum Answer {
    /// 407 for the default deny probe, 200 for anything else.
    Policy,
    /// The same status for every target.
    Always(u16),
    /// 407 for the deny probe; no answer at all for anything else.
    SilentAllow,
}

/// Serves CONNECT requests on 127.0.0.1; returns the port.
fn fake_proxy(answer: Answer) -> u16 {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    thread::spawn(move || {
        for stream in listener.incoming().flatten() {
            thread::spawn(move || serve(stream, answer));
        }
    });
    port
}

fn serve(mut stream: TcpStream, answer: Answer) {
    let mut reader = BufReader::new(stream.try_clone().unwrap());
    let mut request = String::new();
    reader.read_line(&mut request).unwrap();
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap() == 0 || line == "\r\n" {
            break;
        }
    }
    let denied_target = request.contains("169.254.169.254:80");
    let status = match answer {
        Answer::Policy if denied_target => 407,
        Answer::Policy => 200,
        Answer::Always(code) => code,
        Answer::SilentAllow if denied_target => 407,
        Answer::SilentAllow => {
            thread::sleep(Duration::from_secs(8));
            return;
        }
    };
    let _ = write!(stream, "HTTP/1.1 {status} X\r\nContent-Length: 0\r\n\r\n");
}

struct State {
    _dir: tempfile::TempDir,
    config: PathBuf,
    run_dir: PathBuf,
}

/// Writes `config_text` and the running state `proxy run` would have written, with
/// every network listening on 127.0.0.1:`port`.
fn started(config_text: &str, port: u16) -> State {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("config.local.yaml");
    fs::write(&config_path, config_text).unwrap();
    let cfg = config::parse(&config_path, config_text).unwrap();
    let facts = Facts {
        port,
        networks: cfg
            .networks
            .keys()
            .map(|k| (k.clone(), "127.0.0.1".parse().unwrap()))
            .collect::<BTreeMap<_, _>>(),
        host_docker_internal: vec!["192.168.65.254".parse().unwrap()],
        own_addrs: vec!["127.0.0.1".parse().unwrap()],
        exceptions: BTreeMap::new(),
        subnets: BTreeMap::new(),
    };
    let run_dir = dir.path().join("run");
    policy::write_all(&run_dir, &cfg, &facts).unwrap();
    facts::write(&run_dir.join("facts.json"), &facts).unwrap();
    State {
        _dir: dir,
        config: config_path,
        run_dir,
    }
}

fn health(config: &Path, run_dir: &Path, networks: &str) -> (Option<i32>, String) {
    let Output { status, stdout, .. } = Command::new(env!("CARGO_BIN_EXE_proxy"))
        .arg("health")
        .arg("--config")
        .arg(config)
        .arg("--run-dir")
        .arg(run_dir)
        .env("EGRESS_NETWORKS", networks)
        .output()
        .unwrap();
    (status.code(), String::from_utf8_lossy(&stdout).into_owned())
}

fn check(state: &State) -> (Option<i32>, String) {
    health(&state.config, &state.run_dir, "workers")
}

#[test]
fn healthy_when_all_pass() {
    let s = started(WORKERS, fake_proxy(Answer::Policy));
    let (code, out) = check(&s);
    assert_eq!(code, Some(0), "{out}");
    assert!(
        out.contains("ok network workers: running policy matches"),
        "{out}"
    );
    assert!(
        out.contains("ok network workers: deny probe 169.254.169.254:80 denied"),
        "{out}"
    );
    assert!(
        out.contains("ok network workers: allow probe example.com:443 not denied"),
        "{out}"
    );
    assert!(!out.contains("FAIL"), "{out}");
}

#[test]
fn drift_names_network() {
    let s = started(WORKERS, fake_proxy(Answer::Policy));
    fs::write(
        &s.config,
        "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    deny_ranges: [203.0.113.0/24]\n",
    )
    .unwrap();
    let (code, out) = check(&s);
    assert_eq!(code, Some(1), "{out}");
    let want = format!(
        "FAIL network workers: running policy differs from {}; run ./start.sh",
        s.config.display()
    );
    assert!(out.contains(&want), "{out}");
}

#[test]
fn deny_probe_allowed_fails() {
    let s = started(WORKERS, fake_proxy(Answer::Always(200)));
    let (code, out) = check(&s);
    assert_eq!(code, Some(1), "{out}");
    assert!(
        out.contains(
            "FAIL network workers: deny probe 169.254.169.254:80 was not denied (status 200)"
        ),
        "{out}"
    );
}

#[test]
fn allow_probe_denied_fails() {
    let s = started(WORKERS, fake_proxy(Answer::Always(407)));
    let (code, out) = check(&s);
    assert_eq!(code, Some(1), "{out}");
    assert!(
        out.contains("FAIL network workers: allow probe example.com:443 was denied (status 407)"),
        "{out}"
    );
}

#[test]
fn allow_probe_timeout_passes() {
    let s = started(WORKERS, fake_proxy(Answer::SilentAllow));
    let start = Instant::now();
    let (code, out) = check(&s);
    assert_eq!(code, Some(0), "{out}");
    assert!(
        out.contains("allow probe example.com:443 not denied (no answer"),
        "{out}"
    );
    assert!(
        start.elapsed() < Duration::from_secs(6),
        "took {:?}",
        start.elapsed()
    );
}

#[test]
fn networks_checked_concurrently() {
    let two = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n  api:\n    mode: denylist\n";
    let s = started(two, fake_proxy(Answer::SilentAllow));
    let start = Instant::now();
    let (code, out) = health(&s.config, &s.run_dir, "workers,api");
    assert_eq!(code, Some(0), "{out}");
    assert!(
        start.elapsed() < Duration::from_secs(5),
        "took {:?}",
        start.elapsed()
    );
}

#[test]
fn port_unreachable_fails() {
    let port = {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap().port()
    };
    let s = started(WORKERS, port);
    let (code, out) = check(&s);
    assert_eq!(code, Some(1), "{out}");
    assert!(
        out.contains(&format!(
            "FAIL network workers: cannot connect to the proxy at 127.0.0.1:{port}"
        )),
        "{out}"
    );
}

#[test]
fn bad_config_fails() {
    let s = started(WORKERS, fake_proxy(Answer::Policy));
    fs::write(&s.config, "version: 1\nnetworks:\n  workers: {}\n").unwrap();
    let (code, out) = check(&s);
    assert_eq!(code, Some(1), "{out}");
    assert!(out.contains("FAIL config "), "{out}");
    assert!(out.contains("network workers: missing key mode"), "{out}");
}

#[test]
fn not_started_fails() {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("config.local.yaml");
    fs::write(&config_path, WORKERS).unwrap();
    let (code, out) = health(&config_path, &dir.path().join("run"), "workers");
    assert_eq!(code, Some(1), "{out}");
    assert!(out.contains("FAIL not started: "), "{out}");
}

#[test]
fn networks_mismatch_fails() {
    let s = started(WORKERS, fake_proxy(Answer::Policy));
    let (code, out) = health(&s.config, &s.run_dir, "workers,api");
    assert_eq!(code, Some(1), "{out}");
    assert!(
        out.contains("differ from the proxy's networks [api, workers]"),
        "{out}"
    );
}

#[test]
fn network_added_without_restart_fails() {
    let s = started(WORKERS, fake_proxy(Answer::Policy));
    let two = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n  api:\n    mode: denylist\n";
    fs::write(&s.config, two).unwrap();
    let (code, out) = health(&s.config, &s.run_dir, "workers,api");
    assert_eq!(code, Some(1), "{out}");
    assert!(
        out.contains("FAIL networks [api, workers] differ from the running networks [workers]; run ./start.sh"),
        "{out}"
    );
}

#[test]
fn exception_drift_fails() {
    let with_exception = |entry: &str| {
        format!(
            "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    exceptions: [\"{entry}\"]\n"
        )
    };
    let s = started(
        &with_exception("192.168.1.20:11434"),
        fake_proxy(Answer::Policy),
    );
    let (code, out) = check(&s);
    assert_eq!(code, Some(0), "{out}");
    for changed in ["192.168.1.20:11435", "nas.lan:11434"] {
        fs::write(&s.config, with_exception(changed)).unwrap();
        let (code, out) = check(&s);
        assert_eq!(code, Some(1), "{changed}: {out}");
        assert!(
            out.contains("FAIL network workers: running policy differs from"),
            "{changed}: {out}"
        );
    }
}
