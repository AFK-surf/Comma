//! stillfail-station: the native launcher of the TypeScript station (docs/station-ts-native.md §2), with the Rust
//! station's command line (bin/stillfail, the desktop app and the installer call it).
//!
//! `run` is the launcher's own: it holds the data directory's lock, the two listening ports and the pid that
//! run/station.json names, and runs the station's Node process under it (run.rs), starting a new one beside it on
//! SIGUSR2 and letting the old one go once the new one is ready. Every other command is Node's: exec'd with the same
//! arguments. `handoff-version` says 2: a Rust station asked to hand over to this binary does not exec it.

mod data;
mod lifecycle;
mod log;
mod ports;
/// The entrances Windows' launcher keeps for Node (built and tested everywhere; run where Node cannot be handed sockets).
#[cfg_attr(unix, allow(dead_code))]
mod proxy;
#[cfg_attr(windows, path = "run_windows.rs")]
mod run;

use std::ffi::OsString;
#[cfg(unix)]
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};

/// Where Node and the station's script are in the release (`--app`).
#[cfg(unix)]
const NODE_IN_APP: &str = "node/bin/node";
/// Node's own Windows layout: node.exe at the top of its directory.
#[cfg(windows)]
const NODE_IN_APP: &str = "node/node.exe";
const MAIN_IN_APP: &str = "station/main.js";
/// Node to run instead of the release's (tests, development).
const NODE_VAR: &str = "STILLFAIL_NODE";
/// The handoff this binary reads: none of the Rust station's (which is 1).
const HANDOFF_VERSION: u32 = 2;
/// `run`'s exit when another station runs the data directory (the desktop app reads it: apps/desktop/src/station.ts).
const HELD: i32 = 3;

pub fn node(app: &Path) -> PathBuf {
    std::env::var_os(NODE_VAR).filter(|v| !v.is_empty()).map(PathBuf::from).unwrap_or_else(|| app.join(NODE_IN_APP))
}

pub fn main_js(app: &Path) -> PathBuf {
    app.join(MAIN_IN_APP)
}

fn usage() -> ! {
    eprintln!("usage:\n  stillfail-station run --app DIR [--port N] [--data DIR] [--with-parent]\n  stillfail-station enroll <cloud-origin> <token> [--data DIR]\n  stillfail-station status [--data DIR]\n  stillfail-station id [--data DIR]\n  stillfail-station channel [stable|beta] [--app DIR] [--data DIR]\n  stillfail-station handoff-version\n\n--data: default ~/.stillfail ($STILLFAIL_DATA, else $EMBER_DATA); ~/.ember is moved there on the first start.\nrun: --app is the release; --port the loopback port's (default 4760, a free one when it is taken); --with-parent: end when the parent does.\n${NODE_VAR}: the Node to run instead of <app>/{NODE_IN_APP}.");
    std::process::exit(2);
}

fn main() {
    let given: Vec<OsString> = std::env::args_os().skip(1).collect();
    let mut args: Vec<String> = given.iter().map(|a| a.to_string_lossy().into_owned()).collect();
    // What follows `--` is the station's (the connector's flags): passed on to Node as it is.
    let rest: Vec<String> = match args.iter().position(|a| a == "--") {
        Some(i) => args.split_off(i).into_iter().skip(1).collect(),
        None => Vec::new(),
    };
    let mut take = |flag: &str| -> Option<String> {
        let i = args.iter().position(|a| a == flag)?;
        let value = args.get(i + 1).cloned();
        args.drain(i..(i + 2).min(args.len()));
        value
    };
    let data = take("--data");
    let app = take("--app");
    // What the Node part ran on, from launchers written before it went (older desktop apps): taken and let be.
    let _ = take("--node");
    let port = take("--port");
    let handoff = take("--handoff");
    let with_parent = args.iter().position(|a| a == "--with-parent").map(|i| args.remove(i)).is_some();
    match args.first().map(String::as_str) {
        Some("run") => {
            let Some(app) = app else { usage() };
            let named = port.is_some();
            let port = match port.map(|p| p.parse::<u16>()).transpose() {
                Ok(port) => port.unwrap_or(4760),
                Err(error) => {
                    eprintln!("--port: {error}");
                    std::process::exit(1);
                }
            };
            // A Rust station's handoff (its descriptors) is never ours to take: it asks handoff-version first.
            if let Some(file) = handoff {
                log::warn(&format!("a handoff file was given ({file}); this launcher reads none, starting afresh"));
                let _ = std::fs::remove_file(file);
            }
            let data = data::data_dir(&data::home(), data.or_else(|| data::var("DATA")).map(PathBuf::from));
            std::process::exit(run::run(run::Options { data, app: PathBuf::from(app), port, named, with_parent, rest }));
        }
        Some("handoff-version") => println!("{HANDOFF_VERSION}"),
        // The connector's commands (`comma` for the agents, Computer Use for the app) are Node's too.
        Some("enroll" | "status" | "id" | "channel" | "comma-client" | "computer-use") => {
            let app = app.map(PathBuf::from).or_else(app_of_this_binary).unwrap_or_else(|| {
                eprintln!("the release this binary belongs to (with {MAIN_IN_APP}) was not found; give it as --app DIR");
                std::process::exit(1);
            });
            let mut command = std::process::Command::new(node(&app));
            command.arg(main_js(&app)).args(&given);
            #[cfg(unix)]
            let error = command.exec();
            // No exec on Windows: Node runs as a child, its code this process's.
            #[cfg(windows)]
            let error = match command.status() {
                Ok(status) => std::process::exit(status.code().unwrap_or(1)),
                Err(error) => error,
            };
            eprintln!("{} did not run: {error}", node(&app).display());
            std::process::exit(1);
        }
        _ => usage(),
    }
}

/// The release this binary is in, when not given (`stillfail status` gives none): the nearest directory above it that
/// has the station's script.
fn app_of_this_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    app_above(&exe)
}

fn app_above(exe: &Path) -> Option<PathBuf> {
    exe.ancestors().skip(1).find(|dir| main_js(dir).is_file()).map(Path::to_path_buf)
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_release_is_found_above_the_binary() {
        let dir = std::env::temp_dir().join(format!("launcher-app-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("station")).unwrap();
        std::fs::create_dir_all(dir.join("mesh/target/release")).unwrap();
        std::fs::write(dir.join("station/main.js"), "").unwrap();
        assert_eq!(super::app_above(&dir.join("mesh/target/release/stillfail-station")), Some(dir.clone()));
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(super::app_above(std::path::Path::new("/nowhere/at/all/x")), None);
    }
}
