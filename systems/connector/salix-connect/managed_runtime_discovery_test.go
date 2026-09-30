package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

func TestManagedRuntimeDiscoveryFindsNewTargetsWithoutRestart(t *testing.T) {
	root := t.TempDir()
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", root)
	if got := managedRuntimeCommands("codex"); len(got) != 0 {
		t.Fatalf("empty managed root: %v", got)
	}
	for _, provider := range []string{"codex", "claude"} {
		path := filepath.Join(root, "worker-"+provider, "bin", provider)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
			t.Fatal(err)
		}
		found := false
		for _, target := range discoverAgentRuntimeTargets() {
			if target.provider == provider && target.identityMaterial == path {
				found = true
			}
		}
		if !found {
			t.Fatalf("new %s target not discovered at stable path %s", provider, path)
		}
	}
}

func TestManagedRuntimeDiscoveryBoundsDirectoryReads(t *testing.T) {
	root := t.TempDir()
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", root)
	for i := 0; i < 17; i++ {
		if err := os.Mkdir(filepath.Join(root, fmt.Sprint(i)), 0700); err != nil {
			t.Fatal(err)
		}
	}
	if got := managedRuntimeCommands("codex"); len(got) != 0 {
		t.Fatalf("overfull managed root must not publish partial inventory: %v", got)
	}
}
