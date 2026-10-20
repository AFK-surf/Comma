//! stillfail-runner: keeps one agent process (claude, codex app-server) for the station, so the agent outlives the
//! station restarting or crashing (docs/station-ts-native.md, section 1).
//!
//! The runner holds the agent's stdin and appends its stdout and stderr to `<id>.out` and `<id>.err` as they come. A
//! station attaches on `<id>.sock` and is sent what it has not acknowledged yet, then whatever follows; the agent's
//! exit comes after all of its output.
//!
//! What it does through the system (the socket, the agent's group, signals) is `sys`'s: Unix's, or Windows' (a named
//! pipe for the socket, a job object for the group).

use std::fs::{self, File, OpenOptions};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use serde_json::{Value, json};

#[cfg_attr(unix, path = "sys/unix.rs")]
#[cfg_attr(windows, path = "sys/windows.rs")]
mod sys;

use sys::{Agent, Conn, Listener};

/// What a station may ask to be sent to the agent.
#[derive(Clone, Copy)]
enum Signal {
    Term,
    Kill,
    Int,
}

const USAGE: &str = "usage: stillfail-runner --dir <run/runners> --id <id> [--cwd <dir>] -- <program> <args…>
       (Windows) stillfail-runner --job -- <program> <args…>";
/// How long a runner whose agent has exited waits for a `done` before it cleans up by itself.
const LINGER: Duration = Duration::from_secs(24 * 3600);
/// After the agent exits, how long its output may take to end (something it started can hold the pipes open).
const SETTLE: Duration = Duration::from_secs(1);
/// Most bytes in one `out` message.
const CHUNK: usize = 64 * 1024;
const STREAMS: [&str; 2] = ["out", "err"];

struct Args {
    dir: PathBuf,
    id: String,
    cwd: Option<PathBuf>,
    linger: Duration,
    settle: Duration,
    program: String,
    args: Vec<String>,
}

#[derive(Clone)]
struct Paths {
    sock: PathBuf,
    json: PathBuf,
    out: PathBuf,
    err: PathBuf,
}

impl Paths {
    fn remove(&self) {
        sys::remove_socket(&self.sock);
        for path in [&self.json, &self.out, &self.err] {
            let _ = fs::remove_file(path);
        }
    }
}

struct Shared {
    state: Mutex<State>,
    changed: Condvar,
    /// The agent, and its group.
    agent: Agent,
    paths: Paths,
    /// Read handles on `<id>.out` and `<id>.err`, which is where what is sent comes from.
    files: [File; 2],
    stdin: Sender<Option<Vec<u8>>>,
    linger: Duration,
    settle: Duration,
}

#[derive(Default)]
struct State {
    /// Bytes of each stream written to its file so far.
    len: [u64; 2],
    eof: [bool; 2],
    /// The agent has ended (not reaped yet, maybe): its pid is no longer to be signalled alone.
    exiting: bool,
    exit: Option<Value>,
    /// The agent has exited and its output has ended (or had its time to): the exit may be sent.
    settled: bool,
    acked: [u64; 2],
    /// The current connection, by number; a new one closes the one before.
    conn: u64,
    current: Option<Conn>,
    /// What the current connection is being sent, once it has attached.
    push: Option<Push>,
    /// Counts attaches, so that a send in flight while the client re-attaches does not move the new cursor.
    epoch: u64,
    /// `done` came while the agent was running: clean up once it exits.
    done: bool,
}

struct Push {
    epoch: u64,
    at: [u64; 2],
    exit_sent: bool,
}

fn main() {
    let raw: Vec<String> = std::env::args().skip(1).collect();
    // Windows only: a job's process group (see sys::run_job).
    #[cfg(windows)]
    if raw.first().map(String::as_str) == Some("--job") {
        match raw.get(1).map(String::as_str) {
            Some("--") if raw.len() > 2 => sys::run_job(&raw[2], &raw[3..]),
            _ => {
                eprintln!("stillfail-runner: usage: stillfail-runner --job -- <program> <args…>");
                std::process::exit(2);
            }
        }
    }
    let args = match parse_args(raw) {
        Ok(args) => args,
        Err(e) => {
            eprintln!("stillfail-runner: {e}\n{USAGE}");
            std::process::exit(2);
        }
    };
    sys::leave_session();
    let (shared, listener) = match start(&args) {
        Ok(started) => started,
        Err(e) => {
            eprintln!("stillfail-runner: {e}");
            std::process::exit(1);
        }
    };
    serve(shared, listener);
}

