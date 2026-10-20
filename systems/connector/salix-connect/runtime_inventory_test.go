package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
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
	<-observed
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
	defer c.closeRuntimes()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: "/test/codex"}
	c.runtimeInventory.runtimes[target.key()] = map[string]any{
		"provider": "codex", "identity_material": "/test/codex", "ready": false,
	}
	sibling := runtimeProbeTarget{provider: "codex", identityMaterial: "/other/codex"}
	siblingObservation := map[string]any{
		"provider": "codex", "identity_material": sibling.identityMaterial,
		"ready": false, "version": "old-installation", "readiness_checked_at": int64(1),
	}
	c.runtimeInventory.runtimes[sibling.key()] = cloneRuntimeObservation(siblingObservation)
	c.runtimeInventory.run = func(target runtimeProbeTarget) map[string]any {
		if target.identityMaterial != "/test/codex" {
			t.Errorf("probe selected another installation: %q", target.identityMaterial)
		}
		return map[string]any{
			"provider": target.provider, "identity_material": target.identityMaterial,
			"ready": true, "status": "available", "version": "updated-installation",
			"readiness_checked_at": runtimeAuthTestObservedAt,
		}
	}

	sent := make(chan message, 1)
	session := newConnectionSession(c, context.Background(), func(_ context.Context, msg message) error {
		sent <- msg
		return nil
	}, nil)
	defer session.close(context.Canceled)
	returned := make(chan error, 1)
	replies := make(chan map[string]any, 1)
	go func() {
		reply, err := c.methodRuntimeProbe(context.Background(), session, map[string]any{
			"provider": "codex", "identity_material": "/test/codex",
		})
		replies <- reply
		returned <- err
	}()

	select {
	case msg := <-sent:
		if msg.Type != "metadata" {
			t.Fatalf("first frame type = %q, want metadata", msg.Type)
		}
		runtimes := msg.Capabilities["agent_runtimes"].([]map[string]any)
		if len(runtimes) != 2 {
			t.Fatalf("published runtimes = %#v", runtimes)
		}
		for _, runtime := range runtimes {
			if runtime["identity_material"] == sibling.identityMaterial {
				for key, value := range siblingObservation {
					if !reflect.DeepEqual(runtime[key], value) {
						t.Fatalf("unselected installation changed %s: got %#v, want %#v", key, runtime[key], value)
					}
				}
				continue
			}
			if runtime["identity_material"] != target.identityMaterial || runtime["ready"] != true || runtime["version"] != "updated-installation" {
				t.Fatalf("selected installation was not refreshed: %#v", runtime)
			}
			if runtime["probe_trigger"] != "operator" {
				t.Fatalf("published probe trigger = %#v, want operator", runtime["probe_trigger"])
			}
			if _, ok := runtime["probe_duration_ms"].(int64); !ok {
				t.Fatalf("published probe duration = %#v, want int64", runtime["probe_duration_ms"])
			}
		}
	case err := <-returned:
		t.Fatalf("probe returned before metadata was sent: %v", err)
	}
	if err := <-returned; err != nil {
		t.Fatal(err)
	}
	runtimes := (<-replies)["runtimes"].([]map[string]any)
	if len(runtimes) != 1 || runtimes[0]["provider"] != target.provider || runtimes[0]["identity_material"] != target.identityMaterial || runtimes[0]["ready"] != true || runtimes[0]["version"] != "updated-installation" {
		t.Fatalf("probe reply did not identify the refreshed installation: %#v", runtimes)
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
	defer c.closeRuntimes()
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
	defer c.closeRuntimes()

	health := c.connectorHealth()
	want := []string{
		"schema_version", "observed_at", "process_started_at", "request_inflight",
		"request_capacity", "runtime_proxy_inflight", "runtime_proxy_capacity",
		"managed_processes",
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
