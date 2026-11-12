// H.265 as Media Foundation's encoders give it (Annex B, the parameter sets in band) to what a view carries: each NAL
// unit after its length in 4 bytes, the VPS, SPS and PPS in the hvcC of its config (ISO/IEC 14496-15 8.3.3), as
// avc.rs does for H.264.
use super::avc::units;

const VPS: u8 = 32;
const SPS: u8 = 33;
const PPS: u8 = 34;
const AUD: u8 = 35;

/// A NAL unit's type (the 6 bits after the forbidden one).
fn kind(unit: &[u8]) -> u8 {
    (unit[0] >> 1) & 0x3f
}

/// One encoded picture as a view sends it: its NAL units with lengths, whether it is a key frame (an IRAP picture:
/// BLA, IDR or CRA), and the parameter sets it carried.
pub struct Picture {
    pub data: Vec<u8>,
    pub key: bool,
    pub vps: Option<Vec<u8>>,
    pub sps: Option<Vec<u8>>,
    pub pps: Option<Vec<u8>>,
}

pub fn picture(stream: &[u8]) -> Picture {
    let mut data = Vec::with_capacity(stream.len() + 16);
    let (mut vps, mut sps, mut pps, mut key) = (None, None, None, false);
    for unit in units(stream).into_iter().filter(|u| u.len() >= 2) {
        match kind(unit) {
            VPS => vps = Some(unit.to_vec()),
            SPS => sps = Some(unit.to_vec()),
            PPS => pps = Some(unit.to_vec()),
            AUD => {}
            k => {
                key |= (16..=21).contains(&k);
                data.extend_from_slice(&(unit.len() as u32).to_be_bytes());
                data.extend_from_slice(unit);
            }
        }
    }
    Picture { data, key, vps, sps, pps }
}

/// A unit's payload without its emulation prevention bytes (the 3 after two zeros), its first `n` bytes at most.
fn rbsp(payload: &[u8], n: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(n);
    let mut zeros = 0;
    for &b in payload {
        if out.len() == n {
            break;
        }
        if zeros >= 2 && b == 3 {
            zeros = 0;
            continue;
        }
        zeros = if b == 0 { zeros + 1 } else { 0 };
        out.push(b);
    }
    out
}

/// The hvcC of a VPS, an SPS and a PPS, with 4-byte lengths: its head from the SPS's general profile, tier and level
/// (12 bytes after its first, as every SPS has them), 4:2:0 8-bit, one temporal layer. None when the SPS is too short.
pub fn hvcc(vps: &[u8], sps: &[u8], pps: &[u8]) -> Option<Vec<u8>> {
    // After the NAL header (2 bytes): the VPS id, sub-layers and nesting (1 byte), then profile_tier_level's general part.
    let ptl = rbsp(sps.get(2..)?, 13);
    if ptl.len() < 13 {
        return None;
    }
    let mut out = vec![1];
    out.extend_from_slice(&ptl[1..13]);
    out.extend_from_slice(&[0xf0, 0x00, 0xfc, 0xfd, 0xf8, 0xf8, 0, 0, 0x0f, 3]);
    for (k, unit) in [(VPS, vps), (SPS, sps), (PPS, pps)] {
        out.push(0x80 | k);
        out.extend_from_slice(&1u16.to_be_bytes());
        out.extend_from_slice(&(unit.len() as u16).to_be_bytes());
        out.extend_from_slice(unit);
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // An SPS as encoders write it: its header (type 33), VPS 0 and one layer, then Main (1), compatible with Main and
    // Main 10, progressive and frame-only, level 5.1 (153); an emulation prevention byte in the constraint flags.
    const SPS_UNIT: [u8; 18] = [0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0xb0, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x99];

    #[test]
    fn annex_b_to_lengths() {
        let mut stream = vec![0, 0, 0, 1, 0x46, 0x01, 0x50]; // AUD
        stream.extend_from_slice(&[0, 0, 0, 1, 0x40, 0x01, 0x0c]); // VPS
        stream.extend_from_slice(&[0, 0, 1]);
        stream.extend_from_slice(&SPS_UNIT);
        stream.extend_from_slice(&[0, 0, 1, 0x44, 0x01, 0xc1]); // PPS
        stream.extend_from_slice(&[0, 0, 1, 0x26, 0x01, 0xaf, 0x10]); // IDR_W_RADL (19)
        let p = picture(&stream);
        assert!(p.key);
        assert_eq!(p.vps.as_deref(), Some(&[0x40, 0x01, 0x0c][..]));
        assert_eq!(p.sps.as_deref(), Some(&SPS_UNIT[..]));
        assert_eq!(p.data, vec![0, 0, 0, 4, 0x26, 0x01, 0xaf, 0x10]);
        // A trailing picture (type 1): not a key frame.
        assert!(!picture(&[0, 0, 0, 1, 0x02, 0x01, 0xd0]).key);
    }

    #[test]
    fn hvcc_from_the_parameter_sets() {
        let c = hvcc(&[0x40, 0x01, 0x0c], &SPS_UNIT, &[0x44, 0x01, 0xc1]).unwrap();
        // Version 1; Main, Main tier; compatibility 0x60000000; constraints 0xB0 then zeros (the 3s taken out); level 153.
        assert_eq!(&c[..13], &[1, 0x01, 0x60, 0, 0, 0, 0xb0, 0, 0, 0, 0, 0, 153]);
        assert_eq!(&c[13..23], &[0xf0, 0x00, 0xfc, 0xfd, 0xf8, 0xf8, 0, 0, 0x0f, 3]);
        assert_eq!(&c[23..28], &[0xa0, 0, 1, 0, 3]);
        assert_eq!(c.len(), 23 + 3 * 5 + 3 + SPS_UNIT.len() + 3);
        assert!(hvcc(&[], &SPS_UNIT[..6], &[]).is_none());
    }
}
