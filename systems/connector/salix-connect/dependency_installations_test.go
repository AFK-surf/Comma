package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
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
	script := "#!/bin/sh\necho started > '" + started + "'\n(sleep 1; echo late > '" + late + "') &\nwait\n"
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
	deadline := time.Now().Add(2 * time.Second)
	for !exists(started) && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if !exists(started) {
		t.Fatal("installer did not start")
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
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		result, err := c.methodDependencyInstallations(map[string]any{"action": "list"})
		if err != nil {
			t.Fatal(err)
		}
		if strings.Contains(result.(map[string]any)["installation"].(map[string]any)["status"].(string), "cancelled") {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	time.Sleep(1100 * time.Millisecond)
	if exists(late) {
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
	restarted.startDependencyInstallLocked(manifest)
	time.Sleep(50 * time.Millisecond)
	if restarted.dependencyInstall.Total != 0 {
		t.Fatal("restart queued cancelled install")
	}
}
