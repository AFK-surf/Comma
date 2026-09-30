package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

func testAndroidProfiles(t *testing.T) *androidProvider {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("Android runs on Linux; process fixture needs Unix")
	}
	root := t.TempDir()
	profiles := androidProfilesConfig{DefaultProfile: "api35", Profiles: []androidProfileSpec{
		{ID: "api30", APILevel: 30, ABI: "x86_64", ImageFlavor: "default", AVDName: "avd30"},
		{ID: "api35", APILevel: 35, ABI: "x86_64", ImageFlavor: "google_apis", AVDName: "avd35"},
	}}
	data, _ := json.Marshal(profiles)
	manifest := filepath.Join(root, "profiles.json")
	if err := os.WriteFile(manifest, data, 0600); err != nil {
		t.Fatal(err)
	}
	for _, profile := range profiles.Profiles {
		avdRoot := filepath.Join(root, "avd", profile.AVDName+".avd")
		if err := os.MkdirAll(avdRoot, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(avdRoot, "config.ini"), []byte("AvdId="+profile.AVDName), 0600); err != nil {
			t.Fatal(err)
		}
	}
	p := newAndroidProvider(config{root: root, androidEnabled: true, androidSDKRoot: root,
		androidRuntimeRoot: filepath.Join(root, "runtime"), androidAVDHome: filepath.Join(root, "avd"),
		androidProfilesFile: manifest, androidSerial: "emulator-5554"})
	p.hostSupported = true
	p.checkHost = func(androidProfileSpec) error { return nil }
	p.discover = func(context.Context) (*androidOwnedProcess, error) { return nil, nil }
	p.launch = func(ctx context.Context, log string, avd ...string) error {
		if err := ctx.Err(); err != nil {
			return err
		}
		cmd := exec.Command("sleep", "60")
		if err := cmd.Start(); err != nil {
			return err
		}
		done := make(chan struct{})
		p.process = &androidOwnedProcess{process: cmd.Process, done: done}
		go func() { _ = cmd.Wait(); close(done) }()
		return nil
	}
	p.run = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		command := strings.Join(args[2:], " ")
		profile, _ := p.findProfile(p.process.profile)
		switch command {
		case "emu avd name":
			return []byte(profile.AVDName + "\nOK\n"), nil
		case "shell getprop ro.build.version.sdk":
			if profile.APILevel == 30 {
				return []byte("30"), nil
			}
			return []byte("35"), nil
		case "shell getprop ro.product.cpu.abilist":
			return []byte("x86_64,x86"), nil
		case "get-state":
			return []byte("device"), nil
		case "shell getprop sys.boot_completed", "shell getprop dev.bootcomplete":
			return []byte("1"), nil
		case "shell dumpsys window":
			return []byte("mCurrentFocus=fixture"), nil
		}
		return []byte("found"), nil
	}
	t.Cleanup(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		if err := p.stopProcess(ctx); err != nil {
			t.Error(err)
		}
		if p.ownerLock != nil {
			p.ownerLock.Close()
		}
	})
	return p
}

