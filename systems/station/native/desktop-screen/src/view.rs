// One view of the main display (main.rs says the messages): the capture and the encoder on a thread of their own, a
// picture encoded only once one is asked for and only a new one (the screen changed) unless a key frame is asked for;
// the input and the clipboard on this one, in the order they come.
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::time::{Duration, Instant};

use serde_json::{Value, json};
use windows::Graphics::Capture::GraphicsCaptureSession;
use windows::Win32::Foundation::{POINT, RECT};
use windows::Win32::Graphics::Direct3D11::ID3D11Texture2D;
use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_FORMAT_NV12};
use windows::Win32::Graphics::Gdi::{GetMonitorInfoW, HMONITOR, MONITOR_DEFAULTTOPRIMARY, MONITORINFO, MonitorFromPoint};
use windows::Win32::Media::MediaFoundation::{MFSTARTUP_LITE, MFShutdown, MFStartup, MF_VERSION};
use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx};
use windows::Win32::System::Power::{ES_CONTINUOUS, ES_DISPLAY_REQUIRED, ES_SYSTEM_REQUIRED, SetThreadExecutionState};
use windows::Win32::UI::HiDpi::{DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext};

use super::Out;
use super::avc;
use super::hevc;
use super::capture::{Capture, Gpu, Scaler, fitted};
use super::clipboard::{Clipboard, PNG_MAX};
use super::encode::H264;
use super::image::{Images, Pixels};
use super::input::Input;
use super::pace::{self, Gate, KeyClock};
use super::region::{self, Region};

/// Its coordinates in pixels, whatever the display's scale.
pub fn dpi_aware() {
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
}

/// The main display and where it is on the virtual desktop, in pixels.
pub fn main_display() -> (HMONITOR, RECT) {
    unsafe {
        let monitor = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
        let mut info = MONITORINFO { cbSize: std::mem::size_of::<MONITORINFO>() as u32, ..Default::default() };
        let _ = GetMonitorInfoW(monitor, &mut info);
        (monitor, info.rcMonitor)
    }
}

pub fn status() -> Value {
    let (monitor, rect) = main_display();
    let capture = GraphicsCaptureSession::IsSupported().unwrap_or(false);
    json!({ "ok": true, "display": { "id": monitor.0 as usize, "width": rect.right - rect.left, "height": rect.bottom - rect.top }, "capture": capture })
}

pub enum Msg {
    Next,
    Keyframe,
    /// The capture has a new picture.
    Frame,
    /// The display captured went.
    Closed,
    /// Bits a second to encode at from the next frame on (the link carries no more).
    Rate(u32),
    /// The pictures from now on fitted into these bounds, of a part of the display alone (None: the whole).
    Bounds(u32, u32, Option<Region>),
}

struct Options {
    jpeg: bool,
    /// H.265 asked (made where the hardware has an encoder of it, else H.264).
    hevc: bool,
    max: (u32, u32),
    bitrate: Option<u32>,
    /// The most pictures a second asked (the view's 帧率; none: as many as the display draws).
    fps: Option<u32>,
    /// The software encoder even where there is hardware (a test of it): never asked by the station.
    software: bool,
}

