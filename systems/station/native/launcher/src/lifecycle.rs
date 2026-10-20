//! The station's Node processes under the launcher, as one state machine for every platform: started, ready, crashed
//! and started again after a backoff that doubles (back to the first once a Node served `stable`), given up after
//! START_FAILURES starts in a row that never got ready, handed over to a new Node beside the old one (where the
//! platform can: Unix's SIGUSR2), drained, stopped (killed when it does not stop in time), stopped with the parent.
//!
//! run.rs (Unix) and run_windows.rs give it their processes (`Os`, `Process`) and tell it what happened (a line from a
//! Node, a Node's end, a stop, a handover asked for); they decide nothing of the lifecycle themselves, so a change to
//! restarts, timeouts or stopping is made here once and tested here once, on every platform.

use std::io::Result;
use std::path::PathBuf;
use std::time::{Duration, Instant};

use serde_json::Value;

use crate::data::{self, now_ms, write_whole};
use crate::log;

pub struct Options {
    pub data: PathBuf,
    pub app: PathBuf,
    pub port: u16,
    pub named: bool,
    pub with_parent: bool,
    /// What follows `--` on the command line: the station's own flags (the connector's), given to each Node.
    pub rest: Vec<String>,
}

impl Options {
    /// `--` and the station's own flags, to follow Node's: none when there are none.
    pub fn passed_on(&self) -> Vec<String> {
        if self.rest.is_empty() { Vec::new() } else { std::iter::once("--".to_string()).chain(self.rest.iter().cloned()).collect() }
    }
}

/// How long things may take. Tests shorten them (STILLFAIL_LAUNCHER_TIMES: `ready=ms,exit=ms,…`).
#[derive(Clone, Copy, Debug)]
pub struct Times {
    /// A new Node's wait to say ready on a handover, before the handover is given up.
    pub ready: Duration,
    /// The old Node's to exit once told to hand over; a stopped one's. Then it is killed.
    pub exit: Duration,
    pub stop: Duration,
    /// Restarts after an unexpected exit: `backoff` doubled each time, up to `backoff_max`; back to `backoff` after a
    /// Node that ran `stable` since it was ready.
    pub backoff: Duration,
    pub backoff_max: Duration,
    pub stable: Duration,
    /// --with-parent: how often the parent is looked for.
    pub parent: Duration,
    /// How long run/drained stays when nobody stops the station (the Rust station's DRAINED_LIMIT).
    pub drained: Duration,
    /// A Node's, once it serves (ready, or handed over to), to take over: serve every entrance (TAKEN_OVER). The old one
    /// exiting (`exit`) and Node waiting for it (agents.ts PREVIOUS_LIMIT_MS, 40 s) fit in it.
    pub take: Duration,
    /// After a handover whose new Node did not take over, the wait before a Node is started again: the installer's to
    /// put the release from before back (the old Node is gone by then; this way the next one runs on it).
    pub rollback: Duration,
}

/// What a Node serves once it has taken over the station: the agents' door (after the sessions are taken up) and the
/// loopback port. Until then it is not "up" for station.json (an installer's handover is not done).
const TAKEN_OVER: [&str; 2] = ["admin", "mcp"];

/// Starts in a row that end before Node says ready, after which the launcher gives up (the service starts it again).
pub const START_FAILURES: u32 = 5;

impl Times {
    pub fn of_env() -> Times {
        let s = Duration::from_secs;
        let mut times = Times { ready: s(60), exit: s(30), stop: s(30), backoff: s(1), backoff_max: s(60), stable: s(60), parent: s(2), drained: s(300), take: s(90), rollback: s(10) };
        for pair in std::env::var("STILLFAIL_LAUNCHER_TIMES").unwrap_or_default().split(',') {
            let Some((key, ms)) = pair.split_once('=') else { continue };
            let Ok(ms) = ms.trim().parse::<u64>() else { continue };
            let slot = match key.trim() {
                "ready" => &mut times.ready,
                "exit" => &mut times.exit,
                "stop" => &mut times.stop,
                "backoff" => &mut times.backoff,
                "backoff_max" => &mut times.backoff_max,
                "stable" => &mut times.stable,
                "parent" => &mut times.parent,
                "drained" => &mut times.drained,
                "take" => &mut times.take,
                "rollback" => &mut times.rollback,
                _ => continue,
            };
            *slot = Duration::from_millis(ms);
        }
        times
    }
}

/// One Node process as the platform has it: its pid, and the control channel the launcher tells it on.
pub trait Process {
    fn pid(&self) -> u32;
    /// `{"op":<op>}` on the control channel.
    fn tell(&self, op: &str);
}

