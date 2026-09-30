package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strconv"
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
	token           string
	instance        string
	epoch           string
	generation      int
	kind            string
	inputCursor     string
	eventCursor     string
	pendingAck      string
	features        []string
	executionTarget map[string]any
}

func (session computeRuntimeSession) supports(feature string) bool {
	return containsFeature(session.features, feature)
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
	Type              string         `json:"type"`
	RuntimeInstanceID string         `json:"runtime_instance_id"`
	WorkloadID        string         `json:"workload_id"`
	Generation        int            `json:"generation"`
	RuntimeKind       string         `json:"runtime_kind"`
	ConnectionEpoch   string         `json:"connection_epoch"`
	Features          []string       `json:"features"`
	InputCursor       string         `json:"input_cursor"`
	EventCursor       string         `json:"event_cursor"`
	Token             string         `json:"token"`
	ExecutionTarget   map[string]any `json:"execution_target"`
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
		(cfg.computeRuntimeKind != "external_worker" ||
			(computeExternalRuntimeProvider(cfg.computeRuntimeProvider) &&
				strings.TrimSpace(cfg.computeRuntimeTenantID) != "" &&
				strings.TrimSpace(cfg.computeRuntimeProjectID) != "")) &&
		cfg.computeRuntimeGeneration > 0
}

func (c *connector) prepareComputeRuntime(ctx context.Context) error {
	if c.cfg.computeRuntimeKind != "external_worker" {
		return nil
	}
	if c.runtimeInventory == nil {
		return errors.New("compute runtime inventory is unavailable")
	}
	// A runtime-agent does not open the normal remote connector session whose
	// connect probe populates the private provider inventory. Discover locally
	// before opening the carrier so the Server cannot dispatch work to a runtime
	// that has no unambiguous executable target.
	if _, err := c.runtimeInventory.probe(ctx, "", "", "compute_runtime_connect"); err != nil {
		return fmt.Errorf("probe provider inventory: %w", err)
	}
	if _, err := c.computeRuntimeCommand(c.cfg.computeRuntimeProvider); err != nil {
		return err
	}
	return nil
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
			c.setComputeRuntimeExecutionTarget(session.executionTarget)
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
	if cfg.computeRuntimeKind == "external_worker" && containsFeature(ready.Features, "runtime.execution.v1") && !validComputeRuntimeExecutionTarget(ready.ExecutionTarget, cfg) {
		return computeRuntimeSession{}, fmt.Errorf("%w: runtime execution target changed", errComputeRuntimeSessionRejected)
	}
	requiredFeatures := []string{"runtime.input.v1", "runtime.event.v1"}
	for _, requiredFeature := range requiredFeatures {
		if !containsFeature(ready.Features, requiredFeature) {
			return computeRuntimeSession{}, fmt.Errorf("%w: required feature %q missing", errComputeRuntimeSessionRejected, requiredFeature)
		}
	}
	return computeRuntimeSession{
		token:           ready.Token,
		instance:        ready.RuntimeInstanceID,
		epoch:           ready.ConnectionEpoch,
		generation:      ready.Generation,
		kind:            ready.RuntimeKind,
		inputCursor:     ready.InputCursor,
		eventCursor:     ready.EventCursor,
		features:        append([]string(nil), ready.Features...),
		executionTarget: maps.Clone(ready.ExecutionTarget),
	}, nil
}

