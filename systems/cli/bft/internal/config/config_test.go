package config

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestPersistUsesOwnerOnlyPermissions(t *testing.T) {
	path := filepath.Join(t.TempDir(), "cli.json")

	if err := Persist(path, func(string) string { return "" }, Config{
		APIBaseURL: "https://bft.example.test",
		Token:      "secret-token",
		ExpiresAt:  "2026-06-24T00:00:00Z",
	}); err != nil {
		t.Fatalf("Persist() error = %v", err)
	}

	stat, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat persisted config: %v", err)
	}
	if got := stat.Mode().Perm(); got != 0o600 {
		t.Fatalf("mode = %v, want 0600", got)
	}

	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read persisted config: %v", err)
	}
	var cfg Config
	if err := json.Unmarshal(body, &cfg); err != nil {
		t.Fatalf("config JSON invalid: %v", err)
	}
	if cfg.Token != "secret-token" {
		t.Fatalf("token = %q", cfg.Token)
	}
}

func TestResolveBaseURLPrefersExplicitURLOverBadEnvironment(t *testing.T) {
	base, err := ResolveBaseURL(
		Options{URL: "https://self-hosted.example.test/", EnvName: "qa"},
		Config{},
		func(string) string { return "" },
	)
	if err != nil {
		t.Fatalf("ResolveBaseURL() error = %v", err)
	}
	if base != "https://self-hosted.example.test" {
		t.Fatalf("base = %q", base)
	}
}

func TestResolveBaseURLReportsUnknownEnvironment(t *testing.T) {
	_, err := ResolveBaseURL(Options{EnvName: "qa"}, Config{}, func(string) string { return "" })
	if err == nil {
		t.Fatal("expected error")
	}
	if _, ok := err.(UnknownEnvironmentError); !ok {
		t.Fatalf("error = %T, want UnknownEnvironmentError", err)
	}
}
