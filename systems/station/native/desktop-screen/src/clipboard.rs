// The machine's clipboard, while a person drives a view: set (text, or a PNG with a bitmap beside it for apps that take
// no PNG), pasted with Ctrl+V; and, while watched, what is copied on it (its sequence number looked at every half a
// second; nothing else read until it changes, and what the view set not said back): text first, else a picture as PNG.
// Another app may hold the clipboard a moment (a clipboard manager, Remote Desktop): opening it is tried again.
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::time::Duration;

use windows::Win32::Foundation::{HANDLE, HGLOBAL, HWND};
use windows::Win32::Graphics::Gdi::{BI_RGB, BITMAPINFOHEADER, HBITMAP};
use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx};
use windows::Win32::System::DataExchange::*;
use windows::Win32::System::Memory::{GMEM_MOVEABLE, GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock};
use windows::Win32::System::Ole::{CF_BITMAP, CF_DIB, CF_UNICODETEXT};
use windows::Win32::UI::WindowsAndMessaging::{CreateWindowExW, HWND_MESSAGE, WINDOW_EX_STYLE, WINDOW_STYLE};
use windows::core::w;

use super::Out;
use super::image::Images;

pub const TEXT_MAX: usize = 1024 * 1024;
pub const PNG_MAX: usize = 8 * 1024 * 1024;

fn png_format() -> u32 {
    unsafe { RegisterClipboardFormatW(w!("PNG")) }
}

/// The clipboard open (tried again for a moment while another app holds it); closed as this goes.
struct Open;
impl Open {
    fn new(owner: Option<HWND>) -> Option<Open> {
        for _ in 0..20 {
            if unsafe { OpenClipboard(owner) }.is_ok() {
                return Some(Open);
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        None
    }
}
impl Drop for Open {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseClipboard();
        }
    }
}

fn global(bytes: &[u8]) -> Option<HANDLE> {
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)).ok()?;
        let to = GlobalLock(memory) as *mut u8;
        if to.is_null() {
            return None;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), to, bytes.len());
        let _ = GlobalUnlock(memory);
        Some(HANDLE(memory.0))
    }
}

fn read_global(handle: HANDLE) -> Option<Vec<u8>> {
    unsafe {
        let memory = HGLOBAL(handle.0);
        let from = GlobalLock(memory) as *const u8;
        if from.is_null() {
            return None;
        }
        let bytes = std::slice::from_raw_parts(from, GlobalSize(memory)).to_vec();
        let _ = GlobalUnlock(memory);
        Some(bytes)
    }
}

pub struct Clipboard {
    owner: Option<HWND>,
    images: Option<Images>,
    /// The sequence number of what this view set: not said back as a copy.
    ours: Arc<AtomicU32>,
    watching: Option<Arc<AtomicBool>>,
    out: Out,
}

impl Clipboard {
    pub fn new(out: Out) -> Clipboard {
        // A window of its own (message-only) to own what it sets: a clipboard emptied by no window takes nothing.
        let owner = unsafe { CreateWindowExW(WINDOW_EX_STYLE(0), w!("STATIC"), w!("comma-desktop-screen"), WINDOW_STYLE(0), 0, 0, 0, 0, Some(HWND_MESSAGE), None, None, None) }.ok();
        Clipboard { owner, images: Images::new().ok(), ours: Arc::new(AtomicU32::new(0)), watching: None, out }
    }

    /// Message 4's payload: flags (bit 0 paste), type (1 text, 2 PNG), the bytes. Whether it was set.
    pub fn set(&mut self, payload: &[u8]) -> bool {
        if payload.len() < 2 {
            return false;
        }
        let body = &payload[2..];
        let Some(open) = Open::new(self.owner) else {
            self.out.json(4, serde_json::json!({ "clipboard": "busy" }));
            return false;
        };
        unsafe {
            if EmptyClipboard().is_err() {
                return false;
            }
            match payload[1] {
                1 => {
                    let Ok(text) = std::str::from_utf8(body) else { return false };
                    let mut wide: Vec<u16> = text.encode_utf16().collect();
                    wide.push(0);
                    let bytes = std::slice::from_raw_parts(wide.as_ptr() as *const u8, wide.len() * 2);
                    let Some(handle) = global(bytes) else { return false };
                    if SetClipboardData(CF_UNICODETEXT.0 as u32, Some(handle)).is_err() {
                        return false;
                    }
                }
                2 => {
                    let Some(handle) = global(body) else { return false };
                    if SetClipboardData(png_format(), Some(handle)).is_err() {
                        return false;
                    }
                    // A bitmap beside it, for apps that take no PNG (Paint, Office's older paths).
                    if let Some(dib) = self.images.as_ref().and_then(|i| i.decode(body).ok()).map(|(w, h, px)| dib(w, h, &px)) {
                        if let Some(handle) = global(&dib) {
                            let _ = SetClipboardData(CF_DIB.0 as u32, Some(handle));
                        }
                    }
                }
                _ => return false,
            }
            // Its number once closed (the clipboard's changes are counted as it closes).
            drop(open);
            self.ours.store(GetClipboardSequenceNumber(), Ordering::SeqCst);
        }
        true
    }

