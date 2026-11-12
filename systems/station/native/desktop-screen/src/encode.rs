// H.264 with Media Foundation: the hardware encoder (an asynchronous MFT, given the D3D11 textures themselves) where
// the machine has one that takes them, else Microsoft's software encoder (given each picture's bytes). H.265 the same
// way, on the hardware only (Main; where the machine has no HEVC encoder, the view goes on in H.264). Low latency (a
// picture out for each in), no B-frames, constrained baseline where the encoder has it, a key frame when asked for and
// at least every 10 s besides. One picture is in it at a time: the view asks for the next only once one went. A still
// screen's picture sent again as a key frame (docs/remote-screens.md "Still") is encoded finer than the moving ones: its
// QP no higher than STILL_QP and twice the bit rate for it, where the link carries STILL_FROM or more. That is another
// encoder of the same kind, made for that picture with those set before it starts (`still`): an encoder takes them
// once it started without heeding them (NVIDIA's, both codecs: the same picture again the same size to the byte).
// The bit rate asked as it goes (the station's pace) the same: NVIDIA's encoders keep the one they started at whatever
// CODECAPI_AVEncCommonMeanBitRate is set to (asked 6 Mbit/s, ~25 went on), but its output type set again with the new
// MF_MT_AVG_BITRATE starts their rate control anew at it (`restart`: under a millisecond, its next picture a key frame,
// the same parameter sets), which the view does when the rate asked has gone far enough from it (pace.rs `restarts`).
use std::collections::VecDeque;

use windows::Win32::Graphics::Direct3D11::ID3D11Texture2D;
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{CLSCTX_INPROC_SERVER, CoCreateInstance, CoTaskMemFree};
use windows::Win32::System::Variant::VARIANT;
use windows::core::{GUID, Interface, PWSTR, Result};

use super::capture::Gpu;

/// One picture out: Annex B, its time (µs), whether the encoder marked it a key frame.
pub struct Encoded {
    pub stream: Vec<u8>,
    pub ts: i64,
    pub clean: bool,
    /// A key frame was asked of this one.
    pub asked: bool,
}

pub struct H264 {
    transform: IMFTransform,
    /// The asynchronous (hardware) encoder's events; none for the synchronous one.
    events: Option<IMFMediaEventGenerator>,
    codec: Option<ICodecAPI>,
    /// Takes D3D11 textures (else the picture's bytes, read back).
    gpu: bool,
    provides: bool,
    output_size: u32,
    /// Inputs the asynchronous encoder asked for and was not given yet.
    credits: u32,
    /// What was given and not come out yet: its time and whether a key frame was asked of it.
    pending: VecDeque<(i64, bool)>,
    staging: Option<ID3D11Texture2D>,
    pub width: u32,
    pub height: u32,
    pub name: String,
    /// H.265 (else H.264).
    pub hevc: bool,
    /// The parameter sets the output type names (an encoder that does not put them in band).
    pub header: Vec<u8>,
    /// The bit rate asked, and the one its rate control runs at (an encoder that `keeps_rate`: the one it started at,
    /// or was `restart`ed at).
    bitrate: u32,
    started: u32,
    /// The hardware encoder's name (to make another of it), empty for the software one.
    mft: String,
    /// The pictures a second it is set for (pace.rs `encoder_fps`: the view's 帧率, at most 60; 60 where none is asked):
    /// its rate control's bits a picture, its GOP (view.rs also asks a key frame every 10 s by the clock), each
    /// picture's duration.
    fps: u32,
    _manager: Option<IMFDXGIDeviceManager>,
}

/// A still picture's key frame: its QP at most this (of 51), at STILL_BOOST times the bit rate, where the bit rate asked
/// is STILL_FROM or more (a narrow link's would take seconds to go).
const STILL_QP: u32 = 28;
const STILL_BOOST: u32 = 2;
const STILL_FROM: u32 = 4_000_000;