func TestAndroidProfilesSwitchPreservesAVDDataAndFencesLease(t *testing.T) {
	p := testAndroidProfiles(t)
	for _, profile := range p.profiles.Profiles {
		dir := filepath.Join(p.cfg.androidAVDHome, profile.AVDName+".avd")
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "userdata-qemu.img"), []byte(profile.ID), 0600); err != nil {
			t.Fatal(err)
		}
	}
	start := p.handle(context.Background(), "first", map[string]any{"action": "start", "lease_seconds": 60})
	if start["ok"] != true || start["profile"] != "api35" {
		t.Fatalf("default start: %v", start)
	}
	firstProcess := p.process
	replay := p.handle(context.Background(), "first", map[string]any{"action": "start"})
	if replay["lease_id"] != start["lease_id"] || replay["replayed"] != true {
		t.Fatalf("replay: %v", replay)
	}
	params := map[string]any{"lease_id": start["lease_id"], "lease_epoch": start["lease_epoch"], "profile": "api35"}
	rejected := p.handle(context.Background(), "second", map[string]any{"action": "start", "profile": "api30"})
	if rejected["error_code"] != "android_capacity_exhausted" {
		t.Fatalf("active lease switched: %v", rejected)
	}
	wrong := p.handle(context.Background(), "", mergeAndroidTestParams(params, map[string]any{"action": "end", "profile": "api30"}))
	if wrong["error_code"] != "android_profile_mismatch" {
		t.Fatalf("wrong profile ended lease: %v", wrong)
	}
	ended := p.handle(context.Background(), "", mergeAndroidTestParams(params, map[string]any{"action": "end"}))
	if ended["ok"] != true || !firstProcess.alive() {
		t.Fatalf("end must keep AVD warm: %v", ended)
	}
	warm := p.handle(context.Background(), "warm", map[string]any{"action": "start", "profile": "api35"})
	if warm["ok"] != true || p.process != firstProcess {
		t.Fatalf("strictly ready profile was not reused: %v", warm)
	}
	warmParams := map[string]any{
		"action": "end", "lease_id": warm["lease_id"], "lease_epoch": warm["lease_epoch"], "profile": "api35",
	}
	if got := p.handle(context.Background(), "", warmParams); got["ok"] != true {
		t.Fatalf("end warm lease: %v", got)
	}
	next := p.handle(context.Background(), "second", map[string]any{"action": "start", "profile": "api30"})
	if next["ok"] != true || next["profile"] != "api30" || firstProcess.alive() {
		t.Fatalf("switch: %v", next)
	}
	stale := p.handle(context.Background(), "", mergeAndroidTestParams(params, map[string]any{"action": "end"}))
	if stale["error_code"] != "android_stale_lease" {
		t.Fatalf("old lease accepted: %v", stale)
	}
	for _, profile := range p.profiles.Profiles {
		data, err := os.ReadFile(filepath.Join(p.cfg.androidAVDHome, profile.AVDName+".avd", "userdata-qemu.img"))
		if err != nil || string(data) != profile.ID {
			t.Fatalf("AVD data changed: %s %v", data, err)
		}
	}
}

func TestAndroidUnreadyWarmProfileRestartsBeforeLease(t *testing.T) {
	p := testAndroidProfiles(t)
	start := p.handle(context.Background(), "first", map[string]any{"action": "start"})
	if start["ok"] != true {
		t.Fatalf("first start: %v", start)
	}
	params := map[string]any{
		"action": "end", "lease_id": start["lease_id"], "lease_epoch": start["lease_epoch"], "profile": "api35",
	}
	if got := p.handle(context.Background(), "", params); got["ok"] != true {
		t.Fatalf("first end: %v", got)
	}
	oldProcess := p.process
	run := p.run
	p.run = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if p.process == oldProcess && strings.Join(args[2:], " ") == "emu avd name" {
			return []byte("wrong-avd"), nil
		}
		return run(ctx, name, args...)
	}

	restarted := p.handle(context.Background(), "restart", map[string]any{"action": "start"})
	if restarted["ok"] != true || p.process == oldProcess || oldProcess.alive() {
		t.Fatalf("unready warm profile was not restarted: %v", restarted)
	}
}

