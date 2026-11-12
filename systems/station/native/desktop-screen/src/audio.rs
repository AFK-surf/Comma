// System output (never the microphone), pulled in bounded PCM packets alongside a screen view.
// WASAPI loopback stays in shared mode, so it neither changes nor takes over the person's output device.
//
// Cue's own (systems/station/docs/desktop-screen.md, "Clipboard and sound"): the sound of the Comma app's process tree
// is left out. What the app plays is mostly another screen's sound, and captured it would go back there (two computers
// that view each other loop). The app says its process in COMMA_APP_PID (clients/apps/electron station.ts), which the
// station and this program inherit; the capture is then a process loopback that excludes that tree, where Windows
// has process loopback (build 20348 on; AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS). Without the variable, or where the
// process loopback cannot be activated or initialized, it is the output endpoint's loopback, as still.fail's is, and
// the app's sound is captured too: two such computers that view each other unmuted still loop. Either way an event
// says whether the app's sound is left out.
//
// Cue's own as well: a view that asked `audioCodec: "opus"` gets each packet as one Opus packet of the same 20 ms
// (opus.rs, about 64 kbit/s where PCM is 1.5 Mbit/s), as a Mac's helper does; message 8 says which.
use std::sync::mpsc::{Receiver, Sender, SyncSender, channel, sync_channel};
use std::time::Duration;
use windows::Win32::Media::Audio::*;
use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
use windows::Win32::System::Com::{BLOB, CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED};
use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};
use windows::Win32::System::Variant::VT_BLOB;
use windows_core::{Interface, Ref, implement};
use super::{Out, audio_queue::AudioQueue, opus::OpusPackets};

const RATE: u32 = 48_000;
const CHANNELS: u16 = 2;
const FRAME_BYTES: usize = CHANNELS as usize * 2;
const PACKET_FRAMES: usize = 960; // 20 ms
const PACKET_BYTES: usize = PACKET_FRAMES * FRAME_BYTES;

pub struct Audio { next: Sender<()> }
impl Audio {
    /// `opus`: the packets as Opus (PCM where the encoder cannot be made).
    pub fn start(out: Out, opus: bool) -> Self {
        let (tx, rx) = channel();
        std::thread::spawn(move || {
            unsafe {
                if CoInitializeEx(None, COINIT_MULTITHREADED).is_err() {
                    out.json(8, serde_json::json!({"error":"audio COM initialization failed"}));
                    return;
                }
                if let Err(e) = run(rx, &out, opus) {
                    out.json(8, serde_json::json!({"error":e.message()}));
                }
                CoUninitialize();
            }
        });
        Self { next: tx }
    }
    pub fn next(&self) { let _ = self.next.send(()); }
}

/// The Comma app's process (COMMA_APP_PID), whose tree's sound is left out.
fn comma_app() -> Option<u32> {
    std::env::var("COMMA_APP_PID").ok()?.trim().parse().ok().filter(|&pid| pid != 0)
}

unsafe fn run(rx: Receiver<()>, out: &Out, opus: bool) -> windows::core::Result<()> {
    unsafe {
        let format = WAVEFORMATEX { wFormatTag: 1, nChannels: CHANNELS, nSamplesPerSec: RATE,
            nAvgBytesPerSec: RATE * FRAME_BYTES as u32, nBlockAlign: FRAME_BYTES as u16, wBitsPerSample: 16, cbSize: 0 };
        let flags = AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        let without = comma_app().map(|pid| {
            excluding(pid).and_then(|client| client.Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2_000_000, 0, &format, None).map(|()| client))
        });
        let client = match without {
            Some(Ok(client)) => {
                out.json(4, serde_json::json!({"audio":"the Comma app's sound left out"}));
                client
            }
            other => {
                let why = match other {
                    Some(Err(e)) => e.message().to_string(),
                    _ => "no COMMA_APP_PID".to_string(),
                };
                out.json(4, serde_json::json!({"audio":format!("the Comma app's sound not left out: {why}")}));
                let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
                let device = devices.GetDefaultAudioEndpoint(eRender, eConsole)?;
                let client: IAudioClient = device.Activate(CLSCTX_ALL, None)?;
                client.Initialize(AUDCLNT_SHAREMODE_SHARED, flags, 2_000_000, 0, &format, None)?;
                client
            }
        };
        let capture: IAudioCaptureClient = client.GetService()?;
        client.Start()?;
        let encoder = if opus { OpusPackets::new() } else { None };
        let codec = if encoder.is_some() { "opus" } else { "pcm_s16le" };
        out.json(8, serde_json::json!({"codec":codec,"sampleRate":RATE,"channels":CHANNELS}));
        let result = packets(&capture, rx, out, encoder);
        let _ = client.Stop();
        result
    }
}

/// Says when the activation below has completed.
#[implement(IActivateAudioInterfaceCompletionHandler)]
struct Activated(SyncSender<()>);

