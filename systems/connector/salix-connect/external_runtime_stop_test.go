package main

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

func TestRecoveryCheckWaitsForRuntimeActivityFence(t *testing.T) {
	c := &connector{}
	codex := newCodexRuntimeImplementation(c)
	claude := newClaudeRuntimeImplementation(c)
	pi := newPiRuntimeImplementation(c)
	kimi := newKimiRuntimeImplementation(c)
	tests := []struct {
		name   string
		lock   func()
		unlock func()
		check  func() error
	}{
		{"codex", codex.activityMu.Lock, codex.activityMu.Unlock, func() error { return codex.Check(context.Background(), "missing") }},
		{"claude", claude.activityMu.Lock, claude.activityMu.Unlock, func() error { return claude.Check(context.Background(), "missing") }},
		{"pi", pi.activityMu.Lock, pi.activityMu.Unlock, func() error { return pi.Check(context.Background(), "missing") }},
		{"kimi", kimi.activityMu.Lock, kimi.activityMu.Unlock, func() error { return kimi.Check(context.Background(), "missing") }},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			test.lock()
			started := make(chan struct{})
			done := make(chan error, 1)
			go func() {
				close(started)
				done <- test.check()
			}()
			<-started
			select {
			case err := <-done:
				test.unlock()
				t.Fatalf("recovery Check crossed the runtime activity fence: %v", err)
			case <-time.After(25 * time.Millisecond):
			}
			test.unlock()
			select {
			case err := <-done:
				if err != nil {
					t.Fatal(err)
				}
			case <-time.After(time.Second):
				t.Fatal("recovery Check did not resume after the runtime activity fence opened")
			}
		})
	}
}

func TestStopOnlyOwnedPiProcessThroughCurrentComputeTarget(t *testing.T) {
	root := t.TempDir()
	c := newEventTestConnector(t, root)
	implementation := newPiRuntimeImplementation(c)
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": implementation}
	id := canonicalStopSessionID(t)
	record := testRecoveryObligationRecord("pi", id, "dispatch-1", "execution-1")
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	session := &piRuntimeSession{implementation: implementation, connector: c, sessionID: id,
		token: record.Token, cmd: exec.Command("sleep", "60"), done: make(chan struct{}),
		dispatchID: record.DispatchID, executionID: record.ExecutionID, workState: "running"}
	if err := session.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer session.stop()
	go session.wait()
	implementation.sessionSlot(id).session = session
	implementation.sessionSlot(id).recoveryInput = record.input()
	other := exec.Command("sleep", "60")
	if err := other.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = other.Process.Kill(); _ = other.Wait() }()
	c.runtimeAuthSlots = make(chan struct{}, runtimeAuthConcurrency)
	c.cfg.computeRuntimeTenantID = "tenant-1"
	c.cfg.computeRuntimeProjectID = "project-1"
	c.cfg.computeRuntimeWorkloadID = "workload-1"
	c.cfg.computeRuntimeProvider = "pi"
	carrier := computeRuntimeSession{instance: "instance-1", generation: 1, epoch: "epoch-1"}
	target := map[string]any{"tenant_id": "tenant-1", "project_id": "project-1",
		"workload_id": "workload-1", "runtime_instance_id": "instance-1",
		"generation": 1, "connection_epoch": "stale-epoch", "provider": "pi"}
	request := message{ID: "archive-1", Method: "agent_runtime_stop",
		Params: map[string]any{"target": target, "session_id": id}}
	if reply := c.computeRuntimeAuthReply(context.Background(), request, carrier); reply.Type != "error" {
		t.Fatalf("stale carrier target accepted: %v", reply)
	}
	if err := session.cmd.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("rejected target stopped native process: %v", err)
	}
	target["connection_epoch"] = "epoch-1"
	reply := c.computeRuntimeAuthReply(context.Background(), request, carrier)
	if result, ok := reply.Result.(map[string]any); reply.Type != "response" || !ok || result["stopped"] != true {
		t.Fatalf("compute stop=%v", reply)
	}
	select {
	case <-session.done:
	default:
		t.Fatal("stop acknowledged before native exit")
	}
	if err := other.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("unrelated process was stopped: %v", err)
	}
	if c.externalRuntimeState.watched("pi", id) {
		t.Fatal("stopped execution still has an automatic recovery obligation")
	}
	if err := implementation.Check(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if _, ok := implementation.sessions[id]; ok {
		t.Fatal("stopped execution remained in the active session index")
	}
	// A later task remains allowed; a stale stop cannot remove its recovery.
	next := record
	next.DispatchID, next.ExecutionID = "dispatch-2", "execution-2"
	if err := c.externalRuntimeState.watch(next); err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.retireStoppedExecution(record); err != nil {
		t.Fatal(err)
	}
	if !c.externalRuntimeState.watched("pi", id) {
		t.Fatal("stale stop removed newer work")
	}

}

