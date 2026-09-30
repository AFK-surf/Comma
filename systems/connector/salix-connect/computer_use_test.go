package main

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestDefaultComputerUseHelperPathFollowsConnectorBinary(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use helper default path is macOS-only")
	}

	tempDir := t.TempDir()
	oldExecutable := osExecutable
	osExecutable = func() (string, error) {
		return filepath.Join(tempDir, "salix-connect"), nil
	}
	t.Cleanup(func() {
		osExecutable = oldExecutable
	})

	cfg := config{}
	normalizeConfig(&cfg)

	want := filepath.Join(tempDir, "native", "macos", "Comma Computer Use.app")
	if cfg.computerUseHelperApp != want {
		t.Fatalf("computerUseHelperApp = %q, want %q", cfg.computerUseHelperApp, want)
	}
}

func TestComputerUseMetadataReflectsHelperAvailability(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing.app")
	c, err := newConnector(config{
		name:                 "laptop",
		root:                 t.TempDir(),
		computerUseHelperApp: missing,
	})
	if err != nil {
		t.Fatalf("new connector with missing helper: %v", err)
	}
	assertCapability(t, c.metadata().Capabilities, "computer_use_tool", false)

	helperApp := filepath.Join(t.TempDir(), "Comma Computer Use.app")
	if err := os.MkdirAll(helperApp, 0o755); err != nil {
		t.Fatalf("mkdir helper app: %v", err)
	}
	c, err = newConnector(config{
		name:                 "laptop",
		root:                 t.TempDir(),
		computerUseHelperApp: helperApp,
	})
	if err != nil {
		t.Fatalf("new connector with helper: %v", err)
	}
	assertCapability(t, c.metadata().Capabilities, "computer_use_tool", runtime.GOOS == "darwin")
}

func TestComputerUseStartSendsDaemonRequestAndReturnsHelp(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use daemon launch is macOS-only")
	}

	socketPath, requests := startFakeComputerUseSocket(t, `{"kind":"final","response":{"ok":true,"display":{"display":1}}}`+"\n")
	c := newComputerUseTestConnector(t, socketPath)

	result := c.methodComputerUse(context.Background(), map[string]any{
		"action": "start",
		"args": map[string]any{
			"apps":    []any{"Safari"},
			"display": 2,
		},
	})

	assertCapability(t, result, "ok", true)
	assertCapability(t, result, "mode", "foreground")
	if !strings.Contains(result["help"].(string), "get_screenshot") {
		t.Fatalf("start help missing get_screenshot: %v", result["help"])
	}

	request := receiveComputerUseRequest(t, requests)
	assertComputerUseAuthToken(t, request)
	assertCapability(t, request, "display", float64(2))
	action := request["action"].(map[string]any)
	start := action["start"].(map[string]any)
	apps := start["apps"].([]any)
	if len(apps) != 1 || apps[0] != "Safari" {
		t.Fatalf("start apps = %v, want [Safari]", apps)
	}
}

func TestComputerUseScreenshotConvertsImageEnvelope(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use daemon launch is macOS-only")
	}

	socketPath, requests := startFakeComputerUseSocket(t, `{"kind":"final","response":{"ok":true,"imageData":"AQID","imageContentType":"image/jpeg","imageWidth":10,"imageHeight":20}}`+"\n")
	c := newComputerUseTestConnector(t, socketPath)

	result := c.methodComputerUse(context.Background(), map[string]any{"action": "get_screenshot"})

	assertCapability(t, result, "ok", true)
	name, ok := result["image_path"].(string)
	if !ok {
		t.Fatalf("missing image reference: %v", result)
	}
	read := c.methodComputerUse(context.Background(), map[string]any{"action": "read_image", "args": map[string]any{"path": name}})
	assertCapability(t, read, "image_base64", "AQID")
	assertCapability(t, result, "image_width", 10)
	assertCapability(t, result, "image_height", 20)
	assertCapability(t, result, "image_size_bytes", 3)

	request := receiveComputerUseRequest(t, requests)
	assertComputerUseAuthToken(t, request)
	action := request["action"].(map[string]any)
	if _, ok := action["get_screenshot"]; !ok {
		t.Fatalf("daemon action = %v, want get_screenshot", action)
	}
}