/// What the launcher does to processes, and its clock: the system's, or a test's.
pub trait Os {
    type Node: Process;
    fn now(&self) -> Instant;
    /// A new Node.
    fn spawn(&mut self) -> Result<Self::Node>;
    /// Ends a Node whose end has not been seen yet.
    fn kill(&mut self, node: &mut Self::Node);
    /// --with-parent: whether the launcher's parent is gone.
    fn parent_gone(&mut self) -> bool;
    /// What `spawn` starts, for what is said when it does not.
    fn program(&self) -> String;
    /// Connections to the launcher's entrance `name` (mcp, admin) go to `port` from now on (the Node serving's, on
    /// 127.0.0.1); none: none serves, they wait. Where the launcher keeps entrances (Windows: proxy.rs); where Node
    /// listens on sockets handed down to it (Unix), they are its already, and nothing is to be done.
    fn route(&mut self, _name: &str, _port: Option<u16>) {}
}

/// A Node and what the launcher knows of it.
pub struct Node<P> {
    pub process: P,
    ready: Option<Instant>,
    version: String,
    /// The ports it said it serves on (`{"serving":<name>,"port":<n>}`): once it has taken over, as its own.
    served: Vec<(String, u16)>,
    /// Serving, not taken over yet: by when it must have.
    take_by: Option<Instant>,
    /// Taken over: station.json says its start.
    taken: bool,
    /// It came in by a handover (a failure to take over is the handover's).
    handed: bool,
    /// Being ended for not taking over.
    given_up: bool,
}

impl<P> Node<P> {
    fn serves_all(&self) -> bool {
        TAKEN_OVER.iter().all(|name| self.served.iter().any(|(n, _)| n == name))
    }
}

/// Which of the launcher's Nodes: the one serving, the one starting beside it (a handover), the one handing over.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Slot {
    Current,
    Next,
    Retiring,
}

pub struct Lifecycle<O: Os> {
    pub os: O,
    times: Times,
    run: PathBuf,
    current: Option<Node<O::Node>>,
    /// Starting for a handover: until when it may take to be ready, and whether it was given up (handoff-failed).
    next: Option<(Node<O::Node>, Instant, bool)>,
    /// Told to hand over: until when it may take to exit.
    retiring: Option<(Node<O::Node>, Instant)>,
    /// Stopping: until when the Nodes may take to exit.
    stopping: Option<Instant>,
    restart_at: Option<Instant>,
    failures: u32,
    backoff_step: u32,
    drained_at: Option<Instant>,
    /// No Node started before then (Times::rollback).
    restart_floor: Option<Instant>,
    /// --with-parent: when the parent is looked for next.
    parent_at: Option<Instant>,
    /// The launcher's exit once nothing runs.
    exit: i32,
}

impl<O: Os> Lifecycle<O> {
    pub fn new(os: O, times: Times, run: PathBuf, with_parent: bool) -> Lifecycle<O> {
        let parent_at = with_parent.then(|| os.now() + times.parent);
        Lifecycle {
            os,
            times,
            run,
            current: None,
            next: None,
            retiring: None,
            stopping: None,
            restart_at: None,
            failures: 0,
            backoff_step: 0,
            drained_at: None,
            restart_floor: None,
            parent_at,
            exit: 0,
        }
    }

    fn node(process: O::Node) -> Node<O::Node> {
        Node { process, ready: None, version: String::new(), served: vec![], take_by: None, taken: false, handed: false, given_up: false }
    }

    /// The Node serving has taken over once it serves every entrance and the one before it is gone: station.json says
    /// its start then (not at ready: an installer takes that for a handover done).
    fn check_taken(&mut self) {
        if self.retiring.is_some() || self.stopping.is_some() {
            return;
        }
        let Some(node) = self.current.as_mut() else { return };
        if node.taken || node.ready.is_none() || !node.serves_all() {
            return;
        }
        node.taken = true;
        node.take_by = None;
        log::info(&format!("Node {} has taken over", node.process.pid()));
        self.failures = 0;
        self.say_started();
    }

    /// The Node serving did not take over (`why`): ended, and started again as after a crash; after a handover, once
    /// the installer has had the time to put the release before back.
    fn take_failed(&mut self, why: &str) {
        let Some(node) = self.current.as_mut() else { return };
        node.take_by = None;
        node.given_up = true;
        let pid = node.process.pid();
        log::warn(&format!("Node {pid} did not take over: {why}; ending it"));
        if node.handed {
            self.handoff_failed(&format!("the new station did not take over: {why}"));
            self.restart_floor = Some(self.os.now() + self.times.rollback);
        }
        let Lifecycle { os, current, .. } = self;
        if let Some(node) = current.as_mut() {
            os.kill(&mut node.process);
        }
    }

    /// The serving Node changed (from one that served on `before`): each entrance goes to the one serving now, where it
    /// serves on it; elsewhere connections wait for it to.
    fn reroute(&mut self, before: &[(String, u16)]) {
        let now: Vec<(String, u16)> = self.current.as_ref().map(|n| n.served.clone()).unwrap_or_default();
        let mut names: Vec<&str> = before.iter().chain(&now).map(|(name, _)| name.as_str()).collect();
        names.sort();
        names.dedup();
        for name in names {
            let port = now.iter().find(|(n, _)| n == name).map(|(_, p)| *p);
            self.os.route(name, port);
        }
    }

