package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCloudRuntimeIdleFencesAdmission(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	c, err := newConnector(config{name: "cloud-idle", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	ctx := context.Background()
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_quiesce", map[string]any{"token": "park-1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.methodAgentRuntimeInput(ctx, map[string]any{}); err == nil || !strings.Contains(err.Error(), "idle") {
		t.Fatalf("late input was not fenced: %v", err)
	}
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_release", map[string]any{"token": "old-token"}); err == nil {
		t.Fatal("stale release accepted")
	}
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_release", map[string]any{"token": "park-1"}); err != nil {
		t.Fatal(err)
	}
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_resume", map[string]any{"token": "park-1"}); err == nil {
		t.Fatal("released connector resumed")
	}
}

func TestCloudRuntimeRecoveryPreventsIdle(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	c, err := newConnector(config{name: "cloud-recovery", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	record := testRecoveryObligationRecord("codex", canonicalStopSessionID(t), "dispatch", "execution")
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	if err := c.quietManagedCloudRuntimes(context.Background()); err == nil {
		t.Fatal("unfinished recovery was declared idle")
	}
}

func TestCloudRuntimeIdleExitsCodexButNotAdmittedNativeCall(t *testing.T) {
	root := t.TempDir()
	command := filepath.Join(root, "test-codex", "bin", "codex")
	if err := os.MkdirAll(filepath.Dir(command), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(command, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", root)
	t.Setenv("HOME", t.TempDir())
	c, err := newConnector(config{name: "cloud-process", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	unlock := c.runtimeAuthCoordinator().lockTarget(target.key())
	checked := make(chan error, 1)
	go func() { checked <- c.quietManagedCloudRuntimes(context.Background()) }()
	select {
	case err := <-checked:
		unlock()
		if err == nil {
			t.Fatal("contended authentication was treated as idle")
		}
	case <-time.After(time.Second):
		unlock()
		<-checked
		t.Fatal("idle check blocked keepalive behind authentication")
	}
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	process := exec.Command("sleep", "60")
	configureProcessGroup(process)
	if err := process.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = process.Wait(); close(done) }()
	defer func() { killProcessGroup(process); <-done }()
	runtime := &codexRuntime{command: command, cmd: process}
	implementation.runtimes[command] = runtime
	leave := c.runtimeAuthCoordinator().enterNativeCall(runtimeProbeTarget{provider: "codex", identityMaterial: command})
	if err := c.quietManagedCloudRuntimes(context.Background()); err == nil {
		t.Fatal("admitted native call was reclaimed")
	}
	select {
	case <-done:
		t.Fatal("busy native process exited")
	default:
	}
	leave()
	if err := c.quietManagedCloudRuntimes(context.Background()); err != nil {
		t.Fatal(err)
	}
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("idle native process remained alive")
	}
}

func TestCloudRuntimeExpiredDecisionCannotReleaseActiveHold(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	c, err := newConnector(config{name: "cloud-expiry", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	params := map[string]any{"token": "old-decision"}
	if _, err := c.methodCloudRuntimeLifecycle(context.Background(), "cloud_runtime_quiesce", params); err != nil {
		t.Fatal(err)
	}
	c.cloudRuntimeParkUntil = time.Now().Add(-time.Second)
	if _, err := c.methodCloudRuntimeLifecycle(context.Background(), "cloud_runtime_release", params); err == nil {
		t.Fatal("expired decision released the hold")
	}
	if c.cloudRuntimeQuiesced {
		t.Fatal("expired decision still blocks work")
	}
	params["token"] = "new-decision"
	if _, err := c.methodCloudRuntimeLifecycle(context.Background(), "cloud_runtime_quiesce", params); err != nil {
		t.Fatal(err)
	}
	if _, err := c.methodCloudRuntimeLifecycle(context.Background(), "cloud_runtime_release", params); err != nil {
		t.Fatal(err)
	}
	// Simulate loss of that response. A later sweep can finish suspension.
	params["token"] = "recovery-decision"
	if _, err := c.methodCloudRuntimeLifecycle(context.Background(), "cloud_runtime_quiesce", params); err != nil {
		t.Fatal(err)
	}
	if _, err := c.methodCloudRuntimeLifecycle(context.Background(), "cloud_runtime_release", params); err != nil {
		t.Fatal(err)
	}
}

func TestManagedClaudeRetirementDoesNotStopAnotherTarget(t *testing.T) {
	c, err := newConnector(config{name: "claude-targets", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	implementation := c.runtimeImplementations["claude"].(*claudeRuntimeImplementation)
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Fatal(err)
	}
	commands := []string{filepath.Join(t.TempDir(), "target-a"), filepath.Join(t.TempDir(), "target-b")}
	for _, command := range commands {
		if err := os.Symlink(shell, command); err != nil {
			t.Fatal(err)
		}
		process := exec.Command(command, "-c", "sleep 60")
		configureProcessGroup(process)
		if err := process.Start(); err != nil {
			t.Fatal(err)
		}
		session := &claudeRuntimeSession{cmd: process, done: make(chan struct{}), workState: "running"}
		implementation.sessionSlot(command).session = session
		go func() { _ = process.Wait(); close(session.done) }()
	}
	other := implementation.sessions[commands[1]].session
	if err := implementation.retireManagedTarget(context.Background(), commands[0]); err != nil {
		t.Fatal(err)
	}
	select {
	case <-other.done:
		t.Fatal("unrelated Claude target was stopped")
	default:
	}
	if implementation.sessions[commands[0]].session != nil {
		t.Fatal("owned target was not retired")
	}
}

func TestManagedCloudQuietWithoutSpriteHold(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	c, err := newConnector(config{name: "managed-quiet", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	ctx := context.Background()
	first, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_quiesce", map[string]any{"token": "archive", "timeout_ms": 900_000})
	if err != nil {
		t.Fatal(err)
	}
	if first["continued"] != false {
		t.Fatalf("initial quiesce claimed continuation: %v", first)
	}
	renewed, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_quiesce", map[string]any{"token": "archive", "timeout_ms": 4_200_000})
	if err != nil || renewed["continued"] != true {
		t.Fatalf("exact quiesce did not renew: %v %v", renewed, err)
	}
	if _, err := c.methodAgentRuntimeInput(ctx, map[string]any{}); err == nil || !strings.Contains(err.Error(), "idle") {
		t.Fatalf("input crossed archive fence: %v", err)
	}
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_resume", map[string]any{"token": "stale"}); err == nil {
		t.Fatal("stale archive decision resumed runtime")
	}
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_resume", map[string]any{"token": "archive"}); err != nil {
		t.Fatal(err)
	}
	kimi := c.runtimeImplementations["kimi"].(*kimiRuntimeImplementation)
	kimi.sessions["unproven-native"] = &kimiRuntimeSlot{}
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_quiesce", map[string]any{"token": "another"}); err == nil {
		t.Fatal("unproven native session was treated as quiet")
	}
	delete(kimi.sessions, "unproven-native")
}
