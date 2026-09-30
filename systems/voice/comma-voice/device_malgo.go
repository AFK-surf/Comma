//go:build cgo && !nodevice

package main

import (
	"context"
	"errors"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AFK-surf/comma/systems/voice/comma-voice/internal/codec"
	"github.com/AFK-surf/comma/systems/voice/comma-voice/internal/session"
	"github.com/gen2brain/malgo"
)

// maxCaptureBacklog bounds microphone audio waiting for upload. Older audio
// is dropped, because late caller audio is worse than lost audio.
const maxCaptureBacklog = time.Second

func runDevices(args []string, std stdio) int {
	fs := newFlagSet("devices", std)
	if code, ok := parseFlags(fs, args); !ok {
		return code
	}
	mctx, err := malgo.InitContext(nil, malgo.ContextConfig{}, nil)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: open audio system: %v\n", err)
		return exitOther
	}
	defer func() {
		_ = mctx.Uninit()
		mctx.Free()
	}()
	for _, kind := range []struct {
		label string
		t     malgo.DeviceType
	}{{"Input (capture) devices", malgo.Capture}, {"Output (playback) devices", malgo.Playback}} {
		infos, err := mctx.Devices(kind.t)
		if err != nil {
			fmt.Fprintf(std.err, "comma-voice: list devices: %v\n", err)
			return exitOther
		}
		fmt.Fprintf(std.out, "%s:\n", kind.label)
		if len(infos) == 0 {
			fmt.Fprintln(std.out, "  (none)")
		}
		for i, info := range infos {
			def := ""
			if info.IsDefault != 0 {
				def = " (default)"
			}
			fmt.Fprintf(std.out, "  %d: %s%s\n", i, info.Name(), def)
		}
	}
	return exitOK
}

// runDeviceCall connects the microphone and speaker to a voice session.
// miniaudio converts between the device rate and the session rate. The
// device opens before the session, so a missing device costs no call time.
func runDeviceCall(ctx context.Context, f callFlags, opts session.Options, std stdio) int {
	format := opts.Format
	mctx, err := malgo.InitContext(nil, malgo.ContextConfig{}, nil)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: open audio system: %v\n", err)
		return exitOther
	}
	defer func() {
		_ = mctx.Uninit()
		mctx.Free()
	}()

	cfg := malgo.DefaultDeviceConfig(malgo.Duplex)
	cfg.SampleRate = uint32(format.SampleRate)
	cfg.PeriodSizeInMilliseconds = uint32(frameDuration / time.Millisecond)
	cfg.Capture.Format = malgo.FormatS16
	cfg.Capture.Channels = 1
	cfg.Playback.Format = malgo.FormatS16
	cfg.Playback.Channels = 1
	if err := pickDevice(mctx, malgo.Capture, f.captureDevice, &cfg.Capture); err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}
	if err := pickDevice(mctx, malgo.Playback, f.playbackDevice, &cfg.Playback); err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}

	mic := newMicSource(format)
	var live atomic.Pointer[session.Player]
	wire := format.BytesPerSample()
	device, err := malgo.InitDevice(mctx.Context, cfg, malgo.DeviceCallbacks{
		Data: func(out, in []byte, frames uint32) {
			player := live.Load()
			if player == nil {
				clear(out)
				return
			}
			mic.push(in)
			pcm := format.Decode(player.Take(int(frames) * wire))
			n := copy(out, codec.PCM16Bytes(pcm))
			clear(out[n:])
		},
	})
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: open audio device: %v\n", err)
		return exitOther
	}
	defer device.Uninit()
	if err := device.Start(); err != nil {
		fmt.Fprintf(std.err, "comma-voice: start audio device: %v\n", err)
		return exitOther
	}
	defer func() { _ = device.Stop() }()

	s, code := dialAndStart(ctx, opts, std)
	if s == nil {
		return code
	}
	live.Store(s.Player())
	if !f.echoGate {
		fmt.Fprintln(std.err, "comma-voice: use headphones; speaker audio can reach the microphone and interrupt the agent (or pass --echo-gate)")
	}
	fmt.Fprintln(std.err, "comma-voice: talking; press Ctrl-C to hang up")

	uploadCtx, stopUpload := context.WithCancel(context.Background())
	uploadDone := make(chan error, 1)
	go func() { uploadDone <- uploadLoop(uploadCtx, s, mic, format, f.echoGate) }()

	hangUp := false
	select {
	case <-s.Done():
	case <-ctx.Done():
		hangUp = true
	case err := <-uploadDone:
		if err != nil && !errors.Is(err, context.Canceled) {
			select {
			case <-s.Done():
			case <-time.After(endWait):
			}
		}
	}
	stopUpload()
	return finish(s, hangUp, std)
}

func pickDevice(mctx *malgo.AllocatedContext, kind malgo.DeviceType, index int, sub *malgo.SubConfig) error {
	if index < 0 {
		return nil
	}
	infos, err := mctx.Devices(kind)
	if err != nil {
		return fmt.Errorf("list devices: %w", err)
	}
	if index >= len(infos) {
		return fmt.Errorf("device index %d out of range (see 'comma-voice devices')", index)
	}
	sub.DeviceID = infos[index].ID.Pointer()
	return nil
}

// micSource buffers PCM16 samples from the capture callback and yields
// 20 ms frames in the session format.
type micSource struct {
	format codec.Format
	frame  int
	max    int
	mu     sync.Mutex
	buf    []int16
	ready  chan struct{}
}

func newMicSource(format codec.Format) *micSource {
	return &micSource{
		format: format,
		frame:  format.Samples(frameDuration),
		max:    format.Samples(maxCaptureBacklog),
		ready:  make(chan struct{}, 1),
	}
}

func (m *micSource) push(pcm []byte) {
	samples := codec.PCM16Samples(pcm)
	m.mu.Lock()
	m.buf = append(m.buf, samples...)
	if over := len(m.buf) - m.max; over > 0 {
		m.buf = m.buf[over:]
	}
	enough := len(m.buf) >= m.frame
	m.mu.Unlock()
	if enough {
		select {
		case m.ready <- struct{}{}:
		default:
		}
	}
}

func (m *micSource) next(ctx context.Context) ([]byte, error) {
	for {
		m.mu.Lock()
		if len(m.buf) >= m.frame {
			frame := make([]int16, m.frame)
			copy(frame, m.buf)
			m.buf = m.buf[m.frame:]
			m.mu.Unlock()
			return m.format.Encode(frame), nil
		}
		m.mu.Unlock()
		select {
		case <-m.ready:
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
}
