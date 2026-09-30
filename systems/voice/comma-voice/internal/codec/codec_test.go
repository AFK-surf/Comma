package codec

import (
	"bytes"
	"encoding/binary"
	"io"
	"math"
	"os"
	"path/filepath"
	"testing"
)

func TestMuLawKnownValues(t *testing.T) {
	cases := []struct {
		pcm  int16
		ulaw byte
	}{
		{0, 0xFF},
		{32767, 0x80},
		{-32768, 0x00},
		{-1, 0x7F},
	}
	for _, c := range cases {
		if got := MuLawEncode(c.pcm); got != c.ulaw {
			t.Errorf("MuLawEncode(%d) = %#x, want %#x", c.pcm, got, c.ulaw)
		}
	}
	if got := MuLawDecode(0xFF); got != 0 {
		t.Errorf("MuLawDecode(0xFF) = %d, want 0", got)
	}
	if got := MuLawDecode(0x80); got != 32124 {
		t.Errorf("MuLawDecode(0x80) = %d, want 32124", got)
	}
	if got := MuLawDecode(0x00); got != -32124 {
		t.Errorf("MuLawDecode(0x00) = %d, want -32124", got)
	}
}

func TestMuLawRoundTripIsStableAndBounded(t *testing.T) {
	for b := 0; b < 256; b++ {
		pcm := MuLawDecode(byte(b))
		back := MuLawDecode(MuLawEncode(pcm))
		if back != pcm {
			t.Fatalf("decode(encode(decode(%#x))) = %d, want %d", b, back, pcm)
		}
	}
	for s := -32768; s <= 32767; s += 7 {
		got := int(MuLawDecode(MuLawEncode(int16(s))))
		// G.711 quantization error grows with magnitude: at most half a step,
		// and a step is at most 1/16 of the segment base.
		limit := 4 + abs(s)/16
		if abs(got-s) > limit {
			t.Fatalf("round trip of %d gave %d (error > %d)", s, got, limit)
		}
	}
}

func TestFormatEncodeDecode(t *testing.T) {
	samples := []int16{0, 1000, -1000, 32767, -32768}
	raw := PCM16At24k.Encode(samples)
	if len(raw) != 10 || raw[2] != 0xE8 || raw[3] != 0x03 {
		t.Fatalf("pcm16 wire bytes not little-endian: %x", raw)
	}
	if got := PCM16At24k.Decode(raw); !equalSamples(got, samples) {
		t.Fatalf("pcm16 decode = %v", got)
	}
	u := MuLawAt8k.Encode(samples)
	if len(u) != len(samples) {
		t.Fatalf("mu-law bytes = %d", len(u))
	}
	if PCM16At24k.Bytes(20e6) != 960 || MuLawAt8k.Bytes(20e6) != 160 {
		t.Fatal("20 ms frame sizes wrong")
	}
	for _, b := range MuLawAt8k.Silence(4) {
		if MuLawDecode(b) != 0 {
			t.Fatal("mu-law silence is not zero")
		}
	}
}

func TestWAVRoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a.wav")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	w, err := NewWAVWriter(f, 8000)
	if err != nil {
		t.Fatal(err)
	}
	want := sine(8000, 440, 800)
	if err := w.Write(want[:300]); err != nil {
		t.Fatal(err)
	}
	if err := w.Write(want[300:]); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()

	data, _ := os.ReadFile(path)
	if len(data) != 44+1600 || binary.LittleEndian.Uint32(data[40:44]) != 1600 {
		t.Fatalf("header sizes wrong: len=%d", len(data))
	}
	r, err := NewWAVReader(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	if r.SampleRate != 8000 {
		t.Fatalf("rate = %d", r.SampleRate)
	}
	got := readAll(t, r)
	if !equalSamples(got, want) {
		t.Fatal("samples differ after round trip")
	}
}

func TestWAVReaderSkipsChunksAndAcceptsExtensible(t *testing.T) {
	var b bytes.Buffer
	b.WriteString("RIFF\x00\x00\x00\x00WAVE")
	// Extensible fmt chunk with the PCM subformat GUID prefix.
	fmtChunk := make([]byte, 40)
	binary.LittleEndian.PutUint16(fmtChunk[0:], 0xFFFE)
	binary.LittleEndian.PutUint16(fmtChunk[2:], 1)
	binary.LittleEndian.PutUint32(fmtChunk[4:], 24000)
	binary.LittleEndian.PutUint16(fmtChunk[14:], 16)
	binary.LittleEndian.PutUint16(fmtChunk[24:], 1)
	b.WriteString("fmt ")
	binary.Write(&b, binary.LittleEndian, uint32(len(fmtChunk)))
	b.Write(fmtChunk)
	b.WriteString("LIST")
	binary.Write(&b, binary.LittleEndian, uint32(3))
	b.WriteString("abc\x00") // odd size plus pad byte
	b.WriteString("data")
	binary.Write(&b, binary.LittleEndian, uint32(4))
	b.Write([]byte{0x01, 0x00, 0xFF, 0xFF})
	r, err := NewWAVReader(&b)
	if err != nil {
		t.Fatal(err)
	}
	if got := readAll(t, r); !equalSamples(got, []int16{1, -1}) || r.SampleRate != 24000 {
		t.Fatalf("got %v at %d Hz", got, r.SampleRate)
	}
}

