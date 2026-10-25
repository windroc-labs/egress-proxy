//! `gateway run` as a process, with a fake smokescreen.

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::thread::sleep;
use std::time::{Duration, Instant};

use nix::sys::signal::{Signal, kill};
use nix::unistd::Pid;

const TWO_NETWORKS: &str = "version: 1\nnetworks:\n  workers:\n    mode: denylist\n  api:\n    mode: allowlist\n    allow: [example.com]\n";

/// Records its pid next to the config it was given, then sleeps; exits 3 instead when
/// its config path contains `$FAKE_EXIT_FOR`.
const FAKE_SMOKESCREEN: &str = r#"#!/bin/sh
echo $$ > "$2.pid"
if [ -n "$FAKE_EXIT_FOR" ]; then
  case "$2" in *"$FAKE_EXIT_FOR"*) sleep 0.3; exit 3 ;; esac
fi
exec sleep 30
"#;

struct Setup {
    _dir: tempfile::TempDir,
    root: PathBuf,
}

impl Setup {
    fn new(config: &str) -> Setup {
        let dir = tempfile::tempdir().unwrap();
        let root = dir.path().to_path_buf();
        fs::write(root.join("config.yaml"), config).unwrap();
        let fake = root.join("smokescreen");
        fs::write(&fake, FAKE_SMOKESCREEN).unwrap();
        fs::set_permissions(&fake, fs::Permissions::from_mode(0o755)).unwrap();
        Setup { _dir: dir, root }
    }

    fn run_dir(&self) -> PathBuf {
        self.root.join("run")
    }

    fn command(&self, networks: Option<&str>) -> Command {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_gateway"));
        cmd.arg("run")
            .arg("--config")
            .arg(self.root.join("config.yaml"))
            .arg("--run-dir")
            .arg(self.run_dir())
            .arg("--smokescreen")
            .arg(self.root.join("smokescreen"))
            .args(["--port", "4750"])
            .args(["--resolve", "egress-proxy-workers=127.0.0.1"])
            .args(["--resolve", "egress-proxy-api=127.0.0.1"])
            .args(["--resolve", "host.docker.internal="])
            .env_remove("EGRESS_NETWORKS")
            .env_remove("FAKE_EXIT_FOR")
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        if let Some(n) = networks {
            cmd.env("EGRESS_NETWORKS", n);
        }
        cmd
    }

    fn pid_file(&self, key: &str) -> PathBuf {
        self.run_dir().join(key).join("config.yaml.pid")
    }

    fn child_pid(&self, key: &str) -> Pid {
        wait_for(|| self.pid_file(key).exists(), "fake smokescreen pid file");
        let text = fs::read_to_string(self.pid_file(key)).unwrap();
        Pid::from_raw(text.trim().parse().unwrap())
    }
}

fn wait_for(mut done: impl FnMut() -> bool, what: &str) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        sleep(Duration::from_millis(50));
    }
}

fn wait_exit(child: &mut Child) -> ExitStatus {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(status) = child.try_wait().unwrap() {
            return status;
        }
        assert!(Instant::now() < deadline, "gateway did not exit");
        sleep(Duration::from_millis(50));
    }
}

fn stderr_of(child: Child) -> String {
    let out = child.wait_with_output().unwrap();
    String::from_utf8_lossy(&out.stderr).into_owned()
}

fn alive(pid: Pid) -> bool {
    kill(pid, None).is_ok()
}

