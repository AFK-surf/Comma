package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	claudeCommandTimeout        = 60 * time.Second
	claudeWriteTimeout          = 10 * time.Second
	claudeCloseTimeout          = 3 * time.Second
	claudeDiagnosticMaxBytes    = 32 * 1024
	claudeReadinessMaxLineBytes = 1024 * 1024
)

type claudeRuntimeImplementation struct {
	connector        *connector
	activityMu       sync.RWMutex
	activityRevision atomic.Uint64
	mu               sync.Mutex
	sessions         map[string]*claudeRuntimeSlot
	sessionOrder     []string
	sessionIndex     map[string]int
	authGeneration   *claudeAuthGeneration
	authEpoch        uint64
}

func (i *claudeRuntimeImplementation) beginActivity() func() {
	i.activityMu.RLock()
	i.activityRevision.Add(1)
	return i.activityMu.RUnlock
}

type claudeAuthGeneration struct {
	id   uint64
	stop chan struct{}
	wait sync.WaitGroup
}

type claudeRuntimeSlot struct {
	mu            sync.Mutex
	session       *claudeRuntimeSession
	recoveryInput externalRuntimeInput
}

type claudeRuntimeSession struct {
	managedCredential *managedRuntimeCredential
	model             string
	reasoningEffort   string
	implementation    *claudeRuntimeImplementation
	connector         *connector
	sessionID         string
	nativeID          string
	token             string
	runtimeContext    string
	cmd               *exec.Cmd
	stdin             io.WriteCloser
	diagnostics       *harnessDiagnosticBuffer
	done              chan struct{}
	authGeneration    *claudeAuthGeneration
	promptFile        string

	writeMu         sync.Mutex
	mu              sync.Mutex
	nextID          int
	pendingControls map[string]chan map[string]any
	pendingReplays  map[string]chan bool
	turnDone        chan struct{}
	turnDoneClosed  bool
	normal          bool
	abandoned       bool
	steering        bool
	backgroundWork  bool
	dispatchID      string
	executionID     string
	workState       string
	readFailure     string
	processErr      error
	turnFailure     map[string]any
	limitInfo       map[string]any
	startupPending  bool
	startupRefused  bool
}

func newClaudeRuntimeImplementation(c *connector) *claudeRuntimeImplementation {
	return &claudeRuntimeImplementation{
		connector: c, sessions: map[string]*claudeRuntimeSlot{}, sessionIndex: map[string]int{},
		authGeneration: &claudeAuthGeneration{id: 1, stop: make(chan struct{})},
		authEpoch:      1,
	}
}

func (i *claudeRuntimeImplementation) authFence() (string, string) {
	i.mu.Lock()
	defer i.mu.Unlock()
	return fmt.Sprint(i.authGeneration.id), fmt.Sprint(i.authEpoch)
}

func (i *claudeRuntimeImplementation) retireAuthGeneration() <-chan struct{} {
	i.mu.Lock()
	retired := i.authGeneration
	i.authEpoch++
	i.authGeneration = &claudeAuthGeneration{id: retired.id + 1, stop: make(chan struct{})}
	close(retired.stop)
	i.mu.Unlock()
	exited := make(chan struct{})
	go func() { retired.wait.Wait(); close(exited) }()
	return exited
}

// commitAuthSettings retires every owned idle Claude process through one
// generation broadcast. Normal execution admission shares the target lock and
// is checked by the caller, so this never interrupts an active turn or scans
// per-session state on the request path.
func (i *claudeRuntimeImplementation) commitAuthSettings(ctx context.Context, generation, epoch string, commit func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	i.mu.Lock()
	if fmt.Sprint(i.authGeneration.id) != generation || fmt.Sprint(i.authEpoch) != epoch || commit == nil {
		i.mu.Unlock()
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	}
	retired := i.authGeneration
	i.authEpoch++
	i.authGeneration = &claudeAuthGeneration{id: retired.id + 1, stop: make(chan struct{})}
	close(retired.stop)
	i.mu.Unlock()

	exited := make(chan struct{})
	go func() {
		retired.wait.Wait()
		close(exited)
	}()
	timer := time.NewTimer(runtimeAuthNativeCancelTimeout)
	defer timer.Stop()
	select {
	case <-exited:
	case <-ctx.Done():
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	case <-timer.C:
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "native_writer_unavailable"}
	}
	return commit()
}

func (i *claudeRuntimeImplementation) Close() {
	i.mu.Lock()
	slots := make([]*claudeRuntimeSlot, 0, len(i.sessions))
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
			waitClaudeDone(session.done, claudeCloseTimeout)
		}
	}
}

func (i *claudeRuntimeImplementation) Restore(input externalRuntimeInput) error {
	defer i.beginActivity()()
	nativeID := stringParam(input.payload, "session_id")
	if !validClaudeSessionID(nativeID) {
		return errors.New("persisted claude runtime session has no valid session id")
	}
	slot := i.sessionSlot(input.sessionID)
	slot.mu.Lock()
	slot.recoveryInput = input
	slot.mu.Unlock()
	return nil
}

