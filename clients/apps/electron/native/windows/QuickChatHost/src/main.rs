//! QuickChatHost on Windows, native: what Main's QuickChatService starts, as macOS starts its Swift QuickChatHost. It
//! speaks the same protocol, one JSON object per line (src/quick-chat-host/messages.ts):
//!
//!   stdin  ← configure · result · transcript · dictationTicket · listen
//!   stdout → ready · preparing · submit · transcribe · dictationTicket
//!   stdin's end quits.
//!
//! One Quick Chat at a time, as the macOS QuickChatController. A double tap of Ctrl anywhere (or Main's `listen`)
//! shows the overlay on the display under the pointer: a window over the whole display, two DIPs short of its top,
//! left out of screen captures, that takes the keyboard while Quick Chat is open and lets clicks through to the app
//! below except over the words and the buttons. It draws the display's live capture with NameDrop's effect bending it
//! (gpu.rs, effect.rs), and the words over it as they are said (transcript.rs; listening.rs).
//!
//! Clicking the words or typing stops listening and opens them for editing (editor.rs); a tap of Ctrl then listens
//! again after them. Return or the send button sends them away with the shockwave and asks Main to send a Message. The
//! close button and Esc drop the words. A click elsewhere closes it too, and the next Quick Chat continues them; so
//! does `SILENCE_LIMIT_SECONDS` without speech while it listens, so a double tap by mistake never leaves the
//! microphone on.

#![windows_subsystem = "windows"]

mod audio;
mod clip;
mod controls;
mod ctrl_tap;
mod editor;
mod effect;
mod gpu;
mod listening;
mod live;
mod motion;
mod record;
mod spoken;
mod text;
mod transcript;
mod transcript_fit;

