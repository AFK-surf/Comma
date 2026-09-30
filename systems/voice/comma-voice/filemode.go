package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"sync"
	"time"

	"github.com/AFK-surf/comma/systems/voice/comma-voice/internal/codec"
	"github.com/AFK-surf/comma/systems/voice/comma-voice/internal/session"
)

// runFileCall sends an audio file as the caller, paced to real time, and
// records the agent audio. After the input ends it keeps sending silence, so
// the model can detect the end of the caller's turn, and hangs up after
// f.tail without agent audio.
func runFileCall(ctx context.Context, f callFlags, opts session.Options, std stdio) int {
	format := opts.Format
	in, inRate, closeIn, err := openInput(f, format, std)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}
	defer closeIn()
	out, err := openOutput(f.output, format, std)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}

	s, code := dialAndStart(ctx, opts, std)
	if s == nil {
		if cerr := out.close(); cerr != nil {
			fmt.Fprintf(std.err, "comma-voice: write output: %v\n", cerr)
		}
		return code
	}

	src := newFileSource(in, inRate, format)
	uploadCtx, stopUpload := context.WithCancel(context.Background())
	uploadDone := make(chan error, 1)
	go func() { uploadDone <- uploadLoop(uploadCtx, s, src, format, f.echoGate) }()

	speaker := startFileSpeaker(s.Player(), format, out)

	hangUp := false
	tick := time.NewTicker(frameDuration)
loop:
	for {
		select {
		case <-s.Done():
			break loop
		case <-ctx.Done():
			hangUp = true
			break loop
		case err := <-uploadDone:
			uploadDone = nil
			if err != nil {
				// The server is closing; Done follows.
				select {
				case <-s.Done():
				case <-time.After(endWait):
				}
				break loop
			}
		case <-tick.C:
			doneAt, finished := src.inputEnd()
			if !finished {
				continue
			}
			last := s.LastAgentAudio()
			if doneAt.After(last) {
				last = doneAt
			}
			if time.Since(last) >= f.tail {
				hangUp = true
				break loop
			}
		}
	}
	tick.Stop()
	stopUpload()
	if uploadDone != nil {
		select {
		case <-uploadDone:
		case <-time.After(100 * time.Millisecond):
		}
	}
	// Play out what is queued so its marks are answered before session.end.
	speaker.stop()
	speaker.flush()
	code = finish(s, hangUp, std)
	speaker.flush()
	if err := speaker.err(); err != nil {
		fmt.Fprintf(std.err, "comma-voice: write output: %v\n", err)
		code = max(code, exitOther)
	}
	if err := out.close(); err != nil {
		fmt.Fprintf(std.err, "comma-voice: write output: %v\n", err)
		code = max(code, exitOther)
	}
	if n := s.Player().Dropped(); n > 0 {
		fmt.Fprintf(std.err, "comma-voice: dropped %s of agent audio that exceeded the playback queue\n", format.Duration(int(n)))
	}
	return code
}

func openInput(f callFlags, format codec.Format, std stdio) (codec.SampleReader, int, func(), error) {
	if f.input == "-" {
		rate := f.inputRate
		if rate == 0 {
			rate = format.SampleRate
		}
		return codec.NewRawPCMReader(bufio.NewReader(std.in)), rate, func() {}, nil
	}
	file, err := os.Open(f.input)
	if err != nil {
		return nil, 0, nil, err
	}
	wr, err := codec.NewWAVReader(file)
	if err != nil {
		file.Close()
		return nil, 0, nil, fmt.Errorf("%s: %w", f.input, err)
	}
	return wr, wr.SampleRate, func() { file.Close() }, nil
}

// audioSink receives agent audio as PCM16 at the session rate.
type audioSink struct {
	write func([]int16) error
	close func() error
}

func openOutput(path string, format codec.Format, std stdio) (audioSink, error) {
	switch path {
	case "":
		return audioSink{write: func([]int16) error { return nil }, close: func() error { return nil }}, nil
	case "-":
		w := bufio.NewWriter(std.out)
		return audioSink{
			write: func(s []int16) error {
				if _, err := w.Write(codec.PCM16Bytes(s)); err != nil {
					return err
				}
				return w.Flush()
			},
			close: w.Flush,
		}, nil
	}
	file, err := os.Create(path)
	if err != nil {
		return audioSink{}, err
	}
	ww, err := codec.NewWAVWriter(file, format.SampleRate)
	if err != nil {
		file.Close()
		return audioSink{}, err
	}
	return audioSink{
		write: ww.Write,
		close: func() error {
			return errors.Join(ww.Close(), file.Close())
		},
	}, nil
}

