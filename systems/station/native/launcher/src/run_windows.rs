//! `run` on Windows: the station's Node process under a launcher whose pid and lock stay. What happens to the Node
//! (ready, crashed and started again, stopped) is lifecycle.rs's, as on Unix; this is how Windows gives it its
//! processes and events, less what Windows cannot do the same way:
//!
//! - Node binds its ports itself (Node cannot listen on a socket handed down on Windows), so a new Node is not started
//!   beside the old one: there is no handover (nothing here asks the lifecycle for one), and a restart leaves the ports
//!   for a moment.
//! - The control channel is a named pipe only this user may open, `\\.\pipe\stillfail-launcher-<pid>-<n>`, given as
//!   `--launcher-pipe`; on it the same lines go both ways as on Unix's socket.
//! - There are no signals: a ^C (or the console closing) stops the station, as SIGTERM does on Unix. Node runs in a
//!   process group of its own, so the ^C reaches the launcher only.
//!
//! Threads say what happened (Node's exit, a line from it, a ^C) on one channel; the main thread tells the lifecycle.

use std::ffi::OsStr;
use std::io;
use std::os::windows::ffi::OsStrExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle, RawHandle};
use std::os::windows::process::CommandExt;
use std::process::{Child, Command, Stdio};
use std::ptr::{null, null_mut};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use serde_json::Value;
use windows_sys::Win32::Foundation::{CloseHandle, ERROR_IO_PENDING, ERROR_PIPE_CONNECTED, GetLastError, HANDLE, INVALID_HANDLE_VALUE, LocalFree, WAIT_TIMEOUT};
use windows_sys::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use windows_sys::Win32::Security::{GetTokenInformation, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, PIPE_ACCESS_DUPLEX, ReadFile, WriteFile};
use windows_sys::Win32::System::Console::SetConsoleCtrlHandler;
use windows_sys::Win32::System::IO::{CancelIoEx, GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Pipes::{ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_WAIT};
use windows_sys::Win32::System::Threading::{
    CREATE_NEW_PROCESS_GROUP, CreateEventW, GetCurrentProcess, GetExitCodeProcess, OpenProcess, OpenProcessToken, PROCESS_QUERY_LIMITED_INFORMATION,
    PROCESS_SYNCHRONIZE, WaitForSingleObject,
};

use crate::data::{self, Config};
use crate::lifecycle::{Lifecycle, Os, Process, Times};
use crate::proxy::Entrance;
pub use crate::lifecycle::Options;
use crate::log;

enum Event {
    /// Node `pid` exited, with this code.
    Exited(u32, Option<i32>),
    /// Node `pid` said this.
    Said(u32, Value),
    Stop(&'static str),
    /// Asked on the launcher's own pipe (control_pipe): handover, drain, hup, stop (Unix's SIGUSR2, SIGUSR1, SIGHUP,
    /// SIGTERM).
    Ask(String),
}

/// How long a connection to an entrance waits for a Node to serve it (a handover's moment, a restart) before it is
/// closed.
const ENTRANCE_WAIT: Duration = Duration::from_secs(60);

/// The launcher's own pipe, by its pid (run/station.json's): what the installer and the CLI ask it on, one
/// `{"op":…}` a line. Only this user may open it.
pub fn control_pipe(pid: u32) -> String {
    format!(r"\\.\pipe\stillfail-launcher-{pid}")
}

static EVENTS: OnceLock<Mutex<Sender<Event>>> = OnceLock::new();

/// ^C, ^Break, the console closing, the user logging off: the station stops.
unsafe extern "system" fn on_ctrl(_kind: u32) -> i32 {
    if let Some(events) = EVENTS.get() {
        let _ = events.lock().unwrap_or_else(|e| e.into_inner()).send(Event::Stop("a console event"));
    }
    1
}

struct Node {
    child: Child,
    pipe: Pipe,
}

impl Process for Node {
    fn pid(&self) -> u32 {
        self.child.id()
    }

    fn tell(&self, op: &str) {
        let line = format!("{{\"op\":\"{op}\"}}\n");
        if let Err(error) = self.pipe.write_all(line.as_bytes()) {
            log::warn(&format!("Node {} not told {op}: {error}", self.child.id()));
        }
    }
}

/// Windows' processes: each Node with a pipe of its own, its lines and its exit told on the channel by threads.
struct System {
    options: Options,
    security: Arc<Security>,
    tx: Sender<Event>,
    next: u64,
    /// --with-parent: the parent at the start, to wait on.
    parent: Option<OwnedHandle>,
    /// The ports the launcher holds (the agents' MCP endpoint's, the loopback port's), as Node is told them, and their
    /// entrances: each carried to the Node serving it (proxy.rs).
    ports: (u16, u16),
    mcp: Entrance,
    admin: Entrance,
}

impl Os for System {
    type Node = Node;

    fn now(&self) -> Instant {
        Instant::now()
    }

    fn spawn(&mut self) -> io::Result<Node> {
        self.next += 1;
        let name = format!(r"\\.\pipe\stillfail-launcher-{}-{}", std::process::id(), self.next);
        let pipe = Pipe::create(&name, &self.security).map_err(|error| io::Error::new(error.kind(), format!("{name}: {error}")))?;
        let app = &self.options.app;
        let mut command = Command::new(crate::node(app));
        // Node listens where it may (127.0.0.1, any port) and says where once it serves; the launcher's ports, which
        // agents and the CLI are told, it is given to say as its own.
        let ports = format!("{},{}", self.ports.0, self.ports.1);
        command.arg(crate::main_js(app)).arg("run").arg("--app").arg(app).arg("--data").arg(&self.options.data).arg("--launcher-pipe").arg(&name).arg("--launcher-ports").arg(ports);
        command.args(self.options.passed_on());
        command.stdin(Stdio::null()).creation_flags(CREATE_NEW_PROCESS_GROUP);
        let mut child = command.spawn()?;
        let pid = child.id();
        // Its exit, seen from a thread of its own: a handle of its process to wait on.
        // SAFETY: a handle of ours, closed by OwnedHandle.
        let process = unsafe { OpenProcess(PROCESS_SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) };
        if process.is_null() {
            let error = io::Error::last_os_error();
            let _ = child.kill();
            return Err(io::Error::new(error.kind(), format!("Node {pid} cannot be waited for: {error}")));
        }
        let process = unsafe { OwnedHandle::from_raw_handle(process as RawHandle) };
        let (tx, wait_pipe) = (self.tx.clone(), pipe.clone());
        std::thread::spawn(move || {
            // SAFETY: waiting on our handle.
            unsafe { WaitForSingleObject(process.as_raw_handle() as HANDLE, u32::MAX) };
            // A pipe it never connected to waits no more.
            wait_pipe.cancel();
            let code = exit_code(&process);
            let _ = tx.send(Event::Exited(pid, code));
        });
        let (tx, read_pipe) = (self.tx.clone(), pipe.clone());
        std::thread::spawn(move || read_lines(pid, read_pipe, tx));
        let _ = child.stdin.take();
        Ok(Node { child, pipe })
    }

    fn kill(&mut self, node: &mut Node) {
        // Its exit is told by its waiting thread, as any.
        let _ = node.child.kill();
    }

    fn parent_gone(&mut self) -> bool {
        // The parent's pid is not taken over on Windows (a child keeps naming a parent long gone): its process is
        // waited on instead. None to wait on: gone already.
        match &self.parent {
            // SAFETY: waiting on our handle, not at all.
            Some(parent) => unsafe { WaitForSingleObject(parent.as_raw_handle() as HANDLE, 0) != WAIT_TIMEOUT },
            None => true,
        }
    }

    fn program(&self) -> String {
        crate::node(&self.options.app).display().to_string()
    }

    fn route(&mut self, name: &str, port: Option<u16>) {
        match name {
            "mcp" => self.mcp.serve(port),
            "admin" => self.admin.serve(port),
            _ => log::warn(&format!("Node serves {name}, which the launcher has no entrance for")),
        }
    }
}

pub fn run(options: Options) -> i32 {
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
    // The ports, held by the launcher for good (as on Unix), so a handover keeps them: Node serves behind them.
    let bound = crate::ports::mcp(&config).and_then(|mcp| Ok((mcp, crate::ports::admin(&options.data, options.port, options.named, config.english)?)));
    let (mcp, admin) = match bound {
        Ok(bound) => bound,
        Err(error) => {
            log::error(&error);
            eprintln!("{error}");
            return 1;
        }
    };
    let port_of = |l: &std::net::TcpListener| l.local_addr().map(|a| a.port()).unwrap_or(0);
    let ports = (port_of(&mcp), port_of(&admin));
    let (mcp, admin) = (Entrance::open("the agents' MCP endpoint", mcp, ENTRANCE_WAIT), Entrance::open("the loopback port", admin, ENTRANCE_WAIT));
    let security = match Security::this_user() {
        Ok(security) => Arc::new(security),
        Err(error) => {
            log::error(&error);
            return 1;
        }
    };
    let (tx, rx) = mpsc::channel();
    let _ = EVENTS.set(Mutex::new(tx.clone()));
    // SAFETY: a handler that only sends on a channel.
    unsafe { SetConsoleCtrlHandler(Some(on_ctrl), 1) };
    let with_parent = options.with_parent;
    let parent = if with_parent { parent_process() } else { None };
    if with_parent && parent.is_none() {
        log::warn("--with-parent: the parent is not there");
    }
    if let Err(error) = take_asks(&security, tx.clone()) {
        log::error(&format!("{}: {error}", control_pipe(std::process::id())));
        return 1;
    }
    let mut station = Lifecycle::new(System { options, security, tx, next: 0, parent, ports, mcp, admin }, Times::of_env(), run, with_parent);
    station.start();
    serve(&mut station, rx)
}

/// The launcher's own pipe (control_pipe), taking one asker at a time: each line's op told on the channel.
fn take_asks(security: &Security, tx: Sender<Event>) -> io::Result<()> {
    let pipe = Pipe::create(&control_pipe(std::process::id()), security)?;
    std::thread::spawn(move || {
        loop {
            if pipe.connect().is_ok() {
                let mut pending = Vec::new();
                let mut buf = [0u8; 1024];
                while let Ok(got) = pipe.read(&mut buf).and_then(|n| if n == 0 { Err(io::ErrorKind::UnexpectedEof.into()) } else { Ok(n) }) {
                    pending.extend_from_slice(&buf[..got]);
                    while let Some(at) = pending.iter().position(|&b| b == b'\n') {
                        let line: Vec<u8> = pending.drain(..=at).collect();
                        match serde_json::from_slice::<Value>(&line).ok().and_then(|v| v["op"].as_str().map(str::to_string)) {
                            Some(op) => {
                                let _ = tx.send(Event::Ask(op));
                            }
                            None => log::warn(&format!("asked what the launcher does not read: {}", String::from_utf8_lossy(&line).trim())),
                        }
                    }
                }
            }
            // The asker gone (or never there): the next one.
            pipe.disconnect();
        }
    });
    Ok(())
}

/// Waits for what happens (a line from a Node, a Node's end, a stop, something due) and tells the lifecycle, until it
/// is done.
fn serve(station: &mut Lifecycle<System>, rx: Receiver<Event>) -> i32 {
    loop {
        if let Some(exit) = station.finished() {
            log::info("stopped");
            return exit;
        }
        let event = match station.next_due() {
            Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                Ok(event) => Some(event),
                Err(RecvTimeoutError::Timeout) => None,
                Err(RecvTimeoutError::Disconnected) => return 1,
            },
            None => match rx.recv() {
                Ok(event) => Some(event),
                Err(_) => return 1,
            },
        };
        match event {
            Some(Event::Said(pid, message)) => {
                if let Some(slot) = station.slot_of(pid) {
                    station.said(slot, message);
                }
            }
            Some(Event::Exited(pid, code)) => station.ended(pid, &code.map_or("exited (no code)".into(), |c| format!("exited with {c}"))),
            Some(Event::Stop(why)) => {
                log::info(&format!("stopping ({why})"));
                station.stop();
            }
            Some(Event::Ask(op)) => match op.as_str() {
                "handover" => station.start_next(),
                "drain" | "hup" => station.ask(&op),
                "stop" => {
                    log::info("stopping (asked)");
                    station.stop();
                }
                _ => log::warn(&format!("asked to {op}, which the launcher does not do")),
            },
            None => {}
        }
        station.tick();
    }
}

fn exit_code(process: &OwnedHandle) -> Option<i32> {
    let mut code = 0u32;
    // SAFETY: on our handle of the exited process.
    let ok = unsafe { GetExitCodeProcess(process.as_raw_handle() as HANDLE, &mut code) };
    (ok != 0).then_some(code as i32)
}

/// Lines from Node on the pipe, once it has connected; until it closes.
fn read_lines(pid: u32, pipe: Pipe, tx: Sender<Event>) {
    if pipe.connect().is_err() {
        return;
    }
    let mut pending = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        let got = match pipe.read(&mut buf) {
            Ok(0) | Err(_) => return,
            Ok(got) => got,
        };
        pending.extend_from_slice(&buf[..got]);
        while let Some(at) = pending.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = pending.drain(..=at).collect();
            match serde_json::from_slice::<Value>(&line) {
                Ok(message) => {
                    let _ = tx.send(Event::Said(pid, message));
                }
                Err(_) => log::warn(&format!("an unreadable line from Node: {}", String::from_utf8_lossy(&line).trim())),
            }
        }
    }
}