func validComputeRuntimeExecutionTarget(target map[string]any, cfg config) bool {
	if len(target) != 9 ||
		stringParam(target, "runtime_instance_id") != cfg.computeRuntimeInstanceID ||
		stringParam(target, "runtime_connection_epoch") != cfg.computeRuntimeEpoch ||
		stringParam(target, "workload_id") != cfg.computeRuntimeWorkloadID ||
		intParam(target, "runtime_generation", 0) != cfg.computeRuntimeGeneration ||
		intParam(target, "workload_generation", 0) != cfg.computeRuntimeGeneration {
		return false
	}
	for _, key := range []string{"allocation_id", "container_id", "container_instance_id"} {
		if stringParam(target, key) == "" {
			return false
		}
	}
	return intParam(target, "allocation_generation", 0) > 0
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
	var reconciliation <-chan struct{}
	if session.kind == "external_worker" && session.supports("runtime.execution.v1") {
		result := make(chan struct{}, 1)
		reconciliation = result
		go func() {
			c.reconcileRuntimeOperationRights(ctx)
			result <- struct{}{}
		}()
	}
	reconciliationComplete := reconciliation == nil
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
			if !reconciliationComplete && runtimeRequestNeedsOperationRecovery(request.Method) {
				select {
				case <-reconciliation:
					reconciliationComplete = true
				default:
					if err := wire.writeJSON(message{ID: request.ID, Type: "error", Error: "runtime operation recovery pending"}); err != nil {
						return err
					}
					continue
				}
			}
			if missing := missingComputeRuntimeFeature(request.Method, *session); missing != "" {
				if err := wire.writeJSON(message{ID: request.ID, Type: "error", Error: "runtime feature unavailable: " + missing}); err != nil {
					return err
				}
				continue
			}
			// Control and long operations have independent fixed slots. Admit
			// before spawning, never queue, and keep reading replies/disconnects.
			slots, capacityError := c.acquireComputeRuntimeRequest(request)
			if slots == nil {
				if err := wire.writeJSON(message{ID: request.ID, Type: "error", Error: capacityError}); err != nil {
					return err
				}
				continue
			}
			capturedSession := *session
			capturedTransport := c.getActiveTransport()
			go func() {
				defer func() { <-slots }()
				response := c.computeRuntimeAuthReplyAdmitted(ctx, request, capturedSession, capturedTransport)
				if ctx.Err() == nil {
					if err := wire.writeJSON(response); err != nil {
						_ = wire.conn.Close()
					}
				}
			}()
		case "runtime.error":
			return computeRuntimeRejection(frame.Error)
		default:
			return fmt.Errorf("unsupported compute runtime frame %q", frame.Type)
		}
	}
}

func runtimeRequestNeedsOperationRecovery(method string) bool {
	if method == "agent_runtime_stop" || method == "runtime_auth_read" || method == "runtime_auth_status" || method == "session_migration_status" || method == "runtime_subscription_sync" {
		return false
	}
	return true
}

func missingComputeRuntimeFeature(method string, session computeRuntimeSession) string {
	required := ""
	switch {
	case strings.HasPrefix(method, "runtime_auth_"):
		required = "runtime.auth.v1"
	case strings.HasPrefix(method, "session_migration_"):
		required = "runtime.execution.v1"
	case method == "runtime_subscription_sync":
		required = "runtime.subscription.v1"
	case method == "agent_runtime_stop":
		required = "runtime.agent_stop.v1"
	}
	if required != "" && !session.supports(required) {
		return required
	}
	if runtimeAuthNeedsExecution(method) && !session.supports("runtime.execution.v1") {
		return "runtime.execution.v1"
	}
	return ""
}

func runtimeAuthNeedsExecution(method string) bool {
	return strings.HasPrefix(method, "runtime_auth_") && method != "runtime_auth_read" && method != "runtime_auth_status"
}

const runtimeControlConcurrency = 2

func (c *connector) acquireComputeRuntimeRequest(request message) (chan struct{}, string) {
	method := request.Method
	control := method == "agent_runtime_stop" || method == "agent_runtime_quiet" ||
		method == "runtime_auth_read" || method == "runtime_auth_status" ||
		method == "runtime_auth_login_cancel" || method == "runtime_auth_input_cancel" ||
		method == "session_migration_status" ||
		(method == "session_migration_prepare" && boolParam(request.Params, "cancel"))
	slots := c.runtimeAuthSlots
	errorMessage := "runtime operation capacity exhausted"
	if control {
		slots = c.runtimeControlSlots
		errorMessage = "runtime control capacity exhausted"
	}
	select {
	case slots <- struct{}{}:
		return slots, ""
	default:
		return nil, errorMessage
	}
}

func computeRuntimeFeatures(cfg config) []string {
	features := []string{"runtime.input.v1", "runtime.event.v1"}
	if cfg.computeRuntimeKind == "external_worker" {
		features = append(features, "runtime.auth.v1", "runtime.execution.v1", "runtime.agent_stop.v1", "runtime.subscription.v1")
	}
	return features
}

