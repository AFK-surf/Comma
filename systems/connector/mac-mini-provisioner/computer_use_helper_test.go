package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func computerUseHelperTestArchive(t *testing.T, daemon string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	compressed := gzip.NewWriter(&buffer)
	archive := tar.NewWriter(compressed)
	app := "native/macos/" + computerUseHelperAppName
	for _, directory := range []string{"native/", "native/macos/", app + "/", app + "/Contents/", app + "/Contents/MacOS/"} {
		if err := archive.WriteHeader(&tar.Header{Name: directory, Typeflag: tar.TypeDir, Mode: 0o755}); err != nil {
			t.Fatal(err)
		}
	}
	if err := archive.WriteHeader(&tar.Header{Name: app + "/Contents/MacOS/" + computerUseHelperExecutable, Mode: 0o755, Size: int64(len(daemon))}); err != nil {
		t.Fatal(err)
	}
	if _, err := archive.Write([]byte(daemon)); err != nil {
		t.Fatal(err)
	}
	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatal(err)
	}
	return buffer.Bytes()
}

type computerUseHelperTestHooks struct {
	mu       sync.Mutex
	verified []string
	stopped  []string
}

func stubComputerUseHelperHooks(t *testing.T, verifyErr error) *computerUseHelperTestHooks {
	t.Helper()
	hooks := &computerUseHelperTestHooks{}
	previousVerify, previousStop := verifyCodeSignature, stopComputerUseHelper
	verifyCodeSignature = func(path string) error {
		hooks.mu.Lock()
		defer hooks.mu.Unlock()
		hooks.verified = append(hooks.verified, path)
		return verifyErr
	}
	stopComputerUseHelper = func(app string) bool {
		hooks.mu.Lock()
		defer hooks.mu.Unlock()
		hooks.stopped = append(hooks.stopped, app)
		return true
	}
	computerUseHelperFailedTarget.digest = ""
	lastComputerUseHelperUpdate = nil
	t.Cleanup(func() {
		verifyCodeSignature, stopComputerUseHelper = previousVerify, previousStop
		computerUseHelperFailedTarget.digest = ""
		lastComputerUseHelperUpdate = nil
	})
	return hooks
}

func installedComputerUseHelper(t *testing.T, app string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(app, "Contents", "MacOS", computerUseHelperExecutable))
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func computerUseHelperLeftovers(t *testing.T, app string) []string {
	t.Helper()
	leftovers, err := filepath.Glob(filepath.Join(filepath.Dir(app), computerUseHelperWorkPrefix+"*"))
	if err != nil {
		t.Fatal(err)
	}
	return leftovers
}

func writeComputerUseHelperArchive(t *testing.T, root, name, daemon string) string {
	t.Helper()
	archive := filepath.Join(root, name)
	if err := os.WriteFile(archive, computerUseHelperTestArchive(t, daemon), 0o600); err != nil {
		t.Fatal(err)
	}
	return archive
}

func TestComputerUseHelperArchiveReplacesTheAppAfterItsSignatureVerifies(t *testing.T) {
	hooks := stubComputerUseHelperHooks(t, nil)
	root := t.TempDir()
	app := filepath.Join(root, "bin", "native", "macos", computerUseHelperAppName)
	writeExecutable(t, filepath.Join(app, "Contents", "MacOS", computerUseHelperExecutable), "old")
	archive := filepath.Join(root, computerUseHelperArchive)
	if err := os.WriteFile(archive, computerUseHelperTestArchive(t, "new"), 0o600); err != nil {
		t.Fatal(err)
	}

	if _, err := installComputerUseHelperArchive(archive, app); err != nil {
		t.Fatal(err)
	}
	if got := installedComputerUseHelper(t, app); got != "new" {
		t.Fatalf("installed helper = %q, want new", got)
	}
	// The installed app is checked before leftovers are removed, then the extracted one.
	if len(hooks.verified) != 2 || hooks.verified[0] != app || !strings.Contains(hooks.verified[1], computerUseHelperWorkPrefix) {
		t.Fatalf("signature checks = %v", hooks.verified)
	}
	if len(hooks.stopped) != 1 || hooks.stopped[0] != app {
		t.Fatalf("the replaced helper was not stopped: %v", hooks.stopped)
	}
	if leftovers := computerUseHelperLeftovers(t, app); len(leftovers) != 0 {
		t.Fatalf("staging was left beside the helper: %v", leftovers)
	}
}