pub fn run(request: &Value, input: &mut impl std::io::Read, out: Out) {
    unsafe {
        let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
    }
    let opus = request["audioCodec"].as_str() == Some("opus");
    let audio = if request["audio"].as_bool() == Some(true) { Some(super::audio::Audio::start(out.clone(), opus)) } else { None };
    let options = Options {
        jpeg: request["codec"].as_str() == Some("jpeg"),
        hevc: request["codec"].as_str() == Some("h265"),
        max: (request["maxWidth"].as_u64().unwrap_or(1920).max(16) as u32, request["maxHeight"].as_u64().unwrap_or(1080).max(16) as u32),
        bitrate: request["bitrate"].as_u64().map(|b| b as u32),
        fps: pace::fps(request["fps"].as_u64()),
        software: request["encoder"].as_str() == Some("software"),
    };
    let (tx, rx) = channel();
    let worker = {
        let (tx, out) = (tx.clone(), out.clone());
        std::thread::spawn(move || {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
                let _ = MFStartup(MF_VERSION, MFSTARTUP_LITE);
                // The display on (and the machine awake) while the view is open.
                SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
            }
            let ended = View::open(options, tx, &out).map(|mut view| view.run(rx, &out));
            if let Err(e) = ended {
                out.json(4, json!({ "stopped": e.message() }));
            }
            unsafe {
                let _ = MFShutdown();
            }
            // The capture gone: so is the view.
            std::process::exit(0);
        })
    };
    let mut keys = Input::new();
    keys.nudge();
    let mut clipboard = Clipboard::new(out.clone());
    // A picture on the clipboard is the largest message.
    while let Some((kind, payload)) = super::message(input, 2 + PNG_MAX) {
        match kind {
            1 => drop(tx.send(Msg::Next)),
            2 => drop(tx.send(Msg::Keyframe)),
            3 => {
                if let Ok(op) = serde_json::from_slice::<Value>(&payload) {
                    keys.post(&op);
                }
            }
            4 => {
                if clipboard.set(&payload) && payload[0] & 1 == 1 {
                    keys.paste();
                }
            }
            5 => clipboard.watch(payload.first() == Some(&1)),
            9 => { if let Some(a) = &audio { a.next(); } },
            6 => reveal(&String::from_utf8_lossy(&payload)),
            8 => {
                if let Ok(b) = serde_json::from_slice::<Value>(&payload) {
                    if let (Some(w), Some(h)) = (b["maxWidth"].as_u64(), b["maxHeight"].as_u64()) {
                        drop(tx.send(Msg::Bounds(w.max(16) as u32, h.max(16) as u32, region::of(&b["region"]))));
                    }
                }
            }
            7 if payload.len() == 4 => drop(tx.send(Msg::Rate(u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]])))),
            _ => {}
        }
    }
    clipboard.stop();
    drop(tx);
    drop(worker);
    std::process::exit(0);
}

/// A file shown selected in Explorer (one dropped into the view, put on the machine).
fn reveal(path: &str) {
    use std::os::windows::process::CommandExt;
    if path.is_empty() || path.contains('"') {
        return;
    }
    let _ = std::process::Command::new("explorer.exe").raw_arg(format!("/select,\"{path}\"")).spawn();
}

/// How long a picture may be in the encoder before it is taken as lost.
const STUCK: Duration = Duration::from_secs(2);

struct View {
    gpu: Gpu,
    capture: Capture,
    options: Options,
    images: Option<Images>,
    /// The newest picture, as captured (BGRA, the display's size), and when (µs).
    latest: Option<ID3D11Texture2D>,
    latest_at: i64,
    fresh: bool,
    wanted: u32,
    force_key: bool,
    /// The key frame asked is of the picture last encoded (the screen at rest: sent again sharper), encoded finer.
    still: bool,
    last_ts: i64,
    scaler: Option<Scaler>,
    encoder: Option<H264>,
    /// A still picture's encoder (`H264::still`), made for its key frame and gone once that came out; the next picture
    /// from `encoder` is a key frame (the decoder's references are this one's). `no_still`: it could not be made, for
    /// this `encoder`.
    sharp: Option<H264>,
    no_still: bool,
    /// The encoder made a picture asked to be a key frame without one: made anew for the next ask instead.
    force_unheeded: bool,
    /// When (ms since `opened`) the encoder's rate control last started (made, or `restart`ed at the rate asked).
    rated: f64,
    config: Vec<u8>,
    /// Whether the view's encoder makes H.265, once one was made.
    encoder_hevc: Option<bool>,
    vps: Vec<u8>,
    sps: Vec<u8>,
    pps: Vec<u8>,
    jpeg_size: (u32, u32),
    staging: Option<ID3D11Texture2D>,
    /// The part of the display framed alone as the station asks (None: the whole); the part the last picture pushed
    /// shows, those of the pictures in the encoder by their time, and the last said (message 7).
    region: Option<Region>,
    pushed_region: Option<Region>,
    regions: Vec<(i64, Option<Region>)>,
    told_region: Option<Region>,
    /// When the picture in the encoder went in.
    pushed_at: Instant,
    /// When which display is the main one was looked at last.
    looked: Instant,
    /// No picture sooner than the 帧率 asked lets it (ms since `opened`).
    gate: Gate,
    opened: Instant,
    /// A key frame at least every 10 s by the clock (the encoder's GOP counts pictures, fewer than asked may come).
    keys: KeyClock,
}

