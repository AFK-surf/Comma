package gateway

import (
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
)

const (
	// MaxSocketFrame bounds one socket request or reply frame.
	MaxSocketFrame = 16 << 10
	// MaxPortFrame bounds one port frame. A start or persist frame carries
	// the node state, which is a few KiB.
	MaxPortFrame = 256 << 10
)

// ReadFrame reads one length-prefixed JSON frame of at most limit bytes.
func ReadFrame(r io.Reader, limit int, v any) error {
	var n uint32
	if err := binary.Read(r, binary.BigEndian, &n); err != nil {
		return err
	}
	if n == 0 || int(n) > limit {
		return fmt.Errorf("frame of %d bytes", n)
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return err
	}
	return json.Unmarshal(buf, v)
}

// WriteFrame writes one length-prefixed JSON frame of at most limit bytes.
func WriteFrame(w io.Writer, limit int, v any) error {
	body, err := json.Marshal(v)
	if err != nil {
		return err
	}
	if len(body) > limit {
		return fmt.Errorf("frame of %d bytes", len(body))
	}
	buf := binary.BigEndian.AppendUint32(make([]byte, 0, 4+len(body)), uint32(len(body)))
	_, err = w.Write(append(buf, body...))
	return err
}