fn set(codec: &ICodecAPI, api: &GUID, value: VARIANT) -> bool {
    unsafe { codec.SetValue(api, &value).is_ok() }
}

/// The hardware encoders that take NV12 to H.264 (or H.265), best first.
fn hardware(hevc: bool) -> Vec<IMFActivate> {
    let input = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: MFVideoFormat_NV12 };
    let output = MFT_REGISTER_TYPE_INFO { guidMajorType: MFMediaType_Video, guidSubtype: if hevc { MFVideoFormat_HEVC } else { MFVideoFormat_H264 } };
    let mut found: *mut Option<IMFActivate> = std::ptr::null_mut();
    let mut count = 0u32;
    let mut all = Vec::new();
    unsafe {
        if MFTEnumEx(MFT_CATEGORY_VIDEO_ENCODER, MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_SORTANDFILTER, Some(&input), Some(&output), &mut found, &mut count).is_err() || found.is_null() {
            return all;
        }
        for i in 0..count as usize {
            if let Some(activate) = (*found.add(i)).take() {
                all.push(activate);
            }
        }
        CoTaskMemFree(Some(found as _));
    }
    all
}

/// The parameter sets its output type names.
fn sequence_header(transform: &IMFTransform) -> Option<Vec<u8>> {
    unsafe {
        let t = transform.GetOutputCurrentType(0).ok()?;
        let n = t.GetBlobSize(&MF_MT_MPEG_SEQUENCE_HEADER).ok()?;
        let mut blob = vec![0u8; n as usize];
        t.GetBlob(&MF_MT_MPEG_SEQUENCE_HEADER, &mut blob, None).ok()?;
        Some(blob)
    }
}

fn friendly(activate: &IMFActivate) -> String {
    let mut name = PWSTR::null();
    let mut length = 0u32;
    unsafe {
        if activate.GetAllocatedString(&MFT_FRIENDLY_NAME_Attribute, &mut name, &mut length).is_ok() && !name.is_null() {
            let s = name.to_string().unwrap_or_default();
            CoTaskMemFree(Some(name.0 as _));
            return s;
        }
    }
    "hardware".into()
}

impl H264 {
    /// The best H.265 encoder there is for `width`×`height`, on the hardware; an error where there is none.
    pub fn hevc(gpu: &Gpu, width: u32, height: u32, bitrate: u32, fps: u32) -> Result<H264> {
        H264::make(gpu, true, false, None, width, height, bitrate, fps, false)
    }

    /// The best encoder there is for `width`×`height`: hardware first (unless `software`), then software.
    pub fn new(gpu: &Gpu, width: u32, height: u32, bitrate: u32, fps: u32, software: bool) -> Result<H264> {
        H264::make(gpu, false, software, None, width, height, bitrate, fps, false)
    }

    /// Whether a still picture's key frame is encoded finer (by `still`'s encoder) at the bit rate asked now.
    pub fn sharpens(&self) -> bool {
        self.bitrate >= STILL_FROM
    }

    /// Another encoder of this one's kind, codec, size and profile, for a still picture's key frame: its QP at most
    /// STILL_QP and STILL_BOOST times the bit rate asked now, set before it starts.
    pub fn still(&self, gpu: &Gpu) -> Result<H264> {
        let hardware = (!self.mft.is_empty()).then_some(self.mft.as_str());
        H264::make(gpu, self.hevc, hardware.is_none(), hardware, self.width, self.height, self.bitrate.saturating_mul(STILL_BOOST), self.fps, true)
    }

