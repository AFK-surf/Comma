//! Directory-relative opens that never follow a symlink (`openat` with `O_NOFOLLOW`), for the connector's
//! `read_ref`: they pin the desktop app's private local-file index to the directory that was validated, even if its
//! path is later renamed or replaced.

use napi::bindgen_prelude::*;
use napi_derive::napi;
use std::ffi::CString;

fn errno_error(context: &str) -> Error {
    let err = std::io::Error::last_os_error();
    let code = match err.raw_os_error() {
        Some(libc::ENOENT) => "ENOENT",
        Some(libc::ELOOP) => "ELOOP",
        Some(libc::ENOTDIR) => "ENOTDIR",
        Some(libc::EACCES) => "EACCES",
        _ => "EIO",
    };
    Error::new(Status::GenericFailure, format!("{code}: {context}: {err}"))
}

fn child_name(name: &str) -> Result<CString> {
    if name.is_empty() || name == "." || name == ".." || name.contains('/') || name.contains('\\') || name.contains('\0') {
        return Err(Error::new(Status::InvalidArg, "unsafe child name"));
    }
    CString::new(name).map_err(|_| Error::new(Status::InvalidArg, "unsafe child name"))
}

/// Opens `name` inside the directory `dir_fd` without following a final symlink. `directory` requires a directory.
/// Returns the new file descriptor (close-on-exec).
#[napi]
pub fn openat_nofollow(dir_fd: i32, name: String, directory: bool) -> Result<i32> {
    let name = child_name(&name)?;
    let mut flags = libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
    if directory {
        flags |= libc::O_DIRECTORY;
    }
    let fd = unsafe { libc::openat(dir_fd, name.as_ptr(), flags) };
    if fd < 0 {
        return Err(errno_error("openat"));
    }
    Ok(fd)
}

/// Opens an absolute directory path one component at a time, never following a symlink.
#[napi]
pub fn open_directory_nofollow(path: String) -> Result<i32> {
    if !path.starts_with('/') {
        return Err(Error::new(Status::InvalidArg, "path must be absolute"));
    }
    let root = CString::new("/").unwrap();
    let mut fd = unsafe { libc::open(root.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
    if fd < 0 {
        return Err(errno_error("open /"));
    }
    for component in path.split('/').filter(|c| !c.is_empty()) {
        let name = match child_name(component) {
            Ok(name) => name,
            Err(e) => {
                unsafe { libc::close(fd) };
                return Err(e);
            }
        };
        let next = unsafe { libc::openat(fd, name.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC) };
        unsafe { libc::close(fd) };
        if next < 0 {
            return Err(errno_error("openat directory"));
        }
        fd = next;
    }
    Ok(fd)
}