func TestComputerUseHelperArchiveWithAnInvalidSignatureKeepsTheInstalledApp(t *testing.T) {
	hooks := stubComputerUseHelperHooks(t, errors.New("a sealed resource is missing or invalid"))
	root := t.TempDir()
	app := filepath.Join(root, "native", "macos", computerUseHelperAppName)
	writeExecutable(t, filepath.Join(app, "Contents", "MacOS", computerUseHelperExecutable), "old")
	archive := filepath.Join(root, computerUseHelperArchive)
	if err := os.WriteFile(archive, computerUseHelperTestArchive(t, "tampered"), 0o600); err != nil {
		t.Fatal(err)
	}

	_, err := installComputerUseHelperArchive(archive, app)
	if code := provisionerFailureCode(err, ""); code != "computer_use_helper.signature_invalid" {
		t.Fatalf("failure code = %q (%v)", code, err)
	}
	if got := installedComputerUseHelper(t, app); got != "old" {
		t.Fatalf("installed helper = %q, want old", got)
	}
	if len(hooks.stopped) != 0 {
		t.Fatalf("the running helper was stopped without a replacement: %v", hooks.stopped)
	}
	if leftovers := computerUseHelperLeftovers(t, app); len(leftovers) != 0 {
		t.Fatalf("staging was left beside the helper: %v", leftovers)
	}
}

func TestWorkerInstallsTheServerBoundComputerUseHelperOnce(t *testing.T) {
	stubComputerUseHelperHooks(t, nil)
	archive := computerUseHelperTestArchive(t, "release")
	digest := sha256.Sum256(archive)
	var downloads atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		downloads.Add(1)
		_, _ = w.Write(archive)
	}))
	defer server.Close()
	previousTransport := http.DefaultTransport
	http.DefaultTransport = server.Client().Transport
	defer func() { http.DefaultTransport = previousTransport }()

	root := t.TempDir()
	configPath := filepath.Join(root, "runner.json")
	config := map[string]any{"paths": map[string]any{"salix_connect": filepath.Join(root, "bin", "salix-connect")}}
	opts := runOptions{start: true, timeout: 5 * time.Second, configPath: configPath}
	statusPath := filepath.Join(root, "status.json")
	heartbeat := func(sha string) map[string]any {
		return map[string]any{"updates": map[string]any{computerUseHelperComponent: map[string]any{
			"component": computerUseHelperComponent, "artifact_url": server.URL + "/" + computerUseHelperArchive,
			"release_id": strings.Repeat("c", 40), "sha256": sha, "size": len(archive),
		}}}
	}

	for range 2 {
		exclusive, _, err := applyProvisionerUpdates(opts, config, filepath.Join(root, "state"), statusPath, map[string]*managedConnector{}, heartbeat(hex.EncodeToString(digest[:])))
		if err != nil || exclusive {
			t.Fatalf("helper update blocked runner work: exclusive=%v err=%v", exclusive, err)
		}
	}
	app := filepath.Join(root, "bin", "native", "macos", computerUseHelperAppName)
	if got := installedComputerUseHelper(t, app); got != "release" {
		t.Fatalf("installed helper = %q, want release", got)
	}
	if downloads.Load() != 1 {
		t.Fatalf("an installed helper was downloaded again: %d downloads", downloads.Load())
	}

	// A recorded digest does not hide a damaged helper.
	if err := os.Remove(computerUseHelperExecutablePath(app)); err != nil {
		t.Fatal(err)
	}
	if _, _, err := applyProvisionerUpdates(opts, config, filepath.Join(root, "state"), statusPath, map[string]*managedConnector{}, heartbeat(hex.EncodeToString(digest[:]))); err != nil {
		t.Fatal(err)
	}
	if got := installedComputerUseHelper(t, app); got != "release" || downloads.Load() != 2 {
		t.Fatalf("damaged helper was not reinstalled: %q after %d downloads", got, downloads.Load())
	}
	persisted, err := loadJSON(configPath)
	if err != nil || mapValue(mapValue(persisted, "capabilities"), "component_digests")[computerUseHelperComponent] != hex.EncodeToString(digest[:]) {
		t.Fatalf("installed helper digest was not persisted: %v %v", persisted, err)
	}

	// A digest mismatch leaves the installed helper and does not retry at once.
	wrong := strings.Repeat("d", 64)
	for range 2 {
		exclusive, _, err := applyProvisionerUpdates(opts, config, filepath.Join(root, "state"), statusPath, map[string]*managedConnector{}, heartbeat(wrong))
		if err != nil || exclusive {
			t.Fatalf("failed helper update blocked runner work: exclusive=%v err=%v", exclusive, err)
		}
	}
	if downloads.Load() != 3 {
		t.Fatalf("failed helper target downloads = %d, want 3", downloads.Load())
	}
	if got := installedComputerUseHelper(t, app); got != "release" {
		t.Fatalf("installed helper = %q after a failed update", got)
	}
	status, err := loadJSON(statusPath)
	if err != nil || mapValue(status, "computer_use_helper_update")["failure_code"] != "computer_use_helper.sha_mismatch" {
		t.Fatalf("failed helper update status = %v %v", status, err)
	}
}

