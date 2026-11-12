package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const version = "0.1.0"

const agentVMMVersionTimeout = 2 * time.Second
const hostRuntimeOperationTimeout = 3 * time.Minute
const hostRuntimeUpdateTimeout = 21 * time.Minute

type provisionerError struct {
	code    string
	message string
}

type boundedOutputBuffer struct {
	mu       sync.Mutex
	buffer   bytes.Buffer
	limit    int
	overflow bool
}

func (output *boundedOutputBuffer) Write(data []byte) (int, error) {
	output.mu.Lock()
	defer output.mu.Unlock()
	remaining := output.limit - output.buffer.Len()
	if remaining > len(data) {
		remaining = len(data)
	}
	if remaining > 0 {
		_, _ = output.buffer.Write(data[:remaining])
	}
	if remaining < len(data) {
		output.overflow = true
	}
	return len(data), nil
}

func runCommandWithOutputLimit(ctx context.Context, limit int, name string, arguments ...string) ([]byte, bool, error) {
	output := &boundedOutputBuffer{limit: limit}
	command := exec.CommandContext(ctx, name, arguments...)
	command.Stdout = output
	command.Stderr = output
	err := command.Run()
	output.mu.Lock()
	defer output.mu.Unlock()
	return append([]byte(nil), output.buffer.Bytes()...), output.overflow, err
}

func (e provisionerError) Error() string {
	return e.message
}

type controlPlaneError struct {
	method      string
	path        string
	status      int
	contentType string
	body        string
	cause       error
}

func (e controlPlaneError) Error() string {
	parts := []string{e.method + " " + e.path}
	if e.status != 0 {
		parts = append(parts, fmt.Sprintf("HTTP %d", e.status))
	}
	if e.contentType != "" {
		parts = append(parts, e.contentType)
	}
	if e.body != "" {
		parts = append(parts, e.body)
	}
	if e.cause != nil {
		parts = append(parts, e.cause.Error())
	}
	return strings.Join(parts, ": ")
}

type runOptions struct {
	configPath    string
	statusPath    string
	timeout       time.Duration
	start         bool
	once          bool
	loop          bool
	interval      time.Duration
	maxIterations int
}

type processExit struct {
	exitCode int
	err      error
}

func main() {
	os.Exit(runMain(os.Args[1:]))
}

func runMain(args []string) int {
	if len(args) == 0 {
		if err := runWorker(parseRunArgs(nil, runDefaults{start: true, loop: true})); err != nil {
			return renderError(err)
		}
		return 0
	}
	if args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		printUsage(os.Stdout)
		return 0
	}
	if strings.HasPrefix(args[0], "-") {
		fmt.Fprintln(os.Stderr, "bft-runner does not accept root flags; use bft-runner run for worker flags")
		printUsage(os.Stderr)
		return 2
	}

	command := args[0]
	args = args[1:]

	var err error
	switch command {
	case "run":
		err = runWorker(parseRunArgs(args, runDefaults{start: true, loop: true}))
	case "dry-run", "once":
		if len(args) != 0 {
			fmt.Fprintf(os.Stderr, "bft-runner %s does not accept extra arguments; use run for worker flags\n", command)
			return 2
		}
		opts := parseRunArgs(nil, runDefaults{start: false, loop: false})
		opts.once = true
		opts.loop = false
		err = runWorker(opts)
	case "doctor":
		err = runDoctor(parseStatusArgs(args))
	case "status":
		err = runStatus(parseStatusArgs(args))
	case "logs":
		err = runLogs(parseStatusArgs(args))
	case "service":
		err = runService(args)
	case "help", "-h", "--help":
		printUsage(os.Stdout)
		return 0
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n", command)
		printUsage(os.Stderr)
		return 2
	}

	return renderError(err)
}

func renderError(err error) int {
	if err == nil {
		return 0
	}
	var pe provisionerError
	if errors.As(err, &pe) {
		fmt.Fprintln(os.Stderr, "BridgeForTeams runner")
		fmt.Fprintln(os.Stderr, "Status: failed")
		fmt.Fprintf(os.Stderr, "Code: %s\n", pe.code)
		fmt.Fprintf(os.Stderr, "Reason: %s\n", pe.message)
		fmt.Fprintln(os.Stderr, "Next: inspect the status file and logs, then rerun the dry run.")
		return 1
	}

	fmt.Fprintf(os.Stderr, "bft-runner: %v\n", err)
	return 1
}

func printUsage(w io.Writer) {
	fmt.Fprintln(w, "BridgeForTeams runner")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Usage:")
	fmt.Fprintln(w, "  bft-runner")
	fmt.Fprintln(w, "  bft-runner dry-run")
	fmt.Fprintln(w, "  bft-runner doctor")
	fmt.Fprintln(w, "  bft-runner status")
	fmt.Fprintln(w, "  bft-runner logs")
	fmt.Fprintln(w, "  bft-runner service start")
	fmt.Fprintln(w, "  bft-runner service stop")
	fmt.Fprintln(w, "  bft-runner service status")
	fmt.Fprintln(w, "  bft-runner service remove")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Low-level worker entrypoints:")
	fmt.Fprintln(w, "  bft-runner run [--config path]")
}

type runDefaults struct {
	start bool
	loop  bool
}

func parseRunArgs(args []string, defaults runDefaults) runOptions {
	fs := flag.NewFlagSet("run", flag.ExitOnError)
	opts := runOptions{start: defaults.start, loop: defaults.loop}
	fs.StringVar(&opts.configPath, "config", defaultConfigPath(), "path to protected runner.json")
	fs.StringVar(&opts.statusPath, "status-path", "", "optional worker status output path")
	timeout := fs.Float64("timeout", 15.0, "HTTP timeout in seconds")
	fs.BoolVar(&opts.start, "start", opts.start, "apply Agent VMM installs, updates and controls")
	fs.BoolVar(&opts.once, "once", false, "run one heartbeat cycle and exit")
	fs.BoolVar(&opts.loop, "loop", opts.loop, "keep heartbeating and applying Agent VMM work")
	interval := fs.Float64("interval", 15.0, "loop sleep interval in seconds")
	fs.IntVar(&opts.maxIterations, "max-iterations", 0, "testing guard for --loop; 0 means unlimited")
	_ = fs.Parse(args)

	visited := map[string]bool{}
	fs.Visit(func(flag *flag.Flag) {
		visited[flag.Name] = true
	})
	if opts.once {
		if !visited["loop"] {
			opts.loop = false
		}
		if !visited["start"] {
			opts.start = false
		}
	}
	if opts.once && opts.loop {
		fmt.Fprintln(os.Stderr, "--once and --loop cannot be used together")
		os.Exit(2)
	}

	opts.timeout = durationFromSeconds(*timeout)
	opts.interval = durationFromSeconds(*interval)
	return opts
}