fn failed(out: &Out, error: &windows::core::Error, code: &str) -> windows::core::Error {
    out.json(1, json!({ "error": error.message(), "code": code }));
    error.clone()
}

impl View {
    fn open(options: Options, tx: Sender<Msg>, out: &Out) -> windows::core::Result<View> {
        let gpu = Gpu::new().map_err(|e| failed(out, &e, "capture"))?;
        let (monitor, rect) = main_display();
        let capture = Capture::start(&gpu, monitor, tx, options.jpeg, options.fps).map_err(|e| failed(out, &e, "capture"))?;
        if !options.jpeg {
            super::cursor::follow(out.clone());
        }
        if let Some(white) = capture.hdr_white() {
            out.json(4, json!({ "hdr": { "sdrWhiteNits": white } }));
        }
        let (width, height) = fitted((rect.right - rect.left) as u32, (rect.bottom - rect.top) as u32, options.max.0, options.max.1);
        let options_fps = options.fps;
        let mut view = View {
            gpu,
            capture,
            images: if options.jpeg { Some(Images::new().map_err(|e| failed(out, &e, "encoder"))?) } else { None },
            options,
            latest: None,
            latest_at: 0,
            fresh: false,
            wanted: 0,
            force_key: true,
            still: false,
            last_ts: 0,
            scaler: None,
            encoder: None,
            sharp: None,
            no_still: false,
            force_unheeded: false,
            rated: 0.0,
            config: Vec::new(),
            encoder_hevc: None,
            vps: Vec::new(),
            sps: Vec::new(),
            pps: Vec::new(),
            jpeg_size: (0, 0),
            staging: None,
            region: None,
            pushed_region: None,
            regions: Vec::new(),
            told_region: None,
            pushed_at: Instant::now(),
            looked: Instant::now(),
            gate: Gate::new(options_fps),
            opened: Instant::now(),
            keys: KeyClock::default(),
        };
        let encoder = if view.options.jpeg {
            "JPEG, quality 0.8".to_string()
        } else {
            let made = view.make_encoder(width, height).map_err(|e| failed(out, &e, "encoder"))?;
            made
        };
        let codec = if view.options.jpeg { "jpeg" } else if view.encoder_hevc == Some(true) { "h265" } else { "h264" };
        out.json(1, json!({ "width": width, "height": height, "encoder": encoder, "codec": codec, "regions": true, "audio": true }));
        Ok(view)
    }

    fn make_encoder(&mut self, width: u32, height: u32) -> windows::core::Result<String> {
        self.encoder = None;
        self.sharp = None;
        self.no_still = false;
        let bitrate = self.options.bitrate.unwrap_or((width * height * 3).max(1_000_000));
        // H.265 where it was asked and the hardware has it (a size's encoder made anew keeps the codec it had).
        let hevc = self.options.hevc && self.encoder_hevc.unwrap_or(true);
        let fps = pace::encoder_fps(self.options.fps);
        let encoder = match hevc.then(|| H264::hevc(&self.gpu, width, height, bitrate, fps)) {
            Some(Ok(encoder)) => encoder,
            _ => H264::new(&self.gpu, width, height, bitrate, fps, self.options.software)?,
        };
        self.encoder_hevc = Some(encoder.hevc);
        let name = encoder.name.clone();
        // The parameter sets the output type names, for an encoder that puts none in band.
        (self.vps, self.sps, self.pps) = (Vec::new(), Vec::new(), Vec::new());
        if encoder.hevc {
            let header = hevc::picture(&encoder.header);
            if let (Some(vps), Some(sps), Some(pps)) = (header.vps, header.sps, header.pps) {
                (self.vps, self.sps, self.pps) = (vps, sps, pps);
            }
        } else {
            let header = avc::picture(&encoder.header);
            if let (Some(sps), Some(pps)) = (header.sps, header.pps) {
                (self.sps, self.pps) = (sps, pps);
            }
        }
        self.encoder = Some(encoder);
        self.force_key = true;
        self.rated = self.ms();
        Ok(name)
    }