    /// Starts the Node that serves (at first, after a crash).
    pub fn start(&mut self) {
        self.restart_at = None;
        match self.os.spawn() {
            Ok(process) => {
                log::info(&format!("Node started (pid {})", process.pid()));
                self.current = Some(Self::node(process));
            }
            Err(error) => {
                log::error(&format!("{} did not start: {error}", self.os.program()));
                self.failed_start();
            }
        }
    }

    /// A Node that ended before it was ready (or never started): again after the backoff, or, after START_FAILURES in
    /// a row, the launcher gives up.
    fn failed_start(&mut self) {
        self.failures += 1;
        if self.failures >= START_FAILURES {
            log::error(&format!("Node did not start {START_FAILURES} times in a row; giving up"));
            self.exit = 1;
            self.stop();
            return;
        }
        self.schedule_restart();
    }

    fn schedule_restart(&mut self) {
        let delay = self.times.backoff.saturating_mul(1 << self.backoff_step.min(16)).min(self.times.backoff_max);
        self.backoff_step += 1;
        let now = self.os.now();
        let at = (now + delay).max(self.restart_floor.take().unwrap_or(now));
        log::info(&format!("starting Node again in {} ms", at.saturating_duration_since(now).as_millis()));
        self.restart_at = Some(at);
    }

    /// station.json says this Node's start: the installer takes a new startedAt with the same pid for "handed over".
    fn say_started(&mut self) {
        let Some(node) = &self.current else { return };
        let text = data::station_json(std::process::id(), now_ms(), &node.version);
        if let Err(error) = write_whole(&self.run.join("station.json"), &text) {
            log::warn(&format!("station.json not written: {error}"));
        }
        let _ = std::fs::remove_file(self.run.join("drained"));
        self.drained_at = None;
    }

    fn handoff_failed(&self, why: &str) {
        log::warn(&format!("not handed over; going on as before: {why}"));
        let _ = write_whole(&self.run.join("handoff-failed"), &format!("{why}\n"));
    }

    fn node_mut(&mut self, slot: Slot) -> Option<&mut Node<O::Node>> {
        match slot {
            Slot::Current => self.current.as_mut(),
            Slot::Next => self.next.as_mut().map(|n| &mut n.0),
            Slot::Retiring => self.retiring.as_mut().map(|n| &mut n.0),
        }
    }

    /// The Nodes there are, for the platform to read their control channels (Unix polls them; Windows' threads read).
    #[cfg_attr(windows, allow(dead_code))]
    pub fn processes_mut(&mut self) -> Vec<(Slot, &mut O::Node)> {
        let mut out = vec![];
        if let Some(n) = self.current.as_mut() {
            out.push((Slot::Current, &mut n.process));
        }
        if let Some(n) = self.next.as_mut() {
            out.push((Slot::Next, &mut n.0.process));
        }
        if let Some(n) = self.retiring.as_mut() {
            out.push((Slot::Retiring, &mut n.0.process));
        }
        out
    }

    /// Which Node `pid` is.
    pub fn slot_of(&self, pid: u32) -> Option<Slot> {
        if self.current.as_ref().is_some_and(|n| n.process.pid() == pid) {
            Some(Slot::Current)
        } else if self.next.as_ref().is_some_and(|n| n.0.process.pid() == pid) {
            Some(Slot::Next)
        } else if self.retiring.as_ref().is_some_and(|n| n.0.process.pid() == pid) {
            Some(Slot::Retiring)
        } else {
            None
        }
    }

    /// A line from the Node in `slot`.
    pub fn said(&mut self, slot: Slot, message: Value) {
        if message["ready"] == true {
            if slot == Slot::Next && self.next.as_ref().is_some_and(|n| n.2) {
                return;
            }
            let now = self.os.now();
            let take = self.times.take;
            let Some(node) = self.node_mut(slot) else { return };
            if node.ready.is_some() {
                return;
            }
            node.ready = Some(now);
            node.version = message["version"].as_str().unwrap_or_default().to_string();
            log::info(&format!("Node {} ready (version {})", node.process.pid(), node.version));
            match slot {
                Slot::Current => {
                    // Up; started fine once it has taken over (the backoff goes back only once it has served
                    // `stable`: crashed()).
                    node.take_by = Some(now + take);
                    self.check_taken();
                }
                Slot::Next => self.hand_over(),
                Slot::Retiring => {}
            }
        } else if let (Some(name), Some(port)) = (message["serving"].as_str(), message["port"].as_u64().and_then(|p| u16::try_from(p).ok())) {
            // Taken over and serving on `port`: the entrance goes there if it is the Node serving (else once it is).
            let Some(node) = self.node_mut(slot) else { return };
            node.served.retain(|(n, _)| n != name);
            node.served.push((name.to_string(), port));
            log::info(&format!("Node {} serves {name} on port {port}", node.process.pid()));
            if slot == Slot::Current {
                self.os.route(name, Some(port));
                self.check_taken();
            }
        } else if let Some(why) = message["failed"].as_str() {
            // It could not take over (Node: the agents' side did not start).
            // Before or after ready; not one being ended already.
            if slot == Slot::Current && self.current.as_ref().is_some_and(|n| !n.taken && !n.given_up) {
                self.take_failed(why);
            } else {
                log::warn(&format!("Node failed: {why}"));
            }
        } else if let Some(said) = message["drained"].as_str().filter(|_| slot == Slot::Current) {
            log::info(&format!("drained ({said})"));
            let _ = write_whole(&self.run.join("drained"), &format!("{said}\n"));
            self.drained_at = Some(self.os.now());
        } else {
            log::warn(&format!("Node said what the launcher does not know: {message}"));
        }
    }