func TestWorkerWithoutAComputerUseHelperTargetLeavesTheHelperAlone(t *testing.T) {
	hooks := stubComputerUseHelperHooks(t, nil)
	root := t.TempDir()
	config := map[string]any{"paths": map[string]any{"salix_connect": filepath.Join(root, "salix-connect")}}
	opts := runOptions{start: true, timeout: time.Second, configPath: filepath.Join(root, "runner.json")}
	for _, updates := range []map[string]any{
		{},
		{computerUseHelperComponent: map[string]any{"component": computerUseHelperComponent, "error": "server_release_unavailable"}},
	} {
		exclusive, _, err := applyProvisionerUpdates(opts, config, root, filepath.Join(root, "status.json"), map[string]*managedConnector{}, map[string]any{"updates": updates})
		if err != nil || exclusive {
			t.Fatalf("exclusive=%v err=%v", exclusive, err)
		}
	}
	if _, err := os.Stat(filepath.Join(root, "native")); !errors.Is(err, os.ErrNotExist) || len(hooks.verified) != 0 {
		t.Fatalf("a helper was installed without a target: %v %v", err, hooks.verified)
	}
}

func TestComputerUseHelperFailedSwapKeepsBothAppsAndTheNextRunRecovers(t *testing.T) {
	stubComputerUseHelperHooks(t, nil)
	root := t.TempDir()
	app := filepath.Join(root, "native", "macos", computerUseHelperAppName)
	writeExecutable(t, computerUseHelperExecutablePath(app), "old")
	previousSwap := swapComputerUseHelper
	defer func() { swapComputerUseHelper = previousSwap }()
	swapComputerUseHelper = func(string, string) error { return syscall.EXDEV }

	_, err := installComputerUseHelperArchive(writeComputerUseHelperArchive(t, root, "new.tar.gz", "new"), app)
	if code := provisionerFailureCode(err, ""); code != "computer_use_helper.install_failed" {
		t.Fatalf("failure code = %q (%v)", code, err)
	}
	if got := installedComputerUseHelper(t, app); got != "old" {
		t.Fatalf("installed helper = %q after a failed swap, want old", got)
	}
	leftovers := computerUseHelperLeftovers(t, app)
	if len(leftovers) != 1 || installedComputerUseHelper(t, filepath.Join(leftovers[0], "native", "macos", computerUseHelperAppName)) != "new" {
		t.Fatalf("the extracted app was not kept: %v", leftovers)
	}

	swapComputerUseHelper = previousSwap
	if _, err := installComputerUseHelperArchive(writeComputerUseHelperArchive(t, root, "newer.tar.gz", "newer"), app); err != nil {
		t.Fatal(err)
	}
	if got := installedComputerUseHelper(t, app); got != "newer" {
		t.Fatalf("installed helper = %q, want newer", got)
	}
	if leftovers := computerUseHelperLeftovers(t, app); len(leftovers) != 0 {
		t.Fatalf("the next run left %v", leftovers)
	}
}

