package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

func TestCloudRuntimeIdleExitsCodexButNotContendedAuth(t *testing.T) {
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
	defer c.closeRuntimes()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	unlock := c.runtimeAuthCoordinator().lockTarget(target.key())
	checked := make(chan error, 1)
	go func() { checked <- c.quietManagedCloudRuntimes() }()
	// An idle check that waited for the held authentication lock never
	// returns; the go test timeout reports it.
	err = <-checked
	unlock()
	if err == nil {
		t.Fatal("contended authentication was treated as idle")
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
	if err := c.quietManagedCloudRuntimes(); err != nil {
		t.Fatal(err)
	}
	<-done
}

func TestCloudRuntimeExpiredDecisionCannotReleaseActiveHold(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	c, err := newConnector(config{name: "cloud-expiry", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	params := map[string]any{"token": "old-decision"}
	if _, err := c.methodCloudRuntimeLifecycle(context.Background(), "cloud_runtime_quiesce", params); err != nil {
		t.Fatal(err)
	}
	c.cloudRuntimeParkUntil = testLongAgo
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

func TestCloudRuntimeIdleFencesAdmission(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	c, err := newConnector(config{name: "cloud-idle", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	ctx := context.Background()
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_quiesce", map[string]any{"token": "park-1"}); err != nil {
		t.Fatal(err)
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

func TestManagedCloudQuietWithoutSpriteHold(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	c, err := newConnector(config{name: "managed-quiet", root: t.TempDir()})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
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
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_resume", map[string]any{"token": "stale"}); err == nil {
		t.Fatal("stale archive decision resumed runtime")
	}
	if _, err := c.methodCloudRuntimeLifecycle(ctx, "cloud_runtime_resume", map[string]any{"token": "archive"}); err != nil {
		t.Fatal(err)
	}
}