func parseStatusArgs(args []string) runOptions {
	fs := flag.NewFlagSet("status", flag.ExitOnError)
	opts := runOptions{}
	fs.StringVar(&opts.configPath, "config", defaultConfigPath(), "path to protected runner.json")
	fs.StringVar(&opts.statusPath, "status-path", "", "optional worker status output path")
	_ = fs.Parse(args)
	return opts
}

func durationFromSeconds(value float64) time.Duration {
	if value <= 0 {
		return 0
	}
	return time.Duration(value * float64(time.Second))
}

func defaultConfigPath() string {
	if configured := os.Getenv("BFT_CONFIG_PATH"); configured != "" {
		return configured
	}
	if exe, err := os.Executable(); err == nil && exe != "" {
		installedCandidate := filepath.Clean(filepath.Join(filepath.Dir(exe), "..", "runner.json"))
		if _, statErr := os.Stat(installedCandidate); statErr == nil {
			return installedCandidate
		}
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ".bridge-for-teams/runner.json"
	}
	return filepath.Join(home, ".bridge-for-teams", "runner.json")
}

func loadJSON(path string) (map[string]any, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return nil, err
	}
	return payload, nil
}

func writeJSON(path string, payload map[string]any, mode os.FileMode) error {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0o755); err != nil {
		return err
	}
	if err := syncJSONDirectory(filepath.Dir(directory)); err != nil {
		return err
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	temporary, err := os.CreateTemp(directory, "."+filepath.Base(path)+".tmp-*")
	if err != nil {
		return err
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := preserveAtomicJSONOwnership(path, directory, temporary); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Chmod(mode); err != nil {
		temporary.Close()
		return err
	}
	if _, err := temporary.Write(append(raw, '\n')); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return err
	}
	return syncJSONDirectory(directory)
}

func preserveAtomicJSONOwnership(path, directory string, temporary *os.File) error {
	ownerSource := path
	info, err := os.Stat(ownerSource)
	if errors.Is(err, os.ErrNotExist) && os.Geteuid() == 0 {
		ownerSource = directory
		info, err = os.Stat(ownerSource)
	}
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return nil
	}
	return chownAtomicJSONFile(temporary, int(owner.Uid), int(owner.Gid))
}

var chownAtomicJSONFile = func(file *os.File, uid, gid int) error {
	return file.Chown(uid, gid)
}

func syncJSONDirectory(path string) error {
	directory, err := os.Open(path)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func stringValue(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return ""
}

func mapValue(payload map[string]any, key string) map[string]any {
	return mapFromValue(payload[key])
}

func mapFromValue(value any) map[string]any {
	typed, ok := value.(map[string]any)
	if !ok {
		return map[string]any{}
	}
	return typed
}

func requireConfig(config map[string]any, key string) (string, error) {
	value := stringValue(config[key])
	if value == "" {
		return "", provisionerError{code: "preflight." + key + "_missing", message: key + " is required"}
	}
	if key == "api_base_url" {
		value = strings.TrimRight(value, "/")
	}
	return value, nil
}

func requirePath(config map[string]any, name string) (string, error) {
	paths := mapValue(config, "paths")
	value := stringValue(paths[name])
	if value == "" {
		return "", provisionerError{code: "preflight." + name + "_missing", message: "paths." + name + " is required"}
	}
	return value, nil
}

func executable(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode()&0o111 != 0
}

func postJSON(apiBaseURL, token, path string, payload map[string]any, timeout time.Duration) (int, map[string]any, error) {
	return postJSONContext(context.Background(), apiBaseURL, token, path, payload, timeout)
}

func postJSONContext(ctx context.Context, apiBaseURL, token, path string, payload map[string]any, timeout time.Duration) (int, map[string]any, error) {
	raw, err := json.Marshal(payload)
	if err != nil {
		return 0, nil, err
	}
	return requestJSONContext(ctx, http.MethodPost, apiBaseURL, token, path, raw, timeout)
}

func requestJSONContext(ctx context.Context, method, apiBaseURL, token, path string, body []byte, timeout time.Duration) (int, map[string]any, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, apiBaseURL+path, reader)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("accept", "application/json")
	req.Header.Set("user-agent", "bridge-for-teams-runner/"+version)
	if body != nil {
		req.Header.Set("content-type", "application/json")
	}
	if token != "" {
		req.Header.Set("authorization", "Bearer "+token)
	}

	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, controlPlaneError{method: method, path: path, cause: err}
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if err != nil {
		return resp.StatusCode, nil, controlPlaneError{
			method: method, path: path, status: resp.StatusCode,
			contentType: resp.Header.Get("content-type"), cause: err,
		}
	}
	if len(raw) == 0 {
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return resp.StatusCode, nil, nil
		}
		return resp.StatusCode, nil, controlPlaneError{
			method: method, path: path, status: resp.StatusCode,
			contentType: resp.Header.Get("content-type"),
		}
	}

	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		return resp.StatusCode, nil, controlPlaneError{
			method: method, path: path, status: resp.StatusCode,
			contentType: resp.Header.Get("content-type"), body: strings.TrimSpace(string(raw)), cause: err,
		}
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return resp.StatusCode, payload, controlPlaneError{
			method: method, path: path, status: resp.StatusCode,
			contentType: resp.Header.Get("content-type"), body: strings.TrimSpace(string(raw)),
		}
	}
	return resp.StatusCode, payload, nil
}