fn mode(path: &Path) -> u32 {
    fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn writes_policy_files() {
    let s = Setup::new(TWO_NETWORKS);
    let mut gw = s.command(Some("workers,api")).spawn().unwrap();
    s.child_pid("workers");
    s.child_pid("api");
    let config = fs::read_to_string(s.run_dir().join("workers/config.yaml")).unwrap();
    assert!(config.contains("ip: \"127.0.0.1\"\n"), "{config}");
    assert!(config.contains("port: 4750\n"), "{config}");
    let acl = fs::read_to_string(s.run_dir().join("api/acl.yaml")).unwrap();
    assert!(acl.contains("action: enforce"), "{acl}");
    assert_eq!(mode(&s.run_dir().join("facts.json")), 0o600);
    assert_eq!(mode(&s.run_dir().join("workers/config.yaml")), 0o600);
    kill(Pid::from_raw(gw.id() as i32), Signal::SIGTERM).unwrap();
    assert_eq!(wait_exit(&mut gw).code(), Some(0));
    let err = stderr_of(gw);
    assert!(
        err.contains("gateway: network workers (denylist) listening on 127.0.0.1:4750"),
        "{err}"
    );
}

#[test]
fn sigterm_stops_children_exit_0() {
    let s = Setup::new(TWO_NETWORKS);
    let mut gw = s.command(Some("workers,api")).spawn().unwrap();
    let pids = [s.child_pid("workers"), s.child_pid("api")];
    kill(Pid::from_raw(gw.id() as i32), Signal::SIGTERM).unwrap();
    assert_eq!(wait_exit(&mut gw).code(), Some(0));
    for pid in pids {
        assert!(!alive(pid), "smokescreen {pid} survived the gateway");
    }
}

#[test]
fn child_exit_stops_all_exit_1() {
    let s = Setup::new(TWO_NETWORKS);
    let mut gw = s
        .command(Some("workers,api"))
        .env("FAKE_EXIT_FOR", "/api/")
        .spawn()
        .unwrap();
    let workers = s.child_pid("workers");
    assert_eq!(wait_exit(&mut gw).code(), Some(1));
    assert!(!alive(workers), "workers smokescreen survived");
    let err = stderr_of(gw);
    assert!(
        err.contains("gateway: network api: smokescreen exited (exit code 3); stopping"),
        "{err}"
    );
}

#[test]
fn missing_mode_exits_2() {
    let s = Setup::new("version: 1\nnetworks:\n  workers:\n    deny_ranges: []\n");
    let mut gw = s.command(Some("workers")).spawn().unwrap();
    assert_eq!(wait_exit(&mut gw).code(), Some(2));
    let err = stderr_of(gw);
    assert!(err.contains("network workers: missing key mode"), "{err}");
    assert!(!s.run_dir().exists(), "a policy was written");
}

#[test]
fn networks_mismatch_exits_2() {
    let s = Setup::new("version: 1\nnetworks:\n  workers:\n    mode: denylist\n");
    let mut gw = s.command(Some("workers,api")).spawn().unwrap();
    assert_eq!(wait_exit(&mut gw).code(), Some(2));
    let err = stderr_of(gw);
    assert!(
        err.contains("networks [workers] differ from the gateway's networks [api, workers]"),
        "{err}"
    );
    assert!(!s.run_dir().exists(), "a policy was written");
}

#[test]
fn missing_env_exits_2() {
    let s = Setup::new("version: 1\nnetworks:\n  workers:\n    mode: denylist\n");
    let mut gw = s.command(None).spawn().unwrap();
    assert_eq!(wait_exit(&mut gw).code(), Some(2));
    let err = stderr_of(gw);
    assert!(err.contains("EGRESS_NETWORKS is not set"), "{err}");
}

#[test]
fn unknown_option_exits_2() {
    let out = Command::new(env!("CARGO_BIN_EXE_gateway"))
        .args(["run", "--bogus"])
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
    let err = String::from_utf8_lossy(&out.stderr);
    assert!(err.contains("unknown option --bogus"), "{err}");
}

#[test]
fn unresolved_exception_exits_1() {
    let s = Setup::new(
        "version: 1\nnetworks:\n  workers:\n    mode: denylist\n    exceptions: [\"nas.lan:8080\"]\n",
    );
    let mut gw = s
        .command(Some("workers"))
        .args(["--resolve", "nas.lan="])
        .spawn()
        .unwrap();
    assert_eq!(wait_exit(&mut gw).code(), Some(1));
    let err = stderr_of(gw);
    assert!(
        err.contains("gateway: network workers: exceptions: cannot resolve nas.lan"),
        "{err}"
    );
    assert!(!s.pid_file("workers").exists(), "a smokescreen was started");
}