// A missing handshake target must fail closed for a configured Compute runtime.
// Ordinary connected/stdio Connectors have no Compute allocation or Host right.
func (c *connector) requiresHostRuntimeExecution() bool {
	return c.cfg.computeRuntimeURL != "" || c.cfg.computeRuntimeKind != "" ||
		len(c.currentComputeRuntimeExecutionTarget()) > 0
}

func (c *connector) setComputeRuntimeExecutionTarget(target map[string]any) {
	c.computeExecutionMu.Lock()
	c.computeExecutionTarget = maps.Clone(target)
	c.computeExecutionMu.Unlock()
}

func (c *connector) currentComputeRuntimeExecutionTarget() map[string]any {
	c.computeExecutionMu.Lock()
	defer c.computeExecutionMu.Unlock()
	return maps.Clone(c.computeExecutionTarget)
}

func (c *connector) runtimeExecution(
	ctx context.Context,
	action, executionID string,
	target map[string]any,
) (map[string]any, error) {
	return c.runtimeExecutionKind(ctx, action, executionID, "main_execution", time.Time{}, target, "")
}

func (c *connector) runtimeExecutionKind(
	ctx context.Context,
	action, executionID, kind string,
	deadline time.Time,
	target map[string]any,
	operationRequestID string,
) (map[string]any, error) {
	if !slices.Contains([]string{"acquire", "release", "list"}, action) || len(target) == 0 {
		return nil, errors.New("invalid runtime execution request")
	}
	params := map[string]any{"action": action, "target": maps.Clone(target)}
	if action != "list" {
		if executionID == "" || !slices.Contains([]string{
			"main_execution", "auth_operation", "migration_export", "migration_import", "exec", "process", "build",
		}, kind) {
			return nil, errors.New("runtime execution id is required")
		}
		params["execution_id"] = executionID
		params["kind"] = kind
		if kind != "main_execution" {
			if operationRequestID == "" {
				return nil, errors.New("runtime operation request context is required")
			}
			params["operation_request_id"] = operationRequestID
		}
		if action == "acquire" {
			if kind == "main_execution" {
				params["deadline_unix_nano"] = "0"
			} else if deadline.After(time.Now()) {
				params["deadline_unix_nano"] = strconv.FormatInt(deadline.UnixNano(), 10)
			} else {
				return nil, errors.New("runtime execution deadline is required")
			}
		}
	}
	transport := c.getActiveTransport()
	if transport == nil {
		return nil, runtimeOperationNotAcceptedError{err: errRuntimeTransportUnavailable}
	}
	requestCtx, cancel := context.WithTimeout(ctx, 90*time.Second)
	defer cancel()
	// Match ComputeRuntimeSocket's two in-flight requests per class. Queue
	// bounded local workers here instead of failing their recovery at admission.
	class := "operation"
	if action == "list" || action == "release" {
		class = "control"
	}
	c.computeExecutionMu.Lock()
	if c.runtimeExecutionSlots == nil {
		c.runtimeExecutionSlots = map[string]chan struct{}{}
	}
	slots := c.runtimeExecutionSlots[class]
	if slots == nil {
		slots = make(chan struct{}, 2)
		c.runtimeExecutionSlots[class] = slots
	}
	c.computeExecutionMu.Unlock()
	select {
	case slots <- struct{}{}:
		defer func() { <-slots }()
	case <-requestCtx.Done():
		return nil, runtimeOperationNotAcceptedError{err: requestCtx.Err()}
	}
	id := c.nextRuntimeRequestID("runtime_execution_")
	reply, err := c.sendRuntimeRequest(requestCtx, transport, nil, message{
		ID: id, Type: "request", Method: "runtime_execution", Params: params,
	})
	if err != nil {
		return nil, err
	}
	if reply.Type == "error" || reply.Error != "" {
		return nil, runtimeOperationNotAcceptedError{err: errors.New(defaultString(reply.Error, "runtime execution unavailable"))}
	}
	result, ok := reply.Result.(map[string]any)
	if !ok {
		return nil, errors.New("invalid runtime execution response")
	}
	return result, nil
}

