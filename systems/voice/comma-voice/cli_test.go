package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"testing/synctest"
	"time"

	"github.com/AFK-surf/comma/systems/voice/comma-voice/internal/codec"
	"github.com/gorilla/websocket"
)

const (
	testGroup = "grp_1"
	testKey   = "salix_vk_test_secret"
)

// fakeServer is a comma.voice.v1 server. Each test supplies the session script.
// It serves over in-memory pipes, so a call can run in a synctest bubble, where
// the client's pacing and playback run on the bubble's clock.
type fakeServer struct {
	t *testing.T
	// url is the server URL for the client, and dial connects the client to
	// the server whatever the address.
	url       string
	dial      func(ctx context.Context, network, address string) (net.Conn, error)
	hits      atomic.Int32
	readiness map[string]any
	script    func(c *fakeConn)
	lastAuth  atomic.Value
}

func newFakeServer(t *testing.T, script func(c *fakeConn)) *fakeServer {
	fs := &fakeServer{t: t, script: script, readiness: map[string]any{
		"ready":          true,
		"audio_formats":  []string{"pcm16_24k", "pcmu_8k"},
		"max_duration_s": 1800,
	}}
	listener := &memoryListener{conns: make(chan net.Conn), closed: make(chan struct{})}
	server := &http.Server{Handler: http.HandlerFunc(fs.handle)}
	served := make(chan struct{})
	go func() {
		defer close(served)
		_ = server.Serve(listener)
	}()
	t.Cleanup(func() {
		_ = server.Close()
		<-served
	})
	// Proxy settings leave localhost alone.
	fs.url = "http://localhost"
	fs.dial = func(ctx context.Context, _, _ string) (net.Conn, error) {
		client, peer := net.Pipe()
		select {
		case listener.conns <- peer:
			return client, nil
		case <-listener.closed:
			return nil, net.ErrClosed
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	return fs
}

// memoryListener accepts the server ends of the pipes that the client dials.
type memoryListener struct {
	conns  chan net.Conn
	closed chan struct{}
	once   sync.Once
}

func (l *memoryListener) Accept() (net.Conn, error) {
	select {
	case conn := <-l.conns:
		return conn, nil
	case <-l.closed:
		return nil, net.ErrClosed
	}
}

func (l *memoryListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}

func (l *memoryListener) Addr() net.Addr { return memoryAddr{} }

type memoryAddr struct{}

func (memoryAddr) Network() string { return "memory" }
func (memoryAddr) String() string  { return "localhost" }

func (fs *fakeServer) handle(w http.ResponseWriter, r *http.Request) {
	fs.hits.Add(1)
	fs.lastAuth.Store(r.Header.Get("Authorization"))
	if r.URL.RawQuery != "" {
		http.Error(w, "query not allowed", http.StatusBadRequest)
		return
	}
	if r.Header.Get("Authorization") != "Bearer "+testKey {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusUnauthorized)
		io.WriteString(w, `{"error":"unauthorized"}`)
		return
	}
	switch r.URL.Path {
	case "/v1/agent-groups/" + testGroup + "/voice":
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(fs.readiness)
	case "/v1/agent-groups/" + testGroup + "/voice/sessions":
		up := websocket.Upgrader{Subprotocols: []string{"comma.voice.v1"}}
		conn, err := up.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		if conn.Subprotocol() != "comma.voice.v1" {
			fs.t.Errorf("client did not offer comma.voice.v1")
			return
		}
		c := newFakeConn(fs.t, conn)
		fs.script(c)
	default:
		http.NotFound(w, r)
	}
}

type fakeConn struct {
	t      *testing.T
	conn   *websocket.Conn
	texts  chan map[string]any
	closed chan struct{}

	mu sync.Mutex
	// arrived signals each caller audio frame, and the close.
	arrived *sync.Cond
	audio   [][]byte
	ended   bool
}

func newFakeConn(t *testing.T, conn *websocket.Conn) *fakeConn {
	c := &fakeConn{t: t, conn: conn, texts: make(chan map[string]any, 64), closed: make(chan struct{})}
	c.arrived = sync.NewCond(&c.mu)
	go func() {
		defer close(c.closed)
		defer func() {
			c.mu.Lock()
			c.ended = true
			c.arrived.Broadcast()
			c.mu.Unlock()
		}()
		for {
			kind, data, err := conn.ReadMessage()
			if err != nil {
				return
			}
			if kind == websocket.BinaryMessage {
				c.mu.Lock()
				c.audio = append(c.audio, data)
				c.arrived.Broadcast()
				c.mu.Unlock()
				continue
			}
			var m map[string]any
			if err := json.Unmarshal(data, &m); err != nil {
				t.Errorf("client sent bad JSON %q", data)
				continue
			}
			c.texts <- m
		}
	}()
	return c
}

// expect returns the next text message, which must be of type typ. The wait
// has no deadline of its own: the go test timeout stops a client that never
// sends it.
func (c *fakeConn) expect(typ string) map[string]any {
	c.t.Helper()
	for {
		var m map[string]any
		select {
		case m = <-c.texts:
		case <-c.closed:
			// What arrived before the close is already queued.
			select {
			case m = <-c.texts:
			default:
				c.t.Errorf("connection closed while waiting for %s", typ)
				return nil
			}
		}
		if m["type"] == typ {
			return m
		}
		c.t.Errorf("expected %s, got %v", typ, m)
	}
}

// awaitFrames returns once n caller audio frames have arrived, or the
// connection has closed.
func (c *fakeConn) awaitFrames(n int) {
	c.mu.Lock()
	defer c.mu.Unlock()
	for len(c.audio) < n && !c.ended {
		c.arrived.Wait()
	}
}

func (c *fakeConn) send(v any) {
	b, _ := json.Marshal(v)
	if err := c.conn.WriteMessage(websocket.TextMessage, b); err != nil {
		c.t.Errorf("write text: %v", err)
	}
}

func (c *fakeConn) sendRaw(s string) {
	if err := c.conn.WriteMessage(websocket.TextMessage, []byte(s)); err != nil {
		c.t.Errorf("write text: %v", err)
	}
}

func (c *fakeConn) sendAudio(b []byte, chunk int) {
	for len(b) > 0 {
		n := min(chunk, len(b))
		if err := c.conn.WriteMessage(websocket.BinaryMessage, b[:n]); err != nil {
			c.t.Errorf("write audio: %v", err)
			return
		}
		b = b[n:]
	}
}

// closeWith closes the session with code and waits until the client has
// closed the connection.
func (c *fakeConn) closeWith(code int, text string) {
	// A zero deadline waits for the writer as long as it takes.
	c.conn.WriteControl(websocket.CloseMessage, websocket.FormatCloseMessage(code, text), time.Time{})
	<-c.closed
}

func (c *fakeConn) frames() [][]byte {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([][]byte(nil), c.audio...)
}

// start reads session.start and answers session.started.
func (c *fakeConn) start(format string) map[string]any {
	m := c.expect("session.start")
	if m == nil {
		return nil
	}
	if m["audio_format"] != format {
		c.t.Errorf("session.start audio_format = %v, want %s", m["audio_format"], format)
	}
	if client, _ := m["client"].(string); !strings.HasPrefix(client, "comma-voice/") {
		c.t.Errorf("session.start client = %v", m["client"])
	}
	c.send(map[string]any{"type": "session.started", "call_id": "vc_test", "audio_format": format,
		"max_duration_s": 1800, "future_field": map[string]any{"x": 1}})
	return m
}

type result struct {
	code           int
	stdout, stderr string
}

func runCLI(t *testing.T, ctx context.Context, fs *fakeServer, envs map[string]string, stdin io.Reader, args ...string) result {
	t.Helper()
	var out, errb bytes.Buffer
	if stdin == nil {
		stdin = strings.NewReader("")
	}
	e := env{lookup: func(k string) (string, bool) { v, ok := envs[k]; return v, ok }, dial: fs.dial}
	code := run(ctx, args, e, stdio{in: stdin, out: &out, err: &errb})
	return result{code: code, stdout: out.String(), stderr: errb.String()}
}

func baseEnv(fs *fakeServer) map[string]string {
	return map[string]string{
		"COMMA_VOICE_SERVER":  fs.url,
		"COMMA_VOICE_GROUP":   testGroup,
		"COMMA_VOICE_API_KEY": testKey,
	}
}

func constant(n int, v int16) []int16 {
	out := make([]int16, n)
	for i := range out {
		out[i] = v
	}
	return out
}

func writeWAV(t *testing.T, rate int, samples []int16) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "in.wav")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	w, err := codec.NewWAVWriter(f, rate)
	if err != nil {
		t.Fatal(err)
	}
	if err := w.Write(samples); err != nil {
		t.Fatal(err)
	}
	if err := w.Close(); err != nil {
		t.Fatal(err)
	}
	f.Close()
	return path
}

