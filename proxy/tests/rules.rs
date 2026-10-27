//! `proxy rules` as a process, against running state written by the library.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

use proxy::config;
use proxy::facts::{self, Facts};
use proxy::policy;

const WORKERS: &str = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    exceptions: [host.docker.internal:11434]\n";

struct State {
    _dir: tempfile::TempDir,
    config: PathBuf,
    run_dir: PathBuf,
}

/// Writes `config_text` and the running state `proxy run` would have written for it.
fn started(config_text: &str) -> State {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("config.local.yaml");
    fs::write(&config_path, config_text).unwrap();
    let cfg = config::parse(&config_path, config_text).unwrap();
    let facts = Facts {
        port: 4750,
        networks: BTreeMap::from([("workers".to_string(), "172.20.0.2".parse().unwrap())]),
        host_docker_internal: vec!["192.168.65.254".parse().unwrap()],
        own_addrs: vec!["172.20.0.2".parse().unwrap()],
        exceptions: BTreeMap::from([(
            "host.docker.internal".to_string(),
            vec!["192.168.65.254".parse().unwrap()],
        )]),
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

fn rules(state: &State) -> Output {
    Command::new(env!("CARGO_BIN_EXE_proxy"))
        .arg("rules")
        .arg("--config")
        .arg(&state.config)
        .arg("--run-dir")
        .arg(&state.run_dir)
        .env("EGRESS_NETWORKS", "workers")
        .output()
        .unwrap()
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn prints_rules() {
    let state = started(WORKERS);
    let out = rules(&state);
    assert_eq!(out.status.code(), Some(0), "{}", text(&out.stderr));
    let stdout = text(&out.stdout);
    assert!(
        stdout.starts_with("network workers (Docker network egress-workers, proxy http://egress-proxy-workers:4750)\n"),
        "{stdout}"
    );
    assert!(
        stdout
            .lines()
            .any(|l| l == "    host.docker.internal:11434 -> 192.168.65.254:11434"),
        "{stdout}"
    );
    assert!(out.stderr.is_empty(), "{}", text(&out.stderr));
}

#[test]
fn not_started() {
    let state = started(WORKERS);
    fs::remove_file(state.run_dir.join("facts.json")).unwrap();
    let out = rules(&state);
    assert_eq!(out.status.code(), Some(2));
    assert!(out.stdout.is_empty());
    assert!(
        text(&out.stderr).starts_with("proxy: not started: "),
        "{}",
        text(&out.stderr)
    );
}

#[test]
fn config_error() {
    let state = started(WORKERS);
    fs::write(&state.config, "version: 1\nnetworks:\n  workers: {}\n").unwrap();
    let out = rules(&state);
    assert_eq!(out.status.code(), Some(2));
    assert!(out.stdout.is_empty());
    assert!(
        text(&out.stderr).starts_with("proxy: "),
        "{}",
        text(&out.stderr)
    );
}

#[test]
fn differs() {
    let state = started(WORKERS);
    fs::write(
        &state.config,
        format!("{WORKERS}    deny_ranges: [203.0.113.0/24]\n"),
    )
    .unwrap();
    let out = rules(&state);
    assert_eq!(out.status.code(), Some(3));
    assert!(out.stdout.is_empty(), "{}", text(&out.stdout));
    assert_eq!(
        text(&out.stderr),
        format!(
            "proxy: network workers: running policy differs from {}; run ./start.sh\n",
            state.config.display()
        )
    );
}