func (c *connector) computeRuntimeAuthReply(ctx context.Context, request message, session computeRuntimeSession) message {
	if err := c.acquireRuntimeAuth(ctx); err != nil {
		return message{ID: request.ID, Type: "error", Error: "runtime auth capacity exhausted"}
	}
	defer func() { <-c.runtimeAuthSlots }()
	return c.computeRuntimeAuthReplyAdmitted(ctx, request, session, c.getActiveTransport())
}

func (c *connector) computeRuntimeAuthReplyAdmitted(ctx context.Context, request message, session computeRuntimeSession, carrier *runtimeTransport) message {
	if request.Method == "runtime_subscription_sync" {
		result, err := c.computeSubscriptionSync(ctx, request, session, carrier)
		if err != nil {
			return message{ID: request.ID, Type: "error", Error: "subscription access unavailable"}
		}
		return message{ID: request.ID, Type: "response", Result: result}
	}

	if strings.HasPrefix(request.Method, "session_migration_") && request.ID != "" {
		if !c.computeRuntimeTargetMatches(mapParam(request.Params, "target"), session) || stringParam(request.Params, "provider") != c.cfg.computeRuntimeProvider {
			return message{ID: request.ID, Type: "error", Error: "compute migration target changed"}
		}
		action := strings.TrimPrefix(request.Method, "session_migration_")
		result, err := c.computeMigrationOperation(ctx, request.ID, action, request.Params)
		if err != nil {
			return message{ID: request.ID, Type: "error", Error: err.Error()}
		}
		return message{ID: request.ID, Type: "response", Result: result}
	}
	if request.Method == "agent_runtime_stop" && request.ID != "" {
		target := mapParam(request.Params, "target")
		if !c.computeRuntimeTargetMatches(target, session) || len(request.Params) != 2 || stringParam(request.Params, "session_id") == "" {
			return message{ID: request.ID, Type: "error", Error: "compute archive target changed"}
		}
		result, err := c.methodAgentRuntimeStop(ctx, map[string]any{
			"provider": c.cfg.computeRuntimeProvider, "session_id": request.Params["session_id"],
		})
		if err != nil {
			return message{ID: request.ID, Type: "error", Error: "compute archive stop is unconfirmed"}
		}
		return message{ID: request.ID, Type: "response", Result: result}
	}
	if request.Method == "agent_runtime_quiet" && request.ID != "" {
		target := mapParam(request.Params, "target")
		if !c.computeRuntimeTargetMatches(target, session) || len(request.Params) != 1 {
			return message{ID: request.ID, Type: "error", Error: "compute quiet target changed"}
		}
		result, err := c.methodAgentRuntimeQuiet(ctx, map[string]any{"provider": c.cfg.computeRuntimeProvider})
		if err != nil {
			return message{ID: request.ID, Type: "error", Error: "compute runtime is not quiet"}
		}
		return message{ID: request.ID, Type: "response", Result: result}
	}
	if request.ID != "" && ((request.Method == "runtime_auth_login_start" && stringParam(mapParam(request.Params, "target"), "actor_id") != "") || request.Method == "runtime_auth_status" || request.Method == "runtime_auth_verify" || request.Method == "runtime_auth_input_begin" || request.Method == "runtime_auth_input_submit" || request.Method == "runtime_auth_input_cancel") {
		result, err := c.computePrivateRuntimeAuthOwned(ctx, request, session, carrier)
		if err != nil {
			return message{ID: request.ID, Type: "error", Error: err.Error()}
		}
		return message{ID: request.ID, Type: "response", Result: result}
	}
	if request.ID == "" || (request.Method != "runtime_auth_read" && request.Method != "runtime_auth_login_start" && request.Method != "runtime_auth_login_cancel") {
		return message{ID: request.ID, Type: "error", Error: "unsupported compute runtime auth request"}
	}
	params, err := c.computeRuntimeAuthParams(request.Params, session)
	if err != nil {
		return message{ID: request.ID, Type: "error", Error: "compute runtime auth target rejected"}
	}
	var result map[string]any
	switch request.Method {
	case "runtime_auth_read":
		if provider := stringParam(params, "provider"); provider == "pi" || provider == "claude" {
			result, err = c.computePortableRuntimeAuthRead(ctx, params)
		} else {
			result, err = c.runtimeAuthReadAdmitted(ctx, params)
			if err == nil {
				result, err = c.computeRuntimeAuthReadiness(ctx, params, result)
			}
		}
	case "runtime_auth_login_start":
		key := runtimeAuthOperationKey(request.Params)
		if _, err = c.acquireRuntimeOperation(ctx, request.ID, key, key, "auth_operation", 15*time.Minute); err == nil {
			result, err = c.runtimeAuthLoginStartAdmitted(ctx, params)
			if err != nil && !runtimeAuthNativeOutcomeUnknown(err) {
				if releaseErr := c.releaseRuntimeOperation(context.Background(), request.ID, key); releaseErr != nil {
					err = fmt.Errorf("runtime operation settlement is unknown; action required: %w", releaseErr)
				}
			}
		}
	case "runtime_auth_login_cancel":
		familyID := runtimeAuthOperationKey(request.Params)
		var right runtimeOperationRight
		if right, err = c.runtimeOperations.requireActiveFamily(familyID); err == nil {
			result, err = c.runtimeAuthLoginCancelAdmitted(ctx, params)
		}
		if err == nil {
			if releaseErr := c.releaseRuntimeOperation(ctx, request.ID, right.ActivityID); releaseErr != nil {
				err = fmt.Errorf("runtime operation settlement is unknown; action required: %w", releaseErr)
			}
		}
	}
	if err != nil {
		errorMessage := "compute runtime auth operation failed"
		if strings.Contains(err.Error(), "action required") {
			errorMessage = err.Error()
		}
		return message{ID: request.ID, Type: "error", Error: errorMessage}
	}
	return message{ID: request.ID, Type: "response", Result: result}
}

