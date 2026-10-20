//! `archive-rs pack|restore <room>`, `archive-rs file <room> <relative>` (the file's bytes on stdout, exit 3 when it is
//! not there), `archive-rs pack-file|restore-file <path>`: archive.rs as the Rust station runs it, under its lock.
#[allow(dead_code)]
mod archive;

use std::io::Write;
use std::path::Path;

fn main() -> anyhow::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let path = Path::new(&args[2]);
    match args[1].as_str() {
        "pack" => {
            let _lock = archive::lock(path)?;
            archive::pack_workspace_if(path, || true)?;
        }
        "restore" => {
            let _lock = archive::lock(path)?;
            archive::restore_workspace(path)?;
        }
        "file" => {
            let _lock = archive::lock(path)?;
            match archive::workspace_file(path, Path::new(&args[3]))? {
                Some(bytes) => std::io::stdout().write_all(&bytes)?,
                None => std::process::exit(3),
            }
        }
        "pack-file" => archive::pack_file_if(path, || true)?,
        "restore-file" => archive::restore_file(path)?,
        other => anyhow::bail!("unknown command {other}"),
    }
    Ok(())
}
