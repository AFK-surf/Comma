package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

type kimiRuntimeImplementation struct {
	connector  *connector
	activityMu sync.RWMutex
	mu         sync.Mutex
	sessions   map[string]*kimiRuntimeSlot
}

func (i *kimiRuntimeImplementation) beginActivity() func() {
	i.activityMu.RLock()
	return i.activityMu.RUnlock
}

type kimiRuntimeSlot struct {
	mu            sync.Mutex
	session       *kimiRuntimeSession
	recoveryInput externalRuntimeInput
}

type kimiRuntimeSession struct {
	implementation *kimiRuntimeImplementation
	connector      *connector
	sessionID      string
	nativeID       string
	token          string
	runtimeContext string
	model          string
	thinking       string
	baseURL        string
	authToken      string
	cmd            *exec.Cmd
	ws             *websocket.Conn
	done           chan struct{}
	mu             sync.RWMutex
	wsWriteMu      sync.Mutex
	messageStream  strings.Builder
	thinkingStream strings.Builder
	normal         bool
	abandoned      bool
	dispatchID     string
	executionID    string
	workState      string
}

func newKimiRuntimeImplementation(c *connector) *kimiRuntimeImplementation {
	return &kimiRuntimeImplementation{connector: c, sessions: map[string]*kimiRuntimeSlot{}}
}

func (i *kimiRuntimeImplementation) Close() {
	i.mu.Lock()
	slots := make([]*kimiRuntimeSlot, 0, len(i.sessions))
	for _, slot := range i.sessions {
		slots = append(slots, slot)
	}
	i.mu.Unlock()
	for _, slot := range slots {
		slot.mu.Lock()
		session := slot.session
		slot.mu.Unlock()
		if session != nil {
			session.stop()
			<-session.done
		}
	}
}

func (i *kimiRuntimeImplementation) Restore(input externalRuntimeInput) error {
	defer i.beginActivity()()
	if stringParam(input.payload, "session_id") == "" {
		return errors.New("persisted kimi runtime session has no session id")
	}
	slot := i.sessionSlot(input.sessionID)
	slot.mu.Lock()
	slot.recoveryInput = input
	slot.mu.Unlock()
	return nil
}

func (i *kimiRuntimeImplementation) Send(ctx context.Context, input externalRuntimeInput) (map[string]any, string, error) {
	defer i.beginActivity()()
	slot := i.sessionSlot(input.sessionID)
	slot.mu.Lock()
	defer slot.mu.Unlock()
	session := slot.session
	if session == nil || !session.running() {
		var err error
		session, err = i.startSession(ctx, input)
		if err != nil {
			return nil, "", err
		}
		slot.session = session
	}
	executionID, err := session.beginDispatch(input.dispatchID, input.token, input.executionID)
	if err != nil {
		return nil, "", err
	}
	input.executionID = executionID
	i.connector.registerRuntimeRoute(session.runtimeContext, input.token)
	slot.recoveryInput = externalRuntimeRecoveryInput(input, "session_id", session.nativeID)
	if err := i.connector.watchExternalRuntime("kimi", slot.recoveryInput); err != nil {
		return nil, "", err
	}

	if err := session.prompt(ctx, input.text()); err != nil {
		return nil, "", err
	}

	return map[string]any{"session_id": session.nativeID}, executionID, nil
}

func (i *kimiRuntimeImplementation) ReplayObservations() {
	i.mu.Lock()
	slots := make([]*kimiRuntimeSlot, 0, len(i.sessions))
	for _, slot := range i.sessions {
		slots = append(slots, slot)
	}
	i.mu.Unlock()
	for _, slot := range slots {
		slot.mu.Lock()
		if slot.session != nil {
			slot.session.replayObservation()
		}
		slot.mu.Unlock()
	}
}

