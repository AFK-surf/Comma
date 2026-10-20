package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func TestDependencyDeclarationPrunesDeletedSourceBeforeArchive(t *testing.T) {
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	c := &connector{root: t.TempDir()}
	venv := filepath.Join(c.root, "project", ".venv")
	if err := os.MkdirAll(venv, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(venv, "pyvenv.cfg"), []byte("home = /usr/bin"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := c.methodDependencyInstallations(map[string]any{
		"action": "declare", "path": venv, "kind": "repository", "manager": "pip",
		"working_directory": filepath.Dir(venv),
	}); err != nil {
		t.Fatal(err)
	}
	if err := c.prepareDependencyInstallationsForArchive(); err != nil {
		t.Fatal(err)
	}
	manifest, err := c.readDependencyManifest()
	if err != nil {
		t.Fatal(err)
	}
	entry := manifest.Entries["project/.venv"]
	if entry.Omitted || entry.RestorePending {
		t.Fatalf("source venv must be retained without restore work: %+v", entry)
	}
	archiveRaw, err := c.archivedDependencyManifest()
	if err != nil {
		t.Fatal(err)
	}
	var archived dependencyInstallManifest
	if err := json.Unmarshal(archiveRaw, &archived); err != nil {
		t.Fatal(err)
	}
	if archived.Entries["project/.venv"].RestorePending {
		t.Fatal("retained files gained restore work")
	}
	// A separate declaration removed by the agent before any archive must not
	// become an installation request on the next VM.
	other := filepath.Join(c.root, "project", "node_modules")
	if err := os.MkdirAll(other, 0o700); err != nil {
		t.Fatal(err)
	}
	if _, err := c.methodDependencyInstallations(map[string]any{
		"action": "declare", "path": other, "kind": "repository", "manager": "npm",
		"working_directory": filepath.Dir(other),
	}); err != nil {
		t.Fatal(err)
	}
	if err := os.RemoveAll(other); err != nil {
		t.Fatal(err)
	}
	if err := c.prepareDependencyInstallationsForArchive(); err != nil {
		t.Fatal(err)
	}
	manifest, err = c.readDependencyManifest()
	if err != nil {
		t.Fatal(err)
	}
	if _, found := manifest.Entries["project/node_modules"]; found {
		t.Fatal("deleted source dependency was retained")
	}
	if manifest.Entries["project/.venv"].RestorePending {
		t.Fatal("source incorrectly gained restore intent")
	}
	if err := os.RemoveAll(venv); err != nil {
		t.Fatal(err)
	}
	if err := c.prepareDependencyInstallationsForArchive(); err != nil {
		t.Fatal(err)
	}
	manifest, err = c.readDependencyManifest()
	if err != nil {
		t.Fatal(err)
	}
	if _, found := manifest.Entries["project/.venv"]; found {
		t.Fatal("deleted source venv retained after previous archive preparation")
	}
}

func TestCancelledInstallStopsItsChildBeforeAgentTakesOver(t *testing.T) {
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	c := &connector{root: t.TempDir()}
	bin := t.TempDir()
	started := filepath.Join(bin, "started")
	late := filepath.Join(bin, "late")
	release := filepath.Join(bin, "release")
	childPID := filepath.Join(bin, "child.pid")
	// The installer's background child writes only after the test releases it:
	// a child that cancellation killed never writes.
	script := "#!/bin/sh\n" +
		"sh -c 'while [ ! -e \"" + release + "\" ]; do sleep 0.01; done; echo late > \"" + late + "\"' &\n" +
		"echo $! > '" + childPID + "'\n" +
		"echo started > '" + started + "'\n" +
		"wait\n"
	if err := os.WriteFile(filepath.Join(bin, "npm"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin+string(os.PathListSeparator)+os.Getenv("PATH"))
	path := filepath.Join(c.root, ".salix", "sprite-home", ".local", "lib", "node_modules")
	if err := os.MkdirAll(path, 0o700); err != nil {
		t.Fatal(err)
	}
	manifest := dependencyInstallManifest{Entries: map[string]dependencyInstallation{
		".salix/sprite-home/.local/lib/node_modules": {
			Path: ".salix/sprite-home/.local/lib/node_modules", Kind: "tool", Manager: "npm",
			Packages: []string{"example"}, Omitted: true, RestorePending: true,
		},
	}}
	if err := c.writeDependencyManifest(manifest); err != nil {
		t.Fatal(err)
	}
	if _, err := c.methodDependencyInstallations(map[string]any{"action": "start"}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "the installer to start", func() bool { return fileExists(started) })
	pidData, err := os.ReadFile(childPID)
	if err != nil {
		t.Fatal(err)
	}
	child, err := strconv.Atoi(strings.TrimSpace(string(pidData)))
	if err != nil {
		t.Fatal(err)
	}
	beforeCancel, err := c.readDependencyManifest()
	if err != nil {
		t.Fatal(err)
	}
	if !beforeCancel.Entries[".salix/sprite-home/.local/lib/node_modules"].Attempted {
		t.Fatal("install start was not persisted before executing child")
	}
	if _, err := c.methodDependencyInstallations(map[string]any{"action": "cancel"}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "the installation to be cancelled", func() bool {
		result, err := c.methodDependencyInstallations(map[string]any{"action": "list"})
		if err != nil {
			t.Fatal(err)
		}
		return strings.Contains(result.(map[string]any)["installation"].(map[string]any)["status"].(string), "cancelled")
	})
	if err := os.WriteFile(release, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "the installer's background child to exit", func() bool {
		return syscall.Kill(child, 0) != nil
	})
	if fileExists(late) {
		t.Fatal("cancelled child continued writing")
	}
	restarted := &connector{root: c.root}
	manifest, err = restarted.readDependencyManifest()
	if err != nil {
		t.Fatal(err)
	}
	if !manifest.Entries[".salix/sprite-home/.local/lib/node_modules"].Paused {
		t.Fatal("cancel did not persist agent takeover")
	}
	// The start counts its queue before it returns.
	restarted.startDependencyInstallLocked(manifest)
	if restarted.dependencyInstall.Total != 0 {
		t.Fatal("restart queued cancelled install")
	}
}
