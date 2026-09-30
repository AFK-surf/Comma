package runtimeinputs

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestGenerateTracksOnlyRealClassInputs(t *testing.T) {
	root := inputFixture(t)
	before := mustGenerate(t, root)

	writeFixture(t, root, "unrelated/server.ex", "changed")
	assertDigests(t, before, mustGenerate(t, root), nil)

	writeFixture(t, root, "scripts/build-runtime-images.sh", "shared recipe changed")
	afterRecipe := mustGenerate(t, root)
	assertDigests(t, before, afterRecipe, map[string]bool{"external": true, "meeting": true, "shell": true})

	writeFixture(t, root, "systems/runtime-images/cmd/comma-shell-runtime/main.go", "shell changed")
	afterShell := mustGenerate(t, root)
	assertDigests(t, afterRecipe, afterShell, map[string]bool{"shell": true})

	writeFixture(t, root, "systems/connector/salix-connect/main.go", "connector changed")
	afterConnector := mustGenerate(t, root)
	assertDigests(t, afterShell, afterConnector, map[string]bool{"external": true, "meeting": true})
}

func TestGenerateTracksSelectedLockedDependencies(t *testing.T) {
	root := inputFixture(t)
	before := mustGenerate(t, root)
	lockPath := filepath.Join(root, "systems/runtime-images/runtime-dependencies.lock.json")
	var lock map[string]any
	data, err := os.ReadFile(lockPath)
	if err != nil {
		t.Fatal(err)
	}
	if err := json.Unmarshal(data, &lock); err != nil {
		t.Fatal(err)
	}
	lock["meetnative"].(map[string]any)["revision"] = "new-revision"
	encoded, err := json.Marshal(lock)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(lockPath, encoded, 0o644); err != nil {
		t.Fatal(err)
	}
	assertDigests(t, before, mustGenerate(t, root), map[string]bool{"meeting": true})
}

func TestGenerateIsStable(t *testing.T) {
	root := inputFixture(t)
	assertDigests(t, mustGenerate(t, root), mustGenerate(t, root), nil)
}

func inputFixture(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	files := map[string]string{
		"scripts/build-runtime-images.sh":                            "shared build recipe",
		"systems/runtime-images/external/Dockerfile":                 "external",
		"systems/runtime-images/meeting/Dockerfile":                  "meeting",
		"systems/runtime-images/shell/Dockerfile":                    "shell",
		"systems/runtime-images/go.mod":                              "module fixture",
		"systems/runtime-images/cmd/comma-shell-runtime/main.go":       "shell source",
		"systems/runtime-images/cmd/comma-meeting-runtime/main.go":     "meeting source",
		"systems/connector/salix-connect/go.mod":                     "connector module",
		"systems/connector/salix-connect/main.go":                    "connector source",
		"systems/connector/salix-connect/native/ignored-native-file": "ignored",
	}
	for path, body := range files {
		writeFixture(t, root, path, body)
	}
	lock := map[string]any{
		"schemaVersion": float64(1),
		"baseImages": map[string]any{
			"go": "go@sha256:1", "external": "node@sha256:2",
			"meeting": "debian@sha256:3", "shell": "alpine@sha256:4",
		},
		"npm":                map[string]any{"integrity": "npm"},
		"npmSecurityPatches": map[string]any{"integrity": "patches"},
		"codex":              map[string]any{"integrity": "codex"},
		"claude":             map[string]any{"integrity": "claude"},
		"pi":                 map[string]any{"integrity": "pi"},
		"meetnative":         map[string]any{"revision": "meeting-revision"},
	}
	encoded, err := json.Marshal(lock)
	if err != nil {
		t.Fatal(err)
	}
	writeFixture(t, root, "systems/runtime-images/runtime-dependencies.lock.json", string(encoded))
	return root
}

func writeFixture(t *testing.T, root, path, body string) {
	t.Helper()
	absolute := filepath.Join(root, filepath.FromSlash(path))
	if err := os.MkdirAll(filepath.Dir(absolute), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(absolute, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func mustGenerate(t *testing.T, root string) Manifest {
	t.Helper()
	manifest, err := Generate(root)
	if err != nil {
		t.Fatal(err)
	}
	return manifest
}

func assertDigests(t *testing.T, before, after Manifest, changed map[string]bool) {
	t.Helper()
	if len(before.Images) != len(after.Images) {
		t.Fatalf("image counts differ: %d != %d", len(before.Images), len(after.Images))
	}
	for index, left := range before.Images {
		right := after.Images[index]
		if left.Class != right.Class {
			t.Fatalf("classes differ: %q != %q", left.Class, right.Class)
		}
		if (left.InputDigest != right.InputDigest) != changed[left.Class] {
			t.Errorf("class %s changed=%v, want %v", left.Class, left.InputDigest != right.InputDigest, changed[left.Class])
		}
	}
}
