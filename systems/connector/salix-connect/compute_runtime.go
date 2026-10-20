package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

var computeRuntimeRetryInterval = time.Second

// Keep the authenticated carrier active through the gateway's idle timeout.
// The carrier is otherwise quiet while waiting for work, so relying on
// application frames would make every idle runtime reconnect periodically.
const defaultComputeRuntimePingInterval = 20 * time.Second

// Provider-native auth over this carrier is modeled in
// tla/salix/ComputeProviderAuth.tla.

type computeRuntimeInputRecord struct {
	ID                string         `json:"input_id"`
	RuntimeInstanceID string         `json:"runtime_instance_id"`
	ConnectionEpoch   string         `json:"connection_epoch"`
	Generation        int            `json:"generation"`
	Payload           map[string]any `json:"payload"`
}

type computeRuntimeSession struct {
	token       string
	instance    string
	epoch       string
	generation  int
	kind        string
	inputCursor string
	eventCursor string
	pendingAck  string
	features    []string
}

type computeRuntimeWire struct {
	conn    *websocket.Conn
	writeMu sync.Mutex
}

func (w *computeRuntimeWire) send(ctx context.Context, msg message) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
	}

	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	return w.conn.WriteJSON(msg)
}

func (w *computeRuntimeWire) writeJSON(value any) error {
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	return w.conn.WriteJSON(value)
}

func (w *computeRuntimeWire) ping() error {
	w.writeMu.Lock()
	defer w.writeMu.Unlock()
	return w.conn.WriteControl(
		websocket.PingMessage,
		[]byte("salix-runtime"),
		time.Now().Add(webSocketWriteTimeout),
	)
}

func (c *connector) computeRuntimeKeepaliveInterval() time.Duration {
	if c.runtimePingInterval > 0 {
		return c.runtimePingInterval
	}
	return defaultComputeRuntimePingInterval
}

type computeRuntimeReadyFrame struct {
	Type              string   `json:"type"`
	RuntimeInstanceID string   `json:"runtime_instance_id"`
	WorkloadID        string   `json:"workload_id"`
	Generation        int      `json:"generation"`
	RuntimeKind       string   `json:"runtime_kind"`
	ConnectionEpoch   string   `json:"connection_epoch"`
	Features          []string `json:"features"`
	InputCursor       string   `json:"input_cursor"`
	EventCursor       string   `json:"event_cursor"`
	Token             string   `json:"token"`
}

func computeRuntimeConfigured(cfg config) bool {
	return strings.TrimSpace(cfg.computeRuntimeBootstrapToken) != "" &&
		computeRuntimeIdentityConfigured(cfg)
}

// The bootstrap credential is erased after the first carrier handshake, but
// the workload identity remains authoritative for every later sealed
// subscription request on that carrier.
func computeRuntimeIdentityConfigured(cfg config) bool {
	return strings.TrimSpace(cfg.computeRuntimeURL) != "" &&
		strings.TrimSpace(cfg.computeRuntimeWorkloadID) != "" &&
		strings.TrimSpace(cfg.computeRuntimeInstanceID) != "" &&
		strings.TrimSpace(cfg.computeRuntimeEpoch) != "" &&
		strings.TrimSpace(cfg.computeRuntimeKind) != "" &&
		cfg.computeRuntimeGeneration > 0
}

func (c *connector) computeRuntimeInputLoop(ctx context.Context) {
	token := c.cfg.computeRuntimeBootstrapToken
	inputCursor := ""
	eventCursor := ""
	bootstrapPending := true
	retryDelay := computeRuntimeRetryInterval

	for {
		ws, session, err := c.connectComputeRuntime(ctx, token, inputCursor, eventCursor)
		if err == nil {
			retryDelay = computeRuntimeRetryInterval
			wire := &computeRuntimeWire{conn: ws}
			deactivate := c.activateRuntimeTransport(wire.send)
			token = session.token
			inputCursor = session.inputCursor
			eventCursor = session.eventCursor
			if bootstrapPending {
				// The bootstrap credential is needed only until one WSS handshake
				// has completed. Reconnects use the in-memory runtime credential.
				_ = os.Unsetenv("SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN")
				c.cfg.computeRuntimeBootstrapToken = ""
				bootstrapPending = false
			}

			err = c.consumeComputeRuntimeSocket(
				ctx,
				wire,
				&session,
				&token,
				&inputCursor,
				&eventCursor,
			)
			deactivate()
			_ = ws.Close()
			if ctx.Err() != nil {
				return
			}
			if errors.Is(err, errComputeRuntimeSessionRejected) {
				logf("compute runtime carrier rejected the session: %v", err)
				return
			}
			if err != nil {
				logf("compute runtime carrier disconnected: %v", err)
			}
		} else if errors.Is(err, errComputeRuntimeSessionRejected) {
			logf("compute runtime carrier rejected the handshake: %v", err)
			return
		} else if ctx.Err() != nil {
			return
		} else {
			logf("compute runtime carrier unavailable: %v", err)
		}

		if !waitComputeRuntimeRetry(ctx, retryDelay) {
			return
		}
		retryDelay = min(retryDelay*2, 30*time.Second)
	}
}

