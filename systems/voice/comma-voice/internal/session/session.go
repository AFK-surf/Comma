// Package session is a comma.voice.v1 client: it opens the voice session
// WebSocket, sends caller audio, queues agent audio in a Player, answers
// output marks, and maps the session end to a process exit code.
package session

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/AFK-surf/comma/systems/voice/comma-voice/internal/codec"
	"github.com/gorilla/websocket"
)

// Subprotocol is the WebSocket subprotocol this client speaks.
const Subprotocol = "comma.voice.v1"

// Close codes defined by comma.voice.v1.
const (
	CloseNormal      = 1000
	CloseBadFrame    = 4400
	CloseRevoked     = 4401
	CloseTimeout     = 4408
	CloseBusy        = 4409
	CloseSlowReader  = 4410
	CloseUnavailable = 4503
)

// Exit codes of the comma-voice process.
const (
	ExitOK    = 0
	ExitUsage = 2
	ExitAuth  = 3
	ExitBusy  = 4
	ExitOther = 5
)

const (
	startTimeout = 10 * time.Second
	writeTimeout = 5 * time.Second
	readLimit    = 1 << 20
	// maxQueuedAudio bounds the local playback queue. The server closes a
	// session with 4410 long before a client that keeps reading gets here.
	maxQueuedAudio = 120 * time.Second
)

// Options configure one voice session.
type Options struct {
	Server      string
	Group       string
	Key         string
	Format      codec.Format
	DisplayName string
	Client      string
	// JSON, when set, receives every text frame from the server as one line.
	JSON io.Writer
	// Log receives status and final transcript lines.
	Log io.Writer
}

// HandshakeError reports an HTTP answer instead of a WebSocket upgrade.
type HandshakeError struct {
	Status int
	Body   string
}

func (e *HandshakeError) Error() string {
	msg := strings.TrimSpace(e.Body)
	if msg == "" {
		msg = http.StatusText(e.Status)
	}
	return fmt.Sprintf("server answered HTTP %d: %s", e.Status, msg)
}

// Started is the session.started message.
type Started struct {
	CallID       string `json:"call_id"`
	AudioFormat  string `json:"audio_format"`
	MaxDurationS int    `json:"max_duration_s"`
}

// Ended is the session.ended message.
type Ended struct {
	Reason    string  `json:"reason"`
	DurationS float64 `json:"duration_s"`
}

// ErrorMsg is the error message. The code is kept raw because the server may
// send it as a number or a string.
type ErrorMsg struct {
	Code    json.RawMessage `json:"code"`
	Message string          `json:"message"`
}

type inbound struct {
	Type string `json:"type"`
	Started
	Ended
	Name  string          `json:"name"`
	Role  string          `json:"role"`
	Text  string          `json:"text"`
	Final bool            `json:"final"`
	Code  json.RawMessage `json:"code"`
	Msg   string          `json:"message"`
}

// Result is how a session ended.
type Result struct {
	Ended     *Ended
	CloseCode int
	CloseText string
	Error     *ErrorMsg
	Err       error
}

// Session is one open comma.voice.v1 WebSocket.
type Session struct {
	opts   Options
	conn   *websocket.Conn
	player *Player

	writeMu sync.Mutex

	started   chan Started
	ended     chan struct{}
	endedOnce sync.Once
	done      chan struct{}

	lastAudio atomic.Int64

	mu     sync.Mutex
	result Result
}

// SessionURL returns the WebSocket URL for the Group's voice sessions.
func SessionURL(server, group string) (string, error) {
	u, err := groupURL(server, group, "/voice/sessions")
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "http":
		u.Scheme = "ws"
	case "https":
		u.Scheme = "wss"
	}
	return u.String(), nil
}

// ReadinessURL returns the HTTP URL of the Group's voice readiness endpoint.
func ReadinessURL(server, group string) (string, error) {
	u, err := groupURL(server, group, "/voice")
	if err != nil {
		return "", err
	}
	switch u.Scheme {
	case "ws":
		u.Scheme = "http"
	case "wss":
		u.Scheme = "https"
	}
	return u.String(), nil
}

func groupURL(server, group, suffix string) (*url.URL, error) {
	u, err := url.Parse(server)
	if err != nil {
		return nil, fmt.Errorf("bad server URL: %w", err)
	}
	switch u.Scheme {
	case "http", "https", "ws", "wss":
	default:
		return nil, fmt.Errorf("server URL must use http, https, ws, or wss: %q", server)
	}
	if u.Host == "" {
		return nil, fmt.Errorf("server URL has no host: %q", server)
	}
	if u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return nil, errors.New("server URL must not contain credentials, a query, or a fragment")
	}
	if group == "" || strings.ContainsAny(group, "/?#") {
		return nil, fmt.Errorf("bad group id %q", group)
	}
	u.Path = strings.TrimRight(u.Path, "/") + "/v1/agent-groups/" + group + suffix
	u.RawPath = ""
	return u, nil
}