use std::cell::RefCell;
use std::collections::HashMap;
use std::hash::{BuildHasher, Hasher};
use std::io::{BufRead, Write};
use std::sync::atomic::{AtomicIsize, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

use serde::Deserialize;
use windows::core::{w, Interface, Result, HSTRING, PCWSTR};
use windows::Win32::Foundation::{COLORREF, HINSTANCE, HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Direct3D11::{ID3D11RenderTargetView, ID3D11Texture2D};
use windows::Win32::Graphics::DirectComposition::{
    DCompositionCreateDevice, IDCompositionDevice, IDCompositionTarget, IDCompositionVisual,
};
use windows::Win32::Graphics::Dxgi::Common::{DXGI_ALPHA_MODE_IGNORE, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SAMPLE_DESC};
use windows::Win32::Graphics::Dxgi::{
    IDXGIDevice, IDXGIFactory2, IDXGISwapChain1, DXGI_PRESENT, DXGI_SCALING_STRETCH, DXGI_SWAP_CHAIN_DESC1,
    DXGI_SWAP_CHAIN_FLAG, DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL, DXGI_USAGE_RENDER_TARGET_OUTPUT,
};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, MonitorFromPoint, HMONITOR, MONITORINFO, MONITOR_DEFAULTTONEAREST};
use windows::Win32::System::Com::{CoInitializeEx, COINIT_APARTMENTTHREADED};
use windows::Win32::System::DataExchange::{CloseClipboard, EmptyClipboard, GetClipboardData, OpenClipboard, SetClipboardData};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
use windows::Win32::System::Threading::{
    CreateWaitableTimerExW, SetWaitableTimer, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, INFINITE, TIMER_ALL_ACCESS,
};
use windows::Win32::UI::HiDpi::{
    GetDpiForMonitor, SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, MDT_EFFECTIVE_DPI,
};
use windows::Win32::UI::Input::Ime::{
    ImmGetCompositionStringW, ImmGetContext, ImmReleaseContext, ImmSetCandidateWindow, ImmSetCompositionWindow,
    CANDIDATEFORM, CFS_EXCLUDE, CFS_POINT, COMPOSITIONFORM, GCS_COMPSTR, GCS_CURSORPOS, GCS_RESULTSTR,
    ISC_SHOWUICOMPOSITIONWINDOW,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetKeyState, RegisterHotKey, ReleaseCapture, SendInput, SetCapture, SetFocus, UnregisterHotKey, HOT_KEY_MODIFIERS,
    INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VIRTUAL_KEY, VK_BACK, VK_CONTROL,
    VK_DELETE, VK_DOWN, VK_END, VK_ESCAPE, VK_F22, VK_HOME, VK_LCONTROL, VK_LEFT, VK_MENU, VK_PROCESSKEY, VK_RCONTROL,
    VK_RETURN, VK_RIGHT, VK_SHIFT, VK_TAB, VK_UP,
};
use windows::Win32::UI::WindowsAndMessaging::*;

use crate::controls::{Button, Controls, Tip};
use crate::ctrl_tap::{Input, Recognizer, Tap};
use crate::editor::Editor;
use crate::effect::{Effect, CANCEL_DURATION, SEND_DURATION};
use crate::gpu::{Capture, Gpu};
use crate::listening::{Failure, Listening, Post};
use crate::live::LiveEvent;
use crate::spoken::join_spoken;
use crate::text::Ink;
use crate::transcript::{box_height, Area, Style, Transcript};

/// The overlay stops this many DIPs short of its display's top: a window exactly the display's size is taken for a
/// full-screen one, and Windows blanks the display for a frame when it shows or hides.
const SHORT_OF_TOP: f64 = 2.0;
/// The overlay draws at most this many frames a second, whatever the display's refresh rate: a 240 Hz display would
/// otherwise cost four times the work for motion no one sees the difference in.
const FRAME_RATE: f64 = 60.0;
/// Without a frame of the screen by then (no capture), the overlay shows over black.
const REVEAL_TIMEOUT: f64 = 1.5;
/// A ticket for live dictation is waited for this long.
const TICKET_SECONDS: f64 = 5.0;
const SILENCE_LIMIT_SECONDS: f64 = 30.0;
/// The resume tip half a second after editing starts: soon enough to find, late enough not to flash.
const RESUME_TIP_SECONDS: f64 = 0.5;
/// A send that failed while its words were leaving says so this long.
const FAILED_SECONDS: f64 = 3.0;
const WM_APP_TAP: u32 = WM_APP + 1;
const WM_APP_COMMAND: u32 = WM_APP + 2;
const WM_APP_LIVE: u32 = WM_APP + 3;
const WM_APP_POINTER: u32 = WM_APP + 4;
const WM_APP_CLIP: u32 = WM_APP + 5;
const WM_APP_CLIP_AUDIO: u32 = WM_APP + 6;
const WM_APP_FAILURE: u32 = WM_APP + 7;
const WM_APP_QUIT: u32 = WM_APP + 8;
const HOTKEY_FOREGROUND: i32 = 0xbaba;
const TIMER_HIDE: usize = 1;
const TIMER_FOREGROUND: usize = 2;
/** The foreground hotkey is given this long to arrive; then the hand-off goes on without it. */
const FOREGROUND_TIMEOUT_MS: u32 = 500;

/// The interface text in Comma's language (Main's `configure`).
#[derive(Deserialize, Debug, Clone)]
#[serde(default, rename_all = "camelCase")]
struct Strings {
    listening: String,
    close: String,
    send: String,
    preparing: String,
    microphone_denied: String,
    speech_unavailable: String,
    send_failed: String,
    resume: String,
}

impl Default for Strings {
    fn default() -> Self {
        Self {
            listening: "Listening…".into(),
            close: "Close".into(),
            send: "Send".into(),
            preparing: "Preparing speech recognition…".into(),
            microphone_denied:
                "Allow apps to use the microphone in Windows Settings > Privacy & security > Microphone.".into(),
            speech_unavailable: "Speech recognition is unavailable.".into(),
            send_failed: "Couldn't send. Your words are kept for the next voice message.".into(),
            resume: "Press Ctrl to continue".into(),
        }
    }
}

/// Main → helper (messages.ts's HostCommand).
#[derive(Deserialize, Debug)]
#[serde(tag = "type", rename_all = "camelCase")]
enum Command {
    #[serde(rename_all = "camelCase")]
    Configure {
        strings: Strings,
        /// Comma's AppUserModelID, which a failed send's notification is shown as.
        app_user_model_id: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    Result {
        request_id: String,
        ok: bool,
    },
    #[serde(rename_all = "camelCase")]
    Transcript {
        clip_id: String,
        text: Option<String>,
    },
    #[serde(rename_all = "camelCase")]
    DictationTicket {
        request_id: String,
        url: Option<String>,
        ticket: Option<String>,
    },
    Listen,
    /// Tests: the next frame drawn is saved as a BMP at `path`, as the overlay shows it (screen captures leave it out).
    DebugFrame {
        path: String,
    },
}

/// One line to Main on stdout.
pub fn write(event: &serde_json::Value) {
    let mut out = std::io::stdout().lock();
    let _ = writeln!(out, "{event}");
    let _ = out.flush();
}

fn now() -> f64 {
    let (mut count, mut frequency) = (0i64, 0i64);
    unsafe {
        let _ = QueryPerformanceCounter(&mut count);
        let _ = QueryPerformanceFrequency(&mut frequency);
    }
    count as f64 / frequency as f64
}

/// A request's or a clip's id: 128 random bits, as hex.
pub fn random_id() -> String {
    static COUNT: AtomicU64 = AtomicU64::new(0);
    let state = std::collections::hash_map::RandomState::new();
    let mut parts = [0u64; 2];
    for (i, part) in parts.iter_mut().enumerate() {
        let mut hasher = state.build_hasher();
        hasher.write_u64(COUNT.fetch_add(1, Ordering::Relaxed));
        hasher.write_u64((now() * 1e9) as u64);
        hasher.write_usize(i);
        *part = hasher.finish();
    }
    format!("{:016x}{:016x}", parts[0], parts[1])
}

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Phase {
    Idle,
    Listening,
    Editing,
    Leaving,
}

/// What the foreground hotkey does when it arrives.
#[derive(Clone, Copy)]
enum Foreground {
    Take,
    GiveBack(HWND),
}

/// Words still settling after their Quick Chat closed.
enum Closing {
    /// A source closed while listening; its words wait for the next Quick Chat when `keep`.
    Listening { source: Listening, keep: bool },
    /// An editor closed while its words finished: what was typed after `opened` follows the source's last words.
    Edited { source: Listening, text: String, opened: String },
}

/// A send waiting for its words to settle.
struct Sending {
    request_id: String,
    source: Listening,
    /// What Main was told it is preparing (empty when nothing).
    text: String,
}

struct Surface {
    swap_chain: IDXGISwapChain1,
    target: Option<ID3D11RenderTargetView>,
    width: u32,
    height: u32,
    _composition: (IDCompositionDevice, IDCompositionTarget, IDCompositionVisual),
}

/// Posts what the other threads tell the window.
struct Poster;

impl Post for Poster {
    fn clip(&self, listening: usize, samples: Vec<i16>) {
        post(WM_APP_CLIP, listening, Box::into_raw(Box::new(samples)) as isize);
    }

    fn clip_audio(&self, listening: usize, clip: usize, audio: Option<String>) {
        post(WM_APP_CLIP_AUDIO, listening, Box::into_raw(Box::new((clip, audio))) as isize);
    }

    fn failure(&self, listening: usize, failure: Failure) {
        post(WM_APP_FAILURE, listening, if failure == Failure::MicrophoneDenied { 1 } else { 0 });
    }
}

struct App {
    hwnd: HWND,
    gpu: Arc<Gpu>,
    surface: Surface,
    ink: Ink,
    effect: Effect,
    transcript: Transcript,
    editor: Editor,
    editor_open: bool,
    controls: Controls,
    tip: Tip,
    phase: Phase,
    /// Shown off every display, drawing, until the screen's first frame is on: then it moves onto its display.
    revealing: Option<(f64, u32)>,
    capture: Option<Capture>,
    /// Where the overlay goes on its display, px.
    place: RECT,
    area: Area,
    /// How far the words rise as they leave with a send, px: 30% of the screen, as on macOS.
    rise: f32,
    /// The window in front when Quick Chat opened, which the keyboard goes back to.
    front: HWND,
    foreground: Option<Foreground>,
    strings: Strings,
    app_user_model_id: Option<String>,
    listening: Option<Listening>,
    next_listening: usize,
    /// The ticket asked of Main: its request, when, and for which listening.
    ticket: Option<(String, f64, usize)>,
    /// The source whose words are open for editing, the words the editor has from it, and whether they are still
    /// finishing; a send asked meanwhile waits for them.
    editing_source: Option<Listening>,
    editor_words: String,
    finishing: bool,
    send_when_open: bool,
    closing: Vec<Closing>,
    sendings: Vec<Sending>,
    /// Each send's words, until Main's result.
    sends: HashMap<String, String>,
    leaving_send: Option<String>,
    hide_at: Option<f64>,
    /// The words of a Quick Chat closed without sending, or of a send that failed: the next one continues them.
    draft: String,
    level: f32,
    /// When the person last spoke or words last came, for the silence limit.
    active_at: f64,
    speech: u32,
    /// What the current listening last showed.
    shown_text: String,
    pending: bool,
    failure: Option<String>,
    resume_tip_at: Option<f64>,
    /// The overlay takes the pointer (over the words or the buttons).
    interactive: bool,
    /// A high surrogate typed, waiting for its pair.
    surrogate: Option<u16>,
    debug_frame: Option<String>,
    /// Tests: `QUICK_CHAT_TEST_FRAMES` names a folder where four frames a second are saved while it shows.
    test_frames: Option<(String, f64, u32)>,
    /// Tests: every frame shown, recorded (record.rs).
    recorder: Option<record::Recorder>,
}

thread_local! {
    static APP: RefCell<Option<App>> = const { RefCell::new(None) };
}
static WINDOW: AtomicIsize = AtomicIsize::new(0);
static TAPS: Mutex<Option<Recognizer>> = Mutex::new(None);

fn main() -> Result<()> {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        let _ = CoInitializeEx(None, COINIT_APARTMENTTHREADED);
    }
    let gpu = Arc::new(Gpu::new()?);
    let hwnd = create_window()?;
    WINDOW.store(hwnd.0 as isize, Ordering::SeqCst);
    let surface = create_surface(&gpu, hwnd, 16, 16)?;
    let mut ink = Ink::new(&gpu.device.cast::<IDXGIDevice>()?)?;
    ink.set_target(Some(&surface.swap_chain))?;
    APP.with(|app| {
        *app.borrow_mut() = Some(App {
            hwnd,
            gpu,
            surface,
            ink,
            effect: Effect::default(),
            transcript: Transcript::new(),
            editor: Editor::new(),
            editor_open: false,
            controls: Controls::new(),
            tip: Tip::new(),
            phase: Phase::Idle,
            revealing: None,
            capture: None,
            place: RECT::default(),
            area: Area::default(),
            rise: 300.0,
            front: HWND::default(),
            foreground: None,
            strings: Strings::default(),
            app_user_model_id: None,
            listening: None,
            next_listening: 0,
            ticket: None,
            editing_source: None,
            editor_words: String::new(),
            finishing: false,
            send_when_open: false,
            closing: Vec::new(),
            sendings: Vec::new(),
            sends: HashMap::new(),
            leaving_send: None,
            hide_at: None,
            draft: String::new(),
            level: 0.0,
            active_at: 0.0,
            speech: 0,
            shown_text: String::new(),
            pending: false,
            failure: None,
            resume_tip_at: None,
            interactive: false,
            surrogate: None,
            debug_frame: None,
            test_frames: std::env::var("QUICK_CHAT_TEST_FRAMES").ok().map(|dir| (dir, 0.0, 0)),
            recorder: None,
        })
    });
    *TAPS.lock().unwrap() = Some(Recognizer::default());
    let instance: HINSTANCE = unsafe { GetModuleHandleW(None)? }.into();
    let _keyboard = unsafe { SetWindowsHookExW(WH_KEYBOARD_LL, Some(keyboard_hook), Some(instance), 0)? };
    let _mouse = unsafe { SetWindowsHookExW(WH_MOUSE_LL, Some(mouse_hook), Some(instance), 0)? };
    read_stdin();
    write(&serde_json::json!({ "type": "ready" }));
    run()
}

/// Main's commands, each posted to the window; stdin's end quits.
fn read_stdin() {
    std::thread::spawn(|| {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if line.trim().is_empty() {
                continue;
            }
            match serde_json::from_str::<Command>(&line) {
                Ok(command) => post(WM_APP_COMMAND, 0, Box::into_raw(Box::new(command)) as isize),
                Err(error) => eprintln!("QuickChatHost ignored a line it does not know: {error}"),
            }
        }
        post(WM_APP_QUIT, 0, 0);
    });
}

fn post(message: u32, wparam: usize, lparam: isize) {
    let hwnd = HWND(WINDOW.load(Ordering::SeqCst) as *mut _);
    unsafe {
        let _ = PostMessageW(Some(hwnd), message, WPARAM(wparam), LPARAM(lparam));
    }
}

