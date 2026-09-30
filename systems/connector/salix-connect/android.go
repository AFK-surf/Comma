package main

// The Connector owns the single Android slot, lease and observation state.
// See docs/compute-devices.md for the runtime contract.

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/xml"
	"errors"
	"fmt"
	"image"
	_ "image/png"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	androidLeaseTTL         = 15 * time.Minute
	androidBootTimeout      = 150 * time.Second
	androidStopTimeout      = 30 * time.Second
	androidCleanupTimeout   = 20 * time.Second
	androidSwitchTimeout    = 200 * time.Second
	androidCommandTimeout   = 20 * time.Second
	androidMaxTransferBytes = 256 << 20
	androidMaxElements      = 300
)

var (
	androidPackagePattern = regexp.MustCompile(`^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+$`)
	androidGuestPattern   = regexp.MustCompile(`^/(?:sdcard|data/local/tmp)(?:/[^\x00]*)?$`)
	androidBoundsPattern  = regexp.MustCompile(`^\[(\d+),(\d+)\]\[(\d+),(\d+)\]$`)
)

type androidProvider struct {
	cfg config
	mu  sync.Mutex

	profiles      androidProfilesConfig
	details       []map[string]any
	configErr     error
	activeProfile string
	targetProfile string
	phase         string
	lastError     string
	busy          bool
	hostSupported bool

	generation      string
	lease           *androidLease
	observation     *androidObservation
	ownerLock       *os.File
	nextEpoch       uint64
	nextObservation uint64

	now       func() time.Time
	run       func(context.Context, string, ...string) ([]byte, error)
	launch    func(context.Context, string, ...string) error
	checkHost func(androidProfileSpec) error
	process   *androidOwnedProcess
	discover  func(context.Context) (*androidOwnedProcess, error)
}

type androidLease struct {
	id          string
	profile     string
	epoch       uint64
	operationID string
	expiresAt   time.Time
	stagingRoot string
	ttl         time.Duration
}

type androidObservation struct {
	id       uint64
	elements map[string]androidElement
}

type androidElement struct {
	Ref         string `json:"ref"`
	Text        string `json:"text,omitempty"`
	Description string `json:"description,omitempty"`
	ResourceID  string `json:"resource_id,omitempty"`
	Class       string `json:"class,omitempty"`
	Bounds      string `json:"bounds"`
	Clickable   bool   `json:"clickable,omitempty"`
	Scrollable  bool   `json:"scrollable,omitempty"`
	X           int    `json:"-"`
	Y           int    `json:"-"`
}

type androidProfileUnavailableError struct {
	message string
}

func (e androidProfileUnavailableError) Error() string {
	return e.message
}

type androidXMLNode struct {
	XMLName     xml.Name         `xml:"node"`
	Text        string           `xml:"text,attr"`
	Description string           `xml:"content-desc,attr"`
	ResourceID  string           `xml:"resource-id,attr"`
	Class       string           `xml:"class,attr"`
	Bounds      string           `xml:"bounds,attr"`
	Clickable   bool             `xml:"clickable,attr"`
	Scrollable  bool             `xml:"scrollable,attr"`
	Children    []androidXMLNode `xml:"node"`
}

type androidXMLHierarchy struct {
	Nodes []androidXMLNode `xml:"node"`
}

func newAndroidProvider(cfg config) *androidProvider {
	p := &androidProvider{
		cfg: cfg, generation: randomAndroidToken(), now: time.Now,
		hostSupported: runtime.GOOS == "linux" && runtime.GOARCH == "amd64",
	}
	p.run = p.runCommand
	p.launch = p.launchCommand
	p.checkHost = p.preflight
	p.discover = p.discoverProcess
	if cfg.androidEnabled {
		p.profiles, p.configErr = loadAndroidProfiles(cfg.androidProfilesFile)
		if p.configErr == nil {
			p.details = p.profileDetails()
		}
	}
	return p
}

func (p *androidProvider) available() bool {
	if !p.configured() || !p.hostSupported || p.cfg.androidSDKRoot == "" ||
		p.cfg.androidRuntimeRoot == "" || p.cfg.androidAVDHome == "" || p.cfg.androidSerial == "" {
		return false
	}
	for _, detail := range p.details {
		if detail["status"] == "installed" {
			return true
		}
	}
	return false
}

func (p *androidProvider) configured() bool {
	return p != nil && p.cfg.androidEnabled && p.configErr == nil && len(p.profiles.Profiles) > 0
}

func (p *androidProvider) metadata() map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.expireIdleLease()
	result := p.statusSnapshot()
	ids := make([]string, 0, len(p.profiles.Profiles))
	for _, profile := range p.profiles.Profiles {
		ids = append(ids, profile.ID)
	}
	result["protocol_version"] = 2
	result["profiles"] = ids
	result["profile_details"] = p.details
	result["default_profile"] = p.profiles.DefaultProfile
	delete(result, "ok")
	return result
}