func (i *claudeRuntimeImplementation) Send(ctx context.Context, input externalRuntimeInput) (map[string]any, string, error) {
	defer i.beginActivity()()
	slot := i.sessionSlot(input.sessionID)
	slot.mu.Lock()
	defer slot.mu.Unlock()

	session := slot.session
	managed := i.connector.managedRuntimeCredential("claude", input.command)
	credentialChanged := session != nil && session.managedCredential != nil && managed != nil &&
		!session.managedCredential.sameConfiguration(managed)
	// Claude Code reads --model and --effort only at start. A changed choice
	// restarts an idle process on the same native session; a busy one keeps
	// running and the next idle input applies the change.
	settingsChanged := session != nil &&
		(session.model != input.model || session.reasoningEffort != input.reasoningEffort)
	if (credentialChanged || settingsChanged) && session.running() {
		session.mu.Lock()
		busy := session.workState == "starting" || session.workState == "running" || session.backgroundWork || session.steering
		session.mu.Unlock()
		if !busy {
			session.markAbandoned()
			if err := session.drain(ctx); err != nil {
				return nil, "", err
			}
			if stringParam(input.payload, "session_id") == "" {
				input.payload = withNativeClaudeSession(input.payload, session.nativeID)
			}
			slot.session, session = nil, nil
		}
	}
	if session == nil || !session.running() {
		var err error
		session, err = i.startSession(ctx, input)
		if err != nil {
			return nil, "", err
		}
		slot.session = session
	}

	turnDone, steering := session.prepareSteer()
	if steering {
		if _, err := session.control(ctx, map[string]any{"subtype": "interrupt"}); err != nil {
			session.cancelSteer()
			return nil, "", err
		}
		if err := waitClaudeSignal(ctx, turnDone, session.done, "claude interrupt timed out"); err != nil {
			session.cancelSteer()
			return nil, "", err
		}
	}

	executionID, err := session.beginDispatch(input.dispatchID, input.token, input.executionID, steering)
	if err != nil {
		return nil, "", err
	}
	input.executionID = executionID
	i.connector.registerRuntimeRoute(session.runtimeContext, input.token)
	slot.recoveryInput = externalRuntimeRecoveryInput(input, "session_id", session.nativeID)
	if err := i.connector.watchExternalRuntime("claude", slot.recoveryInput); err != nil {
		return nil, "", err
	}
	session.mu.Lock()
	session.abandoned = false
	session.startupPending = false
	session.mu.Unlock()
	if err := session.prompt(ctx, input.text()); err != nil {
		return nil, "", err
	}
	return map[string]any{"session_id": session.nativeID}, executionID, nil
}

