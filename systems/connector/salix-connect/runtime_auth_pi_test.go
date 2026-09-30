package main

import (
	"bytes"
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestRuntimeAuthPiNativeCommit(t *testing.T) {
	sdkEntry := os.Getenv("COMMA_PI_TEST_SDK")
	if sdkEntry == "" {
		t.Skip("set COMMA_PI_TEST_SDK to run the packaged Pi SDK integration")
	}
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal(err)
	}
	for _, allowed := range []bool{false, true} {
		t.Run(map[bool]string{false: "fenced", true: "committed"}[allowed], func(t *testing.T) {
			directory := t.TempDir()
			path := filepath.Join(directory, "auth.json")
			previous := []byte(`{"openrouter":{"type":"api_key","key":"old-test-key"},"other":{"type":"api_key","key":"retained-test-key"}}`)
			if err := os.WriteFile(path, previous, 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			fences := 0
			result := saveRuntimeAuthPi(ctx, node, sdkEntry, path, runtimeAuthPiEntry{Type: "api_key", Key: "new-test-key"}, func(stage string) runtimeAuthSaveOutcome {
				fences++
				if !allowed {
					return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
				}
				return commitRuntimeAuthFile(ctx, stage, path)
			})
			if fences != 1 {
				t.Fatalf("commit fence called %d times; result=%+v", fences, result)
			}
			got, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if !allowed {
				if result.SaveResult != "not_committed" || !bytes.Equal(got, previous) {
					t.Fatalf("fenced save changed native file: %+v", result)
				}
			} else {
				if result.SaveResult != "committed" || result.Issue != "" {
					t.Fatalf("save=%+v", result)
				}
				var content map[string]runtimeAuthPiEntry
				if err := json.Unmarshal(got, &content); err != nil {
					t.Fatal(err)
				}
				if content["openrouter"].Key != "new-test-key" || content["other"].Key != "retained-test-key" {
					t.Fatal("selected backend replacement did not preserve the other backend")
				}
				info, err := os.Stat(path)
				if err != nil || info.Mode().Perm() != 0600 {
					t.Fatal("native credentials are not private")
				}
			}
			entries, err := os.ReadDir(directory)
			if err != nil || len(entries) != 1 || entries[0].Name() != "auth.json" {
				t.Fatal("private staging or lock residue remained")
			}
		})
	}
}

func TestRuntimeAuthPiInputRejectsExecutableFields(t *testing.T) {
	for _, data := range []string{`{"type":"api_key","key":"!command"}`, `{"type":"api_key","key":"$TOKEN"}`, `{"type":"api_key","key":"value","env":{}}`, `{"type":"oauth","key":"value"}`, `{"type":"api_key","Key":"value"}`} {
		if _, err := parseRuntimeAuthPiEntry([]byte(data)); err == nil {
			t.Fatal("unsupported Pi credential accepted")
		}
	}
	if _, err := parseRuntimeAuthPiEntry([]byte(`{"type":"api_key","key":"synthetic-literal-key"}`)); err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeAuthPiFencedMissingFile(t *testing.T) {
	sdkEntry := os.Getenv("COMMA_PI_TEST_SDK")
	if sdkEntry == "" {
		t.Skip("set COMMA_PI_TEST_SDK to run the packaged Pi SDK integration")
	}
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	path := filepath.Join(directory, "auth.json")
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	result := saveRuntimeAuthPi(ctx, node, sdkEntry, path, runtimeAuthPiEntry{Type: "api_key", Key: "synthetic-key"}, func(string) runtimeAuthSaveOutcome {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	})
	if result.SaveResult != "not_committed" || result.Issue != "target_changed" {
		t.Fatalf("fenced missing file save=%+v", result)
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 0 {
		t.Fatal("fenced save created native state or left private residue")
	}
}

func TestRuntimeAuthPiCancelAtCommitBoundary(t *testing.T) {
	sdkEntry := os.Getenv("COMMA_PI_TEST_SDK")
	if sdkEntry == "" {
		t.Skip("set COMMA_PI_TEST_SDK to run the packaged Pi SDK integration")
	}
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal(err)
	}
	for _, afterCommit := range []bool{false, true} {
		t.Run(map[bool]string{false: "cancel_before_rename", true: "cancel_after_rename"}[afterCommit], func(t *testing.T) {
			directory := t.TempDir()
			path := filepath.Join(directory, "auth.json")
			previous := []byte(`{"openrouter":{"type":"api_key","key":"old-test-key"}}`)
			if err := os.WriteFile(path, previous, 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			result := saveRuntimeAuthPi(ctx, node, sdkEntry, path, runtimeAuthPiEntry{Type: "api_key", Key: "new-test-key"}, func(stage string) runtimeAuthSaveOutcome {
				if !afterCommit {
					cancel()
				}
				result := commitRuntimeAuthFile(ctx, stage, path)
				if afterCommit {
					cancel()
				}
				return result
			})
			got, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if afterCommit {
				if result.SaveResult != "committed" || bytes.Equal(got, previous) {
					t.Fatalf("cancel concealed a committed write: %+v", result)
				}
			} else if result.SaveResult != "not_committed" || !bytes.Equal(got, previous) {
				t.Fatalf("cancel before rename modified credentials: %+v", result)
			}
			// Process termination may leave the SDK's stale lock; only the owner-created
			// temporary secret is ours to remove. Never remove a lock owned by another process.
			stages, err := filepath.Glob(filepath.Join(directory, ".auth-input-*"))
			if err != nil || len(stages) != 0 {
				t.Fatal("cancellation left private staging material")
			}
		})
	}
}

func TestRuntimeAuthPiUsesNativeSDKDirectory(t *testing.T) {
	sdk := os.Getenv("COMMA_PI_TEST_SDK")
	if sdk == "" {
		t.Skip("set COMMA_PI_TEST_SDK to run the packaged Pi SDK integration")
	}
	directory := filepath.Join(t.TempDir(), "native-agent")
	t.Setenv("PI_CODING_AGENT_DIR", directory)
	command := filepath.Join(filepath.Dir(sdk), "bundle", "cli.js")
	link := filepath.Join(t.TempDir(), "pi")
	if err := os.Symlink(command, link); err != nil {
		t.Fatal(err)
	}
	expectedSDK, err := filepath.EvalSymlinks(sdk)
	if err != nil {
		t.Fatal(err)
	}
	_, gotSDK, path, err := runtimeAuthPiLocation(context.Background(), link)
	if err != nil || gotSDK != expectedSDK || path != filepath.Join(directory, "auth.json") {
		t.Fatalf("native directory resolution failed: %v", err)
	}
	if _, err := os.Stat(directory); !os.IsNotExist(err) {
		t.Fatal("location discovery materialized native credential state")
	}
	if _, _, _, err := runtimeAuthPiLocation(context.Background(), "/unsupported/wrapper"); err == nil {
		t.Fatal("unsupported launcher silently selected another auth location")
	}
}

func TestRuntimeAuthPiVerifyRejectsIndirectNativeCredential(t *testing.T) {
	sdk := os.Getenv("COMMA_PI_TEST_SDK")
	if sdk == "" {
		t.Skip("set COMMA_PI_TEST_SDK to run the packaged Pi SDK integration")
	}
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal(err)
	}
	directory := t.TempDir()
	path := filepath.Join(directory, "auth.json")
	previous := []byte(`{"openrouter":{"type":"api_key","key":"!must-not-execute"}}`)
	if err := os.WriteFile(path, previous, 0600); err != nil {
		t.Fatal(err)
	}
	result := verifyRuntimeAuthPi(context.Background(), node, sdk, path, "openai/gpt-4.1-nano")
	if result.Status != "error" || result.Issue != "invalid_format" {
		t.Fatalf("indirect credential verification=%+v", result)
	}
	got, err := os.ReadFile(path)
	if err != nil || !bytes.Equal(got, previous) {
		t.Fatal("verification modified native credentials")
	}
}