func (c *connector) computePrivateRuntimeAuthOwned(ctx context.Context, request message, session computeRuntimeSession, carrier *runtimeTransport) (map[string]any, error) {
	key := runtimeAuthOperationKey(request.Params)
	switch request.Method {
	case "runtime_auth_status":
		if c.runtimeOperations.familyRecoveryRequired(key) {
			return nil, errors.New("runtime operation recovery is unknown; action required")
		}
		result, err := c.computePrivateRuntimeAuth(ctx, request, session, carrier)
		if err == nil && result["attempt"] == nil && stringParam(mapParam(result, "auth"), "status") != "pending" {
			if right, ok := c.runtimeOperations.familyState(key); ok {
				if releaseErr := c.releaseRuntimeOperation(ctx, request.ID, right.ActivityID); releaseErr != nil {
					return nil, fmt.Errorf("runtime operation settlement is unknown; action required: %w", releaseErr)
				}
			}
		}
		return result, err

	case "runtime_auth_verify":
		executionID := key + ":verify:" + request.ID
		if _, err := c.acquireRuntimeOperation(ctx, request.ID, key, executionID, "auth_operation", 15*time.Minute); err != nil {
			return nil, err
		}
		result, operationErr := c.computePrivateRuntimeAuth(ctx, request, session, carrier)
		if ctx.Err() != nil {
			return nil, errors.New("runtime operation settlement is unknown; action required")
		}
		if releaseErr := c.releaseRuntimeOperation(ctx, request.ID, executionID); releaseErr != nil {
			return nil, fmt.Errorf("runtime operation settlement is unknown; action required: %w", releaseErr)
		}
		return result, operationErr

	case "runtime_auth_login_start", "runtime_auth_input_begin":
		if _, err := c.acquireRuntimeOperation(ctx, request.ID, key, key, "auth_operation", 15*time.Minute); err != nil {
			return nil, err
		}
		result, operationErr := c.computePrivateRuntimeAuth(ctx, request, session, carrier)
		if operationErr != nil && !runtimeAuthNativeOutcomeUnknown(operationErr) {
			if releaseErr := c.releaseRuntimeOperation(context.Background(), request.ID, key); releaseErr != nil {
				return nil, fmt.Errorf("runtime operation settlement is unknown; action required: %w", releaseErr)
			}
		}
		return result, operationErr

	case "runtime_auth_input_submit", "runtime_auth_input_cancel":
		right, ownershipErr := c.runtimeOperations.requireActiveFamily(key)
		if ownershipErr != nil {
			return nil, ownershipErr
		}
		result, operationErr := c.computePrivateRuntimeAuth(ctx, request, session, carrier)
		if operationErr == nil {
			if releaseErr := c.releaseRuntimeOperation(ctx, request.ID, right.ActivityID); releaseErr != nil {
				return nil, fmt.Errorf("runtime operation settlement is unknown; action required: %w", releaseErr)
			}
		}
		return result, operationErr
	}
	return c.computePrivateRuntimeAuth(ctx, request, session, carrier)
}

