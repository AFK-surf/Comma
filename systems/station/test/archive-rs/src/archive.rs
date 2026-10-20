//! Cold storage for owned session workspaces and runtime transcripts. The caller holds the session lock and has
//! stopped its actor. Originals are removed only after a complete, checksummed archive has been read back.

use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

fn file_lock(path: &Path) -> Result<File> {
    let file = OpenOptions::new().read(true).write(true).create(true).truncate(false).mode(0o600).open(path)?;
    // SAFETY: file owns this descriptor; closing it releases the advisory lock, including after a crash.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
        return Err(io::Error::last_os_error().into());
    }
    Ok(file)
}

pub fn lock(room: &Path) -> Result<File> {
    file_lock(&room.join("archive.lock"))
}

struct Temporary(PathBuf);
impl Drop for Temporary {
    fn drop(&mut self) { let _ = fs::remove_file(&self.0); }
}

pub fn workspace_archive(room: &Path) -> PathBuf {
    room.join("workspace.tar.zst")
}

pub fn packed(path: &Path) -> PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(".zst");
    PathBuf::from(name)
}

/// The raw path stays the stable identity for readers and their offsets, even while its bytes are compressed.
pub fn storage(path: &Path) -> PathBuf {
    if path.exists() { path.to_path_buf() } else { packed(path) }
}

pub fn reader(path: &Path) -> Result<Box<dyn Read>> {
    match File::open(path) {
        Ok(file) => Ok(Box::new(file)),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(Box::new(zstd::Decoder::new(File::open(packed(path))?)?)),
        Err(e) => Err(e.into()),
    }
}

fn encoder(path: &Path) -> Result<zstd::Encoder<'static, File>> {
    let file = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(path)?;
    file.set_permissions(fs::Permissions::from_mode(0o600))?;
    let mut encoder = zstd::Encoder::new(file, 3)?;
    encoder.include_checksum(true)?;
    Ok(encoder)
}

/// Compress a transcript in place, leaving its filename discoverable as <original>.zst. Retry after a crash safely:
/// an original still there always wins over the old compressed copy.
#[cfg(test)]
pub fn pack_file(path: &Path) -> Result<()> { pack_file_if(path, || true) }

pub fn pack_file_if(path: &Path, ready: impl Fn() -> bool) -> Result<()> {
    let _lock = file_lock(&path.with_extension("jsonl.archive-lock"))?;
    if !fs::symlink_metadata(path).is_ok_and(|m| m.is_file()) {
        if packed(path).exists() { io::copy(&mut zstd::Decoder::new(File::open(packed(path))?)?, &mut io::sink())?; }
        return Ok(());
    }
    let dest = packed(path);
    let temp = dest.with_extension("zst.writing");
    let _temporary = Temporary(temp.clone());
    let mut out = encoder(&temp)?;
    io::copy(&mut File::open(path)?, &mut out)?;
    out.finish()?.sync_all()?;
    let mut verify = zstd::Decoder::new(File::open(&temp)?)?;
    let mut source = File::open(path)?;
    let (mut a, mut b) = ([0u8; 65536], [0u8; 65536]);
    loop {
        let n = source.read(&mut a)?;
        verify.read_exact(&mut b[..n])?;
        if a[..n] != b[..n] { bail!("transcript changed while archiving {}", path.display()); }
        if n == 0 { break; }
    }
    if verify.read(&mut b[..1])? != 0 { bail!("transcript shortened while archiving"); }
    if !ready() { return Ok(()) }
    fs::rename(&temp, &dest)?;
    File::open(dest.parent().unwrap())?.sync_all()?;
    fs::remove_file(path)?;
    Ok(())
}

pub fn restore_file(path: &Path) -> Result<()> {
    let _lock = file_lock(&path.with_extension("jsonl.archive-lock"))?;
    let source = packed(path);
    if !source.exists() { return Ok(()) }
    if path.exists() { return Ok(()) } // Never overwrite a runtime's newer transcript.
    let temp = path.with_extension("jsonl.restoring");
    let _temporary = Temporary(temp.clone());
    let mut out = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temp)?;
    io::copy(&mut zstd::Decoder::new(File::open(&source)?)?, &mut out)?;
    out.sync_all()?;
    fs::rename(&temp, path)?;
    File::open(path.parent().unwrap())?.sync_all()?;
    fs::remove_file(source)?;
    Ok(())
}