func waitComputeRuntimeRetry(ctx context.Context, delay time.Duration) bool {
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return false
	case <-timer.C:
		return true
	}
}

var errComputeRuntimeSessionRejected = errors.New("compute runtime session was rejected")

// A recovery deadline bounds the caller's wait, not the execution lifetime.
// Unknown rejections remain terminal. Only these control failures can retry.
func computeRuntimeRejection(reason string) error {
	if reason == "runtime_control_unavailable" || reason == "runtime_recovery_expired" {
		return fmt.Errorf("compute runtime control is unavailable: %s", reason)
	}
	return fmt.Errorf("%w: %s", errComputeRuntimeSessionRejected, reason)
}

func (c *connector) connectComputeRuntime(
	ctx context.Context,
	token string,
	inputCursor string,
	eventCursor string,
) (*websocket.Conn, computeRuntimeSession, error) {
	wsURL, err := computeRuntimeSocketURL(c.cfg.computeRuntimeURL)
	if err != nil {
		return nil, computeRuntimeSession{}, err
	}

	header := http.Header{}
	header.Set("authorization", "Bearer "+token)
	ws, _, err := websocket.DefaultDialer.DialContext(ctx, wsURL, header)
	if err != nil {
		return nil, computeRuntimeSession{}, err
	}

	closeOnCancel := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = ws.Close()
		case <-closeOnCancel:
		}
	}()
	defer close(closeOnCancel)

	hello := map[string]any{
		"type":               "runtime.hello",
		"protocol_version":   1,
		"supported_features": computeRuntimeFeatures(c.cfg),
		"input_cursor":       inputCursor,
		"event_cursor":       eventCursor,
	}
	if err := ws.WriteJSON(hello); err != nil {
		_ = ws.Close()
		return nil, computeRuntimeSession{}, err
	}

	for {
		_, data, err := ws.ReadMessage()
		if err != nil {
			_ = ws.Close()
			return nil, computeRuntimeSession{}, err
		}

		var frame struct {
			Type  string `json:"type"`
			Error string `json:"error"`
		}
		if err := json.Unmarshal(data, &frame); err != nil {
			_ = ws.Close()
			return nil, computeRuntimeSession{}, err
		}
		switch frame.Type {
		case "runtime.ready":
			var ready computeRuntimeReadyFrame
			if err := json.Unmarshal(data, &ready); err != nil {
				_ = ws.Close()
				return nil, computeRuntimeSession{}, err
			}
			session, err := newComputeRuntimeSession(ready, c.cfg)
			if err != nil {
				_ = ws.Close()
				return nil, computeRuntimeSession{}, err
			}
			return ws, session, nil
		case "runtime.error":
			_ = ws.Close()
			return nil, computeRuntimeSession{}, computeRuntimeRejection(frame.Error)
		default:
			_ = ws.Close()
			return nil, computeRuntimeSession{}, errors.New("invalid compute runtime handshake response")
		}
	}
}

func computeRuntimeSocketURL(base string) (string, error) {
	parsed, err := url.Parse(strings.TrimRight(base, "/") + "/v1/compute/runtime/socket")
	if err != nil {
		return "", err
	}
	switch parsed.Scheme {
	case "http":
		parsed.Scheme = "ws"
	case "https":
		parsed.Scheme = "wss"
	case "ws", "wss":
	default:
		return "", fmt.Errorf("unsupported compute runtime URL scheme %q", parsed.Scheme)
	}
	return parsed.String(), nil
}

func newComputeRuntimeSession(ready computeRuntimeReadyFrame, cfg config) (computeRuntimeSession, error) {
	if ready.Token == "" || ready.RuntimeInstanceID == "" || ready.ConnectionEpoch == "" {
		return computeRuntimeSession{}, errors.New("invalid compute runtime ready frame")
	}
	if ready.RuntimeInstanceID != cfg.computeRuntimeInstanceID ||
		ready.WorkloadID != cfg.computeRuntimeWorkloadID ||
		ready.Generation != cfg.computeRuntimeGeneration ||
		ready.RuntimeKind != cfg.computeRuntimeKind ||
		ready.ConnectionEpoch != cfg.computeRuntimeEpoch {
		return computeRuntimeSession{}, fmt.Errorf("%w: runtime identity changed", errComputeRuntimeSessionRejected)
	}
	requiredFeatures := []string{"runtime.input.v1", "runtime.event.v1"}
	for _, requiredFeature := range requiredFeatures {
		if !containsFeature(ready.Features, requiredFeature) {
			return computeRuntimeSession{}, fmt.Errorf("%w: required feature %q missing", errComputeRuntimeSessionRejected, requiredFeature)
		}
	}
	return computeRuntimeSession{
		token:       ready.Token,
		instance:    ready.RuntimeInstanceID,
		epoch:       ready.ConnectionEpoch,
		generation:  ready.Generation,
		kind:        ready.RuntimeKind,
		inputCursor: ready.InputCursor,
		eventCursor: ready.EventCursor,
		features:    append([]string(nil), ready.Features...),
	}, nil
}