fn run() -> Result<()> {
    // Frames are paced by a high-resolution timer: the system's default tick (15.6 ms) would round each wait up,
    // halving the frame rate.
    let timer = unsafe {
        CreateWaitableTimerExW(None, PCWSTR::null(), CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS.0)?
    };
    let mut message = MSG::default();
    let mut last_frame = 0.0;
    loop {
        unsafe {
            while PeekMessageW(&mut message, None, 0, 0, PM_REMOVE).as_bool() {
                if message.message == WM_QUIT {
                    return Ok(());
                }
                let _ = TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        let drawing = APP.with(|app| app.borrow().as_ref().is_some_and(|app| app.busy()));
        if drawing {
            let wait = last_frame + 1.0 / FRAME_RATE - now();
            if wait > 0.0005 {
                // Messages wake it early; the next frame waits its turn. Negative: relative, in 100 ns.
                let due = -((wait * 1e7) as i64);
                unsafe {
                    let _ = SetWaitableTimer(timer, &due, 0, None, None, false);
                    let _ = MsgWaitForMultipleObjects(Some(&[timer]), false, INFINITE, QS_ALLINPUT);
                }
                continue;
            }
            // On the beat, without drifting: a late frame does not push the next ones later.
            last_frame = if now() - last_frame > 2.0 / FRAME_RATE { now() } else { last_frame + 1.0 / FRAME_RATE };
            with_app(|app| app.frame());
        } else {
            unsafe {
                let _ = MsgWaitForMultipleObjects(None, false, INFINITE, QS_ALLINPUT);
            }
        }
    }
}

fn create_window() -> Result<HWND> {
    unsafe {
        let instance = GetModuleHandleW(None)?;
        let class = WNDCLASSW {
            lpfnWndProc: Some(window_proc),
            hInstance: instance.into(),
            lpszClassName: w!("CommaQuickChat"),
            style: CS_DBLCLKS,
            hCursor: LoadCursorW(None, IDC_ARROW)?,
            ..Default::default()
        };
        RegisterClassW(&class);
        // Topmost, no taskbar button, drawn through DirectComposition, and (layered and transparent) letting clicks
        // through to the app below until the pointer is over the words or the buttons.
        let hwnd = CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOREDIRECTIONBITMAP | WS_EX_LAYERED | WS_EX_TRANSPARENT,
            w!("CommaQuickChat"),
            w!("Quick Chat"),
            WS_POPUP,
            0,
            0,
            16,
            16,
            None,
            None,
            Some(instance.into()),
            None,
        )?;
        SetLayeredWindowAttributes(hwnd, COLORREF(0), 255, LWA_ALPHA)?;
        // Left out of screen captures: the overlay draws the capture of the screen behind it.
        SetWindowDisplayAffinity(hwnd, WDA_EXCLUDEFROMCAPTURE)?;
        Ok(hwnd)
    }
}

fn create_surface(gpu: &Gpu, hwnd: HWND, width: u32, height: u32) -> Result<Surface> {
    unsafe {
        let dxgi_device: IDXGIDevice = gpu.device.cast()?;
        let factory: IDXGIFactory2 = dxgi_device.GetAdapter()?.GetParent()?;
        let swap_chain = factory.CreateSwapChainForComposition(
            &gpu.device,
            &DXGI_SWAP_CHAIN_DESC1 {
                Width: width,
                Height: height,
                Format: DXGI_FORMAT_B8G8R8A8_UNORM,
                SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
                BufferUsage: DXGI_USAGE_RENDER_TARGET_OUTPUT,
                BufferCount: 2,
                Scaling: DXGI_SCALING_STRETCH,
                SwapEffect: DXGI_SWAP_EFFECT_FLIP_SEQUENTIAL,
                AlphaMode: DXGI_ALPHA_MODE_IGNORE,
                ..Default::default()
            },
            None,
        )?;
        let device: IDCompositionDevice = DCompositionCreateDevice(&dxgi_device)?;
        let target = device.CreateTargetForHwnd(hwnd, true)?;
        let visual = device.CreateVisual()?;
        visual.SetContent(&swap_chain)?;
        target.SetRoot(&visual)?;
        device.Commit()?;
        let mut surface = Surface { swap_chain, target: None, width, height, _composition: (device, target, visual) };
        surface.make_target(gpu)?;
        Ok(surface)
    }
}

impl Surface {
    fn make_target(&mut self, gpu: &Gpu) -> Result<()> {
        unsafe {
            let buffer: ID3D11Texture2D = self.swap_chain.GetBuffer(0)?;
            let mut target = None;
            gpu.device.CreateRenderTargetView(&buffer, None, Some(&mut target))?;
            self.target = target;
        }
        Ok(())
    }
}

/// `rect` moved left of every display.
fn away(rect: RECT) -> RECT {
    let left = unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) };
    let width = rect.right - rect.left;
    RECT { left: left - width - 100, right: left - 100, ..rect }
}

fn move_to(hwnd: HWND, rect: RECT) {
    unsafe {
        let _ = SetWindowPos(
            hwnd,
            Some(HWND_TOPMOST),
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            SWP_NOACTIVATE,
        );
    }
}

/// Presses the foreground hotkey (F22, on no keyboard): Windows brings a window to the front only for the process
/// that had the last input, and the hotkey is this one's, as Chromium's ForegroundHelper does.
fn press_foreground_key(hwnd: HWND) -> bool {
    unsafe {
        // Registered still from a press that never arrived: it is pressed again.
        let _ = UnregisterHotKey(Some(hwnd), HOTKEY_FOREGROUND);
        if RegisterHotKey(Some(hwnd), HOTKEY_FOREGROUND, HOT_KEY_MODIFIERS(0), VK_F22.0 as u32).is_err() {
            return false;
        }
        let press = |flags| INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VK_F22, dwFlags: flags, ..Default::default() } },
        };
        SendInput(&[press(KEYBD_EVENT_FLAGS(0)), press(KEYEVENTF_KEYUP)], std::mem::size_of::<INPUT>() as i32) == 2
    }
}

/// A monitor's bounds and work area in px, and its scale.
fn monitor_bounds(monitor: HMONITOR) -> (RECT, RECT, f64) {
    let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
    let (mut dpi_x, mut dpi_y) = (96u32, 96u32);
    unsafe {
        let _ = GetMonitorInfoW(monitor, &mut info);
        let _ = GetDpiForMonitor(monitor, MDT_EFFECTIVE_DPI, &mut dpi_x, &mut dpi_y);
    }
    (info.rcMonitor, info.rcWork, dpi_x as f64 / 96.0)
}

fn key_down(key: VIRTUAL_KEY) -> bool {
    unsafe { GetKeyState(key.0 as i32) < 0 }
}

impl App {
    /// Drawing frames: shown, or leaving.
    fn busy(&self) -> bool {
        self.phase != Phase::Idle
    }

    /// The listening `id`, wherever it is now: listening, open for editing, closing or sending.
    fn source(&mut self, id: usize) -> Option<&mut Listening> {
        if let Some(listening) = self.listening.as_mut().filter(|l| l.id == id) {
            return Some(listening);
        }
        if let Some(listening) = self.editing_source.as_mut().filter(|l| l.id == id) {
            return Some(listening);
        }
        for closing in &mut self.closing {
            let (Closing::Listening { source, .. } | Closing::Edited { source, .. }) = closing;
            if source.id == id {
                return Some(source);
            }
        }
        self.sendings.iter_mut().map(|s| &mut s.source).find(|s| s.id == id)
    }

    fn sources(&mut self) -> Vec<&mut Listening> {
        let mut all: Vec<&mut Listening> = Vec::new();
        all.extend(self.listening.as_mut());
        all.extend(self.editing_source.as_mut());
        for closing in &mut self.closing {
            let (Closing::Listening { source, .. } | Closing::Edited { source, .. }) = closing;
            all.push(source);
        }
        all.extend(self.sendings.iter_mut().map(|s| &mut s.source));
        all
    }

    // MARK: Opening

    /// A double tap of Ctrl, or Main's `listen`: Quick Chat opens, or listens again after edited words.
    fn summon(&mut self) {
        match self.phase {
            Phase::Idle | Phase::Leaving => self.present(),
            Phase::Listening => {}
            Phase::Editing => self.resume(),
        }
    }