func canonicalStopSessionID(t *testing.T) string {
	t.Helper()
	// Same canonical Session grammar used by all runtime ingress paths.
	id := "ses1_0000000000000000001"
	if !canonicalExternalRuntimeSessionID.MatchString(id) {
		t.Fatalf("invalid fixture session id: %s", id)
	}
	return id
}

func TestPiQuietRefusesActiveWorkAndStopsIdleNativeProcess(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	implementation := newPiRuntimeImplementation(c)
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": implementation}

	session := &piRuntimeSession{
		implementation: implementation,
		connector:      c,
		sessionID:      "quiet-session",
		cmd:            exec.Command("sleep", "60"),
		done:           make(chan struct{}),
		workState:      "running",
	}
	if err := session.cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer session.stop()
	go session.wait()
	implementation.sessionSlot(session.sessionID).session = session

	if _, err := c.methodAgentRuntimeQuiet(context.Background(), map[string]any{"provider": "pi"}); !errors.Is(err, errRuntimeNotQuiet) {
		t.Fatalf("active Pi quiet = %v, want errRuntimeNotQuiet", err)
	}
	if err := session.cmd.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("busy refusal stopped process: %v", err)
	}

	session.mu.Lock()
	session.workState = "settled"
	session.mu.Unlock()
	result, err := c.methodAgentRuntimeQuiet(context.Background(), map[string]any{"provider": "pi"})
	if err != nil || result["quiet"] != true {
		t.Fatalf("idle Pi quiet = %v, %v", result, err)
	}
	select {
	case <-session.done:
	default:
		t.Fatal("quiet acknowledged before native Pi process exited")
	}
	if _, ok := implementation.sessions[session.sessionID]; ok {
		t.Fatal("quiet kept the stopped Pi session indexed")
	}
}

func TestPiQuietProvesEverySessionIdleBeforeStoppingAnyProcess(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	implementation := newPiRuntimeImplementation(c)

	newSession := func(id, workState string) *piRuntimeSession {
		session := &piRuntimeSession{
			implementation: implementation,
			connector:      c,
			sessionID:      id,
			cmd:            exec.Command("sleep", "60"),
			done:           make(chan struct{}),
			workState:      workState,
		}
		if err := session.cmd.Start(); err != nil {
			t.Fatal(err)
		}
		go session.wait()
		implementation.sessionSlot(id).session = session
		return session
	}

	idle := newSession("a-idle", "settled")
	busy := newSession("b-busy", "running")
	defer idle.stop()
	defer busy.stop()

	if err := implementation.Quiet(context.Background()); !errors.Is(err, errRuntimeNotQuiet) {
		t.Fatalf("mixed quiet = %v, want errRuntimeNotQuiet", err)
	}
	if err := idle.cmd.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("busy refusal partially stopped an idle session: %v", err)
	}
	if implementation.sessions[idle.sessionID].session != idle {
		t.Fatal("busy refusal retired an idle session before proving the full runtime quiet")
	}
	if err := implementation.quietSessions(context.Background(), idle.sessionID); err != nil {
		t.Fatalf("per-session migration drain was blocked by another Session: %v", err)
	}
	if err := busy.cmd.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("per-session drain stopped another Session: %v", err)
	}
}

func TestRuntimeQuietChecksMoreThanTheOldSessionLimitInPages(t *testing.T) {
	implementation := newPiRuntimeImplementation(&connector{})
	for index := 0; index < 257; index++ {
		implementation.sessionSlot(fmt.Sprintf("session-%d", index))
	}
	if err := implementation.Quiet(context.Background()); err != nil {
		t.Fatalf("quiet rejected idle sessions above the old total limit: %v", err)
	}
	if len(implementation.sessions) != 0 || len(implementation.sessionOrder) != 0 || len(implementation.sessionIndex) != 0 {
		t.Fatalf("quiet retained historical sessions: sessions=%d order=%d index=%d", len(implementation.sessions), len(implementation.sessionOrder), len(implementation.sessionIndex))
	}
}

