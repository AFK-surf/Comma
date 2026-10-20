//! `run` on Unix: the station's Node process under a launcher whose pid, lock and ports stay. What happens to the Node
//! (ready, crashed and started again, handed over, stopped) is lifecycle.rs's, as on Windows; this is how Unix gives
//! it its processes and events.
//!
//! Node is started as `node <app>/station/main.js run --app <app> --data <data> --launcher-fds 3,4,5`: fd 3 is the MCP
//! endpoint's listening socket, fd 4 the loopback port's, fd 5 the control socket (both ways, one JSON object a line).
//! Node says `{"ready":true,"version":…}` once it serves, and `{"drained":"idle"|"timeout"}` after a drain; the launcher
//! says `{"op":"handover"|"stop"|"drain"|"hup"}`. Node runs in a process group of its own (a ^C at a terminal reaches
//! the launcher only, which stops it); it ends when the control socket closes (the launcher gone). The listening
//! sockets passing from Node to Node is what makes a handover (SIGUSR2) possible here.
//!
//! One thread: signals come in through a pipe (written by their handlers), and everything waits in one poll().

use std::ffi::c_int;
use std::fs::File;
use std::io::{Error, Result};
use std::os::fd::{AsRawFd, FromRawFd, IntoRawFd, OwnedFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};
use std::time::Instant;

use serde_json::Value;

use crate::data::{self, Config};
use crate::lifecycle::{Lifecycle, Os, Process, Times};
pub use crate::lifecycle::Options;
use crate::log;

/// One Node process and its end of the control socket.
struct Node {
    pid: i32,
    control: OwnedFd,
    /// What came in on the control socket after the last whole line; `open` until it closes.
    pending: Vec<u8>,
    open: bool,
}

impl Process for Node {
    fn pid(&self) -> u32 {
        self.pid as u32
    }

    fn tell(&self, op: &str) {
        let line = format!("{{\"op\":\"{op}\"}}\n");
        let mut rest = line.as_bytes();
        while !rest.is_empty() {
            // SAFETY: a write from a live buffer to a descriptor this Node owns.
            let n = unsafe { libc::write(self.control.as_raw_fd(), rest.as_ptr().cast(), rest.len()) };
            if n < 0 {
                let error = Error::last_os_error();
                if error.kind() == std::io::ErrorKind::Interrupted {
                    continue;
                }
                log::warn(&format!("could not tell Node {} {op}: {error}", self.pid));
                return;
            }
            rest = &rest[n as usize..];
        }
    }
}

impl Node {
    /// Whole lines come in on the control socket since the last read.
    fn read(&mut self) -> Vec<Value> {
        let mut buf = [0u8; 4096];
        loop {
            // SAFETY: a read into a live buffer from a descriptor this Node owns.
            let n = unsafe { libc::read(self.control.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
            match n {
                0 => {
                    self.open = false;
                    break;
                }
                n if n > 0 => self.pending.extend_from_slice(&buf[..n as usize]),
                _ => {
                    let error = Error::last_os_error();
                    match error.kind() {
                        std::io::ErrorKind::Interrupted => continue,
                        std::io::ErrorKind::WouldBlock => break,
                        _ => {
                            self.open = false;
                            break;
                        }
                    }
                }
            }
        }
        let mut said = vec![];
        while let Some(at) = self.pending.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.pending.drain(..=at).collect();
            match serde_json::from_slice::<Value>(&line) {
                Ok(value) => said.push(value),
                Err(error) => log::warn(&format!("Node {} said a line that does not read ({error}): {}", self.pid, String::from_utf8_lossy(&line).trim_end())),
            }
        }
        said
    }
}

/// Unix's processes: each Node given the listening sockets as fds 3 and 4, in a process group of its own.
struct System {
    options: Options,
    mcp: OwnedFd,
    admin: OwnedFd,
    /// The parent at the start (--with-parent): another one later (init, a subreaper) is its end.
    parent: i32,
}

impl Os for System {
    type Node = Node;

