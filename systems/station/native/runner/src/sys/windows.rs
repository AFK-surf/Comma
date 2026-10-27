//! What the runner does through the system on Windows: a named pipe only this user may open, in place of the Unix
//! socket; a job object holding the agent and what it starts, in place of its process group; no signals, so a
//! `signal` ends the agent (or its job) as Node's `process.kill` does on Windows.

use std::ffi::OsStr;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::windows::ffi::OsStrExt;
use std::os::windows::fs::FileExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle, RawHandle};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::ptr::{null, null_mut};
use std::sync::atomic::{AtomicU8, Ordering};
use std::sync::{Arc, Mutex};

use serde_json::{Value, json};
use windows_sys::Win32::Foundation::{
    CloseHandle, DUPLICATE_SAME_ACCESS, DuplicateHandle, ERROR_BROKEN_PIPE, ERROR_IO_PENDING, ERROR_NO_DATA, ERROR_PIPE_BUSY, ERROR_PIPE_CONNECTED,
    ERROR_PIPE_NOT_CONNECTED, GetHandleInformation, GetLastError, HANDLE, HANDLE_FLAG_INHERIT, INVALID_HANDLE_VALUE, LocalFree, STATUS_INFO_LENGTH_MISMATCH,
    SetHandleInformation,
};
use windows_sys::Wdk::System::Threading::{NtQueryInformationProcess, ProcessHandleInformation};
use windows_sys::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
use windows_sys::Win32::Security::{GetTokenInformation, PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES, TOKEN_QUERY, TOKEN_USER, TokenUser};
use windows_sys::Win32::Storage::FileSystem::{FILE_FLAG_FIRST_PIPE_INSTANCE, FILE_FLAG_OVERLAPPED, PIPE_ACCESS_DUPLEX, ReadFile, WriteFile};
use windows_sys::Win32::System::Console::{GetStdHandle, STD_ERROR_HANDLE, STD_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, SetStdHandle};
use windows_sys::Win32::System::Diagnostics::ToolHelp::{CreateToolhelp32Snapshot, TH32CS_SNAPTHREAD, THREADENTRY32, Thread32First, Thread32Next};
use windows_sys::Win32::System::IO::{CancelIoEx, CreateIoCompletionPort, GetOverlappedResult, GetQueuedCompletionStatus, OVERLAPPED};
use windows_sys::Win32::System::JobObjects::{
    AssignProcessToJobObject, CreateJobObjectW, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, JOBOBJECT_ASSOCIATE_COMPLETION_PORT,
    JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JobObjectAssociateCompletionPortInformation, JobObjectExtendedLimitInformation, SetInformationJobObject,
    TerminateJobObject,
};
use windows_sys::Win32::System::Pipes::{
    ConnectNamedPipe, CreateNamedPipeW, DisconnectNamedPipe, PIPE_READMODE_BYTE, PIPE_REJECT_REMOTE_CLIENTS, PIPE_TYPE_BYTE, PIPE_UNLIMITED_INSTANCES,
    PIPE_WAIT,
};
use windows_sys::Win32::System::Threading::{
    CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW, CREATE_SUSPENDED, CreateEventW, GetCurrentProcess,
    GetExitCodeProcess, OpenProcessToken, OpenThread, ResumeThread, THREAD_SUSPEND_RESUME,
    INFINITE, TerminateProcess,
};

use super::Signal;

/// The exit code of an agent this runner ended (what a signal's death is elsewhere).
const ENDED: u32 = 1;
const PIPE_BUFFER: u32 = 64 * 1024;
/// winnt.h's: a job's last process has ended (windows-sys has it under SystemServices, a feature of its own).
const JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO: u32 = 4;

/// A named pipe, not a file: `\\.\pipe\stillfail-runner-<the directory, hashed>-<id>`, so that two data directories'
/// runners of the same id are apart. It is not looked at as a file (opening it, even to see it is there, connects).
pub fn socket_path(dir: &Path, id: &str) -> PathBuf {
    // FNV-1a over the directory as Windows compares paths (case aside).
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for unit in dir.as_os_str().to_string_lossy().to_lowercase().encode_utf16() {
        for byte in unit.to_le_bytes() {
            hash = (hash ^ byte as u64).wrapping_mul(0x0000_0100_0000_01b3);
        }
    }
    PathBuf::from(format!(r"\\.\pipe\stillfail-runner-{hash:016x}-{id}"))
}

