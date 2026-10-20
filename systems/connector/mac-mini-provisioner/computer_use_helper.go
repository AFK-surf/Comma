package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"
)

// salix-connect runs Computer Use through the helper app beside its binary:
// <salix-connect dir>/native/macos/Comma Computer Use.app.
const (
	computerUseHelperComponent  = "computer-use-helper"
	computerUseHelperAppName    = "Comma Computer Use.app"
	computerUseHelperExecutable = "CommaComputerUseDaemon"
	computerUseHelperArchive    = "comma-computer-use.tar.gz"
	computerUseHelperRetryAfter = 10 * time.Minute
	computerUseHelperWorkPrefix = ".comma-computer-use-"
)

var computerUseHelperStopWait = 5 * time.Second

// A failed helper update does not stop runner work. The same target is
// retried only after computerUseHelperRetryAfter.
var computerUseHelperFailedTarget struct {
	digest string
	at     time.Time
}

var verifyCodeSignature = func(path string) error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	output, err := exec.CommandContext(ctx, "codesign", "--verify", "--deep", "--strict", path).CombinedOutput()
	if err != nil {
		return fmt.Errorf("%w: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

// signalComputerUseHelper sends SIGTERM to the helper processes matching the
// pattern; matched reports whether any process matched.
var signalComputerUseHelper = func(pattern string) (matched bool, err error) {
	err = exec.Command("pkill", "-TERM", "-f", pattern).Run()
	var exit *exec.ExitError
	if errors.As(err, &exit) && exit.ExitCode() == 1 {
		return false, nil
	}
	return err == nil, err
}

// pgrep exits 1 when nothing matches; any other failure leaves the helper possibly running.
var computerUseHelperRunning = func(pattern string) bool {
	err := exec.Command("pgrep", "-f", pattern).Run()
	var exit *exec.ExitError
	return !(errors.As(err, &exit) && exit.ExitCode() == 1)
}

// A running helper keeps executing the replaced code. stopComputerUseHelper
// stops it and waits a bounded time for it to exit; salix-connect opens the
// installed app again on its next Computer Use action. It returns false when
// the old helper may still be running.
var stopComputerUseHelper = func(app string) bool {
	pattern := "^" + regexp.QuoteMeta(computerUseHelperExecutablePath(app)) + "( |$)"
	matched, err := signalComputerUseHelper(pattern)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: the replaced helper could not be stopped: %v\n", computerUseHelperComponent, err)
		return false
	}
	if !matched {
		return true
	}
	for deadline := time.Now().Add(computerUseHelperStopWait); time.Now().Before(deadline); time.Sleep(100 * time.Millisecond) {
		if !computerUseHelperRunning(pattern) {
			return true
		}
	}
	fmt.Fprintf(os.Stderr, "%s: the replaced helper did not exit within %s\n", computerUseHelperComponent, computerUseHelperStopWait)
	return false
}

func computerUseHelperAppPath(config map[string]any) (string, error) {
	salixConnect, err := requirePath(config, "salix_connect")
	if err != nil {
		return "", err
	}
	return filepath.Join(filepath.Dir(salixConnect), "native", "macos", computerUseHelperAppName), nil
}

// applyComputerUseHelperUpdate installs the Server-bound helper when its digest
// differs from the installed one. A Server without the helper sends no target.
// Failures are reported in the worker status and never stop runner work.
func applyComputerUseHelperUpdate(opts runOptions, config map[string]any, stateDir, workerStatusPath string, update map[string]any) {
	const component = computerUseHelperComponent
	targetURL := stringValue(update["artifact_url"])
	if targetURL == "" {
		return
	}
	targetDigest := normalizedDigest(update["sha256"])
	targetSize := positiveRevision(update["size"])
	if computerUseHelperFailedTarget.digest == targetDigest &&
		time.Since(computerUseHelperFailedTarget.at) < computerUseHelperRetryAfter {
		return
	}
	restartPending := false
	app, err := computerUseHelperAppPath(config)
	if err == nil {
		err = verifyComponentTarget(config, component, update, targetURL)
	}
	if err == nil {
		digests := mapValue(mapValue(config, "capabilities"), "component_digests")
		if normalizedDigest(digests[component]) == targetDigest && computerUseHelperHealthy(app) {
			return
		}
		restartPending, err = installComputerUseHelper(opts, stateDir, app, targetURL, targetDigest, targetSize)
	}
	if err != nil {
		computerUseHelperFailedTarget.digest = targetDigest
		computerUseHelperFailedTarget.at = time.Now()
		recordComputerUseHelperFailure(workerStatusPath, targetDigest, err)
		return
	}
	computerUseHelperFailedTarget.digest = ""

	capabilities := copyStringAnyMap(mapValue(config, "capabilities"))
	updatedDigests := copyStringAnyMap(mapValue(capabilities, "component_digests"))
	updatedDigests[component] = targetDigest
	capabilities["component_digests"] = updatedDigests
	config["capabilities"] = capabilities
	result := map[string]any{
		"status":        "applied",
		"target_digest": targetDigest,
		"path":          app,
	}
	if restartPending {
		// The new app is installed, but the old daemon may still serve requests.
		result["status"] = "applied_restart_pending"
	}
	// Without the recorded digest the next cycle checks the installed app and
	// installs it again; that is no reason to stop this cycle.
	if err := writeJSON(expandUser(opts.configPath), config, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "%s installed digest could not be persisted: %v\n", component, err)
		result["warning"] = "computer_use_helper.digest_state_persist_failed"
	}
	fmt.Printf("%s updated to digest %s\n", component, targetDigest)
	recordComputerUseHelperStatus(workerStatusPath, result)
}