    fn now(&self) -> Instant {
        Instant::now()
    }

    fn spawn(&mut self) -> Result<Node> {
        let app = &self.options.app;
        let (ours, theirs) = socketpair()?;
        let mut command = Command::new(crate::node(app));
        command
            .arg(crate::main_js(app))
            .arg("run")
            .arg("--app")
            .arg(app)
            .arg("--data")
            .arg(&self.options.data)
            .args(["--launcher-fds", "3,4,5"])
            .args(self.options.passed_on())
            .stdin(Stdio::null())
            .process_group(0);
        let given = [self.mcp.as_raw_fd(), self.admin.as_raw_fd(), theirs.as_raw_fd()];
        // SAFETY: only dup2 (async-signal-safe) between fork and exec. The sources are all at 10 and up, so none is
        // overwritten before it is copied; the copies are not close-on-exec.
        unsafe {
            command.pre_exec(move || {
                for (to, from) in given.iter().enumerate() {
                    if libc::dup2(*from, 3 + to as c_int) < 0 {
                        return Err(Error::last_os_error());
                    }
                }
                Ok(())
            });
        }
        let child = command.spawn()?;
        drop(theirs);
        nonblocking(ours.as_raw_fd())?;
        let pid = child.id() as i32;
        // Reaped by waitpid in serve(), not by std.
        drop(child);
        Ok(Node { pid, control: ours, pending: vec![], open: true })
    }

    fn kill(&mut self, node: &mut Node) {
        // SAFETY: a signal to a child of this process not yet reaped.
        unsafe { libc::kill(node.pid, libc::SIGKILL) };
    }

    fn parent_gone(&mut self) -> bool {
        // SAFETY: getppid has no preconditions.
        unsafe { libc::getppid() != self.parent }
    }

    fn program(&self) -> String {
        crate::node(&self.options.app).display().to_string()
    }
}

/// The pipe signal handlers write to.
static SIGNALS: AtomicI32 = AtomicI32::new(-1);

extern "C" fn on_signal(signal: c_int) {
    // SAFETY: errno saved and restored around a write(2), both async-signal-safe.
    unsafe {
        let errno = errno();
        let byte = signal as u8;
        libc::write(SIGNALS.load(Ordering::Relaxed), (&byte as *const u8).cast(), 1);
        *errno_ptr() = errno;
    }
}

#[cfg(target_os = "macos")]
unsafe fn errno_ptr() -> *mut c_int {
    unsafe { libc::__error() }
}

#[cfg(not(target_os = "macos"))]
unsafe fn errno_ptr() -> *mut c_int {
    unsafe { libc::__errno_location() }
}

unsafe fn errno() -> c_int {
    unsafe { *errno_ptr() }
}

const HANDLED: [c_int; 6] = [libc::SIGTERM, libc::SIGINT, libc::SIGUSR1, libc::SIGUSR2, libc::SIGHUP, libc::SIGCHLD];

/// The pipe's read end, once each handled signal writes to it.
fn take_signals() -> Result<OwnedFd> {
    let (read, write) = pipe()?;
    for fd in [&read, &write] {
        nonblocking(fd.as_raw_fd())?;
    }
    SIGNALS.store(write.into_raw_fd(), Ordering::Relaxed);
    for signal in HANDLED {
        // SAFETY: a handler that only writes to the pipe; sigaction with a zeroed, then filled, struct.
        unsafe {
            let mut action: libc::sigaction = std::mem::zeroed();
            action.sa_sigaction = on_signal as extern "C" fn(c_int) as libc::sighandler_t;
            action.sa_flags = libc::SA_RESTART | if signal == libc::SIGCHLD { libc::SA_NOCLDSTOP } else { 0 };
            libc::sigemptyset(&mut action.sa_mask);
            if libc::sigaction(signal, &action, std::ptr::null_mut()) != 0 {
                return Err(Error::last_os_error());
            }
        }
    }
    Ok(read)
}

fn pipe() -> Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: pipe(2) fills two descriptors, then owned here.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(Error::last_os_error());
    }
    let (read, write) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    cloexec(read.as_raw_fd())?;
    cloexec(write.as_raw_fd())?;
    Ok((read, write))
}