/// --with-parent: the launcher's parent, to wait on (its pid read now, while it is still the parent's).
fn parent_process() -> Option<OwnedHandle> {
    let parent = parent_pid()?;
    // SAFETY: a handle of ours, closed by OwnedHandle.
    let process = unsafe { OpenProcess(PROCESS_SYNCHRONIZE, 0, parent) };
    (!process.is_null()).then(|| unsafe { OwnedHandle::from_raw_handle(process as RawHandle) })
}

fn parent_pid() -> Option<u32> {
    use windows_sys::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, PROCESSENTRY32W, Process32FirstW, Process32NextW, TH32CS_SNAPPROCESS};
    let me = std::process::id();
    // SAFETY: a snapshot of ours, closed after; the entry's size set as the API wants.
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return None;
        }
        let snapshot = OwnedHandle::from_raw_handle(snapshot as RawHandle);
        let mut entry: PROCESSENTRY32W = std::mem::zeroed();
        entry.dwSize = size_of::<PROCESSENTRY32W>() as u32;
        let mut more = Process32FirstW(snapshot.as_raw_handle() as HANDLE, &mut entry) != 0;
        while more {
            if entry.th32ProcessID == me {
                return Some(entry.th32ParentProcessID);
            }
            more = Process32NextW(snapshot.as_raw_handle() as HANDLE, &mut entry) != 0;
        }
        None
    }
}