func expectSuccess(status int, payload map[string]any, event string, err error) (map[string]any, error) {
	if err != nil {
		return nil, err
	}
	if status >= 200 && status < 300 && payload != nil {
		return payload, nil
	}
	return nil, provisionerError{code: fmt.Sprintf("%s.http_%d", event, status), message: fmt.Sprintf("%s returned HTTP %d", event, status)}
}

func provisionerPayload(config map[string]any, installFailures []any) map[string]any {
	provisioner := mapValue(config, "runner")
	host, _ := os.Hostname()
	if host == "" {
		host = "bft-runner"
	}
	payload := map[string]any{
		"stable_id":     firstNonEmpty(stringValue(provisioner["stable_id"]), host),
		"name":          firstNonEmpty(stringValue(provisioner["name"]), host),
		"status":        "online",
		"host_identity": host,
		"os_summary":    fmt.Sprintf("%s %s %s", runtime.GOOS, runtime.Version(), runtime.GOARCH),
		"version":       version,
		"capabilities":  provisionerCapabilities(config),
	}
	if cursor := stringValue(config["_agent_vmm_control_cursor"]); cursor != "" {
		payload["agent_vmm_control_cursor"] = cursor
	}
	if len(installFailures) != 0 {
		payload["agent_vmm_registration_failures"] = installFailures
	}
	return payload
}

func provisionerCapabilities(config map[string]any) map[string]any {
	capabilities := copyStringAnyMap(mapValue(config, "capabilities"))
	capabilities["platform"] = runtime.GOOS + "-" + runtime.GOARCH
	if build, verified := agentVMMRelease(config); verified {
		capabilityComponent := "agent-vmm-host"
		version := firstNonEmpty(stringValue(build["version"]), stringValue(build["release_id"]))
		if version != "" {
			versions := copyStringAnyMap(mapValue(capabilities, "component_versions"))
			versions[capabilityComponent] = version
			capabilities["component_versions"] = versions
		}
		releases := copyStringAnyMap(mapValue(capabilities, "component_releases"))
		releases[capabilityComponent] = build
		capabilities["component_releases"] = releases
		if digest := normalizedDigest(build["artifact_digest"]); digest != "" {
			digests := copyStringAnyMap(mapValue(capabilities, "component_digests"))
			digests[capabilityComponent] = digest
			capabilities["component_digests"] = digests
		}
	}
	return capabilities
}