func readWAV(t *testing.T, path string) (int, []int16) {
	t.Helper()
	f, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	r, err := codec.NewWAVReader(f)
	if err != nil {
		t.Fatal(err)
	}
	var out []int16
	buf := make([]int16, 1024)
	for {
		n, err := codec.ReadSamples(r, buf)
		out = append(out, buf[:n]...)
		if err != nil {
			return r.SampleRate, out
		}
	}
}

func count(samples []int16, v int16) int {
	n := 0
	for _, s := range samples {
		if s == v {
			n++
		}
	}
	return n
}

// A file-mode call exchanges paced audio both ways, honors marks and
// output.clear, reports transcripts, and hangs up after the tail. The call runs
// on the bubble's clock, so its pacing is exact.
func TestFileCallPCM16(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		format := codec.PCM16At24k
		input := make([]int16, 4800) // 200 ms at 24 kHz
		for i := range input {
			input[i] = int16(i%1000 + 1)
		}
		inPath := writeWAV(t, 24000, input)
		outPath := filepath.Join(t.TempDir(), "out.wav")

		var callerFrames [][]byte
		var inputSpan, m1Delay time.Duration
		paced := make(chan struct{})
		fs := newFakeServer(t, func(c *fakeConn) {
			go func() {
				defer close(paced)
				c.awaitFrames(1)
				first := time.Now()
				c.awaitFrames(10)
				inputSpan = time.Since(first)
			}()
			start := c.start("pcm16_24k")
			if start != nil && start["display_name"] != "Ada" {
				t.Errorf("display_name = %v", start["display_name"])
			}
			c.sendRaw(`{"type":"future.message","payload":{"a":1}}`)
			sentA := time.Now()
			c.sendAudio(format.Encode(constant(2400, 1000)), 2400) // 100 ms
			c.send(map[string]any{"type": "output.mark", "name": "m1"})
			c.send(map[string]any{"type": "transcript", "role": "caller", "text": "hello", "final": true})
			c.send(map[string]any{"type": "transcript", "role": "agent", "text": "Hi", "final": false})
			c.send(map[string]any{"type": "transcript", "role": "agent", "text": "Hi there", "final": true})
			if m := c.expect("output.played"); m != nil {
				m1Delay = time.Since(sentA)
				if m["name"] != "m1" {
					t.Errorf("played %v, want m1", m["name"])
				}
			}
			// A long reply that the caller interrupts.
			c.sendAudio(format.Encode(constant(24000, 2000)), 2400)
			cleared := time.Now()
			c.send(map[string]any{"type": "output.clear"})
			c.send(map[string]any{"type": "output.mark", "name": "m2"})
			if m := c.expect("output.played"); m != nil && m["name"] != "m2" {
				t.Errorf("played %v, want m2", m["name"])
			}
			// The clear left nothing to play before m2.
			if waited := time.Since(cleared); waited >= 500*time.Millisecond {
				t.Errorf("m2 played %s after output.clear", waited)
			}
			c.sendAudio(format.Encode(constant(2400, 3000)), 2400)
			c.send(map[string]any{"type": "output.mark", "name": "m3"})
			if m := c.expect("output.played"); m != nil && m["name"] != "m3" {
				t.Errorf("played %v, want m3", m["name"])
			}
			c.expect("session.end")
			callerFrames = c.frames()
			c.send(map[string]any{"type": "session.ended", "reason": "completed", "duration_s": 0.7})
			c.closeWith(websocket.CloseNormalClosure, "")
		})

		res := runCLI(t, context.Background(), fs, baseEnv(fs), nil,
			"call", "--input", inPath, "--output", outPath, "--tail", "300ms",
			"--display-name", "Ada", "--json")
		if res.code != 0 {
			t.Fatalf("exit %d, stderr:\n%s", res.code, res.stderr)
		}

		// Caller audio: 20 ms frames, the input first, paced to real time, then silence.
		if len(callerFrames) < 11 {
			t.Fatalf("server got %d caller frames", len(callerFrames))
		}
		var sent []int16
		for i, f := range callerFrames {
			if len(f) != 960 {
				t.Fatalf("frame %d is %d bytes, want 960", i, len(f))
			}
			if i < 10 {
				sent = append(sent, format.Decode(f)...)
			} else if count(format.Decode(f), 0) != 480 {
				t.Fatalf("frame %d after the input is not silence", i)
			}
		}
		for i := range input {
			if sent[i] != input[i] {
				t.Fatalf("caller sample %d = %d, want %d", i, sent[i], input[i])
			}
		}
		<-paced
		if inputSpan != 9*frameDuration {
			t.Fatalf("the input's ten frames arrived over %s, not one frame apart", inputSpan)
		}

		// Playback is real time, so m1 is played after its 100 ms of audio.
		if m1Delay < 70*time.Millisecond {
			t.Fatalf("m1 played after %s, before its audio could play", m1Delay)
		}

		rate, out := readWAV(t, outPath)
		if rate != 24000 {
			t.Fatalf("output rate %d", rate)
		}
		if count(out[:2400], 1000) != 2400 {
			t.Fatalf("output does not start with reply A")
		}
		if count(out[len(out)-2400:], 3000) != 2400 {
			t.Fatalf("output does not end with reply C")
		}
		if n := count(out, 2000); n >= 2400 {
			t.Fatalf("output kept %d samples of the cleared reply", n)
		}

		var types []string
		sc := bufio.NewScanner(strings.NewReader(res.stdout))
		for sc.Scan() {
			var m map[string]any
			if err := json.Unmarshal(sc.Bytes(), &m); err != nil {
				t.Fatalf("stdout line is not JSON: %q", sc.Text())
			}
			types = append(types, m["type"].(string))
		}
		want := "session.started future.message output.mark transcript transcript transcript output.clear output.mark output.mark session.ended"
		if got := strings.Join(types, " "); got != want {
			t.Fatalf("JSON lines:\n got %s\nwant %s", got, want)
		}
		if !strings.Contains(res.stderr, "caller: hello\n") || !strings.Contains(res.stderr, "agent: Hi there\n") {
			t.Fatalf("final transcripts missing from stderr:\n%s", res.stderr)
		}
		if strings.Contains(res.stderr, "agent: Hi\n") {
			t.Fatalf("partial transcript printed:\n%s", res.stderr)
		}
	})
}

