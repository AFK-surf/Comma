#![cfg(unix)]

//! The launcher run as launchd runs it, with a stand-in for the station's Node side (fixtures/main.js) on a real Node
//! ($STILLFAIL_NODE, else the build machine's). Each test has its own data directory; the launcher binds its ports
//! where it finds them free (port 0), so no other program can take them first.
//!
//! What these tests decide is the code's, not the machine's speed's: they wait for what the processes do, with no
//! limit of time. The ones whose point is real timing (no gap on the ports, the backoff's gaps) are the side run's
//! (`cargo test -- --ignored`); run.rs's tests have the same logic on a test's clock.

use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::net::{TcpListener, TcpStream};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, ExitStatus, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::Value;

const BUILT: &str = env!("CARGO_BIN_EXE_stillfail-station");

/// The launcher, run once before any test starts it. macOS looks at each new executable the first time it runs, and
/// the tests that start it at once all wait for that look.
fn launcher() -> &'static str {
    static LOOKED_AT: std::sync::Once = std::sync::Once::new();
    LOOKED_AT.call_once(|| assert!(output(Command::new(BUILT).arg("handoff-version")).status.success()));
    BUILT
}

/// The Node the station runs on (.node-version), where scripts/node-here.sh puts it, unless STILLFAIL_NODE says another.
fn node() -> String {
    let version = include_str!("../../../.node-version").trim();
    std::env::var("STILLFAIL_NODE").unwrap_or_else(|_| format!("{}/.local/node-v{version}-darwin-arm64/bin/node", std::env::var("HOME").unwrap()))
}

/// Held while a socket is made or a process started. On macOS a socket is made close-on-exec only after it is made: a
/// fork from another test thread in between would hand the child (a launcher) a copy of a test's listening socket.
static FORKS: Mutex<()> = Mutex::new(());

fn spawn(command: &mut Command) -> Child {
    let _forks = FORKS.lock().unwrap_or_else(|e| e.into_inner());
    command.spawn().unwrap()
}

fn output(command: &mut Command) -> std::process::Output {
    let _forks = FORKS.lock().unwrap_or_else(|e| e.into_inner());
    command.output().unwrap()
}

fn bind(port: u16) -> std::io::Result<TcpListener> {
    let _forks = FORKS.lock().unwrap_or_else(|e| e.into_inner());
    TcpListener::bind(("127.0.0.1", port))
}

/// A test's directory: data (with config.json naming the MCP port), app (with the stand-in as station/main.js).
struct Station {
    dir: PathBuf,
    data: PathBuf,
    app: PathBuf,
    /// The loopback port the launcher is given (--port): 0 for one free.
    port: u16,
    launcher: Option<Child>,
}