func recordComputerUseHelperFailure(workerStatusPath, targetDigest string, err error) {
	fmt.Fprintf(os.Stderr, "%s update failed: %v\n", computerUseHelperComponent, err)
	recordComputerUseHelperStatus(workerStatusPath, map[string]any{
		"status":          "failed",
		"target_digest":   targetDigest,
		"failure_code":    provisionerFailureCode(err, "computer_use_helper.update_failed"),
		"failure_message": err.Error(),
	})
}

// The last helper update result; each runner iteration keeps it in the worker status.
var lastComputerUseHelperUpdate map[string]any

// The worker status is diagnostics only; failing to write it does not fail the update.
func recordComputerUseHelperStatus(workerStatusPath string, result map[string]any) {
	// It is the last attempt's result, not a live state: a pending restart is not re-checked.
	result["recorded_at"] = time.Now().UTC().Format(time.RFC3339)
	lastComputerUseHelperUpdate = result
	status, err := loadJSON(workerStatusPath)
	if err != nil {
		status = map[string]any{}
	}
	status["computer_use_helper_update"] = result
	if err := writeWorkerStatus(workerStatusPath, status); err != nil {
		fmt.Fprintf(os.Stderr, "%s status could not be written: %v\n", computerUseHelperComponent, err)
	}
}

func installComputerUseHelper(opts runOptions, stateDir, app, artifactURL, expectedSHA string, expectedSize uint64) (bool, error) {
	stagingDir := filepath.Join(stateDir, "updates", computerUseHelperComponent)
	if err := resetUpdateStagingDir(stagingDir); err != nil {
		return false, err
	}
	defer func() { _ = os.RemoveAll(stagingDir) }()
	archive := filepath.Join(stagingDir, computerUseHelperArchive)
	if _, err := downloadArtifact(artifactURL, opts.timeout, expectedSize, expectedSHA, archive, 0o600); err != nil {
		if errors.Is(err, errArtifactSizeMismatch) {
			return false, provisionerError{code: "computer_use_helper.size_mismatch", message: err.Error()}
		}
		if errors.Is(err, errArtifactDigestMismatch) {
			return false, provisionerError{code: "computer_use_helper.sha_mismatch", message: "Computer Use helper artifact sha256 mismatch"}
		}
		return false, provisionerError{code: "computer_use_helper.download_failed", message: err.Error()}
	}
	return installComputerUseHelperArchive(archive, app)
}

