package erofsbundle

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

const (
	MaxHeaderBytes  = 65536
	ErofsBlockSize  = 4096
	ErofsMagicOff   = 1024
	CompressionZstd = "zstd"
	CompressionNone = "none"
)

var (
	// Magic is the 16-byte COMMA_EROFS_V1 frame header magic.
	Magic = []byte{'C', 'O', 'M', 'M', 'A', '_', 'E', 'R', 'O', 'F', 'S', '_', 'V', '1', '\n', 0}
	// ErofsSuperMagic is 0xe0f5e1e2 in little-endian at offset 1024..1028 of an EROFS image.
	ErofsSuperMagic = [4]byte{0xe2, 0xe1, 0xf5, 0xe0}
	// ZstdFrameMagic is the 4-byte standard zstd frame magic.
	ZstdFrameMagic = [4]byte{0x28, 0xb5, 0x2f, 0xfd}
)

type ContainerDefaults struct {
	Entrypoint []string `json:"Entrypoint,omitempty"`
	Cmd        []string `json:"Cmd,omitempty"`
	Env        []string `json:"Env,omitempty"`
	WorkingDir string   `json:"WorkingDir,omitempty"`
	User       string   `json:"User,omitempty"`
}

type Header struct {
	SchemaVersion  int               `json:"schemaVersion"`
	ManifestDigest string            `json:"manifestDigest"`
	Platform       string            `json:"platform"`
	LogicalBytes   int64             `json:"logicalBytes"`
	ErofsBytes     int64             `json:"erofsBytes"`
	ErofsSHA256    string            `json:"erofsSha256"`
	Compression    string            `json:"compression"`
	Defaults       ContainerDefaults `json:"defaults"`
}

type FlattenMeta struct {
	ManifestDigest string            `json:"manifestDigest"`
	Platform       string            `json:"platform"`
	LogicalBytes   int64             `json:"logicalBytes"`
	Defaults       ContainerDefaults `json:"defaults"`
}

type InspectResult struct {
	Header        Header
	ArchiveSize   int64
	ArchiveSHA256 string
}

func (h Header) Validate() error {
	if h.SchemaVersion != 1 {
		return fmt.Errorf("unsupported COMMA_EROFS_V1 schemaVersion %d", h.SchemaVersion)
	}
	if !ValidDigest(h.ManifestDigest) {
		return fmt.Errorf("invalid manifestDigest %q", h.ManifestDigest)
	}
	if h.Platform != "linux/arm64" {
		return fmt.Errorf("platform must be linux/arm64, got %q", h.Platform)
	}
	if h.LogicalBytes <= 0 {
		return fmt.Errorf("logicalBytes must be positive, got %d", h.LogicalBytes)
	}
	if h.ErofsBytes <= 0 || h.ErofsBytes%ErofsBlockSize != 0 {
		return fmt.Errorf("erofsBytes must be a positive multiple of %d, got %d", ErofsBlockSize, h.ErofsBytes)
	}
	if !ValidLowerHex64(h.ErofsSHA256) {
		return fmt.Errorf("invalid erofsSha256 %q", h.ErofsSHA256)
	}
	if h.Compression != CompressionZstd && h.Compression != CompressionNone {
		return fmt.Errorf("unsupported compression %q", h.Compression)
	}
	return nil
}

func ValidDigest(value string) bool {
	if !strings.HasPrefix(value, "sha256:") {
		return false
	}
	return ValidLowerHex64(strings.TrimPrefix(value, "sha256:"))
}