fn lock_worktrees(dir: &Path, marker: &str, locks: &mut Vec<PathBuf>) -> Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if entry.file_name() == ".git" {
            if entry.file_type()?.is_file() {
                if let Some(gitdir) = fs::read_to_string(&path)?.trim().strip_prefix("gitdir: ") {
                    let gitdir = dir.join(gitdir).canonicalize()?;
                    let locked = gitdir.join("locked");
                    match OpenOptions::new().write(true).create_new(true).open(&locked) {
                        Ok(mut file) => { file.write_all(marker.as_bytes())?; file.sync_all()?; locks.push(locked); }
                        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                            if fs::read_to_string(&locked).ok().as_deref() == Some(marker) && !locks.contains(&locked) {
                                locks.push(locked);
                            }
                        }
                        Err(e) => return Err(e.into()),
                    }
                }
            }
        } else if entry.file_type()?.is_dir() {
            lock_worktrees(&path, marker, locks)?;
        }
    }
    Ok(())
}

fn marker(room: &Path) -> String {
    format!("still.fail archived workspace: {}\n", room.display())
}

pub fn unlock_worktrees(room: &Path) -> Result<()> {
    let path = room.join("workspace-locks.json");
    if !path.exists() { return Ok(()) }
    let locks: Vec<PathBuf> = serde_json::from_slice(&fs::read(&path)?)?;
    for lock in locks {
        if fs::read_to_string(&lock).ok().as_deref() == Some(&marker(room)) {
            fs::remove_file(lock)?;
        }
    }
    fs::remove_file(path)?;
    Ok(())
}

fn snapshot(dir: &Path, files: &mut std::collections::BTreeMap<PathBuf, (u64, std::time::SystemTime)>) -> Result<()> {
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let meta = fs::symlink_metadata(entry.path())?;
        files.insert(entry.path(), (meta.len(), meta.modified()?));
        if meta.is_dir() { snapshot(&entry.path(), files)?; }
    }
    Ok(())
}

#[cfg(test)]
pub fn pack_workspace(room: &Path) -> Result<()> { pack_workspace_if(room, || true) }

pub fn pack_workspace_if(room: &Path, ready: impl Fn() -> bool) -> Result<()> {
    let archive = workspace_archive(room);
    if archive.exists() { return Ok(()) }
    let workspace = room.join("workspace");
    if !workspace.is_dir() { return Ok(()) }
    let temp = room.join("workspace.tar.zst.writing");
    let _temporary = Temporary(temp.clone());
    let locks_path = room.join("workspace-locks.json");
    let mut locks: Vec<PathBuf> = if locks_path.exists() { serde_json::from_slice(&fs::read(&locks_path)?)? } else { vec![] };
    // Keep registered worktrees out of `git worktree prune` while their .git files are inside the archive.
    let locked = lock_worktrees(&workspace, &marker(room), &mut locks);
    let mut saved_locks = File::create(&locks_path)?;
    saved_locks.write_all(&serde_json::to_vec(&locks)?)?;
    saved_locks.sync_all()?;
    locked?;
    let mut before = std::collections::BTreeMap::new();
    snapshot(&workspace, &mut before)?;
    let mut tar = tar::Builder::new(encoder(&temp)?);
    tar.follow_symlinks(false);
    tar.append_dir_all(".", &workspace)?;
    tar.into_inner()?.finish()?.sync_all()?;
    // Read all entries, including the end of the zstd stream/checksum, before touching any originals.
    let mut decoder = zstd::Decoder::new(File::open(&temp)?)?;
    {
        let mut check = tar::Archive::new(&mut decoder);
        for entry in check.entries()? { io::copy(&mut entry?, &mut io::sink())?; }
    }
    io::copy(&mut decoder, &mut io::sink())?;
    let mut after = std::collections::BTreeMap::new();
    snapshot(&workspace, &mut after)?;
    if before != after { bail!("workspace changed while archiving; originals kept"); }
    if !ready() { unlock_worktrees(room)?; return Ok(()) }
    fs::rename(&temp, &archive)?;
    File::open(room)?.sync_all()?;
    let retiring = room.join("workspace.retiring");
    if retiring.exists() { bail!("an earlier workspace retirement needs restoration"); }
    fs::rename(&workspace, &retiring)?;
    fs::create_dir(&workspace)?;
    fs::set_permissions(&workspace, fs::metadata(&retiring)?.permissions())?;
    fs::remove_dir_all(retiring)?;
    Ok(())
}

/// Copy files created since the snapshot into the restored tree. Originals stay intact until the final swap, so an
/// interrupted/failed restoration can be retried without discarding new files or the archive.
fn overlay(source: &Path, dest: &Path) -> Result<()> {
    for entry in fs::read_dir(source)? {
        let entry = entry?;
        let from = entry.path();
        let into = dest.join(entry.file_name());
        let kind = entry.file_type()?;
        if kind.is_dir() {
            if fs::symlink_metadata(&into).is_ok_and(|m| !m.is_dir()) { bail!("restore path conflict: {}", into.display()); }
            fs::create_dir_all(&into)?;
            overlay(&from, &into)?;
        } else {
            if fs::symlink_metadata(&into).is_ok_and(|m| m.is_dir()) { bail!("restore path conflict: {}", into.display()); }
            if fs::symlink_metadata(&into).is_ok() { fs::remove_file(&into)?; }
            if kind.is_symlink() {
                std::os::unix::fs::symlink(fs::read_link(&from)?, &into)?;
            } else if kind.is_file() {
                fs::copy(&from, &into)?;
            } else { bail!("cannot restore special file {}", from.display()); }
        }
    }
    Ok(())
}