    fn run(&mut self, rx: Receiver<Msg>, out: &Out) {
        loop {
            // Waiting on the encoder: looked at again in a moment; else until something comes.
            let busy = self.busy() || (self.wanted > 0 && self.fresh);
            let msg = if busy {
                match rx.recv_timeout(Duration::from_millis(1)) {
                    Ok(m) => Some(m),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return,
                }
            } else {
                match rx.recv() {
                    Ok(m) => Some(m),
                    Err(_) => return,
                }
            };
            match msg {
                Some(Msg::Next) => self.wanted += 1,
                // The next picture is of the new size: the encoder made anew for it (from a key frame, a config first).
                Some(Msg::Bounds(w, h, region)) => {
                    self.options.max = (w, h);
                    // Another part: sent at once, from a key frame, the screen still or not.
                    if region != self.region {
                        self.region = region;
                        self.force_key = true;
                        self.fresh = self.latest.is_some();
                    }
                }
                Some(Msg::Rate(bits)) => {
                    let bits = bits.max(100_000);
                    self.options.bitrate = Some(bits);
                    if let Some(encoder) = self.encoder.as_mut() {
                        encoder.rate(bits);
                    }
                }
                Some(Msg::Keyframe) => {
                    self.force_key = true;
                    // The same picture again, as a key frame, when the screen does not change.
                    if self.latest.is_some() {
                        self.still = !self.fresh;
                        self.fresh = true;
                    }
                }
                Some(Msg::Closed) => {
                    out.json(4, json!({ "stopped": "the display went" }));
                    return;
                }
                Some(Msg::Frame) => match self.capture.take(&self.gpu, &mut self.latest) {
                    Ok(Some(at)) => {
                        self.latest_at = at;
                        self.fresh = true;
                        self.still = false;
                    }
                    Ok(None) => {}
                    Err(e) => {
                        out.json(4, json!({ "stopped": e.message() }));
                        return;
                    }
                },
                None => {}
            }
            // Another display made the main one: this view ends (the station opens the main one again), as its
            // input would go to the other.
            if self.looked.elapsed() > Duration::from_secs(1) {
                self.looked = Instant::now();
                if main_display().0 != self.capture.monitor {
                    out.json(4, json!({ "stopped": "another display is the main one now" }));
                    return;
                }
            }
            if let Err(e) = self.pump(out) {
                out.json(4, json!({ "stopped": e.message() }));
                return;
            }
        }
    }

    /// `crop` of the latest picture scaled into `to`, its scaler made anew when either size changed.
    fn scaled(&mut self, crop: (u32, u32, u32, u32), to: (u32, u32), format: DXGI_FORMAT) -> windows::core::Result<ID3D11Texture2D> {
        let latest = self.latest.clone().unwrap();
        let mut desc = Default::default();
        unsafe { latest.GetDesc(&mut desc) };
        let from = (desc.Width, desc.Height);
        if !self.scaler.as_ref().is_some_and(|s| s.from == from && s.to == to && s.format == format) {
            self.scaler = Some(Scaler::new(&self.gpu, from, to, format)?);
        }
        self.scaler.as_mut().unwrap().run(&self.gpu, &latest, crop)
    }

    /// What of the latest picture is encoded now (the whole, or the part asked for, in its pixels), the size it is
    /// encoded at (fitted into the bounds), and the part it is (None: the whole).
    fn framing(&self) -> ((u32, u32, u32, u32), (u32, u32), Option<Region>) {
        let mut desc = Default::default();
        unsafe { self.latest.as_ref().unwrap().GetDesc(&mut desc) };
        let (crop, part) = match self.region {
            Some(r) => {
                let (crop, part) = region::crop(r, desc.Width, desc.Height);
                (crop, Some(part))
            }
            None => ((0, 0, desc.Width, desc.Height), None),
        };
        (crop, fitted(crop.2, crop.3, self.options.max.0, self.options.max.1), part)
    }

    /// The part of the display the frame about to go shows (message 7), when it is another than the last one's.
    fn tell(&mut self, part: Option<Region>, out: &Out) {
        if part != self.told_region {
            self.told_region = part;
            out.json(7, region::said(part));
        }
    }

    /// ms since the view opened (the 帧率's clock).
    fn ms(&self) -> f64 {
        self.opened.elapsed().as_secs_f64() * 1000.0
    }

    /// A picture is in an encoder, not out yet.
    fn busy(&self) -> bool {
        self.encoder.as_ref().is_some_and(|e| e.busy()) || self.sharp.as_ref().is_some_and(|e| e.busy())
    }