func (i *claudeRuntimeImplementation) ReplayObservations() {
	i.mu.Lock()
	slots := make([]*claudeRuntimeSlot, 0, len(i.sessions))
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

func (i *claudeRuntimeImplementation) RuntimePIDs() []int {
	i.mu.Lock()
	slots := make([]*claudeRuntimeSlot, 0, len(i.sessions))
	for _, slot := range i.sessions {
		slots = append(slots, slot)
	}
	i.mu.Unlock()
	pids := make([]int, 0, len(slots))
	for _, slot := range slots {
		if !slot.mu.TryLock() {
			continue
		}
		if slot.session != nil && slot.session.running() && slot.session.cmd.Process != nil {
			pids = append(pids, slot.session.cmd.Process.Pid)
		}
		slot.mu.Unlock()
	}
	return pids
}

func (i *claudeRuntimeImplementation) Check(ctx context.Context, sessionID string) error {
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
		_, err := slot.session.control(probeCtx, map[string]any{"subtype": "initialize"})
		cancel()
		if err == nil {
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
	if !i.connector.externalRuntimeState.watched("claude", sessionID) || slot.recoveryInput.command == "" {
		return nil
	}

	session, err := i.startSession(ctx, slot.recoveryInput)
	if err != nil {
		return err
	}
	slot.session = session
	session.mu.Lock()
	session.abandoned = false
	session.startupPending = false
	session.mu.Unlock()
	if err := session.prompt(ctx, externalRuntimeRecoveryMessage); err != nil {
		slot.session = nil
		session.stop()
		return err
	}
	if err := i.connector.externalRuntimeState.markExecutionRecovered(
		"claude", sessionID, slot.recoveryInput.token,
	); err != nil {
		return err
	}
	return nil
}

func (i *claudeRuntimeImplementation) sessionSlot(sessionID string) *claudeRuntimeSlot {
	i.mu.Lock()
	defer i.mu.Unlock()
	slot := i.sessions[sessionID]
	if slot == nil {
		slot = &claudeRuntimeSlot{}
		i.sessions[sessionID] = slot
		appendRuntimeSessionID(&i.sessionOrder, &i.sessionIndex, sessionID)
	}
	return slot
}

func (i *claudeRuntimeImplementation) startSession(ctx context.Context, input externalRuntimeInput) (*claudeRuntimeSession, error) {
	var err error
	for _, launchCommand := range harnessLaunchCommands("claude", input.command) {
		attempt, cancel := context.WithTimeout(ctx, 20*time.Second)
		session, startErr := i.startSessionCommand(attempt, input, launchCommand)
		cancel()
		if startErr == nil {
			return session, nil
		}
		err = startErr
		if !canRetryHarnessStartup(ctx, err) {
			return nil, err
		}
	}
	return nil, err
}

func (i *claudeRuntimeImplementation) startSessionCommand(ctx context.Context, input externalRuntimeInput, launchCommand string) (*claudeRuntimeSession, error) {
	if input.command == "" {
		return nil, errors.New("agent_runtime_input requires discovered claude command")
	}
	bridgeURL, err := i.connector.ensureRuntimeBridge()
	if err != nil {
		return nil, err
	}
	cliDir, err := i.connector.ensureSalixCLI("claude")
	if err != nil {
		return nil, err
	}
	runtimeContext, err := newRuntimeContext()
	if err != nil {
		return nil, err
	}

	resumeID := stringParam(input.payload, "session_id")
	if boolParam(input.payload, "require_native_resume") && resumeID == "" {
		return nil, errors.New("migrated Claude Session has no native identity")
	}
	nativeID := resumeID
	if nativeID == "" {
		nativeID, err = newClaudeSessionID()
		if err != nil {
			return nil, err
		}
	} else if !validClaudeSessionID(nativeID) {
		return nil, errors.New("persisted claude runtime session has an invalid session id")
	}

	managed := i.connector.managedRuntimeCredential("claude", input.command)
	settings := []string(nil)
	if managed != nil {
		if managedClaudeNativeAuthConflict() {
			return nil, errors.New("managed Claude credential conflicts with native personal credentials")
		}
		if managedClaudeWorkspaceConflict(input.workspace) {
			return nil, errors.New("managed Claude credential conflicts with workspace auth settings")
		}
	} else {
		settings, _, err = runtimeAuthClaudeArgs()
		if err != nil {
			return nil, errors.New("claude auth settings are invalid")
		}
	}
	args := append([]string{}, settings...)
	args = append(args,
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--verbose",
		"--replay-user-messages",
		"--permission-mode", "bypassPermissions",
		"--allow-dangerously-skip-permissions",
	)
	if resumeID == "" {
		args = append(args, "--session-id="+nativeID)
	} else {
		args = append(args, "--resume="+nativeID)
	}
	if input.model != "" {
		args = append(args, "--model", input.model)
	}
	if input.reasoningEffort != "" {
		args = append(args, "--effort", input.reasoningEffort)
	}
	// Linux bounds each exec argument. Keep the complete prompt outside argv.
	promptFile, err := os.CreateTemp("", "salix-claude-system-prompt-*")
	if err != nil {
		return nil, err
	}
	promptOwnedBySession := false
	defer func() {
		if !promptOwnedBySession {
			_ = os.Remove(promptFile.Name())
		}
	}()
	_, writeErr := io.WriteString(promptFile, externalRuntimeSystemPrompt(input.systemPrompt))
	closeErr := promptFile.Close()
	if writeErr != nil {
		return nil, writeErr
	}
	if closeErr != nil {
		return nil, closeErr
	}
	// Keep the private file until process exit, including any deferred reads.
	args = append(args, "--append-system-prompt-file", promptFile.Name())

	cmd := exec.Command(launchCommand, args...)
	configureProcessGroup(cmd)
	cmd.Dir = input.workspace
	cmd.WaitDelay = claudeCloseTimeout
	managedCompute := i.connector.cfg.runtimeAgent &&
		i.connector.cfg.computeRuntimeKind == "external_worker" &&
		i.connector.cfg.computeRuntimeProvider == "claude"
	environment := map[string]any{
		"PATH":                  runtimeCommandPath(launchCommand, cliDir),
		"SALIX_CONNECT_URL":     bridgeURL,
		"SALIX_CLI":             filepath.Join(cliDir, "salix"),
		"SALIX_ENV_ROOT":        i.connector.root,
		"SALIX_RUNTIME_CONTEXT": runtimeContext,
	}
	if managed != nil {
		environment["ANTHROPIC_BASE_URL"] = managed.endpoint
		if managed.authScheme == "bearer" {
			environment["ANTHROPIC_AUTH_TOKEN"] = managed.apiKey
		} else {
			environment["ANTHROPIC_API_KEY"] = managed.apiKey
		}
	}
	if managed != nil {
		cmd.Env = runtimeAuthClaudeManagedExecEnv(environment, managed)
	} else {
		cmd.Env = runtimeAuthClaudeExecEnv(environment, len(settings) > 0 || managedCompute)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	diagnostics := &harnessDiagnosticBuffer{}
	cmd.Stderr = diagnostics
	i.mu.Lock()
	authGeneration := i.authGeneration
	if managed != i.connector.managedRuntimeCredential("claude", input.command) {
		i.mu.Unlock()
		return nil, errSubscriptionUnavailable
	}
	authGeneration.wait.Add(1)
	i.mu.Unlock()
	if err := cmd.Start(); err != nil {
		authGeneration.wait.Done()
		return nil, &harnessStartupError{err}
	}

	session := &claudeRuntimeSession{
		managedCredential: managed,
		model:             input.model,
		reasoningEffort:   input.reasoningEffort,
		implementation:    i,
		connector:         i.connector,
		sessionID:         input.sessionID,
		nativeID:          nativeID,
		token:             input.token,
		runtimeContext:    runtimeContext,
		cmd:               cmd,
		stdin:             stdin,
		diagnostics:       diagnostics,
		done:              make(chan struct{}),
		authGeneration:    authGeneration,
		promptFile:        promptFile.Name(),
		nextID:            1,
		pendingControls:   map[string]chan map[string]any{},
		pendingReplays:    map[string]chan bool{},
		// Initialization cannot accept user input. Suppress terminal execution
		// events until startup succeeds and Send can persist the native binding.
		abandoned:      true,
		startupPending: true,
		dispatchID:     input.dispatchID,
		executionID:    input.executionID,
	}
	if input.executionID != "" {
		session.workState = "starting"
		session.turnDone = make(chan struct{})
	}
	promptOwnedBySession = true
	go func() {
		session.readLoop(stdout)
		session.wait()
	}()
	go func() {
		select {
		case <-authGeneration.stop:
			session.stop()
		case <-session.done:
		}
	}()

	if _, err := session.control(ctx, map[string]any{"subtype": "initialize"}); err != nil {

		if cleanupErr := stopHarnessStartup(context.WithoutCancel(ctx), func() { killHarnessStartupGroup(session.cmd); session.stop() }, session.done); cleanupErr != nil {
			return nil, cleanupErr
		}
		session.mu.Lock()
		refused := session.startupRefused
		session.mu.Unlock()
		if refused {
			return nil, err
		}
		var rejection *nativeControlRejection
		if errors.As(err, &rejection) || !session.diagnostics.permitsStartupRetry() {
			return nil, err
		}
		return nil, &harnessStartupError{err}
	}
	i.connector.registerRuntimeRoute(runtimeContext, session.token)
	return session, nil
}

func managedClaudeWorkspaceConflict(workspace string) bool {
	return managedClaudeAuthFilesConflict(
		filepath.Join(workspace, ".claude", "settings.json"),
		filepath.Join(workspace, ".claude", "settings.local.json"),
	)
}

func managedClaudeConfigAuthConflict(directory string) bool {
	return managedClaudeAuthFilesConflict(
		filepath.Join(directory, "settings.json"),
		filepath.Join(directory, "settings.local.json"),
	)
}

func managedClaudeAuthFilesConflict(paths ...string) bool {
	for _, path := range paths {
		file, err := os.Open(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return true
		}
		var value any
		err = json.NewDecoder(io.LimitReader(file, runtimeAuthPlaintextLimit+1)).Decode(&value)
		file.Close()
		if err != nil || managedClaudeValueHasAuth(value) {
			return true
		}
	}
	return false
}

func managedClaudeValueHasAuth(value any) bool {
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			switch key {
			case "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "apiKeyHelper":
				return true
			}
			if managedClaudeValueHasAuth(child) {
				return true
			}
		}
	case []any:
		for _, child := range value {
			if managedClaudeValueHasAuth(child) {
				return true
			}
		}
	}
	return false
}

func (i *claudeRuntimeImplementation) AbandonRecovery(record externalRuntimeRecoveryRecord, reason string) bool {
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

func (i *claudeRuntimeImplementation) forgetIfCurrent(session *claudeRuntimeSession) bool {
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
	i.connector.forgetExternalRuntime("claude", session.sessionID)
	return true
}

func (s *claudeRuntimeSession) control(ctx context.Context, request map[string]any) (map[string]any, error) {
	s.mu.Lock()
	id := fmt.Sprintf("salix-%d", s.nextID)
	s.nextID++
	response := make(chan map[string]any, 1)
	s.pendingControls[id] = response
	s.mu.Unlock()

	if err := s.writeJSON(ctx, map[string]any{
		"type": "control_request", "request_id": id, "request": request,
	}); err != nil {
		s.deleteControl(id)
		return nil, err
	}

	timer := time.NewTimer(claudeCommandTimeout)
	defer timer.Stop()
	select {
	case message, ok := <-response:
		if !ok {
			return nil, s.terminalError("control response")
		}
		if stringParam(message, "subtype") != "success" {
			return nil, &nativeControlRejection{fmt.Errorf("claude control %s was rejected", stringParam(request, "subtype"))}
		}
		return mapParam(message, "response"), nil
	case <-ctx.Done():
		s.deleteControl(id)
		return nil, ctx.Err()
	case <-timer.C:
		s.deleteControl(id)
		return nil, fmt.Errorf("claude control %s timed out", stringParam(request, "subtype"))
	case <-s.done:
		s.deleteControl(id)
		return nil, s.terminalError("control response")
	}
}

func (s *claudeRuntimeSession) prompt(ctx context.Context, message string) error {
	uuid, err := newClaudeSessionID()
	if err != nil {
		return err
	}
	accepted := make(chan bool, 1)
	s.mu.Lock()
	s.pendingReplays[uuid] = accepted
	s.mu.Unlock()
	request := map[string]any{
		"type":               "user",
		"session_id":         s.nativeID,
		"uuid":               uuid,
		"parent_tool_use_id": nil,
		"message": map[string]any{
			"role":    "user",
			"content": []any{map[string]any{"type": "text", "text": message}},
		},
	}
	if err := s.writeJSON(ctx, request); err != nil {
		s.deleteReplay(uuid)
		return err
	}

	timer := time.NewTimer(claudeCommandTimeout)
	defer timer.Stop()
	select {
	case accepted, ok := <-accepted:
		if !ok || !accepted {
			return s.terminalError("input acceptance")
		}
		return nil
	case <-ctx.Done():
		s.deleteReplay(uuid)
		return ctx.Err()
	case <-timer.C:
		s.deleteReplay(uuid)
		return errors.New("claude prompt acceptance timed out")
	case <-s.done:
		s.deleteReplay(uuid)
		return s.terminalError("input acceptance")
	}
}

func (s *claudeRuntimeSession) writeJSON(ctx context.Context, value map[string]any) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	written := make(chan error, 1)
	go func() {
		s.writeMu.Lock()
		_, err := s.stdin.Write(raw)
		s.writeMu.Unlock()
		written <- err
	}()
	timer := time.NewTimer(claudeWriteTimeout)
	defer timer.Stop()
	select {
	case err := <-written:
		return err
	case <-ctx.Done():
		s.stop()
		return ctx.Err()
	case <-s.done:
		return s.terminalError("input write")
	case <-timer.C:
		s.stop()
		return errors.New("claude process input write timed out")
	}
}

func (s *claudeRuntimeSession) readLoop(stdout io.Reader) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), maxFile)
	for scanner.Scan() {
		var message map[string]any
		if json.Unmarshal(scanner.Bytes(), &message) != nil {
			s.failProtocol("invalid_json")
			return
		}
		s.handleMessage(message)
	}
	if err := scanner.Err(); err != nil {
		failure := "stream_read_failed"
		if strings.Contains(strings.ToLower(err.Error()), "token too long") {
			failure = "response_too_large"
		}
		s.failProtocol(failure)
		return
	}
	if !s.wasAbandoned() {
		s.failProtocol("stdout_closed")
	}
}