func TestComputerUseOpenPermissionFlowSendsControlRequest(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use daemon launch is macOS-only")
	}

	socketPath, requests := startFakeComputerUseSocket(t, `{"kind":"final","response":{"ok":true,"message":"Authorization window opened.","permissions":{"accessibility":false,"screenRecording":true}}}`+"\n")
	c := newComputerUseTestConnector(t, socketPath)

	result := c.methodComputerUse(context.Background(), map[string]any{"action": "open-permission-flow"})

	assertCapability(t, result, "ok", true)
	if !strings.Contains(result["text"].(string), "Authorization window opened.") {
		t.Fatalf("permission flow response text = %v", result["text"])
	}
	permissions := result["permissions"].(map[string]any)
	assertCapability(t, permissions, "accessibility", false)
	assertCapability(t, permissions, "screenRecording", true)

	request := receiveComputerUseRequest(t, requests)
	assertComputerUseAuthToken(t, request)
	assertCapability(t, request, "control", "open-permission-flow")
	if _, ok := request["action"]; ok {
		t.Fatalf("permission flow request should not include action: %v", request)
	}
}

func TestComputerUsePermissionsStatusSendsDaemonAction(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use daemon launch is macOS-only")
	}

	socketPath, requests := startFakeComputerUseSocket(t, `{"kind":"final","response":{"ok":true,"permissions":{"accessibility":true,"screenRecording":true}}}`+"\n")
	c := newComputerUseTestConnector(t, socketPath)

	result := c.methodComputerUse(context.Background(), map[string]any{"action": "permissions-status"})

	assertCapability(t, result, "ok", true)
	request := receiveComputerUseRequest(t, requests)
	assertComputerUseAuthToken(t, request)
	action := request["action"].(map[string]any)
	if _, ok := action["permissions_status"]; !ok {
		t.Fatalf("daemon action = %v, want permissions_status", action)
	}
}

func TestComputerUseListApplicationsSendsDaemonAction(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use daemon launch is macOS-only")
	}

	socketPath, requests := startFakeComputerUseSocket(t, `{"kind":"final","response":{"ok":true,"text":"[]"}}`+"\n")
	c := newComputerUseTestConnector(t, socketPath)

	result := c.methodComputerUse(context.Background(), map[string]any{"action": "list-applications"})

	assertCapability(t, result, "ok", true)
	request := receiveComputerUseRequest(t, requests)
	assertComputerUseAuthToken(t, request)
	action := request["action"].(map[string]any)
	if _, ok := action["list_applications"]; !ok {
		t.Fatalf("daemon action = %v, want list_applications", action)
	}
}

func TestComputerUseShutdownSendsControlRequest(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use daemon lifecycle is macOS-only")
	}

	socketPath, requests := startFakeComputerUseSocket(t, `{"kind":"final","response":{"ok":true}}`+"\n")
	c := newComputerUseTestConnector(t, socketPath)

	c.shutdownComputerUseDaemon()

	request := receiveComputerUseRequest(t, requests)
	assertComputerUseAuthToken(t, request)
	assertCapability(t, request, "control", "shutdown")
}

func TestComputerUsePermissionsOpenUIIsUnsupported(t *testing.T) {
	result := (&connector{}).methodComputerUse(context.Background(), map[string]any{"action": "permissions-open-ui"})

	assertCapability(t, result, "ok", false)
	if !strings.Contains(result["error"].(string), "unsupported computer_use action") {
		t.Fatalf("permission action error = %v", result["error"])
	}
}

