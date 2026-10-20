package main

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// The Codex app-server serves readiness probes, login and subscription
// credentials. A managed image falls back to its bundled harness when the
// discovered command cannot start, without changing the target identity.
// Claude readiness probes share that fallback.
func harnessFallbackForTest(t *testing.T, provider string) (string, string) {
	t.Helper()
	isolateHostRuntimeCommands(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", t.TempDir())
	log := filepath.Join(t.TempDir(), "native.log")
	var command string
	switch provider {
	case "codex":
		command = fakeCodexCommand(t, log, nil)
	case "claude":
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_LOG", log)
		command = fakeClaudeRuntimeCommand(t)
	default:
		t.Fatalf("unsupported harness provider %q", provider)
	}
	original := imageHarnessCommand
	imageHarnessCommand = func(kind string) string {
		if kind == provider {
			return command
		}
		return original(kind)
	}
	t.Cleanup(func() { imageHarnessCommand = original })
	return command, log
}

func harnessConnectorForTest(t *testing.T) *connector {
	t.Helper()
	c, err := newConnector(config{name: "harness-startup-test", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.closeRuntimes)
	return c
}

func harnessStartForTest(t *testing.T, c *connector, command string) (*codexRuntime, error) {
	t.Helper()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	return implementation.ensureTargetRuntime(ctx, runtimeProbeTarget{provider: "codex", identityMaterial: command})
}

func TestHarnessStartupFallbackPreservesIdentity(t *testing.T) {
	_, log := harnessFallbackForTest(t, "codex")
	broken := filepath.Join(t.TempDir(), "codex")
	if err := os.WriteFile(broken, []byte("#!/bin/sh\necho 'stream-json unsupported' >&2\nexit 42\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	c := harnessConnectorForTest(t)
	native, err := harnessStartForTest(t, c, broken)
	if err != nil {
		t.Fatalf("fallback startup: %v", err)
	}
	if native.command != broken {
		t.Fatalf("changed runtime identity: %q", native.command)
	}
	if _, err := native.rpc(context.Background(), "account/read", nil, time.Second); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(log)
	if err != nil || strings.Count(string(data), "start\n") != 1 {
		t.Fatalf("fallback did not start exactly once: %s, %v", data, err)
	}
}

func TestHarnessStartupKeepsUsableUserCommand(t *testing.T) {
	user, log := harnessFallbackForTest(t, "codex")
	marker := filepath.Join(t.TempDir(), "unexpected-default")
	original := imageHarnessCommand
	fallback := filepath.Join(t.TempDir(), "codex")
	if err := os.WriteFile(fallback, []byte("#!/bin/sh\necho called > "+shellQuote(marker)+"\nexit 42\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	imageHarnessCommand = func(string) string { return fallback }
	defer func() { imageHarnessCommand = original }()
	c := harnessConnectorForTest(t)
	if _, err := harnessStartForTest(t, c, user); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatal("usable user command started default")
	}
	data, _ := os.ReadFile(log)
	if strings.Count(string(data), "start\n") != 1 {
		t.Fatalf("user command did not start once: %s", data)
	}
}

func TestCodexHarnessFallbackSerializesConcurrentStartup(t *testing.T) {
	_, log := harnessFallbackForTest(t, "codex")
	closed := filepath.Join(t.TempDir(), "close-initialize")
	if err := os.WriteFile(closed, []byte("close\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	first := fakeCodexCommand(t, filepath.Join(t.TempDir(), "first.log"), map[string]string{"SALIX_TEST_FAKE_CODEX_CLOSE_INITIALIZE_ONCE": closed})
	c := harnessConnectorForTest(t)
	implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	target := runtimeProbeTarget{provider: "codex", identityMaterial: first}
	unlock := c.runtimeAuthCoordinator().lockTarget(target.key())
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var wg sync.WaitGroup
	results := make(chan *codexRuntime, 2)
	failures := make(chan error, 2)
	wg.Add(2)
	go func() {
		defer wg.Done()
		native, err := implementation.ensureTargetRuntime(ctx, target)
		results <- native
		failures <- err
	}()
	go func() {
		defer wg.Done()
		native, err := implementation.ensureCodexRuntime(ctx, first)
		results <- native
		failures <- err
	}()
	wg.Wait()
	unlock()
	for n := 0; n < 2; n++ {
		if err := <-failures; err != nil {
			t.Fatal(err)
		}
	}
	a, b := <-results, <-results
	if a != b || a.command != first {
		t.Fatal("concurrent startup changed runtime ownership")
	}
	data, _ := os.ReadFile(log)
	if strings.Count(string(data), "start\n") != 1 {
		t.Fatalf("default started more than once: %s", data)
	}
	if _, err := a.rpc(ctx, "account/read", nil, time.Second); err != nil {
		t.Fatal(err)
	}
}

func TestHarnessStartupDoesNotRetryNativeRejection(t *testing.T) {
	_, fallbackLog := harnessFallbackForTest(t, "codex")
	marker := filepath.Join(t.TempDir(), "reject-initialize")
	if err := os.WriteFile(marker, []byte("reject\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	command := fakeCodexCommand(t, filepath.Join(t.TempDir(), "user.log"), map[string]string{"SALIX_TEST_FAKE_CODEX_FAIL_INITIALIZE_ONCE": marker})
	c := harnessConnectorForTest(t)
	if _, err := harnessStartForTest(t, c, command); err == nil {
		t.Fatal("accepted a rejected startup")
	}
	if data, err := os.ReadFile(fallbackLog); err == nil {
		t.Fatalf("native rejection started default: %s", data)
	}
}

func TestHarnessStartupRefusesAuthAndConfigExit(t *testing.T) {
	for _, reason := range []string{"authentication required: please login", "invalid model configuration"} {
		t.Run(reason, func(t *testing.T) {
			_, log := harnessFallbackForTest(t, "codex")
			command := filepath.Join(t.TempDir(), "codex")
			if err := os.WriteFile(command, []byte("#!/bin/sh\necho "+shellQuote(reason)+" >&2\nexit 42\n"), 0o755); err != nil {
				t.Fatal(err)
			}
			c := harnessConnectorForTest(t)
			if _, err := harnessStartForTest(t, c, command); err == nil {
				t.Fatal("startup refusal was hidden by fallback")
			}
			if data, err := os.ReadFile(log); err == nil {
				t.Fatalf("startup refusal launched default: %s", data)
			}
		})
	}
}

// A shell process exits without the race detector's delayed os.Exit path.
func normalExitCodexCommand(t *testing.T, log string) string {
	t.Helper()
	command := filepath.Join(t.TempDir(), "codex")
	script := "#!/bin/sh\nprintf 'start\\n' >> " + shellQuote(log) + "\nexit 0\n"
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return command
}

// holdCodexListenPort gives every app-server this test launches a listen port
// the test keeps bound. A released ephemeral port can be bound by another
// process, such as a concurrent test shard, before a fake that never listens
// exits; connect would then reach that process instead of seeing the exit. The
// held port accepts and closes each connection, so every dial fails until the
// fake's exit is observed.
func holdCodexListenPort(t *testing.T) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			_ = conn.Close()
		}
	}()
	previous := reserveCodexListenURL
	reserveCodexListenURL = func() (string, error) { return "ws://" + ln.Addr().String(), nil }
	t.Cleanup(func() {
		reserveCodexListenURL = previous
		_ = ln.Close()
	})
}

func TestCodexNormalExitBeforeListenIsNotRestarted(t *testing.T) {
	isolateHostRuntimeCommands(t)
	holdCodexListenPort(t)
	t.Setenv("HOME", t.TempDir())
	log := filepath.Join(t.TempDir(), "codex.log")
	command := normalExitCodexCommand(t, log)
	c := harnessConnectorForTest(t)
	var stopped *codexStartupNormalExit
	if _, err := harnessStartForTest(t, c, command); !errors.As(err, &stopped) {
		t.Fatalf("startup did not observe a normal exit: %v", err)
	}
	data, _ := os.ReadFile(log)
	if strings.Count(string(data), "start\n") != 1 {
		t.Fatalf("normal exit restarted app-server: %s", data)
	}
}