    /// The new Node is ready: it serves, and the old one is told to hand over and go.
    fn hand_over(&mut self) {
        let Some((mut next, _, _)) = self.next.take() else { return };
        self.restart_at = None;
        next.handed = true;
        next.take_by = Some(self.os.now() + self.times.take);
        let old = self.current.replace(next);
        // The entrances leave the old one: they go to the new one where it serves already, else wait until it does
        // (it takes over once the old one has handed its sessions over).
        self.reroute(&old.as_ref().map(|n| n.served.clone()).unwrap_or_default());
        match old {
            Some(old) => {
                log::info(&format!("handing over from Node {} to Node {}", old.process.pid(), self.current.as_ref().map_or(0, |n| n.process.pid())));
                old.process.tell("handover");
                self.retiring = Some((old, self.os.now() + self.times.exit));
            }
            // The old one had crashed meanwhile: nothing to wait for.
            None => self.check_taken(),
        }
    }

    /// `op` (drain, hup) to the Node serving.
    pub fn ask(&mut self, op: &str) {
        match &self.current {
            Some(node) if self.stopping.is_none() => node.process.tell(op),
            _ => log::warn(&format!("asked to {op} with no Node serving; not now")),
        }
    }

    /// A handover: a new Node beside the one serving (the release at --app may be new), the one serving told to hand
    /// over once the new one is ready.
    pub fn start_next(&mut self) {
        if self.stopping.is_some() {
            return;
        }
        if self.next.is_some() || self.retiring.is_some() {
            log::warn("asked to hand over while a handover is under way; not again");
            return;
        }
        match self.os.spawn() {
            Ok(process) => {
                log::info(&format!("handover: Node {} started beside the one serving", process.pid()));
                self.next = Some((Self::node(process), self.os.now() + self.times.ready, false));
            }
            Err(error) => self.handoff_failed(&format!("{} did not start: {error}", self.os.program())),
        }
    }

    /// Asks every Node to stop; the launcher exits once none runs.
    pub fn stop(&mut self) {
        if self.stopping.is_some() {
            return;
        }
        self.restart_at = None;
        self.stopping = Some(self.os.now() + self.times.stop);
        if let Some(node) = &self.current {
            node.process.tell("stop");
        }
        if let Some((node, ..)) = &self.next {
            node.process.tell("stop");
        }
        // The one retiring is ending already (within its own limit).
    }

    /// Node `pid` ended (`how`: "exited with 1", "was ended by signal 9").
    pub fn ended(&mut self, pid: u32, how: &str) {
        match self.slot_of(pid) {
            Some(Slot::Current) => {
                let node = self.current.take().unwrap();
                // None serves now: connections wait for the next one (a restart, the one starting beside).
                self.reroute(&node.served);
                log::info(&format!("Node {pid} {how}"));
                if self.stopping.is_none() {
                    self.crashed(node);
                }
            }
            Some(Slot::Next) => {
                let (node, _, given_up) = self.next.take().unwrap();
                log::info(&format!("Node {pid} (starting beside) {how}"));
                if !given_up && self.stopping.is_none() {
                    self.handoff_failed(&format!("the new station {how} before it was ready"));
                }
                drop(node);
                if self.current.is_none() && self.stopping.is_none() && self.restart_at.is_none() {
                    self.schedule_restart();
                }
            }
            Some(Slot::Retiring) => {
                self.retiring = None;
                log::info(&format!("Node {pid} handed over and {how}"));
                self.check_taken();
            }
            None => {}
        }
    }

