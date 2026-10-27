//! A clip of what was said, for the server to transcribe when there is no live dictation: the microphone's 16 kHz PCM
//! as M4A (AAC), which `recordings.transcribe` takes, as the page's MediaRecorder and macOS's clips gave it. Windows'
//! AAC encoder takes 44.1 or 48 kHz, so the samples are brought to 48 kHz first.

use windows::core::{Result, PCWSTR};
use windows::Win32::Media::MediaFoundation::*;
use windows::Win32::System::Com::{IStream, STREAM_SEEK_END, STREAM_SEEK_SET};
use windows::Win32::UI::Shell::SHCreateMemStream;

const RATE: u32 = 48_000;
/// 96 kbit/s, one of the encoder's rates.
const AAC_BYTES_PER_SECOND: u32 = 12_000;

/// `samples` (16 kHz mono s16) as an M4A file.
pub fn m4a(samples: &[i16]) -> Result<Vec<u8>> {
    unsafe {
        let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED);
        MFStartup(MF_VERSION, MFSTARTUP_LITE)?;
        let encoded = encode(samples);
        let _ = MFShutdown();
        encoded
    }
}

unsafe fn encode(samples: &[i16]) -> Result<Vec<u8>> {
    unsafe {
        let stream: IStream = SHCreateMemStream(None).ok_or_else(windows::core::Error::from_win32)?;
        let bytes = MFCreateMFByteStreamOnStream(&stream)?;
        let mut attributes = None;
        MFCreateAttributes(&mut attributes, 1)?;
        let attributes = attributes.unwrap();
        attributes.SetGUID(&MF_TRANSCODE_CONTAINERTYPE, &MFTranscodeContainerType_MPEG4)?;
        let writer = MFCreateSinkWriterFromURL(PCWSTR::null(), &bytes, &attributes)?;

        let output = MFCreateMediaType()?;
        output.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
        output.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_AAC)?;
        output.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
        output.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, RATE)?;
        output.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, 1)?;
        output.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, AAC_BYTES_PER_SECOND)?;
        let index = writer.AddStream(&output)?;

        let input = MFCreateMediaType()?;
        input.SetGUID(&MF_MT_MAJOR_TYPE, &MFMediaType_Audio)?;
        input.SetGUID(&MF_MT_SUBTYPE, &MFAudioFormat_PCM)?;
        input.SetUINT32(&MF_MT_AUDIO_BITS_PER_SAMPLE, 16)?;
        input.SetUINT32(&MF_MT_AUDIO_SAMPLES_PER_SECOND, RATE)?;
        input.SetUINT32(&MF_MT_AUDIO_NUM_CHANNELS, 1)?;
        input.SetUINT32(&MF_MT_AUDIO_BLOCK_ALIGNMENT, 2)?;
        input.SetUINT32(&MF_MT_AUDIO_AVG_BYTES_PER_SECOND, RATE * 2)?;
        writer.SetInputMediaType(index, &input, None)?;
        writer.BeginWriting()?;

        let pcm = upsample(samples);
        // 100 ms a buffer; times in 100 ns.
        let per_buffer = (RATE / 10) as usize;
        for (n, chunk) in pcm.chunks(per_buffer).enumerate() {
            let length = (chunk.len() * 2) as u32;
            let buffer = MFCreateMemoryBuffer(length)?;
            let mut data = std::ptr::null_mut();
            buffer.Lock(&mut data, None, None)?;
            std::ptr::copy_nonoverlapping(chunk.as_ptr() as *const u8, data, length as usize);
            buffer.Unlock()?;
            buffer.SetCurrentLength(length)?;
            let sample = MFCreateSample()?;
            sample.AddBuffer(&buffer)?;
            sample.SetSampleTime((n * per_buffer) as i64 * 10_000_000 / RATE as i64)?;
            sample.SetSampleDuration(chunk.len() as i64 * 10_000_000 / RATE as i64)?;
            writer.WriteSample(index, &sample)?;
        }
        writer.Finalize()?;

        let mut size = 0u64;
        stream.Seek(0, STREAM_SEEK_END, Some(&mut size))?;
        stream.Seek(0, STREAM_SEEK_SET, None)?;
        let mut file = vec![0u8; size as usize];
        let mut read = 0u32;
        stream.Read(file.as_mut_ptr() as _, size as u32, Some(&mut read)).ok()?;
        file.truncate(read as usize);
        Ok(file)
    }
}

/// 16 kHz to 48 kHz, each sample followed by two between it and the next.
fn upsample(samples: &[i16]) -> Vec<i16> {
    let mut out = Vec::with_capacity(samples.len() * 3);
    for (i, &sample) in samples.iter().enumerate() {
        let next = samples.get(i + 1).copied().unwrap_or(sample) as i32;
        let sample = sample as i32;
        out.push(sample as i16);
        out.push((sample + (next - sample) / 3) as i16);
        out.push((sample + (next - sample) * 2 / 3) as i16);
    }
    out
}

pub fn base64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for (i, shift) in [18, 12, 6, 0].into_iter().enumerate() {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> shift & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_is_standard() {
        assert_eq!(base64(b""), "");
        assert_eq!(base64(b"f"), "Zg==");
        assert_eq!(base64(b"fo"), "Zm8=");
        assert_eq!(base64(b"foo"), "Zm9v");
        assert_eq!(base64(b"foobar"), "Zm9vYmFy");
    }

    #[test]
    fn a_second_of_tone_becomes_an_m4a() {
        let samples: Vec<i16> = (0..16_000).map(|i| ((i as f32 * 0.1).sin() * 8000.0) as i16).collect();
        let file = m4a(&samples).unwrap();
        // An MP4's first box is `ftyp`.
        assert_eq!(&file[4..8], b"ftyp");
        assert!(file.len() > 1000 && file.len() < 40_000, "{} bytes", file.len());
    }
}