// Raw PCM on stdin and stdout, converted to and from mu-law at 8 kHz.
func TestFileCallMuLawRawPipes(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		input := make([]int16, 1600) // 200 ms at 8 kHz
		for i := range input {
			input[i] = int16((i%200)*100 - 10000)
		}
		var callerFrames [][]byte
		fs := newFakeServer(t, func(c *fakeConn) {
			c.start("pcmu_8k")
			reply := make([]byte, 800) // 100 ms
			for i := range reply {
				reply[i] = codec.MuLawEncode(1000)
			}
			c.sendAudio(reply, 400)
			c.send(map[string]any{"type": "output.mark", "name": "end-of-reply"})
			c.expect("output.played")
			c.expect("session.end")
			callerFrames = c.frames()
			c.send(map[string]any{"type": "session.ended", "reason": "completed", "duration_s": 0.5})
			c.closeWith(websocket.CloseNormalClosure, "")
		})
		res := runCLI(t, context.Background(), fs, baseEnv(fs), bytes.NewReader(codec.PCM16Bytes(input)),
			"call", "--format", "pcmu_8k", "--input", "-", "--input-rate", "8000", "--output", "-", "--tail", "200ms")
		if res.code != 0 {
			t.Fatalf("exit %d, stderr:\n%s", res.code, res.stderr)
		}
		if len(callerFrames) < 10 {
			t.Fatalf("server got %d caller frames", len(callerFrames))
		}
		for i, f := range callerFrames[:10] {
			if len(f) != 160 {
				t.Fatalf("frame %d is %d bytes, want 160", i, len(f))
			}
			for j, b := range f {
				if want := codec.MuLawEncode(input[i*160+j]); b != want {
					t.Fatalf("frame %d byte %d = %#x, want %#x", i, j, b, want)
				}
			}
		}
		out := codec.PCM16Samples([]byte(res.stdout))
		if len(out) != 800 || count(out, codec.MuLawDecode(codec.MuLawEncode(1000))) != 800 {
			t.Fatalf("stdout has %d samples, want 800 decoded reply samples", len(out))
		}
	})
}

