package codec

import (
	"encoding/binary"
	"fmt"
	"time"
)

// Format is a comma.voice.v1 audio format: the wire encoding of both audio
// directions for one session.
type Format struct {
	Name       string
	SampleRate int
	muLaw      bool
}

var (
	// PCM16At24k is little-endian mono PCM16 at 24 kHz.
	PCM16At24k = Format{Name: "pcm16_24k", SampleRate: 24000}
	// MuLawAt8k is G.711 mu-law mono at 8 kHz.
	MuLawAt8k = Format{Name: "pcmu_8k", SampleRate: 8000, muLaw: true}
)

// ParseFormat returns the Format for a comma.voice.v1 format name.
func ParseFormat(name string) (Format, error) {
	switch name {
	case PCM16At24k.Name:
		return PCM16At24k, nil
	case MuLawAt8k.Name:
		return MuLawAt8k, nil
	}
	return Format{}, fmt.Errorf("unknown audio format %q (want pcm16_24k or pcmu_8k)", name)
}

// BytesPerSample is the number of wire bytes for one mono sample.
func (f Format) BytesPerSample() int {
	if f.muLaw {
		return 1
	}
	return 2
}

// Samples returns the number of samples in duration d.
func (f Format) Samples(d time.Duration) int {
	return int(int64(f.SampleRate) * int64(d) / int64(time.Second))
}

// Bytes returns the number of wire bytes in duration d.
func (f Format) Bytes(d time.Duration) int {
	return f.Samples(d) * f.BytesPerSample()
}

// Duration returns the playback duration of n wire bytes.
func (f Format) Duration(n int) time.Duration {
	samples := int64(n / f.BytesPerSample())
	return time.Duration(samples * int64(time.Second) / int64(f.SampleRate))
}

// Encode converts PCM16 samples to wire bytes.
func (f Format) Encode(samples []int16) []byte {
	if f.muLaw {
		out := make([]byte, len(samples))
		for i, s := range samples {
			out[i] = MuLawEncode(s)
		}
		return out
	}
	return PCM16Bytes(samples)
}

// Decode converts wire bytes to PCM16 samples. A trailing odd byte of PCM16
// input is ignored.
func (f Format) Decode(b []byte) []int16 {
	if f.muLaw {
		out := make([]int16, len(b))
		for i, u := range b {
			out[i] = MuLawDecode(u)
		}
		return out
	}
	return PCM16Samples(b)
}

// Silence returns n wire bytes of silence.
func (f Format) Silence(n int) []byte {
	out := make([]byte, n)
	if f.muLaw {
		for i := range out {
			out[i] = MuLawSilence
		}
	}
	return out
}

// PCM16Bytes encodes samples as little-endian PCM16.
func PCM16Bytes(samples []int16) []byte {
	out := make([]byte, 2*len(samples))
	for i, s := range samples {
		binary.LittleEndian.PutUint16(out[2*i:], uint16(s))
	}
	return out
}

// PCM16Samples decodes little-endian PCM16. A trailing odd byte is ignored.
func PCM16Samples(b []byte) []int16 {
	out := make([]int16, len(b)/2)
	for i := range out {
		out[i] = int16(binary.LittleEndian.Uint16(b[2*i:]))
	}
	return out
}