    /// The serving Node ended without being asked: started again after the backoff.
    fn crashed(&mut self, node: Node<O::Node>) {
        log::warn(&format!("Node {} ended unexpectedly", node.process.pid()));
        // A handover under way brings the next one up.
        if self.next.is_some() {
            return;
        }
        // One that never took over did not start (counted towards giving up), ready or not.
        match node.ready.filter(|_| node.taken) {
            Some(at) => {
                self.failures = 0;
                if self.os.now().saturating_duration_since(at) >= self.times.stable {
                    self.backoff_step = 0;
                }
                self.schedule_restart();
            }
            None => self.failed_start(),
        }
    }

    /// What is due by now: a handover given up, a Node killed, a restart, the parent gone.
    pub fn tick(&mut self) {
        let now = self.os.now();
        if let Some((node, by, given_up)) = &mut self.next
            && !*given_up
            && now >= *by
        {
            *given_up = true;
            let pid = node.process.pid();
            self.os.kill(&mut node.process);
            let why = format!("the new station (pid {pid}) was not ready within {} s", self.times.ready.as_secs_f32());
            self.handoff_failed(&why);
        }
        if self.stopping.is_none()
            && let Some(by) = self.current.as_ref().and_then(|n| n.take_by)
            && now >= by
        {
            self.take_failed(&format!("not within {} s", self.times.take.as_secs_f32()));
        }
        if let Some((node, by)) = &mut self.retiring
            && now >= *by
        {
            log::warn(&format!("Node {} did not exit within {} s of handing over; killed", node.process.pid(), self.times.exit.as_secs_f32()));
            *by = now + Duration::from_secs(3600);
            self.os.kill(&mut node.process);
        }
        if let Some(by) = self.stopping
            && now >= by
        {
            let stop = self.times.stop.as_secs_f32();
            let Lifecycle { os, current, next, retiring, .. } = self;
            for node in [current.as_mut(), next.as_mut().map(|n| &mut n.0), retiring.as_mut().map(|n| &mut n.0)].into_iter().flatten() {
                log::warn(&format!("Node {} did not stop within {stop} s; killed", node.process.pid()));
                os.kill(&mut node.process);
            }
            self.stopping = Some(now + Duration::from_secs(3600));
        }
        if self.restart_at.is_some_and(|at| now >= at) && self.stopping.is_none() {
            self.start();
        }
        if let Some(at) = self.drained_at
            && now >= at + self.times.drained
        {
            log::warn("drained but not stopped; run/drained taken back");
            let _ = std::fs::remove_file(self.run.join("drained"));
            self.drained_at = None;
        }
        if let Some(at) = self.parent_at
            && now >= at
        {
            self.parent_at = Some(now + self.times.parent);
            if self.os.parent_gone() {
                log::info("parent ended; stopping");
                self.parent_at = None;
                self.stop();
            }
        }
    }

    /// When something is due next (what tick does).
    pub fn next_due(&self) -> Option<Instant> {
        [
            self.next.as_ref().filter(|n| !n.2).map(|n| n.1),
            self.retiring.as_ref().map(|n| n.1),
            self.current.as_ref().and_then(|n| n.take_by).filter(|_| self.stopping.is_none()),
            self.stopping,
            self.restart_at,
            self.drained_at.map(|at| at + self.times.drained),
            self.parent_at,
        ]
        .into_iter()
        .flatten()
        .min()
    }

    pub fn running(&self) -> bool {
        self.current.is_some() || self.next.is_some() || self.retiring.is_some()
    }