    /// The first hardware encoder (the one named `only`, where given) that opens, else (H.264, unless `only`) the
    /// software one.
    #[allow(clippy::too_many_arguments)]
    fn make(gpu: &Gpu, hevc: bool, software: bool, only: Option<&str>, width: u32, height: u32, bitrate: u32, fps: u32, still: bool) -> Result<H264> {
        let mut last = None;
        for activate in if software { Vec::new() } else { hardware(hevc) } {
            let name = friendly(&activate);
            if only.is_some_and(|o| o != name) {
                continue;
            }
            match unsafe { activate.ActivateObject::<IMFTransform>() }.and_then(|t| H264::open(gpu, t, true, hevc, width, height, bitrate, fps, still, name)) {
                Ok(encoder) => return Ok(encoder),
                Err(error) => {
                    unsafe {
                        let _ = activate.ShutdownObject();
                    }
                    last = Some(error);
                }
            }
        }
        if hevc || only.is_some() {
            let what = if hevc { "no H.265 encoder on this machine's hardware" } else { "the hardware encoder is not there" };
            return Err(last.unwrap_or_else(|| windows::core::Error::new(MF_E_TOPO_CODEC_NOT_FOUND, what)));
        }
        let software: Result<IMFTransform> = unsafe { CoCreateInstance(&CLSID_MSH264EncoderMFT, None, CLSCTX_INPROC_SERVER) };
        match software.and_then(|t| H264::open(gpu, t, false, false, width, height, bitrate, fps, still, "Microsoft H.264 (software)".into())) {
            Ok(encoder) => Ok(encoder),
            Err(error) => Err(last.unwrap_or(error)),
        }
    }

