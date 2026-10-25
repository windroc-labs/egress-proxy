//! `gateway plan` as a process, against running state written by the library.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use gateway::config;
use gateway::facts::{self, Facts};
use gateway::policy;

const TWO: &str = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n  mini-op:\n    mode: allowlist\n    allow: [example.com]\n";

struct State {
    _dir: tempfile::TempDir,
    config: PathBuf,
    run_dir: PathBuf,
}

/// Writes `config_text` and the running state `gateway run` would have written for it.
fn started(config_text: &str) -> State {
    let dir = tempfile::tempdir().unwrap();
    let config_path = dir.path().join("config.local.yaml");
    fs::write(&config_path, config_text).unwrap();
    let cfg = config::parse(&config_path, config_text).unwrap();
    let facts = Facts {
        port: 4750,
        networks: BTreeMap::from([
            ("mini-op".to_string(), "172.21.0.2".parse().unwrap()),
            ("workers".to_string(), "172.20.0.2".parse().unwrap()),
        ]),
        host_docker_internal: vec!["192.168.65.254".parse().unwrap()],
        own_addrs: vec!["172.20.0.2".parse().unwrap(), "172.21.0.2".parse().unwrap()],
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

fn plan(state: &State, key: &str, advertised: &str) -> Output {
    Command::new(env!("CARGO_BIN_EXE_gateway"))
        .args(["plan", key, "--listener-port", "50123"])
        .args([
            "--host-addr",
            "192.168.1.20/24",
            "--default-gateway",
            "192.168.1.1",
        ])
        .arg("--config")
        .arg(&state.config)
        .arg("--run-dir")
        .arg(&state.run_dir)
        .env("EGRESS_NETWORKS", advertised)
        .output()
        .unwrap()
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[test]
fn prints_tab_separated_checks() {
    let state = started(TWO);
    let out = plan(&state, "workers", "mini-op,workers");
    assert_eq!(out.status.code(), Some(0), "{}", text(&out.stderr));
    let stdout = text(&out.stdout);
    assert!(
        stdout.lines().all(|l| l.split('\t').count() == 3),
        "{stdout}"
    );
    for line in [
        "proxy_allow\tproxy_allow\thttps://example.com/",
        "proxy_deny\tproxy_deny\t192.168.1.20:443",
        "proxy_deny\tproxy_deny\thost.docker.internal:50123",
        "cross_none\tcross_none\thttp://172.21.0.2:4750/",
        "direct_none\tdirect_none\thttps://192.168.1.1:443/",
    ] {
        assert!(stdout.lines().any(|l| l == line), "{line} in {stdout}");
    }
    assert!(out.stderr.is_empty());
}

#[test]
fn drift_refused() {
    let state = started(TWO);
    fs::write(
        &state.config,
        TWO.replace("allow: [example.com]", "allow: [example.org]"),
    )
    .unwrap();
    let out = plan(&state, "mini-op", "mini-op,workers");
    assert_eq!(out.status.code(), Some(2));
    assert!(out.stdout.is_empty());
    assert_eq!(
        text(&out.stderr),
        format!(
            "gateway: network mini-op: running policy differs from {}; restart the gateway (docker compose restart gateway)\n",
            state.config.display()
        )
    );
}

#[test]
fn unknown_network_and_missing_state() {
    let state = started(TWO);
    let out = plan(&state, "other", "mini-op,workers");
    assert_eq!(out.status.code(), Some(2));
    assert_eq!(
        text(&out.stderr),
        "gateway: network other is not in the config\n"
    );
    fs::remove_file(state.run_dir.join("facts.json")).unwrap();
    let out = plan(&state, "workers", "mini-op,workers");
    assert_eq!(out.status.code(), Some(2));
    assert!(
        text(&out.stderr).starts_with("gateway: not started: "),
        "{}",
        text(&out.stderr)
    );
    assert!(Path::new(&state.config).exists());
}

#[test]
fn usage_errors_exit_2() {
    let out = Command::new(env!("CARGO_BIN_EXE_gateway"))
        .args(["plan", "workers"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(text(&out.stderr).starts_with("gateway: plan needs --listener-port\n"));
}