func (i *kimiRuntimeImplementation) Check(ctx context.Context, sessionID string) error {
	defer i.beginActivity()()
	i.mu.Lock()
	slot := i.sessions[sessionID]
	i.mu.Unlock()
	if slot == nil {
		return nil
	}
	if !slot.mu.TryLock() {
		return nil
	}
	defer slot.mu.Unlock()
	if slot.session != nil && slot.session.running() {
		probeCtx, cancel := context.WithTimeout(ctx, externalRuntimeProbeTimeout)
		state, err := slot.session.api(probeCtx, http.MethodGet, "/api/v1/sessions/"+url.PathEscape(slot.session.nativeID), nil)
		cancel()
		if err == nil && stringParam(state, "id") == slot.session.nativeID {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if err := stopExternalRuntime(ctx, slot.session.stop, slot.session.done); err != nil {
			return err
		}
	}
	if slot.session != nil && slot.session.stoppedNormally() {
		return nil
	}
	if !i.connector.externalRuntimeState.watched("kimi", sessionID) {
		return nil
	}
	if slot.recoveryInput.command == "" {
		return nil
	}
	session, err := i.startSession(ctx, slot.recoveryInput)
	if err != nil {
		return err
	}
	slot.session = session
	if err := session.prompt(ctx, externalRuntimeRecoveryMessage); err != nil {
		slot.session = nil
		session.stop()
		return err
	}
	if err := i.connector.externalRuntimeState.markExecutionRecovered(
		"kimi", sessionID, slot.recoveryInput.token,
	); err != nil {
		return err
	}
	// Report recovery only after the native session accepts the recovery prompt.
	return nil
}

func (i *kimiRuntimeImplementation) sessionSlot(sessionID string) *kimiRuntimeSlot {
	i.mu.Lock()
	defer i.mu.Unlock()
	slot := i.sessions[sessionID]
	if slot == nil {
		slot = &kimiRuntimeSlot{}
		i.sessions[sessionID] = slot
	}
	return slot
}

func (i *kimiRuntimeImplementation) startSession(ctx context.Context, input externalRuntimeInput) (*kimiRuntimeSession, error) {
	command := input.command
	if command == "" {
		return nil, errors.New("agent_runtime_input requires discovered kimi command")
	}
	bridgeURL, err := i.connector.ensureRuntimeBridge()
	if err != nil {
		return nil, err
	}
	cliDir, err := i.connector.ensureSalixCLI("kimi")
	if err != nil {
		return nil, err
	}
	runtimeContext, err := newRuntimeContext()
	if err != nil {
		return nil, err
	}
	sessionID := input.sessionID
	kimiHome := filepath.Join(i.connector.runtimeStateRoot(), "external-runtime", "kimi", sessionID)
	if err := prepareKimiHome(
		kimiHome,
		sourceKimiHome(command),
		externalRuntimeSystemPrompt(input.systemPrompt),
	); err != nil {
		return nil, err
	}
	port, err := reserveLocalPort()
	if err != nil {
		return nil, err
	}

	cmd := exec.Command(command, "web", "--no-open", "--port", strconv.Itoa(port), "--log-level", "error")
	cmd.Dir = input.workspace
	cmd.Env = execEnv(map[string]any{
		"KIMI_CODE_HOME":         kimiHome,
		"PATH":                   runtimeCommandPath(command, cliDir),
		"SALIX_CONNECT_URL":      bridgeURL,
		"SALIX_CLI":              filepath.Join(cliDir, "salix"),
		"SALIX_ENV_ROOT":         i.connector.root,
		"SALIX_RUNTIME_CONTEXT":  runtimeContext,
		"KIMI_DISABLE_TELEMETRY": "1",
	})
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go func() { _, _ = io.Copy(io.Discard, stdout) }()
	go func() { _, _ = io.Copy(io.Discard, stderr) }()

	session := &kimiRuntimeSession{
		implementation: i,
		connector:      i.connector,
		sessionID:      sessionID,
		token:          input.token,
		runtimeContext: runtimeContext,
		baseURL:        "http://127.0.0.1:" + strconv.Itoa(port),
		cmd:            cmd,
		done:           make(chan struct{}),
		dispatchID:     input.dispatchID,
		executionID:    input.executionID,
		thinking:       input.reasoningEffort,
	}
	if input.executionID != "" {
		session.workState = "starting"
	}
	if err := session.waitReady(ctx, filepath.Join(kimiHome, "server.token")); err != nil {
		session.stop()
		return nil, err
	}
	auth, err := session.api(ctx, http.MethodGet, "/api/v1/auth", nil)
	if err != nil {
		session.stop()
		return nil, err
	}
	session.model = defaultString(input.model, stringParam(auth, "default_model"))
	if session.model == "" {
		session.stop()
		return nil, errors.New("kimi auth snapshot returned no default model")
	}

	resumeID := stringParam(input.payload, "session_id")
	if resumeID == "" {
		created, err := session.api(ctx, http.MethodPost, "/api/v1/sessions", map[string]any{
			"metadata": map[string]any{"cwd": input.workspace},
			"agent_config": compactMap(map[string]any{
				"model":           session.model,
				"thinking":        input.reasoningEffort,
				"permission_mode": "yolo",
			}),
		})
		if err != nil {
			session.stop()
			return nil, err
		}
		resumeID = stringParam(created, "id")
		if resumeID == "" {
			session.stop()
			return nil, errors.New("kimi create session returned no session id")
		}
	} else {
		resumed, err := session.api(ctx, http.MethodGet, "/api/v1/sessions/"+url.PathEscape(resumeID), nil)
		if err != nil {
			session.stop()
			return nil, fmt.Errorf("resume kimi session %q: %w", resumeID, err)
		}
		if stringParam(resumed, "id") != resumeID {
			session.stop()
			return nil, fmt.Errorf("kimi resumed session %q, want %q", stringParam(resumed, "id"), resumeID)
		}
	}
	session.nativeID = resumeID
	if err := session.subscribe(ctx); err != nil {
		session.stop()
		return nil, err
	}
	i.connector.registerRuntimeRoute(runtimeContext, session.token)
	go session.wait()
	return session, nil
}

func (s *kimiRuntimeSession) waitReady(ctx context.Context, tokenPath string) error {
	deadline := time.Now().Add(15 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if raw, err := os.ReadFile(tokenPath); err == nil && strings.TrimSpace(string(raw)) != "" {
			s.authToken = strings.TrimSpace(string(raw))
			probeCtx, cancel := context.WithTimeout(ctx, time.Second)
			request, _ := http.NewRequestWithContext(probeCtx, http.MethodGet, s.baseURL+"/api/v1/healthz", nil)
			request.Header.Set("Authorization", "Bearer "+s.authToken)
			response, err := runtimeHTTPClient.Do(request)
			cancel()
			if err == nil {
				_ = response.Body.Close()
				if response.StatusCode < 400 {
					return nil
				}
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	return errors.New("kimi server did not become ready")
}

func (s *kimiRuntimeSession) api(ctx context.Context, method, path string, body map[string]any) (map[string]any, error) {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(raw)
	}
	request, err := http.NewRequestWithContext(ctx, method, s.baseURL+path, reader)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Authorization", "Bearer "+s.authToken)
	if body != nil {
		request.Header.Set("Content-Type", "application/json")
	}
	response, err := runtimeHTTPClient.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	var envelope map[string]any
	if err := json.NewDecoder(io.LimitReader(response.Body, maxFile)).Decode(&envelope); err != nil {
		return nil, err
	}
	if response.StatusCode >= 400 || intFromAny(envelope["code"], -1) != 0 {
		return nil, fmt.Errorf("kimi API %s %s: %s", method, path, defaultString(stringParam(envelope, "msg"), response.Status))
	}
	return mapParam(envelope, "data"), nil
}

func (s *kimiRuntimeSession) prompt(ctx context.Context, message string) error {
	prompt, err := s.api(ctx, http.MethodPost, "/api/v1/sessions/"+url.PathEscape(s.nativeID)+"/prompts", compactMap(map[string]any{
		"content":         []any{map[string]any{"type": "text", "text": message}},
		"model":           s.model,
		"thinking":        s.thinking,
		"permission_mode": "yolo",
	}))
	if err != nil {
		return err
	}
	switch stringParam(prompt, "status") {
	case "running":
		return nil
	case "queued":
		promptID := stringParam(prompt, "prompt_id")
		if promptID == "" {
			return errors.New("kimi queued prompt returned no prompt id")
		}
		_, err := s.api(ctx, http.MethodPost, "/api/v1/sessions/"+url.PathEscape(s.nativeID)+"/prompts:steer", map[string]any{
			"prompt_ids": []any{promptID},
		})
		return err
	default:
		return fmt.Errorf("kimi status %q", stringParam(prompt, "status"))
	}
}

func (s *kimiRuntimeSession) subscribe(ctx context.Context) error {
	header := http.Header{}
	header.Set("Authorization", "Bearer "+s.authToken)
	wsURL := "ws" + strings.TrimPrefix(s.baseURL, "http") + "/api/v1/ws"
	ws, _, err := websocket.DefaultDialer.DialContext(ctx, wsURL, header)
	if err != nil {
		return err
	}
	s.ws = ws
	if err := s.writeWS(map[string]any{
		"type": "client_hello",
		"id":   "salix-hello",
		"payload": map[string]any{
			"client_id":     "salix-" + s.runtimeContext,
			"subscriptions": []any{s.nativeID},
		},
	}); err != nil {
		_ = ws.Close()
		return err
	}
	go s.readEvents()
	return nil
}

func (s *kimiRuntimeSession) readEvents() {
	defer func() {
		for _, event := range s.flushStandardStreams() {
			dispatchID, executionID, workState := s.observeEvent(event)
			s.connector.forwardRuntimeEvent(
				s.currentToken(),
				attachRuntimeIdentity(event, dispatchID, executionID, workState),
			)
		}
		s.stop()
	}()
	for {
		var event map[string]any
		if err := s.ws.ReadJSON(&event); err != nil {
			return
		}
		if stringParam(event, "type") == "ping" {
			if err := s.writeWS(map[string]any{"type": "pong", "payload": mapParam(event, "payload")}); err != nil {
				return
			}
			continue
		}
		if stringParam(event, "session_id") != "" && stringParam(event, "session_id") != s.nativeID {
			continue
		}
		for _, event := range s.standardEvents(event) {
			dispatchID, executionID, workState := s.observeEvent(event)
			transition := ""
			if workState == externalRuntimeExecutionRunning {
				transition = externalRuntimeExecutionRunning
			} else if workState == externalRuntimeExecutionSettled || workState == "failed" {
				transition = externalRuntimeExecutionSettled
			}
			s.connector.forwardRuntimeExecutionEvent(
				"kimi",
				s.sessionID,
				s.currentToken(),
				attachRuntimeIdentity(event, dispatchID, executionID, workState),
				transition,
			)
		}
	}
}

func (s *kimiRuntimeSession) standardEvents(native map[string]any) []map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	payload := mapParam(native, "payload")
	switch stringParam(native, "type") {
	case "assistant.delta":
		s.messageStream.WriteString(stringParam(payload, "delta"))
		return nil
	case "thinking.delta":
		s.thinkingStream.WriteString(stringParam(payload, "delta"))
		return nil
	default:
		events := s.flushStandardStreamsLocked()
		if event := kimiStandardEvent(native); event != nil {
			events = append(events, event)
		}
		return events
	}
}

func (s *kimiRuntimeSession) flushStandardStreams() []map[string]any {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.flushStandardStreamsLocked()
}

func (s *kimiRuntimeSession) flushStandardStreamsLocked() []map[string]any {
	events := []map[string]any{}
	if content := s.thinkingStream.String(); content != "" {
		event := standardRuntimeEvent("kimi", "thinking", "thinking.delta")
		event["content"] = content
		events = append(events, event)
		s.thinkingStream.Reset()
	}
	if content := s.messageStream.String(); content != "" {
		event := standardRuntimeEvent("kimi", "message", "assistant.delta")
		event["role"] = "assistant"
		event["content"] = content
		events = append(events, event)
		s.messageStream.Reset()
	}
	return events
}

func (s *kimiRuntimeSession) writeWS(message map[string]any) error {
	s.wsWriteMu.Lock()
	defer s.wsWriteMu.Unlock()
	return s.ws.WriteJSON(message)
}

func (s *kimiRuntimeSession) wait() {
	err := s.cmd.Wait()
	dispatchID, executionID, workState := s.observeExit()
	s.mu.Lock()
	// An unfinished turn is not a normal stop, even after a zero exit.
	s.normal = err == nil && workState != "failed"
	s.mu.Unlock()
	defer close(s.done)
	if s.ws != nil {
		_ = s.ws.Close()
	}
	s.connector.removeRuntimeRoute(s.runtimeContext)
	// A budget stop has already announced recovery_exhausted.
	if s.wasAbandoned() {
		return
	}
	if s.stoppedNormally() {
		if !s.implementation.forgetIfCurrent(s) {
			return
		}
		event := standardRuntimeEvent("kimi", "status", "runtime_stopped")
		event["state"] = "stopped"
		s.connector.forwardRuntimeEvent(s.currentToken(), event)
		return
	}
	reason := "kimi server exited"
	if err != nil {
		reason += ": " + err.Error()
	}
	s.connector.forwardRuntimeExecutionEvent("kimi", s.sessionID, s.currentToken(), attachRuntimeIdentity(map[string]any{
		"type":     "error",
		"provider": "kimi",
		"message":  reason,
	}, dispatchID, executionID, workState), externalRuntimeExecutionInterrupted)
}

func (i *kimiRuntimeImplementation) forgetIfCurrent(session *kimiRuntimeSession) bool {
	i.mu.Lock()
	slot := i.sessions[session.sessionID]
	i.mu.Unlock()
	if slot == nil {
		return false
	}
	slot.mu.Lock()
	defer slot.mu.Unlock()
	if slot.session != session {
		return false
	}
	slot.session = nil
	slot.recoveryInput = externalRuntimeInput{}
	i.connector.forgetExternalRuntime("kimi", session.sessionID)
	return true
}

// AbandonRecovery explicitly stops one execution whose recovery failure budget
// is exhausted. The durable obligation is
// removed first, gated on the sampled execution fence, so a replacement
// execution that started after the budget tripped is never the one
// abandoned, and a late exit observation from the stopped native session
// cannot re-arm anything. The terminal observations are then announced from
// the durable record — including when no native process is alive — and any
// detached native process is stopped. Pending inbox rows survive and
// redeliver into a fresh native session on the next delivery pass.
func (i *kimiRuntimeImplementation) AbandonRecovery(record externalRuntimeRecoveryRecord, reason string) bool {
	i.mu.Lock()
	slot := i.sessions[record.SessionID]
	i.mu.Unlock()
	if slot == nil {
		return i.connector.abandonRuntimeObligation(record, reason)
	}
	if !slot.mu.TryLock() {
		return false
	}
	_, removed, err := i.connector.externalRuntimeState.forgetExecution(record)
	if err != nil {
		slot.mu.Unlock()
		return false
	}
	if !removed {
		slot.mu.Unlock()
		return true
	}
	session := slot.session
	slot.session = nil
	slot.recoveryInput = externalRuntimeInput{}
	slot.mu.Unlock()
	if session != nil {
		// Stop before announcing. The abandoned mark suppresses the exit
		// path's echo of this deliberate kill; waiting for the exit path
		// bounds the concurrent self-death case — an echo enqueued before
		// the mark lands before the recovery_exhausted announcement and
		// loses the watermark race. On timeout the announcement proceeds;
		// a straggler exit still observes the mark and stays silent.
		session.markAbandoned()
		session.stop()
		select {
		case <-session.done:
		case <-time.After(externalRuntimeAbandonStopWait):
		}
	}
	i.connector.announceAbandonedRecovery(record, reason)
	return true
}

func (s *kimiRuntimeSession) running() bool {
	select {
	case <-s.done:
		return false
	default:
		return true
	}
}

func (s *kimiRuntimeSession) stoppedNormally() bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.normal
}

// markAbandoned records that the recovery budget deliberately stopped this
// session: the exit path must not re-announce the same execution as a
// generic runtime failure after the recovery_exhausted conclusion.
func (s *kimiRuntimeSession) markAbandoned() {
	s.mu.Lock()
	s.abandoned = true
	s.mu.Unlock()
}

func (s *kimiRuntimeSession) wasAbandoned() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.abandoned
}