func ValidLowerHex64(value string) bool {
	if len(value) != 64 {
		return false
	}
	for i := 0; i < len(value); i++ {
		c := value[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// MeasureErofs validates an EROFS image file (non-empty, 4096-aligned, valid EROFS magic at 1024..1028)
// and returns its exact byte size and lowercase hex SHA-256 digest.
func MeasureErofs(path string) (int64, string, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, "", err
	}
	defer f.Close()

	return verifyErofsStream(f, io.Discard)
}

func verifyErofsStream(r io.Reader, out io.Writer) (int64, string, error) {
	hash := sha256.New()
	var total int64
	var magicBuf [4]byte
	var magicHave int

	buf := make([]byte, 128*1024)
	for {
		n, readErr := r.Read(buf)
		if n > 0 {
			chunk := buf[:n]
			start := total
			end := total + int64(n)
			if end > ErofsMagicOff && start < ErofsMagicOff+4 {
				lo := max(start, int64(ErofsMagicOff))
				hi := min(end, int64(ErofsMagicOff+4))
				copy(magicBuf[lo-ErofsMagicOff:hi-ErofsMagicOff], chunk[lo-start:hi-start])
				magicHave += int(hi - lo)
			}
			hash.Write(chunk)
			if out != nil && out != io.Discard {
				if _, err := out.Write(chunk); err != nil {
					return 0, "", err
				}
			}
			total = end
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			return 0, "", readErr
		}
	}

	if total <= 0 || total%ErofsBlockSize != 0 {
		return 0, "", fmt.Errorf("erofs image size %d is not a positive multiple of %d", total, ErofsBlockSize)
	}
	if magicHave != 4 || magicBuf != ErofsSuperMagic {
		return 0, "", fmt.Errorf("erofs image missing superblock magic at offset %d (got %x)", ErofsMagicOff, magicBuf)
	}
	return total, hex.EncodeToString(hash.Sum(nil)), nil
}

// Pack writes a COMMA_EROFS_V1 archive from meta.json, a 4096-aligned rootfs.erofs,
// and (for compression="zstd") its zstd-compressed payload.
func Pack(metaPath, erofsPath, zstdErofsPath, compression, outputPath string) (Header, error) {
	if compression == "" {
		compression = CompressionZstd
	}
	if compression != CompressionZstd && compression != CompressionNone {
		return Header{}, fmt.Errorf("unsupported compression %q", compression)
	}

	metaBytes, err := os.ReadFile(metaPath)
	if err != nil {
		return Header{}, fmt.Errorf("read meta: %w", err)
	}
	var meta FlattenMeta
	if err := json.Unmarshal(metaBytes, &meta); err != nil {
		return Header{}, fmt.Errorf("decode meta: %w", err)
	}

	erofsBytes, erofsSHA256, err := MeasureErofs(erofsPath)
	if err != nil {
		return Header{}, fmt.Errorf("validate erofs image: %w", err)
	}

	header := Header{
		SchemaVersion:  1,
		ManifestDigest: meta.ManifestDigest,
		Platform:       meta.Platform,
		LogicalBytes:   meta.LogicalBytes,
		ErofsBytes:     erofsBytes,
		ErofsSHA256:    erofsSHA256,
		Compression:    compression,
		Defaults:       meta.Defaults,
	}
	if err := header.Validate(); err != nil {
		return Header{}, err
	}

	payloadPath := zstdErofsPath
	if compression == CompressionNone {
		payloadPath = erofsPath
	} else if payloadPath == "" {
		return Header{}, errors.New("zstd-erofs path is required when compression is zstd")
	}

	payloadFile, err := os.Open(payloadPath)
	if err != nil {
		return Header{}, fmt.Errorf("open payload: %w", err)
	}
	defer payloadFile.Close()

	if err := WriteArchive(outputPath, header, payloadFile); err != nil {
		return Header{}, err
	}
	return header, nil
}

// WriteArchive writes a COMMA_EROFS_V1 archive with the given header and payload reader.
func WriteArchive(outputPath string, header Header, payload io.Reader) error {
	if err := header.Validate(); err != nil {
		return err
	}
	headerJSON, err := json.Marshal(header)
	if err != nil {
		return fmt.Errorf("marshal header: %w", err)
	}
	if len(headerJSON) == 0 || len(headerJSON) > MaxHeaderBytes {
		return fmt.Errorf("header JSON length %d out of range [1, %d]", len(headerJSON), MaxHeaderBytes)
	}

	out, err := os.OpenFile(outputPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	defer out.Close()

	if _, err := out.Write(Magic); err != nil {
		return err
	}
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(headerJSON)))
	if _, err := out.Write(lenBuf[:]); err != nil {
		return err
	}
	if _, err := out.Write(headerJSON); err != nil {
		return err
	}
	written, err := io.Copy(out, payload)
	if err != nil {
		return err
	}
	if written == 0 {
		return errors.New("empty archive payload")
	}
	return out.Close()
}

// ReadHeader parses and validates the COMMA_EROFS_V1 prefix from r, leaving r positioned
// at the start of the payload.
func ReadHeader(r io.Reader) (Header, int64, error) {
	var magic [16]byte
	if _, err := io.ReadFull(r, magic[:]); err != nil {
		return Header{}, 0, fmt.Errorf("read COMMA_EROFS_V1 magic: %w", err)
	}
	if !bytes.Equal(magic[:], Magic) {
		return Header{}, 0, errors.New("invalid COMMA_EROFS_V1 magic")
	}

	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		return Header{}, 0, fmt.Errorf("read COMMA_EROFS_V1 header length: %w", err)
	}
	headerLen := binary.BigEndian.Uint32(lenBuf[:])
	if headerLen == 0 || headerLen > MaxHeaderBytes {
		return Header{}, 0, fmt.Errorf("COMMA_EROFS_V1 header length %d out of range [1, %d]", headerLen, MaxHeaderBytes)
	}

	headerBytes := make([]byte, headerLen)
	if _, err := io.ReadFull(r, headerBytes); err != nil {
		return Header{}, 0, fmt.Errorf("read COMMA_EROFS_V1 header: %w", err)
	}

	var header Header
	if err := json.Unmarshal(headerBytes, &header); err != nil {
		return Header{}, 0, fmt.Errorf("decode COMMA_EROFS_V1 header: %w", err)
	}
	if err := header.Validate(); err != nil {
		return Header{}, 0, err
	}
	return header, int64(len(magic) + len(lenBuf) + len(headerBytes)), nil
}

