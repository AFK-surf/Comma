#![cfg(windows)]

//! runner.rs's cases on Windows: small `cmd` agents (PowerShell where one must say a pid), the runner talked to over its
//! named pipe as a station would. As there, these wait for what the processes do, with no limit of time.

use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, Write};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

use base64::Engine;
use base64::engine::general_purpose::STANDARD as B64;
use serde_json::{Value, json};
use windows_sys::Win32::Foundation::{CloseHandle, STILL_ACTIVE};
use windows_sys::Win32::Storage::FileSystem::FlushFileBuffers;
use windows_sys::Win32::System::Threading::{
    GetExitCodeProcess, INFINITE, OpenProcess, PROCESS_QUERY_LIMITED_INFORMATION, PROCESS_TERMINATE, PROCESS_SYNCHRONIZE, TerminateProcess,
    WaitForSingleObject,
};

const BIN: &str = env!("CARGO_BIN_EXE_stillfail-runner");

fn tmpdir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("sfr-{}-{name}", std::process::id()));
    let _ = fs::remove_dir_all(&dir);
    dir
}

fn alive(pid: i64) -> bool {
    unsafe {
        let process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid as u32);
        if process.is_null() {
            return false;
        }
        let mut code = 0;
        let ok = GetExitCodeProcess(process, &mut code) != 0;
        CloseHandle(process);
        ok && code == STILL_ACTIVE as u32
    }
}

/// Waits for `pid` to end; one gone already is not found.
fn ends(pid: i64) {
    unsafe {
        let process = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid as u32);
        if !process.is_null() {
            WaitForSingleObject(process, INFINITE);
            CloseHandle(process);
        }
    }
}

fn kill(pid: i64) {
    unsafe {
        let process = OpenProcess(PROCESS_TERMINATE, 0, pid as u32);
        if !process.is_null() {
            TerminateProcess(process, 1);
            CloseHandle(process);
        }
    }
}

fn cmd(script: &str) -> Vec<String> {
    ["cmd", "/d", "/c", script].map(String::from).to_vec()
}

struct Runner {
    dir: PathBuf,
    info: Value,
    child: Option<Child>,
}

impl Runner {
    fn start(name: &str, script: &str) -> Runner {
        Runner::start_with(name, &[], &cmd(script))
    }

    fn start_with(name: &str, extra: &[&str], agent: &[String]) -> Runner {
        let dir = tmpdir(name);
        let mut child = Command::new(BIN)
            .args(["--dir", dir.to_str().unwrap(), "--id", "a"])
            .args(extra)
            .arg("--")
            .args(agent)
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let info = ready_line(child.stdout.take().unwrap());
        Runner { dir, info, child: Some(child) }
    }

    fn pid(&self, key: &str) -> i64 {
        self.info[key].as_i64().unwrap()
    }

    fn connect(&self) -> Client {
        let pipe = OpenOptions::new().read(true).write(true).open(self.info["socket"].as_str().unwrap()).unwrap();
        Client { reader: BufReader::new(pipe.try_clone().unwrap()), writer: pipe }
    }

    fn files(&self) -> Vec<String> {
        let mut names: Vec<String> = fs::read_dir(&self.dir).map(|d| d.map(|e| e.unwrap().file_name().into_string().unwrap()).collect()).unwrap_or_default();
        names.sort();
        names
    }

    fn exited(&mut self) -> i32 {
        self.child.as_mut().unwrap().wait().unwrap().code().unwrap_or(-1)
    }
}