func TestComputerUseHelperRunAfterAnInterruptedRunInstallsAndCleansUp(t *testing.T) {
	stubComputerUseHelperHooks(t, nil)
	root := t.TempDir()
	app := filepath.Join(root, "native", "macos", computerUseHelperAppName)
	writeExecutable(t, computerUseHelperExecutablePath(app), "old")
	// A run killed after its swap leaves the replaced app in its work directory.
	interrupted := filepath.Join(filepath.Dir(app), computerUseHelperWorkPrefix+"123", "native", "macos", computerUseHelperAppName)
	writeExecutable(t, computerUseHelperExecutablePath(interrupted), "older")

	if _, err := installComputerUseHelperArchive(writeComputerUseHelperArchive(t, root, "new.tar.gz", "new"), app); err != nil {
		t.Fatal(err)
	}
	if got := installedComputerUseHelper(t, app); got != "new" {
		t.Fatalf("installed helper = %q, want new", got)
	}
	if leftovers := computerUseHelperLeftovers(t, app); len(leftovers) != 0 {
		t.Fatalf("leftovers = %v", leftovers)
	}
}

func TestComputerUseHelperInstallHoldsTheLockWhileReplacing(t *testing.T) {
	stubComputerUseHelperHooks(t, nil)
	entered, release := make(chan struct{}), make(chan struct{})
	var once sync.Once
	verifyCodeSignature = func(string) error {
		// The first check happens inside the critical section; hold it there.
		once.Do(func() {
			close(entered)
			<-release
		})
		return nil
	}
	root := t.TempDir()
	app := filepath.Join(root, "native", "macos", computerUseHelperAppName)
	writeExecutable(t, computerUseHelperExecutablePath(app), "old")
	done := make(chan error, 1)
	go func() {
		_, err := installComputerUseHelperArchive(writeComputerUseHelperArchive(t, root, "a.tar.gz", "a"), app)
		done <- err
	}()
	<-entered
	// Another installer (the runner or install.sh) cannot take the lock now.
	lock, err := os.OpenFile(filepath.Join(filepath.Dir(app), "."+filepath.Base(app)+".lock"), os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); !errors.Is(err, syscall.EWOULDBLOCK) {
		t.Fatalf("lock taken during an install: %v", err)
	}
	close(release)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	// Released afterwards: the next install runs.
	if _, err := installComputerUseHelperArchive(writeComputerUseHelperArchive(t, root, "b.tar.gz", "b"), app); err != nil {
		t.Fatal(err)
	}
	if got := installedComputerUseHelper(t, app); got != "b" {
		t.Fatalf("installed helper = %q, want b", got)
	}
	if leftovers := computerUseHelperLeftovers(t, app); len(leftovers) != 0 {
		t.Fatalf("leftovers = %v", leftovers)
	}
}

func TestComputerUseHelperLeftoverIsKeptWhileTheInstalledAppIsDamaged(t *testing.T) {
	stubComputerUseHelperHooks(t, nil)
	root := t.TempDir()
	app := filepath.Join(root, "native", "macos", computerUseHelperAppName)
	// The installed app lost its executable; a leftover holds a good app.
	if err := os.MkdirAll(filepath.Join(app, "Contents", "MacOS"), 0o755); err != nil {
		t.Fatal(err)
	}
	leftover := filepath.Join(filepath.Dir(app), computerUseHelperWorkPrefix+"123")
	writeExecutable(t, computerUseHelperExecutablePath(filepath.Join(leftover, "native", "macos", computerUseHelperAppName)), "good")

	if _, err := installComputerUseHelperArchive(writeComputerUseHelperArchive(t, root, "new.tar.gz", "new"), app); err != nil {
		t.Fatal(err)
	}
	if got := installedComputerUseHelper(t, app); got != "new" {
		t.Fatalf("installed helper = %q, want new", got)
	}
	if !directoryExists(leftover) {
		t.Fatal("the leftover was deleted while the installed app was damaged")
	}
	// The next run finds a healthy app and removes the leftover.
	if _, err := installComputerUseHelperArchive(writeComputerUseHelperArchive(t, root, "newer.tar.gz", "newer"), app); err != nil {
		t.Fatal(err)
	}
	if leftovers := computerUseHelperLeftovers(t, app); len(leftovers) != 0 {
		t.Fatalf("leftovers = %v", leftovers)
	}
}