func (s *kimiRuntimeSession) stop() {
	if s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
	}
}

func (s *kimiRuntimeSession) setToken(token string) {
	s.mu.Lock()
	s.token = token
	s.mu.Unlock()
}

func (s *kimiRuntimeSession) beginDispatch(dispatchID, token, preparedExecutionID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	executionID := s.executionID
	active := s.workState == "running" && executionID != ""
	if preparedExecutionID == "" {
		return "", errors.New("prepared execution id is required")
	}
	if active && executionID != preparedExecutionID {
		return "", errors.New("prepared execution id changed during active kimi execution")
	}
	if (s.workState == "settled" || s.workState == "failed") && executionID == preparedExecutionID {
		return "", errors.New("settled kimi execution cannot be restarted")
	}
	executionID = preparedExecutionID
	s.token = token
	s.dispatchID = dispatchID
	s.executionID = executionID
	if !active {
		s.workState = "starting"
	}
	return executionID, nil
}

func (s *kimiRuntimeSession) observeEvent(event map[string]any) (string, string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	workState := ""
	name := stringParam(event, "name")
	state := strings.ToLower(stringParam(event, "state"))
	switch name {
	case "turn.started":
		s.workState = "running"
		workState = "running"
	case "turn.ended":
		if s.workState == "running" {
			if state == "failed" || state == "error" {
				s.workState = "failed"
				workState = "failed"
			} else {
				s.workState = "settled"
				workState = "settled"
			}
		}
	case "agent.status.updated":
		if state == "running" || state == "busy" {
			s.workState = "running"
			workState = "running"
		}
	default:
		if (event["type"] == "message" || event["type"] == "thinking" || event["type"] == "operation") &&
			s.workState == "running" {
			workState = "running"
		}
	}
	return s.dispatchID, s.executionID, workState
}