/// Whether a runner listens on the pipe now: a connection that says nothing, which a runner leaves be (see
/// `connection`). Busy is there too: every instance taken for a moment, while the next one is made.
pub fn answers(sock: &Path) -> bool {
    match OpenOptions::new().read(true).write(true).open(sock) {
        Ok(_) => true,
        Err(e) => e.raw_os_error() == Some(ERROR_PIPE_BUSY as i32),
    }
}

/// A pipe goes when its last handle closes: nothing to remove.
pub fn remove_socket(_sock: &Path) {}

/// A pipe is in no directory.
pub fn create_socket_dir(_sock: &Path, _dir: &Path) -> Result<(), String> {
    Ok(())
}

/// Lets go of what the starter handed down besides stdio. Windows passes a child every inheritable handle of its
/// parent's (Node's own stdio among them, whatever it is told to pass), where Unix closes them on exec: kept, a
/// runner would hold the station's stdout open as long as it lives, so whoever reads that never sees its end.
pub fn leave_session() {
    let std: Vec<HANDLE> = STD.iter().map(|&which| unsafe { GetStdHandle(which) }).collect();
    for handle in own_handles() {
        let mut flags = 0;
        // SAFETY: a handle of this process's, closed only when it was inherited and is none of its stdio.
        unsafe {
            if !std.contains(&handle) && GetHandleInformation(handle, &mut flags) != 0 && flags & HANDLE_FLAG_INHERIT != 0 {
                CloseHandle(handle);
            }
        }
    }
}

/// This process's handles, as the system lists them (Windows 8 on).
fn own_handles() -> Vec<HANDLE> {
    #[repr(C)]
    struct Entry {
        handle: HANDLE,
        handle_count: usize,
        pointer_count: usize,
        granted_access: u32,
        object_type_index: u32,
        attributes: u32,
        reserved: u32,
    }
    #[repr(C)]
    struct Snapshot {
        count: usize,
        reserved: usize,
    }
    let mut buf = vec![0usize; 4096];
    loop {
        let mut len = 0;
        let size = (buf.len() * size_of::<usize>()) as u32;
        // SAFETY: the buffer is as long as said; what is read from it is within what the call filled.
        let status = unsafe { NtQueryInformationProcess(GetCurrentProcess(), ProcessHandleInformation, buf.as_mut_ptr().cast(), size, &mut len) };
        if status == STATUS_INFO_LENGTH_MISMATCH && (len as usize) > buf.len() * size_of::<usize>() {
            buf = vec![0usize; (len as usize).div_ceil(size_of::<usize>()) + 64];
            continue;
        }
        if status < 0 {
            return Vec::new();
        }
        unsafe {
            let head = &*(buf.as_ptr() as *const Snapshot);
            let entries = std::slice::from_raw_parts((buf.as_ptr() as *const Snapshot).add(1) as *const Entry, head.count);
            return entries.iter().map(|e| e.handle).collect();
        }
    }
}

pub fn ready() {}

pub fn create_dir(dir: &Path) -> io::Result<()> {
    // Under the station's data directory, whose ACL (the user's profile's) it inherits.
    fs::create_dir_all(dir)
}

pub fn create_file(options: &mut OpenOptions) -> &mut OpenOptions {
    options
}