func copyStringAnyMap(src map[string]any) map[string]any {
	dst := make(map[string]any, len(src))
	for key, value := range src {
		dst[key] = value
	}
	return dst
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func intValue(value any, fallback int) int {
	switch typed := value.(type) {
	case float64:
		return int(typed)
	case int:
		return typed
	case string:
		parsed, err := strconv.Atoi(typed)
		if err == nil {
			return parsed
		}
	}
	return fallback
}

func writeWorkerStatus(workerStatusPath string, payload map[string]any) error {
	payload["component"] = firstNonEmpty(stringValue(payload["component"]), "bridge-for-teams-runner")
	payload["updated_at"] = int(time.Now().Unix())
	return writeJSON(workerStatusPath, payload, 0o644)
}

func progressPayload(values map[string]any) map[string]any {
	progress := map[string]any{"updated_at": int(time.Now().Unix())}
	for key, value := range values {
		if value != nil {
			progress[key] = value
		}
	}
	return progress
}

func applyProvisionerUpdates(opts runOptions, config map[string]any, heartbeat map[string]any) (bool, map[string]any, error) {
	if !opts.start {
		return false, nil, nil
	}
	updates := mapValue(heartbeat, "updates")
	var advisory map[string]any
	if update := mapValue(updates, "agent-vmm"); len(update) != 0 {
		exclusive, result, err := applyAgentVMMUpdate(opts, config, update)
		if err != nil || exclusive {
			return exclusive, result, err
		}
		advisory = result
	}
	return false, advisory, nil
}

func agentVMMAdministratorUpdateAdvisory(config, update map[string]any) map[string]any {
	if stringValue(mapValue(config, "launchd")["domain"]) != "system" {
		return nil
	}
	targetRelease := strings.TrimSpace(stringValue(update["release_id"]))
	current, _ := agentVMMRelease(config)
	targetDigest := normalizedDigest(update["sha256"])
	configuredDigest := stringValue(mapValue(mapValue(config, "capabilities"), "component_digests")["agent-vmm-host"])
	if targetRelease == "" || stringValue(current["release_id"]) == targetRelease && strings.EqualFold(configuredDigest, targetDigest) {
		return nil
	}
	return map[string]any{
		"status":          "agent_vmm_administrator_update_required",
		"failure_code":    "agent_vmm.administrator_update_required",
		"failure_message": "The selected Agent VMM Host release requires the administrator installer and fixed service executor.",
		"progress": progressPayload(map[string]any{
			"stage": "target_selection", "target_release_id": targetRelease,
		}),
	}
}

func applyAgentVMMUpdate(opts runOptions, config map[string]any, update map[string]any) (bool, map[string]any, error) {
	const component = "agent-vmm"
	targetURL := stringValue(update["artifact_url"])
	if targetURL == "" {
		return false, nil, nil
	}
	if err := verifyComponentTarget(config, component, update, targetURL); err != nil {
		return false, nil, err
	}
	targetRelease := strings.TrimSpace(stringValue(update["release_id"]))
	if !validAgentVMMOperationID(targetRelease) {
		return false, nil, provisionerError{code: "agent-vmm.target_release_invalid", message: "agent-vmm target release ID is required and invalid"}
	}
	targetDigest := normalizedDigest(update["sha256"])
	current, _ := agentVMMRelease(config)
	configuredDigest := stringValue(mapValue(mapValue(config, "capabilities"), "component_digests")["agent-vmm-host"])
	if stringValue(current["release_id"]) == targetRelease && strings.EqualFold(configuredDigest, targetDigest) {
		return false, nil, nil
	}
	serviceArgs, err := hostRuntimeServiceArguments(config)
	if err != nil {
		return false, nil, err
	}
	if stringValue(mapValue(config, "launchd")["domain"]) == "system" {
		return false, agentVMMAdministratorUpdateAdvisory(config, update), nil
	}
	lifecycle, err := requirePath(config, "host_runtime_lifecycle")
	if err != nil || !executable(lifecycle) {
		return false, nil, provisionerError{code: "agent_vmm.lifecycle_unavailable", message: "Agent VMM lifecycle helper is unavailable"}
	}
	cli := stringValue(mapValue(config, "paths")["host_runtime_cli"])
	if cli == "" {
		cli = filepath.Join(filepath.Dir(lifecycle), "agent-vmm")
	}
	if !executable(cli) {
		return false, nil, provisionerError{code: "agent_vmm.cli_unavailable", message: "managed Agent VMM CLI is unavailable"}
	}
	targetSize := positiveRevision(update["size"])
	requestMaterial := strings.Join([]string{targetRelease, targetURL, targetDigest, strconv.FormatUint(targetSize, 10)}, "\x00")
	requestID := "agent-vmm-update-" + sha256Hex([]byte(requestMaterial))[:32]
	arguments := []string{
		"update", "--json", "--request-id", requestID,
		"--target-release-id", targetRelease, "--artifact-url", targetURL,
		"--artifact-sha256", targetDigest, "--artifact-size", strconv.FormatUint(targetSize, 10),
		"--lifecycle-helper", lifecycle,
	}
	arguments = append(arguments, serviceArgs...)
	ctx, cancel := context.WithTimeout(context.Background(), hostRuntimeUpdateTimeout)
	defer cancel()
	output, outputOversize, runErr := runCommandWithOutputLimit(ctx, 2<<20, cli, arguments...)
	if outputOversize {
		return false, agentVMMTerminalUpdateAdvisory(targetRelease, requestID, "agent_vmm.update_result_oversize", "Managed Agent VMM update returned more than 2 MiB."), nil
	}
	var result map[string]any
	if json.Unmarshal(output, &result) != nil || positiveRevision(result["version"]) != 1 || stringValue(result["command"]) != "update" ||
		stringValue(result["state"]) == "" || stringValue(mapValue(result, "facts")["target_release_id"]) != targetRelease ||
		stringValue(mapValue(result, "facts")["request_id"]) != requestID {
		return false, agentVMMTerminalUpdateAdvisory(targetRelease, requestID, "agent_vmm.update_result_invalid", "Managed Agent VMM update returned an invalid result."), nil
	}
	state := stringValue(result["state"])
	disposition := stringValue(result["disposition"])
	payload := map[string]any{
		"status": "agent_vmm_update_" + state,
		"progress": progressPayload(map[string]any{
			"stage": firstNonEmpty(stringValue(result["stage"]), "unknown"), "request_id": requestID, "target_release_id": targetRelease,
		}),
		"agent_vmm_update": result,
	}
	if runErr != nil {
		return false, agentVMMTerminalUpdateAdvisory(targetRelease, requestID, "agent_vmm.update_process_failed", "Managed Agent VMM update exited without a successful CLI contract."), nil
	}
	switch disposition {
	case "exclusive_transition_in_progress":
		if state != "transition_in_progress" {
			return false, agentVMMTerminalUpdateAdvisory(targetRelease, requestID, "agent_vmm.update_disposition_invalid", "Managed Agent VMM update returned an invalid disposition for its state."), nil
		}
		payload["failure_code"] = "agent_vmm.update_" + state
		payload["failure_message"] = "The lifecycle owner has an exclusive Agent VMM transition in progress."
		return true, payload, nil
	case "retry_same_request_at":
		if state != "retry_wait" || strings.TrimSpace(stringValue(mapValue(result, "facts")["retry_at"])) == "" {
			return false, agentVMMTerminalUpdateAdvisory(targetRelease, requestID, "agent_vmm.update_disposition_invalid", "Managed Agent VMM update returned an invalid disposition for its state."), nil
		}
		payload["failure_code"] = "agent_vmm.update_" + state
		payload["failure_message"] = "Managed Agent VMM update did not complete. Follow the typed disposition and keep the same selected target and request identity."
		return false, payload, nil
	case "administrator_action_required":
		if state != "needs_administrator" {
			return false, agentVMMTerminalUpdateAdvisory(targetRelease, requestID, "agent_vmm.update_disposition_invalid", "Managed Agent VMM update returned an invalid disposition for its state."), nil
		}
		payload["failure_code"] = "agent_vmm.update_" + state
		payload["failure_message"] = "Managed Agent VMM update did not complete. Follow the typed disposition and keep the same selected target and request identity."
		return false, payload, nil
	case "terminal_action_required":
		if state != "action_required" {
			return false, agentVMMTerminalUpdateAdvisory(targetRelease, requestID, "agent_vmm.update_disposition_invalid", "Managed Agent VMM update returned an invalid disposition for its state."), nil
		}
		payload["failure_code"] = "agent_vmm.update_" + state
		payload["failure_message"] = "Managed Agent VMM update did not complete. Follow the typed disposition and keep the same selected target and request identity."
		return false, payload, nil
	case "continue_normal_work":
		if state != "succeeded" {
			return false, agentVMMTerminalUpdateAdvisory(targetRelease, requestID, "agent_vmm.update_disposition_invalid", "Managed Agent VMM update returned an invalid disposition for its state."), nil
		}
	default:
		return false, agentVMMTerminalUpdateAdvisory(targetRelease, requestID, "agent_vmm.update_disposition_invalid", "Managed Agent VMM update did not return a recognized disposition."), nil
	}
	capabilities := copyStringAnyMap(mapValue(config, "capabilities"))
	digests := copyStringAnyMap(mapValue(capabilities, "component_digests"))
	digests["agent-vmm-host"] = targetDigest
	capabilities["component_digests"] = digests
	config["capabilities"] = capabilities
	if err := writeJSON(expandUser(opts.configPath), config, 0o600); err != nil {
		return true, payload, provisionerError{code: "agent-vmm.digest_state_persist_failed", message: "agent-vmm installed artifact digest could not be persisted"}
	}
	return false, payload, nil
}

func agentVMMTerminalUpdateAdvisory(targetRelease, requestID, code, message string) map[string]any {
	return map[string]any{
		"status":          "agent_vmm_update_action_required",
		"failure_code":    code,
		"failure_message": message,
		"progress": progressPayload(map[string]any{
			"stage": "owner_response", "request_id": requestID, "target_release_id": targetRelease,
		}),
		"agent_vmm_update": map[string]any{
			"version": 1, "command": "update", "state": "action_required", "stage": "owner_response",
			"disposition": "terminal_action_required",
		},
	}
}

func provisionerFailureCode(err error, fallback string) string {
	var classified provisionerError
	if errors.As(err, &classified) && classified.code != "" {
		return classified.code
	}
	return fallback
}

func verifyComponentTarget(config map[string]any, component string, update map[string]any, artifactURL string) error {
	_ = config
	expectedWireComponent := component
	if component == "agent-vmm" {
		expectedWireComponent = "agent-vmm-host"
	}
	if wireComponent := stringValue(update["component"]); wireComponent != expectedWireComponent {
		return provisionerError{code: component + ".target_component_mismatch", message: component + " target names a different server-bound component"}
	}
	targetDigest := normalizedDigest(update["sha256"])
	targetSize := positiveRevision(update["size"])
	if targetDigest == "" || targetSize == 0 {
		return provisionerError{code: component + ".target_identity_invalid", message: component + " target artifact digest and size are required"}
	}
	parsed, err := url.Parse(artifactURL)
	secureScheme := parsed != nil && parsed.Scheme == "https"
	testLoopbackScheme := parsed != nil && allowInsecureLoopbackArtifact && parsed.Scheme == "http" && parsed.Hostname() == "127.0.0.1"
	if err != nil || (!secureScheme && !testLoopbackScheme) || parsed.Host == "" || parsed.RawQuery != "" || parsed.Fragment != "" || strings.Contains(artifactURL, "__BFT_PLATFORM__") {
		return provisionerError{code: component + ".artifact_url_invalid", message: component + " target artifact URL must be exact HTTPS"}
	}
	return nil
}

func agentVMMRelease(config map[string]any) (map[string]any, bool) {
	info, err := agentVMMBuildInfo(config, agentVMMVersionTimeout)
	return info, err == nil
}

func agentVMMBuildInfo(config map[string]any, timeout time.Duration) (map[string]any, error) {
	path, err := requirePath(config, "host_runtime_lifecycle")
	if err != nil || path == "" {
		return nil, provisionerError{code: "agent_vmm.version_path_invalid", message: "Agent VMM lifecycle helper path is unavailable"}
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, path, "version", "--json").Output()
	if err != nil {
		if errors.Is(ctx.Err(), context.DeadlineExceeded) {
			return nil, provisionerError{code: "agent_vmm.version_probe_timeout", message: "Agent VMM lifecycle version probe timed out"}
		}
		return nil, provisionerError{code: "agent_vmm.version_probe_failed", message: "Agent VMM lifecycle version probe failed: " + err.Error()}
	}
	var info map[string]any
	if json.Unmarshal(out, &info) != nil {
		return nil, provisionerError{code: "agent_vmm.version_result_invalid", message: "Agent VMM lifecycle version result is invalid"}
	}
	version := strings.TrimSpace(stringValue(info["version"]))
	releaseID := strings.TrimSpace(stringValue(info["release_id"]))
	if version == "" || releaseID == "" || version != releaseID ||
		slices.Contains([]string{"dev", "development", "unknown"}, strings.ToLower(version)) {
		return nil, provisionerError{code: "agent_vmm.version_identity_invalid", message: "Agent VMM lifecycle version identity is invalid"}
	}
	info["version"] = version
	capabilities := mapValue(config, "capabilities")
	digests := mapValue(capabilities, "component_digests")
	if digest := normalizedDigest(digests["agent-vmm-host"]); digest != "" {
		info["artifact_digest"] = digest
	}
	return info, nil
}

func runHostRuntimeOperation(path string, args []string) error {
	ctx, cancel := context.WithTimeout(context.Background(), hostRuntimeOperationTimeout)
	defer cancel()
	return exec.CommandContext(ctx, path, args...).Run()
}

func hostRuntimeServiceArguments(config map[string]any) ([]string, error) {
	launchd := mapValue(config, "launchd")
	domain := strings.TrimSpace(stringValue(launchd["domain"]))
	mode := "agent"
	if domain == "system" {
		mode = "daemon"
	} else if domain != "" && !strings.HasPrefix(domain, "gui/") {
		return nil, provisionerError{code: "agent_vmm.service_domain_invalid", message: "Agent VMM launchd domain is invalid"}
	}
	serviceUser := strings.TrimSpace(stringValue(launchd["service_user"]))
	if serviceUser == "" {
		return nil, provisionerError{code: "agent_vmm.service_user_invalid", message: "runner config missing launchd.service_user"}
	}
	return []string{"--service-type", mode, "--service-user", serviceUser}, nil
}

func parseSHA256(raw string) string {
	fields := strings.Fields(raw)
	if len(fields) == 0 {
		return ""
	}
	candidate := strings.ToLower(strings.TrimSpace(fields[0]))
	if len(candidate) != 64 {
		return ""
	}
	if _, err := hex.DecodeString(candidate); err != nil {
		return ""
	}
	return candidate
}

func positiveRevision(value any) uint64 {
	switch typed := value.(type) {
	case uint64:
		return typed
	case int:
		if typed > 0 {
			return uint64(typed)
		}
	case float64:
		if typed > 0 && typed == float64(uint64(typed)) {
			return uint64(typed)
		}
	case json.Number:
		parsed, err := strconv.ParseUint(string(typed), 10, 64)
		if err == nil {
			return parsed
		}
	case string:
		parsed, err := strconv.ParseUint(strings.TrimSpace(typed), 10, 64)
		if err == nil {
			return parsed
		}
	}
	return 0
}

func normalizedDigest(value any) string {
	digest := strings.ToLower(strings.TrimSpace(stringValue(value)))
	digest = strings.TrimPrefix(digest, "sha256:")
	return parseSHA256(digest)
}

func sha256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func runWorker(opts runOptions) error {
	configPath := expandUser(opts.configPath)
	config, err := loadJSON(configPath)
	if err != nil {
		return err
	}
	apiBaseURL, err := requireConfig(config, "api_base_url")
	if err != nil {
		return err
	}
	orgID, err := requireConfig(config, "org_id")
	if err != nil {
		return err
	}
	token, err := requireConfig(config, "runner_token")
	if err != nil {
		return err
	}
	stateDir, err := requirePath(config, "state_dir")
	if err != nil {
		return err
	}
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return err
	}
	workerStatusPath := opts.statusPath
	if workerStatusPath == "" {
		workerStatusPath = filepath.Join(stateDir, "runner-status.json")
	}

	fmt.Println("BridgeForTeams runner")
	fmt.Printf("Org ID: %s\n", orgID)
	if opts.start {
		fmt.Println("Mode: apply")
	} else {
		fmt.Println("Mode: dry run (nothing applied)")
	}
	fmt.Printf("Status path: %s\n", workerStatusPath)
	fmt.Println("")

	var register map[string]any
	for {
		httpStatus, response, requestErr := postJSON(apiBaseURL, token, fmt.Sprintf("/v1/orgs/%s/runners", orgID), provisionerPayload(config, nil), opts.timeout)
		register, err = expectSuccess(httpStatus, response, "register", requestErr)
		if err == nil {
			break
		}
		if !keepRunningAfterControlError(opts, err) {
			return err
		}
		time.Sleep(opts.interval)
	}
	provisioner := mapValue(register, "runner")
	provisionerID := stringValue(provisioner["id"])
	if provisionerID == "" {
		return provisionerError{code: "register.provisioner_id_missing", message: "register response missing id"}
	}

	iteration := 0
	for {
		iteration++
		err := runWorkerIteration(opts, config, stateDir, workerStatusPath, apiBaseURL, token, orgID, provisionerID)
		if err != nil && !keepRunningAfterControlError(opts, err) {
			return err
		}
		if !opts.loop {
			break
		}
		if opts.maxIterations != 0 && iteration >= opts.maxIterations {
			break
		}
		time.Sleep(opts.interval)
	}
	return nil
}

