package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestCleanupGeneratedHomeCaches(t *testing.T) {
	home := t.TempDir()
	cache := filepath.Join(home, ".npm", "_cacache", "content")
	keep := filepath.Join(home, "projects", "my-project", ".git", "config")
	for _, path := range []string{cache, keep} {
		if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("retained"), 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := cleanupGeneratedHomeCaches(home); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(cache); !os.IsNotExist(err) {
		t.Fatalf("generated cache remains: %v", err)
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("project data was removed: %v", err)
	}
}

func TestCleanupGeneratedHomeCachesRejectsSymlinkedParent(t *testing.T) {
	home := t.TempDir()
	outside := t.TempDir()
	keep := filepath.Join(outside, "_cacache", "content")
	if err := os.MkdirAll(filepath.Dir(keep), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(keep, []byte("retain"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(home, ".npm")); err != nil {
		t.Fatal(err)
	}
	if err := cleanupGeneratedHomeCaches(home); err == nil {
		t.Fatal("symlinked cache parent was accepted")
	}
	if _, err := os.Stat(keep); err != nil {
		t.Fatalf("outside data was removed: %v", err)
	}
}