func (p *androidProvider) handle(ctx context.Context, operationID string, params map[string]any) map[string]any {
	if !p.available() {
		return androidError("android_capability_missing", "Android control requires a valid installed profile manifest on this Connector")
	}
	action := strings.ReplaceAll(strings.ToLower(strings.TrimSpace(stringValue(params["action"]))), "-", "_")
	if action == "" {
		return androidError("android_invalid_request", "'action' is required")
	}
	p.mu.Lock()
	p.expireIdleLease()
	if action == "status" {
		result := p.statusSnapshot()
		p.mu.Unlock()
		return result
	}
	if p.busy {
		p.mu.Unlock()
		return androidError("android_capacity_exhausted", "an Android operation is in progress; wait for its result")
	}
	p.busy = true
	p.mu.Unlock()
	defer func() {
		p.mu.Lock()
		p.busy = false
		p.mu.Unlock()
	}()
	if action == "start" {
		return p.start(ctx, operationID, params)
	}
	lease, failure := p.requireLease(params)
	if failure != nil {
		return failure
	}
	if stringValue(params["profile"]) != lease.profile {
		return androidError("android_profile_mismatch", "use the profile returned with this lease")
	}
	var result map[string]any
	switch action {
	case "observe":
		result = p.observe(ctx, lease)
	case "tap", "swipe", "type", "key", "launch", "clipboard_set", "clipboard_get":
		if failure := p.requireObservation(params); failure != nil {
			return failure
		}
		result = p.act(ctx, action, params)
	case "install", "push", "pull":
		result = p.transfer(ctx, action, lease, params)
	case "diagnose":
		result = p.diagnose(ctx)
	case "end":
		return p.end(ctx, lease)
	default:
		return androidError("android_invalid_request", "unsupported Android action")
	}
	p.mu.Lock()
	renewAndroidLeaseOnSuccess(lease, result, p.now())
	p.mu.Unlock()
	return result
}

func (p *androidProvider) expireIdleLease() {
	if !p.busy {
		p.expireLease()
	}
}

func renewAndroidLeaseOnSuccess(lease *androidLease, result map[string]any, now time.Time) {
	if result["ok"] == true {
		lease.expiresAt = now.Add(lease.ttl)
	}
}

func (p *androidProvider) start(ctx context.Context, operationID string, params map[string]any) map[string]any {
	profileID, supplied := params["profile"]
	if !supplied {
		profileID = p.profiles.DefaultProfile
	}
	profile, ok := p.findProfile(stringValue(profileID))
	if !ok {
		return androidError("android_profile_unavailable", "select an installed profile from device.get")
	}
	if p.lease != nil {
		if operationID != "" && p.lease.operationID == operationID && p.lease.profile == profile.ID {
			return p.leaseResponse(p.lease, true)
		}
		return androidError("android_capacity_exhausted", "the Android device already has an active lease")
	}
	ttl, err := androidLeaseDuration(params["lease_seconds"])
	if err != nil {
		return androidError("invalid_request", err.Error())
	}
	if err := p.checkHost(profile); err != nil {
		var unavailable androidProfileUnavailableError
		if errors.As(err, &unavailable) {
			return androidError("android_profile_unavailable", err.Error())
		}
		return androidError("android_not_ready", err.Error())
	}
	if p.ownerLock == nil {
		if err := os.MkdirAll(p.cfg.androidRuntimeRoot, 0o700); err != nil {
			return androidError("android_not_ready", "create Android runtime root: "+err.Error())
		}
		lock, err := acquireAndroidOwnerLock(filepath.Join(p.cfg.androidRuntimeRoot, "owner.lock"))
		if err != nil {
			return androidError("android_capacity_exhausted", err.Error())
		}
		p.ownerLock = lock
	}
	p.setPhase(profile.ID, "checking", "")
	switchCtx, cancel := context.WithTimeout(ctx, androidSwitchTimeout-androidCleanupTimeout)
	defer cancel()
	if err := p.ensureReady(switchCtx, profile); err != nil {
		return p.failStart(profile, err)
	}
	if err := switchCtx.Err(); err != nil {
		return p.failStart(profile, err)
	}
	p.mu.Lock()
	if err := switchCtx.Err(); err != nil {
		p.mu.Unlock()
		return p.failStart(profile, err)
	}
	defer p.mu.Unlock()
	p.nextEpoch++
	id := randomAndroidToken()
	staging := filepath.Join(p.cfg.androidRuntimeRoot, "leases", id)
	if err := os.MkdirAll(staging, 0o700); err != nil {
		p.targetProfile, p.phase, p.lastError = "", "", "could not create lease staging"
		return androidError("android_not_ready", "create lease staging: "+err.Error())
	}
	p.lease = &androidLease{id: id, profile: profile.ID, epoch: p.nextEpoch, operationID: operationID,
		expiresAt: p.now().Add(ttl), stagingRoot: staging, ttl: ttl}
	p.activeProfile, p.targetProfile, p.phase, p.lastError = profile.ID, "", "", ""
	p.observation = nil
	return p.leaseResponse(p.lease, false)
}