// Dial opens the session WebSocket. It does not send session.start.
func Dial(ctx context.Context, opts Options) (*Session, error) {
	wsURL, err := SessionURL(opts.Server, opts.Group)
	if err != nil {
		return nil, err
	}
	dialer := websocket.Dialer{
		Proxy:            http.ProxyFromEnvironment,
		HandshakeTimeout: startTimeout,
		Subprotocols:     []string{Subprotocol},
	}
	header := http.Header{"Authorization": {"Bearer " + opts.Key}}
	conn, resp, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		if resp != nil {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			resp.Body.Close()
			return nil, &HandshakeError{Status: resp.StatusCode, Body: string(body)}
		}
		return nil, err
	}
	if conn.Subprotocol() != Subprotocol {
		conn.Close()
		return nil, fmt.Errorf("server did not accept subprotocol %s", Subprotocol)
	}
	conn.SetReadLimit(readLimit)
	s := &Session{
		opts:    opts,
		conn:    conn,
		player:  NewPlayer(opts.Format.Bytes(maxQueuedAudio)),
		started: make(chan Started, 1),
		ended:   make(chan struct{}),
		done:    make(chan struct{}),
	}
	go s.readLoop()
	go s.playedLoop()
	return s, nil
}

// Player returns the queue of agent audio for this session.
func (s *Session) Player() *Player { return s.player }

// Done is closed when the server connection has closed.
func (s *Session) Done() <-chan struct{} { return s.done }

// EndedCh is closed when session.ended arrives.
func (s *Session) EndedCh() <-chan struct{} { return s.ended }

// LastAgentAudio returns when agent audio last arrived, or the zero time.
func (s *Session) LastAgentAudio() time.Time {
	v := s.lastAudio.Load()
	if v == 0 {
		return time.Time{}
	}
	return time.Unix(0, v)
}

// Start sends session.start and waits for session.started.
func (s *Session) Start(ctx context.Context) (Started, error) {
	msg := map[string]any{
		"type":         "session.start",
		"audio_format": s.opts.Format.Name,
		"client":       s.opts.Client,
	}
	if s.opts.DisplayName != "" {
		msg["display_name"] = s.opts.DisplayName
	}
	if err := s.sendJSON(msg); err != nil {
		return Started{}, err
	}
	timer := time.NewTimer(startTimeout)
	defer timer.Stop()
	select {
	case st := <-s.started:
		if st.AudioFormat != "" && st.AudioFormat != s.opts.Format.Name {
			s.Close()
			return Started{}, fmt.Errorf("server started format %q, requested %q", st.AudioFormat, s.opts.Format.Name)
		}
		return st, nil
	case <-s.done:
		return Started{}, errors.New("session closed before session.started")
	case <-timer.C:
		s.Close()
		return Started{}, errors.New("no session.started within 10 s")
	case <-ctx.Done():
		return Started{}, ctx.Err()
	}
}

// SendAudio sends one binary audio frame.
func (s *Session) SendAudio(frame []byte) error {
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
	return s.conn.WriteMessage(websocket.BinaryMessage, frame)
}

// SendPlayed sends output.played for every mark the player has passed.
func (s *Session) SendPlayed() error {
	for _, name := range s.player.Played() {
		if err := s.sendJSON(map[string]any{"type": "output.played", "name": name}); err != nil {
			return err
		}
	}
	return nil
}

// End sends session.end, waits up to wait for session.ended or the server
// close, and then closes the connection.
func (s *Session) End(wait time.Duration) {
	_ = s.SendPlayed()
	if err := s.sendJSON(map[string]any{"type": "session.end"}); err == nil {
		timer := time.NewTimer(wait)
		select {
		case <-s.ended:
		case <-s.done:
		case <-timer.C:
		}
		timer.Stop()
	}
	s.Close()
}

// Close sends a normal close frame and closes the connection.
func (s *Session) Close() {
	s.writeMu.Lock()
	_ = s.conn.WriteControl(websocket.CloseMessage,
		websocket.FormatCloseMessage(CloseNormal, ""), time.Now().Add(time.Second))
	s.writeMu.Unlock()
	select {
	case <-s.done:
	case <-time.After(time.Second):
	}
	s.conn.Close()
	<-s.done
}