func TestComputerUseHelperThatDoesNotExitLeavesARestartPending(t *testing.T) {
	realStop := stopComputerUseHelper
	stubComputerUseHelperHooks(t, nil)
	previousStop, previousSignal, previousRunning, previousWait := stopComputerUseHelper, signalComputerUseHelper, computerUseHelperRunning, computerUseHelperStopWait
	defer func() {
		stopComputerUseHelper, signalComputerUseHelper, computerUseHelperRunning, computerUseHelperStopWait = previousStop, previousSignal, previousRunning, previousWait
	}()
	// The old daemon ignores SIGTERM.
	stopComputerUseHelper = realStop
	var signalled atomic.Int32
	signalComputerUseHelper = func(pattern string) (bool, error) {
		if !strings.Contains(pattern, computerUseHelperExecutable) {
			t.Errorf("signal pattern = %q", pattern)
		}
		signalled.Add(1)
		return true, nil
	}
	computerUseHelperRunning = func(string) bool { return true }
	computerUseHelperStopWait = 200 * time.Millisecond

	root := t.TempDir()
	app := filepath.Join(root, "bin", "native", "macos", computerUseHelperAppName)
	writeExecutable(t, computerUseHelperExecutablePath(app), "old")
	restartPending, err := installComputerUseHelperArchive(writeComputerUseHelperArchive(t, root, "new.tar.gz", "new"), app)
	if err != nil || !restartPending || signalled.Load() != 1 {
		t.Fatalf("restartPending=%v err=%v signals=%d", restartPending, err, signalled.Load())
	}
	if got := installedComputerUseHelper(t, app); got != "new" {
		t.Fatalf("installed helper = %q, want new", got)
	}

	// The worker reports it, and a digest it cannot persist is a warning.
	archive := computerUseHelperTestArchive(t, "newer")
	digest := sha256.Sum256(archive)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write(archive) }))
	defer server.Close()
	previousTransport := http.DefaultTransport
	http.DefaultTransport = server.Client().Transport
	defer func() { http.DefaultTransport = previousTransport }()
	blocker := filepath.Join(root, "not-a-directory")
	if err := os.WriteFile(blocker, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	config := map[string]any{"paths": map[string]any{"salix_connect": filepath.Join(root, "bin", "salix-connect")}}
	opts := runOptions{start: true, timeout: 5 * time.Second, configPath: filepath.Join(blocker, "runner.json")}
	statusPath := filepath.Join(root, "status.json")
	applyComputerUseHelperUpdate(opts, config, filepath.Join(root, "state"), statusPath, map[string]any{
		"component": computerUseHelperComponent, "artifact_url": server.URL + "/" + computerUseHelperArchive,
		"sha256": hex.EncodeToString(digest[:]), "size": len(archive),
	})
	status, err := loadJSON(statusPath)
	result := mapValue(status, "computer_use_helper_update")
	if err != nil || result["status"] != "applied_restart_pending" || result["warning"] != "computer_use_helper.digest_state_persist_failed" {
		t.Fatalf("helper update status = %v %v", result, err)
	}

	// The runner iteration rewrites the status after updating; the helper result stays.
	if err := writeWorkerStatus(statusPath, map[string]any{"status": "idle"}); err != nil {
		t.Fatal(err)
	}
	if err := retainUpdateAdvisories(statusPath, nil); err != nil {
		t.Fatal(err)
	}
	status, err = loadJSON(statusPath)
	if result := mapValue(status, "computer_use_helper_update"); err != nil || status["status"] != "idle" || result["status"] != "applied_restart_pending" {
		t.Fatalf("status after iteration = %v %v", status, err)
	}
}