func (p *androidProvider) leaseResponse(lease *androidLease, replay bool) map[string]any {
	return map[string]any{"ok": true, "state": "ready", "profile": lease.profile, "lease_id": lease.id,
		"lease_epoch": lease.epoch, "expires_at": lease.expiresAt.UTC().Format(time.RFC3339), "replayed": replay}
}

func (p *androidProvider) setPhase(target, phase, failure string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.targetProfile, p.phase, p.lastError = target, phase, failure
}

func (p *androidProvider) requireLease(params map[string]any) (*androidLease, map[string]any) {
	if p.lease == nil {
		return nil, androidError("android_lease_expired", "start the Android device before this action")
	}
	id := strings.TrimSpace(stringValue(params["lease_id"]))
	epoch, ok := uint64Value(params["lease_epoch"])
	if id == "" || !ok || id != p.lease.id || epoch != p.lease.epoch {
		return nil, androidError("android_stale_lease", "the Android lease is absent, expired, ended, or belongs to an earlier Connector generation")
	}
	return p.lease, nil
}

func (p *androidProvider) requireObservation(params map[string]any) map[string]any {
	id, ok := uint64Value(params["observation_id"])
	if !ok || p.observation == nil || id != p.observation.id {
		return androidError("android_stale_observation", "observe again before acting on the current screen")
	}
	return nil
}

func (p *androidProvider) expireLease() {
	if p.lease != nil && !p.now().Before(p.lease.expiresAt) {
		_ = os.RemoveAll(p.lease.stagingRoot)
		p.lease = nil
		p.observation = nil
	}
}

func (p *androidProvider) preflight(profile androidProfileSpec) error {
	if runtime.GOOS != "linux" || runtime.GOARCH != "amd64" {
		return errors.New("Android profiles require Linux x86_64")
	}
	if info, err := os.Stat("/dev/kvm"); err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return errors.New("/dev/kvm is unavailable")
	}
	for label, path := range map[string]string{"adb": p.adbPath(), "emulator": p.emulatorPath()} {
		if info, err := os.Stat(path); err != nil || info.IsDir() {
			return fmt.Errorf("%s binary is unavailable", label)
		}
	}
	avdRoot := filepath.Join(p.cfg.androidAVDHome, profile.AVDName+".avd")
	if info, err := os.Stat(avdRoot); err != nil || !info.IsDir() {
		return androidProfileUnavailableError{message: "configured Android AVD is unavailable"}
	}
	if info, err := os.Stat(filepath.Join(avdRoot, "config.ini")); err != nil || !info.Mode().IsRegular() {
		return androidProfileUnavailableError{message: "configured Android AVD is incomplete"}
	}
	resolvedRuntimeRoot, err := prepareAndroidRuntimeRoot(p.cfg.root, p.cfg.androidRuntimeRoot)
	if err != nil {
		return err
	}
	if resolvedRuntimeRoot != p.cfg.androidRuntimeRoot {
		return errors.New("Android runtime root must use its resolved path")
	}
	if err := checkAndroidHostCapacity(resolvedRuntimeRoot); err != nil {
		return err
	}
	return nil
}

func prepareAndroidRuntimeRoot(connectorRoot, runtimeRoot string) (string, error) {
	connectorRoot = filepath.Clean(connectorRoot)
	runtimeRoot = filepath.Clean(runtimeRoot)
	if !filepath.IsAbs(connectorRoot) || !filepath.IsAbs(runtimeRoot) || !pathInsideRoot(connectorRoot, runtimeRoot) {
		return "", errors.New("Android runtime root must be an absolute path inside the Connector root")
	}
	resolvedCandidate, err := resolveExistingPrefix(runtimeRoot)
	if err != nil || !pathInsideRoot(connectorRoot, resolvedCandidate) {
		return "", errors.New("Android runtime root must resolve inside the Connector root")
	}
	if err := os.MkdirAll(resolvedCandidate, 0o700); err != nil {
		return "", fmt.Errorf("create Android runtime root: %w", err)
	}
	resolvedRuntimeRoot, err := filepath.EvalSymlinks(resolvedCandidate)
	if err != nil || !pathInsideRoot(connectorRoot, resolvedRuntimeRoot) {
		return "", errors.New("Android runtime root must resolve inside the Connector root")
	}
	return resolvedRuntimeRoot, nil
}