fn wide(text: &str) -> Vec<u16> {
    OsStr::new(text).encode_wide().chain(Some(0)).collect()
}

/// A security descriptor letting this user alone open the pipe (as the runner's).
struct Security(*mut std::ffi::c_void);

// SAFETY: read only, by CreateNamedPipeW.
unsafe impl Send for Security {}
unsafe impl Sync for Security {}

impl Security {
    fn this_user() -> Result<Security, String> {
        let failed = |what: &str| format!("{what}: {}", io::Error::last_os_error());
        // SAFETY: the token and buffers are ours; what Windows allocates is freed with LocalFree.
        unsafe {
            let mut token = null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return Err(failed("OpenProcessToken"));
            }
            let token = OwnedHandle::from_raw_handle(token as RawHandle);
            let mut size = 0;
            GetTokenInformation(token.as_raw_handle() as HANDLE, TokenUser, null_mut(), 0, &mut size);
            let mut buf = vec![0u64; (size as usize).div_ceil(8)];
            if GetTokenInformation(token.as_raw_handle() as HANDLE, TokenUser, buf.as_mut_ptr().cast(), size, &mut size) == 0 {
                return Err(failed("GetTokenInformation"));
            }
            let user = &*(buf.as_ptr() as *const TOKEN_USER);
            let mut sid = null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut sid) == 0 {
                return Err(failed("ConvertSidToStringSidW"));
            }
            let len = (0..).take_while(|&i| *sid.add(i) != 0).count();
            let sid_text = String::from_utf16_lossy(std::slice::from_raw_parts(sid, len));
            LocalFree(sid.cast());
            let sddl = wide(&format!("D:P(A;;GA;;;{sid_text})"));
            let mut descriptor = null_mut();
            if ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, null_mut()) == 0 {
                return Err(failed("ConvertStringSecurityDescriptorToSecurityDescriptorW"));
            }
            Ok(Security(descriptor))
        }
    }
}