func runWorkerIteration(opts runOptions, config map[string]any, stateDir, workerStatusPath, apiBaseURL, token, orgID, provisionerID string) error {
	installFailures, err := agentVMMRegistrationFailureReports(stateDir)
	if err != nil {
		return err
	}
	httpStatus, response, err := postJSON(apiBaseURL, token, fmt.Sprintf("/v1/orgs/%s/runners/%s/heartbeat", orgID, provisionerID), provisionerPayload(config, installFailures), opts.timeout)
	heartbeat, err := expectSuccess(httpStatus, response, "heartbeat", err)
	if err != nil {
		return err
	}
	if err := persistAgentVMMRegistrationDescriptor(stateDir, heartbeat); err != nil {
		return err
	}
	if err := acknowledgeAgentVMMRegistrationFailures(config, stateDir, heartbeat); err != nil {
		return err
	}
	if err := applyAgentVMMRegistrationDescriptor(opts, config, stateDir, workerStatusPath, heartbeat); err != nil {
		fmt.Fprintf(os.Stderr, "Agent VMM managed installation failed: %v\n", err)
	}
	exclusiveUpdate, updateAdvisory, err := applyProvisionerUpdates(opts, config, heartbeat)
	if exclusiveUpdate && len(updateAdvisory) != 0 {
		if statusErr := writeWorkerStatus(workerStatusPath, updateAdvisory); statusErr != nil {
			return statusErr
		}
	}
	if err != nil || exclusiveUpdate {
		return err
	}
	if err := applyAgentVMMControls(opts, config, stateDir, workerStatusPath, heartbeat); err != nil {
		fmt.Fprintf(os.Stderr, "Agent VMM registration control failed: %v\n", err)
		return nil
	}
	payload := map[string]any{"status": "online", "provisioner_id": provisionerID}
	if len(updateAdvisory) != 0 {
		payload["agent_vmm_update"] = updateAdvisory
	}
	if err := writeWorkerStatus(workerStatusPath, payload); err != nil {
		return err
	}
	fmt.Println("Status: online")
	return nil
}

