package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"slices"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestRuntimeInventorySingleflightsSameTarget(t *testing.T) {
	inventory := newRuntimeInventory()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: "/test/codex"}
	inventory.runtimes[target.key()] = map[string]any{
		"provider": "codex", "identity_material": "/test/codex",
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var starts atomic.Int32
	inventory.run = func(target runtimeProbeTarget) map[string]any {
		starts.Add(1)
		close(entered)
		<-release
		return map[string]any{
			"provider": target.provider, "identity_material": target.identityMaterial, "ready": true,
		}
	}

	result := make(chan error, 1)
	go func() {
		_, err := inventory.probeOne(context.Background(), target, "operator")
		result <- err
	}()
	<-entered
	waiterCtx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, err := inventory.probeOne(waiterCtx, target, "periodic"); !errors.Is(err, context.Canceled) {
		t.Fatalf("concurrent waiter error = %v, want cancellation while sharing the in-flight probe", err)
	}
	if starts.Load() != 1 {
		t.Fatalf("native probe starts before release = %d, want 1", starts.Load())
	}
	close(release)
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	if starts.Load() != 1 {
		t.Fatalf("native probe starts = %d, want 1", starts.Load())
	}
}

func TestRuntimeInventoryRetriesSupersededGenerationEpoch(t *testing.T) {
	inventory := newRuntimeInventory()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: "/test/codex"}
	inventory.runtimes[target.key()] = map[string]any{
		"provider": "codex", "identity_material": target.identityMaterial, "ready": false,
	}
	var runs atomic.Int32
	inventory.run = func(target runtimeProbeTarget) map[string]any {
		run := runs.Add(1)
		return map[string]any{
			"provider":                     target.provider,
			"identity_material":            target.identityMaterial,
			"ready":                        run > 1,
			runtimeProbeGenerationEvidence: "generation-1",
			runtimeProbeAuthEpochEvidence:  uint64(run - 1),
		}
	}
	inventory.commitGuard = func(
		_ runtimeProbeTarget,
		_ string,
		authEpoch uint64,
		_ map[string]any,
		commit func(),
	) bool {
		if authEpoch == 0 {
			return false
		}
		commit()
		return true
	}

	runtime, err := inventory.probeOne(context.Background(), target, "operator")
	if err != nil {
		t.Fatal(err)
	}
	if runs.Load() != 2 || runtime["ready"] != true {
		t.Fatalf("superseded probe retry runs=%d runtime=%#v", runs.Load(), runtime)
	}
	if _, exists := runtime[runtimeProbeAuthEpochEvidence]; exists {
		t.Fatalf("private auth epoch leaked in probe result: %#v", runtime)
	}
}

type countingProbeContext struct {
	context.Context
	calls      atomic.Int32
	first      chan struct{}
	second     chan struct{}
	firstOnce  sync.Once
	secondOnce sync.Once
}

func newCountingProbeContext() *countingProbeContext {
	return &countingProbeContext{
		Context: context.Background(),
		first:   make(chan struct{}),
		second:  make(chan struct{}),
	}
}

func (ctx *countingProbeContext) Done() <-chan struct{} {
	call := ctx.calls.Add(1)
	ctx.firstOnce.Do(func() { close(ctx.first) })
	if call >= 2 {
		ctx.secondOnce.Do(func() { close(ctx.second) })
	}
	return ctx.Context.Done()
}