    fn timestamp(&mut self) -> i64 {
        let ts = (self.last_ts + 1).max(self.latest_at);
        self.last_ts = ts;
        ts
    }

    fn pump(&mut self, out: &Out) -> windows::core::Result<()> {
        if self.options.jpeg {
            return self.pump_jpeg(out);
        }
        let mut done = Vec::new();
        if let Some(encoder) = self.encoder.as_mut() {
            done = encoder.poll()?;
        }
        for encoded in done {
            self.sent(encoded, false, out);
        }
        let mut done = Vec::new();
        if let Some(sharp) = self.sharp.as_mut() {
            done = sharp.poll()?;
        }
        let came = !done.is_empty();
        for encoded in done {
            self.sent(encoded, true, out);
        }
        if came && self.sharp.as_ref().is_some_and(|e| !e.busy()) {
            self.sharp = None;
        }
        // A picture the encoder never gave back (a driver that dropped it): the view would wait for it for ever. The
        // encoder is made anew, and the picture owed comes from it as a key frame.
        if self.busy() && self.pushed_at.elapsed() > STUCK {
            out.json(4, json!({ "encoder": "gave nothing back; made anew" }));
            self.encoder = None;
            self.sharp = None;
            self.regions.clear();
            self.pushed_region = self.told_region;
            self.wanted += 1;
            self.force_key = true;
            self.fresh = self.latest.is_some();
        }
        if self.wanted == 0 || !self.fresh || self.latest.is_none() || self.busy() || !self.gate.open(self.ms()) {
            return Ok(());
        }
        let (crop, size, part) = self.framing();
        let remake = self.encoder.as_ref().is_none_or(|e| (e.width, e.height) != size) || (self.force_key && self.force_unheeded);
        if remake {
            self.force_unheeded = false;
            self.make_encoder(size.0, size.1)?;
        }
        // Another part of the display: from a key frame (the client's config says the part); one 10 s after the last.
        let mut key = self.force_key || part != self.pushed_region || self.keys.due(self.ms());
        // The same picture again as a key frame (the screen at rest): encoded finer, by an encoder made for it.
        let still = key && self.still && !self.no_still && self.encoder.as_ref().unwrap().sharpens();
        // An encoder that keeps the bit rate it started at: started anew at the one asked, now and then (its next
        // picture a key frame); made anew where it cannot be.
        let now = self.ms();
        let encoder = self.encoder.as_mut().unwrap();
        let (at, asked) = encoder.rates();
        if !still && encoder.keeps_rate() && pace::restarts(at, asked, now - self.rated, key) {
            if let Err(e) = encoder.restart() {
                out.json(4, json!({ "encoder": format!("not started anew at {asked} bps ({}): made anew", e.message()) }));
                self.make_encoder(size.0, size.1)?;
            }
            self.rated = now;
            self.force_key = true;
            key = true;
        }
        if still && self.sharp.is_none() {
            match self.encoder.as_ref().unwrap().still(&self.gpu) {
                Ok(sharp) => self.sharp = Some(sharp),
                Err(e) => {
                    out.json(4, json!({ "encoder": format!("no still picture's encoder ({}): its key frame as the others", e.message()) }));
                    self.no_still = true;
                }
            }
        }
        let still = still && self.sharp.is_some();
        // One made for a picture that moved before it went in.
        if !still {
            self.sharp = None;
        }
        let mut early = Vec::new();
        let ready = if still { self.sharp.as_mut() } else { self.encoder.as_mut() }.unwrap().ready(&mut early)?;
        for encoded in early {
            self.sent(encoded, still, out);
        }
        if !ready {
            return Ok(());
        }
        let texture = self.scaled(crop, size, DXGI_FORMAT_NV12)?;
        let ts = self.timestamp();
        if key {
            let now = self.ms();
            self.keys.keyed(now);
        }
        if still { self.sharp.as_mut() } else { self.encoder.as_mut() }.unwrap().push(&self.gpu, &texture, ts, key)?;
        self.still = false;
        self.pushed_region = part;
        self.regions.push((ts, part));
        self.pushed_at = Instant::now();
        self.gate.went(self.ms());
        self.wanted -= 1;
        self.fresh = false;
        // After a still picture's key frame, the next of the moving ones is one too.
        self.force_key = still;
        Ok(())
    }