// installComputerUseHelperArchive is the only code that changes the installed
// helper; the installer script runs it through `bft-runner computer-use-helper
// install`. Under a lock beside the target it extracts the archive there,
// verifies the extracted app, and exchanges it with the installed app in one
// atomic swap (a first install is one rename). salix-connect never sees a
// missing or partial app. The swapped-out app is deleted only after the swap;
// after a failed swap both apps are kept and a later run removes the leftover.
func installComputerUseHelperArchive(archive, app string) (restartPending bool, err error) {
	parent := filepath.Dir(app)
	if err := os.MkdirAll(parent, 0o755); err != nil {
		return false, err
	}
	unlock, err := lockComputerUseHelper(app)
	if err != nil {
		return false, err
	}
	defer unlock()
	removeComputerUseHelperLeftovers(app)

	work, err := os.MkdirTemp(parent, computerUseHelperWorkPrefix)
	if err != nil {
		return false, err
	}
	keepWork := false
	defer func() {
		if !keepWork {
			_ = os.RemoveAll(work)
		}
	}()
	if output, err := exec.Command("tar", "-xzf", archive, "-C", work).CombinedOutput(); err != nil {
		return false, provisionerError{code: "computer_use_helper.extract_failed", message: fmt.Sprintf("Computer Use helper archive could not be extracted: %v: %s", err, strings.TrimSpace(string(output)))}
	}
	staged := filepath.Join(work, "native", "macos", computerUseHelperAppName)
	if !executable(computerUseHelperExecutablePath(staged)) {
		return false, provisionerError{code: "computer_use_helper.bundle_invalid", message: "Computer Use helper executable is missing from the archive"}
	}
	if err := verifyCodeSignature(staged); err != nil {
		return false, provisionerError{code: "computer_use_helper.signature_invalid", message: "Computer Use helper signature verification failed: " + err.Error()}
	}

	if _, err := os.Lstat(app); errors.Is(err, os.ErrNotExist) {
		if err := os.Rename(staged, app); err != nil {
			keepWork = true
			return false, provisionerError{code: "computer_use_helper.install_failed", message: fmt.Sprintf("Computer Use helper could not be installed; the extracted app is kept at %s: %v", staged, err)}
		}
		return false, nil
	} else if err != nil {
		return false, err
	}
	if err := swapComputerUseHelper(staged, app); err != nil {
		keepWork = true
		return false, provisionerError{code: "computer_use_helper.install_failed", message: fmt.Sprintf("Computer Use helper could not be replaced; the installed app is unchanged and the extracted app is kept at %s: %v", staged, err)}
	}
	// staged now holds the replaced app; the deferred cleanup deletes it.
	return !stopComputerUseHelper(app), nil
}

func computerUseHelperExecutablePath(app string) string {
	return filepath.Join(app, "Contents", "MacOS", computerUseHelperExecutable)
}

// computerUseHelperHealthy reports whether the installed app can be used as is.
func computerUseHelperHealthy(app string) bool {
	return executable(computerUseHelperExecutablePath(app)) && verifyCodeSignature(app) == nil
}

// The lock serializes the runner's updates and the installer's runs.
func lockComputerUseHelper(app string) (func(), error) {
	path := filepath.Join(filepath.Dir(app), "."+filepath.Base(app)+".lock")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX); err != nil {
		_ = file.Close()
		return nil, err
	}
	return func() {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN)
		_ = file.Close()
	}, nil
}

// A run that stopped before its cleanup leaves a work directory beside the
// target. Called under the lock, so no other run owns one. While the installed
// app is missing or damaged, a leftover may hold the only good copy, so all
// leftovers are kept until a run finds a healthy installed app.
func removeComputerUseHelperLeftovers(app string) {
	if !computerUseHelperHealthy(app) {
		return
	}
	leftovers, _ := filepath.Glob(filepath.Join(filepath.Dir(app), computerUseHelperWorkPrefix+"*"))
	for _, leftover := range leftovers {
		if err := os.RemoveAll(leftover); err != nil {
			fmt.Fprintf(os.Stderr, "%s: leftover %s could not be removed: %v\n", computerUseHelperComponent, leftover, err)
		}
	}
}

func directoryExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

// runComputerUseHelperCommand serves `bft-runner computer-use-helper check|install`.
func runComputerUseHelperCommand(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: bft-runner computer-use-helper check --app PATH | install --app PATH --archive PATH")
	}
	action := args[0]
	flags := flag.NewFlagSet("computer-use-helper "+action, flag.ContinueOnError)
	app := flags.String("app", "", "Comma Computer Use.app path")
	archive := flags.String("archive", "", "verified comma-computer-use.tar.gz")
	if err := flags.Parse(args[1:]); err != nil {
		return err
	}
	if *app == "" || filepath.Base(*app) != computerUseHelperAppName {
		return provisionerError{code: "computer_use_helper.path_invalid", message: "--app must name " + computerUseHelperAppName}
	}
	switch action {
	case "check":
		if !computerUseHelperHealthy(*app) {
			return provisionerError{code: "computer_use_helper.unhealthy", message: "the installed Computer Use helper is missing or its signature does not verify"}
		}
		return nil
	case "install":
		if *archive == "" {
			return errors.New("computer-use-helper install requires --archive")
		}
		restartPending, err := installComputerUseHelperArchive(*archive, *app)
		if err == nil && restartPending {
			fmt.Fprintln(os.Stderr, "Computer Use helper installed; the previous helper is still running until it exits or the Mac restarts")
		}
		return err
	default:
		return fmt.Errorf("unknown computer-use-helper action: %s", action)
	}
}