func waitForProbeContextCall(t *testing.T, observed <-chan struct{}, description string) {
	t.Helper()
	select {
	case <-observed:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func TestRuntimeInventoryJoinedStaleProbeRetriesForAllCallers(t *testing.T) {
	inventory := newRuntimeInventory()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: "/test/codex"}
	inventory.runtimes[target.key()] = map[string]any{
		"provider": target.provider, "identity_material": target.identityMaterial, "ready": false,
	}
	firstEntered, firstRelease := make(chan struct{}), make(chan struct{})
	secondEntered, secondRelease := make(chan struct{}), make(chan struct{})
	var runs atomic.Int32
	inventory.run = func(target runtimeProbeTarget) map[string]any {
		run := runs.Add(1)
		switch run {
		case 1:
			close(firstEntered)
			<-firstRelease
		case 2:
			close(secondEntered)
			<-secondRelease
		}
		return map[string]any{
			"provider":                     target.provider,
			"identity_material":            target.identityMaterial,
			"ready":                        run == 2,
			runtimeProbeGenerationEvidence: "generation-1",
			runtimeProbeAuthEpochEvidence:  uint64(run - 1),
		}
	}
	inventory.commitGuard = func(
		_ runtimeProbeTarget,
		_ string,
		authEpoch uint64,
		_ map[string]any,
		commit func(),
	) bool {
		if authEpoch == 0 {
			return false
		}
		commit()
		return true
	}

	firstCtx, secondCtx := newCountingProbeContext(), newCountingProbeContext()
	type probeResult struct {
		runtime map[string]any
		err     error
	}
	results := make(chan probeResult, 2)
	go func() {
		runtime, err := inventory.probeOne(firstCtx, target, "operator")
		results <- probeResult{runtime: runtime, err: err}
	}()
	<-firstEntered
	go func() {
		runtime, err := inventory.probeOne(secondCtx, target, "periodic")
		results <- probeResult{runtime: runtime, err: err}
	}()
	waitForProbeContextCall(t, secondCtx.first, "second caller to join the stale probe")
	close(firstRelease)
	<-secondEntered
	waitForProbeContextCall(t, firstCtx.second, "first caller to retry the stale probe")
	waitForProbeContextCall(t, secondCtx.second, "second caller to retry the stale probe")
	close(secondRelease)

	for range 2 {
		result := <-results
		if result.err != nil || result.runtime["ready"] != true {
			t.Fatalf("joined stale probe result = %#v, %v", result.runtime, result.err)
		}
	}
	if runs.Load() != 2 {
		t.Fatalf("joined stale probe native runs = %d, want one stale plus one shared retry", runs.Load())
	}
}

func TestRuntimeInventoryJoinedNoRetryProbeReturnsCacheForAllCallers(t *testing.T) {
	inventory := newRuntimeInventory()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: "/test/codex"}
	inventory.runtimes[target.key()] = map[string]any{
		"provider": target.provider, "identity_material": target.identityMaterial,
		"ready": false, "auth": map[string]any{"status": "error", "issue": "login_failed"},
	}
	entered, release := make(chan struct{}), make(chan struct{})
	var runs atomic.Int32
	inventory.run = func(target runtimeProbeTarget) map[string]any {
		runs.Add(1)
		close(entered)
		<-release
		return map[string]any{
			"provider":                     target.provider,
			"identity_material":            target.identityMaterial,
			"ready":                        true,
			runtimeProbeGenerationEvidence: "generation-1",
			runtimeProbeAuthEpochEvidence:  uint64(0),
			runtimeProbeNoRetryEvidence:    true,
		}
	}
	inventory.commitGuard = func(_ runtimeProbeTarget, _ string, _ uint64, _ map[string]any, _ func()) bool {
		return false
	}

	firstCtx, secondCtx := newCountingProbeContext(), newCountingProbeContext()
	results := make(chan map[string]any, 2)
	errs := make(chan error, 2)
	go func() {
		runtime, err := inventory.probeOne(firstCtx, target, "operator")
		results <- runtime
		errs <- err
	}()
	<-entered
	go func() {
		runtime, err := inventory.probeOne(secondCtx, target, "periodic")
		results <- runtime
		errs <- err
	}()
	waitForProbeContextCall(t, secondCtx.first, "second caller to join the no-retry probe")
	close(release)

	for range 2 {
		if err := <-errs; err != nil {
			t.Fatalf("joined no-retry probe error = %v", err)
		}
		runtime := <-results
		if runtime["ready"] != false || mapParam(runtime, "auth")["issue"] != "login_failed" {
			t.Fatalf("joined no-retry probe did not return safe cache: %#v", runtime)
		}
	}
	if runs.Load() != 1 || firstCtx.calls.Load() != 1 || secondCtx.calls.Load() != 1 {
		t.Fatalf("joined no-retry probe retried: runs=%d first_calls=%d second_calls=%d", runs.Load(), firstCtx.calls.Load(), secondCtx.calls.Load())
	}
}