func (p *androidProvider) ensureReady(ctx context.Context, profile androidProfileSpec) error {
	if p.process != nil && !p.process.alive() {
		p.process.release()
		p.process = nil
	}
	if p.process == nil {
		owned, err := p.discover(ctx)
		if err != nil {
			return err
		}
		p.process = owned
	}
	if p.process != nil && p.process.profile == profile.ID {
		probeCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
		err := p.profileReady(probeCtx, profile)
		cancel()
		if err == nil {
			if p.process == nil || !p.process.alive() {
				return errors.New("emulator exited before readiness")
			}
			return nil
		}
	}
	if p.process != nil {
		p.setPhase(profile.ID, "stopping", "")
		stopCtx, cancel := context.WithTimeout(ctx, androidStopTimeout)
		err := p.stopProcess(stopCtx)
		cancel()
		if err != nil {
			return err
		}
	}
	if p.process == nil {
		p.setPhase(profile.ID, "booting", "")
		if err := p.launch(ctx, filepath.Join(p.cfg.androidRuntimeRoot, "emulator.log"), profile.AVDName); err != nil {
			return fmt.Errorf("launch emulator: %w", err)
		}
		if p.process != nil {
			p.process.profile = profile.ID
		}
	}
	p.setPhase(profile.ID, "waiting_ready", "")
	bootCtx, cancel := context.WithTimeout(ctx, androidBootTimeout)
	defer cancel()
	var last error
	for {
		probeCtx, cancel := context.WithTimeout(bootCtx, 8*time.Second)
		last = p.profileReady(probeCtx, profile)
		cancel()
		if last == nil {
			if p.process == nil || !p.process.alive() {
				return errors.New("emulator exited before readiness")
			}
			return bootCtx.Err()
		}
		if p.process != nil && !p.process.alive() {
			return errors.New("emulator exited before readiness")
		}
		select {
		case <-bootCtx.Done():
			return fmt.Errorf("emulator readiness deadline: %w; %v", bootCtx.Err(), last)
		case <-time.After(time.Second):
		}
	}
}

func (p *androidProvider) profileReady(ctx context.Context, profile androidProfileSpec) error {
	name, err := p.adb(ctx, "emu", "avd", "name")
	if err != nil || strings.TrimSpace(strings.SplitN(string(name), "\n", 2)[0]) != profile.AVDName {
		return errors.New("ADB serial does not identify the requested AVD")
	}
	api, err := p.adb(ctx, "shell", "getprop", "ro.build.version.sdk")
	if err != nil || strings.TrimSpace(string(api)) != strconv.Itoa(profile.APILevel) {
		return errors.New("running Android API does not match the profile")
	}
	abis, err := p.adb(ctx, "shell", "getprop", "ro.product.cpu.abilist")
	found := false
	for _, abi := range strings.Split(strings.TrimSpace(string(abis)), ",") {
		if abi == profile.ABI {
			found = true
		}
	}
	if err != nil || !found {
		return errors.New("running Android ABI does not match the profile")
	}
	return p.strictReady(ctx)
}

func (p *androidProvider) failStart(profile androidProfileSpec, cause error) map[string]any {
	p.setPhase(profile.ID, "cleanup", "")
	cleanupCtx, cancel := context.WithTimeout(context.Background(), androidCleanupTimeout)
	defer cancel()
	if p.process != nil {
		if err := p.stopProcess(cleanupCtx); err != nil {
			cause = fmt.Errorf("%v; emulator cleanup requires administrator action: %w", cause, err)
		}
	}
	p.mu.Lock()
	p.activeProfile = ""
	p.mu.Unlock()
	message := boundedAndroidOutput([]byte(cause.Error()))
	p.setPhase("", "", message)
	return androidError("android_recovery_failed", message)
}

func (p *androidProvider) strictReady(ctx context.Context) error {
	state, err := p.run(ctx, p.adbPath(), "-s", p.cfg.androidSerial, "get-state")
	if err != nil || strings.TrimSpace(string(state)) != "device" {
		return errors.New("ADB device is not online")
	}
	for _, prop := range []string{"sys.boot_completed", "dev.bootcomplete"} {
		out, err := p.adb(ctx, "shell", "getprop", prop)
		if err != nil || strings.TrimSpace(string(out)) != "1" {
			return fmt.Errorf("boot property %s is not ready", prop)
		}
	}
	for _, service := range []string{"package", "window", "input", "accessibility"} {
		out, err := p.adb(ctx, "shell", "service", "check", service)
		if err != nil || !strings.Contains(string(out), "found") {
			return fmt.Errorf("Android service %s is unavailable", service)
		}
	}
	if _, err := p.dumpUI(ctx); err != nil {
		return fmt.Errorf("UiAutomator is unavailable: %w", err)
	}
	window, err := p.adb(ctx, "shell", "dumpsys", "window")
	if err != nil || (!bytes.Contains(window, []byte("mCurrentFocus")) && !bytes.Contains(window, []byte("mFocusedApp"))) {
		return errors.New("Android has no focused window")
	}
	return nil
}