func (s *claudeRuntimeSession) handleMessage(native map[string]any) {
	messageType := stringParam(native, "type")
	if messageType == "control_response" {
		response := mapParam(native, "response")
		id := stringParam(response, "request_id")
		s.mu.Lock()
		pending := s.pendingControls[id]
		delete(s.pendingControls, id)
		s.mu.Unlock()
		if pending != nil {
			pending <- response
		}
		return
	}
	if messageType == "control_request" {
		go func() {
			ctx, cancel := context.WithTimeout(context.Background(), externalRuntimeProbeTimeout)
			defer cancel()
			_ = s.writeJSON(ctx, map[string]any{
				"type": "control_response",
				"response": map[string]any{
					"subtype": "error", "request_id": native["request_id"],
					"error": "unsupported by the Salix connected runtime",
				},
			})
		}()
		return
	}
	if nativeID := stringParam(native, "session_id"); nativeID != "" && nativeID != s.nativeID {
		s.mu.Lock()
		s.startupRefused = s.startupPending
		s.mu.Unlock()
		s.failProtocol("session_identity_mismatch")
		return
	}
	s.mu.Lock()
	startup := s.startupPending
	if startup && (messageType == "result" || messageType == "error") {
		s.startupRefused = true
	}
	refused := s.startupRefused
	s.mu.Unlock()
	if startup {
		if refused {
			s.stop()
		}
		return
	}

	if messageType == "system" && stringParam(native, "subtype") == "background_tasks_changed" {
		// The pinned CLI publishes the complete live-task snapshot, including
		// ambient tasks. A settled foreground result does not retire these.
		tasks, valid := native["tasks"].([]any)
		s.mu.Lock()
		s.backgroundWork = !valid || len(tasks) != 0
		s.mu.Unlock()
	}
	if messageType == "system" && stringParam(native, "subtype") == "turn_starting" {
		s.mu.Lock()
		s.workState = externalRuntimeExecutionRunning
		s.mu.Unlock()
	}

	if messageType == "user" {
		if accepted := s.acceptReplay(stringParam(native, "uuid")); accepted != nil {
			dispatchID, executionID, token := s.observeAcceptedInput()
			event := standardRuntimeEvent("claude", "status", "turn.started")
			event["state"] = "running"
			s.connector.forwardRuntimeExecutionEvent(
				"claude", s.sessionID, token,
				attachRuntimeIdentity(event, dispatchID, executionID, externalRuntimeExecutionRunning),
				externalRuntimeExecutionRunning,
			)
			accepted <- true
			close(accepted)
		}
	}

	// Rate-limit warnings are not failed turns: fallback or extra usage may
	// still succeed. Only an assistant API error or failed result is terminal.
	if messageType == "rate_limit_event" {
		s.mu.Lock()
		s.limitInfo = mapParam(native, "rate_limit_info")
		s.mu.Unlock()
		return
	}
	if messageType == "assistant" && stringParam(native, "parent_tool_use_id") == "" {
		if failure := claudeAPIUsageFailure(native); failure != nil {
			s.mu.Lock()
			s.turnFailure = failure
			s.mu.Unlock()
			return
		}
	}

	if messageType == "result" {
		failed := native["is_error"] == true || stringParam(native, "subtype") != "success"
		s.mu.Lock()
		failure := maps.Clone(s.turnFailure)
		if failure != nil {
			failed = true
			if stringParam(s.limitInfo, "errorCode") == "credits_required" {
				failure["issue"] = "quota_exhausted"
			}
			failure["usage_reset_at"] = s.limitInfo["resetsAt"]
			s.turnFailure = maps.Clone(failure)
		}
		s.mu.Unlock()
		dispatchID, executionID, workState, token, intentionalSteer := s.observeResult(failed)
		if intentionalSteer {
			event := standardRuntimeEvent("claude", "status", "turn.interrupted")
			event["state"] = "interrupted"
			s.connector.forwardRuntimeEvent(
				token, attachRuntimeIdentity(event, dispatchID, executionID, ""),
			)
			s.signalTurnDone()
			return
		}
		events := claudeStandardEvents(native)
		if failure != nil {
			if usage := mapParam(native, "usage"); len(usage) > 0 {
				failure["usage"] = usage
			}
			events = []map[string]any{failure}
		}
		for _, event := range events {
			s.connector.forwardRuntimeExecutionEvent(
				"claude", s.sessionID, token,
				attachRuntimeIdentity(event, dispatchID, executionID, workState),
				externalRuntimeExecutionSettled,
			)
		}
		s.signalTurnDone()
		return
	}

	for _, event := range claudeStandardEvents(native) {
		dispatchID, executionID, workState, token := s.currentObservation()
		s.connector.forwardRuntimeExecutionEvent(
			"claude", s.sessionID, token,
			attachRuntimeIdentity(event, dispatchID, executionID, workState), "",
		)
	}
}

