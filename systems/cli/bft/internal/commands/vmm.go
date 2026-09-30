package commands

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/AFK-surf/comma/systems/cli/bft/internal/output"
)

const (
	vmmLifecycleEnv           = "BFT_VMM_LIFECYCLE"
	vmmCLIEnv                 = "BFT_VMM_CLI"
	vmmHomeEnv                = "HOME"
	sharedVMMLifecyclePath    = "Library/Application Support/Agent VMM Host/current/Agent VMM Host.app/Contents/Helpers/agent-vmm-lifecycle"
	sharedVMMCLIPath          = "Library/Application Support/Agent VMM Host/current/Agent VMM Host.app/Contents/Helpers/agent-vmm"
	vmmStatusTimeout          = 6 * time.Second
	vmmRepairTimeout          = 3 * time.Minute
	vmmStopTimeout            = 2 * time.Minute
	vmmInstallTimeout         = 15 * time.Minute
	vmmRemoveTimeout          = 2 * time.Minute
	vmmRunnerOnlineNextAction = "Run bft runners list --org <org> to verify a recent runner heartbeat; local VMM readiness does not prove runner online."
)

func vmmOperationTimeout(operation string) time.Duration {
	switch operation {
	case "status":
		return vmmStatusTimeout
	case "repair":
		return vmmRepairTimeout
	case "stop":
		return vmmStopTimeout
	case "install":
		return vmmInstallTimeout
	case "remove":
		return vmmRemoveTimeout
	default:
		return vmmStatusTimeout
	}
}

// VMMStatus keeps the helper's facts separate from the transport/readability
// of the status observation. A failed later observation may still return the
// last facts known by the same runner instance.
type VMMStatus struct {
	Facts       map[string]any
	State       string
	Freshness   string
	Partial     bool
	Readability string
	LastKnown   bool
}

// VMMRunner is the local lifecycle boundary used by the compute-node CLI.
// Keeping this interface separate from command parsing makes lifecycle
// mapping and last-known behavior testable without a real Agent VMM Host bundle.
type VMMRunner interface {
	Install(context.Context, string) error
	Status(context.Context) (VMMStatus, error)
	Repair(context.Context, string) error
	Stop(context.Context, string) error
	Remove(context.Context, bool, string) error
}

type lifecycleCommand func(context.Context, string, []string) ([]byte, []byte, error)

type localVMMRunner struct {
	path        string
	inspectPath string
	command     lifecycleCommand

	lastKnown *VMMStatus
}

func newLocalVMMRunner(path, inspectPath string) *localVMMRunner {
	return &localVMMRunner{path: path, inspectPath: inspectPath, command: runLifecycleCommand}
}

func (runner *localVMMRunner) Install(ctx context.Context, requestID string) error {
	// The helper owns the durable install operation and delegates the complete
	// local coordinator contract (host, VM, appliance, registration, and
	// readiness observation). BFT only invokes that shared boundary.
	return runner.invoke(ctx, "install", []string{"install", "--request-id", requestID})
}

func (runner *localVMMRunner) Status(ctx context.Context) (VMMStatus, error) {
	stdout, stderr, err := runner.command(ctx, runner.inspectPath, []string{"inspect", "--json", "--lifecycle-helper", runner.path})
	if err != nil {
		return runner.unreadableStatus(newLifecycleCommandError("inspect", runner.inspectPath, stderr, err))
	}
	if len(stdout) > 2<<20 {
		return runner.unreadableStatus(&vmmStatusDecodeError{path: runner.inspectPath, err: errors.New("inspect output exceeded 2 MiB")})
	}

	contract := struct {
		Version   int            `json:"version"`
		State     string         `json:"state"`
		Freshness string         `json:"freshness"`
		Partial   bool           `json:"partial"`
		Facts     map[string]any `json:"facts"`
	}{}
	if err := json.Unmarshal(stdout, &contract); err != nil || contract.Version != 1 || contract.State == "" || contract.Freshness == "" || contract.Facts == nil {
		if err == nil {
			err = errors.New("unsupported Agent VMM inspect contract")
		}
		return runner.unreadableStatus(&vmmStatusDecodeError{path: runner.inspectPath, err: err})
	}
	status := VMMStatus{Facts: contract.Facts, State: contract.State, Freshness: contract.Freshness, Partial: contract.Partial, Readability: "readable"}
	retained := status
	retained.Facts = cloneVMMFacts(status.Facts)
	runner.lastKnown = &retained
	return status, nil
}

func (runner *localVMMRunner) Repair(ctx context.Context, requestID string) error {
	return runner.invoke(ctx, "repair", []string{"repair", "--request-id", requestID})
}

func (runner *localVMMRunner) Stop(ctx context.Context, requestID string) error {
	return runner.invoke(ctx, "stop", []string{"drain", "--request-id", requestID})
}

func (runner *localVMMRunner) Remove(ctx context.Context, purge bool, requestID string) error {
	args := []string{"uninstall"}
	if purge {
		args = append(args, "--purge")
	}
	args = append(args, "--request-id", requestID)
	return runner.invoke(ctx, "remove", args)
}