func TestComputerUseErrorsAndInterruptedResponses(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use daemon launch is macOS-only")
	}

	socketPath, requests := startFakeComputerUseSocket(t, `{"kind":"final","response":{"ok":false,"error":"daemon exploded"}}`+"\n")
	c := newComputerUseTestConnector(t, socketPath)
	result := c.methodComputerUse(context.Background(), map[string]any{"action": "status"})
	assertCapability(t, result, "ok", false)
	assertCapability(t, result, "error", "daemon exploded")
	_ = receiveComputerUseRequest(t, requests)

	socketPath, requests = startFakeComputerUseSocket(t, `{"kind":"final","response":{"ok":false,"interrupted":true,"message":"user took over"}}`+"\n")
	c = newComputerUseTestConnector(t, socketPath)
	result = c.methodComputerUse(context.Background(), map[string]any{"action": "status"})
	assertCapability(t, result, "ok", false)
	assertCapability(t, result, "error", "user took over")
	assertCapability(t, result, "interrupted", true)
	_ = receiveComputerUseRequest(t, requests)
}

func newComputerUseTestConnector(t *testing.T, socketPath string) *connector {
	t.Helper()

	helperApp := filepath.Join(t.TempDir(), "Comma Computer Use.app")
	if err := os.MkdirAll(helperApp, 0o755); err != nil {
		t.Fatalf("mkdir helper app: %v", err)
	}
	c, err := newConnector(config{
		name:                   "laptop",
		root:                   t.TempDir(),
		computerUseHelperApp:   helperApp,
		computerUseSocketPath:  socketPath,
		computerUseRuntimePath: t.TempDir(),
	})
	if err != nil {
		t.Fatalf("new computer_use connector: %v", err)
	}
	return c
}

func TestComputerUseHelperOpenArgsCarryRuntimePathsAndToken(t *testing.T) {
	args := computerUseHelperOpenArgs("/Applications/Comma Computer Use.app", "/tmp/custom-computer-use.sock", "/tmp/@comma-staging/computer-use", "secret-token")

	if !containsString(args, "-n") {
		t.Fatalf("helper open args should force a fresh app instance: %v", args)
	}
	if !containsString(args, "--env") {
		t.Fatalf("helper open args missing env marker: %v", args)
	}
	if !containsString(args, "COMMA_COMPUTER_USE_SOCKET_PATH=/tmp/custom-computer-use.sock") {
		t.Fatalf("helper open args missing socket path: %v", args)
	}
	if !containsString(args, "COMMA_COMPUTER_USE_RUNTIME_PATH=/tmp/@comma-staging/computer-use") {
		t.Fatalf("helper open args missing runtime path: %v", args)
	}
	if !containsString(args, "COMMA_COMPUTER_USE_AUTH_TOKEN=secret-token") {
		t.Fatalf("helper open args missing auth token: %v", args)
	}
	if got := args[len(args)-1]; got != "/Applications/Comma Computer Use.app" {
		t.Fatalf("helper open args app path = %q, want app path last", got)
	}
}

func TestComputerUseSocketPathFollowsRuntimeRoot(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use socket default is macOS-only")
	}

	firstRoot := filepath.Join(t.TempDir(), "one", "profile")
	secondRoot := filepath.Join(t.TempDir(), "two", "profile")
	first := computerUseSocketPathForRuntime("@comma-staging", firstRoot)
	second := computerUseSocketPathForRuntime("@comma-staging", secondRoot)
	if first == second {
		t.Fatalf("same-basename runtime roots share socket path %q", first)
	}
	if !strings.Contains(filepath.Base(first), "comma-staging-") {
		t.Fatalf("runtime socket path lacks bounded release label: %q", first)
	}
	if got := computerUseSocketPathForRuntime("../unsafe namespace", firstRoot); strings.Contains(filepath.Base(got), "..") {
		t.Fatalf("unsafe runtime namespace was not contained: %q", got)
	}
}

func TestComputerUseSocketPathStaysWithinMacOSLimit(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use socket default is macOS-only")
	}

	t.Setenv("TMPDIR", filepath.Join(t.TempDir(), strings.Repeat("long-temp-root-", 8)))
	root := filepath.Join(t.TempDir(), strings.Repeat("long-runtime-root-", 16), "profile")
	path := computerUseSocketPathForRuntime(strings.Repeat("long-release-namespace-", 8), root)
	if got := len([]byte(path)) + 1; got > computerUseSocketPathMaxBytes {
		t.Fatalf("runtime socket path including NUL is %d bytes, want <= %d: %q", got, computerUseSocketPathMaxBytes, path)
	}
	if !strings.HasPrefix(path, "/tmp/comma-cu-") {
		t.Fatalf("long TMPDIR did not use compact per-user fallback: %q", path)
	}
}

