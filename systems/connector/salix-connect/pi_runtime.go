package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type piRuntimeImplementation struct {
	connector        *connector
	activityMu       sync.RWMutex
	activityRevision atomic.Uint64
	mu               sync.Mutex
	sessions         map[string]*piRuntimeSlot
	sessionOrder     []string
	sessionIndex     map[string]int
	authGeneration   *piAuthGeneration
}

func (i *piRuntimeImplementation) beginActivity() func() {
	i.activityMu.RLock()
	i.activityRevision.Add(1)
	return i.activityMu.RUnlock
}

type piAuthGeneration struct {
	id   uint64
	stop chan struct{}
	wait sync.WaitGroup
}

type piRuntimeSlot struct {
	mu            sync.Mutex
	session       *piRuntimeSession
	recoveryInput externalRuntimeInput
}

type piRuntimeSession struct {
	implementation *piRuntimeImplementation
	connector      *connector
	sessionID      string
	nativeID       string
	token          string
	runtimeContext string
	cmd            *exec.Cmd
	stdin          io.WriteCloser
	done           chan struct{}
	authGeneration *piAuthGeneration

	writeMu     sync.Mutex
	mu          sync.Mutex
	nextID      int
	pending     map[string]chan map[string]any
	normal      bool
	abandoned   bool
	dispatchID  string
	executionID string
	workState   string
}

func newPiRuntimeImplementation(c *connector) *piRuntimeImplementation {
	return &piRuntimeImplementation{connector: c, sessions: map[string]*piRuntimeSlot{}, sessionIndex: map[string]int{}, authGeneration: &piAuthGeneration{id: 1, stop: make(chan struct{})}}
}

func writeManagedPiProjection(directory, model string, credential *managedRuntimeCredential) error {
	if credential == nil || model == "" {
		return errSubscriptionUnavailable
	}
	if err := os.MkdirAll(directory, 0o700); err != nil {
		return err
	}
	provider := map[string]any{
		"baseUrl": credential.endpoint,
		"api":     strings.ReplaceAll(credential.protocol, "_", "-"),
		"apiKey":  "$" + managedRuntimeAPIKeyEnv,
		"models":  []map[string]any{{"id": model}},
	}
	if credential.authScheme == "bearer" {
		provider["authHeader"] = true
	}
	models, err := json.Marshal(map[string]any{"providers": map[string]any{"salix-managed": provider}})
	if err != nil {
		return err
	}
	settings, err := json.Marshal(map[string]any{"defaultProvider": "salix-managed", "defaultModel": model})
	if err != nil {
		return err
	}
	for name, data := range map[string][]byte{"models.json": models, "settings.json": settings} {
		path := filepath.Join(directory, name)
		stage := path + ".new"
		if err := os.WriteFile(stage, data, 0o600); err != nil {
			return err
		}
		if err := os.Rename(stage, path); err != nil {
			return err
		}
	}
	return nil
}

func (i *piRuntimeImplementation) retireAuthGeneration() <-chan struct{} {
	i.mu.Lock()
	retired := i.authGeneration
	i.authGeneration = &piAuthGeneration{id: retired.id + 1, stop: make(chan struct{})}
	close(retired.stop)
	i.mu.Unlock()
	exited := make(chan struct{})
	go func() { retired.wait.Wait(); close(exited) }()
	return exited
}