func (runner *localVMMRunner) invoke(ctx context.Context, operation string, args []string) error {
	_, stderr, err := runner.command(ctx, runner.path, args)
	if err != nil {
		return newLifecycleCommandError(operation, runner.path, stderr, err)
	}
	return nil
}

func (runner *localVMMRunner) unreadableStatus(err error) (VMMStatus, error) {
	if runner.lastKnown == nil {
		return VMMStatus{Readability: "unreadable"}, err
	}
	status := *runner.lastKnown
	status.Facts = cloneVMMFacts(status.Facts)
	status.Readability = "unreadable"
	status.LastKnown = true
	return status, err
}

type vmmCommandError struct {
	Operation string
	Path      string
	Stderr    string
	Err       error
}

func newLifecycleCommandError(operation, path string, stderr []byte, err error) error {
	return &vmmCommandError{
		Operation: operation,
		Path:      path,
		Stderr:    boundedVMMOutput(stderr),
		Err:       err,
	}
}

func (err *vmmCommandError) Error() string {
	if err.Stderr != "" {
		return fmt.Sprintf("%s failed: %s (%s)", err.Operation, err.Stderr, err.Err)
	}
	return fmt.Sprintf("%s failed: %s", err.Operation, err.Err)
}

func (err *vmmCommandError) Unwrap() error { return err.Err }

type vmmStatusDecodeError struct {
	path string
	err  error
}

func (err *vmmStatusDecodeError) Error() string {
	return fmt.Sprintf("status from %s was not valid JSON: %v", err.path, err.err)
}

func (err *vmmStatusDecodeError) Unwrap() error { return err.err }

func runLifecycleCommand(ctx context.Context, path string, args []string) ([]byte, []byte, error) {
	command := exec.CommandContext(ctx, path, args...)
	var stdout, stderr bytes.Buffer
	command.Stdout = &stdout
	command.Stderr = &stderr
	err := command.Run()
	return stdout.Bytes(), stderr.Bytes(), err
}

func resolveVMMLifecyclePath(env envFunc) string {
	if env == nil {
		env = os.Getenv
	}
	path := strings.TrimSpace(env(vmmLifecycleEnv))
	if path == "" {
		home := strings.TrimSpace(env(vmmHomeEnv))
		if home == "" {
			home, _ = os.UserHomeDir()
		}
		if home != "" {
			return filepath.Join(home, filepath.FromSlash(sharedVMMLifecyclePath))
		}
		return filepath.FromSlash(sharedVMMLifecyclePath)
	}
	if strings.HasPrefix(path, "~/") {
		home := strings.TrimSpace(env(vmmHomeEnv))
		if home == "" {
			home, _ = os.UserHomeDir()
		}
		if home != "" {
			return filepath.Join(home, path[2:])
		}
	}
	return path
}

func resolveVMMCLIPath(env envFunc, lifecyclePath string) string {
	if env == nil {
		env = os.Getenv
	}
	if path := strings.TrimSpace(env(vmmCLIEnv)); path != "" {
		if strings.HasPrefix(path, "~/") {
			home := strings.TrimSpace(env(vmmHomeEnv))
			if home != "" {
				return filepath.Join(home, path[2:])
			}
		}
		return path
	}
	if filepath.Base(lifecyclePath) == "agent-vmm-lifecycle" {
		return filepath.Join(filepath.Dir(lifecyclePath), "agent-vmm")
	}
	home := strings.TrimSpace(env(vmmHomeEnv))
	if home != "" {
		return filepath.Join(home, filepath.FromSlash(sharedVMMCLIPath))
	}
	return filepath.FromSlash(sharedVMMCLIPath)
}

func validateVMMLifecycleHelper(path string) output.Error {
	info, err := os.Stat(path)
	if err != nil {
		return missingVMMHelperError(path, err.Error())
	}
	if info.IsDir() || info.Mode()&0o111 == 0 {
		return missingVMMHelperError(path, "path is not an executable file")
	}
	return output.Error{}
}

func validateVMMCLI(path string) output.Error {
	info, err := os.Stat(path)
	if err == nil && !info.IsDir() && info.Mode()&0o111 != 0 {
		return output.Error{}
	}
	reason := "path is not an executable file"
	if err != nil {
		reason = err.Error()
	}
	return output.Error{ExitCode: output.ExitNotFound, Code: "vmm_cli_not_found", Message: "The managed Agent VMM CLI is not available.", Details: map[string]any{"cli_path": path, "cli_env": vmmCLIEnv, "reason": reason}, NextAction: fmt.Sprintf("Install the managed Agent VMM Host runtime or set %s to its agent-vmm executable, then retry.", vmmCLIEnv)}
}

func missingVMMHelperError(path, reason string) output.Error {
	return output.Error{
		ExitCode: output.ExitNotFound,
		Code:     "vmm_lifecycle_helper_not_found",
		Message:  "The local Agent VMM Host lifecycle helper is not available.",
		Details: map[string]any{
			"helper_path": path,
			"helper_env":  vmmLifecycleEnv,
			"reason":      reason,
		},
		NextAction: fmt.Sprintf("Install the Agent VMM Host runtime or set %s to an executable lifecycle helper for an explicit test/dev environment, then retry.", vmmLifecycleEnv),
	}
}

