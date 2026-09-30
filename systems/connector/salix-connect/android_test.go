package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAndroidRealLifecycle(t *testing.T) {
	if os.Getenv("SALIX_ANDROID_REAL_TEST") != "1" {
		t.Skip("set SALIX_ANDROID_REAL_TEST=1 on a configured KVM host")
	}
	root, err := filepath.EvalSymlinks(os.Getenv("SALIX_CONNECTOR_ROOT"))
	if err != nil {
		t.Fatal(err)
	}
	p := newAndroidProvider(config{
		root:                root,
		androidEnabled:      true,
		androidSDKRoot:      os.Getenv("SALIX_ANDROID_SDK_ROOT"),
		androidRuntimeRoot:  os.Getenv("SALIX_ANDROID_RUNTIME_ROOT"),
		androidAVDHome:      os.Getenv("SALIX_ANDROID_AVD_HOME"),
		androidProfilesFile: os.Getenv("SALIX_ANDROID_PROFILES_FILE"),
		androidSerial:       os.Getenv("SALIX_ANDROID_SERIAL"),
		androidGPU:          "swiftshader",
	})
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	start := p.handle(ctx, "real-lifecycle", map[string]any{"action": "start", "lease_seconds": 60})
	if start["ok"] != true {
		t.Fatalf("start failed: %v", start)
	}
	lease := map[string]any{"lease_id": start["lease_id"], "lease_epoch": start["lease_epoch"], "profile": start["profile"]}
	observe := p.handle(ctx, "", mergeAndroidTestParams(lease, map[string]any{"action": "observe"}))
	if observe["ok"] != true || observe["observation_id"] == nil {
		t.Fatalf("observe failed: %v", observe)
	}
	screenshotSource, ok := observe["screenshot_source_path"].(string)
	if !ok || screenshotSource == "" {
		t.Fatalf("observe did not return a staged screenshot: %v", observe)
	}
	if info, err := os.Stat(filepath.Join(root, filepath.FromSlash(screenshotSource))); err != nil || !info.Mode().IsRegular() {
		t.Fatalf("staged screenshot is unavailable: %v", err)
	}
	key := p.handle(ctx, "", mergeAndroidTestParams(lease, map[string]any{
		"action": "key", "key": "HOME", "observation_id": observe["observation_id"],
	}))
	if key["ok"] != true {
		t.Fatalf("key failed: %v", key)
	}
	stale := p.handle(ctx, "", mergeAndroidTestParams(lease, map[string]any{
		"action": "key", "key": "HOME", "observation_id": observe["observation_id"],
	}))
	if stale["error_code"] != "android_stale_observation" {
		t.Fatalf("stale observation was not fenced: %v", stale)
	}
	end := p.handle(ctx, "", mergeAndroidTestParams(lease, map[string]any{"action": "end"}))
	if end["ok"] != true {
		t.Fatalf("end failed: %v", end)
	}
}

func mergeAndroidTestParams(base, extra map[string]any) map[string]any {
	result := make(map[string]any, len(base)+len(extra))
	for key, value := range base {
		result[key] = value
	}
	for key, value := range extra {
		result[key] = value
	}
	return result
}

func TestAndroidLeaseAndObservationFencing(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	p := newAndroidProvider(config{})
	p.now = func() time.Time { return now }
	p.lease = &androidLease{id: "current", epoch: 7, expiresAt: now.Add(time.Minute)}
	p.observation = &androidObservation{id: 4, elements: map[string]androidElement{}}

	tests := []struct {
		name   string
		params map[string]any
		code   string
	}{
		{"missing lease", map[string]any{}, "android_stale_lease"},
		{"old lease id", map[string]any{"lease_id": "old", "lease_epoch": 7}, "android_stale_lease"},
		{"old lease epoch", map[string]any{"lease_id": "current", "lease_epoch": 6}, "android_stale_lease"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			_, failure := p.requireLease(tt.params)
			if got := failure["error_code"]; got != tt.code {
				t.Fatalf("error_code = %v, want %s", got, tt.code)
			}
		})
	}
	if _, failure := p.requireLease(map[string]any{"lease_id": "current", "lease_epoch": 7}); failure != nil {
		t.Fatalf("current lease rejected: %v", failure)
	}
	if failure := p.requireObservation(map[string]any{"observation_id": 3}); failure["error_code"] != "android_stale_observation" {
		t.Fatalf("stale observation accepted: %v", failure)
	}
	if failure := p.requireObservation(map[string]any{"observation_id": 4}); failure != nil {
		t.Fatalf("current observation rejected: %v", failure)
	}

	now = now.Add(2 * time.Minute)
	p.expireLease()
	if p.lease != nil || p.observation != nil {
		t.Fatal("expired lease retained state")
	}
}