    fn present(&mut self) {
        let t = now();
        self.hide_at = None;
        self.leaving_send = None;
        unsafe {
            let _ = KillTimer(Some(self.hwnd), TIMER_HIDE);
        }
        let mut cursor = POINT::default();
        unsafe {
            let _ = GetCursorPos(&mut cursor);
        }
        let monitor = unsafe { MonitorFromPoint(cursor, MONITOR_DEFAULTTONEAREST) };
        let was_idle = self.phase == Phase::Idle;
        if was_idle {
            if let Err(error) = self.layout(monitor) {
                eprintln!("QuickChatHost could not size its surface: {error}");
                return;
            }
            self.front = unsafe { GetForegroundWindow() };
            if let Some(capture) = self.capture.take() {
                capture.stop();
            }
            self.capture = Capture::start(&self.gpu, monitor)
                .map_err(|error| eprintln!("QuickChatHost has no screen capture: {error}"))
                .ok();
            move_to(self.hwnd, away(self.place));
            unsafe {
                let _ = ShowWindow(self.hwnd, SW_SHOWNOACTIVATE);
            }
            self.revealing = Some((t, 0));
        } else if self.revealing.is_none() {
            // Summoned again as it leaves: it stays on its display.
            self.take_keyboard();
        }
        self.effect.present(t);
        self.controls.shown = true;
        let draft = std::mem::take(&mut self.draft);
        self.listen(draft);
    }

    fn layout(&mut self, monitor: HMONITOR) -> Result<()> {
        let (bounds, work, scale) = monitor_bounds(monitor);
        let short = (SHORT_OF_TOP * scale).round() as i32;
        self.place = RECT { top: bounds.top + short, ..bounds };
        let (width, height) = ((self.place.right - self.place.left) as u32, (self.place.bottom - self.place.top) as u32);
        self.resize(width, height)?;
        // macOS's rule: the package's canvas min(width, 500, height × 0.38) wide, the words above the Dock (here the
        // taskbar, when it is at the bottom), in DIPs.
        let (width_dip, height_dip) = (width as f64 / scale, height as f64 / scale);
        let stage = width_dip.min(500.0).min(height_dip * 0.38);
        self.effect.layout(width as f32, height as f32, (stage * scale) as f32);
        let text_width = (stage - 60.0).max(360.0).min(480.0).min(width_dip - 40.0);
        let taskbar = ((bounds.bottom - work.bottom).max(0) as f64 / scale).round();
        let s = scale as f32;
        self.area = Area {
            left: ((width_dip - text_width) / 2.0).round() as f32 * s,
            width: text_width.round() as f32 * s,
            bottom: height as f32 - (taskbar + 58.0) as f32 * s,
            scale: s,
        };
        self.transcript.set_area(self.area);
        self.controls.place(width as f32 / 2.0, height as f32 - (taskbar + 30.0) as f32 * s, s);
        self.rise = (height_dip * 0.3).round() as f32 * s;
        if let Ok(dir) = std::env::var("QUICK_CHAT_TEST_RECORD") {
            self.recorder = record::Recorder::new(&self.gpu, &dir, width, height, scale)
                .map_err(|error| eprintln!("QuickChatHost cannot record: {error}"))
                .ok();
        }
        Ok(())
    }

    fn resize(&mut self, width: u32, height: u32) -> Result<()> {
        let surface = &mut self.surface;
        if (width, height) == (surface.width, surface.height) {
            return Ok(());
        }
        self.ink.set_target(None)?;
        surface.target = None;
        unsafe {
            self.gpu.context.ClearState();
            self.gpu.context.Flush();
            surface.swap_chain.ResizeBuffers(0, width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_SWAP_CHAIN_FLAG(0))?;
        }
        surface.width = width;
        surface.height = height;
        surface.make_target(&self.gpu)?;
        self.ink.set_target(Some(&surface.swap_chain))
    }

    /// Starts the microphone and asks Main for live dictation's ticket; the words continue `after`.
    fn listen(&mut self, after: String) {
        let t = now();
        self.phase = Phase::Listening;
        self.level = 0.0;
        self.tip.hide(t);
        self.transcript.hidden = false;
        self.transcript.reset(&self.ink, &self.strings.listening, Style::Waiting, t);
        // The draft was on screen already: it shows at once.
        if !after.is_empty() {
            self.transcript.set_text(&self.ink, &after, true);
        }
        self.next_listening += 1;
        let id = self.next_listening;
        self.shown_text = after.clone();
        self.pending = false;
        self.failure = None;
        self.speech = 0;
        self.active_at = t;
        self.listening = Some(Listening::start(id, after, Arc::new(Poster)));
        let request_id = random_id();
        write(&serde_json::json!({ "type": "dictationTicket", "requestId": request_id }));
        self.ticket = Some((request_id, t, id));
        self.update_send();
    }

    fn on_ticket(&mut self, request_id: String, url: Option<String>, ticket: Option<String>) {
        // An answer to an earlier listening's question: the current one still waits for its own.
        if self.ticket.as_ref().is_none_or(|(asked, _, _)| *asked != request_id) {
            return;
        }
        let Some((_, _, id)) = self.ticket.take() else { return };
        let Some(source) = self.source(id) else { return };
        match (url, ticket) {
            (Some(url), Some(ticket)) => source.connect(url, ticket, move |event| {
                post(WM_APP_LIVE, id, Box::into_raw(Box::new(event)) as isize);
            }),
            _ => source.live(LiveEvent::Unavailable),
        }
    }

    // MARK: Words

    /// What the current listening says, each frame: its words, what is happening, the voice.
    fn follow_listening(&mut self, t: f64) {
        let Some(source) = self.listening.as_ref() else { return };
        let text = source.text().to_string();
        let pending = source.pending();
        let level = source.level();
        let speech = source.speech();
        if text != self.shown_text {
            self.transcript.set_text(&self.ink, &text, false);
            self.shown_text = text.clone();
            self.active_at = t;
            if !self.tip.shown() || self.failure.is_none() {
                // The tip stays above the words as they change.
            }
        }
        if speech != self.speech {
            self.speech = speech;
            self.active_at = t;
        }
        // What is happening shows where the words will be, or above them once there are words.
        if pending != self.pending && self.failure.is_none() {
            self.pending = pending;
            if !text.is_empty() {
                if pending {
                    self.tip.show(&self.strings.preparing, t);
                } else {
                    self.tip.hide(t);
                }
            } else {
                let hint = if pending { &self.strings.preparing } else { &self.strings.listening };
                self.transcript.set_placeholder(&self.ink, hint, Style::Waiting, t);
            }
        }
        // Rises quickly with the voice and falls back slowly.
        self.level += (level - self.level) * if level > self.level { 0.5 } else { 0.12 };
        self.effect.set_voice_level(self.level);
        self.update_send();
    }

    fn on_failure(&mut self, id: usize, denied: bool) {
        if self.listening.as_ref().map(|l| l.id) != Some(id) {
            return;
        }
        let message = if denied { &self.strings.microphone_denied } else { &self.strings.speech_unavailable }.clone();
        let t = now();
        if self.shown_text.is_empty() {
            self.transcript.set_placeholder(&self.ink, &message, Style::Hint, t);
        } else {
            self.tip.show(&message, t);
        }
        self.failure = Some(message);
    }

    fn current_text(&self) -> String {
        if self.phase == Phase::Editing && self.editor_open {
            return self.editor.string().trim().to_string();
        }
        self.listening.as_ref().map(|l| l.text().trim().to_string()).unwrap_or_default()
    }

    fn update_send(&mut self) {
        let heard = self.phase == Phase::Listening && self.listening.as_ref().is_some_and(|l| l.heard());
        self.controls.send_enabled = !self.current_text().is_empty() || heard;
    }

    // MARK: Editing

    /// A click on the words or a key while listening: the editor opens at once over the drawn words, with the caret
    /// where they were clicked, so every key typed lands in it, through the input method too. The words finish
    /// meanwhile and take their place in front of what was typed.
    fn edit(&mut self, caret: Option<usize>) {
        if self.phase != Phase::Listening {
            return;
        }
        let Some(mut source) = self.listening.take() else { return };
        let t = now();
        self.phase = Phase::Editing;
        self.finishing = true;
        self.send_when_open = false;
        self.effect.set_voice_level(0.0);
        let opened = source.text().to_string();
        self.editor_words = opened.clone();
        let scrolled_back = self.transcript.scrolled_back();
        self.editor.open(&self.ink, self.area, &opened, scrolled_back, caret, t);
        self.editor_open = true;
        self.transcript.hidden = true;
        self.tip.hide(t);
        self.resume_tip_at = Some(t + RESUME_TIP_SECONDS);
        source.finish(false, t);
        self.editing_source = Some(source);
        self.update_send();
    }