impl Drop for Security {
    fn drop(&mut self) {
        // SAFETY: allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW.
        unsafe { LocalFree(self.0) };
    }
}

/// One instance of a named pipe for one Node, opened for overlapped I/O (a read waiting does not hold up a write).
#[derive(Clone)]
struct Pipe(Arc<OwnedHandle>);

impl Pipe {
    fn create(name: &str, security: &Security) -> io::Result<Pipe> {
        let attributes = SECURITY_ATTRIBUTES { nLength: size_of::<SECURITY_ATTRIBUTES>() as u32, lpSecurityDescriptor: security.0, bInheritHandle: 0 };
        let name = wide(name);
        // SAFETY: a name and attributes that live through the call.
        let handle = unsafe {
            CreateNamedPipeW(
                name.as_ptr(),
                PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                4096,
                4096,
                0,
                &attributes,
            )
        };
        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: just made, ours alone.
        Ok(Pipe(Arc::new(unsafe { OwnedHandle::from_raw_handle(handle as RawHandle) })))
    }

    fn raw(&self) -> HANDLE {
        self.0.as_raw_handle() as HANDLE
    }

    fn connect(&self) -> io::Result<()> {
        self.overlapped(|h, o| unsafe { ConnectNamedPipe(h, o) }, |e| e == ERROR_PIPE_CONNECTED).map(|_| ())
    }