func (s *claudeRuntimeSession) wait() {
	err := s.cmd.Wait()
	_ = os.Remove(s.promptFile)
	s.authGeneration.wait.Done()
	dispatchID, executionID, workState := s.observeExit()
	s.mu.Lock()
	s.processErr = err
	settled := s.workState == externalRuntimeExecutionSettled
	// An unfinished turn is not a normal stop, even after a zero exit.
	s.normal = err == nil && s.readFailure == "" && workState != "failed"
	s.mu.Unlock()
	defer close(s.done)
	s.closePending()
	s.connector.removeRuntimeRoute(s.runtimeContext)
	if s.wasAbandoned() {
		return
	}
	if err == nil && workState != "failed" {
		if !s.implementation.forgetIfCurrent(s) {
			return
		}
		event := standardRuntimeEvent("claude", "status", "runtime_stopped")
		event["state"] = "stopped"
		s.connector.forwardRuntimeEvent(s.currentToken(), event)
		return
	}
	event := map[string]any{
		"type": "error", "provider": "claude", "issue": s.failureIssue(),
		"message": "Claude Code process exited before completing the turn.",
	}
	if settled {
		event = standardRuntimeEvent("claude", "status", "runtime_stopped")
		event["state"] = "stopped"
		logf("claude runtime stopped after settlement session=%s: %v", s.sessionID, err)
	}
	s.connector.forwardRuntimeExecutionEvent("claude", s.sessionID, s.currentToken(), attachRuntimeIdentity(event,
		dispatchID, executionID, workState), externalRuntimeExecutionInterrupted)
}