// Unpack validates a COMMA_EROFS_V1 archive, decompresses its payload, checks erofsBytes,
// EROFS superblock magic, and erofsSha256, and writes the raw EROFS image to erofsOutPath
// when erofsOutPath is non-empty.
func Unpack(inputPath, erofsOutPath string) (Header, error) {
	f, err := os.Open(inputPath)
	if err != nil {
		return Header{}, err
	}
	defer f.Close()

	header, _, err := ReadHeader(f)
	if err != nil {
		return Header{}, err
	}

	var out io.Writer = io.Discard
	var outFile *os.File
	if erofsOutPath != "" {
		outFile, err = os.OpenFile(erofsOutPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
		if err != nil {
			return Header{}, err
		}
		defer func() {
			if outFile != nil {
				_ = outFile.Close()
			}
		}()
		out = outFile
	}

	if err := verifyPayload(header, f, out); err != nil {
		if outFile != nil {
			_ = outFile.Close()
			outFile = nil
			_ = os.Remove(erofsOutPath)
		}
		return Header{}, err
	}
	if outFile != nil {
		if err := outFile.Close(); err != nil {
			outFile = nil
			return Header{}, err
		}
		outFile = nil
	}
	return header, nil
}

// InspectFile validates a COMMA_EROFS_V1 archive and returns its header, total archive size,
// and archive SHA-256. When verifyPayloadWhenPossible is true, it always verifies uncompressed
// payloads and verifies zstd payloads whenever the `zstd` binary is present in PATH (otherwise
// verifying the zstd frame magic and non-empty payload).
func InspectFile(path string, verifyPayloadWhenPossible bool) (InspectResult, error) {
	f, err := os.Open(path)
	if err != nil {
		return InspectResult{}, err
	}
	defer f.Close()

	archiveHash := sha256.New()
	cr := &countingTeeReader{r: f, w: archiveHash}
	header, _, err := ReadHeader(cr)
	if err != nil {
		return InspectResult{}, err
	}

	switch header.Compression {
	case CompressionNone:
		if err := verifyPayload(header, cr, io.Discard); err != nil {
			return InspectResult{}, err
		}
	case CompressionZstd:
		var zstdMagic [4]byte
		if _, err := io.ReadFull(cr, zstdMagic[:]); err != nil {
			return InspectResult{}, fmt.Errorf("read zstd payload magic: %w", err)
		}
		if zstdMagic != ZstdFrameMagic {
			return InspectResult{}, fmt.Errorf("invalid zstd payload magic %x", zstdMagic)
		}
		payloadReader := io.MultiReader(bytes.NewReader(zstdMagic[:]), cr)
		if verifyPayloadWhenPossible {
			if _, lookErr := exec.LookPath("zstd"); lookErr == nil {
				if err := verifyPayload(header, payloadReader, io.Discard); err != nil {
					return InspectResult{}, err
				}
			} else {
				if _, err := io.Copy(io.Discard, cr); err != nil {
					return InspectResult{}, err
				}
			}
		} else {
			if _, err := io.Copy(io.Discard, cr); err != nil {
				return InspectResult{}, err
			}
		}
	default:
		return InspectResult{}, fmt.Errorf("unsupported compression %q", header.Compression)
	}

	return InspectResult{
		Header:        header,
		ArchiveSize:   cr.n,
		ArchiveSHA256: hex.EncodeToString(archiveHash.Sum(nil)),
	}, nil
}

func verifyPayload(header Header, payload io.Reader, out io.Writer) error {
	var stream io.Reader
	var cmd *exec.Cmd
	var stderr bytes.Buffer

	switch header.Compression {
	case CompressionNone:
		stream = payload
	case CompressionZstd:
		cmd = exec.Command("zstd", "-d", "-q", "--stdout")
		cmd.Stdin = payload
		cmd.Stderr = &stderr
		stdout, err := cmd.StdoutPipe()
		if err != nil {
			return fmt.Errorf("zstd stdout pipe: %w", err)
		}
		if err := cmd.Start(); err != nil {
			return fmt.Errorf("start zstd -d: %w", err)
		}
		stream = stdout
	default:
		return fmt.Errorf("unsupported compression %q", header.Compression)
	}

	gotBytes, gotSHA, streamErr := verifyErofsStream(stream, out)
	if cmd != nil {
		waitErr := cmd.Wait()
		if streamErr != nil {
			if stderr.Len() > 0 {
				return fmt.Errorf("%w (zstd: %s)", streamErr, strings.TrimSpace(stderr.String()))
			}
			return streamErr
		}
		if waitErr != nil {
			return fmt.Errorf("zstd decompress failed: %w (%s)", waitErr, strings.TrimSpace(stderr.String()))
		}
	} else if streamErr != nil {
		return streamErr
	}

	if gotBytes != header.ErofsBytes {
		return fmt.Errorf("decompressed erofs size = %d, want %d", gotBytes, header.ErofsBytes)
	}
	if gotSHA != header.ErofsSHA256 {
		return fmt.Errorf("decompressed erofs sha256 = %s, want %s", gotSHA, header.ErofsSHA256)
	}
	return nil
}

type countingTeeReader struct {
	r io.Reader
	w io.Writer
	n int64
}

func (c *countingTeeReader) Read(p []byte) (int, error) {
	n, err := c.r.Read(p)
	if n > 0 {
		c.n += int64(n)
		_, _ = c.w.Write(p[:n])
	}
	return n, err
}