func keepRunningAfterControlError(opts runOptions, err error) bool {
	var controlErr controlPlaneError
	if !opts.loop || !errors.As(err, &controlErr) {
		return false
	}
	if controlErr.status >= 400 && controlErr.status < 500 &&
		controlErr.status != http.StatusRequestTimeout &&
		controlErr.status != http.StatusTooManyRequests {
		return false
	}
	fmt.Fprintf(os.Stderr, "Control plane unavailable: %v\n", controlErr)
	return true
}

func runDoctor(opts runOptions) error {
	config, err := loadJSON(expandUser(opts.configPath))
	if err != nil {
		return err
	}
	if _, err := requireConfig(config, "api_base_url"); err != nil {
		return err
	}
	if _, err := requireConfig(config, "org_id"); err != nil {
		return err
	}
	if _, err := requireConfig(config, "runner_token"); err != nil {
		return err
	}
	stateDir, err := requirePath(config, "state_dir")
	if err != nil {
		return err
	}
	vmm, err := observeManagedVMM(config)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return provisionerError{code: "preflight.state_dir_not_ready", message: "state_dir is not writable"}
	}
	fmt.Println("BridgeForTeams runner")
	fmt.Println("Doctor passed")
	fmt.Printf("Config: %s\n", expandUser(opts.configPath))
	fmt.Printf("State: %s\n", stateDir)
	fmt.Printf("Agent VMM: %s (%s)\n", vmm.State, vmm.Freshness)
	return nil
}