fn parse_args(raw: Vec<String>) -> Result<Args, String> {
    let (mut dir, mut id, mut cwd, mut linger, mut settle) = (None, None, None, LINGER, SETTLE);
    let mut it = raw.into_iter();
    let mut command = Vec::new();
    while let Some(arg) = it.next() {
        let mut value = || it.next().ok_or_else(|| format!("{arg} needs a value"));
        match arg.as_str() {
            "--dir" => dir = Some(PathBuf::from(value()?)),
            "--id" => id = Some(value()?),
            "--cwd" => cwd = Some(PathBuf::from(value()?)),
            // Not for the station: lets tests see the cleanup without waiting a day.
            "--linger-ms" => linger = Duration::from_millis(value()?.parse().map_err(|_| "--linger-ms needs a number of ms")?),
            // Not for the station either: lets tests wait for the output's end however late it comes.
            "--settle-ms" => settle = Duration::from_millis(value()?.parse().map_err(|_| "--settle-ms needs a number of ms")?),
            "--" => {
                command = it.collect();
                break;
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    let dir = dir.ok_or("--dir is required")?;
    let id = id.ok_or("--id is required")?;
    if id.is_empty() || id.starts_with('.') || id.contains(['/', '\\']) {
        return Err(format!("bad id {id:?}"));
    }
    if command.is_empty() {
        return Err("no program given after --".into());
    }
    let program = command.remove(0);
    let dir = std::path::absolute(&dir).map_err(|e| format!("bad --dir: {e}"))?;
    Ok(Args { dir, id, cwd, linger, settle, program, args: command })
}

/// Starts the agent and everything around it, says it is ready, and lets go of whoever started the runner.
fn start(args: &Args) -> Result<(Arc<Shared>, Listener), String> {
    sys::create_dir(&args.dir).map_err(|e| format!("cannot create {}: {e}", args.dir.display()))?;
    let base = |ext: &str| args.dir.join(format!("{}.{ext}", args.id));
    let paths = Paths { sock: sys::socket_path(&args.dir, &args.id), json: base("json"), out: base("out"), err: base("err") };
    if sys::answers(&paths.sock) {
        return Err(format!("{} is already kept by a runner: {} answers", args.id, paths.sock.display()));
    }
    paths.remove();
    let started = (|| {
        let listener = Listener::bind(&paths.sock)?;
        let create = |path: &Path| {
            sys::create_file(OpenOptions::new().write(true).create(true).truncate(true)).open(path).map_err(|e| format!("cannot create {}: {e}", path.display()))
        };
        let (out, err) = (create(&paths.out)?, create(&paths.err)?);
        let open = |path: &Path| File::open(path).map_err(|e| format!("cannot open {}: {e}", path.display()));
        let files = [open(&paths.out)?, open(&paths.err)?];

        let started_at = now_ms();
        let (mut child, agent) = sys::spawn(&args.program, &args.args, args.cwd.as_deref()).map_err(|e| format!("cannot start {}: {e}", args.program))?;
        let pid = agent.pid();
        let text = |path: &Path| path.to_string_lossy().into_owned();
        let info = json!({
            "id": args.id,
            "runner": std::process::id(),
            "pid": pid,
            "pgid": pid,
            "startedAt": started_at,
            "program": args.program,
            "args": args.args,
            "socket": text(&paths.sock),
            "out": text(&paths.out),
            "err": text(&paths.err),
        });
        if let Err(e) = write_atomic(&paths.json, &format!("{info}\n")) {
            agent.abandon();
            return Err(e);
        }

        let (stdin_tx, stdin_rx) = mpsc::channel();
        let shared = Arc::new(Shared {
            state: Mutex::new(State::default()),
            changed: Condvar::new(),
            agent,
            paths: paths.clone(),
            files,
            stdin: stdin_tx,
            linger: args.linger,
            settle: args.settle,
        });
        let stdin = child.stdin.take();
        std::thread::spawn(move || feed(stdin, stdin_rx));
        for (i, (pipe, file)) in [(Box::new(child.stdout.take().unwrap()) as Box<dyn Read + Send>, out), (Box::new(child.stderr.take().unwrap()), err)].into_iter().enumerate() {
            let shared = shared.clone();
            std::thread::spawn(move || pump(&shared, i, pipe, file));
        }
        let waiting = shared.clone();
        std::thread::spawn(move || wait_agent(&waiting, child));

        let mut ready = info;
        ready["ready"] = json!(true);
        Ok((shared, listener, ready))
    })();
    let (shared, listener, ready) = started.inspect_err(|_| paths.remove())?;

    let mut stdout = io::stdout().lock();
    let _ = writeln!(stdout, "{ready}").and_then(|_| stdout.flush());
    drop(stdout);
    sys::detach_stdio();
    sys::ready();
    Ok((shared, listener))
}

fn write_atomic(path: &Path, text: &str) -> Result<(), String> {
    let tmp = path.with_extension("json.tmp");
    let written = sys::create_file(OpenOptions::new().write(true).create(true).truncate(true))
        .open(&tmp)
        .and_then(|mut file| file.write_all(text.as_bytes()).and_then(|_| file.sync_all()))
        .and_then(|_| fs::rename(&tmp, path));
    written.map_err(|e| {
        let _ = fs::remove_file(&tmp);
        format!("cannot write {}: {e}", path.display())
    })
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

impl Shared {
    fn lock(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// The station is done with it: the files go and the runner ends.
    fn finish(&self) -> ! {
        self.paths.remove();
        std::process::exit(0);
    }
}

/// Writes what the station sends to the agent's stdin, in order, off the connection's thread (an agent that is not
/// reading must not hold up a `signal`). `None` closes it.
fn feed(mut stdin: Option<ChildStdin>, rx: Receiver<Option<Vec<u8>>>) {
    for message in rx {
        match message {
            Some(bytes) => {
                if let Some(pipe) = stdin.as_mut()
                    && pipe.write_all(&bytes).is_err()
                {
                    stdin = None; // it went away; its exit says so
                }
            }
            None => stdin = None,
        }
    }
}

/// Copies one of the agent's output pipes into its file, telling the connection each time there is more.
fn pump(shared: &Shared, i: usize, mut pipe: Box<dyn Read + Send>, file: File) {
    let mut buf = vec![0u8; CHUNK];
    loop {
        let n = match pipe.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(_) => break,
        };
        // Written at the stream's length, so a failed write (disk full) leaves no gap: what is lost is lost whole,
        // and offsets stay those of the file.
        let at = shared.lock().len[i];
        if sys::write_all_at(&file, &buf[..n], at).is_ok() {
            shared.lock().len[i] += n as u64;
            shared.changed.notify_all();
        }
    }
    shared.lock().eof[i] = true;
    shared.changed.notify_all();
}

/// Waits for the agent to exit, lets its output end, then for a `done`; cleans up by itself after the linger.
fn wait_agent(shared: &Shared, child: Child) {
    let exit = shared.agent.wait(child, || shared.lock().exiting = true);

    let mut st = shared.lock();
    st.exit = Some(exit);
    let settle_by = Instant::now() + shared.settle;
    while !(st.eof[0] && st.eof[1]) {
        let left = settle_by.saturating_duration_since(Instant::now());
        if left.is_zero() {
            break;
        }
        st = shared.changed.wait_timeout(st, left).unwrap_or_else(|e| e.into_inner()).0;
    }
    st.settled = true;
    shared.changed.notify_all();
    if st.done {
        shared.finish();
    }
    let linger_until = Instant::now() + shared.linger;
    loop {
        let left = linger_until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            shared.finish();
        }
        st = shared.changed.wait_timeout(st, left).unwrap_or_else(|e| e.into_inner()).0;
    }
}

/// One station at a time: a connection is the station's from its first message on, and closes the one before. One that
/// says nothing changes nothing: it only asks whether the runner is there (`sys::answers`, and the station's same look).
fn serve(shared: Arc<Shared>, listener: Listener) {
    loop {
        let stream = match listener.accept() {
            Ok(stream) => stream,
            Err(_) => {
                std::thread::sleep(Duration::from_millis(100)); // out of descriptors, say: not a spin
                continue;
            }
        };
        let shared = shared.clone();
        std::thread::spawn(move || connection(&shared, stream));
    }
}

/// Makes `stream` the station's connection, closing the one before; its number.
fn take_over(shared: &Arc<Shared>, stream: &Conn, writer: &Arc<Mutex<Conn>>) -> u64 {
    let conn = {
        let mut st = shared.lock();
        if let Some(old) = st.current.take() {
            old.shutdown();
        }
        st.conn += 1;
        st.push = None;
        st.current = stream.try_clone().ok();
        shared.changed.notify_all();
        st.conn
    };
    let (shared, writer) = (shared.clone(), writer.clone());
    std::thread::spawn(move || push(&shared, conn, &writer));
    conn
}

fn connection(shared: &Arc<Shared>, stream: Conn) {
    let Ok(writer) = stream.try_clone() else { return };
    let writer = Arc::new(Mutex::new(writer));
    let mut reader = BufReader::new(stream);
    let mut line = Vec::new();
    let mut conn = None;
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => break,
            Ok(_) => {}
        }
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        if conn.is_none() {
            conn = Some(take_over(shared, reader.get_ref(), &writer));
        }
        if Some(shared.lock().conn) != conn {
            break;
        }
        match handle(shared, &line) {
            Ok(Next::Read) => {}
            Ok(Next::Leave) => break,
            Err(e) => {
                let _ = send(&writer, &json!({"op": "error", "error": e}));
            }
        }
    }
    let mut st = shared.lock();
    if Some(st.conn) == conn {
        st.conn += 1;
        st.push = None;
        st.current = None;
        shared.changed.notify_all();
    }
}

/// After a message: read on, or end the connection.
enum Next {
    Read,
    Leave,
}

fn handle(shared: &Shared, line: &[u8]) -> Result<Next, String> {
    let message: Value = serde_json::from_slice(line).map_err(|e| format!("bad message: {e}"))?;
    match message["op"].as_str().ok_or("message has no op")? {
        "attach" => {
            let mut st = shared.lock();
            st.epoch += 1;
            st.push = Some(Push { epoch: st.epoch, at: st.acked, exit_sent: false });
            // A station that attaches wants it again.
            st.done = false;
            shared.changed.notify_all();
        }
        "ack" => {
            let mut st = shared.lock();
            let mut acked = st.acked;
            for (i, stream) in STREAMS.iter().enumerate() {
                let Some(n) = message.get(*stream) else { continue };
                let n = n.as_u64().ok_or_else(|| format!("ack: {stream} is not a byte offset"))?;
                if n > st.len[i] {
                    return Err(format!("ack: {stream} {n} is past the {} bytes there are", st.len[i]));
                }
                acked[i] = acked[i].max(n);
            }
            st.acked = acked;
        }
        "write" => {
            let data = message["data"].as_str().ok_or("write: no data")?;
            let bytes = B64.decode(data).map_err(|e| format!("write: data is not base64: {e}"))?;
            let _ = shared.stdin.send(Some(bytes));
        }
        "close_stdin" => {
            let _ = shared.stdin.send(None);
        }
        "signal" => {
            let signal = match message["signal"].as_str() {
                Some("TERM") => Signal::Term,
                Some("KILL") => Signal::Kill,
                Some("INT") => Signal::Int,
                other => return Err(format!("signal: unknown signal {other:?}")),
            };
            let group = message["group"].as_bool().unwrap_or(false);
            // Held across the signal: the agent is not reaped meanwhile (see wait_agent).
            let st = shared.lock();
            shared.agent.signal(signal, group, st.exiting)?;
        }
        "done" => {
            let mut st = shared.lock();
            if st.exit.is_some() {
                shared.finish();
            }
            st.done = true;
        }
        // The station is letting go: what it sent before has been handled, and the connection ends, as a socket's
        // does once read to the end of a shutdown (a Windows pipe cannot be shut down one way).
        "leave" => return Ok(Next::Leave),
        other => return Err(format!("unknown op {other:?}")),
    }
    Ok(Next::Read)
}

/// Sends the attached connection what it has not had: each stream from its cursor, in order, then the exit.
fn push(shared: &Shared, conn: u64, writer: &Mutex<Conn>) {
    enum Work {
        Out { i: usize, at: u64, n: usize },
        Exit(Value),
    }
    let mut buf = vec![0u8; CHUNK];
    // Turns between the streams, so a busy one does not hold the other back.
    let mut first = 0;
    loop {
        let (work, epoch) = {
            let mut st = shared.lock();
            loop {
                if st.conn != conn {
                    return;
                }
                if let Some(p) = &st.push {
                    let next = [first, 1 - first].into_iter().find(|&i| p.at[i] < st.len[i]);
                    if let Some(i) = next {
                        let n = (st.len[i] - p.at[i]).min(CHUNK as u64) as usize;
                        break (Work::Out { i, at: p.at[i], n }, p.epoch);
                    }
                    if st.settled && !p.exit_sent {
                        break (Work::Exit(st.exit.clone().unwrap()), p.epoch);
                    }
                }
                st = shared.changed.wait(st).unwrap_or_else(|e| e.into_inner());
            }
        };
        let sent = match &work {
            Work::Out { i, at, n } => {
                first = 1 - i;
                if sys::read_exact_at(&shared.files[*i], &mut buf[..*n], *at).is_err() {
                    return;
                }
                send(writer, &json!({"op": "out", "stream": STREAMS[*i], "at": at, "data": B64.encode(&buf[..*n])}))
            }
            Work::Exit(exit) => send(writer, exit),
        };
        if sent.is_err() {
            return;
        }
        let mut st = shared.lock();
        if let Some(p) = st.push.as_mut().filter(|p| p.epoch == epoch) {
            match work {
                Work::Out { i, at, n } => p.at[i] = at + n as u64,
                Work::Exit(_) => p.exit_sent = true,
            }
        }
    }
}

fn send(writer: &Mutex<Conn>, message: &Value) -> io::Result<()> {
    let mut line = message.to_string();
    line.push('\n');
    writer.lock().unwrap_or_else(|e| e.into_inner()).write_all(line.as_bytes())
}
