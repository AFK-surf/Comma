package codec

import (
	"bufio"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
)

const (
	wavFormatPCM        = 1
	wavFormatExtensible = 0xFFFE
	maxWAVChunkSkip     = 16 << 20
)

// WAVReader streams mono 16-bit PCM samples from a RIFF/WAVE file.
type WAVReader struct {
	SampleRate int
	r          io.Reader
	remaining  int64 // -1: read to EOF
	odd        []byte
}

// NewWAVReader parses the WAV header and positions the reader at the first
// sample. It accepts only mono 16-bit PCM.
func NewWAVReader(r io.Reader) (*WAVReader, error) {
	br := bufio.NewReader(r)
	var riff [12]byte
	if _, err := io.ReadFull(br, riff[:]); err != nil {
		return nil, fmt.Errorf("read WAV header: %w", err)
	}
	if string(riff[0:4]) != "RIFF" || string(riff[8:12]) != "WAVE" {
		return nil, errors.New("not a RIFF/WAVE file")
	}
	var (
		haveFmt bool
		rate    int
	)
	for {
		var hdr [8]byte
		if _, err := io.ReadFull(br, hdr[:]); err != nil {
			return nil, fmt.Errorf("read WAV chunk: %w", err)
		}
		id := string(hdr[0:4])
		size := int64(binary.LittleEndian.Uint32(hdr[4:8]))
		switch id {
		case "fmt ":
			if size < 16 || size > 1024 {
				return nil, fmt.Errorf("bad WAV fmt chunk size %d", size)
			}
			buf := make([]byte, size+size%2)
			if _, err := io.ReadFull(br, buf); err != nil {
				return nil, fmt.Errorf("read WAV fmt chunk: %w", err)
			}
			tag := binary.LittleEndian.Uint16(buf[0:2])
			channels := binary.LittleEndian.Uint16(buf[2:4])
			rate = int(binary.LittleEndian.Uint32(buf[4:8]))
			bits := binary.LittleEndian.Uint16(buf[14:16])
			if tag == wavFormatExtensible && size >= 26 {
				tag = binary.LittleEndian.Uint16(buf[24:26])
			}
			if tag != wavFormatPCM {
				return nil, fmt.Errorf("WAV encoding %#x is not PCM", tag)
			}
			if channels != 1 || bits != 16 {
				return nil, fmt.Errorf("WAV must be mono 16-bit, got %d channels at %d bits", channels, bits)
			}
			if rate <= 0 || rate > 192000 {
				return nil, fmt.Errorf("bad WAV sample rate %d", rate)
			}
			haveFmt = true
		case "data":
			if !haveFmt {
				return nil, errors.New("WAV data chunk before fmt chunk")
			}
			remaining := size
			// Streaming writers leave the size at 0 or 0xFFFFFFFF.
			if size == 0 || size == 0xFFFFFFFF {
				remaining = -1
			}
			return &WAVReader{SampleRate: rate, r: br, remaining: remaining}, nil
		default:
			if size > maxWAVChunkSkip {
				return nil, fmt.Errorf("WAV chunk %q too large", id)
			}
			if _, err := io.CopyN(io.Discard, br, size+size%2); err != nil {
				return nil, fmt.Errorf("skip WAV chunk %q: %w", id, err)
			}
		}
	}
}

// Read reads up to len(dst) samples. It returns io.EOF after the last sample.
func (w *WAVReader) Read(dst []int16) (int, error) {
	return readPCM16(w.r, &w.remaining, &w.odd, dst)
}

// RawPCMReader streams raw little-endian mono PCM16 samples.
type RawPCMReader struct {
	r         io.Reader
	remaining int64
	odd       []byte
}

// NewRawPCMReader reads raw PCM16 samples from r until EOF.
func NewRawPCMReader(r io.Reader) *RawPCMReader {
	return &RawPCMReader{r: r, remaining: -1}
}

// Read reads up to len(dst) samples. It returns io.EOF after the last sample.
func (p *RawPCMReader) Read(dst []int16) (int, error) {
	return readPCM16(p.r, &p.remaining, &p.odd, dst)
}