func runStatus(opts runOptions) error {
	config, err := loadJSON(expandUser(opts.configPath))
	if err != nil {
		return err
	}
	stateDir, err := requirePath(config, "state_dir")
	if err != nil {
		return err
	}
	statusPath := opts.statusPath
	if statusPath == "" {
		statusPath = filepath.Join(stateDir, "runner-status.json")
	}
	status := map[string]any{}
	if raw, err := os.ReadFile(statusPath); err == nil {
		_ = json.Unmarshal(raw, &status)
	}
	provisioner := mapValue(config, "runner")
	vmm, vmmErr := observeManagedVMM(config)
	fmt.Println("BridgeForTeams runner")
	fmt.Printf("Org ID: %s\n", stringValue(config["org_id"]))
	fmt.Printf("Runner: %s\n", firstNonEmpty(stringValue(provisioner["name"]), stringValue(provisioner["stable_id"]), "unknown"))
	fmt.Printf("Status path: %s\n", statusPath)
	if len(status) == 0 {
		fmt.Println("Status: unknown")
		fmt.Println("No worker status file found yet.")
		printManagedVMMObservation(vmm, vmmErr)
		return nil
	}
	fmt.Printf("Status: %s\n", firstNonEmpty(stringValue(status["status"]), "unknown"))
	if updated := intValue(status["updated_at"], 0); updated != 0 {
		fmt.Printf("Updated at: %d\n", updated)
	}
	printManagedVMMObservation(vmm, vmmErr)
	return nil
}

type managedVMMObservation struct {
	Version   int    `json:"version"`
	State     string `json:"state"`
	Freshness string `json:"freshness"`
	Partial   bool   `json:"partial"`
}

func printManagedVMMObservation(observation managedVMMObservation, err error) {
	if err != nil {
		fmt.Printf("Agent VMM: unavailable (%v)\n", err)
		return
	}
	fmt.Printf("Agent VMM: %s (%s)\n", observation.State, observation.Freshness)
}

func observeManagedVMM(config map[string]any) (managedVMMObservation, error) {
	lifecycle, err := requirePath(config, "host_runtime_lifecycle")
	if err != nil || !executable(lifecycle) {
		return managedVMMObservation{}, provisionerError{code: "agent_vmm.lifecycle_unavailable", message: "Agent VMM lifecycle helper is unavailable"}
	}
	cli := stringValue(mapValue(config, "paths")["host_runtime_cli"])
	if cli == "" {
		cli = filepath.Join(filepath.Dir(lifecycle), "agent-vmm")
	}
	if !executable(cli) {
		return managedVMMObservation{}, provisionerError{code: "agent_vmm.cli_unavailable", message: "managed Agent VMM CLI is unavailable"}
	}
	serviceArgs, err := hostRuntimeServiceArguments(config)
	if err != nil {
		return managedVMMObservation{}, err
	}
	arguments := []string{"inspect", "--json", "--lifecycle-helper", lifecycle}
	arguments = append(arguments, serviceArgs...)
	// The CLI owns its five-second observation budget. This outer deadline only
	// stops a wedged child after the CLI has had time to return partial facts.
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	output, err := exec.CommandContext(ctx, cli, arguments...).Output()
	if err != nil {
		return managedVMMObservation{}, provisionerError{code: "agent_vmm.inspect_failed", message: "managed Agent VMM inspect failed"}
	}
	if len(output) > 2<<20 {
		return managedVMMObservation{}, provisionerError{code: "agent_vmm.inspect_oversize", message: "managed Agent VMM inspect exceeded 2 MiB"}
	}
	var observation managedVMMObservation
	if json.Unmarshal(output, &observation) != nil || observation.Version != 1 || observation.State == "" || observation.Freshness == "" {
		return managedVMMObservation{}, provisionerError{code: "agent_vmm.inspect_invalid", message: "managed Agent VMM inspect returned an invalid contract"}
	}
	return observation, nil
}

func runLogs(opts runOptions) error {
	config, err := loadJSON(expandUser(opts.configPath))
	if err != nil {
		return err
	}
	stateDir, err := requirePath(config, "state_dir")
	if err != nil {
		return err
	}
	logsDir := filepath.Join(stateDir, "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		return err
	}
	return filepath.WalkDir(logsDir, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		if strings.HasSuffix(entry.Name(), ".log") {
			fmt.Println(path)
		}
		return nil
	})
}

func runService(args []string) error {
	if len(args) == 0 {
		return provisionerError{code: "service.command_missing", message: "service command is required: start, stop, status, or remove"}
	}
	action := args[0]
	switch action {
	case "start", "stop", "status", "remove":
	default:
		return provisionerError{code: "service.command_unknown", message: "unknown service command: " + action}
	}
	opts := parseServiceArgs(action, args[1:])
	config, err := loadJSON(expandUser(opts.configPath))
	if err != nil {
		return err
	}
	service, err := serviceConfigFrom(config)
	if err != nil {
		return err
	}
	if err := validateServicePermission(service, action, os.Geteuid()); err != nil {
		return err
	}
	switch action {
	case "start":
		return serviceStart(service)
	case "stop":
		return serviceStop(service)
	case "status":
		return serviceStatus(service)
	case "remove":
		return serviceRemove(service)
	}
	return nil
}

func validateFixedSystemService(service serviceConfig) error {
	if service.label != "com.bridgeforteams.runner" {
		return provisionerError{code: "service.system_target_rejected", message: "the administrator executor only accepts the fixed BFT runner job"}
	}
	return nil
}

func validateServicePermission(service serviceConfig, action string, euid int) error {
	if service.domain == "system" && action != "status" {
		if err := validateFixedSystemService(service); err != nil {
			return err
		}
		return provisionerError{
			code: "service.system_administrator_action_required",
			message: "ask an administrator to run /Library/PrivilegedHelperTools/bft-runner-service-executor " + action +
				"; do not run the service-user-owned bft-runner as root",
		}
	}
	_ = euid
	return nil
}

func parseServiceArgs(action string, args []string) runOptions {
	fs := flag.NewFlagSet("service "+action, flag.ExitOnError)
	opts := runOptions{}
	fs.StringVar(&opts.configPath, "config", defaultConfigPath(), "path to protected runner.json")
	_ = fs.Parse(args)
	return opts
}