func TestAndroidRejectedActionDoesNotRenewLease(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	lease := &androidLease{expiresAt: now.Add(time.Minute), ttl: 15 * time.Minute}
	renewAndroidLeaseOnSuccess(lease, androidError("invalid_request", "bad action"), now)
	if want := now.Add(time.Minute); !lease.expiresAt.Equal(want) {
		t.Fatalf("rejected action renewed lease to %v, want %v", lease.expiresAt, want)
	}
	renewAndroidLeaseOnSuccess(lease, map[string]any{"ok": true}, now)
	if want := now.Add(15 * time.Minute); !lease.expiresAt.Equal(want) {
		t.Fatalf("successful action did not renew lease to %v, want %v", lease.expiresAt, want)
	}
}

func TestAndroidLeaseEpochMonotonicAcrossEnd(t *testing.T) {
	p := newAndroidProvider(config{})
	p.nextEpoch++
	first := p.nextEpoch
	p.lease = nil
	p.nextEpoch++
	if p.nextEpoch <= first {
		t.Fatalf("epoch did not advance: first=%d second=%d", first, p.nextEpoch)
	}
}

func TestAndroidObservationDoesNotReuseIDAfterAction(t *testing.T) {
	p := newAndroidProvider(config{})
	p.nextObservation = 1
	p.observation = &androidObservation{id: 1}
	p.observation = nil // every successful UI mutation invalidates the snapshot
	p.nextObservation++
	p.observation = &androidObservation{id: p.nextObservation}
	if p.observation.id != 2 {
		t.Fatalf("observation id reused: %d", p.observation.id)
	}
	if failure := p.requireObservation(map[string]any{"observation_id": 1}); failure["error_code"] != "android_stale_observation" {
		t.Fatalf("old observation accepted: %v", failure)
	}
}

func TestAndroidClipboardDetectsUnsupportedShellCommand(t *testing.T) {
	tests := []struct {
		name   string
		action string
		output string
	}{
		{name: "set", action: "clipboard_set", output: "No shell command implementation.\n"},
		{name: "get", action: "clipboard_get", output: "No shell command implementation.\n"},
		{name: "unknown command", action: "clipboard_get", output: "Unknown command: clipboard\n"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			p := newAndroidProvider(config{androidSDKRoot: "/sdk", androidSerial: "emulator-5554"})
			p.observation = &androidObservation{id: 9}
			p.run = func(context.Context, string, ...string) ([]byte, error) {
				return []byte(tt.output), nil
			}
			params := map[string]any{"observation_id": 9, "text": "hello"}
			result := p.act(context.Background(), tt.action, params)
			if got := result["error_code"]; got != "android_clipboard_unavailable" {
				t.Fatalf("error_code = %v, want android_clipboard_unavailable: %v", got, result)
			}
			if p.observation == nil {
				t.Fatal("unsupported clipboard action invalidated the current observation")
			}
		})
	}
}

func TestAndroidClipboardSupportedCommand(t *testing.T) {
	p := newAndroidProvider(config{androidSDKRoot: "/sdk", androidSerial: "emulator-5554"})
	p.observation = &androidObservation{id: 9}
	p.run = func(_ context.Context, _ string, args ...string) ([]byte, error) {
		if args[len(args)-1] == "get" {
			return []byte("hello\n"), nil
		}
		return nil, nil
	}

	set := p.act(context.Background(), "clipboard_set", map[string]any{"text": "hello"})
	if set["ok"] != true || p.observation != nil {
		t.Fatalf("supported clipboard set failed: %v", set)
	}
	p.observation = &androidObservation{id: 10}
	get := p.act(context.Background(), "clipboard_get", nil)
	if get["ok"] != true || get["text"] != "hello" || p.observation != nil {
		t.Fatalf("supported clipboard get failed: %v", get)
	}
}

func TestParseAndroidElements(t *testing.T) {
	xmlData := []byte(`<?xml version="1.0"?><hierarchy><node class="android.widget.FrameLayout" bounds="[0,0][100,100]"><node text="Settings" resource-id="com.android.settings:id/title" class="android.widget.TextView" clickable="true" bounds="[10,20][90,60]"/></node></hierarchy>`)
	elements, indexed, err := parseAndroidElements(xmlData)
	if err != nil {
		t.Fatal(err)
	}
	if len(elements) != 1 {
		t.Fatalf("elements = %d, want 1", len(elements))
	}
	if got := indexed["@1"]; got.Text != "Settings" || got.X != 50 || got.Y != 40 {
		t.Fatalf("unexpected element: %+v", got)
	}
}

func TestSafeAndroidStagingPath(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"", ".", "..", "../escape", "a/b"} {
		if _, err := safeAndroidStagingPath(root, name); err == nil {
			t.Errorf("accepted unsafe name %q", name)
		}
	}
	got, err := safeAndroidStagingPath(root, "app.apk")
	if err != nil || got != filepath.Join(root, "app.apk") {
		t.Fatalf("safe path = %q, %v", got, err)
	}
}

