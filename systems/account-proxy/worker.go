package accountproxy

import (
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"sync"
)

const maxFrame = 16 * 1024 * 1024
const maxCalls = 64

// Preserve the former 64 x 3 MiB admitted input envelope while allowing larger calls.
const maxActiveRequestBytes = 192 * 1024 * 1024
const maxOutput = 32 * 1024 * 1024
const chunkSize = 64 * 1024

type command struct {
	ID         string          `json:"id"`
	Type       string          `json:"type"`
	Op         string          `json:"op"`
	Body       json.RawMessage `json:"body"`
	Credential Credential      `json:"credential"`
}
type event struct {
	ID     string `json:"id"`
	Type   string `json:"type"`
	Data   []byte `json:"data,omitempty"`
	Status int    `json:"status,omitempty"`
	Code   string `json:"code,omitempty"`
}
type callState struct {
	cancel context.CancelFunc
	ack    chan struct{}
}
type operation func(context.Context, string, json.RawMessage, Credential, emitter) error

// Run uses the same four-byte big-endian frames as Erlang Port's packet: 4.
// One unacknowledged data frame per call bounds slow-consumer buffering.
func Run(ctx context.Context, input io.Reader, output io.Writer) error {
	return run(ctx, input, output, execute)
}
func run(parent context.Context, input io.Reader, output io.Writer, invoke operation) error {
	ctx, cancelAll := context.WithCancel(parent)
	defer cancelAll()
	var mu, writeMu sync.Mutex
	calls := map[string]*callState{}
	activeRequestBytes := 0
	send := func(e event) error {
		data, err := json.Marshal(e)
		if err != nil {
			return err
		}
		writeMu.Lock()
		defer writeMu.Unlock()
		err = writeFrame(output, data)
		if err != nil {
			cancelAll()
		}
		return err
	}
	for {
		data, err := readFrame(input)
		if err != nil {
			if errors.Is(err, io.EOF) {
				return nil
			}
			return err
		}
		var cmd command
		if json.Unmarshal(data, &cmd) != nil || cmd.ID == "" {
			return errors.New("invalid worker command")
		}
		mu.Lock()
		active := calls[cmd.ID]
		switch cmd.Type {
		case "ack":
			if active != nil {
				select {
				case active.ack <- struct{}{}:
				default:
				}
			}
			mu.Unlock()
		case "cancel":
			if active != nil {
				active.cancel()
			}
			mu.Unlock()
		case "call":
			if active != nil {
				mu.Unlock()
				return errors.New("duplicate request ID")
			}
			frameBytes := len(data)
			if len(calls) >= maxCalls || frameBytes > maxActiveRequestBytes-activeRequestBytes {
				mu.Unlock()
				if err := send(event{ID: cmd.ID, Type: "error", Status: 429, Code: "worker_busy"}); err != nil {
					return err
				}
				continue
			}
			callCtx, cancel := context.WithCancel(ctx)
			state := &callState{cancel: cancel, ack: make(chan struct{}, 1)}
			calls[cmd.ID] = state
			activeRequestBytes += frameBytes
			mu.Unlock()
			go func(cmd command) {
				defer cancel()
				// Only the reader mutates admissions; completion removes this specific call.
				// Cancellation does not release capacity until the executor has returned.
				defer func() {
					mu.Lock()
					delete(calls, cmd.ID)
					activeRequestBytes -= frameBytes
					mu.Unlock()
				}()
				total := 0
				emit := func(payload []byte) error {
					total += len(payload)
					if total > maxOutput {
						return &operationError{502, "response_too_large"}
					}
					for len(payload) > 0 {
						n := min(len(payload), chunkSize)
						if err := callCtx.Err(); err != nil {
							return err
						}
						if err := send(event{ID: cmd.ID, Type: "data", Data: payload[:n]}); err != nil {
							return err
						}
						select {
						case <-state.ack:
						case <-callCtx.Done():
							return callCtx.Err()
						}
						payload = payload[n:]
					}
					return nil
				}
				observedCtx, finishObservation := observeCall(callCtx, cmd)
				err := invoke(observedCtx, cmd.Op, cmd.Body, cmd.Credential, emit)
				result := event{ID: cmd.ID, Type: "done"}
				if err != nil {
					result.Type, result.Status, result.Code = "error", 503, "worker_operation_failed"
					var oe *operationError
					if errors.As(err, &oe) {
						result.Status, result.Code = oe.status, oe.code
					}
					if errors.Is(callCtx.Err(), context.DeadlineExceeded) {
						result.Status, result.Code = 504, "worker_timeout"
					}
					if errors.Is(callCtx.Err(), context.Canceled) {
						result.Status, result.Code = 499, "worker_cancelled"
					}
				}
				finishObservation(result)
				_ = send(result)
			}(cmd)
		default:
			mu.Unlock()
			return errors.New("unknown worker command")
		}
	}
}
func readFrame(r io.Reader) ([]byte, error) {
	var header [4]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}
	size := binary.BigEndian.Uint32(header[:])
	if size == 0 || size > maxFrame {
		return nil, errors.New("worker frame too large")
	}
	data := make([]byte, size)
	_, err := io.ReadFull(r, data)
	return data, err
}
func writeFrame(w io.Writer, data []byte) error {
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(data)))
	for _, part := range [][]byte{header[:], data} {
		for len(part) > 0 {
			n, err := w.Write(part)
			if err != nil {
				return err
			}
			if n == 0 {
				return io.ErrShortWrite
			}
			part = part[n:]
		}
	}
	return nil
}
