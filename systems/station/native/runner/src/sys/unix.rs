//! What the runner does through the system on macOS and Linux: a Unix socket, a session and a process group of the
//! agent's own, signals.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::Shutdown;
use std::os::unix::fs::{DirBuilderExt, FileExt, OpenOptionsExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicI32, Ordering};

use serde_json::{Value, json};

use super::Signal;

/// Where the parent of a forked runner waits to hear it is ready (see `leave_session`); -1 when there is none.
static READY_FD: AtomicI32 = AtomicI32::new(-1);

/// `<dir>/<id>.sock`.
pub fn socket_path(dir: &Path, id: &str) -> PathBuf {
    dir.join(format!("{id}.sock"))
}

/// Whether a runner listens on `sock` now. Nothing a runner left on disk says so: the record of one that was killed, or
/// of another boot of the machine (a restart, a disk restored from an archive), names a pid that is by now any
/// process's. Asking is only a connection that says nothing, which a runner leaves be (see `connection`).
pub fn answers(sock: &Path) -> bool {
    UnixStream::connect(sock).is_ok()
}

/// The socket is a file: it goes with the others.
pub fn remove_socket(sock: &Path) {
    let _ = fs::remove_file(sock);
}

/// Leaves the starter's session and process group, so that ending those (launchd ending the station, a terminal
/// closing) leaves the runner and its agent be. A group leader cannot setsid: it forks first, and the parent stays
/// only until the child is ready, then exits with what the child would have.
pub fn leave_session() {
    // SAFETY: plain syscalls; this runs before any thread is started, so fork is safe.
    unsafe {
        if libc::getsid(0) == libc::getpid() || libc::setsid() >= 0 {
            return;
        }
        let mut fds = [0; 2];
        if libc::pipe(fds.as_mut_ptr()) != 0 {
            eprintln!("stillfail-runner: pipe: {}", io::Error::last_os_error());
            std::process::exit(1);
        }
        // The agent must not hold either end, or the parent would wait on it.
        libc::fcntl(fds[0], libc::F_SETFD, libc::FD_CLOEXEC);
        libc::fcntl(fds[1], libc::F_SETFD, libc::FD_CLOEXEC);
        match libc::fork() {
            -1 => {
                eprintln!("stillfail-runner: fork: {}", io::Error::last_os_error());
                std::process::exit(1);
            }
            0 => {
                libc::close(fds[0]);
                libc::setsid();
                READY_FD.store(fds[1], Ordering::SeqCst);
            }
            child => {
                libc::close(fds[1]);
                let mut byte = 0u8;
                loop {
                    let n = libc::read(fds[0], (&raw mut byte).cast(), 1);
                    if n == 1 {
                        libc::_exit(0);
                    }
                    if n == 0 || io::Error::last_os_error().kind() != io::ErrorKind::Interrupted {
                        break;
                    }
                }
                // It failed before being ready: its status is ours.
                let mut status = 0;
                while libc::waitpid(child, &mut status, 0) < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {}
                libc::_exit(if libc::WIFEXITED(status) { libc::WEXITSTATUS(status) } else { 1 });
            }
        }
    }
}

/// Tells a forked runner's parent it is ready, so it exits and lets go of the starter.
pub fn ready() {
    let fd = READY_FD.swap(-1, Ordering::SeqCst);
    if fd >= 0 {
        // SAFETY: the pipe's write end, ours alone.
        unsafe {
            libc::write(fd, [1u8].as_ptr().cast(), 1);
            libc::close(fd);
        }
    }
}

pub fn create_dir(dir: &Path) -> io::Result<()> {
    fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)
}

/// Opened for writing, created 0600.
pub fn create_file(options: &mut OpenOptions) -> &mut OpenOptions {
    options.mode(0o600)
}

pub fn write_all_at(file: &File, buf: &[u8], at: u64) -> io::Result<()> {
    file.write_all_at(buf, at)
}

pub fn read_exact_at(file: &File, buf: &mut [u8], at: u64) -> io::Result<()> {
    file.read_exact_at(buf, at)
}


/// Lets go of the starter's stdio: stdout closes (it reads the ready line to its end), and nothing it holds is
/// written to or read from again.
pub fn detach_stdio() {
    // SAFETY: open and dup2 onto the standard descriptors, which nothing else holds on to.
    unsafe {
        let null = libc::open(c"/dev/null".as_ptr(), libc::O_RDWR);
        if null >= 0 {
            for fd in 0..3 {
                libc::dup2(null, fd);
            }
            if null > 2 {
                libc::close(null);
            }
        }
    }
}

pub struct Listener(UnixListener);

impl Listener {
    pub fn bind(sock: &Path) -> Result<Listener, String> {
        // The socket is made 0600 from the start; the umask is the process's, so it is put back right after.
        // SAFETY: umask has no failure; no other thread runs yet.
        let old = unsafe { libc::umask(0o177) };
        let bound = UnixListener::bind(sock);
        unsafe { libc::umask(old) };
        let listener = bound.map_err(|e| format!("cannot listen on {}: {e}", sock.display()))?;
        let _ = fs::set_permissions(sock, fs::Permissions::from_mode(0o600));
        Ok(Listener(listener))
    }

