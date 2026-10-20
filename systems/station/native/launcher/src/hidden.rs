//! stillfail-station-w: the launcher as Windows starts it at logon (a scheduled task, install.ps1), with no window. A
//! console program started by no console gets a window of its own; this one is a GUI program, which gets none, and runs
//! `stillfail-station` (beside it) with the same arguments, no window either, its output appended to the data
//! directory's stillfail.log, and exits with its code. Elsewhere there is nothing for it to do.
//!
//! `--run <program> <args…>` runs that program instead, no window and no output kept: the station's update, run apart
//! from it by a scheduled task of its own (station/src/updates/updates.ts), which keeps its own log.

#![cfg_attr(windows, windows_subsystem = "windows")]

#[cfg(windows)]
fn main() {
    use std::fs::OpenOptions;
    use std::os::windows::process::CommandExt;
    use std::path::PathBuf;
    use std::process::{Command, Stdio};

    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() > 1 && args[0] == "--run" {
        let status = Command::new(&args[1]).args(&args[2..]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).creation_flags(CREATE_NO_WINDOW).status();
        std::process::exit(status.ok().and_then(|s| s.code()).unwrap_or(1));
    }
    let exe = std::env::current_exe().ok();
    let station = exe.as_ref().and_then(|e| e.parent()).map(|d| d.join("stillfail-station.exe")).unwrap_or_else(|| PathBuf::from("stillfail-station.exe"));
    // The log goes where the data is (--data, else ~\.stillfail), as the desktop app keeps it.
    let data = args.iter().position(|a| a == "--data").and_then(|i| args.get(i + 1)).map(PathBuf::from).unwrap_or_else(|| {
        PathBuf::from(std::env::var_os("USERPROFILE").unwrap_or_default()).join(".stillfail")
    });
    let _ = std::fs::create_dir_all(&data);
    let log = OpenOptions::new().create(true).append(true).open(data.join("stillfail.log"));
    let mut command = Command::new(&station);
    command.args(&args).stdin(Stdio::null()).creation_flags(CREATE_NO_WINDOW);
    if let Ok(log) = log {
        if let Ok(err) = log.try_clone() {
            command.stderr(err);
        }
        command.stdout(log);
    }
    let code = command.status().ok().and_then(|s| s.code()).unwrap_or(1);
    std::process::exit(code);
}

#[cfg(not(windows))]
fn main() {
    eprintln!("stillfail-station-w is Windows' (a launcher with no window); run stillfail-station");
    std::process::exit(2);
}