    fn read(&self, buf: &mut [u8]) -> io::Result<usize> {
        let len = buf.len() as u32;
        // SAFETY: the buffer outlives the operation (`overlapped` waits for its end).
        self.overlapped(|h, o| unsafe { ReadFile(h, buf.as_mut_ptr(), len, null_mut(), o) }, |_| false)
    }

    fn write_all(&self, mut buf: &[u8]) -> io::Result<()> {
        while !buf.is_empty() {
            let len = buf.len() as u32;
            // SAFETY: as in read.
            let n = self.overlapped(|h, o| unsafe { WriteFile(h, buf.as_ptr(), len, null_mut(), o) }, |_| false)?;
            if n == 0 {
                return Err(io::ErrorKind::WriteZero.into());
            }
            buf = &buf[n..];
        }
        Ok(())
    }

    /// Ends what waits on it (a connect Node will never make).
    fn cancel(&self) {
        // SAFETY: on our own handle.
        unsafe { CancelIoEx(self.raw(), null()) };
    }

    /// Lets the client go, for the next one to connect.
    fn disconnect(&self) {
        // SAFETY: on our own handle.
        unsafe { DisconnectNamedPipe(self.raw()) };
    }

    fn overlapped(&self, start: impl FnOnce(HANDLE, *mut OVERLAPPED) -> i32, done: impl Fn(u32) -> bool) -> io::Result<usize> {
        // SAFETY: the event and the OVERLAPPED live until the operation has ended (GetOverlappedResult waits for it).
        unsafe {
            let event = CreateEventW(null(), 1, 0, null());
            if event.is_null() {
                return Err(io::Error::last_os_error());
            }
            let mut o: OVERLAPPED = std::mem::zeroed();
            o.hEvent = event;
            let result = (|| {
                if start(self.raw(), &mut o) == 0 {
                    let error = GetLastError();
                    if done(error) {
                        return Ok(0);
                    }
                    if error != ERROR_IO_PENDING {
                        return Err(io::Error::from_raw_os_error(error as i32));
                    }
                }
                let mut n = 0;
                if GetOverlappedResult(self.raw(), &o, &mut n, 1) == 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(n as usize)
            })();
            CloseHandle(event);
            result
        }
    }
}