// Result returns how the session ended. Call it after Done is closed.
func (s *Session) Result() Result {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.result
}

func (s *Session) sendJSON(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	s.writeMu.Lock()
	defer s.writeMu.Unlock()
	s.conn.SetWriteDeadline(time.Now().Add(writeTimeout))
	return s.conn.WriteMessage(websocket.TextMessage, b)
}

func (s *Session) playedLoop() {
	for {
		select {
		case <-s.done:
			return
		case <-s.player.Notify():
			if err := s.SendPlayed(); err != nil {
				return
			}
		}
	}
}

func (s *Session) readLoop() {
	defer close(s.done)
	for {
		kind, data, err := s.conn.ReadMessage()
		if err != nil {
			s.mu.Lock()
			var ce *websocket.CloseError
			if errors.As(err, &ce) {
				s.result.CloseCode = ce.Code
				s.result.CloseText = ce.Text
			} else {
				s.result.Err = err
			}
			s.mu.Unlock()
			return
		}
		switch kind {
		case websocket.BinaryMessage:
			s.lastAudio.Store(time.Now().UnixNano())
			s.player.Push(data)
		case websocket.TextMessage:
			s.handleText(data)
		}
	}
}

func (s *Session) handleText(data []byte) {
	if s.opts.JSON != nil {
		var line bytes.Buffer
		if json.Compact(&line, data) == nil {
			line.WriteByte('\n')
			_, _ = s.opts.JSON.Write(line.Bytes())
		}
	}
	var m inbound
	if err := json.Unmarshal(data, &m); err != nil {
		s.logf("ignoring malformed text frame: %v", err)
		return
	}
	switch m.Type {
	case "session.started":
		s.logf("session started: call_id=%s format=%s max_duration_s=%d",
			m.CallID, m.AudioFormat, m.MaxDurationS)
		select {
		case s.started <- m.Started:
		default:
		}
	case "output.clear":
		s.player.Clear()
	case "output.mark":
		s.player.Mark(m.Name)
	case "transcript":
		if m.Final && m.Text != "" {
			s.logf("%s: %s", m.Role, m.Text)
		}
	case "session.ended":
		ended := m.Ended
		s.mu.Lock()
		s.result.Ended = &ended
		s.mu.Unlock()
		s.logf("session ended: reason=%s duration_s=%g", ended.Reason, ended.DurationS)
		s.endedOnce.Do(func() { close(s.ended) })
	case "error":
		e := ErrorMsg{Code: m.Code, Message: m.Msg}
		s.mu.Lock()
		s.result.Error = &e
		s.mu.Unlock()
		s.logf("error %s: %s", string(m.Code), m.Msg)
	}
}

func (s *Session) logf(format string, args ...any) {
	if s.opts.Log != nil {
		fmt.Fprintf(s.opts.Log, format+"\n", args...)
	}
}

// ExitCode maps a session result to the comma-voice exit code.
func ExitCode(r Result) int {
	switch r.CloseCode {
	case CloseRevoked:
		return ExitAuth
	case CloseBusy:
		return ExitBusy
	case CloseNormal:
		return ExitOK
	case 0, websocket.CloseNoStatusReceived, websocket.CloseAbnormalClosure:
		// No close code: the connection dropped or this client closed it.
		// An error message names the code the server meant to close with.
		if code, ok := errorCode(r.Error); ok && code != CloseNormal {
			return ExitCode(Result{CloseCode: code})
		}
		if r.Ended != nil {
			return ExitOK
		}
		return ExitOther
	}
	return ExitOther
}

// ExitCodeForDial maps a Dial error to the comma-voice exit code.
func ExitCodeForDial(err error) int {
	var he *HandshakeError
	if errors.As(err, &he) {
		return ExitCodeForHTTP(he.Status)
	}
	return ExitOther
}

// ExitCodeForHTTP maps an HTTP status to the comma-voice exit code.
func ExitCodeForHTTP(status int) int {
	switch status {
	case http.StatusUnauthorized, http.StatusForbidden:
		return ExitAuth
	case http.StatusConflict:
		return ExitBusy
	}
	return ExitOther
}

func errorCode(e *ErrorMsg) (int, bool) {
	if e == nil || len(e.Code) == 0 {
		return 0, false
	}
	var n int
	if json.Unmarshal(e.Code, &n) == nil {
		return n, true
	}
	var str string
	if json.Unmarshal(e.Code, &str) == nil {
		if _, err := fmt.Sscanf(str, "%d", &n); err == nil {
			return n, true
		}
	}
	return 0, false
}