func TestOperatorProbePublishesMetadataBeforeReturning(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: "/test/codex"}
	c.runtimeInventory.runtimes[target.key()] = map[string]any{
		"provider": "codex", "identity_material": "/test/codex", "ready": false,
	}
	c.runtimeInventory.run = func(target runtimeProbeTarget) map[string]any {
		return map[string]any{
			"provider": target.provider, "identity_material": target.identityMaterial,
			"ready": true, "status": "available", "readiness_checked_at": time.Now().UnixMilli(),
		}
	}

	sent := make(chan message, 1)
	session := newConnectionSession(c, context.Background(), func(_ context.Context, msg message) error {
		sent <- msg
		return nil
	}, nil)
	defer session.close(context.Canceled)
	returned := make(chan error, 1)
	go func() {
		_, err := c.methodRuntimeProbe(context.Background(), session, map[string]any{
			"provider": "codex", "identity_material": "/test/codex",
		})
		returned <- err
	}()

	select {
	case msg := <-sent:
		if msg.Type != "metadata" {
			t.Fatalf("first frame type = %q, want metadata", msg.Type)
		}
		runtimes := msg.Capabilities["agent_runtimes"].([]map[string]any)
		if len(runtimes) != 1 || runtimes[0]["ready"] != true {
			t.Fatalf("published runtimes = %#v", runtimes)
		}
		if runtimes[0]["probe_trigger"] != "operator" {
			t.Fatalf("published probe trigger = %#v, want operator", runtimes[0]["probe_trigger"])
		}
		if _, ok := runtimes[0]["probe_duration_ms"].(int64); !ok {
			t.Fatalf("published probe duration = %#v, want int64", runtimes[0]["probe_duration_ms"])
		}
	case err := <-returned:
		t.Fatalf("probe returned before metadata was sent: %v", err)
	}
	if err := <-returned; err != nil {
		t.Fatal(err)
	}
}

func TestCachedRuntimeMetadataDoesNotReplayProbeEvidence(t *testing.T) {
	inventory := newRuntimeInventory()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: "/test/codex"}
	inventory.runtimes[target.key()] = map[string]any{
		"provider": "codex", "identity_material": target.identityMaterial,
	}
	inventory.run = func(target runtimeProbeTarget) map[string]any {
		return map[string]any{
			"provider": target.provider, "identity_material": target.identityMaterial, "ready": true,
		}
	}

	probed, err := inventory.probe(context.Background(), target.provider, target.identityMaterial, "operator")
	if err != nil {
		t.Fatal(err)
	}
	if _, ok := probed[0][runtimeProbeFrameEvidence].(*runtimeProbePublication); probed[0]["probe_trigger"] != "operator" || !ok {
		t.Fatalf("probe result evidence = %#v", probed[0])
	}
	cached := inventory.snapshot()[0]
	if _, ok := cached["probe_trigger"]; ok {
		t.Fatalf("cached runtime replayed probe trigger: %#v", cached)
	}
	if _, ok := cached["probe_duration_ms"]; ok {
		t.Fatalf("cached runtime replayed probe duration: %#v", cached)
	}
}

