// The pointer, said beside a video's pictures (which leave it out: capture.rs) as message 6 {x, y, shape}: where it is on
// the main display (0..1) and its shape as CSS names it (the system's standard cursors; any other "default"), looked at
// 60 times a second and said as it changes, for as long as the view's process lasts.
use std::time::Duration;

use serde_json::json;
use windows::Win32::Foundation::POINT;
use windows::Win32::UI::WindowsAndMessaging::{
    CURSOR_SHOWING, CURSORINFO, GetCursorInfo, HCURSOR, IDC_APPSTARTING, IDC_ARROW, IDC_CROSS, IDC_HAND, IDC_IBEAM, IDC_NO, IDC_SIZEALL,
    IDC_SIZENESW, IDC_SIZENS, IDC_SIZENWSE, IDC_SIZEWE, IDC_WAIT, LoadCursorW,
};

use super::Out;
use super::view::main_display;

/// The system's cursors (shared handles: the same in every app that shows one) by their CSS names.
fn shapes() -> Vec<(HCURSOR, &'static str)> {
    [
        (IDC_ARROW, "default"),
        (IDC_IBEAM, "text"),
        (IDC_HAND, "pointer"),
        (IDC_SIZEWE, "ew-resize"),
        (IDC_SIZENS, "ns-resize"),
        (IDC_SIZENWSE, "nwse-resize"),
        (IDC_SIZENESW, "nesw-resize"),
        (IDC_SIZEALL, "move"),
        (IDC_CROSS, "crosshair"),
        (IDC_NO, "not-allowed"),
        (IDC_WAIT, "wait"),
        (IDC_APPSTARTING, "progress"),
    ]
    .into_iter()
    .filter_map(|(id, name)| unsafe { LoadCursorW(None, id) }.ok().map(|c| (c, name)))
    .collect()
}

/// Says the pointer as it moves or changes, on a thread of its own, until the process ends.
pub fn follow(out: Out) {
    std::thread::spawn(move || {
        let shapes = shapes();
        let mut said = String::new();
        loop {
            let mut info = CURSORINFO { cbSize: std::mem::size_of::<CURSORINFO>() as u32, ..Default::default() };
            if unsafe { GetCursorInfo(&mut info) }.is_ok() {
                let (_, rect) = main_display();
                let (w, h) = ((rect.right - rect.left).max(1) as f64, (rect.bottom - rect.top).max(1) as f64);
                let POINT { x, y } = info.ptScreenPos;
                let unit = |v: f64| (v.clamp(0.0, 1.0) * 10000.0).round() / 10000.0;
                // Hidden (a game, a video player full screen): none drawn.
                let shape = if info.flags.0 & CURSOR_SHOWING.0 == 0 { "none" } else { shapes.iter().find(|(c, _)| *c == info.hCursor).map(|(_, n)| *n).unwrap_or("default") };
                let now = json!({ "x": unit((x - rect.left) as f64 / w), "y": unit((y - rect.top) as f64 / h), "shape": shape }).to_string();
                if now != said {
                    out.send(6, now.as_bytes());
                    said = now;
                }
            }
            std::thread::sleep(Duration::from_millis(16));
        }
    });
}