    /// The editing source's words, each frame: they take the place of the ones the editor has from it; once in, a send
    /// asked meanwhile goes.
    fn follow_editing(&mut self, t: f64) {
        let Some(source) = self.editing_source.as_mut() else { return };
        source.tick(t);
        let words = source.text().to_string();
        let settled = source.heard_out();
        if words != self.editor_words && !self.editor.composing() {
            self.editor.replace_prefix(&self.ink, &self.editor_words, &words, t);
            self.editor_words = words;
            self.update_send();
        }
        if self.finishing && settled {
            self.finishing = false;
            if self.send_when_open {
                self.send();
            }
        }
    }

    fn close_editor(&mut self) {
        if let Some(mut source) = self.editing_source.take() {
            source.stop();
        }
        self.editor_open = false;
        self.editor.dragging = false;
        self.resume_tip_at = None;
        self.tip.hide(now());
    }

    /// A tap of Ctrl while editing: listening resumes after the edited words.
    fn resume(&mut self) {
        if self.phase != Phase::Editing || !self.editor_open || self.editor.composing() {
            return;
        }
        let text = self.editor.string();
        self.close_editor();
        self.listen(text);
    }

    // MARK: Sending and leaving

    /// Return or the send button.
    fn send(&mut self) {
        let t = now();
        let request_id = random_id();
        match self.phase {
            Phase::Listening => {
                let Some(source) = self.listening.as_ref() else { return };
                let text = source.text().trim().to_string();
                if text.is_empty() && !source.heard() {
                    return;
                }
                let mut source = self.listening.take().unwrap();
                self.leave(&text);
                self.sends.insert(request_id.clone(), text.clone());
                self.leaving_send = Some(request_id.clone());
                // Main shows the send at once; its words are final once the last are in.
                if !text.is_empty() {
                    write(&serde_json::json!({ "type": "preparing", "requestId": request_id, "text": text }));
                }
                source.finish(true, t);
                source.retry_for_send(t);
                self.sendings.push(Sending { request_id, source, text });
            }
            Phase::Editing => {
                // The send button while the words finish: send what the editor opens with.
                if self.finishing {
                    self.send_when_open = true;
                    return;
                }
                let text = self.editor.string().trim().to_string();
                if text.is_empty() {
                    return;
                }
                self.leave(&text);
                self.sends.insert(request_id.clone(), text.clone());
                self.leaving_send = Some(request_id.clone());
                write(&serde_json::json!({ "type": "submit", "requestId": request_id, "text": text, "draft": "" }));
            }
            _ => {}
        }
    }

    /// Each send's words, once settled, go to Main.
    fn follow_sendings(&mut self, t: f64) {
        let mut index = 0;
        while index < self.sendings.len() {
            self.sendings[index].source.tick(t);
            if !self.sendings[index].source.settled() {
                index += 1;
                continue;
            }
            let mut sending = self.sendings.remove(index);
            let server = sending.source.text().trim().to_string();
            sending.source.stop();
            let text = if server.is_empty() { sending.text.clone() } else { server };
            if text.is_empty() {
                self.sends.remove(&sending.request_id);
                continue;
            }
            self.sends.insert(sending.request_id.clone(), text.clone());
            let mut submit = serde_json::json!({
                "type": "submit", "requestId": sending.request_id, "text": text, "draft": "",
            });
            if !sending.text.is_empty() {
                submit["prepared"] = serde_json::Value::Bool(true);
            }
            write(&submit);
        }
    }

    /// Words of closed Quick Chats, once settled, wait for the next one, in the order they were said.
    fn follow_closing(&mut self, t: f64) {
        let mut index = 0;
        while index < self.closing.len() {
            let (Closing::Listening { source, .. } | Closing::Edited { source, .. }) = &mut self.closing[index];
            source.tick(t);
            if !source.settled() {
                index += 1;
                continue;
            }
            let words = match self.closing.remove(index) {
                Closing::Listening { mut source, keep } => {
                    let words = if keep { source.text().trim().to_string() } else { String::new() };
                    source.stop();
                    words
                }
                Closing::Edited { mut source, text, opened } => {
                    let words = match text.strip_prefix(opened.as_str()) {
                        Some(typed) => format!("{}{typed}", source.text()),
                        None => text,
                    };
                    source.stop();
                    words.trim().to_string()
                }
            };
            self.keep_words(&words);
        }
    }

    fn keep_words(&mut self, words: &str) {
        if !words.is_empty() {
            self.draft = if self.draft.is_empty() { words.to_string() } else { join_spoken(&self.draft, words) };
        }
    }

    /// The send's leaving: the shockwave, and the words rising away with it, from where they were scrolled.
    fn leave(&mut self, text: &str) {
        let t = now();
        let from_editor = self.phase == Phase::Editing && self.editor_open;
        let scrolled_back = if from_editor { self.editor.scrolled_back() } else { self.transcript.scrolled_back() };
        self.end();
        self.effect.send(t);
        self.transcript.hidden = false;
        if from_editor || !self.transcript.has_words() {
            self.transcript.set_text(&self.ink, if text.is_empty() { "…" } else { text }, true);
            self.transcript.scroll_back(scrolled_back);
        }
        self.transcript.send(&self.ink, self.rise, t);
        self.hide_at = Some(t + SEND_DURATION);
    }

    /// The close button or Esc: the words are dropped, so the next Quick Chat starts empty.
    fn close(&mut self) {
        self.leave_without(false);
    }

    /// A click elsewhere or the silence limit, which can happen by accident: the words wait for the next one.
    fn cancel(&mut self) {
        self.leave_without(true);
    }

    fn leave_without(&mut self, keeping_words: bool) {
        let t = now();
        match self.phase {
            Phase::Listening => {
                if let Some(mut source) = self.listening.take() {
                    source.finish(false, t);
                    if keeping_words {
                        self.closing.push(Closing::Listening { source, keep: true });
                    } else {
                        source.stop();
                    }
                }
            }
            Phase::Editing => {
                let text = self.editor.string();
                let source = self.editing_source.take();
                match (source, keeping_words) {
                    (Some(source), true) if self.finishing => self.closing.push(Closing::Edited {
                        source,
                        text,
                        opened: self.editor_words.clone(),
                    }),
                    (source, keep) => {
                        if let Some(mut source) = source {
                            source.stop();
                        }
                        if keep {
                            self.keep_words(text.trim());
                        }
                    }
                }
            }
            _ => return,
        }
        self.end();
        self.effect.cancel(t);
        self.transcript.cancel(t);
        self.hide_at = Some(t + CANCEL_DURATION);
    }

    fn end(&mut self) {
        // A listening source left without sending is stopped by its leave; a send's keeps going until its words are in.
        self.listening = None;
        self.ticket = None;
        self.finishing = false;
        self.send_when_open = false;
        self.phase = Phase::Leaving;
        self.close_editor();
        self.controls.shown = false;
        self.controls.pressed = None;
        self.set_interactive(false);
        // The keyboard and the pointer go back to the app in front while the overlay finishes.
        self.give_keyboard_back();
    }

    fn on_result(&mut self, request_id: String, ok: bool) {
        let text = self.sends.remove(&request_id);
        if ok {
            return;
        }
        // The words wait for the next Quick Chat; the overlay still showing this send says it failed.
        if let Some(text) = text {
            if self.draft.is_empty() {
                self.draft = text;
            }
        }
        let t = now();
        if self.phase == Phase::Leaving && self.leaving_send.as_deref() == Some(request_id.as_str()) {
            self.transcript.reset(&self.ink, &self.strings.send_failed, Style::Message, t);
            self.hide_at = Some(t + FAILED_SECONDS);
        } else {
            notify(self.app_user_model_id.as_deref(), &self.strings.send_failed);
        }
    }

    fn hide(&mut self) {
        self.phase = Phase::Idle;
        self.hide_at = None;
        self.revealing = None;
        self.effect.reset();
        self.transcript.reset(&self.ink, "", Style::Hint, now());
        self.tip.clear();
        // Off the display first, then hidden: hidden in place, Windows would show its last frame (or black).
        move_to(self.hwnd, away(self.place));
        if let Some(capture) = self.capture.take() {
            capture.stop();
        }
        unsafe {
            let _ = SetTimer(Some(self.hwnd), TIMER_HIDE, 100, None);
        }
    }

    // MARK: Keyboard and pointer

