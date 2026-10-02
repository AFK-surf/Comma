package main

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Uses the same locked real CLIs as the migration contract test. The model is
// a local fixture; native history, credential/config resolution and resume are real.
func TestRecoveryArchiveNativeContinuation(t *testing.T) {
	cliDir := os.Getenv("COMMA_MIGRATION_NATIVE_CLI_DIR")
	if cliDir == "" {
		t.Skip("set COMMA_MIGRATION_NATIVE_CLI_DIR to the locked Linux CLI fixture")
	}
	for _, provider := range []string{"codex", "claude", "pi"} {
		t.Run(provider, func(t *testing.T) {
			requests := make(chan string, 16)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(io.LimitReader(r.Body, 4<<20))
				if !strings.Contains(string(body), "source-native-marker") && !strings.Contains(string(body), "target-native-marker") {
					w.Header().Set("Content-Type", "application/json")
					fmt.Fprint(w, `{"input_tokens":10}`)
					return
				}
				requests <- string(body)
				writeMigrationModelResponse(w, provider)
			}))
			defer server.Close()
			root := filepath.Join(t.TempDir(), "target")
			home := filepath.Join(root, "home")
			configureMigrationNativeHomeAt(t, home, provider, server.URL, "fixture")
			t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(root, "managed-deps"))
			command := filepath.Join(cliDir, provider)
			if provider == "claude" {
				wrapper := filepath.Join(t.TempDir(), "claude")
				script := "#!/bin/sh\nexport ANTHROPIC_BASE_URL=" + shellQuote(server.URL) + "\nexport ANTHROPIC_API_KEY=synthetic-fixture-key\nexec " + shellQuote(command) + " \"$@\"\n"
				if err := os.WriteFile(wrapper, []byte(script), 0700); err != nil {
					t.Fatal(err)
				}
				command = wrapper
			}
			makeConnector := func() *connector {
				c, err := newConnector(config{root: root, name: "native-recovery"})
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(c.closeExternalRuntimes)
				return c
			}
			source := makeConnector()
			const id = "ses1_2098040323912503296"
			workspace := filepath.Join(source.externalWorkspaceRoot, id)
			seedWorkspace(t, source.externalWorkspaceRoot, id)
			recoveryFixtureWrite(t, filepath.Join(workspace, "agent-local-edit.txt"), "disposable local edit")
			// Put Codex native state inside the disposable workspace. A finite retained
			// exception must preserve continuation and credentials through parent pruning.
			if provider == "codex" {
				old := os.Getenv("CODEX_HOME")
				nested := filepath.Join(workspace, "node_modules", "native-home")
				if err := os.MkdirAll(filepath.Dir(nested), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.Rename(old, nested); err != nil {
					t.Fatal(err)
				}
				t.Setenv("CODEX_HOME", nested)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 150*time.Second)
			defer cancel()
			nativeID := createMigrationNativeHistory(t, ctx, provider, command, workspace, filepath.Join(root, "external-runtime", "pi", id), "fixture", "source-native-marker")
			select {
			case <-requests:
			case <-ctx.Done():
				t.Fatal("source did not call model")
			}
			record := testRecoveryObligationRecord(provider, id, "source-dispatch", "source-execution")
			record.Command, record.Workspace, record.Payload = command, workspace, map[string]any{nativeMigrationIDKey(provider): nativeID}
			persistRuntimeIdentity(t, source.externalRuntimeState, externalRuntimeIdentityFromRecovery(record))
			recoveryControl(t, source, "seal", "recovery", 1)
			var packed bytes.Buffer
			if err := writeTarTreesScope(ctx, &packed, []archiveTree{{root, "."}}, source.externalRuntimeState, migrationByteLimit, "zstd", "recovery"); err != nil {
				t.Fatal(err)
			}
			source.closeExternalRuntimes()
			if err := os.Rename(root, root+".source"); err != nil {
				t.Fatal(err)
			}
			target := makeConnector()
			if err := restoreTarZstStateLimit(bytes.NewReader(packed.Bytes()), root, target.externalRuntimeState, migrationByteLimit); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(filepath.Join(workspace, "agent-local-edit.txt")); !os.IsNotExist(err) {
				t.Fatal("workspace local edit was preserved")
			}
			// Re-create the owner-approved disposable working directory. No source file
			// or provider native state is copied from the now inaccessible source root.
			if err := os.MkdirAll(workspace, 0700); err != nil {
				t.Fatal(err)
			}
			for round := 0; round < 2; round++ {
				identity := target.externalRuntimeState.identities[provider+"\x00"+id]
				if identity.Payload[nativeMigrationIDKey(provider)] != nativeID {
					t.Fatal("restored identity changed")
				}
				input := record.input()
				input.workspace, input.payload = identity.Workspace, maps.Clone(identity.Payload)
				input.dispatchID = fmt.Sprintf("target-%d", round)
				input.token = "target-token"
				input.modelProvider, input.model = "fixture", "fixture"
				if provider == "codex" {
					input.model = "gpt-5.3-codex"
				}
				input.messages = []map[string]any{{"role": "user", "content": fmt.Sprintf("target-native-marker-%d", round)}}
				payload, _, err := target.runtimeImplementations[provider].Send(ctx, input)
				if err != nil {
					t.Fatal(err)
				}
				if payload[nativeMigrationIDKey(provider)] != nativeID {
					t.Fatal("native resume created a new identity")
				}
				select {
				case request := <-requests:
					if !strings.Contains(request, "source-native-marker") || !strings.Contains(request, "native-fixture-answer") || !strings.Contains(request, fmt.Sprintf("target-native-marker-%d", round)) {
						t.Fatal("native history was lost")
					}
					if round == 1 && !strings.Contains(request, "target-native-marker-0") {
						t.Fatal("restart lost resumed turn")
					}
					if provider == "codex" && !strings.Contains(request, "data:image/") {
						t.Fatal("native continuation lost source image")
					}
				case <-ctx.Done():
					t.Fatal("native continuation did not reach model")
				}
				for target.externalRuntimeState.watched(provider, id) && ctx.Err() == nil {
					time.Sleep(10 * time.Millisecond)
				}
				if ctx.Err() != nil {
					t.Fatal("native turn did not settle")
				}
				if provider == "claude" {
					if err := target.runtimeImplementations[provider].(*claudeRuntimeImplementation).quietSessions(ctx, id); err != nil {
						t.Fatal(err)
					}
				}
				if round == 0 {
					target.closeExternalRuntimes()
					target = makeConnector()
					if target.peekWorkspaceRuntimeNotice(id) == "" {
						t.Fatal("restart lost recovery scope notice")
					}
				}
			}
		})
	}
}