    /// The launcher's exit, once it has stopped and nothing runs.
    pub fn finished(&self) -> Option<i32> {
        (self.stopping.is_some() && !self.running()).then_some(self.exit)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;
    use std::rc::Rc;

    use serde_json::json;

    /// A test's Node: a pid (from 101 on) and what it was told.
    struct FakeNode {
        pid: u32,
        told: Rc<RefCell<Vec<String>>>,
    }

    impl Process for FakeNode {
        fn pid(&self) -> u32 {
            self.pid
        }
        fn tell(&self, op: &str) {
            self.told.borrow_mut().push(op.to_string());
        }
    }

    /// The test's processes and clock.
    struct Fake {
        dir: PathBuf,
        now: Instant,
        pid: u32,
        told: Vec<(u32, Rc<RefCell<Vec<String>>>)>,
        killed: Vec<u32>,
        parent_gone: bool,
        /// Where the entrances were told to go, in turn.
        routes: Vec<(String, Option<u16>)>,
    }

    impl Os for Fake {
        fn route(&mut self, name: &str, port: Option<u16>) {
            self.routes.push((name.to_string(), port));
        }
        type Node = FakeNode;
        fn now(&self) -> Instant {
            self.now
        }
        fn spawn(&mut self) -> Result<FakeNode> {
            self.pid += 1;
            let told = Rc::new(RefCell::new(vec![]));
            self.told.push((self.pid, told.clone()));
            Ok(FakeNode { pid: self.pid, told })
        }
        fn kill(&mut self, node: &mut FakeNode) {
            self.killed.push(node.pid);
        }
        fn parent_gone(&mut self) -> bool {
            self.parent_gone
        }
        fn program(&self) -> String {
            "node".into()
        }
    }

    impl Drop for Fake {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    const MS: Duration = Duration::from_millis(1);
    const EXITED_1: &str = "exited with 1";
    const EXITED_0: &str = "exited with 0";
    const KILLED: &str = "was ended by signal 9";

    fn s(secs: u64) -> Duration {
        Duration::from_secs(secs)
    }

    /// A launcher with its first Node started.
    fn station(name: &str, with_parent: bool) -> Lifecycle<Fake> {
        let data = std::env::temp_dir().join(format!("launcher-lifecycle-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&data);
        let run = data.join("run");
        std::fs::create_dir_all(&run).unwrap();
        let fake = Fake { dir: data, now: Instant::now(), pid: 100, told: vec![], killed: vec![], parent_gone: false, routes: vec![] };
        let times = Times { ready: s(60), exit: s(30), stop: s(30), backoff: s(1), backoff_max: s(4), stable: s(60), parent: s(2), drained: s(300), take: s(90), rollback: s(10) };
        let mut station = Lifecycle::new(fake, times, run, with_parent);
        station.start();
        station
    }

    fn ready(version: &str) -> Value {
        json!({"ready": true, "version": version})
    }

    impl Lifecycle<Fake> {
        /// The clock moved on by `by`, and what is due by then done.
        fn pass(&mut self, by: Duration) {
            self.os.now += by;
            self.tick();
        }

        /// The Node in `slot` ready and serving both entrances (mcp on `base` + 1, admin on `base` + 2).
        fn up(&mut self, slot: Slot, version: &str, base: u16) {
            self.said(slot, ready(version));
            self.serves(slot, base);
        }

        fn serves(&mut self, slot: Slot, base: u16) {
            self.said(slot, json!({"serving": "admin", "port": base + 2}));
            self.said(slot, json!({"serving": "mcp", "port": base + 1}));
        }

        /// The Node started last.
        fn last(&self) -> u32 {
            self.os.pid
        }

        fn serving(&self) -> u32 {
            self.current.as_ref().unwrap().process.pid
        }

        /// The ops told to Node `pid` since last asked.
        fn told(&mut self, pid: u32) -> Vec<String> {
            let (_, told) = self.os.told.iter().find(|(p, _)| *p == pid).unwrap();
            std::mem::take(&mut *told.borrow_mut())
        }

        fn file(&self, name: &str) -> Option<String> {
            std::fs::read_to_string(self.run.join(name)).ok()
        }

        fn station_json(&self) -> Value {
            serde_json::from_str(&self.file("station.json").unwrap()).unwrap()
        }
    }

    #[test]
    fn a_handover_lets_the_old_node_go_once_the_new_one_is_ready() {
        let mut station = station("handover", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        assert_eq!(station.station_json()["version"], "0.1.0");
        assert_eq!(station.station_json()["pid"], std::process::id());
        station.start_next();
        let new = station.last();
        assert_ne!(new, old);
        // Asked again meanwhile: not a second one.
        station.start_next();
        assert_eq!(station.last(), new);
        assert!(station.told(old).is_empty(), "the old one serves until the new one is ready");
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(station.told(old), ["handover"]);
        assert_eq!(station.serving(), new);
        // The old one not gone within its time: killed. station.json says the new start once it is gone.
        station.pass(s(30) - MS);
        assert!(station.os.killed.is_empty());
        assert_eq!(station.station_json()["version"], "0.1.0");
        station.pass(MS);
        assert_eq!(station.os.killed, [old]);
        station.ended(old, KILLED);
        // Gone; the new one is ready, not yet serving: not handed over yet (an installer reads station.json for it).
        assert_eq!(station.station_json()["version"], "0.1.0");
        station.said(Slot::Current, serving("admin", 6002));
        assert_eq!(station.station_json()["version"], "0.1.0", "the agents' door not open yet");
        station.said(Slot::Current, serving("mcp", 6001));
        assert_eq!(station.station_json()["version"], "0.2.0");
        assert_eq!(station.station_json()["pid"], std::process::id());
        assert!(station.file("handoff-failed").is_none());
        assert!(station.told(new).is_empty() && station.stopping.is_none());
        // Taken over: no deadline is left.
        station.pass(s(3600));
        assert_eq!(station.os.killed, [old]);
        assert_eq!(station.serving(), new);
    }

    #[test]
    fn a_new_node_that_does_not_take_over_is_ended_and_one_started_again_after_the_rollback_wait() {
        let mut station = station("nottaken", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        let first = station.file("station.json");
        station.start_next();
        let new = station.last();
        // Ready, the old one hands over and goes, the new one says its loopback port; its agents' side never comes up.
        station.said(Slot::Next, ready("0.2.0"));
        station.said(Slot::Current, serving("admin", 6002));
        station.ended(old, EXITED_0);
        station.pass(s(90) - MS);
        assert!(station.os.killed.is_empty() && station.file("handoff-failed").is_none());
        assert_eq!(station.file("station.json"), first, "not said handed over");
        station.pass(MS);
        assert_eq!(station.os.killed, [new]);
        assert!(station.file("handoff-failed").unwrap().contains("did not take over"));
        station.ended(new, KILLED);
        // Started again (on whatever release is at --app then), not before the installer could put the old one back.
        station.pass(s(10) - MS);
        assert_eq!(station.last(), new);
        station.pass(MS);
        let again = station.last();
        assert_ne!(again, new);
        station.up(Slot::Current, "0.1.0", 7000);
        assert_ne!(station.file("station.json"), first);
        assert_eq!(station.serving(), again);
    }

    #[test]
    fn a_new_node_that_says_it_failed_to_take_over_is_ended_at_once() {
        let mut station = station("failedtake", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        let new = station.last();
        station.said(Slot::Next, ready("0.2.0"));
        station.ended(old, EXITED_0);
        station.said(Slot::Current, json!({"failed": "the agents' side did not start: boom"}));
        assert_eq!(station.os.killed, [new]);
        assert!(station.file("handoff-failed").unwrap().contains("boom"));
        // Said once more as it goes: nothing more.
        station.said(Slot::Current, json!({"failed": "again"}));
        assert_eq!(station.os.killed, [new]);
    }

    #[test]
    fn a_node_that_never_takes_over_after_a_plain_start_is_started_again_and_counts_towards_giving_up() {
        let mut station = station("nottaken-start", false);
        for start in 1..=5 {
            let node = station.last();
            station.said(Slot::Current, ready("0.1.0"));
            station.pass(s(90));
            assert_eq!(station.os.killed.last(), Some(&node));
            station.ended(node, KILLED);
            if start < 5 {
                station.pass(s(4));
            }
        }
        assert!(station.file("handoff-failed").is_none(), "no handover's");
        assert_eq!(station.finished(), Some(1));
    }

    #[test]
    fn a_new_node_never_ready_is_given_up_and_the_old_one_serves_on() {
        let mut station = station("handfail", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        let first = station.file("station.json");
        station.start_next();
        let new = station.last();
        station.pass(s(60) - MS);
        assert!(station.os.killed.is_empty() && station.file("handoff-failed").is_none());
        station.pass(MS);
        assert_eq!(station.os.killed, [new]);
        assert!(station.file("handoff-failed").unwrap().contains("not ready"));
        // Ready too late: not taken.
        station.said(Slot::Next, ready("0.2.0"));
        station.ended(new, KILLED);
        assert_eq!(station.serving(), old);
        assert!(station.told(old).is_empty());
        assert_eq!(station.file("station.json"), first);
        assert!(station.restart_at.is_none());
        // A later handover works.
        station.start_next();
        let again = station.last();
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(station.told(old), ["handover"]);
        station.ended(old, EXITED_0);
        assert_eq!(station.serving(), again);
        station.serves(Slot::Current, 6000);
        assert_eq!(station.station_json()["version"], "0.2.0");
    }

    #[test]
    fn a_new_node_that_ends_before_it_is_ready_fails_the_handover() {
        let mut station = station("handend", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        station.ended(station.last(), EXITED_1);
        assert!(station.file("handoff-failed").unwrap().contains("exited with 1 before it was ready"));
        assert_eq!(station.serving(), old);
        assert!(station.told(old).is_empty() && station.os.killed.is_empty());
    }

    #[test]
    fn a_stop_during_a_handover_stops_both_and_kills_what_does_not_stop_in_time() {
        let mut station = station("stopboth", false);
        let old = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.start_next();
        let new = station.last();
        station.stop();
        assert_eq!(station.told(old), ["stop"]);
        assert_eq!(station.told(new), ["stop"]);
        station.pass(s(30) - MS);
        assert!(station.os.killed.is_empty());
        station.ended(old, EXITED_0);
        station.pass(MS);
        assert_eq!(station.os.killed, [new]);
        station.ended(new, KILLED);
        assert_eq!(station.finished(), Some(0));
        // Nothing is started again.
        station.pass(s(3600));
        assert_eq!(station.last(), new);
    }

    #[test]
    fn a_crashed_node_is_started_again_after_a_backoff_that_doubles() {
        let mut station = station("crash", false);
        // Each one crashing as soon as it is ready: again after 1, 2, 4, then 4 s (backoff_max). Being ready does not
        // take the backoff back to the first: only serving `stable` does.
        for expected in [1000, 2000, 4000, 4000] {
            let node = station.last();
            station.up(Slot::Current, "0.1.0", 5000);
            station.ended(node, EXITED_1);
            station.pass(Duration::from_millis(expected) - MS);
            assert_eq!(station.last(), node, "not again before {expected} ms");
            station.pass(MS);
            assert_ne!(station.last(), node, "again after {expected} ms");
        }
        // One that served for `stable` before it crashed: back to the first backoff.
        let node = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.pass(s(60));
        station.ended(node, EXITED_1);
        station.pass(s(1) - MS);
        assert_eq!(station.last(), node);
        station.pass(MS);
        assert_ne!(station.last(), node);
        assert!(station.stopping.is_none());
    }

    #[test]
    fn five_starts_in_a_row_that_end_before_ready_and_it_gives_up() {
        let mut station = station("giveup", false);
        for start in 1..=5 {
            station.ended(station.last(), EXITED_1);
            if start < 5 {
                station.pass(s(4));
            }
        }
        assert_eq!(station.os.told.len(), 5);
        assert_eq!(station.finished(), Some(1));
        station.pass(s(3600));
        assert_eq!(station.os.told.len(), 5);
    }

    #[test]
    fn with_parent_it_stops_once_the_parent_is_gone() {
        let mut station = station("parent", true);
        let node = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        for _ in 0..30 {
            station.pass(s(2));
        }
        assert!(station.stopping.is_none() && station.told(node).is_empty(), "still there while the parent is");
        // Gone: seen at the next look.
        station.os.parent_gone = true;
        station.pass(s(2) - MS);
        assert!(station.stopping.is_none());
        station.pass(MS);
        assert!(station.stopping.is_some());
        assert_eq!(station.told(node), ["stop"]);
        station.ended(node, EXITED_0);
        assert_eq!(station.finished(), Some(0));
    }

    fn serving(name: &str, port: u16) -> Value {
        json!({"serving": name, "port": port})
    }

    fn routes(station: &mut Lifecycle<Fake>) -> Vec<(String, Option<u16>)> {
        std::mem::take(&mut station.os.routes)
    }

    fn to(name: &str, port: Option<u16>) -> (String, Option<u16>) {
        (name.to_string(), port)
    }

    #[test]
    fn the_entrances_go_to_a_node_only_once_it_has_taken_over() {
        let mut station = station("entrances", false);
        station.said(Slot::Current, serving("admin", 5002));
        station.said(Slot::Current, ready("0.1.0"));
        station.said(Slot::Current, serving("mcp", 5001));
        assert_eq!(routes(&mut station), [to("admin", Some(5002)), to("mcp", Some(5001))]);
        // A handover: the new one says where it listens before it has taken over (its loopback port is up at once).
        station.start_next();
        let new = station.last();
        station.said(Slot::Next, serving("admin", 6002));
        assert!(routes(&mut station).is_empty(), "not the one serving yet");
        // Ready: it serves, the old one hands over; the agents' door is the new one's once it has taken the sessions
        // up, so until then connections to it wait (none goes to a Node that has not taken over).
        station.said(Slot::Next, ready("0.2.0"));
        assert_eq!(routes(&mut station), [to("admin", Some(6002)), to("mcp", None)]);
        station.said(Slot::Retiring, serving("mcp", 5001));
        assert!(routes(&mut station).is_empty(), "the one handing over is not served to again");
        station.said(Slot::Current, serving("mcp", 6001));
        assert_eq!(routes(&mut station), [to("mcp", Some(6001))]);
        // It crashes: connections wait for the one started again, which serves where it says.
        station.ended(new, EXITED_1);
        assert_eq!(routes(&mut station), [to("admin", None), to("mcp", None)]);
        station.pass(s(1));
        station.said(Slot::Current, serving("mcp", 7001));
        assert_eq!(routes(&mut station), [to("mcp", Some(7001))]);
    }

    #[test]
    fn a_handover_given_up_leaves_the_entrances_with_the_old_node() {
        let mut station = station("entrances-kept", false);
        station.said(Slot::Current, ready("0.1.0"));
        station.said(Slot::Current, serving("mcp", 5001));
        routes(&mut station);
        station.start_next();
        station.said(Slot::Next, serving("mcp", 6001));
        station.pass(s(60));
        assert!(station.file("handoff-failed").is_some());
        assert!(routes(&mut station).is_empty(), "the old one serves on, its entrances its");
    }

    #[test]
    fn drain_and_hup_go_to_node_and_drained_is_taken_back_when_nobody_stops_it() {
        let mut station = station("drain", false);
        let node = station.last();
        station.up(Slot::Current, "0.1.0", 5000);
        station.ask("drain");
        station.ask("hup");
        assert_eq!(station.told(node), ["drain", "hup"]);
        station.said(Slot::Current, json!({"drained": "idle"}));
        assert_eq!(station.file("drained").as_deref(), Some("idle\n"));
        station.pass(s(300) - MS);
        assert!(station.file("drained").is_some());
        station.pass(MS);
        assert!(station.file("drained").is_none());
        assert!(station.stopping.is_none() && station.told(node).is_empty());
    }
}
