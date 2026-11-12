// A person's input, posted with SendInput (station/src/screens/win-input.ts says what each op is): the pointer at its
// place on the main display (in the virtual desktop's absolute units), wheels in their own units, keys by their scan
// code (where they are on the keyboard, whatever its layout) or virtual key, text as Unicode.
use serde_json::Value;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN};

use super::view::main_display;

pub struct Input {
    /// Where the pointer was put last, in the virtual desktop's units.
    pointer: Option<(i32, i32)>,
}

fn send(inputs: &[INPUT]) {
    if !inputs.is_empty() {
        unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    }
}

fn mouse(dx: i32, dy: i32, data: i32, flags: MOUSE_EVENT_FLAGS) -> INPUT {
    INPUT { r#type: INPUT_MOUSE, Anonymous: INPUT_0 { mi: MOUSEINPUT { dx, dy, mouseData: data as u32, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

fn key(vk: u16, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT { r#type: INPUT_KEYBOARD, Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(vk), wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: 0 } } }
}

/// A key down or up: by its scan code where it has one (`ext`: an E0 key), else its virtual key.
fn press(vk: u16, scan: u16, ext: bool, down: bool) -> INPUT {
    let up = if down { KEYBD_EVENT_FLAGS(0) } else { KEYEVENTF_KEYUP };
    if scan != 0 {
        key(0, scan, KEYEVENTF_SCANCODE | up | if ext { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) })
    } else {
        key(vk, 0, up)
    }
}

impl Input {
    pub fn new() -> Input {
        Input { pointer: None }
    }

    /// 0..1 of the main display → the virtual desktop's absolute units (0..65535 over all displays).
    fn place(x: f64, y: f64) -> (i32, i32) {
        let display = main_display().1;
        let (w, h) = ((display.right - display.left) as f64, (display.bottom - display.top) as f64);
        let px = display.left as f64 + x.clamp(0.0, 1.0) * (w - 1.0).max(0.0);
        let py = display.top as f64 + y.clamp(0.0, 1.0) * (h - 1.0).max(0.0);
        let (vx, vy, vw, vh) = unsafe {
            (GetSystemMetrics(SM_XVIRTUALSCREEN) as f64, GetSystemMetrics(SM_YVIRTUALSCREEN) as f64, GetSystemMetrics(SM_CXVIRTUALSCREEN) as f64, GetSystemMetrics(SM_CYVIRTUALSCREEN) as f64)
        };
        let unit = |p: f64, origin: f64, span: f64| (((p - origin) * 65535.0) / (span - 1.0).max(1.0)).round() as i32;
        (unit(px, vx, vw), unit(py, vy, vh))
    }

    fn moved(&mut self, x: f64, y: f64) -> INPUT {
        let at = Input::place(x, y);
        self.pointer = Some(at);
        mouse(at.0, at.1, 0, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK)
    }

    pub fn post(&mut self, op: &Value) {
        let num = |k: &str| op[k].as_f64().unwrap_or(0.0);
        match op["op"].as_str() {
            Some("mouse") => {
                let mut inputs = vec![self.moved(num("x"), num("y"))];
                let button = op["button"].as_u64().unwrap_or(0);
                let (down, up) = match button {
                    1 => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP),
                    2 => (MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP),
                    _ => (MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP),
                };
                match op["type"].as_str() {
                    Some("down") => inputs.push(mouse(0, 0, 0, down)),
                    Some("up") => inputs.push(mouse(0, 0, 0, up)),
                    _ => {}
                }
                send(&inputs);
            }
            Some("wheel") => {
                let at = Input::place(num("x"), num("y"));
                let mut inputs = Vec::new();
                // A wheel turns what is under the pointer: it goes there first.
                if self.pointer != Some(at) {
                    inputs.push(self.moved(num("x"), num("y")));
                }
                let (dx, dy) = (num("dx") as i32, num("dy") as i32);
                if dy != 0 {
                    inputs.push(mouse(0, 0, dy, MOUSEEVENTF_WHEEL));
                }
                if dx != 0 {
                    inputs.push(mouse(0, 0, dx, MOUSEEVENTF_HWHEEL));
                }
                send(&inputs);
            }
            Some("key") => {
                let (vk, scan) = (op["vk"].as_u64().unwrap_or(0) as u16, op["scan"].as_u64().unwrap_or(0) as u16);
                send(&[press(vk, scan, op["ext"].as_bool().unwrap_or(false), op["down"].as_bool().unwrap_or(true))]);
            }
            Some("text") => self.text(op["text"].as_str().unwrap_or("")),
            _ => {}
        }
    }

    /// Text as typed: each UTF-16 unit as a Unicode key (a surrogate pair is two, as Windows takes it), a newline as
    /// Enter, a tab as Tab.
    pub fn text(&mut self, text: &str) {
        let mut inputs = Vec::new();
        for c in text.chars() {
            match c {
                '\r' => {}
                '\n' => inputs.extend([key(VK_RETURN.0, 0, KEYBD_EVENT_FLAGS(0)), key(VK_RETURN.0, 0, KEYEVENTF_KEYUP)]),
                '\t' => inputs.extend([key(VK_TAB.0, 0, KEYBD_EVENT_FLAGS(0)), key(VK_TAB.0, 0, KEYEVENTF_KEYUP)]),
                c => {
                    let mut units = [0u16; 2];
                    for &unit in c.encode_utf16(&mut units).iter() {
                        inputs.extend([key(0, unit, KEYEVENTF_UNICODE), key(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP)]);
                    }
                }
            }
        }
        send(&inputs);
    }

    /// Ctrl+V where the focus is (what the viewer set on the clipboard, pasted).
    pub fn paste(&mut self) {
        send(&[press(0, 0x1d, false, true), press(0, 0x2f, false, true), press(0, 0x2f, false, false), press(0, 0x1d, false, false)]);
    }

    /// The display woken (as a person moving the mouse does): one that went to sleep is captured black.
    pub fn nudge(&mut self) {
        send(&[mouse(0, 0, 0, MOUSEEVENTF_MOVE)]);
    }
}