type serviceConfig struct {
	label        string
	domain       string
	sourcePlist  string
	installPlist string
	statusPath   string
}

func serviceConfigFrom(config map[string]any) (serviceConfig, error) {
	launchd := mapValue(config, "launchd")
	paths := mapValue(config, "paths")
	stateDir, err := requirePath(config, "state_dir")
	if err != nil {
		return serviceConfig{}, err
	}
	service := serviceConfig{
		label:        stringValue(launchd["label"]),
		domain:       stringValue(launchd["domain"]),
		sourcePlist:  stringValue(launchd["source_plist"]),
		installPlist: stringValue(launchd["install_plist"]),
		statusPath:   stringValue(paths["runner_install_status"]),
	}
	if service.statusPath == "" {
		service.statusPath = filepath.Join(filepath.Dir(stateDir), "runner-install-status.json")
	}
	if service.label == "" {
		return serviceConfig{}, provisionerError{code: "service.launchd_label_missing", message: "runner config missing launchd.label"}
	}
	if service.domain == "" {
		return serviceConfig{}, provisionerError{code: "service.launchd_domain_missing", message: "runner config missing launchd.domain"}
	}
	if service.sourcePlist == "" {
		return serviceConfig{}, provisionerError{code: "service.launchd_source_plist_missing", message: "runner config missing launchd.source_plist"}
	}
	if service.installPlist == "" {
		return serviceConfig{}, provisionerError{code: "service.launchd_install_plist_missing", message: "runner config missing launchd.install_plist"}
	}
	return service, nil
}

func serviceStart(service serviceConfig) error {
	if err := os.MkdirAll(filepath.Dir(service.installPlist), 0o755); err != nil {
		return err
	}
	if err := copyFile(service.sourcePlist, service.installPlist); err != nil {
		return err
	}
	_ = runLaunchctl("bootout", service.domain+"/"+service.label)
	if err := runLaunchctl("bootstrap", service.domain, service.installPlist); err != nil {
		return err
	}
	if err := runLaunchctl("kickstart", "-k", service.domain+"/"+service.label); err != nil {
		return err
	}
	if err := updateServiceStatus(service.statusPath, service.installPlist, boolPtr(true), boolPtr(true), "bootstrap", nil); err != nil {
		return err
	}
	fmt.Printf("launchd loaded: %s\n", service.label)
	return nil
}

func serviceStop(service serviceConfig) error {
	if err := runLaunchctl("bootout", service.domain+"/"+service.label); err != nil {
		return err
	}
	installed := fileExists(service.installPlist)
	if err := updateServiceStatus(service.statusPath, service.installPlist, boolPtr(installed), boolPtr(false), "bootout", nil); err != nil {
		return err
	}
	fmt.Printf("launchd unloaded: %s\n", service.label)
	return nil
}

func serviceStatus(service serviceConfig) error {
	installed := fileExists(service.installPlist)
	err := runLaunchctl("print", service.domain+"/"+service.label)
	loaded := err == nil
	updateErr := updateServiceStatus(service.statusPath, service.installPlist, boolPtr(installed), boolPtr(loaded), "status", nil)
	if err != nil {
		return err
	}
	return updateErr
}

func serviceRemove(service serviceConfig) error {
	if err := runLaunchctl("bootout", service.domain+"/"+service.label); err != nil {
		return err
	}
	removed := fileExists(service.installPlist)
	if removed {
		if err := os.Remove(service.installPlist); err != nil {
			return err
		}
	}
	if err := updateServiceStatus(service.statusPath, service.installPlist, boolPtr(false), boolPtr(false), "remove", boolPtr(removed)); err != nil {
		return err
	}
	fmt.Printf("launchd install removed: %s\n", service.installPlist)
	return nil
}

func runLaunchctl(args ...string) error {
	cmd := exec.Command("launchctl", args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

func updateServiceStatus(statusPath, installPath string, installed, loaded *bool, action string, removed *bool) error {
	status := map[string]any{}
	if raw, err := os.ReadFile(statusPath); err == nil {
		_ = json.Unmarshal(raw, &status)
	}
	launchd, ok := status["launchd"].(map[string]any)
	if !ok {
		launchd = map[string]any{}
		status["launchd"] = launchd
	}
	if installed != nil {
		launchd["installed"] = *installed
		if *installed {
			launchd["install_path"] = installPath
		}
	} else if boolValue(launchd["installed"]) && stringValue(launchd["install_path"]) == "" {
		launchd["install_path"] = installPath
	}
	if loaded != nil {
		launchd["loaded"] = *loaded
	}
	launchd["last_action"] = action
	if removed != nil {
		launchd["last_remove_removed"] = *removed
	}
	raw, err := json.Marshal(status)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	return os.WriteFile(statusPath, raw, 0o644)
}

func copyFile(source, destination string) error {
	raw, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	return os.WriteFile(destination, raw, 0o644)
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func boolPtr(value bool) *bool {
	return &value
}

func boolValue(value any) bool {
	typed, ok := value.(bool)
	return ok && typed
}

func expandUser(path string) string {
	if path == "~" {
		home, err := os.UserHomeDir()
		if err == nil {
			return home
		}
	}
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			return filepath.Join(home, strings.TrimPrefix(path, "~/"))
		}
	}
	return path
}

func runDetachedLifecycle(ctx context.Context, path string, args []string, input []byte) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	command := exec.Command(path, args...)
	command.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	retained := append([]byte(nil), input...)
	if retained != nil {
		command.Stdin = bytes.NewReader(retained)
	}
	output := &boundedOutputBuffer{limit: 1 << 20}
	command.Stdout = output
	if err := command.Start(); err != nil {
		return nil, err
	}
	done := make(chan error, 1)
	go func() {
		err := command.Wait()
		for index := range retained {
			retained[index] = 0
		}
		done <- err
	}()
	snapshot := func() []byte {
		output.mu.Lock()
		defer output.mu.Unlock()
		return append([]byte(nil), output.buffer.Bytes()...)
	}
	select {
	case err := <-done:
		return snapshot(), err
	case <-ctx.Done():
		return snapshot(), ctx.Err()
	}
}