func (s *claudeRuntimeSession) failProtocol(failure string) {
	s.mu.Lock()
	if s.readFailure == "" {
		s.readFailure = failure
	}
	s.mu.Unlock()
	s.stop()
}

func (s *claudeRuntimeSession) failureIssue() string {
	category := s.diagnostics.category()
	if category == "authentication_required" || category == "quota_exhausted" || category == "rate_limited" {
		return category
	}
	return "runtime_failed"
}

func (s *claudeRuntimeSession) terminalError(action string) error {
	category := s.diagnostics.category()
	s.mu.Lock()
	readFailure := s.readFailure
	processErr := s.processErr
	s.mu.Unlock()
	if category != "runtime_failed" {
		return fmt.Errorf("claude %s failed: %s", action, category)
	}
	if readFailure != "" {
		return fmt.Errorf("claude %s failed: %s", action, readFailure)
	}
	if processErr != nil {
		return fmt.Errorf("claude %s failed: runtime_failed", action)
	}
	return fmt.Errorf("claude %s failed: process_closed", action)
}

func (s *claudeRuntimeSession) closePending() {
	s.mu.Lock()
	defer s.mu.Unlock()
	for id, pending := range s.pendingControls {
		delete(s.pendingControls, id)
		close(pending)
	}
	for id, pending := range s.pendingReplays {
		delete(s.pendingReplays, id)
		close(pending)
	}
}

func (s *claudeRuntimeSession) acceptReplay(uuid string) chan bool {
	if uuid == "" {
		return nil
	}
	s.mu.Lock()
	pending := s.pendingReplays[uuid]
	delete(s.pendingReplays, uuid)
	s.mu.Unlock()
	return pending
}

func (s *claudeRuntimeSession) deleteControl(id string) {
	s.mu.Lock()
	delete(s.pendingControls, id)
	s.mu.Unlock()
}

func (s *claudeRuntimeSession) deleteReplay(id string) {
	s.mu.Lock()
	delete(s.pendingReplays, id)
	s.mu.Unlock()
}

func (s *claudeRuntimeSession) prepareSteer() (<-chan struct{}, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.workState != externalRuntimeExecutionRunning || s.executionID == "" || s.turnDone == nil {
		return nil, false
	}
	s.steering = true
	return s.turnDone, true
}

func (s *claudeRuntimeSession) cancelSteer() {
	s.mu.Lock()
	s.steering = false
	s.mu.Unlock()
}

