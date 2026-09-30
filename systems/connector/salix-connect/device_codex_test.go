package main

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

func TestCodexEntrySurvivesStandaloneUpgrade(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	entryDir := t.TempDir()
	t.Setenv("PATH", entryDir)
	entry := filepath.Join(entryDir, "codex")
	otherEntry := filepath.Join(entryDir, "codex-other")

	for _, version := range []string{"old", "new"} {
		bundle := fakeCodexCommand(t, filepath.Join(t.TempDir(), "codex.log"), map[string]string{
			"SALIX_TEST_FAKE_CODEX_VERSION": version,
		})
		// The standalone CLI needs resources beside its actual executable.
		script, err := os.ReadFile(bundle)
		if err != nil {
			t.Fatal(err)
		}
		guard := "#!/bin/sh\ncase \"$1\" in app-server) test -x \"${0%/*}/codex-code-mode-host\" || exit 42;; esac\n"
		if err := os.WriteFile(bundle, []byte(guard+strings.TrimPrefix(string(script), "#!/bin/sh\n")), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(filepath.Dir(bundle), "codex-code-mode-host"), []byte("#!/bin/sh\nexit 0\n"), 0700); err != nil {
			t.Fatal(err)
		}
		for _, link := range []string{entry, otherEntry} {
			if err := os.Remove(link); err != nil && !os.IsNotExist(err) {
				t.Fatal(err)
			}
			if err := os.Symlink(bundle, link); err != nil {
				t.Fatal(err)
			}
		}
		if got := detectCodexCommands(); len(got) != 1 || got[0] != entry {
			t.Fatalf("%s discovery changed the selected entry: %v", version, got)
		}
		paths := appendUniquePath(nil, map[string]bool{}, entry)
		seen := map[string]bool{entry: true}
		if got := appendUniquePath(paths, seen, otherEntry); len(got) != 2 {
			t.Fatalf("independent entries were merged: %v", got)
		}
		ready := detectCodexReadiness(entry)
		if ready["ready"] != true || ready["version"] != version {
			t.Fatalf("%s readiness through entry: %#v", version, ready)
		}
		c, err := newConnector(config{root: t.TempDir()})
		if err != nil {
			t.Fatal(err)
		}
		impl := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
		rt, err := impl.ensureTargetRuntime(context.Background(), runtimeProbeTarget{provider: "codex", identityMaterial: entry})
		if err != nil {
			c.closeExternalRuntimes()
			t.Fatalf("%s runtime launch through entry: %v", version, err)
		}
		if rt.command != entry {
			t.Errorf("runtime replaced entry identity: %q", rt.command)
		}
		c.closeExternalRuntimes()
	}
}

func TestDeviceCodexReenable(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	command := fakeCodexCommand(t, filepath.Join(t.TempDir(), "codex.log"), nil)
	c, err := newConnector(config{name: "review", root: t.TempDir(), deviceMode: true})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	impl := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	if _, err := impl.ensureTargetRuntime(context.Background(), target); err != nil {
		t.Fatalf("before: %v", err)
	}
	if err := c.setCurrentScope(scopeLocalFileRead); err != nil {
		t.Fatal(err)
	}
	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}
	impl = c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	if _, err := impl.ensureTargetRuntime(context.Background(), target); err != nil {
		t.Fatalf("after reenable: %v", err)
	}
}

func TestDeviceDiscoversUserCodexAppWithoutShellPATH(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("PATH", t.TempDir())
	command := filepath.Join(home, "Applications", "ChatGPT.app", "Contents", "Resources", "codex")
	if err := os.MkdirAll(filepath.Dir(command), 0700); err != nil {
		t.Fatal(err)
	}
	marker := filepath.Join(home, "provider-was-started")
	if err := os.WriteFile(command, []byte("#!/bin/sh\ntouch '"+marker+"'\n"), 0700); err != nil {
		t.Fatal(err)
	}
	targets := discoverAgentRuntimeTargets()
	if !slices.ContainsFunc(targets, func(target runtimeProbeTarget) bool {
		return target.provider == "codex" && target.identityMaterial == command
	}) {
		t.Fatal("device did not discover the installed application without a shell PATH")
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("passive discovery started the provider")
	}
}