func TestAndroidPreparingStatusAndCancellation(t *testing.T) {
	p := testAndroidProfiles(t)
	entered := make(chan struct{})
	p.run = func(ctx context.Context, _ string, _ ...string) ([]byte, error) {
		close(entered)
		<-ctx.Done()
		return nil, ctx.Err()
	}
	ctx, cancel := context.WithCancel(context.Background())
	result := make(chan map[string]any, 1)
	go func() { result <- p.handle(ctx, "cancel", map[string]any{"action": "start"}) }()
	<-entered
	status := p.handle(context.Background(), "", map[string]any{"action": "status"})
	if status["state"] != "preparing" || status["target_profile"] != "api35" || status["available_slots"] != 0 {
		t.Fatalf("status: %v", status)
	}
	busy := p.handle(context.Background(), "other", map[string]any{"action": "start"})
	if busy["error_code"] != "android_capacity_exhausted" {
		t.Fatalf("slot not reserved: %v", busy)
	}
	cancel()
	select {
	case got := <-result:
		if got["ok"] != false || p.lease != nil || p.process != nil {
			t.Fatalf("cancel leaked lease/process: %v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cancellation did not finish cleanup")
	}
}

func TestAndroidWrongRuntimeCannotReceiveLease(t *testing.T) {
	for _, field := range []string{"emu avd name", "shell getprop ro.build.version.sdk", "shell getprop ro.product.cpu.abilist"} {
		t.Run(field, func(t *testing.T) {
			p := testAndroidProfiles(t)
			run := p.run
			p.run = func(ctx context.Context, name string, args ...string) ([]byte, error) {
				if strings.Join(args[2:], " ") == field {
					return []byte("wrong"), nil
				}
				return run(ctx, name, args...)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
			defer cancel()
			got := p.handle(ctx, "wrong", map[string]any{"action": "start"})
			if got["ok"] != false || p.lease != nil || p.process != nil {
				t.Fatalf("mismatch granted lease or leaked process: %v", got)
			}
		})
	}
}

func TestAndroidProcessExitDuringFinalProbeCannotReceiveLease(t *testing.T) {
	p := testAndroidProfiles(t)
	run := p.run
	p.run = func(ctx context.Context, name string, args ...string) ([]byte, error) {
		if strings.Join(args[2:], " ") == "shell dumpsys window" {
			process := p.process
			if err := process.process.Kill(); err != nil {
				t.Fatal(err)
			}
			<-process.done
			return []byte("mCurrentFocus=fixture"), nil
		}
		return run(ctx, name, args...)
	}

	got := p.handle(context.Background(), "dies-at-ready", map[string]any{"action": "start"})
	if got["ok"] != false || p.lease != nil || p.process != nil {
		t.Fatalf("dead emulator received a lease or leaked process state: %v", got)
	}
}

func TestAndroidUnknownProcessFailsWithoutLaunch(t *testing.T) {
	p := testAndroidProfiles(t)
	p.discover = func(context.Context) (*androidOwnedProcess, error) { return nil, errors.New("unowned serial") }
	p.launch = func(context.Context, string, ...string) error { t.Fatal("launched over unknown process"); return nil }
	got := p.handle(context.Background(), "unknown", map[string]any{"action": "start"})
	if got["ok"] != false || p.lease != nil {
		t.Fatalf("unknown ownership accepted: %v", got)
	}
}

func TestAndroidPreflightSeparatesProfileAndHostFailures(t *testing.T) {
	for _, test := range []struct {
		name string
		err  error
		code string
	}{
		{name: "profile", err: androidProfileUnavailableError{message: "AVD missing"}, code: "android_profile_unavailable"},
		{name: "host", err: errors.New("KVM missing"), code: "android_not_ready"},
	} {
		t.Run(test.name, func(t *testing.T) {
			p := testAndroidProfiles(t)
			p.checkHost = func(androidProfileSpec) error { return test.err }
			got := p.handle(context.Background(), "preflight", map[string]any{"action": "start"})
			if got["error_code"] != test.code || p.process != nil || p.lease != nil {
				t.Fatalf("preflight result = %v, want %s without runtime state", got, test.code)
			}
		})
	}
}

func TestAndroidStopFailureKeepsOwnedProcessAndBlocksReplacement(t *testing.T) {
	p := testAndroidProfiles(t)
	cmd := exec.Command("sh", "-c", `trap '' TERM; while :; do sleep 1; done`)
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		_ = cmd.Wait()
		close(done)
	}()
	p.process = &androidOwnedProcess{process: cmd.Process, profile: "api30", done: done}

	// Give the shell time to install its TERM handler before the stop attempt.
	time.Sleep(20 * time.Millisecond)
	ctx, cancel := context.WithTimeout(context.Background(), 40*time.Millisecond)
	defer cancel()
	if err := p.stopProcess(ctx); err == nil {
		t.Fatal("stop unexpectedly succeeded")
	}
	if p.process == nil || !p.process.alive() {
		t.Fatal("failed stop discarded the owned process")
	}

	launched := false
	p.launch = func(context.Context, string, ...string) error {
		launched = true
		return nil
	}
	profile, _ := p.findProfile("api35")
	ctx, cancel = context.WithTimeout(context.Background(), 40*time.Millisecond)
	err := p.ensureReady(ctx, profile)
	cancel()
	if err == nil || launched {
		t.Fatalf("stop failure launched a replacement: %v", err)
	}

	if err := cmd.Process.Kill(); err != nil && !errors.Is(err, os.ErrProcessDone) {
		t.Fatal(err)
	}
	<-done
	p.process = nil
}

func TestAndroidProfileManifestAndProcessOwnership(t *testing.T) {
	p := testAndroidProfiles(t)
	valid := []byte(filepath.Join(p.cfg.androidSDKRoot, "emulator/qemu/linux-x86_64/qemu-system-x86_64-headless") + "\x00@avd35\x00-port\x005554\x00")
	profile, _ := p.findProfile("api35")
	if !p.matchesAndroidProcess(valid, profile) {
		t.Fatal("owned emulator rejected")
	}
	for _, bad := range [][]byte{
		[]byte(strings.ReplaceAll(string(valid), "@avd35", "@other")),
		[]byte(strings.ReplaceAll(string(valid), "5554", "5556")),
		[]byte(strings.ReplaceAll(string(valid), "qemu-system-x86_64-headless", "unrelated")),
	} {
		if p.matchesAndroidProcess(bad, profile) {
			t.Fatal("unowned process accepted")
		}
	}
	for _, mutate := range []func(*androidProfilesConfig){
		func(c *androidProfilesConfig) { c.DefaultProfile = "missing" },
		func(c *androidProfilesConfig) { c.Profiles[1].AVDName = c.Profiles[0].AVDName },
		func(c *androidProfilesConfig) { c.Profiles[0].ID = "../bad" },
		func(c *androidProfilesConfig) { c.Profiles[0].ABI = "arm64" },
	} {
		c := p.profiles
		c.Profiles = append([]androidProfileSpec(nil), c.Profiles...)
		mutate(&c)
		data, _ := json.Marshal(c)
		os.WriteFile(p.cfg.androidProfilesFile, data, 0600)
		if _, err := loadAndroidProfiles(p.cfg.androidProfilesFile); err == nil {
			t.Fatal("invalid manifest accepted")
		}
	}
	oversized := append([]byte(`{"default_profile":"api35","profiles":[]}`), make([]byte, 64<<10)...)
	if err := os.WriteFile(p.cfg.androidProfilesFile, oversized, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := loadAndroidProfiles(p.cfg.androidProfilesFile); err == nil {
		t.Fatal("oversized manifest accepted")
	}
}

func TestAndroidMetadataReportsConfiguredButUnavailableProfiles(t *testing.T) {
	p := testAndroidProfiles(t)
	for _, detail := range p.details {
		detail["status"] = "unavailable"
		detail["issue"] = "avd_missing"
	}

	c, err := newConnector(config{
		name:                "android-metadata",
		root:                t.TempDir(),
		runNonce:            "77777777777777777777777777777777",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	c.android = p
	capabilities := c.metadata().Capabilities
	if capabilities["android_device_tool"] != false {
		t.Fatalf("unavailable profiles advertised the tool: %v", capabilities)
	}
	android, ok := capabilities["android"].(map[string]any)
	if !ok || android["protocol_version"] != 2 || len(android["profile_details"].([]map[string]any)) != 2 {
		t.Fatalf("configured profile issues were not projected: %v", capabilities)
	}
	if android["state"] != "unavailable" || android["available_slots"] != 0 {
		t.Fatalf("unavailable profile state is ambiguous: %v", android)
	}
}