func (s *claudeRuntimeSession) beginDispatch(dispatchID, token, preparedExecutionID string, preserveExecution bool) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	executionID := s.executionID
	if preparedExecutionID == "" {
		return "", errors.New("prepared execution id is required")
	}
	if preserveExecution && executionID != "" && executionID != preparedExecutionID {
		return "", errors.New("prepared execution id changed during active claude execution")
	}
	if (s.workState == "settled" || s.workState == "failed") && executionID == preparedExecutionID {
		return "", errors.New("settled claude execution cannot be restarted")
	}
	executionID = preparedExecutionID
	s.token = token
	s.dispatchID = dispatchID
	s.executionID = executionID
	s.workState = "starting"
	s.turnFailure = nil
	s.limitInfo = nil
	s.steering = false
	s.turnDone = make(chan struct{})
	s.turnDoneClosed = false
	return executionID, nil
}

func (s *claudeRuntimeSession) observeAcceptedInput() (string, string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.workState = externalRuntimeExecutionRunning
	return s.dispatchID, s.executionID, s.token
}

func (s *claudeRuntimeSession) observeResult(failed bool) (string, string, string, string, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	intentionalSteer := s.steering
	s.steering = false
	if intentionalSteer {
		s.workState = "steering"
		return s.dispatchID, s.executionID, "", s.token, true
	}
	workState := externalRuntimeExecutionSettled
	if failed {
		workState = "failed"
	}
	s.workState = workState
	return s.dispatchID, s.executionID, workState, s.token, false
}

func (s *claudeRuntimeSession) signalTurnDone() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.turnDone != nil && !s.turnDoneClosed {
		close(s.turnDone)
		s.turnDoneClosed = true
	}
}

func (s *claudeRuntimeSession) currentObservation() (string, string, string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	workState := ""
	if s.workState == externalRuntimeExecutionRunning {
		workState = externalRuntimeExecutionRunning
	}
	return s.dispatchID, s.executionID, workState, s.token
}

func (s *claudeRuntimeSession) observeExit() (string, string, string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	workState := ""
	if s.workState == "starting" || s.workState == externalRuntimeExecutionRunning || s.workState == "steering" {
		s.workState = "failed"
		workState = "failed"
	}
	return s.dispatchID, s.executionID, workState
}

func (s *claudeRuntimeSession) replayObservation() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.workState == externalRuntimeExecutionRunning || s.workState == externalRuntimeExecutionSettled || s.workState == "failed" {
		event := standardRuntimeEvent("claude", "status", "connector/reconnected")
		event["state"] = s.workState
		if s.workState == "failed" && s.turnFailure != nil {
			event["issue"] = s.turnFailure["issue"]
			event["usage_reset_at"] = s.turnFailure["usage_reset_at"]
		}
		s.connector.forwardRuntimeEvent(
			s.token, attachRuntimeIdentity(event, s.dispatchID, s.executionID, s.workState),
		)
	}
}

func (s *claudeRuntimeSession) running() bool {
	select {
	case <-s.done:
		return false
	default:
		return true
	}
}

func (s *claudeRuntimeSession) stoppedNormally() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.normal
}

func (s *claudeRuntimeSession) markAbandoned() {
	s.mu.Lock()
	s.abandoned = true
	s.mu.Unlock()
}

func (s *claudeRuntimeSession) wasAbandoned() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.abandoned
}

func (s *claudeRuntimeSession) currentToken() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.token
}

func (s *claudeRuntimeSession) stop() {
	killProcessGroup(s.cmd)
}