    #[allow(clippy::too_many_arguments)]
    fn open(gpu: &Gpu, transform: IMFTransform, hardware: bool, hevc: bool, width: u32, height: u32, bitrate: u32, fps: u32, still: bool, name: String) -> Result<H264> {
        unsafe {
            let attributes = transform.GetAttributes().ok();
            let asynchronous = attributes.as_ref().and_then(|a| a.GetUINT32(&MF_TRANSFORM_ASYNC).ok()).unwrap_or(0) != 0;
            if asynchronous {
                attributes.as_ref().unwrap().SetUINT32(&MF_TRANSFORM_ASYNC_UNLOCK, 1)?;
            }
            if let Some(a) = attributes.as_ref() {
                let _ = a.SetUINT32(&MF_LOW_LATENCY, 1);
            }
            // The hardware encoder reads the textures on the device; without it, it is not used (the software one is).
            let mut manager = None;
            let mut gpu_input = false;
            if hardware {
                let mut token = 0u32;
                let mut made = None;
                MFCreateDXGIDeviceManager(&mut token, &mut made)?;
                let made = made.unwrap();
                made.ResetDevice(&gpu.device, token)?;
                transform.ProcessMessage(MFT_MESSAGE_SET_D3D_MANAGER, made.as_raw() as usize)?;
                manager = Some(made);
                gpu_input = true;
            }
            let codec = transform.cast::<ICodecAPI>().ok();
            if let Some(c) = codec.as_ref() {
                set(c, &CODECAPI_AVLowLatencyMode, VARIANT::from(true));
                let _ = set(c, &CODECAPI_AVEncCommonRateControlMode, VARIANT::from(eAVEncCommonRateControlMode_LowDelayVBR.0 as u32))
                    || set(c, &CODECAPI_AVEncCommonRateControlMode, VARIANT::from(eAVEncCommonRateControlMode_CBR.0 as u32));
                set(c, &CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(bitrate));
                set(c, &CODECAPI_AVEncMPVDefaultBPictureCount, VARIANT::from(0u32));
                set(c, &CODECAPI_AVEncMPVGOPSize, VARIANT::from(fps * 10));
                // A still picture's (bitrate already raised): an encoder that takes no QP bound keeps its own.
                if still {
                    set(c, &CODECAPI_AVEncVideoMaxQP, VARIANT::from(STILL_QP));
                }
            }
            let size = ((width as u64) << 32) | height as u64;
            let rate = ((fps as u64) << 32) | 1;
            // H.264: constrained baseline, as every decoder takes it; baseline, then main (no B-frames asked) where not.
            // H.265: Main, 8 bits 4:2:0.
            let mut profile = "";
            let profiles: &[(u32, &str)] = if hevc {
                &[(eAVEncH265VProfile_Main_420_8.0 as u32, "H.265 main")]
            } else {
                &[(eAVEncH264VProfile_ConstrainedBase.0 as u32, "constrained baseline"), (eAVEncH264VProfile_Base.0 as u32, "baseline"), (eAVEncH264VProfile_Main.0 as u32, "main")]
            };
            for &(p, named) in profiles {
                let output = MFCreateMediaType()?;
                output.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
                output.SetGUID(&MF_MT_SUBTYPE, if hevc { &MFVideoFormat_HEVC } else { &MFVideoFormat_H264 })?;
                output.SetUINT32(&MF_MT_AVG_BITRATE, bitrate)?;
                output.SetUINT64(&MF_MT_FRAME_SIZE, size)?;
                output.SetUINT64(&MF_MT_FRAME_RATE, rate)?;
                output.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
                output.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
                output.SetUINT32(&MF_MT_MPEG2_PROFILE, p)?;
                output.SetUINT32(&MF_MT_VIDEO_PRIMARIES, MFVideoPrimaries_BT709.0 as u32)?;
                output.SetUINT32(&MF_MT_TRANSFER_FUNCTION, MFVideoTransFunc_709.0 as u32)?;
                output.SetUINT32(&MF_MT_YUV_MATRIX, MFVideoTransferMatrix_BT709.0 as u32)?;
                output.SetUINT32(&MF_MT_VIDEO_NOMINAL_RANGE, MFNominalRange_16_235.0 as u32)?;
                if transform.SetOutputType(0, &output, 0).is_ok() {
                    profile = named;
                    break;
                }
            }
            if profile.is_empty() {
                return Err(windows::core::Error::new(MF_E_INVALIDMEDIATYPE, "the encoder takes no profile asked"));
            }
            let input = MFCreateMediaType()?;
            input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Video)?;
            input.SetGUID(&MF_MT_SUBTYPE, &MFVideoFormat_NV12)?;
            input.SetUINT64(&MF_MT_FRAME_SIZE, size)?;
            input.SetUINT64(&MF_MT_FRAME_RATE, rate)?;
            input.SetUINT64(&MF_MT_PIXEL_ASPECT_RATIO, (1u64 << 32) | 1)?;
            input.SetUINT32(&MF_MT_INTERLACE_MODE, MFVideoInterlace_Progressive.0 as u32)?;
            transform.SetInputType(0, &input, 0)?;
            let info = transform.GetOutputStreamInfo(0)?;
            let provides = info.dwFlags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES.0 as u32 | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES.0 as u32) != 0;
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0)?;
            transform.ProcessMessage(MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0)?;
            let header = sequence_header(&transform).unwrap_or_default();
            let events = if asynchronous { Some(transform.cast::<IMFMediaEventGenerator>()?) } else { None };
            Ok(H264 {
                transform,
                events,
                codec,
                gpu: gpu_input,
                provides,
                output_size: info.cbSize.max(width * height * 2),
                credits: 0,
                pending: VecDeque::new(),
                staging: None,
                width,
                height,
                name: format!("{name}, {profile}, {bitrate} bps, {fps} fps"),
                hevc,
                header,
                bitrate,
                started: bitrate,
                fps,
                mft: if hardware { name } else { String::new() },
                _manager: manager,
            })
        }
    }

    /// From the next frame on, about this many bits a second (an encoder that `keeps_rate` once `restart`ed).
    pub fn rate(&mut self, bitrate: u32) {
        self.bitrate = bitrate;
        if let Some(c) = self.codec.as_ref() {
            set(c, &CODECAPI_AVEncCommonMeanBitRate, VARIANT::from(bitrate));
        }
    }

    /// Whether it keeps the bit rate it started at whatever `rate` asks (NVIDIA's, both codecs). Microsoft's software
    /// encoder heeds it from the next frame; Intel's and AMD's are said to.
    pub fn keeps_rate(&self) -> bool {
        self.mft.starts_with("NVIDIA")
    }

    /// The bit rate its rate control runs at, and the one asked.
    pub fn rates(&self) -> (u32, u32) {
        (self.started, self.bitrate)
    }

    /// Its rate control started anew at the bit rate asked: its output type set again with it (no picture may be in
    /// it). The next picture comes out a key frame; the caller asks for one too.
    pub fn restart(&mut self) -> Result<()> {
        unsafe {
            let output = self.transform.GetOutputCurrentType(0)?;
            output.SetUINT32(&MF_MT_AVG_BITRATE, self.bitrate)?;
            self.transform.SetOutputType(0, &output, 0)?;
            if let Some(header) = sequence_header(&self.transform) {
                self.header = header;
            }
        }
        self.started = self.bitrate;
        Ok(())
    }

    /// A picture is in it, not out yet.
    pub fn busy(&self) -> bool {
        !self.pending.is_empty()
    }

    /// Whether it takes a picture now (the asynchronous encoder: once it asked for one).
    pub fn ready(&mut self, out: &mut Vec<Encoded>) -> Result<bool> {
        self.drain(out)?;
        Ok(self.pending.is_empty() && (self.events.is_none() || self.credits > 0))
    }

    /// `texture` (NV12, its size) in, at `ts` (µs), a key frame when `key`.
    pub fn push(&mut self, gpu: &Gpu, texture: &ID3D11Texture2D, ts: i64, key: bool) -> Result<()> {
        unsafe {
            let buffer = if self.gpu {
                let buffer = MFCreateDXGISurfaceBuffer(&ID3D11Texture2D::IID, texture, 0, false)?;
                if let Ok(two) = buffer.cast::<IMF2DBuffer>() {
                    buffer.SetCurrentLength(two.GetContiguousLength()?)?;
                }
                buffer
            } else {
                let (bytes, pitch) = gpu.read(texture, &mut self.staging)?;
                let (w, h) = (self.width as usize, self.height as usize);
                let length = w * h * 3 / 2;
                let buffer = MFCreateMemoryBuffer(length as u32)?;
                let mut to = std::ptr::null_mut();
                buffer.Lock(&mut to, None, None)?;
                for row in 0..h * 3 / 2 {
                    std::ptr::copy_nonoverlapping(bytes.as_ptr().add(row * pitch), to.add(row * w), w);
                }
                buffer.Unlock()?;
                buffer.SetCurrentLength(length as u32)?;
                buffer
            };
            let sample = MFCreateSample()?;
            sample.AddBuffer(&buffer)?;
            sample.SetSampleTime(ts * 10)?;
            sample.SetSampleDuration(10_000_000 / self.fps as i64)?;
            if key {
                if let Some(c) = self.codec.as_ref() {
                    set(c, &CODECAPI_AVEncVideoForceKeyFrame, VARIANT::from(1u32));
                }
            }
            self.transform.ProcessInput(0, &sample, 0)?;
            self.credits = self.credits.saturating_sub(1);
            self.pending.push_back((ts, key));
        }
        Ok(())
    }

    /// What came out since.
    pub fn poll(&mut self) -> Result<Vec<Encoded>> {
        let mut out = Vec::new();
        self.drain(&mut out)?;
        if self.events.is_none() {
            while let Some(e) = self.output()? {
                out.push(e);
            }
        }
        Ok(out)
    }

    fn drain(&mut self, out: &mut Vec<Encoded>) -> Result<()> {
        let Some(events) = self.events.clone() else { return Ok(()) };
        loop {
            let event = match unsafe { events.GetEvent(MF_EVENT_FLAG_NO_WAIT) } {
                Ok(e) => e,
                Err(e) if e.code() == MF_E_NO_EVENTS_AVAILABLE => return Ok(()),
                Err(e) => return Err(e),
            };
            let kind = unsafe { event.GetType()? };
            if kind == METransformNeedInput.0 as u32 {
                self.credits += 1;
            } else if kind == METransformHaveOutput.0 as u32 {
                if let Some(e) = self.output()? {
                    out.push(e);
                }
            }
        }
    }

    fn output(&mut self) -> Result<Option<Encoded>> {
        unsafe {
            let given = if self.provides {
                None
            } else {
                let sample = MFCreateSample()?;
                sample.AddBuffer(&MFCreateMemoryBuffer(self.output_size)?)?;
                Some(sample)
            };
            let mut buffers = [MFT_OUTPUT_DATA_BUFFER { dwStreamID: 0, pSample: std::mem::ManuallyDrop::new(given), dwStatus: 0, pEvents: std::mem::ManuallyDrop::new(None) }];
            let mut status = 0u32;
            let done = self.transform.ProcessOutput(0, &mut buffers, &mut status);
            let [buffer] = buffers;
            let sample = std::mem::ManuallyDrop::into_inner(buffer.pSample);
            drop(std::mem::ManuallyDrop::into_inner(buffer.pEvents));
            match done {
                Ok(()) => {}
                Err(e) if e.code() == MF_E_TRANSFORM_NEED_MORE_INPUT => return Ok(None),
                Err(e) if e.code() == MF_E_TRANSFORM_STREAM_CHANGE => {
                    // The encoder chose its output anew: taken as it offers it.
                    let offered = self.transform.GetOutputAvailableType(0, 0)?;
                    self.transform.SetOutputType(0, &offered, 0)?;
                    return Ok(None);
                }
                Err(e) => return Err(e),
            }
            let Some(sample) = sample else { return Ok(None) };
            let contiguous = sample.ConvertToContiguousBuffer()?;
            let mut from = std::ptr::null_mut();
            let mut length = 0u32;
            contiguous.Lock(&mut from, None, Some(&mut length))?;
            let stream = std::slice::from_raw_parts(from, length as usize).to_vec();
            contiguous.Unlock()?;
            let clean = sample.GetUINT32(&MFSampleExtension_CleanPoint).unwrap_or(0) != 0;
            let time = sample.GetSampleTime().map(|t| t / 10).ok();
            // Matched to what went in: the oldest given (its time, as the encoder may round it).
            let (ts, asked) = self.pending.pop_front().unwrap_or((time.unwrap_or(0), false));
            Ok(Some(Encoded { stream, ts, clean, asked }))
        }
    }
}