func TestRuntimeQuietRefusesAuthenticationMigrationAndProcessRights(t *testing.T) {
	for _, kind := range []string{"auth_operation", "migration_export", "exec"} {
		t.Run(kind, func(t *testing.T) {
			c := newEventTestConnector(t, t.TempDir())
			defer c.externalRuntimeState.close()
			implementation := newPiRuntimeImplementation(c)
			c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": implementation}
			if _, err := c.runtimeOperations.beginAcquire("family", "operation", kind, map[string]any{"target": "test"}); err != nil {
				t.Fatal(err)
			}
			if _, err := c.runtimeOperations.finishAcquire("operation", true, nil); err != nil {
				t.Fatal(err)
			}

			if _, err := c.methodAgentRuntimeQuiet(context.Background(), map[string]any{"provider": "pi"}); !errors.Is(err, errRuntimeNotQuiet) {
				t.Fatalf("%s right accepted quiet: %v", kind, err)
			}
		})
	}
}

func TestCodexQuietReadsBackgroundTerminalsWithoutStoppingThem(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	requests := make(chan map[string]any, 2)
	listAttempt := 0
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		for {
			var request map[string]any
			if err := ws.ReadJSON(&request); err != nil {
				return
			}
			requests <- request
			data := []any{}
			if listAttempt == 0 {
				data = []any{map[string]any{"processId": "42"}}
			}
			listAttempt++
			if err := ws.WriteJSON(map[string]any{"id": request["id"], "result": map[string]any{"data": data, "nextCursor": nil}}); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	runtime := &codexRuntime{ws: ws, done: make(chan struct{}), nextID: 1, pending: map[string]chan map[string]any{}}
	defer runtime.close()
	go runtime.readLoop(ws)
	id := canonicalStopSessionID(t)
	session := &codexRuntimeSession{sessionID: id, runtime: runtime, threadID: "thread-1", workState: "settled"}
	implementation := &codexRuntimeImplementation{connector: c, sessions: map[string]*codexRuntimeSession{id: session}, sessionOrder: []string{id}}
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": implementation}

	if _, err := c.methodAgentRuntimeQuiet(context.Background(), map[string]any{"provider": "codex"}); !errors.Is(err, errRuntimeNotQuiet) {
		t.Fatalf("background terminal quiet = %v, want errRuntimeNotQuiet", err)
	}
	if _, err := c.methodAgentRuntimeQuiet(context.Background(), map[string]any{"provider": "codex"}); err != nil {
		t.Fatal(err)
	}
	for range 2 {
		request := receiveMap(t, requests)
		params := mapParam(request, "params")
		if request["method"] != "thread/backgroundTerminals/list" || params["threadId"] != "thread-1" || params["limit"] != float64(1) {
			t.Fatalf("quiet used a mutating or unbounded Codex request: %v", request)
		}
	}
}

func TestCodexQuietRejectsActivityThatStartsBetweenPages(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	inspecting := make(chan struct{})
	release := make(chan struct{})
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		var request map[string]any
		if ws.ReadJSON(&request) != nil {
			return
		}
		close(inspecting)
		<-release
		_ = ws.WriteJSON(map[string]any{"id": request["id"], "result": map[string]any{"data": []any{}, "nextCursor": nil}})
	}))
	defer server.Close()
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	runtime := &codexRuntime{ws: ws, done: make(chan struct{}), nextID: 1, pending: map[string]chan map[string]any{}}
	defer runtime.close()
	go runtime.readLoop(ws)
	id := canonicalStopSessionID(t)
	session := &codexRuntimeSession{sessionID: id, runtime: runtime, threadID: "thread-1", workState: "settled"}
	implementation := &codexRuntimeImplementation{connector: c, sessions: map[string]*codexRuntimeSession{id: session}, sessionOrder: []string{id}}
	result := make(chan error, 1)
	go func() { result <- implementation.Quiet(context.Background()) }()
	<-inspecting
	implementation.activityRevision.Add(1)
	close(release)
	if err := <-result; !errors.Is(err, errRuntimeNotQuiet) {
		t.Fatalf("quiet concurrent activity = %v, want errRuntimeNotQuiet", err)
	}
}