pub fn restore_workspace(room: &Path) -> Result<()> {
    let archive = workspace_archive(room);
    if !archive.exists() { return unlock_worktrees(room); }
    let stage = room.join("workspace.restoring");
    if stage.exists() { fs::remove_dir_all(&stage)?; }
    fs::create_dir(&stage)?;
    fs::set_permissions(&stage, fs::Permissions::from_mode(0o700))?;
    let mut tar = tar::Archive::new(zstd::Decoder::new(File::open(&archive)?)?);
    tar.set_preserve_permissions(true);
    tar.unpack(&stage).context("restoring the archived workspace")?;
    io::copy(&mut tar.into_inner(), &mut io::sink())?;
    let workspace = room.join("workspace");
    let retiring = room.join("workspace.retiring");
    let old = room.join("workspace.restored-old");
    for live in [&retiring, &old, &workspace] {
        if live.is_dir() { overlay(live, &stage)?; }
    }
    if old.exists() { fs::remove_dir_all(&old)?; }
    if workspace.exists() { fs::rename(&workspace, &old)?; }
    fs::rename(&stage, &workspace)?;
    File::open(room)?.sync_all()?;
    // Everything is now back at its original path. Any interrupted deletion is harmless on the next restore.
    if retiring.exists() { fs::remove_dir_all(&retiring)?; }
    if old.exists() { fs::remove_dir_all(&old)?; }
    fs::remove_file(archive)?;
    unlock_worktrees(room)?;
    Ok(())
}

/// An archived attachment is read directly from the tar stream, without inflating the whole workspace on disk.
pub fn workspace_file(room: &Path, relative: &Path) -> Result<Option<Vec<u8>>> {
    let archive = workspace_archive(room);
    if !archive.exists() { return Ok(None) }
    let mut tar = tar::Archive::new(zstd::Decoder::new(File::open(archive)?)?);
    for entry in tar.entries()? {
        let mut entry = entry?;
        let path = entry.path()?;
        if path.components().filter(|c| *c != std::path::Component::CurDir).eq(relative.components()) && entry.header().entry_type().is_file() {
            let mut bytes = vec![];
            entry.read_to_end(&mut bytes)?;
            return Ok(Some(bytes));
        }
    }
    Ok(None)
}