fn socketpair() -> Result<(OwnedFd, OwnedFd)> {
    let mut fds = [0; 2];
    // SAFETY: socketpair(2) fills two descriptors, then owned here.
    if unsafe { libc::socketpair(libc::AF_UNIX, libc::SOCK_STREAM, 0, fds.as_mut_ptr()) } != 0 {
        return Err(Error::last_os_error());
    }
    let (ours, theirs) = unsafe { (OwnedFd::from_raw_fd(fds[0]), OwnedFd::from_raw_fd(fds[1])) };
    cloexec(ours.as_raw_fd())?;
    cloexec(theirs.as_raw_fd())?;
    Ok((ours, theirs))
}

fn cloexec(fd: RawFd) -> Result<()> {
    // SAFETY: fcntl on a descriptor the caller owns.
    if unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) } != 0 {
        return Err(Error::last_os_error());
    }
    Ok(())
}

fn nonblocking(fd: RawFd) -> Result<()> {
    // SAFETY: fcntl on a descriptor the caller owns.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        if flags < 0 || libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK) != 0 {
            return Err(Error::last_os_error());
        }
    }
    Ok(())
}

/// Fills descriptors 0 to 9 (with /dev/null) where nothing is open, so nothing the launcher opens later is at 3, 4 or
/// 5, where a Node gets its own: dup2 there in the child can then overwrite nothing it still needs (std's pipe for
/// spawn errors among them). 0 to 2 are left inheritable; the rest are close-on-exec.
fn keep_low_fds() {
    loop {
        let Ok(file) = File::open("/dev/null") else { return };
        let fd = file.into_raw_fd();
        if fd >= 10 {
            // SAFETY: the descriptor just opened, owned here.
            unsafe { libc::close(fd) };
            return;
        }
        if fd <= 2 {
            // SAFETY: as above; std opens files close-on-exec, which stdin/stdout/stderr must not be.
            unsafe { libc::fcntl(fd, libc::F_SETFD, 0) };
        }
    }
}

pub fn run(options: Options) -> i32 {
    keep_low_fds();
    let run = options.data.join("run");
    if let Err(error) = std::fs::create_dir_all(&run) {
        log::error(&format!("{}: {error}", run.display()));
        return 1;
    }
    let config = match Config::read(&options.data) {
        Ok(config) => config,
        Err(error) => {
            log::error(&format!("the config does not read: {error}"));
            return 1;
        }
    };
    // One station per data directory: a second would take the first one's ports and runtimes away.
    let _lock = match data::lock(&run.join("station.lock")) {
        Ok(Some(lock)) => lock,
        Ok(None) => {
            let dir = options.data.display();
            if config.english {
                eprintln!("Another still.fail station is running on this data directory ({dir}); only one station can run on a data directory on one machine");
            } else {
                eprintln!("另一个 still.fail station 正在运行这个数据目录（{dir}）；同一台机器上的一个数据目录只能运行一个 station");
            }
            return crate::HELD;
        }
        Err(error) => {
            log::error(&format!("{}: {error}", run.join("station.lock").display()));
            return 1;
        }
    };
    let _ = std::fs::remove_file(run.join("drained"));
    // Both at descriptors of 10 and up (keep_low_fds).
    let bound = crate::ports::mcp(&config).and_then(|mcp| Ok((mcp, crate::ports::admin(&options.data, options.port, options.named, config.english)?)));
    let (mcp, admin): (OwnedFd, OwnedFd) = match bound {
        Ok((mcp, admin)) => (mcp.into(), admin.into()),
        Err(error) => {
            log::error(&error);
            eprintln!("{error}");
            return 1;
        }
    };
    let signals = match take_signals() {
        Ok(fd) => fd,
        Err(error) => {
            log::error(&format!("signals not taken: {error}"));
            return 1;
        }
    };
    let with_parent = options.with_parent;
    // SAFETY: getppid has no preconditions.
    let parent = unsafe { libc::getppid() };
    let mut station = Lifecycle::new(System { options, mcp, admin, parent }, Times::of_env(), run, with_parent);
    station.start();
    serve(&mut station, signals)
}