impl Drop for H264 {
    fn drop(&mut self) {
        unsafe {
            let _ = self.transform.ProcessMessage(MFT_MESSAGE_NOTIFY_END_OF_STREAM, 0);
            let _ = self.transform.ProcessMessage(MFT_MESSAGE_COMMAND_FLUSH, 0);
            if let Ok(shutdown) = self.transform.cast::<IMFShutdown>() {
                let _ = shutdown.Shutdown();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::{Duration, Instant};

    use windows::Win32::Graphics::Direct3D11::*;
    use windows::Win32::Graphics::Dxgi::Common::{DXGI_FORMAT_NV12, DXGI_SAMPLE_DESC};
    use windows::Win32::System::Com::{COINIT_MULTITHREADED, CoInitializeEx};

    use super::*;

    /// A desktop's page (NV12): light, lines of small dark marks as text, a coloured side bar, a grey ramp.
    fn page(width: u32, height: u32) -> Vec<u8> {
        let (w, h) = (width as usize, height as usize);
        let mut bytes = vec![128u8; w * h * 3 / 2];
        let mut seed = 7u32;
        let mut next = move || {
            seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
            seed >> 8
        };
        let glyphs: Vec<u32> = (0..4096).map(|_| next()).collect();
        for y in 0..h {
            for x in 0..w {
                bytes[y * w + x] = if x < w / 8 {
                    (16 + 200 * y / h) as u8
                } else if y % 28 < 16 && (x / 8) % 12 != 11 && (y / 28) % 9 != 8 {
                    // A glyph: 8×16 of 2×2 dots, picked by its place.
                    let glyph = glyphs[((y / 28) * 977 + x / 8) % glyphs.len()];
                    let bit = ((y % 28) / 2) * 4 + (x % 8) / 2;
                    if glyph >> (bit % 24) & 1 == 1 { 40 } else { 235 }
                } else {
                    235
                };
            }
        }
        for y in 0..h / 2 {
            for x in 0..w / 2 {
                if x < w / 16 {
                    bytes[w * h + y * w + x * 2] = 90;
                    bytes[w * h + y * w + x * 2 + 1] = 160;
                }
            }
        }
        bytes
    }

    /// A picture that moves (NV12): the page scrolled by `i`, a patch of grain changing as video does.
    fn moving(gpu: &Gpu, page: &[u8], width: u32, height: u32, i: usize) -> ID3D11Texture2D {
        let (w, h) = (width as usize, height as usize);
        let mut bytes = vec![128u8; w * h * 3 / 2];
        for y in 0..h {
            let from = (y + i * 6) % h;
            bytes[y * w..y * w + w].copy_from_slice(&page[from * w..from * w + w]);
        }
        let mut seed = (i as u32).wrapping_mul(2_654_435_761).wrapping_add(1);
        for y in h / 10..h / 10 + h / 3 {
            for x in w / 4..w / 4 + w / 3 {
                seed = seed.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                bytes[y * w + x] = ((x + y + i * 3) % 200) as u8 / 2 + (seed >> 26) as u8 * 2;
            }
        }
        texture(gpu, width, height, &bytes)
    }

    fn texture(gpu: &Gpu, width: u32, height: u32, bytes: &[u8]) -> ID3D11Texture2D {
        let desc = D3D11_TEXTURE2D_DESC {
            Width: width,
            Height: height,
            MipLevels: 1,
            ArraySize: 1,
            Format: DXGI_FORMAT_NV12,
            SampleDesc: DXGI_SAMPLE_DESC { Count: 1, Quality: 0 },
            Usage: D3D11_USAGE_DEFAULT,
            BindFlags: D3D11_BIND_RENDER_TARGET.0 as u32,
            CPUAccessFlags: 0,
            MiscFlags: 0,
        };
        let data = D3D11_SUBRESOURCE_DATA { pSysMem: bytes.as_ptr() as _, SysMemPitch: width, SysMemSlicePitch: 0 };
        let mut texture = None;
        unsafe { gpu.device.CreateTexture2D(&desc, Some(&data), Some(&mut texture)).unwrap() };
        texture.unwrap()
    }

    /// One picture through `encoder`, what came of it.
    fn one(encoder: &mut H264, gpu: &Gpu, picture: &ID3D11Texture2D, ts: i64, key: bool) -> Encoded {
        let until = Instant::now() + Duration::from_secs(5);
        let mut out = Vec::new();
        while !encoder.ready(&mut out).unwrap() {
            assert!(Instant::now() < until, "the encoder takes no picture");
            std::thread::sleep(Duration::from_millis(1));
        }
        encoder.push(gpu, picture, ts, key).unwrap();
        loop {
            if let Some(e) = encoder.poll().unwrap().pop() {
                return e;
            }
            assert!(Instant::now() < until, "the encoder gave nothing back");
            std::thread::sleep(Duration::from_millis(1));
        }
    }

    #[test]
    fn a_still_pictures_key_frame_is_finer() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let _ = MFStartup(MF_VERSION, MFSTARTUP_LITE);
        }
        let Ok(gpu) = Gpu::new() else {
            eprintln!("no GPU here: not tried");
            return;
        };
        let (width, height, rate) = (3840, 2160, 8_000_000);
        let picture = texture(&gpu, width, height, &page(width, height));
        for hevc in [false, true] {
            let made = if hevc { H264::hevc(&gpu, width, height, rate, 60) } else { H264::new(&gpu, width, height, rate, 60, false) };
            let Ok(mut moving) = made else {
                eprintln!("no {} encoder here", if hevc { "H.265" } else { "H.264" });
                continue;
            };
            assert!(moving.sharpens());
            for i in 0..5 {
                one(&mut moving, &gpu, &picture, i * 16_667, i == 0);
            }
            // The same picture again as a key frame, by the view's encoder (as before) and by one made for it.
            let again = one(&mut moving, &gpu, &picture, 5 * 16_667, true);
            let at = Instant::now();
            let mut still = moving.still(&gpu).unwrap();
            let made_in = at.elapsed();
            let sharp = one(&mut still, &gpu, &picture, 6 * 16_667, true);
            eprintln!("{}: key frame again {} bytes, the still one's {} bytes (its encoder made in {made_in:?})", moving.name, again.stream.len(), sharp.stream.len());
            let key = if hevc { crate::hevc::picture(&sharp.stream).key } else { crate::avc::picture(&sharp.stream).key };
            assert!(key, "the still one's is a key frame");
            assert!(sharp.stream.len() > again.stream.len() * 3 / 2, "{} bytes, not finer than {}", sharp.stream.len(), again.stream.len());
        }
    }

    #[test]
    fn a_rate_asked_lower_is_kept() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let _ = MFStartup(MF_VERSION, MFSTARTUP_LITE);
        }
        let Ok(gpu) = Gpu::new() else {
            eprintln!("no GPU here: not tried");
            return;
        };
        let (width, height) = (3840, 2160);
        let page = page(width, height);
        for hevc in [false, true] {
            let made = if hevc { H264::hevc(&gpu, width, height, 25_000_000, 60) } else { H264::new(&gpu, width, height, 25_000_000, 60, false) };
            let Ok(mut encoder) = made else {
                eprintln!("no {} encoder here", if hevc { "H.265" } else { "H.264" });
                continue;
            };
            let mut n = 0;
            let mut through = |encoder: &mut H264, count: usize, key: bool| {
                let mut bytes = Vec::new();
                for i in 0..count {
                    let picture = moving(&gpu, &page, width, height, n);
                    let e = one(encoder, &gpu, &picture, n as i64 * 16_667, key && i == 0);
                    n += 1;
                    bytes.push(e.stream.len());
                }
                bytes
            };
            let before = through(&mut encoder, 30, true);
            let started = before[10..].iter().sum::<usize>() as f64 * 8.0 * 60.0 / 20.0;
            // As the view does: asked, then started anew where it keeps the rate it started at.
            encoder.rate(6_000_000);
            let restarted = encoder.keeps_rate();
            if restarted {
                let at = Instant::now();
                encoder.restart().unwrap();
                eprintln!("{}: started anew in {:?}", encoder.name, at.elapsed());
            }
            let bytes = through(&mut encoder, 90, restarted);
            // Its rate control settled: a second of pictures, at 60 a second.
            let rate = bytes[30..].iter().sum::<usize>() as f64 * 8.0;
            eprintln!("{}: {:.1} Mbit/s, asked 6 Mbit/s: {:.1} Mbit/s (its first picture {} bytes)", encoder.name, started / 1e6, rate / 1e6, bytes[0]);
            // The picture takes more than 6 Mbit/s at the rate it started at (else nothing is shown here).
            assert!(started > 12_000_000.0, "{}: {started} bit/s at the start", encoder.name);
            assert!(rate < 6_000_000.0 * 1.5, "{}: {rate} bit/s", encoder.name);
            assert_eq!(encoder.rates(), (6_000_000, 6_000_000));
        }
    }
}
