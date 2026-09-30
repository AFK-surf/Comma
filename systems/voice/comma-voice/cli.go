package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/AFK-surf/comma/systems/voice/comma-voice/internal/codec"
	"github.com/AFK-surf/comma/systems/voice/comma-voice/internal/session"
)

const (
	exitOK    = session.ExitOK
	exitUsage = session.ExitUsage
	exitAuth  = session.ExitAuth
	exitOther = session.ExitOther

	// endWait is how long a client hang-up waits for session.ended.
	endWait = 2 * time.Second
	// frameDuration is the caller audio frame size; comma.voice.v1 allows 10-100 ms.
	frameDuration = 20 * time.Millisecond
	// echoHold keeps the echo gate closed after agent audio stops playing.
	echoHold = 200 * time.Millisecond
)

type env struct {
	lookup func(string) (string, bool)
}

func (e env) get(name string) string {
	v, _ := e.lookup(name)
	return v
}

type stdio struct {
	in       io.Reader
	out, err io.Writer
}

const usageText = `Usage: comma-voice <command> [flags]

Commands:
  check     Call the Group's voice readiness endpoint and print formats and limits
  devices   List audio input and output devices
  call      Start a voice session (microphone and speaker, or --input/--output files)

Connection flags (check, call):
  --server URL      Salix base URL (or COMMA_VOICE_SERVER)
  --group ID        Agent Group id (or COMMA_VOICE_GROUP)
  --key-file PATH   File that holds the voice agent API key
                    (default: the COMMA_VOICE_API_KEY environment variable)

Run "comma-voice <command> -h" for the flags of one command.
Exit codes: 0 normal end, 2 usage, 3 authentication, 4 Group busy, 5 other.
`

func run(ctx context.Context, args []string, e env, std stdio) int {
	// Session goroutines print status and JSON lines concurrently.
	std.out = &lockedWriter{w: std.out}
	std.err = &lockedWriter{w: std.err}
	if len(args) == 0 {
		fmt.Fprint(std.err, usageText)
		return exitUsage
	}
	switch args[0] {
	case "check":
		return runCheck(ctx, args[1:], e, std)
	case "devices":
		return runDevices(args[1:], std)
	case "call":
		return runCall(ctx, args[1:], e, std)
	case "-h", "--help", "help":
		fmt.Fprint(std.out, usageText)
		return exitOK
	case "version", "--version":
		fmt.Fprintf(std.out, "comma-voice %s\n", version)
		return exitOK
	}
	fmt.Fprintf(std.err, "comma-voice: unknown command %q\n\n%s", args[0], usageText)
	return exitUsage
}

type connFlags struct {
	server, group, keyFile string
}

func (c *connFlags) register(fs *flag.FlagSet) {
	fs.StringVar(&c.server, "server", "", "Salix base URL (default $COMMA_VOICE_SERVER)")
	fs.StringVar(&c.group, "group", "", "Agent Group id (default $COMMA_VOICE_GROUP)")
	fs.StringVar(&c.keyFile, "key-file", "", "file with the voice agent API key (default $COMMA_VOICE_API_KEY)")
}

// resolve fills defaults from the environment and loads the key. The key is
// never a flag value, so it stays out of process lists and shell history.
func (c *connFlags) resolve(e env) (server, group, key string, err error) {
	server = c.server
	if server == "" {
		server = e.get("COMMA_VOICE_SERVER")
	}
	group = c.group
	if group == "" {
		group = e.get("COMMA_VOICE_GROUP")
	}
	if server == "" || group == "" {
		return "", "", "", errors.New("--server and --group (or COMMA_VOICE_SERVER and COMMA_VOICE_GROUP) are required")
	}
	if c.keyFile != "" {
		b, rerr := os.ReadFile(c.keyFile)
		if rerr != nil {
			return "", "", "", fmt.Errorf("read key file: %w", rerr)
		}
		key = strings.TrimSpace(string(b))
	} else {
		key = strings.TrimSpace(e.get("COMMA_VOICE_API_KEY"))
	}
	if key == "" {
		return "", "", "", errors.New("no API key: set COMMA_VOICE_API_KEY or pass --key-file")
	}
	if strings.ContainsAny(key, " \t\r\n") {
		return "", "", "", errors.New("API key contains whitespace")
	}
	return server, group, key, nil
}