func TestComputerUseSocketPathFallsBackAtExactMacOSBufferSize(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use socket default is macOS-only")
	}

	runtimeNamespace := "@comma-staging"
	runtimeRoot := filepath.Join(t.TempDir(), "profile")
	fileName := computerUseSocketIdentity(runtimeNamespace, runtimeRoot) + ".sock"
	relativePath := filepath.Join(computerUseSocketDirectoryName, fileName)
	tempRootLength := computerUseSocketPathMaxBytes - len([]byte(relativePath)) - 1
	prefix := fmt.Sprintf("/tmp/comma-boundary-%d-", os.Getpid())
	if len([]byte(prefix)) > tempRootLength {
		t.Fatalf("test temp prefix is %d bytes, want <= %d", len([]byte(prefix)), tempRootLength)
	}
	tempRoot := prefix + strings.Repeat("x", tempRootLength-len([]byte(prefix)))
	t.Cleanup(func() { _ = os.RemoveAll(tempRoot) })
	if err := os.MkdirAll(tempRoot, 0o700); err != nil {
		t.Fatalf("create exact-boundary temp root: %v", err)
	}
	t.Setenv("TMPDIR", tempRoot)

	candidate := filepath.Join(tempRoot, relativePath)
	if got := len([]byte(candidate)); got != computerUseSocketPathMaxBytes {
		t.Fatalf("test candidate is %d bytes, want exact %d: %q", got, computerUseSocketPathMaxBytes, candidate)
	}
	path := computerUseSocketPathForRuntime(runtimeNamespace, runtimeRoot)
	if path == candidate || !strings.HasPrefix(path, "/tmp/comma-cu-") {
		t.Fatalf("exact-buffer-size socket path did not use compact fallback: %q", path)
	}
	if got := len([]byte(path)) + 1; got > computerUseSocketPathMaxBytes {
		t.Fatalf("fallback socket path including NUL is %d bytes, want <= %d: %q", got, computerUseSocketPathMaxBytes, path)
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatalf("create fallback socket directory: %v", err)
	}
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("bind fallback socket path: %v", err)
	}
	if err := listener.Close(); err != nil {
		t.Fatalf("close fallback socket: %v", err)
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		t.Fatalf("remove fallback socket: %v", err)
	}
}

func TestComputerUseRuntimeFollowsElectronConfig(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use runtime paths are macOS-only")
	}

	root := filepath.Join(t.TempDir(), "@comma-staging")
	configPath := filepath.Join(t.TempDir(), "connector.json")
	encoded := fmt.Sprintf(
		`{"connector":{"root":"."},"electron":{"runtime_namespace":"@comma-staging","runtime_root":%q}}`,
		root,
	)
	if err := os.WriteFile(configPath, []byte(encoded), 0o600); err != nil {
		t.Fatalf("write connector config: %v", err)
	}

	cfg := config{configPath: configPath}
	if err := applyConfigFile(&cfg, map[string]bool{}); err != nil {
		t.Fatalf("apply connector config: %v", err)
	}
	normalizeConfig(&cfg)

	if got, want := cfg.computerUseSocketPath, computerUseSocketPathForRuntime("@comma-staging", root); got != want {
		t.Fatalf("computerUseSocketPath = %q, want %q", got, want)
	}
	if got, want := cfg.computerUseRuntimePath, filepath.Join(root, "computer-use"); got != want {
		t.Fatalf("computerUseRuntimePath = %q, want %q", got, want)
	}
}

func TestDefaultComputerUseSocketPathAvoidsGlobalTmpSocket(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("computer_use socket default is macOS-only")
	}

	socketPath := defaultComputerUseSocketPath()
	if socketPath == "/tmp/computeruse.sock" {
		t.Fatalf("default socket path = %q, want private per-user path", socketPath)
	}
	if !strings.Contains(socketPath, computerUseSocketDirectoryName) {
		t.Fatalf("default socket path = %q, want comma computer_use directory", socketPath)
	}
}