// The caller holds mu. State reads never run ADB or wait for a boot command.
func (p *androidProvider) statusSnapshot() map[string]any {
	state := "idle"
	slots := 1
	if !p.available() {
		state, slots = "unavailable", 0
	}
	if p.activeProfile != "" {
		state = "ready"
	}
	if p.lease != nil {
		state, slots = "leased", 0
	}
	if p.targetProfile != "" {
		state, slots = "preparing", 0
	}
	if p.busy {
		slots = 0
	}
	if p.lastError != "" {
		state = "error"
	}
	result := map[string]any{"ok": true, "state": state, "capacity": 1, "available_slots": slots,
		"active_profile": p.activeProfile, "target_profile": p.targetProfile, "phase": p.phase}
	if p.lease != nil {
		result["profile"] = p.lease.profile
		result["leased"] = true
		result["expires_at"] = p.lease.expiresAt.UTC().Format(time.RFC3339)
	}
	if p.lastError != "" {
		result["error"] = p.lastError
	}
	return result
}

func (p *androidProvider) observe(ctx context.Context, lease *androidLease) map[string]any {
	xmlData, err := p.dumpUI(ctx)
	if err != nil {
		return androidError("android_not_ready", err.Error())
	}
	png, err := p.adb(ctx, "exec-out", "screencap", "-p")
	if err != nil {
		return androidError("android_not_ready", "capture screenshot: "+err.Error())
	}
	elements, indexed, err := parseAndroidElements(xmlData)
	if err != nil {
		return androidError("android_not_ready", "parse UI hierarchy: "+err.Error())
	}
	p.nextObservation++
	id := p.nextObservation
	screenshotPath := filepath.Join(lease.stagingRoot, "observation.png")
	if err := writeAndroidStagedFile(lease.stagingRoot, screenshotPath, png); err != nil {
		return androidError("android_not_ready", "stage screenshot: "+err.Error())
	}
	relScreenshotPath, err := filepath.Rel(p.cfg.root, screenshotPath)
	if err != nil || relScreenshotPath == ".." || strings.HasPrefix(relScreenshotPath, ".."+string(filepath.Separator)) {
		return androidError("invalid_path", "staged screenshot is outside the Connector root")
	}
	p.observation = &androidObservation{id: id, elements: indexed}
	result := map[string]any{
		"ok": true, "state": "ready", "observation_id": id, "elements": elements,
		"screenshot_source_path": filepath.ToSlash(relScreenshotPath),
		"image_content_type":     "image/png",
		"image_size_bytes":       len(png),
	}
	if cfg, _, err := image.DecodeConfig(bytes.NewReader(png)); err == nil {
		result["image_width"], result["image_height"] = cfg.Width, cfg.Height
	}
	return result
}

