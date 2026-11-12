// Cue's own: the system output's 20 ms packets (960 frames of interleaved stereo PCM16 at 48 kHz) as Opus packets of
// the same 20 ms (RFC 6716), one for one, at BITRATE, for a view that asked `audioCodec: "opus"` (audio.rs). A Mac's
// helper does the same with AudioToolbox (SystemAudio.swift, `OpusPackets`). The encoder is libopus 1.3.1 as Rust
// (unsafe-libopus, transpiled by c2rust): the release builds this program from a Mac for x86_64-pc-windows-gnu, and a
// crate of libopus's C sources would need a C toolchain and CMake for Windows there.
use unsafe_libopus::{
    OPUS_APPLICATION_AUDIO, OPUS_OK, OPUS_SET_BITRATE_REQUEST, OpusEncoder, opus_encode, opus_encoder_create,
    opus_encoder_ctl, opus_encoder_destroy,
};

pub const BITRATE: i32 = 64_000;
const RATE: i32 = 48_000;
const CHANNELS: i32 = 2;
const FRAMES: usize = 960;
/// A packet's PCM: 20 ms of stereo PCM16.
pub const PCM_BYTES: usize = FRAMES * CHANNELS as usize * 2;
/// The largest packet the wire takes (`SCREEN_OPUS_MAX`, @comma/mesh screen-wire.ts).
pub const MAX_PACKET: usize = 1500;

pub struct OpusPackets {
    encoder: *mut OpusEncoder,
    samples: Vec<i16>,
    out: Vec<u8>,
}

// SAFETY: the encoder is owned by this value alone and used through `&mut self` only.
unsafe impl Send for OpusPackets {}

impl OpusPackets {
    /// None when the encoder cannot be made: the packets then stay PCM.
    pub fn new() -> Option<Self> {
        let mut error = 0;
        // SAFETY: a fresh encoder, destroyed below on failure or by Drop.
        unsafe {
            let encoder = opus_encoder_create(RATE, CHANNELS, OPUS_APPLICATION_AUDIO, &mut error);
            if encoder.is_null() {
                return None;
            }
            if error != OPUS_OK || opus_encoder_ctl!(encoder, OPUS_SET_BITRATE_REQUEST, BITRATE) != OPUS_OK {
                opus_encoder_destroy(encoder);
                return None;
            }
            Some(Self { encoder, samples: vec![0; FRAMES * CHANNELS as usize], out: vec![0; MAX_PACKET] })
        }
    }

    /// One packet's PCM (PCM_BYTES, little-endian) as one Opus packet; None for anything else or when it fails.
    pub fn encode(&mut self, pcm: &[u8]) -> Option<Vec<u8>> {
        if pcm.len() != PCM_BYTES {
            return None;
        }
        for (sample, bytes) in self.samples.iter_mut().zip(pcm.chunks_exact(2)) {
            *sample = i16::from_le_bytes([bytes[0], bytes[1]]);
        }
        // SAFETY: `samples` holds FRAMES frames of CHANNELS, `out` MAX_PACKET bytes.
        let size = unsafe {
            opus_encode(self.encoder, self.samples.as_ptr(), FRAMES as i32, self.out.as_mut_ptr(), MAX_PACKET as i32)
        };
        (size > 0).then(|| self.out[..size as usize].to_vec())
    }
}

impl Drop for OpusPackets {
    fn drop(&mut self) {
        // SAFETY: made by opus_encoder_create, destroyed once.
        unsafe { opus_encoder_destroy(self.encoder) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use unsafe_libopus::{opus_decode, opus_decoder_create, opus_decoder_destroy};

    /// 20 ms packets of a 440 Hz tone on the left and 660 Hz on the right, from `start` frames on.
    fn tone(start: usize) -> Vec<u8> {
        let mut pcm = Vec::with_capacity(PCM_BYTES);
        for i in start..start + FRAMES {
            let t = i as f64 / RATE as f64;
            for hz in [440.0, 660.0] {
                let sample = ((t * hz * std::f64::consts::TAU).sin() * 8000.0) as i16;
                pcm.extend_from_slice(&sample.to_le_bytes());
            }
        }
        pcm
    }

    /// The frequency of `samples` (one channel) by its zero crossings.
    fn frequency(samples: &[i16]) -> f64 {
        let crossings = samples.windows(2).filter(|w| (w[0] < 0) != (w[1] < 0)).count();
        crossings as f64 / 2.0 / (samples.len() as f64 / RATE as f64)
    }

    #[test]
    fn packets_are_opus_a_decoder_plays_back() {
        let mut encoder = OpusPackets::new().expect("an encoder");
        let mut error = 0;
        let decoder = unsafe { opus_decoder_create(RATE, CHANNELS, &mut error) };
        assert!(!decoder.is_null() && error == OPUS_OK);
        let packets = 50;
        let mut bytes = 0;
        let (mut left, mut right) = (Vec::new(), Vec::new());
        for n in 0..packets {
            let packet = encoder.encode(&tone(n * FRAMES)).expect("a packet");
            assert!(!packet.is_empty() && packet.len() <= MAX_PACKET);
            bytes += packet.len();
            let mut pcm = vec![0i16; FRAMES * 2];
            let frames = unsafe { opus_decode(decoder, packet.as_ptr(), packet.len() as i32, pcm.as_mut_ptr(), FRAMES as i32, 0) };
            assert_eq!(frames, FRAMES as i32);
            // The decoder's first packets are its lookahead's: listen once it settled.
            if n >= 5 {
                left.extend(pcm.iter().step_by(2));
                right.extend(pcm.iter().skip(1).step_by(2));
            }
        }
        unsafe { opus_decoder_destroy(decoder) };
        // About BITRATE: a twentieth of PCM's 1.5 Mbit/s.
        let bits_per_second = bytes as f64 * 8.0 / (packets as f64 * 0.02);
        assert!(bits_per_second < 100_000.0, "{bits_per_second} bit/s");
        assert!((frequency(&left) - 440.0).abs() < 10.0, "left {}", frequency(&left));
        assert!((frequency(&right) - 660.0).abs() < 10.0, "right {}", frequency(&right));
    }

    #[test]
    fn a_packet_of_another_size_is_none() {
        let mut encoder = OpusPackets::new().expect("an encoder");
        assert_eq!(encoder.encode(&[0; PCM_BYTES - 4]), None);
    }
}