func vmmLifecycleOperationError(operation, path string, err error) output.Error {
	details := map[string]any{
		"operation":   operation,
		"helper_path": path,
		"reason":      err.Error(),
	}
	var commandErr *vmmCommandError
	if errors.As(err, &commandErr) {
		details["helper_action"] = commandErr.Operation
		if commandErr.Stderr != "" {
			details["helper_stderr"] = commandErr.Stderr
		}
	}
	return output.Error{
		ExitCode:   output.ExitUnavailable,
		Code:       "vmm_lifecycle_failed",
		Message:    fmt.Sprintf("Local Agent VMM Host runtime %s failed.", operation),
		Details:    details,
		NextAction: fmt.Sprintf("Check the Agent VMM Host bundle and rerun bft compute-node %s --confirm-mutating.", operation),
	}
}

func vmmStatusError(path string, err error) output.Error {
	return output.Error{
		ExitCode:   output.ExitUnavailable,
		Code:       "vmm_status_unreadable",
		Message:    "The local Agent VMM Host status could not be read.",
		Details:    map[string]any{"helper_path": path, "reason": err.Error()},
		NextAction: fmt.Sprintf("Check that %s is executable and rerun bft compute-node status.", path),
	}
}

func vmmNotReadyError(path string, status VMMStatus) output.Error {
	return output.Error{
		ExitCode: output.ExitUnavailable,
		Code:     "vmm_not_ready",
		Message:  "The Agent VMM Host runtime was installed, but readiness was not observed.",
		Details: map[string]any{
			"helper_path": path,
			"readiness":   vmmReadiness(status),
			"status":      status.Facts,
		},
		NextAction: fmt.Sprintf("Run bft compute-node status and check Host health before retrying the install at %s.", path),
	}
}

func computeNodeStatusData(path string, status VMMStatus, statusErr error) map[string]any {
	readiness := vmmReadiness(status)
	data := map[string]any{
		"mode":                      "compute_node_status",
		"operation":                 "status",
		"helper_path":               path,
		"readability":               fallback(status.Readability, "unknown"),
		"last_known":                status.LastKnown,
		"helper_status":             status.Facts,
		"vmm_state":                 fallback(status.State, "unknown"),
		"vmm_freshness":             fallback(status.Freshness, "unknown"),
		"vmm_partial":               status.Partial,
		"runner_online":             "unknown",
		"runner_online_source":      "not_observed_by_local_vmm_helper",
		"node_admission":            "unknown",
		"node_admission_source":     "server_only",
		"readiness_statement":       "VMM readiness is local Host runtime evidence; it proves neither BFT runner connectivity nor server Node admission.",
		"runner_online_next_action": vmmRunnerOnlineNextAction,
	}
	if status.LastKnown {
		data["vmm_readiness"] = "unknown"
		data["last_known_vmm_readiness"] = readiness
	} else {
		data["vmm_readiness"] = readiness
		if readiness == "ready" {
			data["vmm_ready"] = true
		} else if readiness == "not_ready" {
			data["vmm_ready"] = false
		}
	}
	if statusErr != nil {
		data["status_error"] = statusErr.Error()
	}
	if status.LastKnown {
		data["next_action"] = "The helper became unreadable; the VMM fields above are last-known only. Check the helper and rerun status. " + vmmRunnerOnlineNextAction
	} else {
		data["next_action"] = vmmRunnerOnlineNextAction
	}
	return data
}

func vmmReadiness(status VMMStatus) string {
	if status.State == "" {
		return "unknown"
	}
	if status.State == "healthy" && status.Freshness == "current" && !status.Partial && !status.LastKnown {
		return "ready"
	}
	if status.Freshness == "" || status.Freshness == "unknown" || status.LastKnown {
		return "unknown"
	}
	return "not_ready"
}

func cloneVMMFacts(facts map[string]any) map[string]any {
	if facts == nil {
		return nil
	}
	copy := make(map[string]any, len(facts))
	for key, value := range facts {
		copy[key] = value
	}
	return copy
}

func computeNodeOperations() map[string]bool {
	return map[string]bool{
		"install": true,
		"status":  true,
		"repair":  true,
		"stop":    true,
		"remove":  true,
	}
}

func computeNodeOperationNames() []string {
	return []string{"install", "status", "repair", "stop", "remove"}
}

func computeNodeHelperAction(operation string) string {
	switch operation {
	case "install", "repair":
		return operation
	case "status":
		return "status"
	case "stop":
		return "drain"
	case "remove":
		return "uninstall"
	default:
		return ""
	}
}

func boundedVMMOutput(value []byte) string {
	const maxOutput = 500
	trimmed := strings.TrimSpace(string(value))
	if len(trimmed) > maxOutput {
		return trimmed[:maxOutput] + "..."
	}
	return trimmed
}