// A 24 kHz WAV is resampled for a pcmu_8k session.
func TestFileCallResamplesInput(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		var got []int16
		fs := newFakeServer(t, func(c *fakeConn) {
			c.start("pcmu_8k")
			c.expect("session.end")
			for _, f := range c.frames() {
				got = append(got, codec.MuLawAt8k.Decode(f)...)
			}
			c.send(map[string]any{"type": "session.ended", "reason": "completed", "duration_s": 0.3})
			c.closeWith(websocket.CloseNormalClosure, "")
		})
		inPath := writeWAV(t, 24000, constant(2400, 8000)) // 100 ms
		res := runCLI(t, context.Background(), fs, baseEnv(fs), nil,
			"call", "--format", "pcmu_8k", "--input", inPath, "--tail", "100ms")
		if res.code != 0 {
			t.Fatalf("exit %d, stderr:\n%s", res.code, res.stderr)
		}
		if len(got) < 800 {
			t.Fatalf("got %d samples", len(got))
		}
		// 100 ms at 24 kHz is 800 samples at 8 kHz; the level survives mu-law.
		for i := 10; i < 790; i++ {
			if d := int(got[i]) - 8000; d < -300 || d > 300 {
				t.Fatalf("sample %d = %d, want about 8000", i, got[i])
			}
		}
		if got[900] != 0 {
			t.Fatalf("audio after the input is %d, want silence", got[900])
		}
	})
}