func (p *androidProvider) act(ctx context.Context, action string, params map[string]any) map[string]any {
	var args []string
	switch action {
	case "tap":
		x, y, err := p.target(params)
		if err != nil {
			return androidError("invalid_request", err.Error())
		}
		args = []string{"shell", "input", "tap", strconv.Itoa(x), strconv.Itoa(y)}
	case "swipe":
		x1, ok1 := intValue(params["x1"])
		y1, ok2 := intValue(params["y1"])
		x2, ok3 := intValue(params["x2"])
		y2, ok4 := intValue(params["y2"])
		if !ok1 || !ok2 || !ok3 || !ok4 {
			return androidError("invalid_request", "swipe requires integer x1, y1, x2, and y2")
		}
		duration, ok := intValue(params["duration_ms"])
		if !ok {
			duration = 300
		}
		if duration < 50 || duration > 5000 {
			return androidError("invalid_request", "duration_ms must be between 50 and 5000")
		}
		args = []string{"shell", "input", "swipe", strconv.Itoa(x1), strconv.Itoa(y1), strconv.Itoa(x2), strconv.Itoa(y2), strconv.Itoa(duration)}
	case "type":
		value := stringValue(params["text"])
		if len([]byte(value)) > 4096 {
			return androidError("invalid_request", "text exceeds 4096 bytes")
		}
		args = []string{"shell", "input", "text", strings.ReplaceAll(value, " ", "%s")}
	case "key":
		key := strings.ToUpper(strings.TrimSpace(stringValue(params["key"])))
		if !allowedAndroidKey(key) {
			return androidError("invalid_request", "key is not allowed")
		}
		args = []string{"shell", "input", "keyevent", key}
	case "launch":
		pkg := strings.TrimSpace(stringValue(params["package"]))
		if !androidPackagePattern.MatchString(pkg) {
			return androidError("invalid_request", "invalid package name")
		}
		args = []string{"shell", "monkey", "-p", pkg, "-c", "android.intent.category.LAUNCHER", "1"}
	case "clipboard_set":
		value := stringValue(params["text"])
		if len([]byte(value)) > 64<<10 {
			return androidError("invalid_request", "clipboard exceeds 64 KiB")
		}
		out, err := p.adb(ctx, "shell", "cmd", "clipboard", "set", value)
		if err != nil {
			return androidError("action_failed", err.Error())
		}
		if androidClipboardUnavailable(out) {
			return androidClipboardUnavailableError()
		}
		p.observation = nil
		return map[string]any{"ok": true, "observation_required": true}
	case "clipboard_get":
		out, err := p.adb(ctx, "shell", "cmd", "clipboard", "get")
		if err != nil {
			return androidError("action_failed", err.Error())
		}
		if androidClipboardUnavailable(out) {
			return androidClipboardUnavailableError()
		}
		p.observation = nil
		return map[string]any{"ok": true, "text": strings.TrimRight(string(out), "\r\n"), "observation_required": true}
	}
	if _, err := p.adb(ctx, args...); err != nil {
		return androidError("action_failed", err.Error())
	}
	p.observation = nil
	return map[string]any{"ok": true, "observation_required": true}
}

func androidClipboardUnavailable(output []byte) bool {
	message := strings.ToLower(strings.TrimSpace(string(output)))
	return message == "no shell command implementation." ||
		message == "no shell command implementation" ||
		message == "unknown command: clipboard"
}

func androidClipboardUnavailableError() map[string]any {
	return androidError(
		"android_clipboard_unavailable",
		"clipboard control is unavailable on this Android image; use type on a focused text field instead",
	)
}

func (p *androidProvider) target(params map[string]any) (int, int, error) {
	if ref := strings.TrimSpace(stringValue(params["ref"])); ref != "" {
		el, ok := p.observation.elements[ref]
		if !ok {
			return 0, 0, errors.New("element ref is not in the current observation")
		}
		return el.X, el.Y, nil
	}
	x, okX := intValue(params["x"])
	y, okY := intValue(params["y"])
	if !okX || !okY || x < 0 || y < 0 {
		return 0, 0, errors.New("tap requires a current ref or non-negative integer x and y")
	}
	return x, y, nil
}

func (p *androidProvider) transfer(ctx context.Context, action string, lease *androidLease, params map[string]any) map[string]any {
	guest := strings.TrimSpace(stringValue(params["guest_path"]))
	if action != "install" && !androidGuestPattern.MatchString(guest) {
		return androidError("invalid_path", "guest_path must be under /sdcard or /data/local/tmp")
	}
	name := strings.TrimSpace(stringValue(params["staging_name"]))
	local, err := safeAndroidStagingPath(lease.stagingRoot, name)
	if err != nil {
		return androidError("invalid_path", err.Error())
	}
	switch action {
	case "install", "push":
		source, sourceErr := p.importStagedInput(lease, params, local)
		if sourceErr != nil {
			return androidError("invalid_path", sourceErr.Error())
		}
		local = source
		info, err := os.Stat(local)
		if err != nil || !info.Mode().IsRegular() {
			return androidError("invalid_path", "staged input is not a regular file")
		}
		if info.Size() > androidMaxTransferBytes {
			return androidError("too_large", "file exceeds 256 MiB")
		}
		args := []string{"push", local, guest}
		if action == "install" {
			if strings.ToLower(filepath.Ext(local)) != ".apk" {
				return androidError("invalid_type", "install accepts only .apk files")
			}
			args = []string{"install", "-r", local}
		}
		if _, err := p.adb(ctx, args...); err != nil {
			return androidError("transfer_failed", err.Error())
		}
	case "pull":
		temporary, err := os.CreateTemp(lease.stagingRoot, ".pull-*")
		if err != nil {
			return androidError("transfer_failed", err.Error())
		}
		temporaryPath := temporary.Name()
		_ = temporary.Close()
		defer os.Remove(temporaryPath)
		if _, err := p.adb(ctx, "pull", guest, temporaryPath); err != nil {
			return androidError("transfer_failed", err.Error())
		}
		info, err := os.Lstat(temporaryPath)
		if err != nil || !info.Mode().IsRegular() || info.Size() > androidMaxTransferBytes {
			return androidError("too_large", "pulled file is invalid or exceeds 256 MiB")
		}
		if err := os.Rename(temporaryPath, local); err != nil {
			return androidError("transfer_failed", err.Error())
		}
	}
	result := map[string]any{"ok": true, "staging_name": name}
	if action == "pull" {
		rel, err := filepath.Rel(p.cfg.root, local)
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			_ = os.Remove(local)
			return androidError("invalid_path", "pulled file is outside the Connector root")
		}
		result["source_path"] = filepath.ToSlash(rel)
	}
	return result
}

