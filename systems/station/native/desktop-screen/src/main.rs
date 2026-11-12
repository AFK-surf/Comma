// Ported from still.fail (github.com/AFK-surf/still.fail, afk/main 7470ca2abe), station/native/screen, as it is there:
// only the crate's and the executable's name (comma-desktop-screen) and the clipboard window's name differ. Paths in
// the comments below are still.fail's; Cue's counterparts are systems/station/src/screens/screen-pipe.ts (still.fail's
// desktop.ts `HelperView`, `TO_HELPER`), win-desktop.ts and win-input.ts (systems/station/docs/desktop-screen.md).
//
// stillfail-screen: this Windows machine's display as the station's `desktop` screen (docs/remote-screens.md), what
// still.fail Helper is on macOS. The station starts one for each view and talks to it on its standard input and
// output, in the helper's messages (station/src/screens/desktop.ts `TO_HELPER`, native/helper's ScreenView.swift):
//
//   stillfail-screen status   one JSON line: {ok, display: {id, width, height}, capture} (the main display, in pixels)
//   stillfail-screen scale [percent]
//                             one JSON line: the main display's scale {percent, recommended, steps: [percent…]}, set to
//                             `percent` first when it is given (one of its steps); or {error}
//   stillfail-screen resolution [WxH]
//                             one JSON line: the main display's resolution {width, height, modes: [{width, height}…]}
//                             (landscape, at its depth, the largest first), set to `WxH` first when it is given (one of
//                             its modes; for now, not kept in the registry); or {error}
//   stillfail-screen view     a JSON line {codec: "h265"|"h264"|"jpeg", maxWidth, maxHeight, bitrate?, fps?, audio?: true, audioCodec?: "opus", encoder?: "software"}
//                             (`fps`: the most pictures a second, 1…120, captured at it, the encoder set for it up
//                             to 60: pace.rs; none, as many as the display draws, the encoder set for 60), then
//                             messages
//                             (a kind byte, the payload's length in 4 bytes big-endian, the payload) both ways until
//                             its input ends:
//   in   1 next      (empty)  the next new picture, encoded
//        2 keyframe  (empty)  the next one a key frame, the screen changed or not
//        3 input     JSON     win-input.ts's ops: {op:"mouse", type:"move"|"down"|"up", x, y, button},
//                             {op:"wheel", x, y, dx, dy}, {op:"key", scan, ext, vk, down}, {op:"text", text}
//        4 clipboard 1 byte flags (bit 0: paste with Ctrl+V), 1 byte type (1 text, 2 PNG), the bytes
//        5 watch     1 byte       1: say each copy made on the machine from now on (message 5 out), 0: stop
//        6 reveal    UTF-8        a file's path, shown selected in Explorer
//        7 rate      4 bytes      bits a second (big-endian) to encode at from the next frame on
//        8 bounds    JSON         {maxWidth, maxHeight, region?}: the pictures from now on fitted into these, of
//                             `region` of the display alone ({x, y, w, h}, 0..1 of it: a client zoomed in) or, without
//                             it, of the whole
//        9 audio     (empty)      the latest 20 ms of system output (only with audio:true)
//   out  1 info      JSON     first: {width, height, encoder, codec, regions: true} (h265 where asked and the hardware has it), or
//                             {error, code: "capture"|"display"|"encoder"}
//        2 config    4 bytes width, 4 bytes height, then the avcC or hvcC (none for JPEG): before the first frame and whenever
//                             it changes
//        3 frame     1 byte flags (bit 0: key frame), 8 bytes timestamp (µs), then the frame (AVCC, or one JPEG)
//        4 event     JSON     what the station logs
//        5 clipboard 1 byte type (1 text, 2 PNG), the bytes: what was copied, while watched
//        6 cursor    JSON     {x, y, shape}: the pointer (0..1 of the display, a CSS cursor's name; "none" hidden) as it
//                             moves or changes; a video's pictures leave it out, a JPEG's have it drawn in
//        7 region    JSON     {region: {x, y, w, h} | null}: the part of the display the frames from the next one on
//                             show, as it was cut (null the whole), said before a frame whose part is another than the
//                             last one's (that frame a key frame)
//
//   out  8 audio config JSON  {codec:"pcm_s16le"|"opus", sampleRate:48000, channels:2}, or {error}; `opus` (Cue's) to a
//                             view that asked `audioCodec: "opus"` (opus.rs)
//        9 audio     8 bytes timestamp (µs), then 3840 bytes stereo PCM16 little-endian, or one Opus packet of those 20 ms
//
// Windows.Graphics.Capture captures the main display (the cursor drawn in, no border), a picture only when the screen
// changed (an HDR display's as FP16, made SDR by a pixel shader: hdr.rs); the GPU's video processor scales it into the
// view's bounds as NV12 (or BGRA for a JPEG); Media Foundation encodes H.264 on the hardware encoder (the software one
// where there is none), low latency, no B-frames; WIC makes the JPEGs. SendInput posts the input. While a view is open
// the display is kept on.