    fn take_keyboard(&mut self) {
        self.press_foreground(Foreground::Take);
    }

    /// The hand-off through the foreground hotkey; without it (not registered, input refused, or not arrived in
    /// `FOREGROUND_TIMEOUT_MS`, as when an elevated app is in front), it goes on as it can.
    fn press_foreground(&mut self, foreground: Foreground) {
        self.foreground = Some(foreground);
        if press_foreground_key(self.hwnd) {
            unsafe {
                let _ = SetTimer(Some(self.hwnd), TIMER_FOREGROUND, FOREGROUND_TIMEOUT_MS, None);
            }
        } else {
            self.on_foreground_key();
        }
    }

    fn give_keyboard_back(&mut self) {
        let front = self.front;
        if front.is_invalid() || unsafe { GetForegroundWindow() } != self.hwnd {
            return;
        }
        self.press_foreground(Foreground::GiveBack(front));
    }

    fn on_foreground_key(&mut self) {
        unsafe {
            let _ = UnregisterHotKey(Some(self.hwnd), HOTKEY_FOREGROUND);
            let _ = KillTimer(Some(self.hwnd), TIMER_FOREGROUND);
            match self.foreground.take() {
                Some(Foreground::Take) => {
                    let _ = SetForegroundWindow(self.hwnd);
                    let _ = SetFocus(Some(self.hwnd));
                }
                Some(Foreground::GiveBack(front)) => {
                    if IsWindow(Some(front)).as_bool() && IsWindowVisible(front).as_bool() {
                        let _ = SetForegroundWindow(front);
                    }
                }
                None => {}
            }
        }
    }

    /// The overlay takes the pointer, or lets it through to the app below.
    fn set_interactive(&mut self, interactive: bool) {
        if interactive == self.interactive {
            return;
        }
        self.interactive = interactive;
        unsafe {
            let style = GetWindowLongPtrW(self.hwnd, GWL_EXSTYLE);
            let transparent = WS_EX_TRANSPARENT.0 as isize;
            let style = if interactive { style & !transparent } else { style | transparent };
            SetWindowLongPtrW(self.hwnd, GWL_EXSTYLE, style);
        }
    }

    /// The pointer moved to (`x`, `y`) on the screen.
    fn on_pointer(&mut self, x: i32, y: i32) {
        if !matches!(self.phase, Phase::Listening | Phase::Editing) || self.revealing.is_some() {
            self.controls.hover = None;
            self.set_interactive(false);
            return;
        }
        let (x, y) = ((x - self.place.left) as f32, (y - self.place.top) as f32);
        let button = self.controls.at(x, y);
        self.controls.hover = button;
        // While editing, the whole text area takes the pointer, so a click beside short words does not close Quick Chat.
        let over_text = if self.phase == Phase::Editing {
            self.editor.contains(x, y)
        } else {
            self.transcript.over_words(x, y)
        };
        self.set_interactive(over_text || button.is_some() || self.editor.dragging);
    }

    fn on_press(&mut self, x: f32, y: f32) {
        let t = now();
        if let Some(button) = self.controls.at(x, y) {
            self.controls.pressed = Some(button);
            return;
        }
        match self.phase {
            Phase::Listening if self.transcript.over_words(x, y) => {
                let caret = self.transcript.index_at(&self.ink, x, y);
                self.edit(caret);
            }
            Phase::Editing if self.editor.contains(x, y) => {
                self.editor.press(x, y, key_down(VK_SHIFT), t);
            }
            _ => {}
        }
    }

    fn on_release(&mut self, x: f32, y: f32) {
        self.editor.dragging = false;
        let pressed = self.controls.pressed.take();
        if pressed.is_some() && pressed == self.controls.at(x, y) {
            match pressed {
                Some(Button::Close) => self.close(),
                Some(Button::Send) if self.controls.send_enabled => self.send(),
                _ => {}
            }
        }
    }

    fn on_wheel(&mut self, notches: f32) {
        match self.phase {
            Phase::Listening => self.transcript.wheel(notches),
            Phase::Editing => self.editor.wheel(notches),
            _ => {}
        }
    }

    /// A key: true when it was taken.
    fn on_key(&mut self, key: VIRTUAL_KEY) -> bool {
        let t = now();
        let (ctrl, alt, shift) = (key_down(VK_CONTROL), key_down(VK_MENU), key_down(VK_SHIFT));
        let editing_key = matches!(key, VK_BACK | VK_DELETE | VK_LEFT | VK_RIGHT | VK_UP | VK_DOWN | VK_HOME | VK_END);
        match self.phase {
            Phase::Listening => {
                if key == VK_RETURN && !ctrl && !alt && !shift {
                    self.send();
                } else if key == VK_ESCAPE {
                    self.close();
                } else if key == VK_TAB {
                } else if !ctrl && !alt && (editing_key || key == VK_PROCESSKEY) {
                    // Typing while listening edits the words: the editor takes the key, or the input method's
                    // composition, after them. Characters come as WM_CHAR, which opens it too.
                    self.edit(None);
                    if editing_key {
                        self.edit_key(key, ctrl, shift, t);
                    }
                } else {
                    return false;
                }
                true
            }
            Phase::Editing => {
                if self.editor.composing() {
                    return false;
                }
                if key == VK_RETURN && !ctrl && !alt {
                    if shift {
                        self.editor.insert(&self.ink, "\n", t);
                        self.update_send();
                    } else {
                        self.send();
                    }
                } else if key == VK_ESCAPE {
                    self.close();
                } else if key == VK_TAB {
                } else if ctrl && !alt && matches!(key.0, 0x41 | 0x43 | 0x58 | 0x56 | 0x59 | 0x5A) {
                    match key.0 {
                        0x41 => self.editor.select_all(t),
                        0x43 => set_clipboard(&self.editor.selected()),
                        0x58 => {
                            if !self.editor.selected().is_empty() {
                                set_clipboard(&self.editor.selected());
                                self.editor.erase(&self.ink, true, false, t);
                            }
                        }
                        0x5A => self.editor.undo(&self.ink, !shift, t),
                        0x59 => self.editor.undo(&self.ink, false, t),
                        _ => {
                            if let Some(text) = clipboard() {
                                self.editor.insert(&self.ink, &text.replace("\r\n", "\n"), t);
                            }
                        }
                    }
                    self.update_send();
                } else if editing_key {
                    self.edit_key(key, ctrl, shift, t);
                } else {
                    return false;
                }
                true
            }
            _ => false,
        }
    }

    fn edit_key(&mut self, key: VIRTUAL_KEY, ctrl: bool, shift: bool, t: f64) {
        match key {
            VK_BACK => self.editor.erase(&self.ink, false, ctrl, t),
            VK_DELETE => self.editor.erase(&self.ink, true, ctrl, t),
            VK_LEFT if ctrl => self.editor.word(false, shift, t),
            VK_RIGHT if ctrl => self.editor.word(true, shift, t),
            VK_LEFT => self.editor.left(shift, t),
            VK_RIGHT => self.editor.right(shift, t),
            VK_UP => self.editor.vertical(-1.0, shift, t),
            VK_DOWN => self.editor.vertical(1.0, shift, t),
            VK_HOME => self.editor.line_edge(false, shift, t),
            VK_END => self.editor.line_edge(true, shift, t),
            _ => {}
        }
        self.update_send();
    }

    /// A character typed (UTF-16 unit; a surrogate pair comes in two).
    fn on_char(&mut self, unit: u16) {
        if key_down(VK_CONTROL) && !key_down(VK_MENU) {
            return;
        }
        if (0xD800..0xDC00).contains(&unit) {
            self.surrogate = Some(unit);
            return;
        }
        let units: Vec<u16> = match self.surrogate.take() {
            Some(high) if (0xDC00..0xE000).contains(&unit) => vec![high, unit],
            _ => vec![unit],
        };
        if units.len() == 1 && (units[0] < 0x20 || units[0] == 0x7F) {
            return;
        }
        if self.phase == Phase::Listening {
            self.edit(None);
        }
        if self.phase == Phase::Editing {
            self.editor.insert(&self.ink, &String::from_utf16_lossy(&units), now());
            self.update_send();
        }
    }

