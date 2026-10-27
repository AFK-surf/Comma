//! The microphone: the default capture device through WASAPI, shared, as 16 kHz mono s16le (live dictation's rate;
//! Windows converts), with the speech category's processing (noise suppression and gain control where the device has
//! them). A thread of its own hands each packet to `on_samples`; dropping the `Microphone` stops it.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;

use windows::core::{Interface, Result};
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0};
use windows::Win32::Media::Audio::{
    eCapture, eConsole, AudioCategory_Speech, AudioClientProperties, IAudioCaptureClient, IAudioClient, IAudioClient2,
    IMMDeviceEnumerator, MMDeviceEnumerator, AUDCLNT_BUFFERFLAGS_SILENT, AUDCLNT_SHAREMODE_SHARED,
    AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM, AUDCLNT_STREAMFLAGS_EVENTCALLBACK, AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
    WAVEFORMATEX, WAVE_FORMAT_PCM,
};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED};
use windows::Win32::System::Threading::{CreateEventW, WaitForSingleObject};

pub const SAMPLE_RATE: u32 = 16_000;

pub struct Microphone {
    running: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
}

impl Microphone {
    /// Starts hearing; `on_samples` gets each packet, `on_failure` says why it could not start (or stopped).
    pub fn start(
        mut on_samples: impl FnMut(&[i16]) + Send + 'static,
        on_failure: impl FnOnce(windows::core::Error) + Send + 'static,
    ) -> Self {
        let running = Arc::new(AtomicBool::new(true));
        let alive = running.clone();
        let thread = std::thread::spawn(move || {
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            }
            if let Err(error) = capture(&alive, &mut on_samples) {
                on_failure(error);
            }
            unsafe { CoUninitialize() };
        });
        Self { running, thread: Some(thread) }
    }
}

impl Drop for Microphone {
    fn drop(&mut self) {
        self.running.store(false, Ordering::SeqCst);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

fn capture(running: &AtomicBool, on_samples: &mut dyn FnMut(&[i16])) -> Result<()> {
    unsafe {
        let enumerator: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
        let device = enumerator.GetDefaultAudioEndpoint(eCapture, eConsole)?;
        let client: IAudioClient = device.Activate(CLSCTX_ALL, None)?;
        if let Ok(client2) = client.cast::<IAudioClient2>() {
            let properties = AudioClientProperties {
                cbSize: std::mem::size_of::<AudioClientProperties>() as u32,
                eCategory: AudioCategory_Speech,
                ..Default::default()
            };
            let _ = client2.SetClientProperties(&properties);
        }
        let format = WAVEFORMATEX {
            wFormatTag: WAVE_FORMAT_PCM as u16,
            nChannels: 1,
            nSamplesPerSec: SAMPLE_RATE,
            nAvgBytesPerSec: SAMPLE_RATE * 2,
            nBlockAlign: 2,
            wBitsPerSample: 16,
            cbSize: 0,
        };
        // 100 ms of buffer, in 100 ns units.
        client.Initialize(
            AUDCLNT_SHAREMODE_SHARED,
            AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY,
            1_000_000,
            0,
            &format,
            None,
        )?;
        let event: HANDLE = CreateEventW(None, false, false, None)?;
        client.SetEventHandle(event)?;
        let reader: IAudioCaptureClient = client.GetService()?;
        client.Start()?;
        let mut samples = Vec::new();
        while running.load(Ordering::SeqCst) {
            if WaitForSingleObject(event, 200) != WAIT_OBJECT_0 {
                continue;
            }
            loop {
                let packet = reader.GetNextPacketSize()?;
                if packet == 0 {
                    break;
                }
                let (mut data, mut frames, mut flags) = (std::ptr::null_mut::<u8>(), 0u32, 0u32);
                reader.GetBuffer(&mut data, &mut frames, &mut flags, None, None)?;
                samples.clear();
                if flags & AUDCLNT_BUFFERFLAGS_SILENT.0 as u32 != 0 || data.is_null() {
                    samples.resize(frames as usize, 0);
                } else {
                    samples.extend_from_slice(std::slice::from_raw_parts(data as *const i16, frames as usize));
                }
                reader.ReleaseBuffer(frames)?;
                on_samples(&samples);
            }
        }
        let _ = client.Stop();
        let _ = CloseHandle(event);
    }
    Ok(())
}

/// RMS of `samples` in dBFS.
pub fn decibels(samples: &[i16]) -> f32 {
    if samples.is_empty() {
        return -140.0;
    }
    let sum: f64 = samples.iter().map(|&s| (s as f64 / 32768.0).powi(2)).sum();
    (20.0 * (sum / samples.len() as f64).sqrt().max(1e-7).log10()) as f32
}

/// How loud the voice looks, 0…1: -50 dB is silence, -10 dB full.
pub fn voice_level(db: f32) -> f32 {
    ((db + 50.0) / 40.0).clamp(0.0, 1.0)
}

/// Finds the person's pauses in the microphone's loudness, as QuickChatCore's SpeechPause does on macOS: speech is
/// `SPEECH_DB` louder than a noise floor that follows the quietest sound and rises slowly toward louder sound; a pause
/// is `PAUSE_SECONDS` without speech after some. Speech is also at least `QUIETEST_SPEECH_DB`: Windows' gain control
/// can turn a muted or silent input into digital near-silence, where a whisper of noise is 12 dB over the floor.
#[derive(Default)]
pub struct SpeechPause {
    floor: Option<f32>,
    pub spoke: bool,
    quiet: f32,
}

impl SpeechPause {
    const PAUSE_SECONDS: f32 = 0.6;
    const SPEECH_DB: f32 = 12.0;
    const QUIETEST_SPEECH_DB: f32 = -50.0;
    const FLOOR_RISE_DB_PER_SECOND: f32 = 2.0;

    /// One buffer of `seconds` of audio, `loudness` loud (RMS, dBFS). True for the buffer that completes a pause; once
    /// for each pause.
    pub fn hear(&mut self, loudness: f32, seconds: f32) -> bool {
        let floor = loudness.min(self.floor.unwrap_or(loudness) + Self::FLOOR_RISE_DB_PER_SECOND * seconds);
        self.floor = Some(floor);
        if loudness > (floor + Self::SPEECH_DB).max(Self::QUIETEST_SPEECH_DB) {
            self.spoke = true;
            self.quiet = 0.0;
            return false;
        }
        self.quiet += seconds;
        if !self.spoke || self.quiet + 1e-4 < Self::PAUSE_SECONDS {
            return false;
        }
        self.spoke = false;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pauses(levels: &[f32]) -> Vec<usize> {
        let mut pause = SpeechPause::default();
        levels.iter().enumerate().filter(|&(_, &db)| pause.hear(db, 0.02)).map(|(i, _)| i).collect()
    }

    #[test]
    fn a_pause_comes_0_6_s_after_speech_once() {
        let levels: Vec<f32> = [vec![-60.0; 25], vec![-25.0; 50], vec![-60.0; 80]].concat();
        assert_eq!(pauses(&levels), vec![25 + 50 + 29]);
    }

    #[test]
    fn noise_alone_has_no_pause() {
        assert!(pauses(&[-60.0; 200]).is_empty());
        let levels: Vec<f32> = [vec![-110.0; 25], vec![-90.0; 50], vec![-110.0; 80]].concat();
        assert!(pauses(&levels).is_empty());
    }

    #[test]
    fn loudness_is_rms_in_dbfs() {
        assert!((decibels(&[16384, -16384, 16384, -16384]) + 6.02).abs() < 0.1);
        assert_eq!(decibels(&[]), -140.0);
    }
}