// Closing the input stream lets Claude flush its native transcript before
// an idle handoff. A kill after the result event can lose the completed turn.
func (s *claudeRuntimeSession) drain(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	select {
	case <-s.done:
	default:
		if err := lockRuntimeContext(ctx, &s.writeMu); err != nil {
			return err
		}
		if s.stdin == nil {
			s.writeMu.Unlock()
			return errors.New("Claude input stream is unavailable for a durable drain")
		}
		err := s.stdin.Close()
		s.writeMu.Unlock()
		if err != nil {
			return err
		}
		select {
		case <-s.done:
		case <-ctx.Done():
			return fmt.Errorf("Claude native Session drain did not finish: %w", ctx.Err())
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.processErr != nil || s.readFailure != "" {
		return fmt.Errorf("Claude failed to flush its native Session: exit=%v read=%s", s.processErr, s.readFailure)
	}
	return nil
}

func waitClaudeSignal(ctx context.Context, signal <-chan struct{}, processDone <-chan struct{}, timeoutMessage string) error {
	timer := time.NewTimer(claudeCommandTimeout)
	defer timer.Stop()
	select {
	case <-signal:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	case <-processDone:
		return errors.New("claude process exited")
	case <-timer.C:
		return errors.New(timeoutMessage)
	}
}

func waitClaudeDone(done <-chan struct{}, timeout time.Duration) bool {
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-done:
		return true
	case <-timer.C:
		return false
	}
}

func newClaudeSessionID() (string, error) {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	encoded := hex.EncodeToString(bytes)
	return encoded[0:8] + "-" + encoded[8:12] + "-" + encoded[12:16] + "-" + encoded[16:20] + "-" + encoded[20:32], nil
}

func validClaudeSessionID(value string) bool {
	parts := strings.Split(value, "-")
	if len(parts) != 5 || len(parts[0]) != 8 || len(parts[1]) != 4 || len(parts[2]) != 4 || len(parts[3]) != 4 || len(parts[4]) != 12 {
		return false
	}
	raw, err := hex.DecodeString(strings.Join(parts, ""))
	return err == nil && len(raw) == 16
}

func claudeStandardEvents(native map[string]any) []map[string]any {
	switch stringParam(native, "type") {
	case "assistant":
		message := mapParam(native, "message")
		if stringParam(message, "role") != "assistant" {
			return nil
		}
		events := []map[string]any{}
		if content := contentBlockText(message["content"], "thinking", "thinking"); content != "" {
			event := standardRuntimeEvent("claude", "thinking", "assistant.thinking")
			event["content"] = content
			events = append(events, event)
		}
		if content := contentBlockText(message["content"], "text", "text"); content != "" {
			event := standardRuntimeEvent("claude", "message", "assistant.message")
			event["role"] = "assistant"
			event["content"] = content
			if usage := mapParam(message, "usage"); len(usage) > 0 {
				event["usage"] = usage
			}
			events = append(events, event)
		}
		content, _ := message["content"].([]any)
		for _, item := range content {
			block, _ := item.(map[string]any)
			if stringParam(block, "type") != "tool_use" || stringParam(block, "name") == "" {
				continue
			}
			event := standardRuntimeEvent("claude", "operation", stringParam(block, "name"))
			event["operation_id"] = stringParam(block, "id")
			event["status"] = "started"
			if input := mapParam(block, "input"); len(input) > 0 {
				event["input"] = input
			}
			events = append(events, event)
		}
		return events

	case "user":
		message := mapParam(native, "message")
		content, _ := message["content"].([]any)
		events := []map[string]any{}
		for _, item := range content {
			block, _ := item.(map[string]any)
			if stringParam(block, "type") != "tool_result" {
				continue
			}
			event := standardRuntimeEvent("claude", "operation", "tool_result")
			event["operation_id"] = stringParam(block, "tool_use_id")
			event["status"] = "completed"
			event["output"] = block["content"]
			events = append(events, event)
		}
		return events

	case "result":
		if native["is_error"] == true || stringParam(native, "subtype") != "success" {
			event := standardRuntimeEvent("claude", "error", "turn.ended")
			event["code"] = defaultString(stringParam(native, "subtype"), "runtime_failed")
			event["message"] = defaultString(textList(native["errors"]), "Claude execution failed")
			if usage := mapParam(native, "usage"); len(usage) > 0 {
				event["usage"] = usage
			}
			return []map[string]any{event}
		}
		event := standardRuntimeEvent("claude", "status", "turn.ended")
		event["state"] = "completed"
		if usage := mapParam(native, "usage"); len(usage) > 0 {
			event["usage"] = usage
		}
		return []map[string]any{event}

	case "system":
		if subtype := stringParam(native, "subtype"); subtype != "" {
			event := standardRuntimeEvent("claude", "status", "system."+subtype)
			event["state"] = subtype
			return []map[string]any{event}
		}
	case "status":
		state := defaultString(stringParam(native, "status"), stringParam(native, "subtype"))
		if state != "" {
			event := standardRuntimeEvent("claude", "status", "agent.status.updated")
			event["state"] = state
			return []map[string]any{event}
		}
	case "stream_event", "keep_alive", "control_request", "control_response":
		return nil
	}
	return nil
}

// Only SDK API-error envelopes are interpreted as usage failures. Ordinary
// assistant prose (including quoted limit messages) is not a status signal.
func claudeAPIUsageFailure(native map[string]any) map[string]any {
	code := stringParam(native, "error")
	if code != "rate_limit" && code != "billing_error" {
		return nil
	}
	issue := "rate_limited"
	detail := strings.ToLower(contentBlockText(mapParam(native, "message")["content"], "text", "text"))
	if code == "billing_error" || strings.Contains(detail, "hit your session limit") ||
		strings.Contains(detail, "hit your usage limit") {
		issue = "quota_exhausted"
	}
	event := standardRuntimeEvent("claude", "error", "turn.ended")
	event["issue"] = issue
	return event
}

// Pool credentials are target-local. Retiring the shared native auth generation
// would interrupt a different Cloud VM target that is still executing work.
func (i *claudeRuntimeImplementation) retireManagedTarget(ctx context.Context, command string) error {
	i.activityMu.Lock()
	defer i.activityMu.Unlock()
	i.activityRevision.Add(1)
	i.mu.Lock()
	slots := make([]*claudeRuntimeSlot, 0, len(i.sessions))
	for _, slot := range i.sessions {
		slots = append(slots, slot)
	}
	i.mu.Unlock()
	for _, slot := range slots {
		if !slot.mu.TryLock() {
			return errors.New("runtime_busy")
		}
		session := slot.session
		if session != nil && session.cmd != nil && session.cmd.Path == command {
			err := stopExternalRuntime(ctx, session.stop, session.done)
			if err != nil {
				slot.mu.Unlock()
				return err
			}
			slot.session = nil
		}
		slot.mu.Unlock()
	}
	return nil
}

// withNativeClaudeSession returns a copy of payload that resumes nativeID.
func withNativeClaudeSession(payload map[string]any, nativeID string) map[string]any {
	resumed := make(map[string]any, len(payload)+1)
	for key, value := range payload {
		resumed[key] = value
	}
	resumed["session_id"] = nativeID
	return resumed
}