/// Logical JSONL names, including files whose raw bytes have been put away. Never follow directory symlinks.
pub fn jsonl_files(dir: &Path, out: &mut Vec<PathBuf>) -> Result<()> {
    if !dir.exists() { return Ok(()) }
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if entry.file_type()?.is_dir() {
            jsonl_files(&path, out)?;
        } else if entry.file_type()?.is_file() {
            let logical = if path.extension().is_some_and(|e| e == "zst") { path.with_extension("") } else { path };
            if logical.extension().is_some_and(|e| e == "jsonl") && !out.contains(&logical) { out.push(logical); }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    fn write(path: &Path, bytes: &[u8]) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    #[test]
    fn workspace_round_trip_preserves_edits_permissions_symlinks_and_attachments() {
        let root = tempfile::tempdir().unwrap();
        let room = root.path();
        let ws = room.join("workspace");
        write(&ws.join("project/uncommitted.rs"), &vec![b'x'; 100_000]);
        write(&ws.join("script.sh"), b"#!/bin/sh\ntrue\n");
        fs::set_permissions(ws.join("script.sh"), fs::Permissions::from_mode(0o751)).unwrap();
        write(&ws.join("uploads/evidence.txt"), b"historical attachment");
        std::os::unix::fs::symlink("project/uncommitted.rs", ws.join("link")).unwrap();
        let _lock = lock(room).unwrap();
        pack_workspace(room).unwrap();
        assert!(!ws.join("project/uncommitted.rs").exists());
        assert!(fs::metadata(workspace_archive(room)).unwrap().len() < 10_000);
        assert_eq!(workspace_file(room, Path::new("uploads/evidence.txt")).unwrap().unwrap(), b"historical attachment");
        pack_workspace(room).unwrap(); // An hourly retry must not replace the archive with the now-empty directory.
        write(&ws.join("uploads/new.txt"), b"new attachment while archived");
        restore_workspace(room).unwrap();
        assert_eq!(fs::read(ws.join("project/uncommitted.rs")).unwrap(), vec![b'x'; 100_000]);
        assert_eq!(fs::metadata(ws.join("script.sh")).unwrap().permissions().mode() & 0o777, 0o751);
        assert_eq!(fs::read_link(ws.join("link")).unwrap(), Path::new("project/uncommitted.rs"));
        assert_eq!(fs::read(ws.join("uploads/new.txt")).unwrap(), b"new attachment while archived");
        assert!(!workspace_archive(room).exists());
        restore_workspace(room).unwrap();
    }

    #[test]
    fn transcript_round_trip_and_corruption_keep_the_only_good_copy() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("history.jsonl");
        let text = b"{\"type\":\"user\"}\n".repeat(10_000);
        write(&path, &text);
        pack_file(&path).unwrap();
        assert!(!path.exists());
        let mut decoded = vec![];
        reader(&path).unwrap().read_to_end(&mut decoded).unwrap();
        assert_eq!(decoded, text);
        restore_file(&path).unwrap();
        assert_eq!(fs::read(&path).unwrap(), text);
        pack_file(&path).unwrap();
        fs::write(packed(&path), b"broken archive").unwrap();
        assert!(restore_file(&path).is_err());
        assert!(!path.exists());
        assert!(packed(&path).exists());
    }

    #[test]
    fn failed_workspace_restore_preserves_archive_and_new_files() {
        let root = tempfile::tempdir().unwrap();
        let room = root.path();
        write(&room.join("workspace/source.rs"), b"original");
        pack_workspace(room).unwrap();
        write(&room.join("workspace/new.txt"), b"new");
        fs::write(workspace_archive(room), b"broken archive").unwrap();
        assert!(restore_workspace(room).is_err());
        assert_eq!(fs::read(room.join("workspace/new.txt")).unwrap(), b"new");
        assert!(workspace_archive(room).exists());
    }

    #[test]
    fn interrupted_workspace_retirement_can_be_restored() {
        let root = tempfile::tempdir().unwrap();
        let room = root.path();
        write(&room.join("workspace/source.rs"), b"snapshot");
        pack_workspace(room).unwrap();
        write(&room.join("workspace.retiring/source.rs"), b"latest surviving original");
        restore_workspace(room).unwrap();
        assert_eq!(fs::read(room.join("workspace/source.rs")).unwrap(), b"latest surviving original");
    }

    #[test]
    fn archived_git_worktree_survives_prune_and_restores_dirty_files() {
        let root = tempfile::tempdir().unwrap();
        let repo = root.path().join("repo");
        fs::create_dir(&repo).unwrap();
        let git = |dir: &Path, args: &[&str]| {
            let out = std::process::Command::new("git").arg("-C").arg(dir).args(args).output().unwrap();
            assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
            out
        };
        git(&repo, &["init", "-q"]);
        write(&repo.join("source.rs"), b"committed");
        git(&repo, &["add", "."]);
        git(&repo, &["-c", "user.name=test", "-c", "user.email=test@example.com", "commit", "-qm", "initial"]);
        let room = root.path().join("chat");
        let ws = room.join("workspace");
        fs::create_dir_all(&ws).unwrap();
        let worktree = ws.join("project");
        git(&repo, &["worktree", "add", "--detach", worktree.to_str().unwrap()]);
        write(&worktree.join("source.rs"), b"uncommitted edit");
        let dotgit = fs::read_to_string(worktree.join(".git")).unwrap();
        let gitdir = Path::new(dotgit.trim().strip_prefix("gitdir: ").unwrap());
        pack_workspace(&room).unwrap();
        assert!(gitdir.join("locked").exists());
        git(&repo, &["worktree", "prune", "--expire", "now"]);
        assert!(gitdir.exists());
        restore_workspace(&room).unwrap();
        assert!(!gitdir.join("locked").exists());
        assert_eq!(fs::read(worktree.join("source.rs")).unwrap(), b"uncommitted edit");
        assert!(String::from_utf8_lossy(&git(&worktree, &["status", "--porcelain"]).stdout).contains("source.rs"));
    }
    #[test]
    fn becoming_active_before_commit_keeps_originals_and_removes_temporary_archives() {
        let root = tempfile::tempdir().unwrap();
        let room = root.path();
        write(&room.join("workspace/source.rs"), b"work");
        pack_workspace_if(room, || false).unwrap();
        assert_eq!(fs::read(room.join("workspace/source.rs")).unwrap(), b"work");
        assert!(!workspace_archive(room).exists());
        assert!(!room.join("workspace.tar.zst.writing").exists());
        let history = room.join("history.jsonl");
        write(&history, b"history\n");
        pack_file_if(&history, || false).unwrap();
        assert_eq!(fs::read(&history).unwrap(), b"history\n");
        assert!(!packed(&history).exists());
        assert!(!room.join("history.jsonl.zst.writing").exists());
    }

}