// Ctrl-C sends session.end and exits after session.ended, without waiting for
// its own timeout on the bubble's clock.
func TestInterruptSendsSessionEnd(t *testing.T) {
	synctest.Test(t, func(t *testing.T) {
		ctx, cancel := context.WithCancel(context.Background())
		defer cancel()
		fs := newFakeServer(t, func(c *fakeConn) {
			c.start("pcm16_24k")
			cancel()
			c.expect("session.end")
			c.send(map[string]any{"type": "session.ended", "reason": "caller_hangup", "duration_s": 0.1})
			c.closeWith(websocket.CloseNormalClosure, "")
		})
		inPath := writeWAV(t, 24000, constant(24000*5, 1))
		begin := time.Now()
		res := runCLI(t, ctx, fs, baseEnv(fs), nil, "call", "--input", inPath)
		if res.code != 0 {
			t.Fatalf("exit %d, stderr:\n%s", res.code, res.stderr)
		}
		if took := time.Since(begin); took >= endWait {
			t.Fatalf("hang-up took %s", took)
		}
		if !strings.Contains(res.stderr, "session ended: reason=caller_hangup") {
			t.Fatalf("stderr:\n%s", res.stderr)
		}
	})
}

func TestCloseCodesMapToExitCodes(t *testing.T) {
	cases := []struct {
		name  string
		close int
		want  int
	}{
		{"busy", 4409, 4},
		{"revoked", 4401, 3},
		{"draining", 4503, 5},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				fs := newFakeServer(t, func(c *fakeConn) {
					if tc.close == 4409 {
						c.expect("session.start")
					} else {
						c.start("pcm16_24k")
					}
					c.send(map[string]any{"type": "error", "code": tc.close, "message": tc.name})
					c.closeWith(tc.close, tc.name)
				})
				inPath := writeWAV(t, 24000, constant(24000, 1))
				res := runCLI(t, context.Background(), fs, baseEnv(fs), nil, "call", "--input", inPath)
				if res.code != tc.want {
					t.Fatalf("exit %d, want %d; stderr:\n%s", res.code, tc.want, res.stderr)
				}
			})
		})
	}
}