func (s *kimiRuntimeSession) observeExit() (string, string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	workState := ""
	if s.workState == "starting" || s.workState == "running" {
		s.workState = "failed"
		workState = "failed"
	}
	return s.dispatchID, s.executionID, workState
}

func (s *kimiRuntimeSession) replayObservation() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.workState == "running" || s.workState == "settled" || s.workState == "failed" {
		event := standardRuntimeEvent("kimi", "status", "connector/reconnected")
		event["state"] = s.workState
		s.connector.forwardRuntimeEvent(
			s.token,
			attachRuntimeIdentity(event, s.dispatchID, s.executionID, s.workState),
		)
	}
}

func (s *kimiRuntimeSession) currentToken() string {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.token
}

func kimiStandardEvent(native map[string]any) map[string]any {
	payload := mapParam(native, "payload")
	name := stringParam(native, "type")

	switch name {
	case "prompt.submitted", "prompt.completed", "tool.call.started", "shell.started", "tool.result", "subagent.spawned", "subagent.started", "subagent.suspended", "subagent.completed", "subagent.failed", "background.task.started", "background.task.terminated":
		event := standardRuntimeEvent("kimi", "operation", defaultString(stringParam(payload, "name"), name))
		event["operation_id"] = kimiOperationID(payload)
		event["status"] = name
		if input := mapParam(payload, "args"); len(input) > 0 {
			event["input"] = input
		}
		if output := payload["output"]; output != nil {
			event["output"] = output
		}
		if usage := mapParam(payload, "usage"); len(usage) > 0 {
			event["usage"] = usage
		}
		return event

	case "error":
		event := standardRuntimeEvent("kimi", "error", name)
		event["code"] = stringParam(payload, "code")
		event["message"] = stringParam(payload, "message")
		return event

	case "agent.status.updated":
		if usage := mapParam(payload, "usage"); len(usage) > 0 {
			event := standardRuntimeEvent("kimi", "usage", name)
			event["usage"] = usage
			return event
		}
		event := standardRuntimeEvent("kimi", "status", name)
		event["state"] = defaultString(stringParam(payload, "status"), name)
		return event

	case "warning", "event.session.created", "event.session.status_changed", "session.meta.updated", "turn.started", "turn.ended", "turn.step.started", "turn.step.completed", "turn.step.retrying", "turn.step.interrupted", "compaction.started", "compaction.blocked", "compaction.cancelled", "compaction.completed":
		event := standardRuntimeEvent("kimi", "status", name)
		event["state"] = defaultString(stringParam(payload, "status"), defaultString(stringParam(payload, "reason"), name))
		if usage := mapParam(payload, "usage"); len(usage) > 0 {
			event["usage"] = usage
		}
		return event
	default:
		return nil
	}
}