#[cfg_attr(not(windows), allow(dead_code))]
mod avc;
#[cfg_attr(not(windows), allow(dead_code))]
mod hevc;
#[cfg(windows)]
mod audio;
#[cfg_attr(not(windows), allow(dead_code))]
mod audio_queue;
#[cfg_attr(not(windows), allow(dead_code))]
mod opus;
#[cfg(windows)]
mod capture;
#[cfg(windows)]
mod clipboard;
#[cfg(windows)]
mod cursor;
#[cfg(windows)]
mod encode;
#[cfg_attr(not(windows), allow(dead_code))]
mod hdr;
#[cfg(windows)]
mod image;
#[cfg(windows)]
mod input;
#[cfg_attr(not(windows), allow(dead_code))]
mod pace;
#[cfg_attr(not(windows), allow(dead_code))]
mod region;
#[cfg_attr(not(windows), allow(dead_code))]
mod resolution;
mod scale;
#[cfg(windows)]
mod view;

use std::io::{Read, Write};
use std::sync::{Arc, Mutex};

/// The messages out, from whichever thread has one: each written whole.
#[derive(Clone)]
pub struct Out(Arc<Mutex<std::io::Stdout>>);

impl Out {
    pub fn new() -> Out {
        Out(Arc::new(Mutex::new(std::io::stdout())))
    }
    pub fn send(&self, kind: u8, payload: &[u8]) {
        let mut head = [0u8; 5];
        head[0] = kind;
        head[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
        let out = self.0.lock().unwrap();
        let mut out = out.lock();
        // The station gone: the view ends as its input does.
        let _ = out.write_all(&head).and_then(|_| out.write_all(payload)).and_then(|_| out.flush());
    }
    pub fn json(&self, kind: u8, value: serde_json::Value) {
        self.send(kind, value.to_string().as_bytes());
    }
}

/// The next message in (kind, payload), None once the input ends or a message is past `limit`.
pub fn message(input: &mut impl Read, limit: usize) -> Option<(u8, Vec<u8>)> {
    let mut head = [0u8; 5];
    input.read_exact(&mut head).ok()?;
    let length = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
    if length > limit {
        return None;
    }
    let mut payload = vec![0u8; length];
    input.read_exact(&mut payload).ok()?;
    Some((head[0], payload))
}

/// The first line in: the request.
pub fn request_line(input: &mut impl Read) -> Option<serde_json::Value> {
    let mut line = Vec::new();
    let mut byte = [0u8; 1];
    loop {
        input.read_exact(&mut byte).ok()?;
        if byte[0] == b'\n' {
            break;
        }
        line.push(byte[0]);
        if line.len() > 64 * 1024 {
            return None;
        }
    }
    serde_json::from_slice(&line).ok()
}

#[cfg(windows)]
fn main() {
    view::dpi_aware();
    match std::env::args().nth(1).as_deref() {
        Some("status") => println!("{}", view::status()),
        // The main display's scale; with a percent, set to it first.
        Some("scale") => match std::env::args().nth(2) {
            Some(percent) => println!("{}", percent.parse().map(scale::set).unwrap_or_else(|_| serde_json::json!({ "error": "not a percent" }))),
            None => println!("{}", scale::read()),
        },
        // The main display's resolution; with WxH, set to it first.
        Some("resolution") => match std::env::args().nth(2) {
            Some(size) => println!(
                "{}",
                resolution::parse(&size).map(|(w, h)| resolution::set(w, h)).unwrap_or_else(|| serde_json::json!({ "error": "not WxH" }))
            ),
            None => println!("{}", resolution::read()),
        },
        Some("view") => {
            let mut input = std::io::stdin().lock();
            let Some(request) = request_line(&mut input) else { std::process::exit(2) };
            view::run(&request, &mut input, Out::new());
        }
        _ => {
            eprintln!("usage: comma-desktop-screen status | view | scale [percent] | resolution [WxH]");
            std::process::exit(2);
        }
    }
}

#[cfg(not(windows))]
fn main() {
    eprintln!("comma-desktop-screen is for Windows");
    std::process::exit(2);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_messages_and_the_request() {
        let mut bytes = b"{\"codec\":\"jpeg\"}\n".to_vec();
        bytes.extend_from_slice(&[1, 0, 0, 0, 0]);
        bytes.extend_from_slice(&[3, 0, 0, 0, 2, b'{', b'}']);
        let mut input = &bytes[..];
        assert_eq!(request_line(&mut input).unwrap()["codec"], "jpeg");
        assert_eq!(message(&mut input, 10), Some((1, vec![])));
        assert_eq!(message(&mut input, 10), Some((3, b"{}".to_vec())));
        assert_eq!(message(&mut input, 10), None);
    }

    #[test]
    fn a_message_past_its_bound_ends_the_input() {
        let bytes = [3u8, 0, 0, 1, 0];
        assert_eq!(message(&mut &bytes[..], 10), None);
    }
}