func runtimeAuthOperationKey(params map[string]any) string {
	return runtimeAuthOperationFamily(params)
}

func (c *connector) computeMigrationOperation(ctx context.Context, requestID, action string, params map[string]any) (map[string]any, error) {
	if action != "export" && action != "import" {
		operationID := stringParam(params, "operation_id")
		if operationID != "" && c.runtimeOperations.familyRecoveryRequired(runtimeMigrationOperationFamily(operationID)) {
			return nil, errors.New("runtime operation recovery is unknown; action required")
		}
		return c.methodSessionMigration(ctx, action, params)
	}
	operationID := stringParam(params, "operation_id")
	kind := "migration_" + action
	activityID := kind + ":" + operationID
	familyID := runtimeMigrationOperationFamily(operationID)
	_, err := c.acquireRuntimeOperation(ctx, requestID, familyID, activityID, kind, 30*time.Minute)
	if err != nil {
		return nil, err
	}
	result, operationErr := c.methodSessionMigration(ctx, action, params)
	if ctx.Err() != nil {
		return nil, errors.New("runtime operation settlement is unknown; action required")
	}
	if releaseErr := c.releaseRuntimeOperation(ctx, requestID, activityID); releaseErr != nil {
		return nil, fmt.Errorf("runtime operation settlement is unknown; action required: %w", releaseErr)
	}
	return result, operationErr
}

func (c *connector) computeRuntimeAuthParams(params map[string]any, session computeRuntimeSession) (map[string]any, error) {
	target := mapParam(params, "target")
	if !c.computeRuntimeTargetMatches(target, session) {
		return nil, errors.New("compute runtime auth target changed")
	}
	for key := range params {
		if key != "target" && key != "flow" && key != "attempt_id" {
			return nil, errors.New("unsupported compute runtime auth parameter")
		}
	}
	provider := c.cfg.computeRuntimeProvider
	var identity string
	for _, runtime := range c.runtimeInventory.snapshot() {
		if stringParam(runtime, "kind") == "external" && stringParam(runtime, "provider") == provider {
			candidate := strings.TrimSpace(stringParam(runtime, "identity_material"))
			if candidate == "" || identity != "" {
				return nil, errors.New("compute runtime auth target is ambiguous")
			}
			identity = candidate
		}
	}
	if !computeExternalRuntimeProvider(provider) || identity == "" {
		return nil, errors.New("compute runtime auth provider is unsupported")
	}
	native := map[string]any{"provider": provider, "identity_material": identity}
	if flow := stringParam(params, "flow"); flow != "" {
		native["flow"] = flow
	}
	if attemptID := stringParam(params, "attempt_id"); attemptID != "" {
		native["attempt_id"] = attemptID
	}
	return native, nil
}

func (c *connector) computeRuntimeTargetMatches(target map[string]any, session computeRuntimeSession) bool {
	return target != nil && stringParam(target, "tenant_id") == c.cfg.computeRuntimeTenantID &&
		stringParam(target, "project_id") == c.cfg.computeRuntimeProjectID &&
		stringParam(target, "workload_id") == c.cfg.computeRuntimeWorkloadID &&
		stringParam(target, "runtime_instance_id") == session.instance &&
		intParam(target, "generation", 0) == session.generation &&
		stringParam(target, "connection_epoch") == session.epoch &&
		stringParam(target, "provider") == c.cfg.computeRuntimeProvider
}

