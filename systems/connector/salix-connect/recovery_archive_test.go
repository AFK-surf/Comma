package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
	bolt "go.etcd.io/bbolt"
)

func recoveryFixtureWrite(t *testing.T, path, value string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(value), 0600); err != nil {
		t.Fatal(err)
	}
}
func recoveryControl(t *testing.T, c *connector, action, scope string, revision int64) map[string]any {
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
func TestCloudRuntimeAdmissionBirthAndRestart(t *testing.T) {
	isolateHostRuntimeCommands(t)
	for _, fresh := range []bool{false, true} {
		t.Run(map[bool]string{false: "legacy", true: "fresh"}[fresh], func(t *testing.T) {
			root := t.TempDir()
			t.Setenv("HOME", filepath.Join(root, "home"))
			t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(root, "deps"))
			if fresh {
				recoveryFixtureWrite(t, filepath.Join(root, cloudRuntimeFreshRelativePath), "")
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
			result := recoveryControl(t, c, "seal", "", 1)
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
			result = recoveryControl(t, c, "seal", "", 1)
			if result["never_admitted"] != fresh {
				t.Fatal("repair handshake changed admission")
			}
			recoveryControl(t, c, "open", "", 2)
			ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
			if err != nil {
				t.Fatal(err)
			}
			if err := ws.ReadJSON(&meta); err != nil {
				t.Fatal(err)
			}
			ws.Close()
			server.Close()
			if result = recoveryControl(t, c, "seal", "", 3); result["never_admitted"] != false {
				t.Fatal("ordinary handshake did not persist admission")
			}
			c.closeExternalRuntimes()
			c, err = newConnector(cfg)
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeExternalRuntimes()
			if result = recoveryControl(t, c, "seal", "", 3); result["never_admitted"] != false {
				t.Fatal("restart lost admission")
			}
			recoveryControl(t, c, "open", "", 4)
			if result = recoveryControl(t, c, "seal", "", 5); result["never_admitted"] != false {
				t.Fatal("new revision cleared admission")
			}
		})
	}
}

func TestRecoveryArchiveRetainsNativeAndCredentialExceptions(t *testing.T) {
	isolateHostRuntimeCommands(t)
	root := t.TempDir()
	home := filepath.Join(root, "home")
	t.Setenv("HOME", home)
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(root, "deps"))
	native := filepath.Join(home, ".comma", "workspaces", "repository", "node_modules", "provider-state")
	t.Setenv("CLAUDE_CONFIG_DIR", native)
	c, err := newConnector(config{root: root, name: "recovery-fixture"})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	const id = "ses1_2098040323912503296"
	const nativeID = "9edcd2a2-5609-47f2-9f94-0588d1172331"
	history := filepath.Join(native, "projects", "project", nativeID+".jsonl")
	retained := []string{history, filepath.Join(native, "projects", "project", nativeID, "subagents", "child.jsonl"), filepath.Join(native, runtimeAuthClaudeCredentialsName), filepath.Join(native, runtimeAuthClaudeSettingsName), filepath.Join(native, "settings.json")}
	for _, p := range retained {
		recoveryFixtureWrite(t, p, "retained:"+filepath.Base(p))
	}
	discarded := []string{filepath.Join(c.externalWorkspaceRoot, "repository", "dirty.txt"), filepath.Join(native, "projects", "project", "unrelated.txt"), filepath.Join(root, "deps", "installed.js"), filepath.Join(c.workspaceArchiver.archive, "old.tar.gz")}
	for _, p := range discarded {
		recoveryFixtureWrite(t, p, "disposable")
	}
	recoveryFixtureWrite(t, filepath.Join(root, "owner-note"), "retain unknown file")
	record := testRecoveryObligationRecord("claude", id, "d", "e")
	record.Workspace = filepath.Join(c.externalWorkspaceRoot, "repository")
	record.Payload = map[string]any{"session_id": nativeID}
	persistRuntimeIdentity(t, c.externalRuntimeState, externalRuntimeIdentityFromRecovery(record))
	recoveryControl(t, c, "seal", "recovery", 1)
	recoveryFixtureWrite(t, filepath.Join(root, cloudRuntimeFreshRelativePath), "")
	var packed bytes.Buffer
	if err := writeTarTreesScope(context.Background(), &packed, []archiveTree{{root, "."}}, c.externalRuntimeState, migrationByteLimit, "gzip", "recovery"); err != nil {
		t.Fatal(err)
	}
	targetRoot := t.TempDir()
	target, err := newConnector(config{root: targetRoot, name: "recovery-target"})
	if err != nil {
		t.Fatal(err)
	}
	importRequest := func(c *connector, body map[string]any) map[string]any {
		t.Helper()
		body["operation"] = "recovery-import"
		raw, _ := json.Marshal(body)
		out := httptest.NewRecorder()
		c.handleProviderMigrationImport(out, httptest.NewRequest(http.MethodPost, "/archive", bytes.NewReader(raw)))
		if out.Code != 200 {
			t.Fatal(out.Code, out.Body.String())
		}
		var result map[string]any
		json.Unmarshal(out.Body.Bytes(), &result)
		return result
	}
	importRequest(target, map[string]any{"action": "part", "offset": 0, "data": base64.StdEncoding.EncodeToString(packed.Bytes())})
	result := importRequest(target, map[string]any{"action": "finish", "bytes": packed.Len(), "sessions": 1})
	if result["scope"] != "recovery" {
		t.Fatal("import receipt lost scope", result)
	}
	for _, p := range retained {
		rel, _ := filepath.Rel(root, p)
		if _, err := os.Stat(filepath.Join(targetRoot, rel)); err != nil {
			t.Fatalf("critical path pruned: %s: %v", rel, err)
		}
	}
	for _, p := range discarded {
		rel, _ := filepath.Rel(root, p)
		if _, err := os.Stat(filepath.Join(targetRoot, rel)); !os.IsNotExist(err) {
			t.Fatalf("disposable path retained: %s", rel)
		}
	}
	if _, err := os.Stat(filepath.Join(targetRoot, "owner-note")); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(targetRoot, cloudRuntimeFreshRelativePath)); !os.IsNotExist(err) {
		t.Fatal("source birth marker imported")
	}
	if target.cloudRuntimeControl != nil {
		t.Fatal("source control imported")
	}
	projection, err := target.readArchiveProjection()
	if err != nil || projection.Scope != "recovery" {
		t.Fatal(projection, err)
	}
	if !strings.Contains(target.peekWorkspaceRuntimeNotice(id), "were not preserved") {
		t.Fatal("missing recovery notice")
	}
	target.closeExternalRuntimes()
	target, err = newConnector(config{root: targetRoot, name: "recovery-target"})
	if err != nil {
		t.Fatal(err)
	}
	defer target.closeExternalRuntimes()
	if target.peekWorkspaceRuntimeNotice(id) == "" {
		t.Fatal("restart lost recovery notice")
	}
	if result := importRequest(target, map[string]any{"action": "status"}); result["scope"] != "recovery" || result["phase"] != "restored" {
		t.Fatal("restart lost receipt scope", result)
	}
	// Retained input/event obligations still reject the existing snapshot boundary.
	if err := c.externalRuntimeState.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeSessionEventsBucket).Put([]byte("unacked"), []byte(`{}`))
	}); err != nil {
		t.Fatal(err)
	}
	packed.Reset()
	if err := writeTarTreesScope(context.Background(), &packed, []archiveTree{{root, "."}}, c.externalRuntimeState, migrationByteLimit, "gzip", "recovery"); err == nil {
		t.Fatal("recovery checkpoint discarded unACK event")
	}
}

func TestArchiveRejectsDuplicateScopeAndLocalControl(t *testing.T) {
	isolateHostRuntimeCommands(t)
	for _, entry := range []string{archiveScopeRelativePath, cloudRuntimeFreshRelativePath, "cloud-runtime-control.json"} {
		t.Run(entry, func(t *testing.T) {
			c, err := newConnector(config{root: t.TempDir()})
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeExternalRuntimes()
			var packed bytes.Buffer
			gz := gzip.NewWriter(&packed)
			tw := tar.NewWriter(gz)
			for _, name := range []string{archiveScopeRelativePath, entry} {
				body := `{"scope":"full"}`
				if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0600, Typeflag: tar.TypeReg, Size: int64(len(body))}); err != nil {
					t.Fatal(err)
				}
				io.WriteString(tw, body)
			}
			tw.Close()
			gz.Close()
			if err := restoreTarGzState(bytes.NewReader(packed.Bytes()), c.root, c.externalRuntimeState); err == nil {
				t.Fatal("accepted duplicate scope or local control")
			}
		})
	}
}