func (p *androidProvider) importStagedInput(lease *androidLease, params map[string]any, target string) (string, error) {
	sourceName := strings.TrimSpace(stringValue(params["source_path"]))
	if sourceName == "" {
		return target, nil
	}
	if filepath.IsAbs(sourceName) {
		return "", errors.New("source_path must be relative to the Connector root")
	}
	source := filepath.Join(p.cfg.root, filepath.Clean(sourceName))
	resolvedSource, err := filepath.EvalSymlinks(source)
	if err != nil || resolvedSource != filepath.Clean(source) || !pathInsideRoot(p.cfg.root, resolvedSource) {
		return "", errors.New("source_path escapes the Connector root")
	}
	info, err := os.Lstat(resolvedSource)
	if err != nil || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 {
		return "", errors.New("source_path is not a regular file")
	}
	if info.Size() > androidMaxTransferBytes {
		return "", errors.New("source_path exceeds 256 MiB")
	}
	in, err := os.Open(resolvedSource)
	if err != nil {
		return "", err
	}
	defer in.Close()
	out, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return "", err
	}
	written, copyErr := io.Copy(out, io.LimitReader(in, androidMaxTransferBytes+1))
	closeErr := out.Close()
	if copyErr != nil || closeErr != nil || written > androidMaxTransferBytes {
		_ = os.Remove(target)
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		return "", errors.New("source_path exceeds 256 MiB")
	}
	_ = lease
	return target, nil
}

func (p *androidProvider) diagnose(ctx context.Context) map[string]any {
	state, _ := p.run(ctx, p.adbPath(), "-s", p.cfg.androidSerial, "get-state")
	boot, _ := p.adb(ctx, "shell", "getprop", "sys.boot_completed")
	return map[string]any{"ok": true, "profile": p.lease.profile, "adb_state": strings.TrimSpace(string(state)), "boot_completed": strings.TrimSpace(string(boot)), "generation": p.generation}
}

func (p *androidProvider) end(ctx context.Context, lease *androidLease) map[string]any {
	_ = ctx
	_ = os.RemoveAll(lease.stagingRoot)
	p.mu.Lock()
	p.lease = nil
	p.observation = nil
	p.mu.Unlock()
	return map[string]any{"ok": true, "state": "idle"}
}

func (p *androidProvider) dumpUI(ctx context.Context) ([]byte, error) {
	if _, err := p.adb(ctx, "shell", "uiautomator", "dump", "/data/local/tmp/salix-window.xml"); err != nil {
		return nil, err
	}
	return p.adb(ctx, "exec-out", "cat", "/data/local/tmp/salix-window.xml")
}

func (p *androidProvider) adb(ctx context.Context, args ...string) ([]byte, error) {
	all := append([]string{"-s", p.cfg.androidSerial}, args...)
	return p.run(ctx, p.adbPath(), all...)
}

func (p *androidProvider) runCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	cmdCtx, cancel := context.WithTimeout(ctx, androidCommandTimeout)
	defer cancel()
	cmd := exec.CommandContext(cmdCtx, name, args...)
	cmd.Env = p.commandEnv()
	out, err := cmd.CombinedOutput()
	if err != nil {
		return nil, fmt.Errorf("Android command failed: %w: %s", err, boundedAndroidOutput(out))
	}
	return out, nil
}

func (p *androidProvider) launchCommand(ctx context.Context, logPath string, avd ...string) error {
	logFile, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	cmd := exec.CommandContext(context.WithoutCancel(ctx), p.emulatorPath(), "@"+avd[0], "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot", "-gpu", p.cfg.androidGPU, "-memory", "3072", "-cores", "2", "-port", strings.TrimPrefix(p.cfg.androidSerial, "emulator-"))
	cmd.Env, cmd.Stdout, cmd.Stderr = p.commandEnv(), logFile, logFile
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return err
	}
	done := make(chan struct{})
	p.process = &androidOwnedProcess{process: cmd.Process, done: done}
	go func() { _ = cmd.Wait(); _ = logFile.Close(); close(done) }()
	return nil
}