impl IActivateAudioInterfaceCompletionHandler_Impl for Activated_Impl {
    fn ActivateCompleted(&self, _: Ref<IActivateAudioInterfaceAsyncOperation>) -> windows::core::Result<()> {
        let _ = self.0.try_send(());
        Ok(())
    }
}

/// An audio client of every process's output but `pid`'s and its descendants' (a process loopback), not initialized.
unsafe fn excluding(pid: u32) -> windows::core::Result<IAudioClient> {
    unsafe {
        let mut params = AUDIOCLIENT_ACTIVATION_PARAMS {
            ActivationType: AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK,
            Anonymous: AUDIOCLIENT_ACTIVATION_PARAMS_0 {
                ProcessLoopbackParams: AUDIOCLIENT_PROCESS_LOOPBACK_PARAMS {
                    TargetProcessId: pid,
                    ProcessLoopbackMode: PROCESS_LOOPBACK_MODE_EXCLUDE_TARGET_PROCESS_TREE,
                },
            },
        };
        // Its drop would clear it (PropVariantClear), freeing `params`, which is not the heap's.
        let mut blob = std::mem::ManuallyDrop::new(PROPVARIANT::default());
        let value = &mut *blob.Anonymous.Anonymous;
        value.vt = VT_BLOB;
        value.Anonymous.blob = BLOB { cbSize: size_of::<AUDIOCLIENT_ACTIVATION_PARAMS>() as u32, pBlobData: &mut params as *mut _ as *mut u8 };
        let (done, completed) = sync_channel(1);
        let handler: IActivateAudioInterfaceCompletionHandler = Activated(done).into();
        let operation = ActivateAudioInterfaceAsync(VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK, &IAudioClient::IID, Some(&*blob), &handler)?;
        if completed.recv_timeout(Duration::from_secs(5)).is_err() {
            return Err(windows::core::Error::new(windows::Win32::Foundation::E_FAIL, "the process loopback did not activate"));
        }
        let mut result = windows::core::HRESULT(0);
        let mut activated = None;
        operation.GetActivateResult(&mut result, &mut activated)?;
        result.ok()?;
        activated.ok_or_else(|| windows::core::Error::from(windows::Win32::Foundation::E_NOINTERFACE))?.cast()
    }
}

/// Now on the frames' clock (QPC, in 100 ns), for a packet the system gave no position (a process loopback's).
fn qpc_now() -> u64 {
    let (mut count, mut frequency) = (0i64, 0i64);
    // SAFETY: both write only the value given.
    unsafe {
        let _ = QueryPerformanceCounter(&mut count);
        let _ = QueryPerformanceFrequency(&mut frequency);
    }
    if frequency <= 0 { 0 } else { (count as i128 * 10_000_000 / frequency as i128) as u64 }
}

unsafe fn packets(capture: &IAudioCaptureClient, rx: Receiver<()>, out: &Out, mut encoder: Option<OpusPackets>) -> windows::core::Result<()> {
    // Drain WASAPI without discarding packets within a normal capture or network burst.
    let mut building = Vec::with_capacity(PACKET_BYTES);
    let mut queued = AudioQueue::new();
    let mut packet_ts = 0;
    let mut wanted = false;
    loop {
        match rx.recv_timeout(Duration::from_millis(5)) {
            Ok(()) => wanted = true,
            Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => return Ok(()),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
        }
        while rx.try_recv().is_ok() { wanted = true; }
        unsafe {
            while capture.GetNextPacketSize()? > 0 {
                let mut data = std::ptr::null_mut();
                let mut frames = 0;
                let mut flags = 0;
                let mut qpc = 0;
                capture.GetBuffer(&mut data, &mut frames, &mut flags, None, Some(&mut qpc))?;
                if qpc == 0 { qpc = qpc_now(); }
                if flags & AUDCLNT_BUFFERFLAGS_DATA_DISCONTINUITY.0 as u32 != 0 { building.clear(); }
                let silent = flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0;
                let size = frames as usize * FRAME_BYTES;
                // A packet from the system is bounded by its endpoint buffer. Copy before releasing that buffer.
                for offset in 0..size {
                    if building.is_empty() { packet_ts = qpc / 10 + (offset / FRAME_BYTES) as u64 * 1_000_000 / RATE as u64; }
                    building.push(if silent || data.is_null() { 0 } else { *data.add(offset) });
                    if building.len() == PACKET_BYTES {
                        queued.push((packet_ts,
                            std::mem::replace(&mut building, Vec::with_capacity(PACKET_BYTES))));
                    }
                }
                capture.ReleaseBuffer(frames)?;
            }
        }
        if wanted {
            if let Some((ts, pcm)) = queued.pop() {
                // (one in, one out: a packet the encoder gives nothing for is none to send; the next is)
                let Some(data) = (match encoder.as_mut() { Some(encoder) => encoder.encode(&pcm), None => Some(pcm) }) else { continue };
                let mut payload = Vec::with_capacity(8 + data.len());
                payload.extend_from_slice(&ts.to_be_bytes());
                payload.extend_from_slice(&data);
                out.send(9, &payload);
                wanted = false;
            }
        }
    }
}
