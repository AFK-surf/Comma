package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestManagedRuntimeDiscoveryPreservesBrokenPublishedEntries(t *testing.T) {
	root := t.TempDir()
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", root)
	for _, provider := range []string{"codex", "claude"} {
		path := filepath.Join(root, "installed-"+provider, "bin", provider)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(filepath.Join(root, "missing-package", provider), path); err != nil {
			t.Fatal(err)
		}
		paths := managedRuntimeCommands(provider)
		if len(paths) != 1 || paths[0] != path {
			t.Fatalf("published %s identity disappeared: %v", provider, paths)
		}
	}
	for _, id := range []string{"empty", ".unpublished"} {
		path := filepath.Join(root, id, "bin", "codex")
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if id != "empty" {
			if err := os.Symlink("missing", path); err != nil {
				t.Fatal(err)
			}
		}
	}
	if got := managedRuntimeCommands("codex"); len(got) != 1 {
		t.Fatalf("unpublished directories became targets: %v", got)
	}
}

func TestCodexManagedReadinessUsesSelectedGenerationVersion(t *testing.T) {
	for _, tc := range []struct {
		name, userAgent, accountType string
		broken, badVersion           bool
	}{
		{name: "broken-entry-default", broken: true},
		{name: "usable-user"},
		{name: "native-version", userAgent: "salix/9.8.7 (test)", badVersion: true},
		{name: "legacy-version-failed", badVersion: true},
		{name: "user-needs-auth", accountType: "none"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			fallback, nativeLog := harnessFallbackForTest(t, "codex")
			if tc.userAgent != "" || tc.accountType != "" {
				fallback = fakeCodexCommand(t, nativeLog, map[string]string{"SALIX_TEST_FAKE_CODEX_USER_AGENT": tc.userAgent, "SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": tc.accountType})
			}
			versionLog := filepath.Join(t.TempDir(), "version.log")
			selected := filepath.Join(t.TempDir(), "codex")
			versionExit := "0"
			if tc.badVersion {
				versionExit = "42"
			}
			script := "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then\n echo checked >> " + shellQuote(versionLog) + "\n echo 'codex selected 9.8.7'\n exit " + versionExit + "\nfi\nexec " + shellQuote(fallback) + " \"$@\"\n"
			if err := os.WriteFile(selected, []byte(script), 0755); err != nil {
				t.Fatal(err)
			}
			defaultMarker := filepath.Join(t.TempDir(), "default-called")
			unusedDefault := filepath.Join(t.TempDir(), "unused-default")
			if err := os.WriteFile(unusedDefault, []byte("#!/bin/sh\necho called > "+shellQuote(defaultMarker)+"\nexec "+shellQuote(fallback)+" \"$@\"\n"), 0755); err != nil {
				t.Fatal(err)
			}
			original := imageHarnessCommand
			imageHarnessCommand = func(string) string {
				if tc.broken {
					return selected
				}
				return unusedDefault
			}
			defer func() { imageHarnessCommand = original }()
			identity := selected
			if tc.broken {
				identity = filepath.Join(os.Getenv("SALIX_MANAGED_RUNTIME_ROOT"), "old-install", "bin", "codex")
				if err := os.MkdirAll(filepath.Dir(identity), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink("missing-codex-package", identity); err != nil {
					t.Fatal(err)
				}
			}
			c := harnessConnectorForTest(t)
			i := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
			target := runtimeProbeTarget{provider: "codex", identityMaterial: identity}
			first := i.probeRuntimeTarget(target)
			wantReady := (!tc.badVersion || tc.userAgent != "") && tc.accountType != "none"
			if first["ready"] != wantReady {
				t.Fatalf("selected readiness: %#v", first)
			}
			if first["command"] != identity || first["identity_material"] != identity {
				t.Fatalf("selected launch changed identity: %#v", first)
			}
			wantVersion := "codex selected 9.8.7"
			if tc.userAgent != "" {
				wantVersion = tc.userAgent
			}
			if first["version"] != wantVersion {
				t.Fatalf("version is not from selected command: %#v", first)
			}
			second := i.probeRuntimeTarget(target)
			if second[runtimeProbeGenerationEvidence] != first[runtimeProbeGenerationEvidence] || second["ready"] != wantReady {
				t.Fatalf("repeat readiness replaced the initialized generation: %#v", second)
			}
			data, _ := os.ReadFile(versionLog)
			checks := 1
			if tc.userAgent != "" {
				checks = 0
			}
			if strings.Count(string(data), "checked") != checks {
				t.Fatalf("version probe ran %d times: %s", checks, data)
			}
			if _, err := os.Stat(defaultMarker); !os.IsNotExist(err) {
				t.Fatal("readiness replaced an initialized user process")
			}
			starts, _ := os.ReadFile(nativeLog)
			if strings.Count(string(starts), "start\n") != 1 {
				t.Fatalf("readiness restarted native server: %s", starts)
			}
		})
	}
}

func readinessWrapperForTest(t *testing.T, provider, body string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), provider)
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body), 0755); err != nil {
		t.Fatal(err)
	}
	return path
}