func TestCodexStopWaitsForExactTurnAndKeepsSharedRuntime(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	received := make(chan map[string]any, 4)
	cleanAllowed := make(chan struct{}, 2)
	defer close(cleanAllowed)
	background := exec.Command("sleep", "60")
	if err := background.Start(); err != nil {
		t.Fatal(err)
	}
	backgroundDone := make(chan struct{})
	go func() { _ = background.Wait(); close(backgroundDone) }()
	defer func() { _ = background.Process.Kill(); <-backgroundDone }()
	otherBackground := exec.Command("sleep", "60")
	if err := otherBackground.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = otherBackground.Process.Kill(); _ = otherBackground.Wait() }()
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		for {
			var request map[string]any
			if err = ws.ReadJSON(&request); err != nil {
				return
			}
			received <- request
			if request["method"] == "thread/backgroundTerminals/clean" {
				<-cleanAllowed
				_ = background.Process.Kill()
				<-backgroundDone
			}
			if err = ws.WriteJSON(map[string]any{"id": request["id"], "result": map[string]any{}}); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	runtime := &codexRuntime{ws: ws, done: make(chan struct{}), nextID: 1, pending: map[string]chan map[string]any{}}
	defer runtime.close()
	go runtime.readLoop(ws)
	id := canonicalStopSessionID(t)
	record := testRecoveryObligationRecord("codex", id, "dispatch-1", "execution-1")
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	session := &codexRuntimeSession{sessionID: id, runtime: runtime, threadID: "thread-1", activeTurnID: "turn-1", workState: "running", recoveryInput: record.input()}
	other := &codexRuntimeSession{sessionID: "other", runtime: runtime, threadID: "thread-2", activeTurnID: "turn-2", workState: "running"}
	implementation := &codexRuntimeImplementation{connector: c, sessions: map[string]*codexRuntimeSession{id: session, "other": other}, sessionOrder: []string{id, "other"}, threads: map[string]string{"thread-1": id, "thread-2": "other"}}
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": implementation}
	stopped := make(chan error, 1)
	go func() {
		result, err := c.methodAgentRuntimeStop(context.Background(), map[string]any{"provider": "codex", "session_id": id})
		if err == nil && result["stopped"] != true {
			err = errors.New("not stopped")
		}
		stopped <- err
	}()
	request := receiveMap(t, received)
	if request["method"] != "turn/interrupt" || mapParam(request, "params")["threadId"] != "thread-1" || mapParam(request, "params")["turnId"] != "turn-1" {
		t.Fatalf("wrong native stop: %v", request)
	}
	implementation.forwardEvent(codexTurnEvent("turn/completed", "thread-1", "stale-turn", "completed"))
	select {
	case err := <-stopped:
		t.Fatalf("RPC ack or stale event counted as stop: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	implementation.forwardEvent(codexTurnEvent("turn/completed", "thread-1", "turn-1", "interrupted"))
	select {
	case request = <-received:
		if request["method"] != "thread/backgroundTerminals/clean" || mapParam(request, "params")["threadId"] != "thread-1" {
			t.Fatalf("wrong background stop target: %v", request)
		}
	case err := <-stopped:
		t.Fatalf("turn interruption acknowledged stop while native terminal still runs: %v", err)
	case <-time.After(time.Second):
		t.Fatal("background terminal stop was not requested")
	}
	select {
	case err := <-stopped:
		t.Fatalf("stop acknowledged before terminal cleanup: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	if err := background.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("background fixture exited before cleanup: %v", err)
	}
	cleanAllowed <- struct{}{}

	select {
	case err := <-stopped:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("terminal event did not settle stop")
	}
	select {
	case <-runtime.done:
		t.Fatal("shared runtime killed")
	default:
	}
	if other.workState != "running" || other.activeTurnID != "turn-2" {
		t.Fatal("other Session changed")
	}
	if err := otherBackground.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("other thread's native terminal stopped: %v", err)
	}
	if c.externalRuntimeState.watched("codex", id) {
		t.Fatal("stopped turn can still recover")
	}
	if _, ok := implementation.sessions[id]; ok || implementation.threads["thread-1"] == id {
		t.Fatal("stopped turn remained in the active session index")
	}
	select {
	case <-backgroundDone:
	default:
		t.Fatal("stop left native background terminal alive")
	}
}

func TestStopCannotConfirmAnUnobservedNativeProcess(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	id := canonicalStopSessionID(t)
	record := testRecoveryObligationRecord("pi", id, "dispatch-1", "execution-1")
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": newPiRuntimeImplementation(c)}
	if _, err := c.methodAgentRuntimeStop(context.Background(), map[string]any{"provider": "pi", "session_id": id}); err == nil {
		t.Fatal("missing native evidence counted as stop")
	}

}

func TestCodexSettledTurnCleanupFailureRemainsRetryable(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	requests := make(chan map[string]any, 2)
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		for attempt := 0; ; attempt++ {
			var request map[string]any
			if err := ws.ReadJSON(&request); err != nil {
				return
			}
			requests <- request
			response := map[string]any{"id": request["id"], "result": map[string]any{}}
			if attempt == 0 {
				response = map[string]any{"id": request["id"], "error": map[string]any{"code": -32601, "message": "cleanup unavailable"}}
			}
			if err := ws.WriteJSON(response); err != nil {
				return
			}
		}
	}))
	defer server.Close()
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	runtime := &codexRuntime{ws: ws, done: make(chan struct{}), nextID: 1, pending: map[string]chan map[string]any{}}
	defer runtime.close()
	go runtime.readLoop(ws)
	id := canonicalStopSessionID(t)
	record := testRecoveryObligationRecord("codex", id, "dispatch-1", "execution-1")
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	session := &codexRuntimeSession{sessionID: id, runtime: runtime, threadID: "thread-1", workState: "settled", recoveryInput: record.input()}
	implementation := &codexRuntimeImplementation{connector: c, sessions: map[string]*codexRuntimeSession{id: session}, sessionOrder: []string{id}}
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": implementation}
	if result, err := c.methodAgentRuntimeStop(context.Background(), map[string]any{"provider": "codex", "session_id": id}); err == nil || result != nil {
		t.Fatalf("failed terminal cleanup reported success: %v %v", result, err)
	}
	if !c.externalRuntimeState.watched("codex", id) {
		t.Fatal("failed cleanup discarded retry ownership")
	}
	if _, err := c.methodAgentRuntimeStop(context.Background(), map[string]any{"provider": "codex", "session_id": id}); err != nil {
		t.Fatal(err)
	}
	if c.externalRuntimeState.watched("codex", id) {
		t.Fatal("successful retry did not retire execution")
	}
	for range 2 {
		request := receiveMap(t, requests)
		if request["method"] != "thread/backgroundTerminals/clean" || mapParam(request, "params")["threadId"] != "thread-1" {
			t.Fatalf("settled turn must clean only its own terminals: %v", request)
		}
	}
}