    /// One picture out (of the still picture's encoder: `still`): its config first when it changed.
    fn sent(&mut self, encoded: super::encode::Encoded, still: bool, out: &Out) {
        let hevc = self.encoder.as_ref().is_some_and(|e| e.hevc);
        let (data, key, mut vps, mut sps, mut pps) = if hevc {
            let p = hevc::picture(&encoded.stream);
            (p.data, p.key, p.vps, p.sps, p.pps)
        } else {
            let p = avc::picture(&encoded.stream);
            (p.data, p.key, None, p.sps, p.pps)
        };
        // A key frame without its parameter sets in band: its encoder's output type names them (the still picture's
        // encoder's may be other than the view's, and the view's again after it).
        if (key || encoded.clean) && sps.is_none() {
            let header = if still { self.sharp.as_ref() } else { self.encoder.as_ref() }.map(|e| e.header.clone()).unwrap_or_default();
            if hevc {
                let h = hevc::picture(&header);
                (vps, sps, pps) = (h.vps, h.sps, h.pps);
            } else {
                let h = avc::picture(&header);
                (sps, pps) = (h.sps, h.pps);
            }
        }
        // The part this picture shows, as it was pushed (those before it gone with it).
        let mut part = self.told_region;
        while let Some(&(ts, p)) = self.regions.first() {
            if ts > encoded.ts {
                break;
            }
            self.regions.remove(0);
            if ts == encoded.ts {
                part = p;
            }
        }
        if data.is_empty() {
            return;
        }
        if let Some(vps) = vps {
            self.vps = vps;
        }
        if let Some(sps) = sps {
            self.sps = sps;
        }
        if let Some(pps) = pps {
            self.pps = pps;
        }
        let key = key || encoded.clean;
        if key {
            let now = self.ms();
            self.keys.keyed(now);
        }
        if encoded.asked && !key {
            self.force_unheeded = true;
            self.force_key = true;
            self.fresh = self.latest.is_some();
        }
        if self.sps.len() < 4 || self.pps.is_empty() || (hevc && self.vps.is_empty()) {
            return;
        }
        let description = if hevc { hevc::hvcc(&self.vps, &self.sps, &self.pps) } else { Some(avc::avcc(&self.sps, &self.pps)) };
        let Some(description) = description else { return };
        self.tell(part, out);
        let (width, height) = self.encoder.as_ref().map(|e| (e.width, e.height)).unwrap_or((0, 0));
        let mut config = Vec::new();
        config.extend_from_slice(&width.to_be_bytes());
        config.extend_from_slice(&height.to_be_bytes());
        config.extend_from_slice(&description);
        if config != self.config {
            out.send(2, &config);
            self.config = config;
        }
        let mut payload = Vec::with_capacity(9 + data.len());
        payload.push(key as u8);
        payload.extend_from_slice(&(encoded.ts as u64).to_be_bytes());
        payload.extend_from_slice(&data);
        out.send(3, &payload);
    }

    /// The latest picture as one JPEG, when one is wanted and it is new (or a key frame was asked for: every one is).
    fn pump_jpeg(&mut self, out: &Out) -> windows::core::Result<()> {
        while self.wanted > 0 && self.fresh && self.latest.is_some() && self.gate.open(self.ms()) {
            self.gate.went(self.ms());
            let (crop, size, part) = self.framing();
            let texture = self.scaled(crop, size, DXGI_FORMAT_B8G8R8A8_UNORM)?;
            let (bytes, pitch) = self.gpu.read(&texture, &mut self.staging)?;
            let images = self.images.as_ref().unwrap();
            let jpeg = images.jpeg(&Pixels { width: size.0, height: size.1, pitch: pitch as u32, bytes: &bytes })?;
            self.wanted -= 1;
            self.fresh = false;
            self.force_key = false;
            self.tell(part, out);
            if size != self.jpeg_size {
                self.jpeg_size = size;
                let mut config = Vec::new();
                config.extend_from_slice(&size.0.to_be_bytes());
                config.extend_from_slice(&size.1.to_be_bytes());
                out.send(2, &config);
            }
            let ts = self.timestamp();
            let mut payload = vec![1u8];
            payload.extend_from_slice(&(ts as u64).to_be_bytes());
            payload.extend_from_slice(&jpeg);
            out.send(3, &payload);
        }
        Ok(())
    }
}