func newFlagSet(name string, std stdio) *flag.FlagSet {
	fs := flag.NewFlagSet("comma-voice "+name, flag.ContinueOnError)
	fs.SetOutput(std.err)
	return fs
}

func parseFlags(fs *flag.FlagSet, args []string) (int, bool) {
	if err := fs.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return exitOK, false
		}
		return exitUsage, false
	}
	if fs.NArg() > 0 {
		fmt.Fprintf(fs.Output(), "unexpected arguments: %v\n", fs.Args())
		return exitUsage, false
	}
	return 0, true
}

func runCheck(ctx context.Context, args []string, e env, std stdio) int {
	fs := newFlagSet("check", std)
	var conn connFlags
	conn.register(fs)
	jsonOut := fs.Bool("json", false, "print the readiness response as one JSON line")
	if code, ok := parseFlags(fs, args); !ok {
		return code
	}
	server, group, key, err := conn.resolve(e)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}
	target, err := session.ReadinessURL(server, group)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}
	reqCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(reqCtx, http.MethodGet, target, nil)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}
	req.Header.Set("Authorization", "Bearer "+key)
	req.Header.Set("Accept", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: readiness request failed: %v\n", err)
		return exitOther
	}
	defer resp.Body.Close()
	body, err := readLimited(resp.Body, 1<<20)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: read readiness response: %v\n", err)
		return exitOther
	}
	if resp.StatusCode != http.StatusOK {
		fmt.Fprintf(std.err, "comma-voice: readiness returned HTTP %d: %s\n", resp.StatusCode, strings.TrimSpace(string(body)))
		return session.ExitCodeForHTTP(resp.StatusCode)
	}
	var doc map[string]any
	if err := json.Unmarshal(body, &doc); err != nil {
		fmt.Fprintf(std.err, "comma-voice: readiness response is not a JSON object: %v\n", err)
		return exitOther
	}
	if *jsonOut {
		line, _ := json.Marshal(doc)
		fmt.Fprintf(std.out, "%s\n", line)
	} else {
		printReadiness(std.out, doc)
	}
	if ready, ok := doc["ready"].(bool); ok && !ready {
		fmt.Fprintln(std.err, "comma-voice: the Group is not ready for voice sessions")
		return exitOther
	}
	return exitOK
}

func printReadiness(w io.Writer, doc map[string]any) {
	keys := make([]string, 0, len(doc))
	for k := range doc {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		fmt.Fprintf(w, "%s: %s\n", k, formatValue(doc[k]))
	}
}

func formatValue(v any) string {
	switch t := v.(type) {
	case []any:
		parts := make([]string, len(t))
		for i, x := range t {
			parts[i] = formatValue(x)
		}
		return strings.Join(parts, ", ")
	case string:
		return t
	case nil:
		return "null"
	case map[string]any:
		b, _ := json.Marshal(t)
		return string(b)
	}
	return fmt.Sprint(v)
}

func readLimited(r io.Reader, limit int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(b)) > limit {
		return nil, errors.New("response too large")
	}
	return b, nil
}

type callFlags struct {
	conn           connFlags
	format         string
	displayName    string
	json           bool
	echoGate       bool
	input, output  string
	inputRate      int
	tail           time.Duration
	captureDevice  int
	playbackDevice int
}

