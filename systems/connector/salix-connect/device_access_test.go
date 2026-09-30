package main

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestDesktopDeviceAccessUsesMainWorkspaceOwner(t *testing.T) {
	called := false
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer main-test-token" {
			t.Error("missing Main credential")
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Error(err)
		}
		input := body["input"].(map[string]any)
		if input["workspaceId"] != "wsp_owned" || input["allow_operations"] != true {
			t.Errorf("wrong target: %#v", input)
		}
		called = true
		_, _ = w.Write([]byte(`{"allows_operations":true}`))
	}))
	defer server.Close()
	t.Setenv(commaClientControlURLEnv, server.URL)
	t.Setenv(commaClientControlTokenEnv, "main-test-token")
	c := &connector{cfg: config{deviceMode: true, configPath: "main-owned.json", deviceWorkspaceID: "wsp_owned"}, scope: scopeLocalFileRead}
	result, err := c.methodDeviceAccess(map[string]any{"allow_operations": true, "workspaceId": "wsp_other"})
	if err != nil {
		t.Fatal(err)
	}
	if !called || result.(map[string]any)["allows_operations"] != true {
		t.Fatal("did not use Main owner")
	}
	if c.currentScope() != scopeLocalFileRead {
		t.Fatal("remote request bypassed Main's scope command")
	}
}

func TestDeviceReadOnlyDiscoversWithoutExecutingAndReadsFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	bin := t.TempDir()
	marker := filepath.Join(home, "executed")
	if err := os.WriteFile(filepath.Join(bin, "codex"), []byte("#!/bin/sh\ntouch '"+marker+"'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
	root := t.TempDir()
	if err := os.WriteFile(filepath.Join(root, "hello.txt"), []byte("hello"), 0600); err != nil {
		t.Fatal(err)
	}
	c, err := newConnector(config{root: root, deviceMode: true, scope: scopeLocalFileRead})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	entries := c.metadata().Capabilities["agent_runtimes"].([]map[string]any)
	if len(entries) != 1 || entries[0]["provider"] != "codex" || entries[0]["readiness_issue"] != "permission_required" {
		t.Fatalf("inventory = %#v", entries)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("discovery executed the provider")
	}
	if _, err := c.dispatchSession(context.Background(), nil, "read", "read", map[string]any{"path": "hello.txt"}); err != nil {
		t.Fatal(err)
	}
	for _, method := range []string{"exec", "write", "agent_runtime_input"} {
		if _, err := c.dispatchSession(context.Background(), nil, "write", method, map[string]any{"path": "hello.txt", "content": "changed", "command": "touch touched"}); err == nil {
			t.Fatalf("read-only accepted %s", method)
		}
	}
	bytes, _ := os.ReadFile(filepath.Join(root, "hello.txt"))
	if string(bytes) != "hello" {
		t.Fatal("read-only modified file")
	}
}

func TestStandaloneDeviceAccessSurvivesRestart(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := config{root: t.TempDir(), deviceMode: true, scope: scopeLocalFileRead}
	c, err := newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}
	c.closeExternalRuntimes()
	c, err = newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	if c.currentScope() != "" {
		t.Fatal("lost granted permission")
	}
	if err := c.setCurrentScope(scopeLocalFileRead); err != nil {
		t.Fatal(err)
	}
	c.closeExternalRuntimes()
	c, err = newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	if c.currentScope() != scopeLocalFileRead {
		t.Fatal("lost revoked permission")
	}
}

func TestDeviceReadOnlyRejectsNativeRecoveryAdmission(t *testing.T) {
	c, err := newConnector(config{root: t.TempDir(), deviceMode: true, scope: scopeLocalFileRead})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	_, leave, admitted := c.deviceRuntimeAdmission(context.Background())
	leave()
	if admitted {
		t.Fatal("read-only admitted a native call")
	}
	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}
	ctx, leave, admitted := c.deviceRuntimeAdmission(context.Background())
	if !admitted {
		t.Fatal("allowed device rejected native call")
	}
	revoked := make(chan error, 1)
	go func() { revoked <- c.setCurrentScope(scopeLocalFileRead) }()
	<-ctx.Done()
	leave()
	if err := <-revoked; err != nil {
		t.Fatal(err)
	}
	_, leave, admitted = c.deviceRuntimeAdmission(context.Background())
	leave()
	if admitted {
		t.Fatal("permission withdrawal admitted a new native call")
	}
}

// The runtime database owns device-process exclusion, including concurrent
// installer retries. No installer PID file determines whether a device runs.
func TestDeviceInstallRetryUsesRuntimeStateLock(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	cfg := config{root: t.TempDir(), deviceMode: true, scope: scopeLocalFileRead}
	first, err := newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer first.closeExternalRuntimes()
	second, err := newConnector(cfg)
	if err == nil {
		second.closeExternalRuntimes()
		t.Fatal("a second Connector acquired the same device runtime state")
	}
	first.closeExternalRuntimes()
	recovered, err := newConnector(cfg)
	if err != nil {
		t.Fatalf("could not recover after the owner exited: %v", err)
	}
	recovered.closeExternalRuntimes()
}