func containsFeature(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func (c *connector) consumeComputeRuntimeSocket(
	ctx context.Context,
	wire *computeRuntimeWire,
	session *computeRuntimeSession,
	token *string,
	inputCursor *string,
	eventCursor *string,
) error {
	// Auth operations belong to this socket, never the outer reconnect loop.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	closeOnCancel := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			_ = wire.conn.Close()
		case <-closeOnCancel:
		}
	}()
	defer close(closeOnCancel)

	keepaliveDone := make(chan struct{})
	go func() {
		ticker := time.NewTicker(c.computeRuntimeKeepaliveInterval())
		defer ticker.Stop()

		for {
			select {
			case <-ctx.Done():
				return
			case <-keepaliveDone:
				return
			case <-ticker.C:
				if err := wire.ping(); err != nil {
					// Closing the socket unblocks the read loop and lets the
					// outer carrier loop reconnect with its durable cursors.
					_ = wire.conn.Close()
					return
				}
			}
		}
	}()
	defer close(keepaliveDone)

	for {
		_, data, err := wire.conn.ReadMessage()
		if err != nil {
			if ctx.Err() != nil {
				return ctx.Err()
			}
			return err
		}

		var frame struct {
			Type    string `json:"type"`
			InputID string `json:"input_id"`
			Error   string `json:"error"`
		}
		if err := json.Unmarshal(data, &frame); err != nil {
			return err
		}
		switch frame.Type {
		case "runtime.input":
			if session.pendingAck != "" {
				return errors.New("compute runtime delivered input before confirming the previous ACK")
			}
			var input computeRuntimeInputRecord
			if err := json.Unmarshal(data, &input); err != nil {
				return err
			}
			if err := c.consumeComputeRuntimeInput(ctx, input); err != nil {
				return err
			}
			if err := wire.writeJSON(map[string]any{
				"type":                "runtime.input_ack",
				"input_id":            input.ID,
				"runtime_instance_id": session.instance,
				"connection_epoch":    session.epoch,
			}); err != nil {
				return err
			}
			session.pendingAck = input.ID
		case "runtime.input_acked":
			if frame.InputID == "" || frame.InputID != session.pendingAck {
				return fmt.Errorf("%w: invalid input ACK confirmation", errComputeRuntimeSessionRejected)
			}
			if session.kind == "meeting_runtime" {
				*eventCursor = frame.InputID
			} else {
				*inputCursor = frame.InputID
			}
			session.pendingAck = ""
		case "response", "error":
			var response message
			if err := json.Unmarshal(data, &response); err != nil {
				return err
			}
			c.completeRuntimeProxy(response)
		case "request":
			var request message
			if err := json.Unmarshal(data, &request); err != nil {
				return err
			}
			// The carrier serves Meeting inputs and events only.
			if err := wire.writeJSON(message{ID: request.ID, Type: "error", Error: "unsupported compute runtime request"}); err != nil {
				return err
			}
		case "runtime.error":
			return computeRuntimeRejection(frame.Error)
		default:
			return fmt.Errorf("unsupported compute runtime frame %q", frame.Type)
		}
	}
}

const runtimeControlConcurrency = 2

func computeRuntimeFeatures(cfg config) []string {
	return []string{"runtime.input.v1", "runtime.event.v1"}
}

func (c *connector) consumeComputeRuntimeInput(ctx context.Context, input computeRuntimeInputRecord) error {
	if input.Payload == nil {
		return errors.New("compute runtime input has no payload")
	}

	frameType := stringParam(input.Payload, "frame_type")
	frame := mapParam(input.Payload, "payload")
	if frameType == "" || frame == nil {
		return errors.New("unsupported compute runtime input kind")
	}
	for key, value := range input.Payload {
		if key != "payload" {
			frame[key] = value
		}
	}
	switch frameType {
	case "meeting.join":
		_, err := c.methodMeetingJoin(ctx, frame)
		return err
	case "meeting.chat":
		_, err := c.methodMeetingSendChat(ctx, frame)
		return err
	case "meeting.leave":
		return c.methodMeetingLeave(ctx, frame)
	default:
		return fmt.Errorf("unsupported compute runtime frame %q", frameType)
	}
}

func computeExternalRuntimeProvider(provider string) bool {
	return provider == "codex" || provider == "claude"
}