/// Waits for what happens (a signal, a line from a Node, something due) and tells the lifecycle, until it is done.
fn serve(station: &mut Lifecycle<System>, signals: OwnedFd) -> i32 {
    loop {
        if let Some(exit) = station.finished() {
            log::info("stopped");
            return exit;
        }
        let mut fds = vec![libc::pollfd { fd: signals.as_raw_fd(), events: libc::POLLIN, revents: 0 }];
        let mut pids = vec![];
        for (_, node) in station.processes_mut() {
            if node.open {
                fds.push(libc::pollfd { fd: node.control.as_raw_fd(), events: libc::POLLIN, revents: 0 });
                pids.push(node.pid);
            }
        }
        let timeout = station.next_due().map_or(-1, |at| at.saturating_duration_since(Instant::now()).as_millis().min(i32::MAX as u128) as c_int + 1);
        // SAFETY: poll over a live array of pollfds.
        let n = unsafe { libc::poll(fds.as_mut_ptr(), fds.len() as libc::nfds_t, timeout) };
        if n < 0 && Error::last_os_error().kind() != std::io::ErrorKind::Interrupted {
            log::error(&format!("poll: {}", Error::last_os_error()));
            return 1;
        }
        if n > 0 {
            for (pid, fd) in pids.iter().zip(&fds[1..]) {
                if fd.revents == 0 {
                    continue;
                }
                let Some((slot, said)) = station.processes_mut().into_iter().find(|(_, node)| node.pid == *pid).map(|(slot, node)| (slot, node.read())) else {
                    continue;
                };
                for message in said {
                    station.said(slot, message);
                }
            }
            if fds[0].revents != 0 {
                for signal in drain_signals(&signals) {
                    match signal {
                        libc::SIGCHLD => reap(station),
                        libc::SIGTERM | libc::SIGINT => {
                            log::info("stopping");
                            station.stop();
                        }
                        libc::SIGUSR1 => station.ask("drain"),
                        libc::SIGHUP => station.ask("hup"),
                        libc::SIGUSR2 => station.start_next(),
                        _ => {}
                    }
                }
            }
        }
        station.tick();
    }
}

/// The Nodes that ended, told to the lifecycle.
fn reap(station: &mut Lifecycle<System>) {
    loop {
        let mut status = 0;
        // SAFETY: waitpid on this process's children, without blocking.
        let pid = unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) };
        if pid <= 0 {
            return;
        }
        station.ended(pid as u32, &describe(status));
    }
}

fn drain_signals(fd: &OwnedFd) -> Vec<c_int> {
    let mut buf = [0u8; 64];
    let mut got = vec![];
    loop {
        // SAFETY: a read into a live buffer from the signal pipe.
        let n = unsafe { libc::read(fd.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
        if n <= 0 {
            return got;
        }
        got.extend(buf[..n as usize].iter().map(|b| *b as c_int));
    }
}

/// How a process ended, as waitpid said.
fn describe(status: c_int) -> String {
    if libc::WIFEXITED(status) {
        format!("exited with {}", libc::WEXITSTATUS(status))
    } else if libc::WIFSIGNALED(status) {
        format!("was ended by signal {}", libc::WTERMSIG(status))
    } else {
        format!("ended ({status})")
    }
}