    /// The input method's composition, where the caret is.
    fn on_composition(&mut self, flags: u32) {
        if self.phase == Phase::Listening {
            self.edit(None);
        }
        if self.phase != Phase::Editing {
            return;
        }
        let t = now();
        unsafe {
            let context = ImmGetContext(self.hwnd);
            let read = |kind| {
                let bytes = ImmGetCompositionStringW(context, kind, None, 0);
                if bytes <= 0 {
                    return Vec::new();
                }
                let mut buffer = vec![0u16; bytes as usize / 2];
                ImmGetCompositionStringW(context, kind, Some(buffer.as_mut_ptr() as _), bytes as u32);
                buffer
            };
            if flags & GCS_RESULTSTR.0 != 0 {
                let result = read(GCS_RESULTSTR);
                self.editor.compose(&self.ink, Vec::new(), 0, t);
                self.editor.insert(&self.ink, &String::from_utf16_lossy(&result), t);
            }
            if flags & GCS_COMPSTR.0 != 0 {
                let composition = read(GCS_COMPSTR);
                let caret = ImmGetCompositionStringW(context, GCS_CURSORPOS, None, 0).max(0) as usize;
                self.editor.compose(&self.ink, composition, caret, t);
            }
            let _ = ImmReleaseContext(self.hwnd, context);
        }
        self.place_ime();
        self.update_send();
    }

    /// The input method's windows go at the caret.
    fn place_ime(&self) {
        let (x, top, height) = self.editor.caret_rect();
        unsafe {
            let context = ImmGetContext(self.hwnd);
            let point = POINT { x: x as i32, y: top as i32 };
            let _ = ImmSetCompositionWindow(
                context,
                &COMPOSITIONFORM { dwStyle: CFS_POINT, ptCurrentPos: point, rcArea: RECT::default() },
            );
            let caret = RECT { left: x as i32, top: top as i32, right: x as i32 + 1, bottom: (top + height) as i32 };
            let _ = ImmSetCandidateWindow(
                context,
                &CANDIDATEFORM { dwIndex: 0, dwStyle: CFS_EXCLUDE, ptCurrentPos: point, rcArea: caret },
            );
            let _ = ImmReleaseContext(self.hwnd, context);
        }
    }

    // MARK: Frames

    /// One frame: the words follow their sources, the effect and the text are drawn and presented; the overlay moves
    /// onto its display once it shows the screen.
    fn frame(&mut self) {
        let t = now();
        if let Some((since, drawn)) = self.revealing {
            let frames = self.gpu.screen.lock().unwrap().frames;
            let drawn = if frames > 0 { drawn + 1 } else { 0 };
            // Two frames of the screen presented off the display, then onto it, the effect starting over there; without
            // a capture, at once over black.
            if drawn >= 2 || t - since >= REVEAL_TIMEOUT || self.capture.is_none() {
                self.revealing = None;
                move_to(self.hwnd, self.place);
                if self.phase == Phase::Listening {
                    self.effect.present(t);
                }
                if matches!(self.phase, Phase::Listening | Phase::Editing) {
                    self.take_keyboard();
                }
            } else {
                self.revealing = Some((since, drawn));
            }
        }
        if let Some((_, asked, id)) = &self.ticket {
            if t - asked > TICKET_SECONDS {
                let id = *id;
                self.ticket = None;
                if let Some(source) = self.source(id) {
                    source.live(LiveEvent::Unavailable);
                }
            }
        }
        if let Some(source) = self.listening.as_mut() {
            source.tick(t);
        }
        self.follow_listening(t);
        self.follow_editing(t);
        self.follow_sendings(t);
        self.follow_closing(t);
        if self.resume_tip_at.is_some_and(|at| t >= at) {
            self.resume_tip_at = None;
            if self.phase == Phase::Editing && self.editor_open {
                self.tip.show(&self.strings.resume, t);
            }
        }
        if self.phase == Phase::Listening && t - self.active_at > SILENCE_LIMIT_SECONDS {
            self.cancel();
        }
        if self.phase == Phase::Leaving && self.hide_at.is_some_and(|at| t >= at) {
            self.hide();
            return;
        }
        self.transcript.tick();
        let has_screen = self.gpu.screen.lock().unwrap().frames > 0;
        let values = self.effect.values(t, has_screen, self.gpu.max_lod());
        if let Some(target) = &self.surface.target {
            self.gpu.draw(target, &values);
        }
        {
            // The capture's thread draws into the screen texture on the same device.
            let gpu = self.gpu.clone();
            let _screen = gpu.screen.lock().unwrap();
            if let Err(error) = self.draw_text(t) {
                eprintln!("QuickChatHost could not draw the words: {error}");
            }
        }
        if self.phase == Phase::Editing && self.editor.composing() {
            self.place_ime();
        }
        if let Some((dir, last, count)) = &mut self.test_frames {
            if t - *last >= 0.25 {
                *last = t;
                *count += 1;
                self.debug_frame.get_or_insert_with(|| format!("{dir}\\{count:04}.bmp"));
            }
        }
        if let Some(path) = self.debug_frame.take() {
            if let Err(error) = self.gpu.save_frame(&self.surface.swap_chain, &path) {
                eprintln!("QuickChatHost could not save the frame: {error}");
            }
        }
        if let Some(recorder) = self.recorder.as_ref().filter(|_| self.revealing.is_none()) {
            let _ = recorder.record(&self.gpu, &self.surface.swap_chain, t);
        }
        unsafe {
            let _ = self.surface.swap_chain.Present(1, DXGI_PRESENT(0));
        }
    }

    fn draw_text(&mut self, t: f64) -> Result<()> {
        if !self.ink.has_target() {
            return Ok(());
        }
        self.ink.begin();
        self.transcript.draw(&self.ink, t)?;
        if self.editor_open {
            self.editor.draw(&self.ink, t)?;
        }
        // Eight pixels above the editor, the words, or the box while there are none.
        let top = if self.editor_open {
            self.editor.top()
        } else {
            self.transcript.words_top().unwrap_or(box_height())
        };
        let s = self.area.scale;
        self.tip.draw(&self.ink, self.area.left + self.area.width / 2.0, self.area.bottom - (top + 8.0) * s, s, t)?;
        self.controls.draw(&self.ink, t)?;
        self.ink.end()
    }

    fn command(&mut self, command: Command) {
        match command {
            Command::Configure { strings, app_user_model_id } => {
                self.strings = strings;
                self.app_user_model_id = app_user_model_id;
            }
            Command::Listen => self.summon(),
            Command::DictationTicket { request_id, url, ticket } => self.on_ticket(request_id, url, ticket),
            Command::Transcript { clip_id, text } => {
                let t = now();
                for source in self.sources() {
                    if source.transcript(&clip_id, text.clone(), t) {
                        break;
                    }
                }
            }
            Command::Result { request_id, ok } => self.on_result(request_id, ok),
            Command::DebugFrame { path } => self.debug_frame = Some(path),
        }
    }
}

/// A notification as Comma, which says something went wrong after Quick Chat closed.
fn notify(app_user_model_id: Option<&str>, body: &str) {
    use windows::Data::Xml::Dom::XmlDocument;
    use windows::UI::Notifications::{ToastNotification, ToastNotificationManager};
    let Some(id) = app_user_model_id else {
        eprintln!("QuickChatHost has no AppUserModelID to notify as.");
        return;
    };
    let escaped = body.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;");
    let shown = (|| -> Result<()> {
        let xml = XmlDocument::new()?;
        xml.LoadXml(&HSTRING::from(format!(
            "<toast><visual><binding template=\"ToastGeneric\"><text>{escaped}</text></binding></visual>\
             <audio silent=\"true\"/></toast>"
        )))?;
        let toast = ToastNotification::CreateToastNotification(&xml)?;
        ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(id))?.Show(&toast)
    })();
    if let Err(error) = shown {
        eprintln!("QuickChatHost could not notify: {error}");
    }
}

fn set_clipboard(text: &str) {
    if text.is_empty() {
        return;
    }
    let units: Vec<u16> = text.encode_utf16().chain(std::iter::once(0)).collect();
    unsafe {
        if OpenClipboard(None).is_err() {
            return;
        }
        let _ = EmptyClipboard();
        if let Ok(memory) = GlobalAlloc(GMEM_MOVEABLE, units.len() * 2) {
            let data = GlobalLock(memory) as *mut u16;
            if !data.is_null() {
                std::ptr::copy_nonoverlapping(units.as_ptr(), data, units.len());
                let _ = GlobalUnlock(memory);
                // CF_UNICODETEXT; the clipboard owns the memory now.
                let _ = SetClipboardData(13, Some(windows::Win32::Foundation::HANDLE(memory.0)));
            }
        }
        let _ = CloseClipboard();
    }
}