// fileSpeaker consumes the playback queue in real time, like a speaker, and
// writes what it plays to the output. Only agent audio is written; the gaps
// between agent turns are not.
type fileSpeaker struct {
	player *session.Player
	format codec.Format
	out    audioSink
	quit   chan struct{}
	done   chan struct{}
	mu     sync.Mutex
	wErr   error
}

func startFileSpeaker(p *session.Player, format codec.Format, out audioSink) *fileSpeaker {
	sp := &fileSpeaker{player: p, format: format, out: out, quit: make(chan struct{}), done: make(chan struct{})}
	go func() {
		defer close(sp.done)
		frame := format.Bytes(frameDuration)
		t := time.NewTicker(frameDuration)
		defer t.Stop()
		for {
			select {
			case <-sp.quit:
				return
			case <-t.C:
				sp.play(p.Take(frame))
			}
		}
	}()
	return sp
}

func (sp *fileSpeaker) play(b []byte) {
	if len(b) == 0 {
		return
	}
	sp.mu.Lock()
	defer sp.mu.Unlock()
	if sp.wErr == nil {
		sp.wErr = sp.out.write(sp.format.Decode(b))
	}
}

func (sp *fileSpeaker) stop() {
	close(sp.quit)
	<-sp.done
}

func (sp *fileSpeaker) flush() {
	sp.play(sp.player.Take(sp.player.Queued()))
}

func (sp *fileSpeaker) err() error {
	sp.mu.Lock()
	defer sp.mu.Unlock()
	return sp.wErr
}

// fileSource yields 20 ms frames of the input in the session format, paced
// to real time. After the input ends it yields silence.
type fileSource struct {
	in        codec.SampleReader
	resampler *codec.Resampler
	format    codec.Format
	frame     int
	readBuf   []int16
	pending   []int16
	eof       bool

	start time.Time
	sent  int64

	mu       sync.Mutex
	finished bool
	endedAt  time.Time
}

func newFileSource(in codec.SampleReader, inRate int, format codec.Format) *fileSource {
	return &fileSource{
		in:        in,
		resampler: codec.NewResampler(inRate, format.SampleRate),
		format:    format,
		frame:     format.Samples(frameDuration),
		readBuf:   make([]int16, max(1, inRate*int(frameDuration/time.Millisecond)/1000)),
	}
}

func (fs *fileSource) next(ctx context.Context) ([]byte, error) {
	for len(fs.pending) < fs.frame && !fs.eof {
		n, err := codec.ReadSamples(fs.in, fs.readBuf)
		fs.pending = append(fs.pending, fs.resampler.Process(fs.readBuf[:n])...)
		if err != nil {
			if !errors.Is(err, io.EOF) {
				return nil, fmt.Errorf("read input: %w", err)
			}
			fs.pending = append(fs.pending, fs.resampler.Flush()...)
			fs.eof = true
		}
	}
	samples := make([]int16, fs.frame)
	if len(fs.pending) > 0 {
		n := copy(samples, fs.pending)
		fs.pending = fs.pending[n:]
	} else {
		fs.markFinished()
	}
	if err := fs.pace(ctx); err != nil {
		return nil, err
	}
	return fs.format.Encode(samples), nil
}

// pace waits until this frame's slot. When the input stalled (a slow pipe),
// the schedule restarts instead of bursting to catch up.
func (fs *fileSource) pace(ctx context.Context) error {
	now := time.Now()
	if fs.start.IsZero() {
		fs.start = now
	}
	due := fs.start.Add(time.Duration(fs.sent) * frameDuration)
	if now.Sub(due) > 5*frameDuration {
		fs.start = now.Add(-time.Duration(fs.sent) * frameDuration)
		due = now
	}
	fs.sent++
	if wait := due.Sub(now); wait > 0 {
		t := time.NewTimer(wait)
		defer t.Stop()
		select {
		case <-t.C:
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	return ctx.Err()
}

func (fs *fileSource) markFinished() {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	if !fs.finished {
		fs.finished = true
		fs.endedAt = time.Now()
	}
}

// inputEnd reports whether all input audio was sent, and when.
func (fs *fileSource) inputEnd() (time.Time, bool) {
	fs.mu.Lock()
	defer fs.mu.Unlock()
	return fs.endedAt, fs.finished
}