func TestWriteAndroidStagedFileReplacesSymlinkWithoutFollowingIt(t *testing.T) {
	root := t.TempDir()
	escape := filepath.Join(t.TempDir(), "escape.png")
	if err := os.WriteFile(escape, []byte("outside"), 0o600); err != nil {
		t.Fatal(err)
	}
	target := filepath.Join(root, "observation.png")
	if err := os.Symlink(escape, target); err != nil {
		t.Fatal(err)
	}
	if err := writeAndroidStagedFile(root, target, []byte("inside")); err != nil {
		t.Fatal(err)
	}
	if got, _ := os.ReadFile(escape); string(got) != "outside" {
		t.Fatalf("followed staging symlink: %q", got)
	}
	if info, err := os.Lstat(target); err != nil || !info.Mode().IsRegular() {
		t.Fatalf("target was not replaced with a regular file: %v", err)
	}
}

func TestAndroidImportStagedInputRejectsEscapeAndSymlink(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	staging := t.TempDir()
	p := newAndroidProvider(config{root: root})
	lease := &androidLease{stagingRoot: staging}
	target := filepath.Join(staging, "input.apk")
	if _, err := p.importStagedInput(lease, map[string]any{"source_path": "../escape"}, target); err == nil {
		t.Fatal("accepted traversal")
	}
	real := filepath.Join(root, "real.apk")
	if err := os.WriteFile(real, []byte("apk"), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link.apk")
	if err := os.Symlink(real, link); err != nil {
		t.Fatal(err)
	}
	if _, err := p.importStagedInput(lease, map[string]any{"source_path": "link.apk"}, target); err == nil {
		t.Fatal("accepted symlink")
	}
	escapeDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(escapeDir, "escape.apk"), []byte("apk"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(escapeDir, filepath.Join(root, "linked-dir")); err != nil {
		t.Fatal(err)
	}
	if _, err := p.importStagedInput(lease, map[string]any{"source_path": "linked-dir/escape.apk"}, target); err == nil {
		t.Fatal("accepted parent symlink escape")
	}
	got, err := p.importStagedInput(lease, map[string]any{"source_path": "real.apk"}, target)
	if err != nil || got != target {
		t.Fatalf("import = %q, %v", got, err)
	}
}

func TestPrepareAndroidRuntimeRootCreatesOnlyInsideConnectorRoot(t *testing.T) {
	root := t.TempDir()
	root, _ = filepath.EvalSymlinks(root)
	runtimeRoot := filepath.Join(root, "runtime", "android")
	got, err := prepareAndroidRuntimeRoot(root, runtimeRoot)
	if err != nil || got != runtimeRoot {
		t.Fatalf("prepare runtime root = %q, %v", got, err)
	}
	if info, err := os.Stat(runtimeRoot); err != nil || !info.IsDir() {
		t.Fatalf("runtime root was not created: %v", err)
	}
	if _, err := prepareAndroidRuntimeRoot(root, filepath.Join(root, "..", "escape")); err == nil {
		t.Fatal("accepted runtime root outside Connector root")
	}
	escape := t.TempDir()
	if err := os.Symlink(escape, filepath.Join(root, "linked-runtime")); err != nil {
		t.Fatal(err)
	}
	if _, err := prepareAndroidRuntimeRoot(root, filepath.Join(root, "linked-runtime")); err == nil {
		t.Fatal("accepted runtime root symlink outside Connector root")
	}
	if _, err := prepareAndroidRuntimeRoot(root, filepath.Join(root, "linked-runtime", "must-not-create")); err == nil {
		t.Fatal("accepted missing runtime root beneath an escaping symlink")
	}
	if _, err := os.Stat(filepath.Join(escape, "must-not-create")); !os.IsNotExist(err) {
		t.Fatalf("created a directory outside Connector root: %v", err)
	}
}

func TestAllowedAndroidKeyIsBounded(t *testing.T) {
	if !allowedAndroidKey("BACK") {
		t.Fatal("BACK rejected")
	}
	if allowedAndroidKey("KEYCODE_POWER") || allowedAndroidKey("123") {
		t.Fatal("unsafe key accepted")
	}
}

func TestAndroidLeaseDurationIsBounded(t *testing.T) {
	for _, value := range []any{59, 3601} {
		if _, err := androidLeaseDuration(value); err == nil {
			t.Fatalf("accepted lease_seconds=%v", value)
		}
	}
	if got, err := androidLeaseDuration(120); err != nil || got != 2*time.Minute {
		t.Fatalf("duration = %v, %v", got, err)
	}
	if got, err := androidLeaseDuration(nil); err != nil || got != androidLeaseTTL {
		t.Fatalf("default duration = %v, %v", got, err)
	}
}

func TestAndroidRequestTimeoutOutlivesBootAndPrecedesServer(t *testing.T) {
	got := requestTimeout(message{Method: "android"})
	if got != 210*time.Second {
		t.Fatalf("Android request timeout = %v, want 210s", got)
	}
	if got <= androidSwitchTimeout || got >= 220*time.Second {
		t.Fatalf("Android request timeout does not nest boot and Server budgets: %v", got)
	}
}