fn clipboard() -> Option<String> {
    unsafe {
        OpenClipboard(None).ok()?;
        let text = GetClipboardData(13).ok().and_then(|handle| {
            let memory = windows::Win32::Foundation::HGLOBAL(handle.0);
            let data = GlobalLock(memory) as *const u16;
            if data.is_null() {
                return None;
            }
            let mut length = 0;
            while *data.add(length) != 0 {
                length += 1;
            }
            let text = String::from_utf16_lossy(std::slice::from_raw_parts(data, length));
            let _ = GlobalUnlock(memory);
            Some(text)
        });
        let _ = CloseClipboard();
        text
    }
}

fn with_app(f: impl FnOnce(&mut App)) {
    APP.with(|app| {
        if let Ok(mut app) = app.try_borrow_mut() {
            if let Some(app) = app.as_mut() {
                f(app);
            }
        }
    });
}

/// A point in a mouse message: client px (`screen` false) or screen px.
fn point_of(lparam: LPARAM) -> (i32, i32) {
    ((lparam.0 & 0xffff) as i16 as i32, ((lparam.0 >> 16) & 0xffff) as i16 as i32)
}

unsafe extern "system" fn window_proc(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    match message {
        WM_APP_TAP => {
            with_app(|app| match wparam.0 {
                2 => app.summon(),
                // A tap of Ctrl: listening resumes after edited words.
                _ => app.resume(),
            });
            LRESULT(0)
        }
        WM_APP_COMMAND => {
            let command = unsafe { Box::from_raw(lparam.0 as *mut Command) };
            with_app(|app| app.command(*command));
            LRESULT(0)
        }
        WM_APP_LIVE => {
            let event = unsafe { Box::from_raw(lparam.0 as *mut LiveEvent) };
            with_app(|app| {
                if let Some(source) = app.source(wparam.0) {
                    source.live(*event);
                }
            });
            LRESULT(0)
        }
        WM_APP_CLIP => {
            let samples = unsafe { Box::from_raw(lparam.0 as *mut Vec<i16>) };
            with_app(|app| {
                if let Some(source) = app.source(wparam.0) {
                    source.clip(*samples);
                }
            });
            LRESULT(0)
        }
        WM_APP_CLIP_AUDIO => {
            let audio = unsafe { Box::from_raw(lparam.0 as *mut (usize, Option<String>)) };
            with_app(|app| {
                let t = now();
                if let Some(source) = app.source(wparam.0) {
                    source.clip_audio(audio.0, audio.1, t);
                }
            });
            LRESULT(0)
        }
        WM_APP_FAILURE => {
            with_app(|app| app.on_failure(wparam.0, lparam.0 == 1));
            LRESULT(0)
        }
        WM_APP_POINTER => {
            let (x, y) = point_of(lparam);
            with_app(|app| app.on_pointer(x, y));
            LRESULT(0)
        }
        WM_HOTKEY if wparam.0 as i32 == HOTKEY_FOREGROUND => {
            with_app(|app| app.on_foreground_key());
            LRESULT(0)
        }
        WM_KEYDOWN | WM_SYSKEYDOWN => {
            let mut taken = false;
            with_app(|app| taken = app.on_key(VIRTUAL_KEY(wparam.0 as u16)));
            if taken {
                LRESULT(0)
            } else {
                unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
            }
        }
        WM_CHAR => {
            with_app(|app| app.on_char(wparam.0 as u16));
            LRESULT(0)
        }
        WM_IME_SETCONTEXT => {
            // The composition is drawn in the editor, not in the input method's own window.
            let lparam = LPARAM(lparam.0 & !(ISC_SHOWUICOMPOSITIONWINDOW as isize));
            unsafe { DefWindowProcW(hwnd, message, wparam, lparam) }
        }
        WM_IME_STARTCOMPOSITION => {
            with_app(|app| {
                if app.phase == Phase::Listening {
                    app.edit(None);
                }
                app.place_ime();
            });
            LRESULT(0)
        }
        WM_IME_COMPOSITION => {
            with_app(|app| app.on_composition(lparam.0 as u32));
            LRESULT(0)
        }
        WM_IME_ENDCOMPOSITION => {
            with_app(|app| app.editor.compose(&app.ink, Vec::new(), 0, now()));
            LRESULT(0)
        }
        WM_LBUTTONDOWN => {
            let (x, y) = point_of(lparam);
            unsafe { SetCapture(hwnd) };
            with_app(|app| app.on_press(x as f32, y as f32));
            LRESULT(0)
        }
        WM_LBUTTONDBLCLK => {
            let (x, y) = point_of(lparam);
            with_app(|app| {
                if app.phase == Phase::Editing && app.editor.contains(x as f32, y as f32) {
                    app.editor.select_word(x as f32, y as f32, now());
                } else {
                    app.on_press(x as f32, y as f32);
                }
            });
            LRESULT(0)
        }
        WM_MOUSEMOVE => {
            let (x, y) = point_of(lparam);
            with_app(|app| app.editor.drag(x as f32, y as f32, now()));
            LRESULT(0)
        }
        WM_LBUTTONUP => {
            let (x, y) = point_of(lparam);
            let _ = unsafe { ReleaseCapture() };
            with_app(|app| app.on_release(x as f32, y as f32));
            LRESULT(0)
        }
        WM_MOUSEWHEEL => {
            let delta = ((wparam.0 >> 16) & 0xffff) as i16 as f32;
            with_app(|app| app.on_wheel(delta / WHEEL_DELTA as f32));
            LRESULT(0)
        }
        // The overlay lost the keyboard: a click elsewhere.
        WM_ACTIVATE if (wparam.0 & 0xffff) as u32 == WA_INACTIVE => {
            with_app(|app| {
                if matches!(app.phase, Phase::Listening | Phase::Editing) && app.foreground.is_none() {
                    app.cancel();
                }
            });
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TIMER_FOREGROUND => {
            with_app(|app| app.on_foreground_key());
            LRESULT(0)
        }
        WM_TIMER if wparam.0 == TIMER_HIDE => {
            unsafe {
                let _ = KillTimer(Some(hwnd), TIMER_HIDE);
            }
            with_app(|app| {
                if app.phase == Phase::Idle {
                    unsafe {
                        let _ = ShowWindow(app.hwnd, SW_HIDE);
                    }
                }
            });
            LRESULT(0)
        }
        // Only stdin's end quits: Alt+F4 on the overlay closes Quick Chat as Esc does.
        WM_APP_QUIT => {
            unsafe { PostQuitMessage(0) };
            LRESULT(0)
        }
        WM_CLOSE => {
            with_app(|app| app.close());
            LRESULT(0)
        }
        _ => unsafe { DefWindowProcW(hwnd, message, wparam, lparam) },
    }
}

/// Taps of Ctrl in every app. A key other than Ctrl, a click or a scroll between makes a press a chord, not a tap.
/// A tap goes to the window as `WM_APP_TAP` with 1 (single) or 2 (double).
fn feed(input: Input, time: u32) {
    let tap = TAPS.lock().unwrap().as_mut().and_then(|taps| taps.handle(input, time as f64));
    let kind = match tap {
        Some(Tap::Double) => 2,
        Some(Tap::Single) => 1,
        None => return,
    };
    post(WM_APP_TAP, kind, 0);
}

unsafe extern "system" fn keyboard_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let key = unsafe { &*(lparam.0 as *const KBDLLHOOKSTRUCT) };
        let vk = key.vkCode as u16;
        let ctrl = vk == VK_LCONTROL.0 || vk == VK_RCONTROL.0 || vk == VK_CONTROL.0;
        match wparam.0 as u32 {
            WM_KEYDOWN | WM_SYSKEYDOWN => feed(if ctrl { Input::CtrlDown } else { Input::Other }, key.time),
            WM_KEYUP | WM_SYSKEYUP if ctrl => feed(Input::CtrlUp, key.time),
            _ => {}
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}

unsafe extern "system" fn mouse_hook(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let event = unsafe { &*(lparam.0 as *const MSLLHOOKSTRUCT) };
        match wparam.0 as u32 {
            WM_LBUTTONDOWN | WM_RBUTTONDOWN | WM_MBUTTONDOWN | WM_MOUSEWHEEL | WM_MOUSEHWHEEL => {
                feed(Input::Other, event.time)
            }
            WM_MOUSEMOVE => {
                let (x, y) = (event.pt.x as u16 as isize, event.pt.y as u16 as isize);
                post(WM_APP_POINTER, 0, x | (y << 16));
            }
            _ => {}
        }
    }
    unsafe { CallNextHookEx(None, code, wparam, lparam) }
}