func readPCM16(r io.Reader, remaining *int64, odd *[]byte, dst []int16) (int, error) {
	if len(dst) == 0 {
		return 0, nil
	}
	want := int64(2 * len(dst))
	if *remaining >= 0 && want > *remaining {
		want = *remaining
	}
	if want <= 0 {
		return 0, io.EOF
	}
	buf := make([]byte, len(*odd), int(want)+1)
	copy(buf, *odd)
	buf = buf[:int(want)]
	n, err := r.Read(buf[len(*odd):])
	total := len(*odd) + n
	if *remaining >= 0 {
		*remaining -= int64(n)
	}
	whole := total / 2 * 2
	*odd = append((*odd)[:0], buf[whole:total]...)
	samples := whole / 2
	for i := 0; i < samples; i++ {
		dst[i] = int16(binary.LittleEndian.Uint16(buf[2*i:]))
	}
	if err == io.EOF && samples > 0 {
		err = nil
	}
	return samples, err
}

// SampleReader reads PCM16 samples. It may return fewer samples than asked
// without an error; it returns io.EOF after the last sample.
type SampleReader interface {
	Read(dst []int16) (int, error)
}

// ReadSamples fills dst from r. It returns fewer than len(dst) samples only
// together with an error, which is io.EOF at the end of the input.
func ReadSamples(r SampleReader, dst []int16) (int, error) {
	total := 0
	empty := 0
	for total < len(dst) {
		n, err := r.Read(dst[total:])
		total += n
		if err != nil {
			return total, err
		}
		if n == 0 {
			empty++
			if empty > 100 {
				return total, io.ErrNoProgress
			}
		} else {
			empty = 0
		}
	}
	return total, nil
}

// WAVWriter writes a mono 16-bit PCM WAV file. Close patches the sizes.
type WAVWriter struct {
	w          io.WriteSeeker
	sampleRate int
	dataBytes  int64
}

// NewWAVWriter writes a WAV header for mono 16-bit PCM at sampleRate.
func NewWAVWriter(w io.WriteSeeker, sampleRate int) (*WAVWriter, error) {
	ww := &WAVWriter{w: w, sampleRate: sampleRate}
	if _, err := w.Write(ww.header()); err != nil {
		return nil, err
	}
	return ww, nil
}

// Write appends samples to the data chunk.
func (w *WAVWriter) Write(samples []int16) error {
	n, err := w.w.Write(PCM16Bytes(samples))
	w.dataBytes += int64(n)
	return err
}

// Close rewrites the header with the final sizes.
func (w *WAVWriter) Close() error {
	if w.dataBytes%2 == 1 {
		return errors.New("odd WAV data length")
	}
	if _, err := w.w.Seek(0, io.SeekStart); err != nil {
		return err
	}
	if _, err := w.w.Write(w.header()); err != nil {
		return err
	}
	_, err := w.w.Seek(0, io.SeekEnd)
	return err
}

func (w *WAVWriter) header() []byte {
	h := make([]byte, 44)
	copy(h[0:4], "RIFF")
	binary.LittleEndian.PutUint32(h[4:8], uint32(36+w.dataBytes))
	copy(h[8:12], "WAVE")
	copy(h[12:16], "fmt ")
	binary.LittleEndian.PutUint32(h[16:20], 16)
	binary.LittleEndian.PutUint16(h[20:22], wavFormatPCM)
	binary.LittleEndian.PutUint16(h[22:24], 1)
	binary.LittleEndian.PutUint32(h[24:28], uint32(w.sampleRate))
	binary.LittleEndian.PutUint32(h[28:32], uint32(w.sampleRate*2))
	binary.LittleEndian.PutUint16(h[32:34], 2)
	binary.LittleEndian.PutUint16(h[34:36], 16)
	copy(h[36:40], "data")
	binary.LittleEndian.PutUint32(h[40:44], uint32(w.dataBytes))
	return h
}