func (c *connector) computePortableRuntimeAuthRead(ctx context.Context, params map[string]any) (map[string]any, error) {
	provider := stringParam(params, "provider")
	identity := stringParam(params, "identity_material")
	runtimes, err := c.runtimeInventory.probe(ctx, provider, identity, "compute_runtime_auth_read")
	if err != nil || len(runtimes) != 1 {
		return nil, errors.New("compute runtime native readiness probe failed")
	}
	runtime := runtimes[0]
	managedReady := c.managedRuntimeCredential(provider, identity) != nil
	authReady := runtime["auth_ready"] == true || managedReady
	status := "unauthenticated"
	auth := map[string]any{
		"schema_version":       1,
		"status":               status,
		"requires_openai_auth": false,
		"observed_at":          int64Param(runtime, "readiness_checked_at", time.Now().UnixMilli()),
	}
	if authReady {
		auth["status"] = "authenticated"
	}
	if nativeAuth := mapParam(runtime, "auth"); len(nativeAuth) != 0 && !managedReady {
		auth = cloneAuthSnapshot(nativeAuth)
	}
	nativeReady := runtime["native_server_startable"] == true && runtime["app_server_startable"] == true
	ready := runtime["ready"] == true
	if managedReady {
		// Managed static credentials stay in memory and are injected only into
		// admitted executions. Override only native credential-probe failures.
		issue := stringParam(runtime, "readiness_issue")
		ready = runtime["version_detected"] == true && nativeReady &&
			(issue == "" || issue == "authentication_required" || issue == "verification_required")
	}
	return map[string]any{
		"auth":         auth,
		"native_ready": nativeReady,
		"ready":        ready,
	}, nil
}

func (c *connector) computeRuntimeAuthReadiness(ctx context.Context, params, result map[string]any) (map[string]any, error) {
	runtimes, err := c.runtimeInventory.probe(ctx, stringParam(params, "provider"), stringParam(params, "identity_material"), "compute_runtime_auth_read")
	if err != nil || len(runtimes) != 1 {
		return nil, errors.New("compute runtime native readiness probe failed")
	}
	runtime := runtimes[0]
	return map[string]any{
		"auth":         result["auth"],
		"native_ready": runtime["native_server_startable"] == true && runtime["app_server_startable"] == true,
		"ready":        runtime["ready"] == true,
	}, nil
}

func (c *connector) consumeComputeRuntimeInput(ctx context.Context, input computeRuntimeInputRecord) error {
	if input.Payload == nil {
		return errors.New("compute runtime input has no payload")
	}

	if stringParam(input.Payload, "kind") == "external" {
		provider, runtimeInput, err := parseExternalRuntimeInput(input.Payload)
		if err != nil {
			return err
		}
		runtimeInput.command, err = c.computeRuntimeCommand(provider)
		if err != nil {
			return err
		}
		runtimeInput.workspace, err = c.externalRuntimeWorkspace(provider, runtimeInput.sessionID)
		if err != nil {
			return err
		}
		return c.externalRuntimeState.enqueueInputBatch(provider, runtimeInput)
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

// Compute images own their provider binaries. The Server selects the product
// provider but must not persist or send a host-native command path. Resolve the
// exact command from this runtime's private inventory and fail closed unless it
// identifies one unambiguous target.
func (c *connector) computeRuntimeCommand(provider string) (string, error) {
	if !computeExternalRuntimeProvider(provider) {
		return "", errors.New("compute runtime provider is unsupported")
	}
	if c.runtimeInventory == nil {
		return "", errors.New("compute runtime inventory is unavailable")
	}
	command := ""
	for _, runtime := range c.runtimeInventory.snapshot() {
		if stringParam(runtime, "kind") != "external" || stringParam(runtime, "provider") != provider {
			continue
		}
		candidate := strings.TrimSpace(stringParam(runtime, "identity_material"))
		if candidate == "" || command != "" {
			return "", errors.New("compute runtime provider target is ambiguous")
		}
		command = candidate
	}
	if command == "" {
		return "", errors.New("compute runtime provider target is unavailable")
	}
	return command, nil
}

func computeExternalRuntimeProvider(provider string) bool {
	return provider == "codex" || provider == "pi" || provider == "claude"
}