func TestClaudeQuietWaitsForNativeBackgroundWork(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	implementation := newClaudeRuntimeImplementation(c)
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"claude": implementation}
	cmd := exec.Command("cat")
	configureProcessGroup(cmd)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	session := &claudeRuntimeSession{connector: c, sessionID: "background-session", nativeID: "native-background", cmd: cmd, stdin: stdin, done: make(chan struct{}), workState: "settled"}
	defer session.stop()
	go func() {
		err := cmd.Wait()
		session.mu.Lock()
		session.processErr = err
		session.mu.Unlock()
		close(session.done)
	}()
	implementation.sessionSlot(session.sessionID).session = session
	session.handleMessage(map[string]any{"type": "system", "subtype": "background_tasks_changed", "tasks": []any{map[string]any{"task_id": "background-1", "ambient": true}}})
	for _, selected := range []string{"", session.sessionID} {
		if err := implementation.quietSessions(context.Background(), selected); !errors.Is(err, errRuntimeNotQuiet) {
			t.Fatalf("background work accepted quiet: %v", err)
		}
	}
	if err := cmd.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("quiet stopped background process: %v", err)
	}
	session.handleMessage(map[string]any{"type": "system", "subtype": "turn_starting", "mode": "task-notification"})
	session.handleMessage(map[string]any{"type": "system", "subtype": "background_tasks_changed", "tasks": []any{}})
	if err := implementation.quietSessions(context.Background(), session.sessionID); !errors.Is(err, errRuntimeNotQuiet) {
		t.Fatalf("notification turn accepted quiet: %v", err)
	}
	session.handleMessage(map[string]any{"type": "result", "subtype": "success"})
	if err := implementation.quietSessions(context.Background(), session.sessionID); err != nil {
		t.Fatalf("completed native work failed drain: %v", err)
	}
	select {
	case <-session.done:
	default:
		t.Fatal("quiet acknowledged before native process exited")
	}
}
