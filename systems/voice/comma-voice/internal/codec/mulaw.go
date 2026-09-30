// Package codec holds the audio encodings, WAV container, and resampler that
// comma-voice needs to speak the comma.voice.v1 audio formats.
package codec

const (
	muLawBias = 0x84
	muLawClip = 32635
)

// MuLawEncode encodes one linear PCM16 sample as a G.711 mu-law byte.
func MuLawEncode(sample int16) byte {
	s := int(sample)
	sign := 0
	if s < 0 {
		s = -s
		sign = 0x80
	}
	if s > muLawClip {
		s = muLawClip
	}
	s += muLawBias
	exponent := 7
	for mask := 0x4000; s&mask == 0 && exponent > 0; mask >>= 1 {
		exponent--
	}
	mantissa := (s >> (exponent + 3)) & 0x0F
	return ^byte(sign | exponent<<4 | mantissa)
}

// MuLawDecode decodes one G.711 mu-law byte to a linear PCM16 sample.
func MuLawDecode(b byte) int16 {
	u := ^b
	sign := u & 0x80
	exponent := int(u>>4) & 0x07
	mantissa := int(u & 0x0F)
	s := ((mantissa << 3) + muLawBias) << exponent
	s -= muLawBias
	if sign != 0 {
		return int16(-s)
	}
	return int16(s)
}

// MuLawSilence is the mu-law encoding of a zero sample.
const MuLawSilence byte = 0xFF