func kimiOperationID(payload map[string]any) string {
	for _, key := range []string{"toolCallId", "promptId", "commandId", "taskId", "subagentId", "id"} {
		if id := stringParam(payload, key); id != "" {
			return id
		}
	}
	info := mapParam(payload, "info")
	for _, key := range []string{"id", "taskId"} {
		if id := stringParam(info, key); id != "" {
			return id
		}
	}
	return ""
}

func prepareKimiHome(target, source, systemPrompt string) error {
	if err := os.MkdirAll(target, 0o700); err != nil {
		return err
	}
	for _, name := range []string{"config.toml", "credentials", "skills", "plugins"} {
		sourcePath := filepath.Join(source, name)
		if _, err := os.Stat(sourcePath); err != nil {
			continue
		}
		targetPath := filepath.Join(target, name)
		if _, err := os.Lstat(targetPath); err == nil {
			continue
		}
		if err := os.Symlink(sourcePath, targetPath); err != nil {
			return err
		}
	}
	return writeKimiAgents(
		filepath.Join(target, "AGENTS.md"),
		filepath.Join(source, "AGENTS.md"),
		systemPrompt,
	)
}

func writeKimiAgents(target, source, systemPrompt string) error {
	parts := []string{}
	if raw, err := os.ReadFile(source); err == nil {
		if content := strings.TrimSpace(string(raw)); content != "" {
			parts = append(parts, content)
		}
	}
	if prompt := strings.TrimSpace(systemPrompt); prompt != "" {
		parts = append(parts, prompt)
	}
	return os.WriteFile(target, []byte(strings.Join(parts, "\n\n")+"\n"), 0o600)
}

func sourceKimiHome(command string) string {
	if home := strings.TrimSpace(os.Getenv("KIMI_CODE_HOME")); home != "" {
		return home
	}
	if filepath.Base(filepath.Dir(command)) == "bin" {
		candidate := filepath.Dir(filepath.Dir(command))
		if filepath.Base(candidate) == ".kimi-code" {
			return candidate
		}
	}
	home, _ := os.UserHomeDir()
	for _, candidate := range []string{filepath.Join(home, ".kimi-code"), filepath.Join(home, ".kimi")} {
		if info, err := os.Stat(candidate); err == nil && info.IsDir() {
			return candidate
		}
	}
	return filepath.Join(home, ".kimi-code")
}

func reserveLocalPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()
	return listener.Addr().(*net.TCPAddr).Port, nil
}

var runtimeHTTPClient = &http.Client{Timeout: 60 * time.Second}

func compactMap(values map[string]any) map[string]any {
	for key, value := range values {
		if text, ok := value.(string); ok && text == "" {
			delete(values, key)
		}
	}
	return values
}
