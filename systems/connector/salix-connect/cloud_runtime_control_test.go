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

	"github.com/gorilla/websocket"
)

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
	cloudControlForTest(t, c, "seal", "", 1)
	c.closeRuntimes()
	c, err = newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	launched := filepath.Join(t.TempDir(), "launched")
	command := filepath.Join(t.TempDir(), "claude")
	if err := os.WriteFile(command, []byte("#!/bin/sh\ntouch "+shellQuote(launched)+"\necho 0.1.0\n"), 0700); err != nil {
		t.Fatal(err)
	}
	target := runtimeProbeTarget{provider: "claude", identityMaterial: command}
	observed := c.runtimeInventory.run(target)
	if observed["readiness_issue"] != "cloud_runtime_sealed" {
		t.Fatal(observed)
	}
	if _, err := os.Stat(launched); !os.IsNotExist(err) {
		t.Fatal("sealed observation launched CLI")
	}
	cloudControlForTest(t, c, "open", "", 2)
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
	// State from an earlier release proves this disk admitted work.
	writeFixtureFile(t, filepath.Join(root, legacyExternalRuntimeDir, "state.db"), "legacy")
	writeFixtureFile(t, filepath.Join(root, cloudRuntimeFreshRelativePath), "")
	c, err := newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	if result := cloudControlForTest(t, c, "seal", "", 1); result["never_admitted"] != false {
		t.Fatal("empty control metadata misclassified existing owned state", result)
	}
}

func TestCloudRuntimeAdmissionBirthAndRestart(t *testing.T) {
	isolateHostRuntimeCommands(t)
	for _, fresh := range []bool{false, true} {
		t.Run(map[bool]string{false: "legacy", true: "fresh"}[fresh], func(t *testing.T) {
			root := t.TempDir()
			t.Setenv("HOME", filepath.Join(root, "home"))
			t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(root, "deps"))
			if fresh {
				writeFixtureFile(t, filepath.Join(root, cloudRuntimeFreshRelativePath), "")
			}
			cfg := config{root: root, name: "admission-fixture"}
			c, err := newConnector(cfg)
			if err != nil {
				t.Fatal(err)
			}
			server := httptest.NewServer(c.vmHTTPHandler(context.Background()))
			wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
			if fresh {
				_, response, err := websocket.DefaultDialer.Dial(wsURL, nil)
				if err == nil || response.StatusCode != 409 {
					t.Fatal("fresh target admitted ordinary connection")
				}
			}
			result := cloudControlForTest(t, c, "seal", "", 1)
			if result["never_admitted"] != fresh {
				t.Fatalf("wrong initial fact: %v", result)
			}
			// Repair handshakes do not grant business admission or launch probes.
			repair, _, err := websocket.DefaultDialer.Dial(wsURL+"?archive_repair=true", nil)
			if err != nil {
				t.Fatal(err)
			}
			var meta message
			if err := repair.ReadJSON(&meta); err != nil {
				t.Fatal(err)
			}
			repair.Close()
			result = cloudControlForTest(t, c, "seal", "", 1)
			if result["never_admitted"] != fresh {
				t.Fatal("repair handshake changed admission")
			}
			cloudControlForTest(t, c, "open", "", 2)
			ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
			if err != nil {
				t.Fatal(err)
			}
			if err := ws.ReadJSON(&meta); err != nil {
				t.Fatal(err)
			}
			ws.Close()
			server.Close()
			if result = cloudControlForTest(t, c, "seal", "", 3); result["never_admitted"] != false {
				t.Fatal("ordinary handshake did not persist admission")
			}
			c.closeRuntimes()
			c, err = newConnector(cfg)
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeRuntimes()
			if result = cloudControlForTest(t, c, "seal", "", 3); result["never_admitted"] != false {
				t.Fatal("restart lost admission")
			}
			cloudControlForTest(t, c, "open", "", 4)
			if result = cloudControlForTest(t, c, "seal", "", 5); result["never_admitted"] != false {
				t.Fatal("new revision cleared admission")
			}
		})
	}
}

func TestArchiveRejectsLocalControl(t *testing.T) {
	isolateHostRuntimeCommands(t)
	for _, entry := range []string{cloudRuntimeFreshRelativePath, "cloud-runtime-control.json"} {
		t.Run(entry, func(t *testing.T) {
			c, err := newConnector(config{root: t.TempDir()})
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeRuntimes()
			packed := makeTarGz(t, []tarEntry{{name: entry, data: []byte(`{"sealed":false}`)}})
			if err := restoreTarGzOwned(bytes.NewReader(packed), c.root, c); err == nil {
				t.Fatal("accepted local control")
			}
		})
	}
}

func writeFixtureFile(t *testing.T, path, value string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(value), 0600); err != nil {
		t.Fatal(err)
	}
}

func cloudControlForTest(t *testing.T, c *connector, action, scope string, revision int64) map[string]any {
	t.Helper()
	raw, _ := json.Marshal(map[string]any{"action": action, "scope": scope, "control": cloudRuntimeControl{OwnerID: "fixture-owner", OperationID: "fixture-operation", Generation: 1, Revision: revision}})
	out := httptest.NewRecorder()
	c.handleCloudRuntimeControl(out, httptest.NewRequest(http.MethodPost, "/control", bytes.NewReader(raw)))
	if out.Code != 200 {
		t.Fatalf("control %s: %d %s", action, out.Code, out.Body.String())
	}
	var body map[string]any
	if err := json.Unmarshal(out.Body.Bytes(), &body); err != nil {
		t.Fatal(err)
	}
	return body
}

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
	c.cloudRuntimeParkUntil = testLongAgo
	c.cloudRuntimeMu.Unlock()
	c.closeRuntimes()
	c, err = newConnector(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
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
}
