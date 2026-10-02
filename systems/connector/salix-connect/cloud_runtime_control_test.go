package main

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCloudRuntimeSealSurvivesRestartAndRequiresNextOwnerPermit(t *testing.T) {
	isolateHostRuntimeCommands(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	root := t.TempDir()
	cfg := config{name: "sealed-restart", root: root, externalStateRoot: filepath.Join(root, "state")}
	c, err := newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	permit := cloudRuntimeControl{OwnerID: "workload-test", OperationID: "wake-test", Generation: 1, Revision: 1}
	request := func(c *connector, action string, value cloudRuntimeControl) *httptest.ResponseRecorder {
		t.Helper()
		raw, _ := json.Marshal(map[string]any{"action": action, "control": value})
		out := httptest.NewRecorder()
		c.handleCloudRuntimeControl(out, httptest.NewRequest(http.MethodPost, "/control", bytes.NewReader(raw)))
		return out
	}
	if out := request(c, "open", permit); out.Code != 200 {
		t.Fatal(out.Code, out.Body.String())
	}
	// A running owner request prevents quiet, but the failed seal must close admission.
	c.cloudRuntimeMu.Lock()
	c.cloudRuntimeRequests = 1
	c.cloudRuntimeMu.Unlock()
	if out := request(c, "seal", permit); out.Code != 409 {
		t.Fatal(out.Code, out.Body.String())
	}
	c.cloudRuntimeMu.Lock()
	c.cloudRuntimeRequests = 0
	c.cloudRuntimeParkUntil = time.Now().Add(-time.Hour)
	c.cloudRuntimeMu.Unlock()
	if _, err := c.methodAgentRuntimeInput(context.Background(), map[string]any{}); err == nil || !strings.Contains(err.Error(), "idle") {
		t.Fatalf("seal allowed input: %v", err)
	}
	c.closeExternalRuntimes()
	c, err = newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	if _, err := c.methodAgentRuntimeInput(context.Background(), map[string]any{}); err == nil || !strings.Contains(err.Error(), "idle") {
		t.Fatalf("restart lost seal: %v", err)
	}
	if out := request(c, "open", permit); out.Code != 409 {
		t.Fatal("sealed permit reopened", out.Code)
	}
	if out := request(c, "seal", permit); out.Code != 200 {
		t.Fatal("settled seal could not complete", out.Code, out.Body.String())
	}
	changed := permit
	changed.OwnerID = "another-owner"
	changed.Revision = 2
	if out := request(c, "open", changed); out.Code != 409 {
		t.Fatal("another owner opened target", out.Code)
	}
	next := permit
	next.OperationID = "wake-next"
	next.Revision = 2
	if out := request(c, "open", next); out.Code != 200 {
		t.Fatal(out.Code, out.Body.String())
	}
	if out := request(c, "seal", permit); out.Code != 409 {
		t.Fatal("old seal affected new permit", out.Code)
	}
	if _, err := c.methodAgentRuntimeInput(context.Background(), map[string]any{}); err == nil || strings.Contains(err.Error(), "idle") {
		t.Fatalf("new permit failed admission: %v", err)
	}
}

func TestCloudRuntimeSealedRestartProbeDoesNotLaunch(t *testing.T) {
	isolateHostRuntimeCommands(t)
	root := t.TempDir()
	t.Setenv("HOME", filepath.Join(root, "home"))
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(root, "deps"))
	cfg := config{root: root, name: "sealed-probe"}
	c, err := newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	recoveryControl(t, c, "seal", "", 1)
	c.closeExternalRuntimes()
	c, err = newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	launched := filepath.Join(t.TempDir(), "launched")
	command := filepath.Join(t.TempDir(), "pi")
	if err := os.WriteFile(command, []byte("#!/bin/sh\ntouch "+shellQuote(launched)+"\necho 0.1.0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	target := runtimeProbeTarget{provider: "pi", identityMaterial: command}
	observed := c.runtimeInventory.run(target)
	if observed["readiness_issue"] != "cloud_runtime_sealed" {
		t.Fatal(observed)
	}
	if _, err := os.Stat(launched); !os.IsNotExist(err) {
		t.Fatal("sealed observation launched CLI")
	}
	recoveryControl(t, c, "open", "", 2)
	c.runtimeInventory.run(target)
	if _, err := os.Stat(launched); err != nil {
		t.Fatal("control experiment did not exercise actual CLI probe", err)
	}
}

func TestCloudRuntimeFreshMarkerCannotEraseExistingState(t *testing.T) {
	isolateHostRuntimeCommands(t)
	root := t.TempDir()
	t.Setenv("HOME", filepath.Join(root, "home"))
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(root, "deps"))
	cfg := config{root: root}
	c, err := newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	record := testRecoveryObligationRecord("claude", "ses1_2098040323912503296", "dispatch", "execution")
	persistRuntimeIdentity(t, c.externalRuntimeState, externalRuntimeIdentityFromRecovery(record))
	c.closeExternalRuntimes()
	recoveryFixtureWrite(t, filepath.Join(root, cloudRuntimeFreshRelativePath), "")
	c, err = newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	if result := recoveryControl(t, c, "seal", "", 1); result["never_admitted"] != false {
		t.Fatal("empty control metadata misclassified existing owned state", result)
	}
}