func runCall(ctx context.Context, args []string, e env, std stdio) int {
	fs := newFlagSet("call", std)
	var f callFlags
	f.conn.register(fs)
	fs.StringVar(&f.format, "format", codec.PCM16At24k.Name, "session audio format: pcm16_24k or pcmu_8k")
	fs.StringVar(&f.displayName, "display-name", "", "caller name shown to the agent")
	fs.BoolVar(&f.json, "json", false, "write every text frame from the server to stdout as JSON lines")
	fs.BoolVar(&f.echoGate, "echo-gate", false, "mute the upload while agent audio plays and for 200 ms after (disables barge-in)")
	fs.StringVar(&f.input, "input", "", "file mode: mono 16-bit WAV to send, or - for raw PCM16 on stdin")
	fs.StringVar(&f.output, "output", "", "file mode: WAV file for agent audio, or - for raw PCM16 on stdout")
	fs.IntVar(&f.inputRate, "input-rate", 0, "sample rate of raw PCM16 on stdin (default: the session rate)")
	fs.DurationVar(&f.tail, "tail", 10*time.Second, "file mode: after the input ends, hang up after this long without agent audio")
	fs.IntVar(&f.captureDevice, "capture-device", -1, "device mode: capture device index from 'comma-voice devices'; -1 is the system default")
	fs.IntVar(&f.playbackDevice, "playback-device", -1, "device mode: playback device index from 'comma-voice devices'; -1 is the system default")
	if code, ok := parseFlags(fs, args); !ok {
		return code
	}
	format, err := codec.ParseFormat(f.format)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}
	if err := f.validate(); err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}
	server, group, key, err := f.conn.resolve(e)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}
	opts := session.Options{
		Server:      server,
		Group:       group,
		Key:         key,
		Format:      format,
		DisplayName: f.displayName,
		Client:      "comma-voice/" + version,
		Log:         std.err,
	}
	if f.json {
		opts.JSON = std.out
	}
	if _, err := session.SessionURL(server, group); err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return exitUsage
	}
	if f.input != "" {
		return runFileCall(ctx, f, opts, std)
	}
	return runDeviceCall(ctx, f, opts, std)
}

func (f callFlags) validate() error {
	if f.input == "" && f.output != "" {
		return errors.New("--output needs --input (file mode)")
	}
	if f.input == "" && f.inputRate != 0 {
		return errors.New("--input-rate applies only to --input -")
	}
	if f.input != "" && f.input != "-" && f.inputRate != 0 {
		return errors.New("--input-rate applies only to --input - (a WAV file carries its rate)")
	}
	if f.inputRate < 0 || f.inputRate > 192000 {
		return errors.New("--input-rate must be between 1 and 192000")
	}
	if f.json && f.output == "-" {
		return errors.New("--json and --output - both need stdout")
	}
	if f.tail <= 0 {
		return errors.New("--tail must be positive")
	}
	if f.input != "" && (f.captureDevice >= 0 || f.playbackDevice >= 0) {
		return errors.New("device flags do not apply in file mode")
	}
	return nil
}

// finish ends the session from the client side when it is still open and
// returns the process exit code.
func finish(s *session.Session, hangUp bool, std stdio) int {
	select {
	case <-s.Done():
		s.Close()
	default:
		if hangUp {
			s.End(endWait)
		} else {
			s.Close()
		}
	}
	r := s.Result()
	if r.Err != nil && r.Ended == nil {
		fmt.Fprintf(std.err, "comma-voice: connection lost: %v\n", r.Err)
	} else if r.CloseCode != 0 && r.CloseCode != session.CloseNormal {
		fmt.Fprintf(std.err, "comma-voice: server closed the session with code %d %s\n", r.CloseCode, r.CloseText)
	}
	return session.ExitCode(r)
}

func dialAndStart(ctx context.Context, opts session.Options, std stdio) (*session.Session, int) {
	s, err := session.Dial(ctx, opts)
	if err != nil {
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		return nil, session.ExitCodeForDial(err)
	}
	if _, err := s.Start(ctx); err != nil {
		if errors.Is(err, context.Canceled) {
			return nil, finish(s, true, std)
		}
		fmt.Fprintf(std.err, "comma-voice: %v\n", err)
		code := finish(s, false, std)
		if code == exitOK {
			code = exitOther
		}
		return nil, code
	}
	return s, exitOK
}

// uploadLoop sends caller audio frames until the source stops, the session
// closes, or ctx ends. With the echo gate, frames sent while agent audio
// plays are replaced by silence, which keeps the stream paced.
func uploadLoop(ctx context.Context, s *session.Session, src frameSource, format codec.Format, echoGate bool) error {
	for {
		frame, err := src.next(ctx)
		if err != nil {
			return err
		}
		if echoGate && s.Player().Busy(echoHold) {
			frame = format.Silence(len(frame))
		}
		select {
		case <-s.Done():
			return nil
		default:
		}
		if err := s.SendAudio(frame); err != nil {
			return err
		}
	}
}

type frameSource interface {
	next(ctx context.Context) ([]byte, error)
}

type lockedWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.w.Write(p)
}