pub fn write_all_at(file: &File, mut buf: &[u8], mut at: u64) -> io::Result<()> {
    while !buf.is_empty() {
        match file.seek_write(buf, at) {
            Ok(0) => return Err(io::ErrorKind::WriteZero.into()),
            Ok(n) => {
                buf = &buf[n..];
                at += n as u64;
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

pub fn read_exact_at(file: &File, mut buf: &mut [u8], mut at: u64) -> io::Result<()> {
    while !buf.is_empty() {
        match file.seek_read(buf, at) {
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => {
                buf = &mut buf[n..];
                at += n as u64;
            }
            Err(e) if e.kind() == io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(())
}

const STD: [STD_HANDLE; 3] = [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE];

/// The starter's stdio is not to be inherited by the agent: Windows passes every inheritable handle on, and the
/// starter reads the runner's stdout to its end, which would then be the agent's.
fn keep_stdio() {
    for which in STD {
        // SAFETY: flags on our own standard handles.
        unsafe {
            let handle = GetStdHandle(which);
            if !handle.is_null() && handle != INVALID_HANDLE_VALUE {
                SetHandleInformation(handle, HANDLE_FLAG_INHERIT, 0);
            }
        }
    }
}

pub fn detach_stdio() {
    let null = OpenOptions::new().read(true).write(true).open("NUL").ok().map(|f| f.into_raw_handle_leaked());
    for which in STD {
        // SAFETY: the standard handles are ours; each is replaced (by NUL) before the old one is closed.
        unsafe {
            let old = GetStdHandle(which);
            SetStdHandle(which, null.unwrap_or(null_mut()));
            if !old.is_null() && old != INVALID_HANDLE_VALUE && Some(old) != null {
                CloseHandle(old);
            }
        }
    }
}

trait Leak {
    fn into_raw_handle_leaked(self) -> HANDLE;
}

impl Leak for File {
    fn into_raw_handle_leaked(self) -> HANDLE {
        use std::os::windows::io::IntoRawHandle;
        self.into_raw_handle() as HANDLE
    }
}

fn wide(text: &OsStr) -> Vec<u16> {
    text.encode_wide().chain(Some(0)).collect()
}

fn last_error(what: &str) -> String {
    format!("{what}: {}", io::Error::last_os_error())
}

/// A security descriptor letting this user alone (not other users, not the network) open the pipe.
struct Security {
    descriptor: PSECURITY_DESCRIPTOR,
}

// SAFETY: the descriptor is read only, by CreateNamedPipeW.
unsafe impl Send for Security {}
unsafe impl Sync for Security {}

impl Security {
    fn this_user() -> Result<Security, String> {
        // SAFETY: the token and the buffers are ours; what Windows allocates is freed with LocalFree.
        unsafe {
            let mut token = null_mut();
            if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
                return Err(last_error("OpenProcessToken"));
            }
            let token = OwnedHandle::from_raw_handle(token as RawHandle);
            let mut size = 0;
            GetTokenInformation(token.as_raw_handle() as HANDLE, TokenUser, null_mut(), 0, &mut size);
            let mut buf = vec![0u64; (size as usize).div_ceil(8)];
            if GetTokenInformation(token.as_raw_handle() as HANDLE, TokenUser, buf.as_mut_ptr().cast(), size, &mut size) == 0 {
                return Err(last_error("GetTokenInformation"));
            }
            let user = &*(buf.as_ptr() as *const TOKEN_USER);
            let mut sid = null_mut();
            if ConvertSidToStringSidW(user.User.Sid, &mut sid) == 0 {
                return Err(last_error("ConvertSidToStringSidW"));
            }
            let len = (0..).take_while(|&i| *sid.add(i) != 0).count();
            let sid_text = String::from_utf16_lossy(std::slice::from_raw_parts(sid, len));
            LocalFree(sid.cast());
            // Protected (no inherited entries); all access to the user, nothing to anyone else.
            let sddl = wide(OsStr::new(&format!("D:P(A;;GA;;;{sid_text})")));
            let mut descriptor = null_mut();
            if ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl.as_ptr(), SDDL_REVISION_1, &mut descriptor, null_mut()) == 0 {
                return Err(last_error("ConvertStringSecurityDescriptorToSecurityDescriptorW"));
            }
            Ok(Security { descriptor })
        }
    }
}

pub struct Listener {
    name: Vec<u16>,
    security: Security,
    /// The instance the next station connects to: there is always one, so the pipe is never found missing.
    next: Mutex<Option<Pipe>>,
}

impl Listener {
    pub fn bind(sock: &Path) -> Result<Listener, String> {
        let listener = Listener { name: wide(sock.as_os_str()), security: Security::this_user()?, next: Mutex::new(None) };
        // The first instance: no other process may have the name already.
        let first = listener.instance(true).map_err(|e| format!("cannot listen on {}: {e}", sock.display()))?;
        *listener.next.lock().unwrap() = Some(first);
        Ok(listener)
    }

    fn instance(&self, first: bool) -> io::Result<Pipe> {
        let attributes = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: self.security.descriptor,
            bInheritHandle: 0,
        };
        let open = PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | if first { FILE_FLAG_FIRST_PIPE_INSTANCE } else { 0 };
        let mode = PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS;
        // SAFETY: a name and attributes that live through the call.
        let handle = unsafe { CreateNamedPipeW(self.name.as_ptr(), open, mode, PIPE_UNLIMITED_INSTANCES, PIPE_BUFFER, PIPE_BUFFER, 0, &attributes) };
        if handle == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: just made, ours alone.
        Ok(Pipe(Arc::new(unsafe { OwnedHandle::from_raw_handle(handle as RawHandle) })))
    }

    pub fn accept(&self) -> io::Result<Conn> {
        let pipe = match self.next.lock().unwrap().take() {
            Some(pipe) => pipe,
            None => self.instance(false)?,
        };
        let connected = pipe.connect();
        // The next instance before this one is handed on: a station connecting meanwhile waits (busy), not fails.
        *self.next.lock().unwrap() = self.instance(false).ok();
        connected?;
        Ok(Conn(pipe))
    }
}

impl Drop for Security {
    fn drop(&mut self) {
        // SAFETY: allocated by ConvertStringSecurityDescriptorToSecurityDescriptorW.
        unsafe { LocalFree(self.descriptor) };
    }
}

/// One instance of the pipe, opened for overlapped I/O: a read waiting on it does not hold up a write (synchronous
/// I/O on one handle is done one at a time).
#[derive(Clone)]
struct Pipe(Arc<OwnedHandle>);

impl Pipe {
    fn raw(&self) -> HANDLE {
        self.0.as_raw_handle() as HANDLE
    }

    fn connect(&self) -> io::Result<()> {
        overlapped(self.raw(), |h, o| unsafe { ConnectNamedPipe(h, o) }, |e| e == ERROR_PIPE_CONNECTED).map(|_| ())
    }
}

/// Runs one overlapped operation on `handle` to its end: `start` begins it (non-zero: done at once); an error that
/// `done` accepts means it is done anyway. The bytes it moved.
fn overlapped(handle: HANDLE, start: impl FnOnce(HANDLE, *mut OVERLAPPED) -> i32, done: impl Fn(u32) -> bool) -> io::Result<usize> {
    // SAFETY: the event and the OVERLAPPED live until the operation has ended (GetOverlappedResult waits for it).
    unsafe {
        let event = CreateEventW(null(), 1, 0, null());
        if event.is_null() {
            return Err(io::Error::last_os_error());
        }
        let event = OwnedHandle::from_raw_handle(event as RawHandle);
        let mut o: OVERLAPPED = std::mem::zeroed();
        o.hEvent = event.as_raw_handle() as HANDLE;
        if start(handle, &mut o) == 0 {
            let error = GetLastError();
            if done(error) {
                return Ok(0);
            }
            if error != ERROR_IO_PENDING {
                return Err(io::Error::from_raw_os_error(error as i32));
            }
        }
        let mut n = 0;
        if GetOverlappedResult(handle, &o, &mut n, 1) == 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(n as usize)
    }
}

pub struct Conn(Pipe);

impl Conn {
    pub fn try_clone(&self) -> io::Result<Conn> {
        Ok(Conn(self.0.clone()))
    }

    /// Ends it both ways: what waits on it fails, the station sees it closed.
    pub fn shutdown(&self) {
        // SAFETY: on our own handle.
        unsafe {
            CancelIoEx(self.0.raw(), null());
            DisconnectNamedPipe(self.0.raw());
        }
    }

    fn io(&self, start: impl FnOnce(HANDLE, *mut OVERLAPPED) -> i32) -> io::Result<usize> {
        overlapped(self.0.raw(), start, |_| false)
    }
}

/// The pipe's end, as a socket's: the station gone, or this end disconnected.
fn ended(e: &io::Error) -> bool {
    matches!(e.raw_os_error().map(|c| c as u32), Some(ERROR_BROKEN_PIPE | ERROR_PIPE_NOT_CONNECTED | ERROR_NO_DATA))
}

impl Read for Conn {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let len = buf.len().min(u32::MAX as usize) as u32;
        // SAFETY: the buffer outlives the operation (`io` waits for its end).
        match self.io(|h, o| unsafe { ReadFile(h, buf.as_mut_ptr(), len, null_mut(), o) }) {
            Err(e) if ended(&e) => Ok(0),
            other => other,
        }
    }
}

impl Write for Conn {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        let len = buf.len().min(u32::MAX as usize) as u32;
        // SAFETY: as in read.
        match self.io(|h, o| unsafe { WriteFile(h, buf.as_ptr(), len, null_mut(), o) }) {
            Err(e) if ended(&e) => Err(io::ErrorKind::BrokenPipe.into()),
            other => other,
        }
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// The agent, and the job that holds it and whatever it starts (its group).
pub struct Agent {
    pid: i32,
    process: OwnedHandle,
    job: OwnedHandle,
    /// The signal it was ended by, as `signal_name` says: 0 while it was not.
    ended_by: AtomicU8,
}

/// Starts the agent in a job of its own, without a console window, its stdio piped to the runner.
pub fn spawn(program: &str, args: &[String], cwd: Option<&Path>) -> io::Result<(Child, Agent)> {
    keep_stdio();
    let job = new_job()?;
    let (child, process) = start_in_job(&job, program, args, cwd, true)?;
    let agent = Agent { pid: child.id() as i32, process, job, ended_by: AtomicU8::new(0) };
    Ok((child, agent))
}

fn new_job() -> io::Result<OwnedHandle> {
    // SAFETY: a job of ours.
    let job = unsafe { CreateJobObjectW(null(), null()) };
    if job.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: just made, ours alone.
    Ok(unsafe { OwnedHandle::from_raw_handle(job as RawHandle) })
}

/// Starts `program` in `job`: suspended, and resumed once in it, so nothing it starts escapes it. Its stdio piped, or
/// this process's (inherited). With its handle, which stays good (its pid not reused) while kept.
fn start_in_job(job: &OwnedHandle, program: &str, args: &[String], cwd: Option<&Path>, piped: bool) -> io::Result<(Child, OwnedHandle)> {
    let program = resolve(program);
    let (program, before) = unshim(&program).unwrap_or((program, Vec::new()));
    let command = |breakaway: bool| {
        let mut command = Command::new(&program);
        command.args(&before).args(args);
        if piped {
            command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
        }
        let flags = CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP | CREATE_SUSPENDED | if breakaway { CREATE_BREAKAWAY_FROM_JOB } else { 0 };
        command.creation_flags(flags);
        if let Some(cwd) = cwd {
            command.current_dir(cwd);
        }
        command
    };
    // Out of whatever job holds the runner (a terminal's, say) when that job lets it; in it, as nested, when not.
    let mut child = match command(true).spawn() {
        Err(e) if e.raw_os_error() == Some(windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED as i32) => command(false).spawn()?,
        other => other?,
    };
    let pid = child.id();
    let mut process = null_mut();
    // SAFETY: duplicating the child's handle, which `child` keeps open meanwhile.
    let duplicated = unsafe {
        DuplicateHandle(GetCurrentProcess(), child.as_raw_handle() as HANDLE, GetCurrentProcess(), &mut process, 0, 0, DUPLICATE_SAME_ACCESS)
    };
    let started = (|| {
        if duplicated == 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: on the suspended child's handle.
        if unsafe { AssignProcessToJobObject(job.as_raw_handle() as HANDLE, child.as_raw_handle() as HANDLE) } == 0 {
            return Err(io::Error::last_os_error());
        }
        resume(pid)
    })();
    if let Err(e) = started {
        let _ = child.kill();
        let _ = child.wait();
        if duplicated != 0 {
            // SAFETY: ours.
            unsafe { CloseHandle(process) };
        }
        return Err(e);
    }
    // SAFETY: duplicated above, ours alone.
    Ok((child, unsafe { OwnedHandle::from_raw_handle(process as RawHandle) }))
}

/// `stillfail-runner --job -- <program> <args…>`: what a process group is to the station's jobs and commands on Unix.
/// Runs the program, with this process's stdio, in a job that ends whole when this process does (killed: what ending
/// the group is), and exits with its code once nothing of the job is left (as a group lives while a member does). What
/// a shell execs is a new process with its parent gone, which no process tree finds but the job holds.
pub fn run_job(program: &str, args: &[String]) -> ! {
    leave_session();
    let fail = |e: io::Error| -> ! {
        eprintln!("stillfail-runner: cannot start {program}: {e}");
        std::process::exit(127)
    };
    let job = new_job().unwrap_or_else(|e| fail(e));
    // SAFETY: our own job and port; the structures live through the calls.
    let port = unsafe {
        let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        let raw = job.as_raw_handle() as HANDLE;
        if SetInformationJobObject(raw, JobObjectExtendedLimitInformation, (&raw const limits).cast(), size_of_val(&limits) as u32) == 0 {
            fail(io::Error::last_os_error());
        }
        // Told when no process of the job is left.
        let port = CreateIoCompletionPort(INVALID_HANDLE_VALUE, null_mut(), 0, 1);
        if port.is_null() {
            fail(io::Error::last_os_error());
        }
        let port = OwnedHandle::from_raw_handle(port as RawHandle);
        let associate = JOBOBJECT_ASSOCIATE_COMPLETION_PORT { CompletionKey: null_mut(), CompletionPort: port.as_raw_handle() as HANDLE };
        if SetInformationJobObject(raw, JobObjectAssociateCompletionPortInformation, (&raw const associate).cast(), size_of_val(&associate) as u32) == 0 {
            fail(io::Error::last_os_error());
        }
        port
    };
    let (mut child, _process) = start_in_job(&job, program, args, None, false).unwrap_or_else(|e| fail(e));
    let code = child.wait().ok().and_then(|s| s.code()).unwrap_or(1);
    // SAFETY: waiting on our own port for the job's messages.
    unsafe {
        loop {
            let (mut message, mut key, mut overlapped) = (0u32, 0usize, null_mut());
            if GetQueuedCompletionStatus(port.as_raw_handle() as HANDLE, &mut message, &mut key, &mut overlapped, INFINITE) == 0 {
                break;
            }
            if message == JOB_OBJECT_MSG_ACTIVE_PROCESS_ZERO {
                break;
            }
        }
    }
    std::process::exit(code)
}

/// A bare name as a shell finds it on PATH, with each of PATHEXT's extensions: `codex` is `codex.cmd` when npm put it
/// there (Rust alone would look for `codex.exe`). A `.cmd` or `.bat` is then run through cmd, its arguments escaped
/// for it (or refused when they cannot be), by Rust's Command.
fn resolve(program: &str) -> PathBuf {
    let path = Path::new(program);
    if path.extension().is_some() || path.components().count() > 1 {
        return path.to_path_buf();
    }
    let exts = std::env::var("PATHEXT").unwrap_or_else(|_| ".COM;.EXE;.BAT;.CMD".into());
    let dirs = std::env::var_os("PATH").unwrap_or_default();
    for dir in std::env::split_paths(&dirs) {
        for ext in exts.split(';').filter(|e| !e.is_empty()) {
            let candidate = dir.join(format!("{program}{}", ext.to_lowercase()));
            if candidate.is_file() {
                return candidate;
            }
        }
    }
    path.to_path_buf()
}

/// What a `.cmd` shim runs, when it is one whose arguments can go around cmd (which cannot pass a newline, and which
/// Rust then refuses: an agent's instructions have them): npm's (cmd-shim: `"%_prog%" "%dp0%\…\cli.js" %*`, Node
/// beside it or on PATH) as Node and the script; one that only hands on to another `.cmd` (Vite+'s) as what that one
/// runs. None for anything else, which cmd runs.
pub fn unshim(path: &Path) -> Option<(PathBuf, Vec<String>)> {
    let mut path = path.to_path_buf();
    for _ in 0..4 {
        if !path.extension().is_some_and(|e| e.eq_ignore_ascii_case("cmd")) {
            return None;
        }
        let text = fs::read(&path).ok().filter(|t| t.len() < 16 * 1024)?;
        let text = String::from_utf8_lossy(&text);
        let dir = path.parent()?.to_path_buf();
        // npm's: the script, relative to the shim's directory.
        if let Some(at) = text.find("\"%_prog%\"") {
            let rest = &text[at + "\"%_prog%\"".len()..];
            let open = rest.find("\"%dp0%\\")? + "\"%dp0%\\".len();
            let close = rest[open..].find('"')? + open;
            if !rest[close + 1..].trim_start().starts_with("%*") {
                return None;
            }
            let script = dir.join(&rest[open..close]);
            let node = dir.join("node.exe");
            let node = if node.is_file() { node } else { resolve("node") };
            return Some((node, vec![script.to_string_lossy().into_owned()]));
        }
        // One that only hands on: `"<another>.cmd" %*` (and an @echo off, an exit with its code).
        let lines: Vec<&str> = text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.eq_ignore_ascii_case("@echo off") && !l.to_ascii_lowercase().starts_with("exit /b")).collect();
        let [line] = lines.as_slice() else { return None };
        let rest = line.strip_prefix('"')?;
        let close = rest.find('"')?;
        if rest[close + 1..].trim() != "%*" {
            return None;
        }
        path = PathBuf::from(&rest[..close]);
    }
    None
}

/// Resumes the threads of a process started suspended (it has the one).
fn resume(pid: u32) -> io::Result<()> {
    // SAFETY: a snapshot and thread handles of ours, closed after; the entry's size set as the API wants.
    unsafe {
        let snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if snapshot == INVALID_HANDLE_VALUE {
            return Err(io::Error::last_os_error());
        }
        let snapshot = OwnedHandle::from_raw_handle(snapshot as RawHandle);
        let mut entry: THREADENTRY32 = std::mem::zeroed();
        entry.dwSize = size_of::<THREADENTRY32>() as u32;
        let mut resumed = 0;
        let mut more = Thread32First(snapshot.as_raw_handle() as HANDLE, &mut entry) != 0;
        while more {
            if entry.th32OwnerProcessID == pid {
                let thread = OpenThread(THREAD_SUSPEND_RESUME, 0, entry.th32ThreadID);
                if !thread.is_null() {
                    if ResumeThread(thread) != u32::MAX {
                        resumed += 1;
                    }
                    CloseHandle(thread);
                }
            }
            more = Thread32Next(snapshot.as_raw_handle() as HANDLE, &mut entry) != 0;
        }
        if resumed == 0 {
            return Err(io::Error::other(format!("could not resume process {pid}")));
        }
        Ok(())
    }
}

const SIGNALS: [&str; 3] = ["TERM", "KILL", "INT"];

impl Agent {
    pub fn pid(&self) -> i32 {
        self.pid
    }

    pub fn abandon(&self) {
        // SAFETY: our own job.
        unsafe { TerminateJobObject(self.job.as_raw_handle() as HANDLE, ENDED) };
    }

    /// Waits for the agent to exit. The process handle kept means its pid is not reused meanwhile, so `ended` has
    /// nothing to guard here; it is called all the same, before the exit is said.
    pub fn wait(&self, mut child: Child, ended: impl FnOnce()) -> Value {
        let status = child.wait();
        ended();
        let by = self.ended_by.load(Ordering::SeqCst);
        if by > 0 {
            return json!({"op": "exit", "code": null, "signal": SIGNALS[by as usize - 1]});
        }
        match status.ok().and_then(|s| s.code()) {
            Some(code) => json!({"op": "exit", "code": code, "signal": null}),
            None => {
                let mut code = 0;
                // SAFETY: on our handle of the exited process.
                unsafe { GetExitCodeProcess(self.process.as_raw_handle() as HANDLE, &mut code) };
                json!({"op": "exit", "code": code as i32, "signal": null})
            }
        }
    }

    /// There are no signals: any of them ends the agent, or its whole job (what it started too, the agent ended or
    /// not), as `process.kill` does on Windows.
    pub fn signal(&self, signal: Signal, group: bool, exiting: bool) -> Result<(), String> {
        let by = match signal {
            Signal::Term => 1,
            Signal::Kill => 2,
            Signal::Int => 3,
        };
        if !group && exiting {
            return Err("signal: the agent has exited".into());
        }
        if !exiting {
            let _ = self.ended_by.compare_exchange(0, by, Ordering::SeqCst, Ordering::SeqCst);
        }
        // SAFETY: our own job and process handles.
        let ok = unsafe {
            if group {
                TerminateJobObject(self.job.as_raw_handle() as HANDLE, ENDED)
            } else {
                TerminateProcess(self.process.as_raw_handle() as HANDLE, ENDED)
            }
        };
        if ok == 0 && !exiting {
            return Err(last_error("signal"));
        }
        Ok(())
    }
}