func TestRuntimeInventoryAppliesWorkspaceReadinessToEveryProbePath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	logPath := filepath.Join(t.TempDir(), "fake-codex.log")
	codex := fakeCodexCommand(t, logPath, map[string]string{
		"SALIX_TEST_FAKE_CODEX_VERSION": "codex-cli 1.2.3",
	})
	t.Setenv("PATH", filepath.Dir(codex))
	workspaceRoot := filepath.Join(home, ".comma", "workspaces")
	if err := os.MkdirAll(filepath.Dir(workspaceRoot), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(workspaceRoot, []byte("unavailable\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	c, err := newConnector(config{name: "laptop", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	assertWorkspaceUnavailable := func(trigger string, provider, identityMaterial string) {
		t.Helper()
		runtimes, err := c.runtimeInventory.probe(context.Background(), provider, identityMaterial, trigger)
		if err != nil {
			t.Fatal(err)
		}
		if len(runtimes) != 1 || runtimes[0]["ready"] != false || runtimes[0]["status"] != "unavailable" || runtimes[0]["readiness_issue"] != "workspace_unavailable" {
			t.Fatalf("%s probe ignored workspace readiness: %#v", trigger, runtimes)
		}
	}

	assertWorkspaceUnavailable("connect", "", "")
	metadataRuntimes := c.metadata().Capabilities["agent_runtimes"].([]map[string]any)
	if len(metadataRuntimes) != 1 || metadataRuntimes[0]["readiness_issue"] != "workspace_unavailable" {
		t.Fatalf("metadata did not retain workspace readiness: %#v", metadataRuntimes)
	}
	if err := os.Remove(workspaceRoot); err != nil {
		t.Fatal(err)
	}
	metadataRuntimes = c.metadata().Capabilities["agent_runtimes"].([]map[string]any)
	if metadataRuntimes[0]["readiness_issue"] != "workspace_unavailable" {
		t.Fatalf("metadata cache read changed workspace readiness: %#v", metadataRuntimes)
	}
	if _, err := os.Stat(workspaceRoot); !os.IsNotExist(err) {
		t.Fatalf("metadata cache read retried workspace preparation: %v", err)
	}
	runtimes, err := c.runtimeInventory.probe(context.Background(), "codex", codex, "operator")
	if err != nil {
		t.Fatal(err)
	}
	if len(runtimes) != 1 || runtimes[0]["ready"] != true || runtimes[0]["status"] != "available" {
		t.Fatalf("operator probe did not observe workspace recovery: %#v", runtimes)
	}
	if err := os.RemoveAll(workspaceRoot); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(workspaceRoot, []byte("unavailable again\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	assertWorkspaceUnavailable("periodic", "", "")
}

func TestRuntimeProbeReportsSafeWorkspaceMessageWhenHomeIsUnset(t *testing.T) {
	t.Setenv("HOME", "")
	logPath := filepath.Join(t.TempDir(), "fake-codex.log")
	codex := fakeCodexCommand(t, logPath, map[string]string{
		"SALIX_TEST_FAKE_CODEX_VERSION": "codex-cli 1.2.3",
	})
	t.Setenv("PATH", filepath.Dir(codex))

	report := runtimeProbeReport()
	runtimes, ok := report["agent_runtimes"].([]map[string]any)
	if !ok || len(runtimes) != 1 {
		t.Fatalf("agent_runtimes = %#v, want the actual discovered Codex runtime", report["agent_runtimes"])
	}
	runtime := runtimes[0]
	if runtime["readiness_issue"] != "workspace_unavailable" {
		t.Fatalf("readiness_issue = %#v, want workspace_unavailable", runtime["readiness_issue"])
	}
	if runtime["readiness_message"] != "HOME is not set; the external runtime workspace root cannot be resolved." {
		t.Fatalf("readiness_message = %#v", runtime["readiness_message"])
	}
	if data := fmt.Sprint(runtime); strings.Contains(data, "/Users/") || strings.Contains(data, "token") {
		t.Fatalf("public workspace diagnostic leaked private data: %s", data)
	}
}

func TestConnectorHealthIsBoundedSnapshot(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()

	health := c.connectorHealth()
	want := []string{
		"schema_version", "observed_at", "process_started_at", "request_inflight",
		"request_capacity", "runtime_proxy_inflight", "runtime_proxy_capacity",
		"managed_processes", "resumable_runtime_sessions", "recoverable_runtime_sessions", "pending_input_batches",
		"pending_runtime_events", "runtime_settlements_action_required", "oldest_runtime_settlement_seconds",
		"runtime_host_orphans", "runtime_host_orphans_action_required",
	}
	if len(health) != len(want) {
		t.Fatalf("health fields = %#v", health)
	}
	for _, key := range want {
		if _, ok := health[key]; !ok {
			t.Fatalf("health missing %q: %#v", key, health)
		}
	}
}

func TestRuntimeSessionSnapshotFollowsDurableOwnershipAndExactRuntime(t *testing.T) {
	root := t.TempDir()
	c, err := newConnector(config{name: "laptop", root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	targets := []runtimeProbeTarget{
		{provider: "codex", identityMaterial: "/runtime/a"},
		{provider: "codex", identityMaterial: "/runtime/b"},
	}
	for _, target := range targets {
		c.runtimeInventory.runtimes[target.key()] = map[string]any{
			"provider": target.provider, "identity_material": target.identityMaterial,
		}
	}

	firstID, secondID := canonicalSessionID(2), canonicalSessionID(1)
	if err := c.externalRuntimeState.watch(testRecoveryRecord(firstID, "/runtime/a")); err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.watch(testRecoveryRecord(secondID, "/runtime/a")); err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.watch(testRecoveryRecord(canonicalSessionID(3), "/unmatched")); err != nil {
		t.Fatal(err)
	}

	runtimes := c.metadata().Capabilities["agent_runtimes"].([]map[string]any)
	first := runtimes[0]["session_snapshot"].(map[string]any)
	second := runtimes[1]["session_snapshot"].(map[string]any)
	if !reflect.DeepEqual(first["session_ids"], []string{secondID, firstID}) || first["session_count"] != 2 || first["truncated"] != false {
		t.Fatalf("exact runtime snapshot = %#v", first)
	}
	if !reflect.DeepEqual(second["session_ids"], []string{}) || second["session_count"] != 0 {
		t.Fatalf("unmatched ownership leaked to another runtime: %#v", second)
	}
	if keys := sortedMapKeys(first); !reflect.DeepEqual(keys, []string{"observed_at", "schema_version", "session_count", "session_ids", "truncated"}) {
		t.Fatalf("snapshot exposed private fields: %v", keys)
	}
	observedAt := first["observed_at"].(int64)
	unchanged := c.metadata().Capabilities["agent_runtimes"].([]map[string]any)[0]["session_snapshot"].(map[string]any)
	if unchanged["observed_at"] != observedAt {
		t.Fatalf("metadata read changed ownership observation time: before=%d after=%v", observedAt, unchanged["observed_at"])
	}

	c.externalRuntimeState.forget("codex", firstID)
	first = c.metadata().Capabilities["agent_runtimes"].([]map[string]any)[0]["session_snapshot"].(map[string]any)
	if !reflect.DeepEqual(first["session_ids"], []string{secondID}) || first["session_count"] != 1 {
		t.Fatalf("snapshot after durable forget = %#v", first)
	}
	if first["observed_at"].(int64) <= observedAt {
		t.Fatalf("ownership observation time did not advance: before=%d after=%d", observedAt, first["observed_at"])
	}
	c.closeExternalRuntimes()

	restarted, err := newConnector(config{name: "laptop", root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer restarted.closeExternalRuntimes()
	for _, target := range targets {
		restarted.runtimeInventory.runtimes[target.key()] = map[string]any{
			"provider": target.provider, "identity_material": target.identityMaterial,
		}
	}
	first = restarted.metadata().Capabilities["agent_runtimes"].([]map[string]any)[0]["session_snapshot"].(map[string]any)
	if !reflect.DeepEqual(first["session_ids"], []string{secondID}) || first["session_count"] != 1 {
		t.Fatalf("restart did not rebuild durable ownership: %#v", first)
	}
}

func TestRuntimeAuthNonReadySnapshotsInvalidateDispatch(t *testing.T) {
	for _, status := range []string{"unknown", "configured", "unauthenticated", "pending", "error"} {
		t.Run(status, func(t *testing.T) {
			inventory := newRuntimeInventory()
			target := runtimeProbeTarget{provider: "codex", identityMaterial: "/native/codex"}
			inventory.runtimes[target.key()] = map[string]any{"ready": true, "auth_ready": true}
			inventory.updateAuthSnapshot(target, map[string]any{"status": status}, false)
			if inventory.runtimes[target.key()]["ready"] != false || inventory.runtimes[target.key()]["auth_ready"] != false {
				t.Fatal("non-ready auth left dispatch enabled")
			}
		})
	}
}

func TestRuntimeSessionSnapshotEnforcesPerRuntimeAndFrameBounds(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()

	for runtimeIndex := range 5 {
		target := runtimeProbeTarget{provider: "codex", identityMaterial: fmt.Sprintf("/runtime/%d", runtimeIndex)}
		c.runtimeInventory.runtimes[target.key()] = map[string]any{
			"provider": target.provider, "identity_material": target.identityMaterial,
		}
		for sessionIndex := range 65 {
			record := testRecoveryRecord(canonicalSessionID(runtimeIndex*100+sessionIndex), target.identityMaterial)
			c.externalRuntimeState.mu.Lock()
			c.externalRuntimeState.addRuntimeSessionLocked(externalRuntimeIdentityFromRecovery(record))
			c.externalRuntimeState.mu.Unlock()
		}
	}
	c.externalRuntimeState.mu.Lock()
	c.externalRuntimeState.rebuildRuntimeSessionSnapshotsLocked()
	c.externalRuntimeState.markSessionsObservedLocked()
	c.externalRuntimeState.mu.Unlock()

	runtimes := c.metadata().Capabilities["agent_runtimes"].([]map[string]any)
	total := 0
	for index, runtime := range runtimes {
		snapshot := runtime["session_snapshot"].(map[string]any)
		ids := snapshot["session_ids"].([]string)
		if len(ids) > externalRuntimeSessionsPerRuntime {
			t.Fatalf("runtime %d returned %d session ids", index, len(ids))
		}
		total += len(ids)
		if snapshot["session_count"] != 65 || snapshot["truncated"] != true {
			t.Fatalf("runtime %d bound metadata = %#v", index, snapshot)
		}
	}
	if total != externalRuntimeSessionsPerMetadata {
		t.Fatalf("metadata returned %d ids, want %d", total, externalRuntimeSessionsPerMetadata)
	}
}

func testRecoveryRecord(sessionID, command string) externalRuntimeRecoveryRecord {
	return externalRuntimeRecoveryRecord{
		Provider: "codex", SessionID: sessionID, Token: "capability", Command: command,
		Workspace: "/workspace", Payload: map[string]any{"thread_id": "thread-" + sessionID},
	}
}

func canonicalSessionID(index int) string {
	return fmt.Sprintf("ses1_%019d", index+1)
}

func sortedMapKeys(value map[string]any) []string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	slices.Sort(keys)
	return keys
}