    pub fn accept(&self) -> io::Result<Conn> {
        self.0.accept().map(|(stream, _)| Conn(stream))
    }
}

pub struct Conn(UnixStream);

impl Conn {
    pub fn try_clone(&self) -> io::Result<Conn> {
        self.0.try_clone().map(Conn)
    }

    /// Ends it both ways: its reader sees the end, the station sees it closed.
    pub fn shutdown(&self) {
        let _ = self.0.shutdown(Shutdown::Both);
    }
}

impl Read for Conn {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.0.read(buf)
    }
}

impl Write for Conn {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.0.write(buf)
    }

    fn flush(&mut self) -> io::Result<()> {
        self.0.flush()
    }
}

/// The agent: its pid, which is also its process group.
pub struct Agent {
    pid: i32,
}

/// Starts the agent in a process group of its own.
pub fn spawn(program: &str, args: &[String], cwd: Option<&Path>) -> io::Result<(Child, Agent)> {
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).process_group(0);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let child = command.spawn()?;
    let pid = child.id() as i32;
    Ok((child, Agent { pid }))
}

impl Agent {
    pub fn pid(&self) -> i32 {
        self.pid
    }

    /// Ends the group just started, whose start did not go through.
    pub fn abandon(&self) {
        // SAFETY: the group was just started and is ours.
        unsafe { libc::kill(-self.pid, libc::SIGKILL) };
    }

    /// Waits for the agent to exit: `ended` is called once it has, before it is reaped (see `signal`). Its exit, as
    /// the runner says it.
    pub fn wait(&self, _child: Child, ended: impl FnOnce()) -> Value {
        let pid = self.pid;
        // It is seen ended before it is reaped, so a `signal` never reaches a pid that was reaped and reused.
        // SAFETY: waitid/waitpid on our own child, with somewhere to write.
        unsafe {
            let mut info: libc::siginfo_t = std::mem::zeroed();
            while libc::waitid(libc::P_PID, pid as libc::id_t, &mut info, libc::WEXITED | libc::WNOWAIT) < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {}
        }
        ended();
        let mut status = 0;
        unsafe { while libc::waitpid(pid, &mut status, 0) < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {} }
        if libc::WIFSIGNALED(status) {
            json!({"op": "exit", "code": null, "signal": signal_name(libc::WTERMSIG(status))})
        } else {
            json!({"op": "exit", "code": libc::WEXITSTATUS(status), "signal": null})
        }
    }

    /// Sends `signal` to the agent's group, or to it alone. Called with the runner's state locked, so the agent is not
    /// reaped meanwhile (see `wait`): `exiting` is whether it has ended.
    pub fn signal(&self, signal: Signal, group: bool, exiting: bool) -> Result<(), String> {
        let signal = match signal {
            Signal::Term => libc::SIGTERM,
            Signal::Kill => libc::SIGKILL,
            Signal::Int => libc::SIGINT,
        };
        let target = target(self.pid, group, exiting)?;
        // SAFETY: kill on the agent or its group.
        if unsafe { libc::kill(target, signal) } != 0 {
            return Err(format!("signal: {}", io::Error::last_os_error()));
        }
        Ok(())
    }
}

fn signal_name(signal: i32) -> String {
    let name = match signal {
        libc::SIGTERM => "TERM",
        libc::SIGKILL => "KILL",
        libc::SIGINT => "INT",
        libc::SIGHUP => "HUP",
        libc::SIGQUIT => "QUIT",
        libc::SIGABRT => "ABRT",
        libc::SIGSEGV => "SEGV",
        libc::SIGBUS => "BUS",
        libc::SIGILL => "ILL",
        libc::SIGFPE => "FPE",
        libc::SIGPIPE => "PIPE",
        libc::SIGALRM => "ALRM",
        libc::SIGUSR1 => "USR1",
        libc::SIGUSR2 => "USR2",
        other => return other.to_string(),
    };
    name.into()
}

/// Whom a `signal` goes to: the agent's group (which outlives the agent), else the agent alone while it runs.
fn target(pid: i32, group: bool, exiting: bool) -> Result<i32, String> {
    if group {
        Ok(-pid)
    } else if exiting {
        Err("signal: the agent has exited".into())
    } else {
        Ok(pid)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_signal_goes_to_the_agent_alone_unless_to_its_group() {
        assert_eq!(target(42, false, false), Ok(42));
        assert_eq!(target(42, true, false), Ok(-42));
        // Its group still: what it started may run on.
        assert_eq!(target(42, true, true), Ok(-42));
        assert_eq!(target(42, false, true), Err("signal: the agent has exited".into()));
    }
}
