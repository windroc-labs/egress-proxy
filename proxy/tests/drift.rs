//! `proxy drift` as a process, against running state written by the library.

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;
use std::process::{Command, Output};

use proxy::config;
use proxy::facts::{self, Facts};
use proxy::policy;

const WORKERS: &str = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n";

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

fn drift(state: &State) -> Output {
    Command::new(env!("CARGO_BIN_EXE_proxy"))
        .arg("drift")
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
fn matches_exits_0() {
    let state = started(WORKERS);
    let out = drift(&state);
    assert_eq!(out.status.code(), Some(0), "{}", text(&out.stderr));
    assert_eq!(
        text(&out.stdout),
        format!(
            "network workers: running policy matches {}\n",
            state.config.display()
        )
    );
}

#[test]
fn comment_only_edit_matches() {
    let state = started(WORKERS);
    fs::write(&state.config, format!("# edited\n{WORKERS}")).unwrap();
    assert_eq!(drift(&state).status.code(), Some(0));
}

#[test]
fn policy_edit_exits_3() {
    let state = started(WORKERS);
    fs::write(
        &state.config,
        format!("{WORKERS}    deny_ranges: [203.0.113.0/24]\n"),
    )
    .unwrap();
    let out = drift(&state);
    assert_eq!(out.status.code(), Some(3));
    assert_eq!(
        text(&out.stdout),
        format!(
            "network workers: running policy differs from {}; run ./start.sh\n",
            state.config.display()
        )
    );
}

#[test]
fn unreadable_running_policy_exits_3() {
    let state = started(WORKERS);
    fs::remove_file(policy::network_dir(&state.run_dir, "workers").join("acl.yaml")).unwrap();
    let out = drift(&state);
    assert_eq!(out.status.code(), Some(3));
    assert!(
        text(&out.stdout).starts_with("network workers: cannot read the running policy: "),
        "{}",
        text(&out.stdout)
    );
}

#[test]
fn not_started_exits_2() {
    let state = started(WORKERS);
    fs::remove_file(state.run_dir.join("facts.json")).unwrap();
    let out = drift(&state);
    assert_eq!(out.status.code(), Some(2));
    assert!(out.stdout.is_empty());
    assert!(
        text(&out.stderr).starts_with("proxy: not started: "),
        "{}",
        text(&out.stderr)
    );
}

#[test]
fn config_error_exits_2() {
    let state = started(WORKERS);
    fs::write(&state.config, "version: 1\nnetworks:\n  workers: {}\n").unwrap();
    let out = drift(&state);
    assert_eq!(out.status.code(), Some(2));
    assert!(
        text(&out.stderr).starts_with("proxy: "),
        "{}",
        text(&out.stderr)
    );
}