func TestUnauthorizedExitsWithAuthCode(t *testing.T) {
	fs := newFakeServer(t, func(c *fakeConn) { t.Error("socket opened with a bad key") })
	envs := baseEnv(fs)
	envs["COMMA_VOICE_API_KEY"] = "salix_gk_inbound_key"
	inPath := writeWAV(t, 24000, constant(480, 1))
	res := runCLI(t, context.Background(), fs, envs, nil, "call", "--input", inPath)
	if res.code != 3 || !strings.Contains(res.stderr, "HTTP 401") {
		t.Fatalf("call: exit %d, stderr:\n%s", res.code, res.stderr)
	}
	res = runCLI(t, context.Background(), fs, envs, nil, "check")
	if res.code != 3 {
		t.Fatalf("check: exit %d, stderr:\n%s", res.code, res.stderr)
	}
}

func TestCheckPrintsReadiness(t *testing.T) {
	fs := newFakeServer(t, nil)
	res := runCLI(t, context.Background(), fs, baseEnv(fs), nil, "check")
	if res.code != 0 {
		t.Fatalf("exit %d, stderr:\n%s", res.code, res.stderr)
	}
	for _, line := range []string{"audio_formats: pcm16_24k, pcmu_8k\n", "max_duration_s: 1800\n", "ready: true\n"} {
		if !strings.Contains(res.stdout, line) {
			t.Fatalf("stdout lacks %q:\n%s", line, res.stdout)
		}
	}
	fs.readiness["ready"] = false
	if res := runCLI(t, context.Background(), fs, baseEnv(fs), nil, "check"); res.code != 5 {
		t.Fatalf("not-ready exit %d", res.code)
	}
}

// The key comes only from COMMA_VOICE_API_KEY or --key-file.
func TestKeyNeverComesFromFlags(t *testing.T) {
	fs := newFakeServer(t, nil)
	envs := baseEnv(fs)
	delete(envs, "COMMA_VOICE_API_KEY")

	for _, args := range [][]string{
		{"check", "--key", testKey},
		{"check", "--api-key", testKey},
		{"check", "--server", fs.url, testKey},
		{"check"},
	} {
		if res := runCLI(t, context.Background(), fs, envs, nil, args...); res.code != 2 {
			t.Fatalf("%v: exit %d, want 2", args, res.code)
		}
	}
	if n := fs.hits.Load(); n != 0 {
		t.Fatalf("server contacted %d times without a key", n)
	}

	keyFile := filepath.Join(t.TempDir(), "key")
	os.WriteFile(keyFile, []byte(testKey+"\n"), 0o600)
	envs["COMMA_VOICE_API_KEY"] = "salix_vk_wrong"
	res := runCLI(t, context.Background(), fs, envs, nil, "check", "--key-file", keyFile)
	if res.code != 0 {
		t.Fatalf("--key-file: exit %d, stderr:\n%s", res.code, res.stderr)
	}
	if got := fs.lastAuth.Load(); got != "Bearer "+testKey {
		t.Fatalf("Authorization = %v", got)
	}
}

func TestUsageErrors(t *testing.T) {
	fs := newFakeServer(t, nil)
	for _, args := range [][]string{
		{},
		{"nope"},
		{"call", "--output", "x.wav"},
		{"call", "--input", "-", "--output", "-", "--json"},
		{"call", "--format", "opus"},
		{"call", "--input", filepath.Join(t.TempDir(), "missing.wav")},
	} {
		if res := runCLI(t, context.Background(), fs, baseEnv(fs), nil, args...); res.code != 2 {
			t.Fatalf("%v: exit %d, want 2; stderr:\n%s", args, res.code, res.stderr)
		}
	}
	if n := fs.hits.Load(); n != 0 {
		t.Fatalf("server contacted %d times on usage errors", n)
	}
}