func startFakeComputerUseSocket(t *testing.T, response string) (string, <-chan map[string]any) {
	t.Helper()

	socketPath := filepath.Join(os.TempDir(), fmt.Sprintf("cu-%d-%d.sock", os.Getpid(), time.Now().UnixNano()))
	_ = os.Remove(socketPath)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen fake computer_use socket: %v", err)
	}
	t.Cleanup(func() {
		_ = listener.Close()
		_ = os.Remove(socketPath)
	})

	requests := make(chan map[string]any, 1)
	go func() {
		defer close(requests)
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
			line, err := bufio.NewReader(conn).ReadString('\n')
			if err != nil && strings.TrimSpace(line) == "" {
				_ = conn.Close()
				continue
			}

			var request map[string]any
			if err := json.Unmarshal([]byte(strings.TrimSpace(line)), &request); err == nil {
				if request["control"] == "hello" {
					_, _ = io.WriteString(conn, fmt.Sprintf(
						`{"kind":"final","response":{"ok":true,"message":%q}}`+"\n",
						computerUseHelloMessage,
					))
					_ = conn.Close()
					continue
				}
				requests <- request
			}
			if !strings.HasSuffix(response, "\n") {
				response += "\n"
			}
			_, _ = io.WriteString(conn, response)
			_ = conn.Close()
			_ = listener.Close()
			return
		}
	}()

	return socketPath, requests
}

func assertComputerUseAuthToken(t *testing.T, request map[string]any) {
	t.Helper()

	token, ok := request["auth_token"].(string)
	if !ok || strings.TrimSpace(token) == "" {
		t.Fatalf("computer_use request missing auth_token: %v", request)
	}
}

func containsString(values []string, want string) bool {
	for _, value := range values {
		if value == want {
			return true
		}
	}
	return false
}

func receiveComputerUseRequest(t *testing.T, requests <-chan map[string]any) map[string]any {
	t.Helper()

	select {
	case request, ok := <-requests:
		if !ok {
			t.Fatal("fake computer_use socket closed before receiving request")
		}
		return request
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for computer_use request")
		return map[string]any{}
	}
}

func TestComputerUseImageExpiryAndIsolation(t *testing.T) {
	c := &connector{cfg: config{computerUseRuntimePath: t.TempDir()}}
	image := computerUseDaemonResponse{ImageData: []byte("image"), ImageContentType: "image/png"}
	result, err := c.storeComputerUseImage(image)
	if err != nil {
		t.Fatal(err)
	}
	name := result["image_path"].(string)
	path := filepath.Join(c.cfg.computerUseRuntimePath, "screenshots", name)
	body, err := os.ReadFile(path)
	if err != nil || string(body) != "image" {
		t.Fatalf("device file: %q %v", body, err)
	}
	// An independently constructed connector can read a retained image after restart.
	restarted := &connector{cfg: c.cfg}
	assertCapability(t, restarted.readComputerUseImage(name), "ok", true)
	assertCapability(t, c.readComputerUseImage("../"+name), "ok", false)
	old := time.Now().Add(-computerUseImageTTL - time.Second)
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	assertCapability(t, c.readComputerUseImage(name), "ok", false)
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("expired image remains: %v", err)
	}
}

func TestComputerUseImageStorageBound(t *testing.T) {
	c := &connector{cfg: config{computerUseRuntimePath: t.TempDir()}}
	if _, err := c.storeComputerUseImage(computerUseDaemonResponse{ImageData: make([]byte, computerUseImageMaxBytes+1), ImageContentType: "image/png"}); err == nil {
		t.Fatal("accepted oversized image")
	}
	dir, err := c.computerUseImageDirectory()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < computerUseImageMaxCount; i++ {
		if err := os.WriteFile(filepath.Join(dir, fmt.Sprintf("capture-%d.png", i)), []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := c.storeComputerUseImage(computerUseDaemonResponse{ImageData: []byte("new"), ImageContentType: "image/png"}); err == nil {
		t.Fatal("accepted image above storage count limit")
	}
	assertCapability(t, c.readComputerUseImage("capture-0.png"), "ok", true)
}