func TestManagedPortableReadinessSelectsOnlyStartupFallback(t *testing.T) {
	for _, provider := range []string{"claude"} {
		for _, mode := range []string{"usable", "missing-entry", "failed-version", "bootstrap-failure"} {
			t.Run(provider+"/"+mode, func(t *testing.T) {
				user, _ := harnessFallbackForTest(t, provider)
				marker := filepath.Join(t.TempDir(), "fallback")
				fallback := readinessWrapperForTest(t, provider, "echo called >> "+shellQuote(marker)+"\nexec "+shellQuote(user)+" \"$@\"\n")
				imageHarnessCommand = func(string) string { return fallback }
				identity := user
				switch mode {
				case "missing-entry":
					identity = filepath.Join(t.TempDir(), provider)
					if err := os.Symlink("missing-package", identity); err != nil {
						t.Fatal(err)
					}
				case "failed-version":
					identity = readinessWrapperForTest(t, provider, "if [ \"$1\" = \"--version\" ]; then exit 42; fi\nexec "+shellQuote(user)+" \"$@\"\n")
				case "bootstrap-failure":
					identity = readinessWrapperForTest(t, provider, "exec /no-such-salix-harness \"$@\"\n")
				}
				runtime := portableRuntimeEntry(provider, identity, "native", []string{"stdio"})
				wantIssue := ""
				if mode == "failed-version" {
					wantIssue = "runtime_probe_failed"
				}
				if stringParam(runtime, "readiness_issue") != wantIssue || runtime["native_server_startable"] != true {
					t.Fatalf("selected readiness: %#v", runtime)
				}
				if runtime["command"] != identity || runtime["identity_material"] != identity {
					t.Fatalf("identity changed: %#v", runtime)
				}
				data, _ := os.ReadFile(marker)
				if mode == "missing-entry" || mode == "bootstrap-failure" {
					// Auth status and initialize select the native candidate; one
					// final version observation follows.
					if strings.Count(string(data), "called") != 3 {
						t.Fatalf("default attempts: %s", data)
					}
				} else if len(data) != 0 {
					t.Fatalf("usable user command was replaced: %s", data)
				}
			})
		}
	}
}

func TestManagedClaudeReadinessKeepsAuthAndConfigFailuresTerminal(t *testing.T) {
	for _, tc := range []struct {
		name, response, diagnostic string
		exit                       string
		fallback                   bool
	}{
		{"signed-out-with-bootstrap-exit", `{"loggedIn":false}`, "MODULE_NOT_FOUND", "127", false},
		{"config-error", "", "configuration invalid MODULE_NOT_FOUND", "1", false},
		{"malformed-response", "secret-token-not-json", "", "1", false},
		{"missing-module", "", "Error: MODULE_NOT_FOUND", "1", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			user, _ := harnessFallbackForTest(t, "claude")
			marker := filepath.Join(t.TempDir(), "default")
			fallback := readinessWrapperForTest(t, "claude", "echo called >> "+shellQuote(marker)+"\nexec "+shellQuote(user)+" \"$@\"\n")
			imageHarnessCommand = func(string) string { return fallback }
			command := readinessWrapperForTest(t, "claude", "if [ \"$1\" = \"--version\" ]; then echo user; exit 0; fi\necho "+shellQuote(tc.response)+"\necho "+shellQuote(tc.diagnostic)+" >&2\nexit "+tc.exit+"\n")
			runtime := portableRuntimeEntry("claude", command, "native", []string{"stdio"})
			if runtime["ready"] != tc.fallback {
				t.Fatalf("auth/bootstrap authority: %#v", runtime)
			}
			data, _ := os.ReadFile(marker)
			if (len(data) > 0) != tc.fallback {
				t.Fatalf("unexpected fallback: %s", data)
			}
			encoded, _ := json.Marshal(runtime)
			if strings.Contains(string(encoded), "secret-token") {
				t.Fatalf("auth output leaked: %s", encoded)
			}
		})
	}
}

func TestManagedPortableReadinessKeepsNativeRefusalTerminal(t *testing.T) {
	_, log := harnessFallbackForTest(t, "claude")
	auth := "if [ \"$1\" = \"auth\" ]; then echo '{\"loggedIn\":true,\"authMethod\":\"claude.ai\"}'; exit 0; fi\n"
	output := `{"type":"control_response","response":{"request_id":"salix-readiness","subtype":"error"}}`
	command := readinessWrapperForTest(t, "claude", "if [ \"$1\" = \"--version\" ]; then echo user; exit 0; fi\n"+auth+"read request\necho "+shellQuote(output)+"\nexit 0\n")
	runtime := portableRuntimeEntry("claude", command, "native", []string{"stdio"})
	if runtime["ready"] != false || runtime["readiness_issue"] == "verification_required" {
		t.Fatalf("native refusal hidden: %#v", runtime)
	}
	if data, err := os.ReadFile(log); err == nil {
		t.Fatalf("native refusal launched default: %s", data)
	}
}