func TestWAVReaderRejectsUnsupportedAudio(t *testing.T) {
	for name, mutate := range map[string]func([]byte){
		"stereo":  func(h []byte) { binary.LittleEndian.PutUint16(h[22:], 2) },
		"8-bit":   func(h []byte) { binary.LittleEndian.PutUint16(h[34:], 8) },
		"float":   func(h []byte) { binary.LittleEndian.PutUint16(h[20:], 3) },
		"not wav": func(h []byte) { copy(h[8:], "AVI ") },
	} {
		w := &WAVWriter{sampleRate: 8000}
		h := w.header()
		mutate(h)
		if _, err := NewWAVReader(bytes.NewReader(h)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestResampleUpAndDownKeepsSignal(t *testing.T) {
	in := sine(8000, 300, 8000) // 1 s
	up := resampleAll(NewResampler(8000, 24000), in, 160)
	if d := len(up) - 24000; d < -3 || d > 3 {
		t.Fatalf("8k->24k produced %d samples", len(up))
	}
	ref := sine(24000, 300, len(up))
	if e := rmsError(up[100:len(up)-100], ref[100:len(up)-100]); e > 200 {
		t.Fatalf("8k->24k RMS error %.1f", e)
	}

	in24 := sine(24000, 300, 24000)
	down := resampleAll(NewResampler(24000, 8000), in24, 480)
	if d := len(down) - 8000; d < -3 || d > 3 {
		t.Fatalf("24k->8k produced %d samples", len(down))
	}
	// The moving-average filter delays the signal by one input sample.
	ref8 := sine8Delayed(len(down), 1.0/24000)
	if e := rmsError(down[100:len(down)-100], ref8[100:len(down)-100]); e > 400 {
		t.Fatalf("24k->8k RMS error %.1f", e)
	}
}

func TestResampleChunkingDoesNotChangeOutput(t *testing.T) {
	in := sine(24000, 523, 4801)
	whole := resampleAll(NewResampler(24000, 8000), in, len(in))
	chunked := resampleAll(NewResampler(24000, 8000), in, 7)
	if !equalSamples(whole, chunked) {
		t.Fatalf("chunked output differs: %d vs %d samples", len(whole), len(chunked))
	}
	same := resampleAll(NewResampler(8000, 8000), in, 13)
	if !equalSamples(same, in) {
		t.Fatal("same-rate resampling changed samples")
	}
}

func sine(rate, freq, n int) []int16 {
	out := make([]int16, n)
	for i := range out {
		out[i] = int16(10000 * math.Sin(2*math.Pi*float64(freq)*float64(i)/float64(rate)))
	}
	return out
}

func sine8Delayed(n int, delay float64) []int16 {
	out := make([]int16, n)
	for i := range out {
		ts := float64(i)/8000 - delay
		out[i] = int16(10000 * math.Sin(2*math.Pi*300*ts))
	}
	return out
}

func resampleAll(r *Resampler, in []int16, chunk int) []int16 {
	var out []int16
	for len(in) > 0 {
		n := min(chunk, len(in))
		out = append(out, r.Process(in[:n])...)
		in = in[n:]
	}
	return append(out, r.Flush()...)
}

func readAll(t *testing.T, r SampleReader) []int16 {
	t.Helper()
	var out []int16
	buf := make([]int16, 64)
	for {
		n, err := ReadSamples(r, buf)
		out = append(out, buf[:n]...)
		if err == io.EOF {
			return out
		}
		if err != nil {
			t.Fatal(err)
		}
	}
}

func rmsError(a, b []int16) float64 {
	var sum float64
	for i := range a {
		d := float64(a[i]) - float64(b[i])
		sum += d * d
	}
	return math.Sqrt(sum / float64(len(a)))
}

func equalSamples(a, b []int16) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func abs(v int) int {
	if v < 0 {
		return -v
	}
	return v
}