impl Drop for Runner {
    fn drop(&mut self) {
        kill(self.pid("pid"));
        kill(self.pid("runner"));
        if let Some(child) = self.child.as_mut() {
            let _ = child.wait();
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn ready_line(stdout: impl std::io::Read) -> Value {
    let mut reader = BufReader::new(stdout);
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let info: Value = serde_json::from_str(&line).unwrap_or_else(|e| panic!("ready line {line:?}: {e}"));
    assert_eq!(info["ready"], json!(true));
    let mut rest = String::new();
    reader.read_line(&mut rest).unwrap();
    assert_eq!(rest, "", "stdout closes after the ready line");
    info
}

struct Client {
    reader: BufReader<File>,
    writer: File,
}

impl Client {
    fn send(&mut self, message: Value) {
        self.writer.write_all(format!("{message}\n").as_bytes()).unwrap();
    }

    fn recv(&mut self) -> Option<Value> {
        let mut line = String::new();
        match self.reader.read_line(&mut line) {
            Ok(0) => None,
            Ok(_) => Some(serde_json::from_str(&line).unwrap()),
            Err(e) if e.kind() == std::io::ErrorKind::BrokenPipe || e.raw_os_error() == Some(233) => None,
            Err(e) => panic!("reading from the runner: {e}"),
        }
    }

    /// A pipe has no half close: `leave` asks the runner to end the connection once it has read up to it, which is
    /// what reading to the end after a shutdown is on a socket.
    fn leave(mut self) {
        self.send(json!({"op": "leave"}));
        unsafe { FlushFileBuffers(self.writer.as_raw_handle() as _) };
        while self.recv().is_some() {}
    }

    fn write(&mut self, data: &[u8]) {
        self.send(json!({"op": "write", "data": B64.encode(data)}));
    }

    fn read_until(&mut self, at: &mut [u64; 2], got: &mut [Vec<u8>; 2], stream: usize, want: usize) {
        while got[stream].len() < want {
            let message = self.recv().expect("connection ended");
            assert_eq!(message["op"], "out", "{message}");
            self.take(message, at, got);
        }
    }

    fn take(&mut self, message: Value, at: &mut [u64; 2], got: &mut [Vec<u8>; 2]) {
        let i = match message["stream"].as_str() {
            Some("out") => 0,
            Some("err") => 1,
            other => panic!("stream {other:?}"),
        };
        assert_eq!(message["at"].as_u64().unwrap(), at[i], "offsets run on: {message}");
        let data = B64.decode(message["data"].as_str().unwrap()).unwrap();
        at[i] += data.len() as u64;
        got[i].extend(data);
    }

    fn until_exit(&mut self, mut at: [u64; 2]) -> ([Vec<u8>; 2], Value) {
        let mut got = [vec![], vec![]];
        loop {
            let message = self.recv().expect("connection ended before the exit");
            if message["op"] == "exit" {
                return (got, message);
            }
            assert_eq!(message["op"], "out", "{message}");
            self.take(message, &mut at, &mut got);
        }
    }

    fn handled(&mut self) {
        self.send(json!({"op": "nothing"}));
        let said = self.recv().expect("connection ended");
        assert_eq!(said["error"], "unknown op \"nothing\"", "{said}");
    }
}

#[test]
fn the_ready_line_says_where_everything_is() {
    let runner = Runner::start("ready", "set /p x=");
    let info = &runner.info;
    let dir = runner.dir.to_str().unwrap();
    assert_eq!(info["id"], "a");
    assert_eq!(info["program"], "cmd");
    let socket = info["socket"].as_str().unwrap();
    assert!(socket.starts_with(r"\\.\pipe\stillfail-runner-") && socket.ends_with("-a"), "{socket}");
    assert_eq!(info["out"], format!(r"{dir}\a.out"));
    assert_eq!(info["err"], format!(r"{dir}\a.err"));
    assert_eq!(info["runner"].as_u64().unwrap(), runner.child.as_ref().unwrap().id() as u64);
    assert_eq!(info["pid"], info["pgid"]);
    assert_ne!(info["pid"], info["runner"]);
    let mut on_disk: Value = serde_json::from_str(&fs::read_to_string(runner.dir.join("a.json")).unwrap()).unwrap();
    on_disk["ready"] = json!(true);
    assert_eq!(&on_disk, info);
    // The pipe is no file of the directory.
    assert_eq!(runner.files(), ["a.err", "a.json", "a.out"]);
}

#[test]
fn output_comes_with_its_offsets_then_the_exit_and_again_on_the_next_attach() {
    let runner = Runner::start("offsets", "<nul set /p =abc& 1>&2 <nul set /p =def& ping -n 1 127.0.0.1 >nul& <nul set /p =ghi& 1>&2 <nul set /p =jk& exit /b 3");
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    let ([out, err], exit) = client.until_exit([0, 0]);
    assert_eq!(out, b"abcghi");
    assert_eq!(err, b"defjk");
    assert_eq!(exit, json!({"op": "exit", "code": 3, "signal": null}));
    assert_eq!(fs::read(runner.dir.join("a.out")).unwrap(), b"abcghi");
    assert_eq!(fs::read(runner.dir.join("a.err")).unwrap(), b"defjk");
    let mut again = runner.connect();
    again.send(json!({"op": "attach"}));
    let ([out, err], exit) = again.until_exit([0, 0]);
    assert_eq!((out.as_slice(), err.as_slice()), (&b"abcghi"[..], &b"defjk"[..]));
    assert_eq!(exit["code"], 3);
}

#[test]
fn the_exit_comes_once_the_output_had_its_time_though_a_child_holds_it_open() {
    // `start /b` leaves a ping holding the agent's output open after it exits.
    let runner = Runner::start_with("held", &["--settle-ms", "0"], &cmd("start /b ping -n 600 127.0.0.1& exit /b 0"));
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    let (_, exit) = client.until_exit([0, 0]);
    assert_eq!(exit["code"], 0);
    client.send(json!({"op": "signal", "signal": "KILL", "group": true}));
}

#[test]
fn a_second_connection_attaching_resumes_from_the_ack() {
    let runner = Runner::start("ack", "echo one& set /p x=& echo two");
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    let (mut at, mut got) = ([0, 0], [vec![], vec![]]);
    client.read_until(&mut at, &mut got, 0, 5);
    assert_eq!(got[0], b"one\r\n");
    client.send(json!({"op": "ack", "out": 9, "err": 0}));
    assert_eq!(client.recv().unwrap()["op"], "error", "an ack past the end is refused");
    client.send(json!({"op": "ack", "out": 2, "err": 0}));
    client.leave();

    let mut second = runner.connect();
    second.send(json!({"op": "attach"}));
    let (mut at, mut got) = ([2, 0], [vec![], vec![]]);
    second.read_until(&mut at, &mut got, 0, 3);
    assert_eq!(got[0], b"e\r\n");
    second.send(json!({"op": "ack", "out": 5}));
    second.leave();

    let mut third = runner.connect();
    third.send(json!({"op": "attach"}));
    third.handled();
    third.write(b"go\r\n");
    let ([out, _], exit) = third.until_exit([5, 0]);
    assert_eq!(out, b"two\r\n");
    assert_eq!(exit["code"], 0);
}

#[test]
fn stdin_is_written_and_closed() {
    let runner = Runner::start("stdin", "set /p x=& call echo %x%& set /p y=& echo end");
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    client.write(b"hello\r\n");
    let (mut at, mut got) = ([0, 0], [vec![], vec![]]);
    client.read_until(&mut at, &mut got, 0, 7);
    assert_eq!(got[0], b"hello\r\n");
    client.send(json!({"op": "write", "data": "not base64!"}));
    assert_eq!(client.recv().unwrap()["op"], "error");
    client.send(json!({"op": "close_stdin"}));
    let ([out, _], exit) = client.until_exit(at);
    assert_eq!(out, b"end\r\n");
    assert_eq!(exit["code"], 0);
}

/// The agent starts a ping and says its pid.
fn agent_with_grandchild(name: &str) -> (Runner, Client, i64) {
    let script = "$p = Start-Process ping.exe -ArgumentList '-n','600','127.0.0.1' -NoNewWindow -PassThru -RedirectStandardOutput NUL; $p.Id; Wait-Process -Id $p.Id";
    let agent = ["powershell", "-NoProfile", "-NonInteractive", "-Command", script].map(String::from);
    let runner = Runner::start_with(name, &[], &agent);
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    let mut got = [vec![], vec![]];
    let mut at = [0, 0];
    while !got[0].ends_with(b"\n") {
        let want = got[0].len() + 1;
        client.read_until(&mut at, &mut got, 0, want);
    }
    let grandchild: i64 = String::from_utf8(got[0].clone()).unwrap().trim().parse().unwrap();
    assert!(alive(grandchild));
    (runner, client, grandchild)
}

#[test]
fn signal_to_the_group_takes_the_grandchild_too() {
    let (_runner, mut client, grandchild) = agent_with_grandchild("group");
    client.send(json!({"op": "signal", "signal": "TERM", "group": true}));
    let (_, exit) = client.until_exit([0, 0]);
    assert_eq!(exit, json!({"op": "exit", "code": null, "signal": "TERM"}));
    ends(grandchild);
    client.send(json!({"op": "signal", "signal": "TERM"}));
    assert_eq!(client.recv().unwrap()["error"], "signal: the agent has exited");
    client.send(json!({"op": "signal", "signal": "STOP"}));
    assert_eq!(client.recv().unwrap()["op"], "error");
}

#[test]
fn signal_to_the_agent_alone_leaves_the_grandchild() {
    let (runner, mut client, grandchild) = agent_with_grandchild("alone");
    client.send(json!({"op": "signal", "signal": "KILL", "group": false}));
    let (_, exit) = client.until_exit([0, 0]);
    assert_eq!(exit["signal"], "KILL");
    assert!(alive(grandchild), "only the agent was ended");
    // Its job outlives it: what it started can still be ended through it.
    client.send(json!({"op": "signal", "signal": "KILL", "group": true}));
    ends(grandchild);
    drop(runner);
}

#[test]
fn done_after_the_exit_removes_the_files_and_ends_the_runner() {
    let mut runner = Runner::start("done", "<nul set /p =hi");
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    let ([out, _], _) = client.until_exit([0, 0]);
    assert_eq!(out, b"hi");
    client.send(json!({"op": "done"}));
    assert_eq!(runner.exited(), 0);
    assert!(runner.files().is_empty(), "{:?}", runner.files());
    assert!(client.recv().is_none());
}

#[test]
fn done_while_running_ends_nothing_and_cleans_up_once_the_agent_exits() {
    let mut runner = Runner::start("done-early", "set /p x=");
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    client.send(json!({"op": "done"}));
    client.handled();
    assert!(alive(runner.pid("pid")));
    assert_eq!(runner.files().len(), 3);
    client.write(b"x\r\n");
    assert_eq!(runner.exited(), 0);
    assert!(runner.files().is_empty(), "{:?}", runner.files());
}

#[test]
fn a_new_connection_replaces_the_old() {
    let runner = Runner::start("replace", "set /p x=& call echo %x%");
    let mut first = runner.connect();
    first.send(json!({"op": "attach"}));
    first.handled();
    let mut second = runner.connect();
    second.send(json!({"op": "attach"}));
    assert!(first.recv().is_none(), "the old connection is closed");
    second.write(b"hi\r\n");
    let ([out, _], exit) = second.until_exit([0, 0]);
    assert_eq!(out, b"hi\r\n");
    assert_eq!(exit["code"], 0);
}

#[test]
fn after_the_exit_without_done_it_cleans_up_by_itself() {
    let mut runner = Runner::start_with("linger", &["--linger-ms", "300"], &cmd("exit /b 0"));
    assert_eq!(runner.exited(), 0);
    assert!(runner.files().is_empty(), "{:?}", runner.files());
}

#[test]
fn the_runner_and_its_agent_outlive_the_process_that_started_it() {
    // The starter is killed while the agent runs, as a station crashing would be.
    let dir = tmpdir("parent");
    let mut starter = Command::new("cmd")
        .args(["/d", "/c"])
        // Quoted whole: cmd takes the outer quotes off (more than two quotes in all).
        .raw_arg(format!("\"\"{BIN}\" --dir {} --id a -- cmd /d /c \"set /p x=& call echo got %x%\"& ping -n 600 127.0.0.1 >nul\"", dir.display()))
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(starter.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let info: Value = serde_json::from_str(&line).unwrap_or_else(|e| panic!("ready line {line:?}: {e}"));
    starter.kill().unwrap();
    starter.wait().unwrap();
    let runner = Runner { dir, info, child: None };
    assert!(alive(runner.pid("runner")));
    assert!(alive(runner.pid("pid")));
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    client.write(b"hi\r\n");
    let ([out, _], exit) = client.until_exit([0, 0]);
    assert_eq!(out, b"got hi\r\n");
    assert_eq!(exit["code"], 0);
}

#[test]
fn a_start_that_fails_says_why_and_leaves_nothing() {
    let dir = tmpdir("fail");
    let out = Command::new(BIN).args(["--dir", dir.to_str().unwrap(), "--id", "a", "--", r"C:\nonexistent\agent.exe"]).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(out.stdout.is_empty());
    assert!(String::from_utf8_lossy(&out.stderr).contains(r"cannot start C:\nonexistent\agent.exe"), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(fs::read_dir(&dir).unwrap().count(), 0);
    let _ = fs::remove_dir_all(&dir);

    let usage = Command::new(BIN).args(["--id", "a", "--", "cmd"]).output().unwrap();
    assert_eq!(usage.status.code(), Some(2));
    let bad = Command::new(BIN).args(["--dir", dir.to_str().unwrap(), "--id", r"a\b", "--", "cmd"]).output().unwrap();
    assert_eq!(bad.status.code(), Some(2));
}

#[test]
fn a_second_runner_for_a_live_id_is_refused() {
    let runner = Runner::start("twice", "set /p x= & call echo %x%");
    let mut station = runner.connect();
    station.send(json!({"op": "attach"}));
    station.handled();
    let out = Command::new(BIN).args(["--dir", runner.dir.to_str().unwrap(), "--id", "a", "--", "cmd", "/c", "exit"]).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&out.stderr).contains("a is already kept by a runner"), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(alive(runner.pid("pid")));
    assert_eq!(runner.files().len(), 3);
    // Asked whether it is there, it let its station be: the agent is still that station's to write to and hear.
    station.write(b"hi
");
    let ([out, _], exit) = station.until_exit([0, 0]);
    assert_eq!(String::from_utf8_lossy(&out).trim(), "hi");
    assert_eq!(exit["code"], 0);
}

#[test]
fn a_record_whose_pid_is_another_process_now_does_not_refuse_a_start() {
    // What a runner left that is no more (killed, or of another boot of the machine): its record, naming a pid that is
    // now another process's (this test's), and its output. No pipe answers.
    let dir = tmpdir("stale");
    fs::create_dir_all(&dir).unwrap();
    let record = json!({"id": "a", "runner": std::process::id(), "pid": std::process::id(), "pgid": std::process::id()});
    fs::write(dir.join("a.json"), format!("{record}
")).unwrap();
    fs::write(dir.join("a.out"), "what it said then
").unwrap();
    let mut child = Command::new(BIN)
        .args(["--dir", dir.to_str().unwrap(), "--id", "a", "--"])
        .args(cmd("set /p x= & call echo %x%"))
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let info = ready_line(child.stdout.take().unwrap());
    let runner = Runner { dir, info, child: Some(child) };
    assert_ne!(runner.pid("runner"), std::process::id() as i64);
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    client.write(b"hi
");
    let ([out, _], exit) = client.until_exit([0, 0]);
    assert_eq!(String::from_utf8_lossy(&out).trim(), "hi", "its output is its own, not what the one before left");
    assert_eq!(exit["code"], 0);
}

#[test]
fn a_bare_name_is_found_on_path_as_a_shell_would_a_cmd_too() {
    // npm puts `codex` there as `codex.cmd`.
    let bin = tmpdir("pathext-bin");
    fs::create_dir_all(&bin).unwrap();
    // As npm's shims pass them on: `%*`, the arguments as Rust quoted them for cmd.
    fs::write(bin.join("sayit.cmd"), "@echo said %*\r\n").unwrap();
    let dir = tmpdir("pathext");
    let path = format!("{};{}", bin.display(), std::env::var("PATH").unwrap());
    let mut child = Command::new(BIN)
        .args(["--dir", dir.to_str().unwrap(), "--id", "a", "--", "sayit", "a b&c"])
        .env("PATH", path)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let info = ready_line(child.stdout.take().unwrap());
    let runner = Runner { dir, info, child: Some(child) };
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    let ([out, _], exit) = client.until_exit([0, 0]);
    assert_eq!(String::from_utf8_lossy(&out), "said \"a b&c\"\r\n");
    assert_eq!(exit["code"], 0);
    let _ = fs::remove_dir_all(&bin);
}

/// npm's shim for a package's command, as cmd-shim writes it.
const NPM_SHIM: &str = "@ECHO off\r\nGOTO start\r\n:find_dp0\r\nSET dp0=%~dp0\r\nEXIT /b\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\r\nIF EXIST \"%dp0%\\node.exe\" (\r\n  SET \"_prog=%dp0%\\node.exe\"\r\n) ELSE (\r\n  SET \"_prog=node\"\r\n  SET PATHEXT=%PATHEXT:;.JS;=;%\r\n)\r\n\r\nendLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  \"%dp0%\\node_modules\\said\\cli.js\" %*\r\n";

#[test]
fn an_npm_shim_runs_its_script_with_node_so_a_newline_in_an_argument_gets_through() {
    // cmd cannot pass a newline (Rust refuses to try); an agent's instructions have them. Vite+'s shim hands on to npm's.
    let bin = tmpdir("shim-bin");
    let npm = bin.join("npm");
    fs::create_dir_all(npm.join("node_modules").join("said")).unwrap();
    fs::write(npm.join("node_modules").join("said").join("cli.js"), "process.stdout.write(JSON.stringify(process.argv.slice(2)))").unwrap();
    fs::write(npm.join("said.cmd"), NPM_SHIM).unwrap();
    fs::write(bin.join("said.cmd"), format!("@echo off\r\n\"{}\" %*\r\nexit /b %ERRORLEVEL%\r\n", npm.join("said.cmd").display())).unwrap();
    let dir = tmpdir("shim");
    let path = format!("{};{}", bin.display(), std::env::var("PATH").unwrap());
    let mut child = Command::new(BIN)
        .args(["--dir", dir.to_str().unwrap(), "--id", "a", "--", "said", "two\nlines", "100%", "\"quoted\""])
        .env("PATH", path)
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let info = ready_line(child.stdout.take().unwrap());
    let runner = Runner { dir, info, child: Some(child) };
    let mut client = runner.connect();
    client.send(json!({"op": "attach"}));
    let ([out, _], exit) = client.until_exit([0, 0]);
    assert_eq!(String::from_utf8_lossy(&out), r#"["two\nlines","100%","\"quoted\""]"#);
    assert_eq!(exit["code"], 0);
    let _ = fs::remove_dir_all(&bin);
}

#[test]
fn what_the_starter_holds_inheritable_is_not_held_by_the_runner_or_its_agent() {
    // A pipe's write end the starter has as inheritable (as Node's own stdio is when it starts the runner): Windows hands
    // it down, and the runner (and so its agent) would keep it open while they live.
    let (mut read, write) = std::io::pipe().unwrap();
    unsafe {
        windows_sys::Win32::Foundation::SetHandleInformation(write.as_raw_handle() as _, windows_sys::Win32::Foundation::HANDLE_FLAG_INHERIT, 1)
    };
    let runner = Runner::start("inherit", "set /p x=");
    drop(write);
    // Nobody else holds it: its end comes, though the runner and the agent run on.
    let mut rest = Vec::new();
    std::io::Read::read_to_end(&mut read, &mut rest).unwrap();
    assert!(alive(runner.pid("runner")) && alive(runner.pid("pid")));
}

/// `--job`: a command and what it starts, held as a process group holds them on Unix.
fn job(script: &str) -> Child {
    Command::new(BIN).args(["--job", "--", "cmd", "/d", "/c", script]).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap()
}

#[test]
fn a_job_says_what_its_command_says_and_ends_with_its_code() {
    let out = job("echo hi& 1>&2 echo there& exit /b 7").wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(7));
    assert_eq!(String::from_utf8_lossy(&out.stdout), "hi\r\n");
    assert_eq!(String::from_utf8_lossy(&out.stderr), "there\r\n");
}

#[test]
fn a_job_ends_once_what_its_command_left_behind_has_ended_too() {
    // What cmd leaves behind outlives it (a ping, then a file written); the job is over once it ends (as a group lives
    // while a member does), so the file is there by then.
    let dir = tmpdir("left-behind");
    fs::create_dir_all(&dir).unwrap();
    let done = dir.join("done");
    let out = job(&format!("start /b cmd /d /c ping -n 2 127.0.0.1 ^>nul ^& echo done^>{}& exit /b 4", done.display())).wait_with_output().unwrap();
    assert_eq!(out.status.code(), Some(4));
    assert!(done.exists(), "the job ended before what its command left behind");
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn ending_a_job_ends_what_its_command_left_behind_whose_parent_is_gone() {
    // PowerShell starts a ping, says its pid and exits: the ping's parent is gone, so no process tree has it.
    let script = "$p = Start-Process ping.exe -ArgumentList '-n','600','127.0.0.1' -NoNewWindow -PassThru -RedirectStandardOutput NUL; $p.Id";
    let mut runner = Command::new(BIN)
        .args(["--job", "--", "powershell", "-NoProfile", "-NonInteractive", "-Command", script])
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut line = String::new();
    BufReader::new(runner.stdout.take().unwrap()).read_line(&mut line).unwrap();
    let ping: i64 = line.trim().parse().unwrap();
    assert!(alive(ping));
    // What the station does to end a job's group on Windows: end the runner that holds it.
    runner.kill().unwrap();
    runner.wait().unwrap();
    ends(ping);
}