func (p *androidProvider) commandEnv() []string {
	return append(os.Environ(), "ANDROID_HOME="+p.cfg.androidSDKRoot, "ANDROID_SDK_ROOT="+p.cfg.androidSDKRoot, "ANDROID_AVD_HOME="+p.cfg.androidAVDHome)
}

func (p *androidProvider) adbPath() string {
	return filepath.Join(p.cfg.androidSDKRoot, "platform-tools", "adb")
}
func (p *androidProvider) emulatorPath() string {
	return filepath.Join(p.cfg.androidSDKRoot, "emulator", "emulator")
}

func parseAndroidElements(data []byte) ([]androidElement, map[string]androidElement, error) {
	var hierarchy androidXMLHierarchy
	if err := xml.Unmarshal(data, &hierarchy); err != nil {
		return nil, nil, err
	}
	elements := make([]androidElement, 0, 32)
	indexed := map[string]androidElement{}
	var visit func([]androidXMLNode)
	visit = func(nodes []androidXMLNode) {
		for _, node := range nodes {
			if len(elements) >= androidMaxElements {
				return
			}
			match := androidBoundsPattern.FindStringSubmatch(node.Bounds)
			if len(match) == 5 && (node.Text != "" || node.Description != "" || node.ResourceID != "" || node.Clickable || node.Scrollable) {
				x1, _ := strconv.Atoi(match[1])
				y1, _ := strconv.Atoi(match[2])
				x2, _ := strconv.Atoi(match[3])
				y2, _ := strconv.Atoi(match[4])
				ref := fmt.Sprintf("@%d", len(elements)+1)
				el := androidElement{Ref: ref, Text: node.Text, Description: node.Description, ResourceID: node.ResourceID, Class: node.Class, Bounds: node.Bounds, Clickable: node.Clickable, Scrollable: node.Scrollable, X: (x1 + x2) / 2, Y: (y1 + y2) / 2}
				elements = append(elements, el)
				indexed[ref] = el
			}
			visit(node.Children)
		}
	}
	visit(hierarchy.Nodes)
	return elements, indexed, nil
}

func safeAndroidStagingPath(root, name string) (string, error) {
	if name == "" || filepath.Base(name) != name || name == "." || name == ".." {
		return "", errors.New("staging_name must be one file name")
	}
	target := filepath.Join(root, name)
	rel, err := filepath.Rel(root, target)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("staging path escapes the lease")
	}
	return target, nil
}

func writeAndroidStagedFile(root, target string, data []byte) error {
	temporary, err := os.CreateTemp(root, ".observation-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return err
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return os.Rename(temporaryPath, target)
}

func allowedAndroidKey(key string) bool {
	switch key {
	case "BACK", "HOME", "ENTER", "TAB", "ESCAPE", "DEL", "DPAD_UP", "DPAD_DOWN", "DPAD_LEFT", "DPAD_RIGHT", "DPAD_CENTER", "APP_SWITCH":
		return true
	default:
		return false
	}
}

func androidLeaseDuration(value any) (time.Duration, error) {
	seconds, ok := intValue(value)
	if !ok {
		seconds = int(androidLeaseTTL / time.Second)
	}
	if seconds < 60 || seconds > 3600 {
		return 0, errors.New("lease_seconds must be between 60 and 3600")
	}
	return time.Duration(seconds) * time.Second, nil
}

func randomAndroidToken() string {
	b := make([]byte, 18)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}
func boundedAndroidOutput(data []byte) string {
	const max = 512
	clean := strings.TrimSpace(string(data))
	if len(clean) > max {
		return clean[:max] + "…"
	}
	return clean
}
func androidError(code, message string) map[string]any {
	switch code {
	case "invalid_request", "unsupported_action", "invalid_type":
		code = "android_invalid_request"
	case "invalid_path":
		code = "android_invalid_path"
	case "too_large":
		code = "android_payload_too_large"
	case "action_failed", "transfer_failed":
		code = "android_action_required"
	}
	return map[string]any{"ok": false, "error_code": code, "error": message}
}

func uint64Value(value any) (uint64, bool) {
	switch v := value.(type) {
	case float64:
		if v >= 0 && v == float64(uint64(v)) {
			return uint64(v), true
		}
	case int:
		if v >= 0 {
			return uint64(v), true
		}
	case int64:
		if v >= 0 {
			return uint64(v), true
		}
	case uint64:
		return v, true
	case string:
		n, err := strconv.ParseUint(v, 10, 64)
		return n, err == nil
	}
	return 0, false
}

func intValue(value any) (int, bool) {
	n, ok := uint64Value(value)
	if !ok || n > uint64(^uint(0)>>1) {
		return 0, false
	}
	return int(n), true
}

func cleanOptionalPath(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	return filepath.Clean(value)
}