impl Station {
    fn new(name: &str) -> Station {
        let dir = std::env::temp_dir().join(format!("launcher-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (data, app) = (dir.join("data"), dir.join("app"));
        std::fs::create_dir_all(app.join("station")).unwrap();
        std::fs::create_dir_all(&data).unwrap();
        std::fs::copy(Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/main.js"), app.join("station/main.js")).unwrap();
        std::fs::write(data.join("config.json"), r#"{"http":{"port":0}}"#).unwrap();
        Station { dir, data, app, port: 0, launcher: None }
    }

    fn command(&self, times: &str) -> Command {
        let mut command = Command::new(launcher());
        command
            .env("STILLFAIL_NODE", node())
            .env("STILLFAIL_LAUNCHER_TIMES", times)
            .env_remove("STILLFAIL_DATA")
            .env_remove("EMBER_DATA")
            .env_remove("STILLFAIL_CONFIG")
            .env_remove("EMBER_CONFIG")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(std::fs::OpenOptions::new().create(true).append(true).open(self.dir.join("launcher.log")).unwrap());
        command
    }

    fn run_args(&self) -> Vec<String> {
        ["run", "--app", self.app.to_str().unwrap(), "--data", self.data.to_str().unwrap(), "--port", &self.port.to_string()].map(String::from).to_vec()
    }

    fn start(&mut self, times: &str) {
        let child = spawn(self.command(times).args(self.run_args()));
        self.launcher = Some(child);
    }

    fn pid(&self) -> i32 {
        self.launcher.as_ref().unwrap().id() as i32
    }

    fn signal(&self, signal: i32) {
        // SAFETY: a signal to the launcher this test started.
        assert_eq!(unsafe { libc::kill(self.pid(), signal) }, 0);
    }

    fn wait(&mut self) -> ExitStatus {
        self.launcher.as_mut().unwrap().wait().unwrap()
    }

    fn conf(&self, text: &str) {
        std::fs::write(self.data.join("fake.conf"), text).unwrap();
    }

    fn file(&self, name: &str) -> Option<String> {
        std::fs::read_to_string(self.data.join("run").join(name)).ok()
    }

    fn station_json(&self) -> Option<Value> {
        self.file("station.json").and_then(|t| serde_json::from_str(&t).ok())
    }

    /// The stand-in's log: (ms, pid, what).
    fn log(&self) -> Vec<(u64, i32, String)> {
        let text = std::fs::read_to_string(self.data.join("fake.log")).unwrap_or_default();
        text.lines()
            .filter_map(|l| {
                let mut parts = l.splitn(3, ' ');
                Some((parts.next()?.parse().ok()?, parts.next()?.parse().ok()?, parts.next()?.to_string()))
            })
            .collect()
    }

    fn said(&self, pid: i32, what: &str) -> bool {
        self.log().iter().any(|(_, p, w)| *p == pid && w.starts_with(what))
    }

    /// Where in the log `pid` first said `what`: the log is appended to in the order things happened.
    fn said_at(&self, pid: i32, what: &str) -> usize {
        self.log().iter().position(|(_, p, w)| *p == pid && w.starts_with(what)).unwrap()
    }

    fn started(&self) -> Vec<i32> {
        self.log().into_iter().filter(|(_, _, w)| w.starts_with("start")).map(|(_, p, _)| p).collect()
    }

    /// The ports the launcher bound, (MCP, loopback), once a Node serves them.
    fn ports(&mut self) -> (u16, u16) {
        self.until("a Node serving the ports", |station| {
            let log = station.log();
            let (_, _, ports) = log.iter().find(|(_, _, w)| w.starts_with("ports "))?;
            let mut ports = ports.split(' ').skip(1).map(|p| p.parse().unwrap());
            Some((ports.next()?, ports.next()?))
        })
    }

    fn mcp(&mut self) -> u16 {
        self.ports().0
    }

    fn admin(&mut self) -> u16 {
        self.ports().1
    }

    /// Waits for the station to be up: station.json written.
    fn up(&mut self) -> Value {
        let up = self.until("station.json or an exit", |station| match station.station_json() {
            Some(said) => Some(Ok(said)),
            None => station.launcher.as_mut().unwrap().try_wait().unwrap().map(Err),
        });
        up.unwrap_or_else(|status| panic!("the launcher exited ({status})"))
    }

    /// Waits for what the launcher and its Nodes do (a file one writes, a line one logs, the launcher's end), looking
    /// again each time one of these changes. Each of them logs what it does, the launcher a Node's end among it. No
    /// limit of time: the outcome must not depend on how fast the machine is.
    fn until<T>(&mut self, _what: &str, mut f: impl FnMut(&mut Station) -> Option<T>) -> T {
        loop {
            // Watched before looking: a change after the look ends the wait.
            let mut changes = Changes::new();
            for path in [self.dir.join("launcher.log"), self.data.clone(), self.data.join("run"), self.data.join("fake.log")] {
                changes.file(&path);
            }
            if let Some(launcher) = &mut self.launcher
                && launcher.try_wait().unwrap().is_none()
            {
                changes.end(launcher.id() as i32);
            }
            if let Some(v) = f(self) {
                return v;
            }
            changes.wait();
        }
    }
}

impl Drop for Station {
    fn drop(&mut self) {
        if std::thread::panicking() {
            eprintln!("--- launcher.log\n{}", std::fs::read_to_string(self.dir.join("launcher.log")).unwrap_or_default());
            eprintln!("--- fake.log\n{}", std::fs::read_to_string(self.data.join("fake.log")).unwrap_or_default());
        }
        // Only the launcher is killed: its Nodes end when their control socket closes.
        if let Some(child) = &mut self.launcher
            && child.try_wait().ok().flatten().is_none()
        {
            let _ = child.kill();
            let _ = child.wait();
        }
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

/// What to wait for a change of, with kqueue: files and directories (written to, an entry made or taken), processes'
/// ends.
struct Changes {
    kq: OwnedFd,
    watched: Vec<File>,
    /// A process watched had ended already: no wait.
    ended: bool,
}

impl Changes {
    fn new() -> Changes {
        // SAFETY: kqueue makes a descriptor, owned from here on (a fork does not copy it).
        let kq = unsafe { libc::kqueue() };
        assert!(kq >= 0, "kqueue: {}", std::io::Error::last_os_error());
        Changes { kq: unsafe { OwnedFd::from_raw_fd(kq) }, watched: vec![], ended: false }
    }

    fn add(&self, ident: usize, filter: i16, fflags: u32) -> std::io::Result<()> {
        // SAFETY: one change, from a live struct, to this kqueue.
        unsafe {
            let mut change: libc::kevent = std::mem::zeroed();
            change.ident = ident;
            change.filter = filter;
            change.flags = libc::EV_ADD | libc::EV_CLEAR;
            change.fflags = fflags;
            if libc::kevent(self.kq.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null()) != 0 {
                return Err(std::io::Error::last_os_error());
            }
        }
        Ok(())
    }

    /// A file or a directory, when it is there: one made later is a change to its directory.
    fn file(&mut self, path: &Path) {
        let Ok(file) = File::open(path) else { return };
        self.add(file.as_raw_fd() as usize, libc::EVFILT_VNODE, libc::NOTE_WRITE | libc::NOTE_EXTEND).unwrap();
        self.watched.push(file);
    }

    /// The end of `pid`; one ending or gone already is not waited for.
    fn end(&mut self, pid: i32) {
        match self.add(pid as usize, libc::EVFILT_PROC, libc::NOTE_EXIT) {
            Ok(()) => {}
            Err(e) if e.raw_os_error() == Some(libc::ESRCH) => self.ended = true,
            Err(e) => panic!("kevent: {e}"),
        }
    }

    fn wait(self) {
        if self.ended {
            return;
        }
        // SAFETY: an event, into a live struct, from this kqueue.
        unsafe {
            let mut got: libc::kevent = std::mem::zeroed();
            while libc::kevent(self.kq.as_raw_fd(), std::ptr::null(), 0, &mut got, 1, std::ptr::null()) < 0 {
                let error = std::io::Error::last_os_error();
                assert_eq!(error.kind(), std::io::ErrorKind::Interrupted, "kevent: {error}");
            }
        }
    }
}

/// Waits for `pid`, not this test's child, to end; one gone already is not waited for.
fn ends(pid: i32) {
    let mut changes = Changes::new();
    changes.end(pid);
    changes.wait();
}

fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only asks whether the process is there.
    unsafe { libc::kill(pid, 0) == 0 }
}

/// What the station answers on `port`: "<pid> mcp|admin". The launcher holds the listening socket: a connection waits
/// in its backlog until a Node takes it.
fn ask(port: u16) -> std::io::Result<String> {
    let mut stream = TcpStream::connect(("127.0.0.1", port))?;
    let mut text = String::new();
    stream.read_to_string(&mut text)?;
    if text.is_empty() {
        return Err(std::io::Error::other("closed without an answer"));
    }
    Ok(text.trim().to_string())
}

fn answered_by(port: u16) -> i32 {
    ask(port).unwrap().split(' ').next().unwrap().parse().unwrap()
}

#[test]
fn handoff_version_is_2() {
    let out = output(Command::new(launcher()).arg("handoff-version"));
    assert!(out.status.success());
    assert_eq!(String::from_utf8(out.stdout).unwrap(), "2\n");
}

#[test]
fn other_commands_are_node_s_with_the_same_arguments() {
    let station = Station::new("exec");
    let mut command = station.command("");
    let args = ["channel", "beta", "--app", station.app.to_str().unwrap(), "--data", station.data.to_str().unwrap()];
    let child = spawn(command.args(args).stdout(Stdio::piped()));
    let pid = child.id();
    let out = child.wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(7));
    let said: Value = serde_json::from_slice(&out.stdout).unwrap();
    // Exec'd: the same process.
    assert_eq!(said["pid"], pid);
    assert_eq!(said["args"], serde_json::json!(args));
}

#[test]
fn a_held_lock_exits_3() {
    let mut station = Station::new("held");
    std::fs::create_dir_all(station.data.join("run")).unwrap();
    let lock = std::fs::File::create(station.data.join("run/station.lock")).unwrap();
    // SAFETY: flock on a file this test owns.
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) }, 0);
    station.start("");
    assert_eq!(station.wait().code(), Some(3));
    assert!(std::fs::read_to_string(station.dir.join("launcher.log")).unwrap().contains("另一个 still.fail station 正在运行这个数据目录"));
    assert!(station.log().is_empty(), "no Node started");
}

#[test]
fn a_named_port_taken_fails_the_start() {
    let mut station = Station::new("taken");
    // Held by the test all along: taken for sure.
    let taken = bind(0).unwrap();
    station.port = taken.local_addr().unwrap().port();
    station.start("");
    assert_eq!(station.wait().code(), Some(1));
    assert!(std::fs::read_to_string(station.dir.join("launcher.log")).unwrap().contains(&format!("端口 127.0.0.1:{} 已被别的程序占用", station.port)));
    assert!(station.log().is_empty(), "no Node started");
}

#[test]
fn node_serves_the_launchers_ports_and_station_json_names_the_launcher() {
    let mut station = Station::new("ports");
    station.start("");
    let said = station.up();
    let text = station.file("station.json").unwrap();
    assert!(text.ends_with('\n') && text.trim_end().lines().count() == 1, "{text:?}");
    assert!(text.starts_with(&format!("{{\"pid\":{},\"startedAt\":", station.pid())), "{text}");
    assert_eq!(said["pid"], station.pid());
    assert_eq!(said["version"], "0.1.0");
    assert_eq!((said["handoff"].as_u64(), said["drain"].as_u64(), said["channel"].as_u64()), (Some(1), Some(1), Some(1)));
    let started_at = said["startedAt"].as_u64().unwrap();
    let (mcp, admin) = station.ports();
    assert_eq!(station.file("ports.json").unwrap(), format!("{{\"admin\":{admin}}}\n"));
    // The launcher bound them; Node accepts on them.
    let node = station.started()[0];
    assert_ne!(node, station.pid());
    assert_eq!(ask(mcp).unwrap(), format!("{node} mcp"));
    assert_eq!(ask(admin).unwrap(), format!("{node} admin"));
    let start = &station.log()[0].2;
    let app = station.app.display();
    let data = station.data.display();
    assert_eq!(start, &format!("start run --app {app} --data {data} --launcher-fds 3,4,5"));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    assert!(station.said(node, "got stop") && station.said(node, "exit"));
    // startedAt is the machine's time of Node's ready: not before Node logged it, not after Node logged the stop that
    // came once station.json was read.
    let logged = |what: &str| station.log().into_iter().find(|(_, p, w)| *p == node && w.starts_with(what)).unwrap().0;
    let (ready, stop) = (logged("ready"), logged("got stop"));
    assert!(ready <= started_at && started_at <= stop, "{ready} <= {started_at} <= {stop}");
}

#[test]
fn the_flags_after_a_double_dash_are_given_to_each_node() {
    let mut station = Station::new("rest");
    let child = spawn(station.command("").args(station.run_args()).args(["--", "--server", "https://salix.test"]));
    station.launcher = Some(child);
    station.up();
    let start = &station.log()[0].2;
    assert!(start.ends_with("--launcher-fds 3,4,5 -- --server https://salix.test"), "{start}");
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn sigusr2_hands_over_to_a_new_node() {
    let mut station = Station::new("handover");
    station.start("");
    station.up();
    let old = answered_by(station.mcp());
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    // Written again once the old one is gone.
    let after = station.until("station.json of the new version", |station| station.station_json().filter(|s| s["version"] == "0.2.0"));
    assert_eq!(after["pid"], station.pid(), "the pid stays");
    let new = *station.started().last().unwrap();
    assert_ne!(new, old);
    assert_eq!(answered_by(station.mcp()), new);
    assert_eq!(answered_by(station.admin()), new);
    assert!(station.said(old, "got handover") && station.said(old, "exit"));
    assert!(!alive(old));
    // The old one was told only once the new one was ready.
    assert!(station.said_at(new, "ready") < station.said_at(old, "got handover"));
    assert!(station.file("handoff-failed").is_none());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
#[ignore = "side: no gap on real ports while real processes hand over is a matter of real timing"]
fn sigusr2_hands_over_to_a_new_node_with_no_gap_on_the_ports() {
    let mut station = Station::new("nogap");
    station.start("");
    station.up();
    let (mcp, admin) = station.ports();
    let old = answered_by(mcp);
    // Asking both ports all along: every connection is answered, by the old Node, then the new.
    let stop = Arc::new(AtomicBool::new(false));
    let (said, answers) = std::sync::mpsc::channel();
    let askers: Vec<_> = [mcp, admin]
        .into_iter()
        .map(|port| {
            let (stop, said) = (stop.clone(), said.clone());
            std::thread::spawn(move || {
                while !stop.load(Ordering::SeqCst) {
                    said.send((port, ask(port))).unwrap();
                }
            })
        })
        .collect();
    drop(said);
    let mut failed = vec![];
    // Takes the answers until `node` has answered on both ports.
    let mut answered = |node: i32| {
        let mut ports = std::collections::BTreeSet::new();
        while ports.len() < 2 {
            match answers.recv().unwrap() {
                (port, Ok(said)) if said.starts_with(&format!("{node} ")) => _ = ports.insert(port),
                (_, Ok(_)) => {}
                (_, Err(e)) => failed.push(e.to_string()),
            }
        }
    };
    answered(old);
    station.conf("version=0.2.0\nready_after=400\n");
    station.signal(libc::SIGUSR2);
    station.until("station.json of the new version", |station| station.station_json().filter(|s| s["version"] == "0.2.0"));
    let new = answered_by(mcp);
    assert_ne!(new, old);
    answered(new);
    stop.store(true, Ordering::SeqCst);
    askers.into_iter().for_each(|t| t.join().unwrap());
    failed.extend(answers.iter().filter_map(|(_, said)| said.err().map(|e| e.to_string())));
    assert!(failed.is_empty(), "connections not answered: {failed:?}");
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn a_handover_whose_new_node_is_never_ready_fails_and_the_old_one_serves_on() {
    let mut station = Station::new("handfail");
    station.start("ready=1500");
    let first = station.up();
    let (mcp, admin) = station.ports();
    let old = answered_by(mcp);
    station.conf("ready=no\n");
    station.signal(libc::SIGUSR2);
    let why = station.until("handoff-failed", |station| station.file("handoff-failed"));
    assert!(why.contains("not ready"), "{why}");
    let new = *station.started().last().unwrap();
    assert_ne!(new, old);
    // Reaped by the launcher, which then logs its end.
    station.until("the new Node killed", |_| (!alive(new)).then_some(()));
    assert_eq!(station.station_json().unwrap(), first);
    assert_eq!(answered_by(mcp), old);
    assert_eq!(answered_by(admin), old);
    assert!(!station.said(old, "got handover"));
    // A later handover works.
    station.conf("version=0.2.0\n");
    station.signal(libc::SIGUSR2);
    station.until("station.json of the new version", |station| station.station_json().filter(|s| s["version"] == "0.2.0"));
    assert_ne!(answered_by(mcp), old);
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn a_handover_whose_new_node_does_not_take_over_fails_and_a_node_is_started_again_after_the_rollback_wait() {
    let mut station = Station::new("nottaken");
    station.start("rollback=500");
    let first = station.up();
    let (mcp, _) = station.ports();
    let old = answered_by(mcp);
    // Ready, so the old one hands over and goes; then its agents' side does not start.
    station.conf("version=0.2.0\ntake=failed\n");
    station.signal(libc::SIGUSR2);
    let why = until("handoff-failed", || station.file("handoff-failed"));
    assert!(why.contains("did not take over") && why.contains("a test's"), "{why}");
    let new = *station.started().last().unwrap();
    assert!(station.said(old, "got handover") && station.said(new, "take failed"));
    until("the new Node ended", || (!alive(new)).then_some(()));
    assert_eq!(station.station_json().unwrap(), first, "not said handed over");
    // The installer puts the release before back meanwhile; the Node started again is that one, and serves.
    station.conf("version=0.1.0\n");
    let again = until("station.json of a new start", || station.station_json().filter(|s| *s != first));
    assert_eq!(again["version"], "0.1.0");
    let node = *station.started().last().unwrap();
    assert!(node != new && node != old);
    assert_eq!(answered_by(mcp), node);
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn sigusr1_and_sighup_go_to_node_and_drained_is_written() {
    let mut station = Station::new("forward");
    station.start("");
    station.up();
    let node = station.started()[0];
    station.signal(libc::SIGUSR1);
    station.until("run/drained", |station| station.file("drained").filter(|d| d == "idle\n"));
    assert!(station.said(node, "got drain"));
    station.signal(libc::SIGHUP);
    station.until("hup", |station| station.said(node, "got hup").then_some(()));
    assert!(station.launcher.as_mut().unwrap().try_wait().unwrap().is_none());
    assert_eq!(answered_by(station.admin()), node);
    station.signal(libc::SIGINT);
    assert!(station.wait().success());
    assert!(station.said(node, "got stop"));
}

#[test]
fn sigterm_during_a_handover_stops_both() {
    let mut station = Station::new("stopboth");
    station.start("");
    station.up();
    station.conf("ready=no\n");
    station.signal(libc::SIGUSR2);
    let both = station.until("the second Node", |station| Some(station.started()).filter(|s| s.len() == 2));
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
    for pid in both {
        // Stopped when told, not killed when late.
        assert!(station.said(pid, "got stop") && station.said(pid, "exit"), "{pid}");
        assert!(!alive(pid));
    }
}

#[test]
#[ignore = "side: measures the gaps between real restarts"]
fn a_crashed_node_is_started_again_with_backoff() {
    let mut station = Station::new("crash");
    station.conf("crash_after=100\n");
    station.start("backoff=300");
    station.up();
    // Started, crashed, again after 300, 600, 1200 ms.
    let log = station.until("four starts", |station| Some(station.log()).filter(|l| l.iter().filter(|e| e.2.starts_with("start")).count() >= 4));
    station.conf("");
    let crashes: Vec<u64> = log.iter().filter(|e| e.2 == "crash").map(|e| e.0).collect();
    let starts: Vec<u64> = log.iter().filter(|e| e.2.starts_with("start")).map(|e| e.0).collect();
    for (i, expected) in [300u64, 600, 1200].into_iter().enumerate() {
        let gap = starts[i + 1] - crashes[i];
        // Wall-clock times (the log's) may be slewed against the launcher's monotonic clock: some leeway below.
        assert!(gap * 100 >= expected * 85 && gap < expected + 700, "restart {i}: {gap} ms, expected about {expected}");
    }
    // The launcher stays; a Node that does not crash serves again.
    let pid = station.pid();
    let mcp = station.mcp();
    station.until("a Node that stays", |station| {
        let node = *station.started().last()?;
        (station.said(node, "ready") && !station.said(node, "crash") && ask(mcp).ok()? == format!("{node} mcp")).then_some(())
    });
    assert_eq!(station.station_json().unwrap()["pid"], pid);
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn a_crashed_node_is_started_again() {
    let mut station = Station::new("restart");
    station.conf("crash=once\n");
    station.start("backoff=100");
    station.up();
    let first = station.started()[0];
    station.until("the first Node's crash", |station| station.said(first, "crash").then_some(()));
    let again = station.until("a Node that stays", |station| Some(*station.started().last()?).filter(|n| *n != first && station.said(*n, "ready")));
    assert_eq!(answered_by(station.mcp()), again);
    assert_eq!(station.station_json().unwrap()["pid"], station.pid());
    station.signal(libc::SIGTERM);
    assert!(station.wait().success());
}

#[test]
fn five_starts_in_a_row_that_fail_and_the_launcher_gives_up() {
    let mut station = Station::new("giveup");
    station.conf("start=crash\n");
    station.start("backoff=100");
    assert_eq!(station.wait().code(), Some(1));
    assert_eq!(station.started().len(), 5);
    assert!(station.station_json().is_none());
}

/// Kills the shell of with_parent's test when it panics (the launcher then sees its parent gone).
struct Shell(Child);

impl Drop for Shell {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

#[test]
fn with_parent_it_stops_once_the_parent_is_gone() {
    let mut station = Station::new("parent");
    // A shell starts the launcher in the background, says its pid, then waits (as sleep, the same process).
    let log = station.dir.join("launcher.log");
    let args = station.run_args().iter().map(|a| format!("'{a}'")).collect::<Vec<_>>().join(" ");
    let script = format!("\"$0\" {args} --with-parent >/dev/null 2>>'{}' & echo $!; exec sleep 600", log.display());
    let mut shell = spawn(
        Command::new("/bin/sh")
            .args(["-c", &script, launcher()])
            .env("STILLFAIL_NODE", node())
            .env("STILLFAIL_LAUNCHER_TIMES", "parent=200")
            .env_remove("STILLFAIL_DATA")
            .env_remove("EMBER_DATA")
            .env_remove("STILLFAIL_CONFIG")
            .env_remove("EMBER_CONFIG")
            .stdout(Stdio::piped()),
    );
    let mut line = String::new();
    BufReader::new(shell.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let (shell, launcher) = (Shell(shell), line.trim().parse::<i32>().unwrap());
    let said = station.until("station.json", |station| station.station_json());
    assert_eq!(said["pid"], launcher);
    let node = station.started()[0];
    drop(shell);
    ends(launcher);
    assert!(station.said(node, "got stop"));
    ends(node);
}