func (i *piRuntimeImplementation) Close() {
	i.mu.Lock()
	slots := make([]*piRuntimeSlot, 0, len(i.sessions))
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

func (i *piRuntimeImplementation) Restore(input externalRuntimeInput) error {
	defer i.beginActivity()()
	if stringParam(input.payload, "session_id") == "" {
		return errors.New("persisted pi runtime session has no session id")
	}
	slot := i.sessionSlot(input.sessionID)
	slot.mu.Lock()
	slot.recoveryInput = input
	slot.mu.Unlock()
	return nil
}

func (i *piRuntimeImplementation) Send(ctx context.Context, input externalRuntimeInput) (map[string]any, string, error) {
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
	if err := i.connector.watchExternalRuntime("pi", slot.recoveryInput); err != nil {
		return nil, "", err
	}

	if err := session.prompt(ctx, input.text()); err != nil {
		return nil, "", err
	}
	return map[string]any{"session_id": session.nativeID}, executionID, nil
}

func (i *piRuntimeImplementation) ReplayObservations() {
	i.mu.Lock()
	slots := make([]*piRuntimeSlot, 0, len(i.sessions))
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

func (i *piRuntimeImplementation) Check(ctx context.Context, sessionID string) error {
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
		state, err := slot.session.rpc(probeCtx, map[string]any{"type": "get_state"})
		cancel()
		if err == nil && stringParam(mapParam(state, "data"), "sessionId") == slot.session.nativeID {
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
	if !i.connector.externalRuntimeState.watched("pi", sessionID) {
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
		"pi", sessionID, slot.recoveryInput.token,
	); err != nil {
		return err
	}
	// Report recovery only after the native session accepts the recovery prompt.
	return nil
}

func (i *piRuntimeImplementation) sessionSlot(sessionID string) *piRuntimeSlot {
	i.mu.Lock()
	defer i.mu.Unlock()
	slot := i.sessions[sessionID]
	if slot == nil {
		slot = &piRuntimeSlot{}
		i.sessions[sessionID] = slot
		appendRuntimeSessionID(&i.sessionOrder, &i.sessionIndex, sessionID)
	}
	return slot
}

func (i *piRuntimeImplementation) startSession(ctx context.Context, input externalRuntimeInput) (*piRuntimeSession, error) {
	command := input.command
	if command == "" {
		return nil, errors.New("agent_runtime_input requires discovered pi command")
	}
	bridgeURL, err := i.connector.ensureRuntimeBridge()
	if err != nil {
		return nil, err
	}
	cliDir, err := i.connector.ensureSalixCLI("pi")
	if err != nil {
		return nil, err
	}
	runtimeContext, err := newRuntimeContext()
	if err != nil {
		return nil, err
	}
	sessionID := input.sessionID
	sessionDir := filepath.Join(i.connector.runtimeStateRoot(), "external-runtime", "pi", sessionID)
	if err := os.MkdirAll(sessionDir, 0o700); err != nil {
		return nil, err
	}

	args := []string{"--mode", "rpc", "--session-dir", sessionDir}
	resumeID := stringParam(input.payload, "session_id")
	if boolParam(input.payload, "require_native_resume") && resumeID == "" {
		return nil, errors.New("migrated Pi Session has no native identity")
	}
	if resumeID != "" {
		resume := resumeID
		if boolParam(input.payload, "require_native_resume") {
			resume = stringParam(input.payload, "session_file")
			if !filepath.IsAbs(resume) || filepath.Dir(resume) != sessionDir {
				return nil, errors.New("migrated Pi Session has no exact native file")
			}
			if info, err := os.Stat(resume); err != nil || !info.Mode().IsRegular() {
				return nil, errors.New("migrated Pi Session file is unavailable")
			}
			file, err := os.Open(resume)
			if err != nil {
				return nil, err
			}
			var header map[string]any
			err = json.NewDecoder(io.LimitReader(file, 1<<20)).Decode(&header)
			file.Close()
			if err != nil || stringParam(header, "type") != "session" || stringParam(header, "id") != resumeID {
				return nil, errors.New("migrated Pi Session header is missing or changed; refusing a fresh Session")
			}
		}
		args = append(args, "--session", resume)
	}
	managed := i.connector.managedRuntimeCredential("pi", command)
	managedDir := ""
	if managed != nil {
		if input.model == "" {
			return nil, errors.New("managed pi runtime requires a model id")
		}
		managedDir = filepath.Join(i.connector.runtimeStateRoot(), "external-runtime", "managed-pi", sessionID)
		if err := writeManagedPiProjection(managedDir, input.model, managed); err != nil {
			return nil, err
		}
		args = append(args, "--provider", "salix-managed", "--model", input.model)
	} else if input.modelProvider != "" {
		args = append(args, "--provider", input.modelProvider)
		if input.model != "" {
			args = append(args, "--model", input.model)
		}
	} else if input.model != "" {
		args = append(args, "--model", input.model)
	}
	if input.reasoningEffort != "" {
		args = append(args, "--thinking", input.reasoningEffort)
	}
	// Pi resolves an existing --append-system-prompt path to its full contents.
	// A single inline argument can exceed Linux MAX_ARG_STRLEN even when the
	// total environment fits. Keep the private file for the native lifetime
	// because Pi may reload its resources after startup.
	promptFile, err := os.CreateTemp(sessionDir, "system-prompt-*.txt")
	if err != nil {
		return nil, err
	}
	promptPath := promptFile.Name()
	promptOwnedByProcess := false
	defer func() {
		if !promptOwnedByProcess {
			_ = os.Remove(promptPath)
		}
	}()
	_, writeErr := promptFile.WriteString(externalRuntimeSystemPrompt(input.systemPrompt))
	closeErr := promptFile.Close()
	if writeErr != nil {
		return nil, writeErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	args = append(args, "--append-system-prompt", promptPath)

	cmd := exec.Command(command, args...)
	cmd.Dir = input.workspace
	environment := map[string]any{
		"PATH":                  runtimeCommandPath(command, cliDir),
		"SALIX_CONNECT_URL":     bridgeURL,
		"SALIX_CLI":             filepath.Join(cliDir, "salix"),
		"SALIX_ENV_ROOT":        i.connector.root,
		"SALIX_RUNTIME_CONTEXT": runtimeContext,
	}
	if managed != nil {
		cmd.Env = runtimeAuthPiManagedExecEnv(environment, managedDir, managed.apiKey)
	} else {
		cmd.Env = execEnv(environment)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	session := &piRuntimeSession{
		implementation: i,
		connector:      i.connector,
		sessionID:      sessionID,
		token:          input.token,
		runtimeContext: runtimeContext,
		cmd:            cmd,
		stdin:          stdin,
		done:           make(chan struct{}),
		nextID:         1,
		pending:        map[string]chan map[string]any{},
		dispatchID:     input.dispatchID,
		executionID:    input.executionID,
	}
	if input.executionID != "" {
		session.workState = "starting"
	}
	// Cmd owns the copy: Wait drains output before classifying exit. WaitDelay
	// bounds inherited pipes after process exit, not a running tool's duration.
	cmd.Stdout = &piRuntimeOutput{session: session}
	cmd.Stderr = io.Discard
	cmd.WaitDelay = externalRuntimeProbeTimeout
	i.mu.Lock()
	authGeneration := i.authGeneration
	if managed != i.connector.managedRuntimeCredential("pi", command) {
		i.mu.Unlock()
		return nil, errSubscriptionUnavailable
	}
	authGeneration.wait.Add(1)
	i.mu.Unlock()
	if err := cmd.Start(); err != nil {
		authGeneration.wait.Done()
		return nil, err
	}
	session.authGeneration = authGeneration
	promptOwnedByProcess = true
	go func() {
		defer os.Remove(promptPath)
		session.wait()
	}()
	go func() {
		select {
		case <-authGeneration.stop:
			session.stop()
		case <-session.done:
		}
	}()

	state, err := session.rpc(ctx, map[string]any{"type": "get_state"})
	if err != nil {
		session.stop()
		return nil, err
	}
	nativeID := stringParam(mapParam(state, "data"), "sessionId")
	if nativeID == "" {
		session.stop()
		return nil, errors.New("pi get_state returned no session id")
	}
	if resumeID != "" && nativeID != resumeID {
		session.stop()
		return nil, fmt.Errorf("pi resumed session %q, want %q", nativeID, resumeID)
	}
	if result, err := session.rpc(ctx, map[string]any{"type": "set_auto_retry", "enabled": false}); err != nil || result["success"] != true {
		session.stop()
		return nil, defaultError(err, errors.New("pi rejected set_auto_retry"))
	}
	session.nativeID = nativeID
	i.connector.registerRuntimeRoute(runtimeContext, session.token)
	return session, nil
}

func runtimeAuthPiManagedExecEnv(raw map[string]any, directory, key string) []string {
	blocked := map[string]bool{
		"PI_CODING_AGENT_DIR": true, managedRuntimeAPIKeyEnv: true,
		"ANTHROPIC_API_KEY": true, "ANTHROPIC_AUTH_TOKEN": true,
		"OPENAI_API_KEY": true, "OPENAI_BASE_URL": true, "OPENROUTER_API_KEY": true,
		"AZURE_OPENAI_API_KEY": true, "GOOGLE_GENERATIVE_AI_API_KEY": true, "GEMINI_API_KEY": true,
		"GROQ_API_KEY": true, "MISTRAL_API_KEY": true, "XAI_API_KEY": true,
		"COHERE_API_KEY": true, "CEREBRAS_API_KEY": true, "DEEPSEEK_API_KEY": true,
		"TOGETHER_API_KEY": true, "FIREWORKS_API_KEY": true, "PERPLEXITY_API_KEY": true,
	}
	environment := execEnv(raw)
	filtered := environment[:0]
	for _, item := range environment {
		name, _, _ := strings.Cut(item, "=")
		if !blocked[name] {
			filtered = append(filtered, item)
		}
	}
	return append(filtered, "PI_CODING_AGENT_DIR="+directory, managedRuntimeAPIKeyEnv+"="+key)
}

func (s *piRuntimeSession) rpc(ctx context.Context, request map[string]any) (map[string]any, error) {
	s.mu.Lock()
	id := "salix-" + strconv.Itoa(s.nextID)
	s.nextID++
	request["id"] = id
	ch := make(chan map[string]any, 1)
	s.pending[id] = ch
	s.mu.Unlock()

	s.writeMu.Lock()
	err := json.NewEncoder(s.stdin).Encode(request)
	s.writeMu.Unlock()
	if err != nil {
		s.deletePending(id)
		return nil, err
	}

	select {
	case response, ok := <-ch:
		if !ok {
			return nil, errors.New("pi process exited")
		}
		return response, nil
	case <-ctx.Done():
		s.deletePending(id)
		return nil, ctx.Err()
	case <-time.After(60 * time.Second):
		s.deletePending(id)
		return nil, errors.New("pi command timed out")
	}
}

func (s *piRuntimeSession) prompt(ctx context.Context, message string) error {
	result, err := s.rpc(ctx, map[string]any{
		"type":              "prompt",
		"message":           message,
		"streamingBehavior": "steer",
	})
	if err != nil {
		return err
	}
	if result["success"] != true {
		return fmt.Errorf("pi: %s", defaultString(stringParam(result, "error"), "unknown error"))
	}
	return nil
}

// NativeExitSettlement: os/exec completes this writer before Wait returns.
type piRuntimeOutput struct {
	session *piRuntimeSession
	pending []byte
}

func (w *piRuntimeOutput) Write(p []byte) (int, error) {
	w.pending = append(w.pending, p...)
	for {
		line, rest, ok := bytes.Cut(w.pending, []byte{'\n'})
		if !ok {
			break
		}
		w.consume(line)
		w.pending = rest
	}
	return len(p), nil
}

func (w *piRuntimeOutput) consume(line []byte) {
	var event map[string]any
	if json.Unmarshal(line, &event) == nil {
		w.session.handleEvent(event)
	}
}

func (s *piRuntimeSession) handleEvent(event map[string]any) {
	id := stringParam(event, "id")
	if stringParam(event, "type") == "response" && id != "" {
		s.mu.Lock()
		ch := s.pending[id]
		delete(s.pending, id)
		s.mu.Unlock()
		if ch != nil {
			ch <- event
		}
		return
	}
	for _, event := range piStandardEvents(event) {
		dispatchID, executionID, workState := s.observeEvent(stringParam(event, "type"), stringParam(event, "name"))
		transition := ""
		if workState == externalRuntimeExecutionRunning {
			transition = externalRuntimeExecutionRunning
		} else if workState == externalRuntimeExecutionSettled || workState == "failed" {
			transition = externalRuntimeExecutionSettled
		}
		s.connector.forwardRuntimeExecutionEvent(
			"pi",
			s.sessionID,
			s.currentToken(),
			attachRuntimeIdentity(event, dispatchID, executionID, workState),
			transition,
		)
	}
}

func (s *piRuntimeSession) wait() {
	err := s.cmd.Wait()
	if s.authGeneration != nil {
		s.authGeneration.wait.Done()
	}
	if output, ok := s.cmd.Stdout.(*piRuntimeOutput); ok {
		output.consume(output.pending)
	}
	dispatchID, executionID, workState, settled := s.observeExit()
	s.mu.Lock()
	// An unfinished turn is not a normal stop, even after a zero exit.
	s.normal = err == nil && workState != "failed"
	s.mu.Unlock()
	defer close(s.done)
	s.closePending()
	s.connector.removeRuntimeRoute(s.runtimeContext)
	// A budget stop has already announced recovery_exhausted.
	if s.wasAbandoned() {
		return
	}
	if s.stoppedNormally() {
		if !s.implementation.forgetIfCurrent(s) {
			return
		}
		event := standardRuntimeEvent("pi", "status", "runtime_stopped")
		event["state"] = "stopped"
		s.connector.forwardRuntimeEvent(s.currentToken(), event)
		return
	}
	reason := "pi process exited"
	if err != nil {
		reason += ": " + err.Error()
	}
	event := map[string]any{
		"type":     "error",
		"provider": "pi",
		"message":  reason,
	}
	if settled {
		// Process lifetime is not execution lifetime. Preserve the exit diagnostic
		// without reporting an already-settled execution as an error. SIGKILL
		// alone does not establish whether this was an intentional replacement.
		// Settlement state is unchanged; this only changes the unscoped
		// observation after settlement.
		event = standardRuntimeEvent("pi", "status", "runtime_stopped")
		event["state"] = "stopped"
		logf("pi runtime stopped after settlement session=%s: %v", s.sessionID, err)
	}
	s.connector.forwardRuntimeExecutionEvent("pi", s.sessionID, s.currentToken(), attachRuntimeIdentity(event,
		dispatchID, executionID, workState), externalRuntimeExecutionInterrupted)
}

func (i *piRuntimeImplementation) forgetIfCurrent(session *piRuntimeSession) bool {
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
	i.connector.forgetExternalRuntime("pi", session.sessionID)
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
func (i *piRuntimeImplementation) AbandonRecovery(record externalRuntimeRecoveryRecord, reason string) bool {
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

func (s *piRuntimeSession) closePending() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, ch := range s.pending {
		delete(s.pending, id)
		close(ch)
	}
}

func (s *piRuntimeSession) running() bool {
	select {
	case <-s.done:
		return false
	default:
		return true
	}
}

func (s *piRuntimeSession) stoppedNormally() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.normal
}

// markAbandoned records that the recovery budget deliberately stopped this
// session: the exit path must not re-announce the same execution as a
// generic runtime failure after the recovery_exhausted conclusion.
func (s *piRuntimeSession) markAbandoned() {
	s.mu.Lock()
	s.abandoned = true
	s.mu.Unlock()
}

func (s *piRuntimeSession) wasAbandoned() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.abandoned
}

func (s *piRuntimeSession) stop() {
	if s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
	}
}

func (s *piRuntimeSession) deletePending(id string) {
	s.mu.Lock()
	delete(s.pending, id)
	s.mu.Unlock()
}

func (s *piRuntimeSession) setToken(token string) {
	s.mu.Lock()
	s.token = token
	s.mu.Unlock()
}

func (s *piRuntimeSession) beginDispatch(dispatchID, token, preparedExecutionID string) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	executionID := s.executionID
	active := s.workState == "running" && executionID != ""
	if preparedExecutionID == "" {
		return "", errors.New("prepared execution id is required")
	}
	if active && executionID != preparedExecutionID {
		return "", errors.New("prepared execution id changed during active pi execution")
	}
	if (s.workState == "settled" || s.workState == "failed") && executionID == preparedExecutionID {
		return "", errors.New("settled pi execution cannot be restarted")
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

func (s *piRuntimeSession) observeEvent(eventType, name string) (string, string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	workState := ""
	switch name {
	case "agent_start", "turn_start":
		s.workState = "running"
		workState = "running"
	case "agent_settled":
		if s.workState == "running" {
			s.workState = "settled"
			workState = "settled"
		}
	default:
		if (eventType == "message" || eventType == "thinking" || eventType == "operation") &&
			s.workState == "running" {
			workState = "running"
		}
	}
	return s.dispatchID, s.executionID, workState
}

func (s *piRuntimeSession) observeExit() (string, string, string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	workState := ""
	if s.workState == "starting" || s.workState == "running" {
		s.workState = "failed"
		workState = "failed"
	}
	return s.dispatchID, s.executionID, workState, s.workState == "settled"
}

func (s *piRuntimeSession) replayObservation() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.workState == "running" || s.workState == "settled" || s.workState == "failed" {
		event := standardRuntimeEvent("pi", "status", "connector/reconnected")
		event["state"] = s.workState
		s.connector.forwardRuntimeEvent(
			s.token,
			attachRuntimeIdentity(event, s.dispatchID, s.executionID, s.workState),
		)
	}
}

func (s *piRuntimeSession) currentToken() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.token
}

func piStandardEvents(native map[string]any) []map[string]any {
	name := stringParam(native, "type")
	switch name {
	case "message_update":
		update := mapParam(native, "assistantMessageEvent")
		if stringParam(update, "type") == "error" {
			event := standardRuntimeEvent("pi", "error", name)
			event["message"] = stringParam(mapParam(update, "error"), "errorMessage")
			return []map[string]any{event}
		}
		return nil

	case "message_end":
		message := mapParam(native, "message")
		if stringParam(message, "role") != "assistant" {
			return nil
		}
		events := []map[string]any{}
		if content := contentBlockText(message["content"], "thinking", "thinking"); content != "" {
			event := standardRuntimeEvent("pi", "thinking", name)
			event["content"] = content
			events = append(events, event)
		}
		if content := contentBlockText(message["content"], "text", "text"); content != "" {
			event := standardRuntimeEvent("pi", "message", name)
			event["role"] = "assistant"
			event["content"] = content
			if usage := mapParam(message, "usage"); len(usage) > 0 {
				event["usage"] = usage
			}
			events = append(events, event)
		}
		return events

	case "tool_execution_start", "tool_execution_end":
		event := standardRuntimeEvent("pi", "operation", stringParam(native, "toolName"))
		event["operation_id"] = stringParam(native, "toolCallId")
		event["status"] = strings.TrimPrefix(name, "tool_execution_")
		if input := mapParam(native, "args"); len(input) > 0 {
			event["input"] = input
		}
		if output := native["result"]; output != nil {
			event["output"] = output
		}
		return []map[string]any{event}

	case "extension_error":
		event := standardRuntimeEvent("pi", "error", name)
		event["message"] = stringParam(native, "error")
		return []map[string]any{event}

	case "agent_start", "agent_end", "agent_settled", "turn_start", "turn_end", "queue_update", "compaction_start", "compaction_end", "auto_retry_start", "auto_retry_end", "model_select", "thinking_level_changed":
		event := standardRuntimeEvent("pi", "status", name)
		event["state"] = name
		return []map[string]any{event}
	default:
		return nil
	}
}
