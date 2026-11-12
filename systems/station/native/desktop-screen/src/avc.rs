// H.264 as Media Foundation's encoders give it (Annex B: NAL units after start codes, the parameter sets in band) to
// what a view carries (AVCC: each NAL unit after its length in 4 bytes, the parameter sets in the avcC of its config).

/// The NAL units of an Annex B stream, without their start codes.
pub fn units(stream: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= stream.len() {
        if stream[i] == 0 && stream[i + 1] == 0 && stream[i + 2] == 1 {
            starts.push(i + 3);
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut units = Vec::new();
    for (n, &start) in starts.iter().enumerate() {
        let mut end = starts.get(n + 1).map(|&next| next - 3).unwrap_or(stream.len());
        // A four-byte start code's leading zero, and any trailing zeros, are not the unit's.
        while end > start && stream[end - 1] == 0 {
            end -= 1;
        }
        if end > start {
            units.push(&stream[start..end]);
        }
    }
    units
}

const SPS: u8 = 7;
const PPS: u8 = 8;
const AUD: u8 = 9;
const IDR: u8 = 5;

/// One encoded picture as a view sends it: its NAL units in AVCC, whether it is a key frame, and the parameter sets it
/// carried (none: those before still hold).
pub struct Picture {
    pub data: Vec<u8>,
    pub key: bool,
    pub sps: Option<Vec<u8>>,
    pub pps: Option<Vec<u8>>,
}

pub fn picture(stream: &[u8]) -> Picture {
    let mut data = Vec::with_capacity(stream.len() + 16);
    let (mut sps, mut pps, mut key) = (None, None, false);
    for unit in units(stream) {
        match unit[0] & 0x1f {
            SPS => sps = Some(unit.to_vec()),
            PPS => pps = Some(unit.to_vec()),
            AUD => {}
            kind => {
                key |= kind == IDR;
                data.extend_from_slice(&(unit.len() as u32).to_be_bytes());
                data.extend_from_slice(unit);
            }
        }
    }
    Picture { data, key, sps, pps }
}

/// The avcC (ISO 14496-15's AVCDecoderConfigurationRecord) of one SPS and one PPS, with 4-byte lengths.
pub fn avcc(sps: &[u8], pps: &[u8]) -> Vec<u8> {
    let mut out = vec![1, sps[1], sps[2], sps[3], 0xff, 0xe1];
    out.extend_from_slice(&(sps.len() as u16).to_be_bytes());
    out.extend_from_slice(sps);
    out.push(1);
    out.extend_from_slice(&(pps.len() as u16).to_be_bytes());
    out.extend_from_slice(pps);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn annex_b_to_avcc() {
        let stream = [
            0, 0, 0, 1, 0x09, 0xf0, // AUD
            0, 0, 0, 1, 0x67, 0x42, 0xc0, 0x1f, 0xaa, // SPS
            0, 0, 1, 0x68, 0xce, 0x3c, 0x80, // PPS
            0, 0, 1, 0x65, 0x88, 0x84, 0x00, 0x10, // IDR (an inner 00 kept)
        ];
        let p = picture(&stream);
        assert!(p.key);
        assert_eq!(p.sps.as_deref(), Some(&[0x67, 0x42, 0xc0, 0x1f, 0xaa][..]));
        assert_eq!(p.pps.as_deref(), Some(&[0x68, 0xce, 0x3c, 0x80][..]));
        assert_eq!(p.data, vec![0, 0, 0, 5, 0x65, 0x88, 0x84, 0x00, 0x10]);
        let c = avcc(p.sps.as_deref().unwrap(), p.pps.as_deref().unwrap());
        assert_eq!(&c[..8], &[1, 0x42, 0xc0, 0x1f, 0xff, 0xe1, 0, 5]);
        assert_eq!(&c[13..16], &[1, 0, 4]);
    }

    #[test]
    fn a_picture_without_parameter_sets() {
        let p = picture(&[0, 0, 0, 1, 0x41, 0x9a, 0, 0, 1, 0x01, 0x02]);
        assert!(!p.key);
        assert!(p.sps.is_none());
        assert_eq!(p.data, vec![0, 0, 0, 2, 0x41, 0x9a, 0, 0, 0, 2, 0x01, 0x02]);
    }
}