    /// Message 5: 1 watch, 0 stop.
    pub fn watch(&mut self, on: bool) {
        if let Some(flag) = self.watching.take() {
            flag.store(false, Ordering::SeqCst);
        }
        if !on {
            return;
        }
        let flag = Arc::new(AtomicBool::new(true));
        self.watching = Some(flag.clone());
        let (ours, out) = (self.ours.clone(), self.out.clone());
        std::thread::spawn(move || {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            }
            let images = Images::new().ok();
            let mut seen = unsafe { GetClipboardSequenceNumber() };
            while flag.load(Ordering::SeqCst) {
                std::thread::sleep(Duration::from_millis(500));
                let now = unsafe { GetClipboardSequenceNumber() };
                if now == seen {
                    continue;
                }
                seen = now;
                if now == ours.load(Ordering::SeqCst) || !flag.load(Ordering::SeqCst) {
                    continue;
                }
                if let Some((kind, bytes)) = copied(images.as_ref()) {
                    let mut payload = vec![kind];
                    payload.extend_from_slice(&bytes);
                    out.send(5, &payload);
                }
            }
        });
    }

    pub fn stop(&mut self) {
        self.watch(false);
    }
}

/// What the clipboard holds: text first (its UTF-8), else a picture as PNG; none past its bound.
fn copied(images: Option<&Images>) -> Option<(u8, Vec<u8>)> {
    let _open = Open::new(None)?;
    unsafe {
        if IsClipboardFormatAvailable(CF_UNICODETEXT.0 as u32).is_ok() {
            let bytes = read_global(GetClipboardData(CF_UNICODETEXT.0 as u32).ok()?)?;
            let wide: Vec<u16> = bytes.chunks_exact(2).map(|c| u16::from_le_bytes([c[0], c[1]])).take_while(|&u| u != 0).collect();
            let text = String::from_utf16_lossy(&wide);
            return (!text.is_empty() && text.len() <= TEXT_MAX).then(|| (1, text.into_bytes()));
        }
        let png = png_format();
        if IsClipboardFormatAvailable(png).is_ok() {
            if let Some(bytes) = GetClipboardData(png).ok().and_then(read_global) {
                return (!bytes.is_empty() && bytes.len() <= PNG_MAX).then_some((2, bytes));
            }
        }
        if IsClipboardFormatAvailable(CF_BITMAP.0 as u32).is_ok() {
            let bitmap = HBITMAP(GetClipboardData(CF_BITMAP.0 as u32).ok()?.0);
            let bytes = images?.png_of_hbitmap(bitmap).ok()?;
            return (bytes.len() <= PNG_MAX).then_some((2, bytes));
        }
    }
    None
}

/// A CF_DIB of BGRA pixels (top row first): 32 bits, bottom-up.
fn dib(width: u32, height: u32, pixels: &[u8]) -> Vec<u8> {
    let header = BITMAPINFOHEADER {
        biSize: std::mem::size_of::<BITMAPINFOHEADER>() as u32,
        biWidth: width as i32,
        biHeight: height as i32,
        biPlanes: 1,
        biBitCount: 32,
        biCompression: BI_RGB.0,
        biSizeImage: width * height * 4,
        ..Default::default()
    };
    let mut out = Vec::with_capacity(header.biSize as usize + pixels.len());
    out.extend_from_slice(unsafe { std::slice::from_raw_parts(&header as *const _ as *const u8, header.biSize as usize) });
    let row = (width * 4) as usize;
    for y in (0..height as usize).rev() {
        out.extend_from_slice(&pixels[y * row..(y + 1) * row]);
    }
    out
}
