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
	"math"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const version = "0.1.0"

const salixConnectVersionTimeout = 2 * time.Second
const hostRuntimeOperationTimeout = 3 * time.Minute
const hostRuntimeUpdateTimeout = 21 * time.Minute
const largeArtifactDownloadTimeout = 10 * time.Minute

const (
	statusReportQueueCapacity = 256
	reporterShutdownGrace     = 250 * time.Millisecond
)

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

type managedConnector struct {
	requestID      string
	argv           []string
	env            []string
	configPath     string
	root           string
	process        *exec.Cmd
	done           chan processExit
	restartCount   int
	lastExitCode   *int
	attached       bool
	connectorRunID string
	stderrLog      string
}

type processExit struct {
	exitCode int
	err      error
}

type statusReport struct {
	requestID string
	status    string
	payload   map[string]any
	verify    bool
}

// statusReporter keeps provision-request projection outside the local
// Connector lifecycle. Reports are best-effort observations: heartbeat and
// Connector supervision must continue even when the Server rejects them.
type statusReporter struct {
	apiBaseURL    string
	token         string
	orgID         string
	provisionerID string
	timeout       time.Duration
	queue         chan statusReport
	stale         chan string
	ctx           context.Context
	cancel        context.CancelFunc
	pending       sync.WaitGroup
	done          chan struct{}
}

type launchPlan struct {
	argv       []string
	env        []string
	configPath string
	config     map[string]any
	root       string
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
	case "claim":
		opts := parseRunArgs(args, runDefaults{start: false, loop: false})
		opts.once = true
		opts.loop = false
		err = runWorker(opts)
	case "dry-run", "once":
		if len(args) != 0 {
			fmt.Fprintf(os.Stderr, "bft-runner %s does not accept extra arguments; use claim for worker flags\n", command)
			return 2
		}
		opts := parseRunArgs(nil, runDefaults{start: false, loop: false})
		opts.once = true
		opts.loop = false
		err = runWorker(opts)
	case "doctor":
		err = runDoctor(parseStatusArgs(args))
	case "preprocess":
		var opts preprocessOptions
		opts, err = parsePreprocessArgs(args)
		if err == nil {
			err = runPreprocess(opts, systemFallbackExecutor{})
		}
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
	fmt.Fprintln(w, "  bft-runner preprocess --input path --output path")
	fmt.Fprintln(w, "  bft-runner status")
	fmt.Fprintln(w, "  bft-runner logs")
	fmt.Fprintln(w, "  bft-runner service start")
	fmt.Fprintln(w, "  bft-runner service stop")
	fmt.Fprintln(w, "  bft-runner service status")
	fmt.Fprintln(w, "  bft-runner service remove")
	fmt.Fprintln(w, "")
	fmt.Fprintln(w, "Low-level worker entrypoints:")
	fmt.Fprintln(w, "  bft-runner run [--config path]")
	fmt.Fprintln(w, "  bft-runner claim [--config path]")
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
	fs.BoolVar(&opts.start, "start", opts.start, "spawn salix-connect")
	fs.BoolVar(&opts.once, "once", false, "run one claim cycle and exit")
	fs.BoolVar(&opts.loop, "loop", opts.loop, "keep heartbeating, claiming, and supervising")
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

func connectorConfigDir(stateDir string) string {
	return filepath.Join(stateDir, "connectors")
}

func connectorConfigPath(stateDir, requestID string) string {
	return filepath.Join(connectorConfigDir(stateDir), requestID+".json")
}

func connectorStatusPath(stateDir, requestID string) string {
	return filepath.Join(connectorConfigDir(stateDir), requestID+".status.json")
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

func getJSON(apiBaseURL, token, path string, timeout time.Duration) (int, map[string]any, error) {
	return requestJSON(http.MethodGet, apiBaseURL, token, path, nil, timeout)
}

func requestJSON(method, apiBaseURL, token, path string, body []byte, timeout time.Duration) (int, map[string]any, error) {
	return requestJSONContext(context.Background(), method, apiBaseURL, token, path, body, timeout)
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

func provisionerPayload(config map[string]any, currentConnectorCount int, installFailures []any) map[string]any {
	provisioner := mapValue(config, "runner")
	host, _ := os.Hostname()
	if host == "" {
		host = "bft-runner"
	}
	capacity := configuredCapacity(config)
	payload := map[string]any{
		"stable_id":               firstNonEmpty(stringValue(provisioner["stable_id"]), host),
		"name":                    firstNonEmpty(stringValue(provisioner["name"]), host),
		"status":                  "online",
		"host_identity":           host,
		"os_summary":              fmt.Sprintf("%s %s %s", runtime.GOOS, runtime.Version(), runtime.GOARCH),
		"version":                 version,
		"capabilities":            provisionerCapabilities(config),
		"capacity":                capacity,
		"current_connector_count": currentConnectorCount,
	}
	if cursor := stringValue(config["_agent_vmm_control_cursor"]); cursor != "" {
		payload["agent_vmm_control_cursor"] = cursor
	}
	if len(installFailures) != 0 {
		payload["agent_vmm_install_failures"] = installFailures
	}
	return payload
}

func managedProvisionRequestIDs(connectors map[string]*managedConnector) []string {
	ids := make([]string, 0, len(connectors))
	for requestID := range connectors {
		if requestID != "" {
			ids = append(ids, requestID)
		}
	}
	sort.Strings(ids)
	return ids
}

func provisionerCapabilities(config map[string]any) map[string]any {
	capabilities := copyStringAnyMap(mapValue(config, "capabilities"))
	capabilities["platform"] = runtime.GOOS + "-" + runtime.GOARCH
	for _, component := range []string{"salix-connect", "agent-vmm"} {
		build, verified := componentBuildInfo(config, component)
		if !verified {
			continue
		}
		capabilityComponent := component
		if component == "agent-vmm" {
			capabilityComponent = "agent-vmm-host"
		}
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

// salixConnectBuildInfo and applyProvisionerUpdates implement
// tla/connector/ManagedConnectorRelease.tla: unknown is not a mismatch.
func salixConnectBuildInfo(config map[string]any) (map[string]any, bool) {
	path, err := requirePath(config, "salix_connect")
	if err != nil || path == "" {
		return map[string]any{}, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), salixConnectVersionTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, path, "version", "--json").Output()
	if err != nil {
		return map[string]any{}, false
	}
	var info map[string]any
	if err := json.Unmarshal(out, &info); err != nil {
		return map[string]any{}, false
	}
	version := strings.TrimSpace(stringValue(info["version"]))
	releaseID := strings.TrimSpace(stringValue(info["release_id"]))
	if version == "" || releaseID == "" || version != releaseID ||
		slices.Contains([]string{"dev", "development", "unknown"}, strings.ToLower(version)) ||
		slices.Contains([]string{"dev", "development", "unknown"}, strings.ToLower(releaseID)) {
		return map[string]any{}, false
	}
	info["version"] = version
	if artifact, readErr := os.ReadFile(path); readErr == nil {
		info["artifact_digest"] = sha256Hex(artifact)
	}
	return info, true
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

// runnerWorkdir is the runner-owned directory that holds managed connector roots.
func runnerWorkdir(config map[string]any) (string, error) {
	return requirePath(config, "workdir")
}

func connectorRootDirName(requestID string) string {
	return "bft_" + strings.ReplaceAll(requestID, "-", "_")
}

// resolveConnectorRoot places the managed connector root under the runner
// workdir. Server payloads use a relative root.
func resolveConnectorRoot(workdir, requestID string, launch map[string]any) string {
	root := stringValue(launch["root"])
	if root == "" {
		root = filepath.Join("agents", connectorRootDirName(requestID))
	}
	if !filepath.IsAbs(root) {
		root = filepath.Join(workdir, root)
	}
	return filepath.Clean(root)
}

func buildLaunch(config map[string]any, connect map[string]any, launch map[string]any, stateDir, requestID string) (launchPlan, error) {
	salixConnect, err := requirePath(config, "salix_connect")
	if err != nil {
		return launchPlan{}, err
	}
	workdir, err := runnerWorkdir(config)
	if err != nil {
		return launchPlan{}, err
	}
	if !executable(salixConnect) {
		return launchPlan{}, provisionerError{code: "preflight.salix_connect_not_executable", message: "salix-connect is not executable: " + salixConnect}
	}

	root := resolveConnectorRoot(workdir, requestID, launch)
	if err := os.MkdirAll(root, 0o755); err != nil {
		return launchPlan{}, err
	}

	server := stringValue(connect["server"])
	token := stringValue(connect["token"])
	if server == "" {
		return launchPlan{}, provisionerError{code: "preflight.connect_server_missing", message: "connect.server is required"}
	}
	if token == "" {
		return launchPlan{}, provisionerError{code: "preflight.connector_credential_missing", message: "connect.credential is required"}
	}

	configPath := connectorConfigPath(stateDir, requestID)
	statusPath := connectorStatusPath(stateDir, requestID)

	connectorConfig := map[string]any{
		"connector": map[string]any{
			"server":          server,
			"connector_token": token,
			"name":            firstNonEmpty(stringValue(launch["name"]), "Project device"),
			"alias":           stringValue(launch["alias"]),
			"root":            root,
		},
		"status": map[string]any{"path": statusPath},
	}
	argv := []string{salixConnect, "--config", configPath}
	env := append(os.Environ(), "BFT_WORKDIR="+workdir)

	return launchPlan{
		argv:       argv,
		env:        env,
		configPath: configPath,
		config:     connectorConfig,
		root:       root,
	}, nil
}

func launchFromStoredConnectorConfig(config map[string]any, stateDir, requestID string) (launchPlan, error) {
	salixConnect, err := requirePath(config, "salix_connect")
	if err != nil {
		return launchPlan{}, err
	}
	configPath := connectorConfigPath(stateDir, requestID)
	stored, err := loadJSON(configPath)
	if err != nil {
		return launchPlan{}, err
	}
	connector := mapValue(stored, "connector")
	root := stringValue(connector["root"])
	if root == "" {
		return launchPlan{}, provisionerError{code: "preflight.connector_root_missing", message: "stored connector config is missing connector.root"}
	}
	return launchPlan{
		argv:       []string{salixConnect, "--config", configPath},
		env:        os.Environ(),
		configPath: configPath,
		config:     stored,
		root:       root,
	}, nil
}

func redactLaunch(argv []string) map[string]any {
	name := ""
	if len(argv) > 0 {
		name = filepath.Base(argv[0])
	}
	return map[string]any{
		"argv_shape": []string{
			name,
			"--config", "<connector-config>",
		},
	}
}

func statusCallback(apiBaseURL, token, orgID, provisionerID, requestID, status string, timeout time.Duration, extra map[string]any) error {
	return statusCallbackContext(context.Background(), apiBaseURL, token, orgID, provisionerID, requestID, status, timeout, extra)
}

func statusCallbackContext(ctx context.Context, apiBaseURL, token, orgID, provisionerID, requestID, status string, timeout time.Duration, extra map[string]any) error {
	payload := map[string]any{"status": status}
	for key, value := range extra {
		payload[key] = value
	}
	httpStatus, response, err := postJSONContext(ctx, apiBaseURL, token, fmt.Sprintf("/v1/orgs/%s/runners/%s/provision-requests/%s/status", orgID, provisionerID, requestID), payload, timeout)
	_, err = expectSuccess(httpStatus, response, "status_callback", err)
	return err
}

func newStatusReporter(apiBaseURL, token, orgID, provisionerID string, timeout time.Duration) *statusReporter {
	ctx, cancel := context.WithCancel(context.Background())
	reporter := &statusReporter{
		apiBaseURL:    apiBaseURL,
		token:         token,
		orgID:         orgID,
		provisionerID: provisionerID,
		timeout:       timeout,
		queue:         make(chan statusReport, statusReportQueueCapacity),
		stale:         make(chan string, statusReportQueueCapacity),
		ctx:           ctx,
		cancel:        cancel,
		done:          make(chan struct{}),
	}
	go reporter.run()
	return reporter
}

func (r *statusReporter) enqueue(requestID, status string, payload map[string]any) bool {
	r.pending.Add(1)
	select {
	case r.queue <- statusReport{requestID: requestID, status: status, payload: payload}:
		return true
	default:
		r.pending.Done()
		return false
	}
}

func (r *statusReporter) verifyRequest(requestID string) bool {
	r.pending.Add(1)
	select {
	case r.queue <- statusReport{requestID: requestID, verify: true}:
		return true
	default:
		r.pending.Done()
		return false
	}
}

func (r *statusReporter) run() {
	defer close(r.done)
	for {
		select {
		case report := <-r.queue:
			var err error
			if report.verify {
				err = verifyProvisionRequestContext(r.ctx, r.apiBaseURL, r.token, r.orgID, r.provisionerID, report.requestID, r.timeout)
			} else {
				err = statusCallbackContext(r.ctx, r.apiBaseURL, r.token, r.orgID, r.provisionerID, report.requestID, report.status, r.timeout, report.payload)
			}
			if provisionRequestNotFound(err) && r.ctx.Err() == nil {
				// A 404 is not a transient projection failure: the Server no longer
				// recognizes this request as desired state. Hand the exact identity
				// back to the owner loop so it can stop the process, remove the
				// persisted credential, and release runner capacity.
				select {
				case r.stale <- report.requestID:
				case <-r.ctx.Done():
				}
			} else if err != nil && r.ctx.Err() == nil {
				fmt.Fprintf(os.Stderr, "Connector status report failed asynchronously: %v\n", err)
			}
			r.pending.Done()
		case <-r.ctx.Done():
			r.discardQueued()
			return
		}
	}
}

func verifyProvisionRequestContext(ctx context.Context, apiBaseURL, token, orgID, provisionerID, requestID string, timeout time.Duration) error {
	httpStatus, response, err := requestJSONContext(ctx, http.MethodGet, apiBaseURL, token, fmt.Sprintf("/v1/orgs/%s/runners/%s/provision-requests/%s", orgID, provisionerID, requestID), nil, timeout)
	_, err = expectSuccess(httpStatus, response, "provision_request_verify", err)
	return err
}

func provisionRequestNotFound(err error) bool {
	var controlErr controlPlaneError
	return errors.As(err, &controlErr) && controlErr.status == http.StatusNotFound
}

// reconcileRejectedManagedConnectors applies the Server's authoritative
// not-found result inside the runner owner loop. The status reporter only
// transports the exact request identity; it never mutates local lifecycle
// state from its asynchronous goroutine.
func reconcileRejectedManagedConnectors(reporter *statusReporter, config map[string]any, stateDir, workerStatusPath, provisionerID string, connectors map[string]*managedConnector) error {
	if reporter == nil {
		return nil
	}
	rejected := map[string]bool{}
	for {
		select {
		case requestID := <-reporter.stale:
			rejected[requestID] = true
		default:
			if len(rejected) == 0 {
				return nil
			}
			for requestID := range rejected {
				stopManagedConnector(requestID, connectors, config, stateDir)
				fmt.Fprintf(os.Stderr, "Removed stale managed connector after Server rejected provision request %s.\n", requestID)
			}
			return writeWorkerStatus(workerStatusPath, map[string]any{
				"status":             "stale_connector_removed",
				"provisioner_id":     provisionerID,
				"managed_connectors": managedConnectorsPayload(connectors),
				"progress": progressPayload(map[string]any{
					"stage":         "stale_connector_removed",
					"removed_count": len(rejected),
				}),
			})
		}
	}
}

func (r *statusReporter) stop() {
	flushed := make(chan struct{})
	go func() {
		r.pending.Wait()
		close(flushed)
	}()

	select {
	case <-flushed:
	case <-time.After(reporterShutdownGrace):
	}
	r.cancel()
	<-r.done
}

func (r *statusReporter) discardQueued() {
	for {
		select {
		case <-r.queue:
			r.pending.Done()
		default:
			return
		}
	}
}

func connectorStdoutLogPath(stateDir, requestID string) string {
	return filepath.Join(stateDir, "logs", requestID+".stdout.log")
}

func connectorStderrLogPath(stateDir, requestID string) string {
	return filepath.Join(stateDir, "logs", requestID+".stderr.log")
}

func spawnConnector(stateDir, requestID string, argv []string, env []string) (*exec.Cmd, chan processExit, string, error) {
	if err := os.Remove(connectorStatusPath(stateDir, requestID)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return nil, nil, "", fmt.Errorf("invalidate stale Connector status: %w", err)
	}
	logDir := filepath.Join(stateDir, "logs")
	if err := os.MkdirAll(logDir, 0o755); err != nil {
		return nil, nil, "", err
	}
	stdoutPath := connectorStdoutLogPath(stateDir, requestID)
	stderrPath := connectorStderrLogPath(stateDir, requestID)
	stdout, err := os.OpenFile(stdoutPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, nil, "", err
	}
	stderr, err := os.OpenFile(stderrPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		stdout.Close()
		return nil, nil, "", err
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = env
	cmd.Stdout = stdout
	cmd.Stderr = stderr
	if err := cmd.Start(); err != nil {
		stdout.Close()
		stderr.Close()
		return nil, nil, "", err
	}
	stdout.Close()
	stderr.Close()

	done := make(chan processExit, 1)
	go func() {
		err := cmd.Wait()
		exitCode := 0
		if err != nil {
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) {
				exitCode = exitErr.ExitCode()
			} else {
				exitCode = 1
			}
		}
		done <- processExit{exitCode: exitCode, err: err}
		close(done)
	}()
	return cmd, done, stderrPath, nil
}

func connectorStartFailed(err error, workerStatusPath, apiBaseURL, token, orgID, provisionerID, requestID string, timeout time.Duration, plan launchPlan) error {
	progress := progressPayload(map[string]any{
		"stage":   "connector_start_failed",
		"dry_run": false,
		"root":    plan.root,
		"launch":  redactLaunch(plan.argv),
	})
	if provisionerID != "" {
		_ = statusCallback(apiBaseURL, token, orgID, provisionerID, requestID, "failed", timeout, map[string]any{
			"failure_code":    "connector.start_failed",
			"failure_message": "salix-connect could not be started",
			"progress":        progress,
		})
	}
	_ = writeWorkerStatus(workerStatusPath, map[string]any{
		"status":               "connector_start_failed",
		"progress":             progress,
		"provisioner_id":       provisionerID,
		"provision_request_id": requestID,
		"error":                fmt.Sprintf("%T", err),
		"root":                 plan.root,
		"launch":               redactLaunch(plan.argv),
	})
	return provisionerError{code: "connector.start_failed", message: "salix-connect could not be started"}
}

func preflightFilesystemFailed(err error, workerStatusPath, apiBaseURL, token, orgID, provisionerID, requestID string, timeout time.Duration) error {
	progress := progressPayload(map[string]any{"stage": "preflight_failed"})
	_ = statusCallback(apiBaseURL, token, orgID, provisionerID, requestID, "failed", timeout, map[string]any{
		"failure_code":    "preflight.workdir_not_ready",
		"failure_message": "runner workdir or connector workdir is not writable",
		"progress":        progress,
	})
	_ = writeWorkerStatus(workerStatusPath, map[string]any{
		"status":               "preflight_failed",
		"progress":             progress,
		"provisioner_id":       provisionerID,
		"provision_request_id": requestID,
		"failure_code":         "preflight.workdir_not_ready",
		"error":                fmt.Sprintf("%T", err),
	})
	return provisionerError{code: "preflight.workdir_not_ready", message: "runner workdir or connector workdir is not writable"}
}

func cleanupPolicy(config map[string]any) map[string]any {
	policy := mapValue(config, "cleanup_policy")
	mode := firstNonEmpty(stringValue(policy["mode"]), "preserve")
	if mode != "preserve" && mode != "remove_on_stop" {
		mode = "preserve"
	}
	return map[string]any{"mode": mode}
}

func configuredCapacity(config map[string]any) int {
	capacity := intValue(config["capacity"], 1)
	if capacity < 1 {
		return 1
	}
	return capacity
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

func managedConnectorPayload(connector *managedConnector) map[string]any {
	payload := map[string]any{
		"provision_request_id": connector.requestID,
		"restart_count":        connector.restartCount,
		"attached":             connector.attached,
	}
	processRunning := connector.process != nil && connector.process.Process != nil
	if processRunning {
		payload["pid"] = connector.process.Process.Pid
	}
	if connector.lastExitCode != nil {
		payload["last_exit_code"] = *connector.lastExitCode
	}
	if processRunning && connector.connectorRunID != "" {
		payload["connector_run_id"] = connector.connectorRunID
	}
	return payload
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

func observeConnectors(stateDir, workerStatusPath, provisionerID string, reporter *statusReporter, connectors map[string]*managedConnector) error {
	for requestID, connector := range connectors {
		if connector.process == nil || connector.process.Process == nil {
			continue
		}
		connectorRunID, err := currentConnectorRunIDFromStatus(stateDir, requestID)
		if err != nil {
			return err
		}
		if connectorRunID == "" {
			continue
		}
		if connector.attached && connector.connectorRunID == connectorRunID {
			continue
		}

		connector.attached = true
		connector.connectorRunID = connectorRunID
		status := map[string]any{
			"status":               "connected",
			"progress":             progressPayload(map[string]any{"stage": "connected", "connector_run_id": connector.connectorRunID}),
			"provisioner_id":       provisionerID,
			"provision_request_id": requestID,
			"connector_run_id":     connector.connectorRunID,
			"managed_connectors":   managedConnectorsPayload(connectors),
		}
		if err := writeWorkerStatus(workerStatusPath, status); err != nil {
			return err
		}
		if reporter != nil && !reporter.verifyRequest(requestID) {
			fmt.Fprintln(os.Stderr, "Connector request verification queue is full; current local state remains authoritative")
		}
	}
	return nil
}

func currentConnectorRunIDFromStatus(stateDir, requestID string) (string, error) {
	path := connectorStatusPath(stateDir, requestID)
	for attempt := 0; attempt < 6; attempt++ {
		raw, err := os.ReadFile(path)
		if errors.Is(err, os.ErrNotExist) {
			return "", nil
		}
		if err != nil {
			return "", err
		}
		var status map[string]any
		if err := json.Unmarshal(raw, &status); err != nil {
			// Connector status files are written by an independently supervised
			// process. A runner observation can race a truncate/write cycle and see an
			// empty or partial JSON document; briefly retry, then treat it as "not
			// attached yet" instead of exiting the whole control loop.
			if attempt < 5 {
				time.Sleep(10 * time.Millisecond)
				continue
			}
			return "", nil
		}
		if stringValue(status["state"]) != "connected" {
			return "", nil
		}
		return stringValue(status["connector_run_id"]), nil
	}
	return "", nil
}

func managedConnectorsPayload(connectors map[string]*managedConnector) []map[string]any {
	payload := make([]map[string]any, 0, len(connectors))
	for _, connector := range connectors {
		payload = append(payload, managedConnectorPayload(connector))
	}
	return payload
}

func materializeManagedConnectors(opts runOptions, config map[string]any, stateDir, workerStatusPath, apiBaseURL, token, orgID, provisionerID string, connectors map[string]*managedConnector) error {
	paths, err := filepath.Glob(filepath.Join(connectorConfigDir(stateDir), "*.json"))
	if err != nil {
		return err
	}
	for _, configPath := range paths {
		requestID := strings.TrimSuffix(filepath.Base(configPath), ".json")
		if requestID == "" || strings.HasSuffix(requestID, ".status") {
			continue
		}
		if connectors[requestID] != nil {
			continue
		}
		plan, err := launchFromStoredConnectorConfig(config, stateDir, requestID)
		if err != nil {
			return connectorStartFailed(err, workerStatusPath, apiBaseURL, token, orgID, provisionerID, requestID, opts.timeout, launchPlan{argv: []string{filepath.Base(configPath)}, root: stateDir})
		}
		stderrLog := connectorStderrLogPath(stateDir, requestID)
		connectors[requestID] = &managedConnector{
			requestID:  requestID,
			argv:       plan.argv,
			env:        plan.env,
			configPath: plan.configPath,
			root:       plan.root,
			stderrLog:  stderrLog,
		}
	}
	return nil
}

// Modeled in tla/connector/ManagedConnectorSupervisor.tla.
func reapConnectors(stateDir, workerStatusPath, provisionerID string, statusReporter *statusReporter, connectors map[string]*managedConnector) error {
	if err := consumeConnectorExits(workerStatusPath, provisionerID, connectors); err != nil {
		return err
	}
	for requestID, connector := range connectors {
		if connector.done != nil {
			continue
		}
		if err := ensureConnectorRunning(stateDir, workerStatusPath, provisionerID, requestID, statusReporter, connector); err != nil {
			return err
		}
	}
	return nil
}

func consumeConnectorExits(workerStatusPath, provisionerID string, connectors map[string]*managedConnector) error {
	for requestID, connector := range connectors {
		if connector.done == nil {
			continue
		}
		select {
		case result, ok := <-connector.done:
			exitCode := -1
			if ok {
				exitCode = result.exitCode
			}
			connector.lastExitCode = &exitCode
			connector.process = nil
			connector.done = nil
			connector.attached = false
			progress := progressPayload(map[string]any{
				"stage":                     "connector_restart_pending",
				"restart_count":             connector.restartCount,
				"exit_code":                 exitCode,
				"previous_connector_run_id": connector.connectorRunID,
			})
			if err := writeWorkerStatus(workerStatusPath, map[string]any{
				"status":               "connector_restart_pending",
				"progress":             progress,
				"provisioner_id":       provisionerID,
				"provision_request_id": requestID,
				"managed_connectors":   managedConnectorsPayload(connectors),
			}); err != nil {
				return err
			}
		default:
		}
	}
	return nil
}

func ensureConnectorRunning(stateDir, workerStatusPath, provisionerID, requestID string, reporter *statusReporter, connector *managedConnector) error {
	restoring := connector.lastExitCode == nil && connector.restartCount == 0
	previousConnectorRunID := connector.connectorRunID
	connector.connectorRunID = ""
	stage := "restoring_connector"
	if !restoring {
		connector.restartCount++
		stage = "restarting_connector"
	}
	restartingProgress := progressPayload(map[string]any{
		"stage":                     stage,
		"dry_run":                   false,
		"restart_count":             connector.restartCount,
		"exit_code":                 connector.lastExitCode,
		"root":                      connector.root,
		"launch":                    redactLaunch(connector.argv),
		"previous_connector_run_id": previousConnectorRunID,
	})
	enqueueConnectorStatus(reporter, requestID, "starting_connector", map[string]any{
		"restart_count": connector.restartCount,
		"progress":      restartingProgress,
	})

	process, done, stderrLog, err := spawnConnector(stateDir, requestID, connector.argv, connector.env)
	if err != nil {
		progress := progressPayload(map[string]any{
			"stage":                     "connector_restart_pending",
			"restart_count":             connector.restartCount,
			"exit_code":                 connector.lastExitCode,
			"error_type":                fmt.Sprintf("%T", err),
			"root":                      connector.root,
			"launch":                    redactLaunch(connector.argv),
			"previous_connector_run_id": previousConnectorRunID,
		})
		if writeErr := writeWorkerStatus(workerStatusPath, map[string]any{
			"status":               "connector_restart_pending",
			"progress":             progress,
			"provisioner_id":       provisionerID,
			"provision_request_id": requestID,
			"managed_connectors":   managedConnectorsPayload(map[string]*managedConnector{requestID: connector}),
		}); writeErr != nil {
			return writeErr
		}
		fmt.Fprintf(os.Stderr, "Connector restart deferred: %v\n", err)
		return nil
	}

	connector.process = process
	connector.done = done
	connector.stderrLog = stderrLog
	connector.lastExitCode = nil

	progress := progressPayload(map[string]any{
		"stage":                     "waiting_for_attach",
		"dry_run":                   false,
		"pid":                       process.Process.Pid,
		"restart_count":             connector.restartCount,
		"root":                      connector.root,
		"launch":                    redactLaunch(connector.argv),
		"previous_connector_run_id": previousConnectorRunID,
	})
	if err := writeWorkerStatus(workerStatusPath, map[string]any{
		"status":                    "waiting_for_attach",
		"progress":                  progress,
		"dry_run":                   false,
		"pid":                       process.Process.Pid,
		"provisioner_id":            provisionerID,
		"provision_request_id":      requestID,
		"restart_count":             connector.restartCount,
		"root":                      connector.root,
		"launch":                    redactLaunch(connector.argv),
		"previous_connector_run_id": previousConnectorRunID,
	}); err != nil {
		return err
	}
	enqueueConnectorStatus(reporter, requestID, "waiting_for_attach", map[string]any{
		"restart_count": connector.restartCount,
		"progress":      progress,
	})
	return nil
}

func enqueueConnectorStatus(reporter *statusReporter, requestID, status string, payload map[string]any) {
	if reporter == nil || reporter.enqueue(requestID, status, payload) {
		return
	}
	fmt.Fprintln(os.Stderr, "Connector status report queue is full; current local state remains authoritative")
}

func stopManagedConnector(requestID string, connectors map[string]*managedConnector, config map[string]any, stateDir string) map[string]any {
	connector := connectors[requestID]
	if connector == nil {
		return map[string]any{
			"managed":            false,
			"credential_cleanup": cleanupConnectorCredential(stateDir, requestID),
		}
	}
	delete(connectors, requestID)

	exitCode := stopConnectorProcess(connector)

	return map[string]any{
		"managed":       true,
		"exit_code":     exitCode,
		"restart_count": connector.restartCount,
		"cleanup":       cleanupManagedConnector(connector, config, stateDir),
	}
}

func applyProvisionerUpdates(opts runOptions, config map[string]any, stateDir, workerStatusPath string, connectors map[string]*managedConnector, heartbeat map[string]any) (bool, map[string]any, error) {
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
	update := mapValue(updates, "salix-connect")
	if len(update) == 0 {
		return false, advisory, nil
	}
	updated, err := applySalixConnectUpdate(opts, config, stateDir, workerStatusPath, connectors, update)
	if err != nil || updated {
		return updated, nil, err
	}
	return false, advisory, nil
}

func agentVMMAdministratorUpdateAdvisory(config, update map[string]any) map[string]any {
	if stringValue(mapValue(config, "launchd")["domain"]) != "system" {
		return nil
	}
	targetRelease := strings.TrimSpace(stringValue(update["release_id"]))
	current, _ := componentBuildInfo(config, "agent-vmm")
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

func retainWorkerStatusAdvisory(workerStatusPath, key string, advisory map[string]any) error {
	if len(advisory) == 0 {
		return nil
	}
	status, err := loadJSON(workerStatusPath)
	if err != nil {
		return err
	}
	status[key] = advisory
	return writeWorkerStatus(workerStatusPath, status)
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
	current, _ := componentBuildInfo(config, component)
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
	if err == nil {
		if policyErr := checkHostMaintenancePolicy(lifecycle, ""); policyErr != nil {
			return false, nil, policyErr
		}
	}
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

func applySalixConnectUpdate(opts runOptions, config map[string]any, stateDir, workerStatusPath string, connectors map[string]*managedConnector, update map[string]any) (bool, error) {
	const component = "salix-connect"
	targetDigest := normalizedDigest(update["sha256"])
	targetURL := stringValue(update["artifact_url"])
	artifactURL := expandPlatformURL(targetURL)
	targetSize := positiveRevision(update["size"])
	if targetURL == "" {
		return false, nil
	}
	if err := verifyComponentTarget(config, component, update, targetURL); err != nil {
		return false, err
	}

	current, _ := componentBuildInfo(config, component)
	fromVersion := firstNonEmpty(stringValue(current["version"]), stringValue(current["release_id"]))
	if targetDigest != "" && normalizedDigest(current["artifact_digest"]) == targetDigest {
		return false, nil
	}

	result, err := updateSalixConnectBinary(opts, config, stateDir, artifactURL, targetDigest, targetSize, connectors)
	if err != nil {
		failureCode := provisionerFailureCode(err, component+".update_failed")
		payload := map[string]any{
			"status": strings.ReplaceAll(component, "-", "_") + "_update_failed",
			"progress": progressPayload(map[string]any{
				"stage":         strings.ReplaceAll(component, "-", "_") + "_update_failed",
				"from_version":  fromVersion,
				"target_digest": targetDigest,
				"artifact_url":  artifactURL,
				"failure":       err.Error(),
			}),
			"failure_code":       failureCode,
			"failure_message":    err.Error(),
			"managed_connectors": managedConnectorsPayload(connectors),
		}
		_ = writeWorkerStatus(workerStatusPath, payload)
		fmt.Printf("%s update failed: %v\n", component, err)
		return true, nil
	}

	payload := map[string]any{
		"status":               strings.ReplaceAll(component, "-", "_") + "_update",
		"progress":             progressPayload(result),
		"salix_connect_update": result,
		"managed_connectors":   managedConnectorsPayload(connectors),
	}
	if err := writeWorkerStatus(workerStatusPath, payload); err != nil {
		return true, err
	}
	capabilities := copyStringAnyMap(mapValue(config, "capabilities"))
	digests := copyStringAnyMap(mapValue(capabilities, "component_digests"))
	digestComponent := component
	if component == "agent-vmm" {
		digestComponent = "agent-vmm-host"
	}
	digests[digestComponent] = targetDigest
	capabilities["component_digests"] = digests
	config["capabilities"] = capabilities
	if err := writeJSON(expandUser(opts.configPath), config, 0o600); err != nil {
		return true, provisionerError{code: component + ".digest_state_persist_failed", message: component + " installed artifact digest could not be persisted"}
	}
	fmt.Printf("%s updated from %s to digest %s\n", component, fromVersion, targetDigest)
	return true, nil
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

func componentBuildInfo(config map[string]any, component string) (map[string]any, bool) {
	if component == "salix-connect" {
		return salixConnectBuildInfo(config)
	}
	info, err := agentVMMBuildInfo(config, salixConnectVersionTimeout)
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

func agentVMMInstallDescriptorPath(stateDir, operationID string) string {
	return filepath.Join(stateDir, "install-operations", operationID, "descriptor.json")
}

func agentVMMInstallFailurePath(stateDir, operationID string) string {
	return filepath.Join(stateDir, "install-operations", operationID, "terminal-failure.json")
}

func agentVMMInstallFailureReports(stateDir string) ([]any, error) {
	root := filepath.Join(stateDir, "install-operations")
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	reports := make([]any, 0)
	for _, entry := range entries {
		if !entry.IsDir() || !validAgentVMMOperationID(entry.Name()) {
			continue
		}
		report, readErr := loadJSON(agentVMMInstallFailurePath(stateDir, entry.Name()))
		if errors.Is(readErr, os.ErrNotExist) {
			continue
		}
		if readErr != nil || stringValue(report["operation_id"]) != entry.Name() || stringValue(report["failure_code"]) == "" {
			return nil, provisionerError{code: "agent_vmm.install_failure_report_unreadable", message: "pending Agent VMM install failure report is unreadable"}
		}
		reports = append(reports, report)
		if len(reports) == 8 {
			break
		}
	}
	return reports, nil
}

func acknowledgeAgentVMMInstallFailures(config map[string]any, stateDir string, heartbeat map[string]any) error {
	acks, ok := heartbeat["agent_vmm_install_failure_acks"].([]any)
	if !ok {
		return nil
	}
	for _, value := range acks {
		operationID := stringValue(value)
		if !validAgentVMMOperationID(operationID) {
			return provisionerError{code: "agent_vmm.install_failure_ack_invalid", message: "Agent VMM install failure acknowledgement is invalid"}
		}
		helper, err := requirePath(config, "host_runtime_lifecycle")
		if err != nil {
			return err
		}
		serviceArgs, err := hostRuntimeServiceArguments(config)
		if err != nil {
			return err
		}
		args := append([]string{"install-operation-ack", "--operation-id", operationID}, serviceArgs...)
		if err := runHostRuntimeOperation(helper, args); err != nil {
			return provisionerError{code: "agent_vmm.install_failure_ack_cleanup_failed", message: "Agent VMM install plan could not be removed after Server acknowledgement"}
		}
		if err := os.Remove(agentVMMInstallFailurePath(stateDir, operationID)); err != nil && !errors.Is(err, os.ErrNotExist) {
			return provisionerError{code: "agent_vmm.install_failure_ack_cleanup_failed", message: "Agent VMM install failure acknowledgement could not be persisted"}
		}
	}
	return nil
}

func validAgentVMMOperationID(value string) bool {
	if len(value) == 0 || len(value) > 128 {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') && (char < 'A' || char > 'Z') &&
			(char < '0' || char > '9') && char != '_' && char != '-' {
			return false
		}
	}
	return true
}

func nextAgentVMMInstallDescriptor(stateDir string) (map[string]any, string, error) {
	root := filepath.Join(stateDir, "install-operations")
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, "", os.ErrNotExist
	}
	if err != nil {
		return nil, "", err
	}
	for _, entry := range entries {
		if !entry.IsDir() || !validAgentVMMOperationID(entry.Name()) {
			continue
		}
		path := agentVMMInstallDescriptorPath(stateDir, entry.Name())
		descriptor, readErr := loadJSON(path)
		if errors.Is(readErr, os.ErrNotExist) {
			continue
		}
		return descriptor, path, readErr
	}
	return nil, "", os.ErrNotExist
}

func validateAgentVMMInstallDescriptor(descriptor map[string]any) (string, bool, bool, error) {
	operationID := strings.TrimSpace(stringValue(descriptor["operation_id"]))
	resumeOnly := boolValue(descriptor["resume_operation"])
	if positiveRevision(descriptor["version"]) != 1 || !validAgentVMMOperationID(operationID) ||
		(!resumeOnly && (stringValue(descriptor["exchange_url"]) == "" || stringValue(descriptor["one_time_secret"]) == "" || stringValue(descriptor["expires_at"]) == "")) {
		return "", false, false, provisionerError{code: "agent_vmm.install_descriptor_invalid", message: "agent-vmm install descriptor is incomplete"}
	}
	if resumeOnly {
		return operationID, true, true, nil
	}
	expiresAt, err := time.Parse(time.RFC3339, stringValue(descriptor["expires_at"]))
	if err != nil {
		return "", false, false, provisionerError{code: "agent_vmm.install_descriptor_invalid", message: "agent-vmm install descriptor expiry is invalid"}
	}
	return operationID, false, !time.Now().Before(expiresAt), nil
}

func persistAgentVMMInstallDescriptor(stateDir string, heartbeat map[string]any) error {
	descriptor := mapValue(heartbeat, "agent_vmm_install")
	if len(descriptor) == 0 {
		return nil
	}
	operationID, _, _, err := validateAgentVMMInstallDescriptor(descriptor)
	if err != nil {
		return err
	}
	if err := writeJSON(agentVMMInstallDescriptorPath(stateDir, operationID), descriptor, 0o600); err != nil {
		return provisionerError{code: "agent_vmm.install_descriptor_persist_failed", message: "agent-vmm install descriptor could not be persisted"}
	}
	return nil
}

// Descriptor retention/retry is modeled in tla/salix/VMMInstallHandoff.tla.
// The runner owns delivery persistence;
// the helper owns the fixed material plan after exchange.
func applyAgentVMMInstallDescriptor(opts runOptions, config map[string]any, stateDir, workerStatusPath string, heartbeat map[string]any) error {
	if !opts.start {
		return nil
	}
	descriptor := mapValue(heartbeat, "agent_vmm_install")
	fromPending := false
	pendingPath := ""
	if len(descriptor) == 0 {
		pending, path, err := nextAgentVMMInstallDescriptor(stateDir)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return provisionerError{code: "agent_vmm.install_descriptor_unreadable", message: "pending agent-vmm install descriptor is unreadable"}
		}
		descriptor = pending
		pendingPath = path
		fromPending = true
	}
	operationID, resumeOnly, expired, validationErr := validateAgentVMMInstallDescriptor(descriptor)
	if validationErr != nil {
		if fromPending {
			_ = os.Remove(pendingPath)
		}
		return validationErr
	}
	if pendingPath == "" {
		pendingPath = agentVMMInstallDescriptorPath(stateDir, operationID)
	}
	if expired && !resumeOnly {
		// Drop the expired bearer but retain a bounded, non-secret trigger for
		// the helper's same-operation durable-plan resume path.
		if err := writeJSON(pendingPath, map[string]any{
			"version":          1,
			"operation_id":     operationID,
			"resume_operation": true,
		}, 0o600); err != nil {
			return provisionerError{code: "agent_vmm.install_descriptor_cleanup_failed", message: "expired agent-vmm install descriptor could not be replaced with a safe resume trigger"}
		}
	} else if len(mapValue(heartbeat, "agent_vmm_install")) != 0 {
		if err := writeJSON(pendingPath, descriptor, 0o600); err != nil {
			return provisionerError{code: "agent_vmm.install_descriptor_persist_failed", message: "agent-vmm install descriptor could not be persisted"}
		}
	}
	path, err := requirePath(config, "host_runtime_lifecycle")
	if err != nil {
		return err
	}
	serviceArgs, err := hostRuntimeServiceArguments(config)
	if err != nil {
		return err
	}
	args := []string{"install", "--disable-personal-mesh-pairing", "--request-id", operationID}
	if policyErr := checkHostMaintenancePolicy(path, operationID); policyErr != nil {
		if provisionerFailureCode(policyErr, "") != "agent_vmm.local_disposed" {
			return policyErr
		}
		if err := writeJSON(agentVMMInstallFailurePath(stateDir, operationID), map[string]any{"operation_id": operationID, "failure_code": "agent_vmm.local_disposed"}, 0o600); err != nil {
			return err
		}
		if err := os.Remove(pendingPath); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	var encoded []byte
	if expired {
		args = append(args, "--resume-operation", operationID)
	} else {
		args = append(args, "--operation-stdin")
		encoded, err = json.Marshal(descriptor)
		if err != nil {
			return provisionerError{code: "agent_vmm.install_descriptor_invalid", message: "agent-vmm install descriptor could not be encoded"}
		}
	}
	args = append(args, serviceArgs...)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	command := exec.CommandContext(ctx, path, args...)
	if !expired {
		command.Stdin = bytes.NewReader(encoded)
	}
	output, err := command.Output()
	for index := range encoded {
		encoded[index] = 0
	}
	var operation map[string]any
	resultReadable := json.Unmarshal(output, &operation) == nil && stringValue(operation["operationId"]) == operationID
	if err != nil {
		retryable := resultReadable && boolValue(operation["retryable"])
		secretDisposition := stringValue(operation["secretDisposition"])
		failureStage := firstNonEmpty(stringValue(operation["failureStage"]), "install-managed")
		failureCode := firstNonEmpty(stringValue(operation["failureCode"]), "helper_failed")
		failureMessage := firstNonEmpty(stringValue(operation["failureMessage"]), "Agent VMM lifecycle helper failed without a structured result.")
		attempt := positiveRevision(operation["attempt"])
		if expired && !resultReadable {
			failureStage = "authorization-expired"
			failureCode = "install_descriptor_expired"
			failureMessage = "Agent VMM managed installation authorization expired and no durable local plan could be resumed."
		}
		if secretDisposition == "destroy_terminal" {
			report := map[string]any{
				"operation_id": operationID,
				"failure_code": "agent_vmm." + failureCode,
			}
			if err := writeJSON(agentVMMInstallFailurePath(stateDir, operationID), report, 0o600); err != nil {
				return provisionerError{code: "agent_vmm.install_failure_report_persist_failed", message: "terminal Agent VMM install failure could not be persisted for the control plane"}
			}
			_ = os.Remove(pendingPath)
			_ = writeWorkerStatus(workerStatusPath, map[string]any{"status": "agent_vmm_install_action_required", "failure_code": "agent_vmm." + failureCode, "failure_message": failureMessage, "progress": progressPayload(map[string]any{"stage": failureStage, "operation_id": operationID, "attempt": attempt})})
			return provisionerError{code: "agent_vmm.install_action_required", message: "Agent VMM managed installation requires operator action at stage " + failureStage + ": " + failureMessage}
		}
		if !retryable {
			_ = writeWorkerStatus(workerStatusPath, map[string]any{"status": "agent_vmm_install_local_failure", "failure_code": "agent_vmm." + failureCode, "failure_message": failureMessage, "progress": progressPayload(map[string]any{"stage": failureStage, "operation_id": operationID, "attempt": attempt})})
			return provisionerError{code: "agent_vmm.install_local_failure", message: "Agent VMM managed installation stopped with retained local recovery material at stage " + failureStage + ": " + failureMessage}
		}
		_ = writeWorkerStatus(workerStatusPath, map[string]any{"status": "agent_vmm_install_retrying", "failure_code": "agent_vmm." + failureCode, "failure_message": failureMessage, "progress": progressPayload(map[string]any{"stage": failureStage, "operation_id": operationID, "attempt": attempt})})
		return provisionerError{code: "agent_vmm.install_retryable", message: "Agent VMM managed installation encountered a retryable failure at stage " + failureStage + ": " + failureMessage}
	}
	if !resultReadable || stringValue(operation["outcome"]) != "succeeded" || stringValue(operation["secretDisposition"]) != "destroy_completed" {
		return provisionerError{code: "agent_vmm.install_result_invalid", message: "Agent VMM managed installation returned an invalid result"}
	}
	if err := os.Remove(pendingPath); err != nil && !errors.Is(err, os.ErrNotExist) {
		return provisionerError{code: "agent_vmm.install_descriptor_cleanup_failed", message: "applied agent-vmm install descriptor could not be removed"}
	}
	return writeWorkerStatus(workerStatusPath, map[string]any{"status": "agent_vmm_install_applied", "progress": progressPayload(map[string]any{"stage": "agent_vmm_install_applied", "operation_id": operationID})})
}

func applyAgentVMMControls(opts runOptions, config map[string]any, stateDir, workerStatusPath string, heartbeat map[string]any) error {
	if !opts.start {
		return nil
	}
	page := mapValue(heartbeat, "agent_vmm_controls")
	if len(page) == 0 {
		return nil
	}
	if positiveRevision(page["version"]) != 1 {
		return provisionerError{code: "agent_vmm.control_page_invalid", message: "agent-vmm control page version is invalid"}
	}
	items, ok := page["items"].([]any)
	if !ok || len(items) > 32 {
		return provisionerError{code: "agent_vmm.control_page_invalid", message: "agent-vmm control page items are invalid"}
	}
	nextCursor := strings.TrimSpace(stringValue(page["next_cursor"]))
	if len(nextCursor) > 200 {
		return provisionerError{code: "agent_vmm.control_page_invalid", message: "agent-vmm control cursor is invalid"}
	}
	if len(items) == 0 {
		if nextCursor == "" {
			delete(config, "_agent_vmm_control_cursor")
		} else {
			config["_agent_vmm_control_cursor"] = nextCursor
		}
		return nil
	}
	path, err := requirePath(config, "host_runtime_lifecycle")
	if err != nil {
		return err
	}
	serviceArgs, err := hostRuntimeServiceArguments(config)
	if err != nil {
		return err
	}
	for _, raw := range items {
		control := mapFromValue(raw)
		operationID := strings.TrimSpace(stringValue(control["operation_id"]))
		registrationID := strings.TrimSpace(stringValue(control["registration_id"]))
		state := stringValue(control["state"])
		registrationRevision := positiveRevision(control["registration_revision"])
		if !validAgentVMMOperationID(operationID) || registrationID == "" || len(registrationID) > 200 || registrationRevision == 0 || (state != "enabled" && state != "draining") {
			return provisionerError{code: "agent_vmm.control_invalid", message: "agent-vmm registration control is incomplete"}
		}
		// A durable terminal report is sent through the existing delivery-failure owner.
		// Skip only this exact operation while its acknowledgement is pending.
		report, readErr := loadJSON(agentVMMInstallFailurePath(stateDir, operationID))
		if readErr == nil && stringValue(report["operation_id"]) == operationID && stringValue(report["failure_code"]) == "agent_vmm.local_disposed" {
			continue
		}
		if readErr != nil && !errors.Is(readErr, os.ErrNotExist) {
			return readErr
		}
		requestID := fmt.Sprintf("%s-r%d", operationID, registrationRevision)
		if policyErr := checkHostMaintenancePolicy(path, operationID); policyErr != nil {
			if provisionerFailureCode(policyErr, "") == "agent_vmm.local_disposed" {
				continue
			}
			return policyErr
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
		args := append([]string{"registration-state", "--registration-id", registrationID, "--state", state, "--request-id", requestID}, serviceArgs...)
		command := exec.CommandContext(ctx, path, args...)
		output, commandErr := command.Output()
		cancel()
		if commandErr != nil {
			var result map[string]any
			if json.Unmarshal(output, &result) == nil && stringValue(result["requestId"]) == requestID && stringValue(result["failureCode"]) == "local_disposed" && !boolValue(result["retryable"]) {
				if err := writeJSON(agentVMMInstallFailurePath(stateDir, operationID), map[string]any{"operation_id": operationID, "failure_code": "agent_vmm.local_disposed"}, 0o600); err != nil {
					return err
				}
				continue
			}
			_ = writeWorkerStatus(workerStatusPath, map[string]any{"status": "agent_vmm_control_failed", "failure_code": "agent_vmm.control_failed", "failure_message": "Agent VMM registration control did not complete.", "progress": progressPayload(map[string]any{"stage": "agent_vmm_control_failed", "operation_id": operationID, "registration_id": registrationID})})
			return provisionerError{code: "agent_vmm.control_failed", message: "Agent VMM registration control did not complete"}
		}
		var result map[string]any
		if json.Unmarshal(output, &result) != nil || stringValue(result["outcome"]) != "succeeded" {
			return provisionerError{code: "agent_vmm.control_result_invalid", message: "Agent VMM registration control returned an invalid result"}
		}
	}
	if nextCursor == "" {
		delete(config, "_agent_vmm_control_cursor")
	} else {
		config["_agent_vmm_control_cursor"] = nextCursor
	}
	return writeWorkerStatus(workerStatusPath, map[string]any{"status": "agent_vmm_control_applied", "progress": progressPayload(map[string]any{"stage": "agent_vmm_control_applied", "count": len(items)})})
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

func updateSalixConnectBinary(opts runOptions, config map[string]any, stateDir, artifactURL, expectedSHA string, expectedSize uint64, connectors map[string]*managedConnector) (map[string]any, error) {
	targetPath, err := requirePath(config, "salix_connect")
	if err != nil {
		return nil, err
	}
	before, verified := salixConnectBuildInfo(config)
	if !verified {
		return nil, provisionerError{code: "salix_connect.version_unknown", message: "installed salix-connect version could not be verified"}
	}
	fromVersion := firstNonEmpty(stringValue(before["version"]), stringValue(before["release_id"]))

	if expectedSHA == "" {
		return nil, provisionerError{code: "salix_connect.sha_missing", message: "salix-connect artifact sha256 is required"}
	}

	stagingDir := filepath.Join(stateDir, "updates", "salix-connect")
	// Update artifacts are disposable; interrupted attempts must not accumulate
	// across runner cycles.
	if err := resetUpdateStagingDir(stagingDir); err != nil {
		return nil, err
	}
	stagedPath := filepath.Join(stagingDir, "salix-connect."+expectedSHA)
	defer func() { _ = os.Remove(stagedPath) }()
	actualSHA, err := downloadArtifact(artifactURL, opts.timeout, expectedSize, expectedSHA, stagedPath, 0o755)
	if err != nil {
		if errors.Is(err, errArtifactSizeMismatch) {
			return nil, provisionerError{code: "salix_connect.size_mismatch", message: err.Error()}
		}
		if errors.Is(err, errArtifactDigestMismatch) {
			return nil, provisionerError{code: "salix_connect.sha_mismatch", message: "salix-connect artifact sha256 mismatch"}
		}
		return nil, provisionerError{code: "salix_connect.download_failed", message: err.Error()}
	}
	if err := os.Chmod(stagedPath, 0o755); err != nil {
		return nil, err
	}

	stopped := stopConnectorsForUpdate(connectors)
	backupPath := targetPath + ".previous"
	_ = os.Remove(backupPath)
	if err := os.Rename(targetPath, backupPath); err != nil {
		_, _ = restartConnectorsAfterUpdate(stateDir, connectors)
		return nil, err
	}
	replaced := false
	if err := os.Rename(stagedPath, targetPath); err != nil {
		_ = os.Rename(backupPath, targetPath)
		_, _ = restartConnectorsAfterUpdate(stateDir, connectors)
		return nil, err
	}
	replaced = true
	if err := os.Chmod(targetPath, 0o755); err != nil {
		_ = restoreComponent(targetPath, backupPath, replaced)
		_, _ = restartConnectorsAfterUpdate(stateDir, connectors)
		return nil, err
	}

	after, verified := salixConnectBuildInfo(config)
	if !verified {
		_ = restoreComponent(targetPath, backupPath, replaced)
		_, _ = restartConnectorsAfterUpdate(stateDir, connectors)
		return nil, provisionerError{code: "salix_connect.version_unknown", message: "updated salix-connect version could not be verified"}
	}
	toVersion := firstNonEmpty(stringValue(after["version"]), stringValue(after["release_id"]))
	restarted, err := restartConnectorsAfterUpdate(stateDir, connectors)
	if err != nil {
		if rollbackErr := rollbackSalixConnectUpdate(targetPath, backupPath, replaced, stateDir, connectors); rollbackErr != nil {
			return nil, provisionerError{
				code:    "salix_connect.restart_rollback_failed",
				message: fmt.Sprintf("restart failed after salix-connect update: %v; rollback failed: %v", err, rollbackErr),
			}
		}
		return nil, provisionerError{code: "salix_connect.restart_failed", message: err.Error()}
	}

	return map[string]any{
		"stage":              "salix_connect_update_applied",
		"status":             "applied",
		"from_version":       fromVersion,
		"to_version":         toVersion,
		"artifact_url":       artifactURL,
		"sha256":             actualSHA,
		"stopped_connectors": stopped,
		"restarted":          restarted,
		"path":               targetPath,
	}, nil
}

func restoreComponent(targetPath, backupPath string, replaced bool) error {
	if !replaced {
		return nil
	}
	if err := os.RemoveAll(targetPath); err != nil {
		return err
	}
	if err := os.Rename(backupPath, targetPath); err != nil {
		return err
	}
	return nil
}

func rollbackSalixConnectUpdate(targetPath, backupPath string, replaced bool, stateDir string, connectors map[string]*managedConnector) error {
	stopConnectorsForUpdate(connectors)
	if err := restoreComponent(targetPath, backupPath, replaced); err != nil {
		return err
	}
	_, err := restartConnectorsAfterUpdate(stateDir, connectors)
	return err
}

func resetUpdateStagingDir(stagingDir string) error {
	if err := os.RemoveAll(stagingDir); err != nil {
		return err
	}
	return os.MkdirAll(stagingDir, 0o755)
}

func stopConnectorsForUpdate(connectors map[string]*managedConnector) []map[string]any {
	stopped := []map[string]any{}
	for requestID, connector := range connectors {
		exitCode := stopConnectorProcess(connector)
		stopped = append(stopped, map[string]any{
			"provision_request_id": requestID,
			"exit_code":            exitCode,
			"attached":             connector.attached,
			"connector_run_id":     connector.connectorRunID,
		})
	}
	return stopped
}

func restartConnectorsAfterUpdate(stateDir string, connectors map[string]*managedConnector) ([]map[string]any, error) {
	restarted := []map[string]any{}
	for requestID, connector := range connectors {
		process, done, stderrLog, err := spawnConnector(stateDir, requestID, connector.argv, connector.env)
		if err != nil {
			return restarted, err
		}
		connector.restartCount++
		connector.process = process
		connector.done = done
		connector.stderrLog = stderrLog
		connector.lastExitCode = nil
		connector.attached = false
		restarted = append(restarted, map[string]any{
			"provision_request_id": requestID,
			"pid":                  process.Process.Pid,
			"restart_count":        connector.restartCount,
		})
	}
	return restarted, nil
}

func expandPlatformURL(raw string) string {
	return strings.ReplaceAll(raw, "__BFT_PLATFORM__", runtime.GOOS+"-"+runtime.GOARCH)
}

var errArtifactSizeMismatch = errors.New("artifact size mismatch")
var errArtifactDigestMismatch = errors.New("artifact digest mismatch")

func downloadArtifact(rawURL string, timeout time.Duration, expectedSize uint64, expectedSHA, targetPath string, mode os.FileMode) (string, error) {
	if expectedSize == 0 || expectedSize > math.MaxInt64-1 {
		return "", fmt.Errorf("%w: invalid expected size %d", errArtifactSizeMismatch, expectedSize)
	}
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("user-agent", "bridge-for-teams-bft-runner/"+version)
	// Large immutable bundles are downloaded over the runner's slowest link;
	// keep the short control-plane timeout for small requests, but do not abort
	// a valid bundle halfway through artifact transport.
	if expectedSize >= 64<<20 && timeout < largeArtifactDownloadTimeout {
		timeout = largeArtifactDownloadTimeout
	}
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", provisionerError{code: "network.http_" + strconv.Itoa(resp.StatusCode), message: "download returned HTTP " + strconv.Itoa(resp.StatusCode)}
	}
	if resp.ContentLength >= 0 && uint64(resp.ContentLength) != expectedSize {
		return "", fmt.Errorf("%w: expected %d bytes, response declared %d", errArtifactSizeMismatch, expectedSize, resp.ContentLength)
	}

	temporaryPath := targetPath + ".download"
	_ = os.Remove(temporaryPath)
	file, err := os.OpenFile(temporaryPath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return "", err
	}
	keep := false
	defer func() {
		_ = file.Close()
		if !keep {
			_ = os.Remove(temporaryPath)
		}
	}()

	hash := sha256.New()
	written, copyErr := io.Copy(io.MultiWriter(file, hash), io.LimitReader(resp.Body, int64(expectedSize)+1))
	if copyErr != nil {
		return "", copyErr
	}
	if uint64(written) != expectedSize {
		return "", fmt.Errorf("%w: expected %d bytes, received %d", errArtifactSizeMismatch, expectedSize, written)
	}
	actualSHA := hex.EncodeToString(hash.Sum(nil))
	if expectedSHA == "" || !strings.EqualFold(actualSHA, expectedSHA) {
		return "", errArtifactDigestMismatch
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	if err := os.Chmod(temporaryPath, mode); err != nil {
		return "", err
	}
	if err := os.Rename(temporaryPath, targetPath); err != nil {
		return "", err
	}
	keep = true
	return actualSHA, nil
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

func connectorExitCode(connector *managedConnector) *int {
	if connector.lastExitCode != nil {
		return connector.lastExitCode
	}
	select {
	case result := <-connector.done:
		connector.lastExitCode = &result.exitCode
		return &result.exitCode
	default:
		return nil
	}
}

func waitForConnectorExit(done <-chan processExit, timeout time.Duration) *int {
	select {
	case result := <-done:
		return &result.exitCode
	case <-time.After(timeout):
		return nil
	}
}

func processAlive(process *os.Process) bool {
	if process == nil {
		return false
	}
	return process.Signal(syscall.Signal(0)) == nil
}

func pollConnectorProcessExit(connector *managedConnector) *int {
	select {
	case result := <-connector.done:
		exitCode := result.exitCode
		connector.lastExitCode = &exitCode
		return &exitCode
	default:
		return nil
	}
}

func stopConnectorProcess(connector *managedConnector) *int {
	if connector == nil {
		return nil
	}
	if connector.process == nil || connector.process.Process == nil {
		return connectorExitCode(connector)
	}
	if exitCode := pollConnectorProcessExit(connector); exitCode != nil {
		return exitCode
	}

	process := connector.process.Process
	_ = process.Signal(syscall.SIGTERM)
	exitCode := waitForConnectorExit(connector.done, 5*time.Second)
	if exitCode == nil || processAlive(process) {
		_ = process.Kill()
		if killedExitCode := waitForConnectorExit(connector.done, 5*time.Second); killedExitCode != nil {
			exitCode = killedExitCode
		}
	}
	if exitCode == nil {
		fallback := -1
		exitCode = &fallback
	}
	connector.lastExitCode = exitCode
	return exitCode
}

func cleanupManagedConnector(connector *managedConnector, config map[string]any, stateDir string) map[string]any {
	policy := cleanupPolicy(config)
	mode := stringValue(policy["mode"])
	result := map[string]any{"mode": mode, "removed": []string{}}
	result["credential_cleanup"] = cleanupConnectorCredential(stateDir, connector.requestID)
	if mode != "remove_on_stop" {
		return result
	}
	removed := []string{}
	if _, err := os.Stat(connector.root); err == nil {
		if err := os.RemoveAll(connector.root); err == nil {
			removed = append(removed, "root")
		} else {
			result["error"] = fmt.Sprintf("%T", err)
		}
	}
	result["removed"] = removed
	return result
}

func cleanupConnectorCredential(stateDir, requestID string) map[string]any {
	result := map[string]any{"config_removed": false, "status_removed": false}
	if err := os.Remove(connectorConfigPath(stateDir, requestID)); err == nil {
		result["config_removed"] = true
	}
	if err := os.Remove(connectorStatusPath(stateDir, requestID)); err == nil {
		result["status_removed"] = true
	}
	return result
}

func startManagedConnector(opts runOptions, stateDir, workerStatusPath, apiBaseURL, token, orgID, provisionerID, requestID string, connectors map[string]*managedConnector, plan launchPlan, stage string) error {
	launchProgress := progressPayload(map[string]any{
		"stage":   stage,
		"dry_run": false,
		"root":    plan.root,
		"launch":  redactLaunch(plan.argv),
	})
	if err := statusCallback(apiBaseURL, token, orgID, provisionerID, requestID, "starting_connector", opts.timeout, map[string]any{"progress": launchProgress}); err != nil {
		return err
	}
	if err := writeJSON(plan.configPath, plan.config, 0o600); err != nil {
		return preflightFilesystemFailed(err, workerStatusPath, apiBaseURL, token, orgID, provisionerID, requestID, opts.timeout)
	}

	process, done, stderrLog, err := spawnConnector(stateDir, requestID, plan.argv, plan.env)
	if err != nil {
		return connectorStartFailed(err, workerStatusPath, apiBaseURL, token, orgID, provisionerID, requestID, opts.timeout, plan)
	}
	connectors[requestID] = &managedConnector{
		requestID:  requestID,
		argv:       plan.argv,
		env:        plan.env,
		configPath: plan.configPath,
		root:       plan.root,
		process:    process,
		done:       done,
		stderrLog:  stderrLog,
	}

	attachProgress := progressPayload(map[string]any{
		"stage":   "waiting_for_attach",
		"dry_run": false,
		"pid":     process.Process.Pid,
		"root":    plan.root,
		"launch":  redactLaunch(plan.argv),
	})
	if err := statusCallback(apiBaseURL, token, orgID, provisionerID, requestID, "waiting_for_attach", opts.timeout, map[string]any{"progress": attachProgress}); err != nil {
		return err
	}
	if err := writeWorkerStatus(workerStatusPath, map[string]any{
		"status":               "waiting_for_attach",
		"progress":             attachProgress,
		"dry_run":              false,
		"pid":                  process.Process.Pid,
		"provisioner_id":       provisionerID,
		"provision_request_id": requestID,
		"root":                 plan.root,
		"launch":               redactLaunch(plan.argv),
	}); err != nil {
		return err
	}
	return nil
}

func claimOnce(opts runOptions, config map[string]any, stateDir, workerStatusPath, apiBaseURL, token, orgID, provisionerID string, statusReporter *statusReporter, connectors map[string]*managedConnector) error {
	claimStatus, claimPayload, err := postJSON(apiBaseURL, token, fmt.Sprintf("/v1/orgs/%s/runners/%s/claim", orgID, provisionerID), map[string]any{
		"available_capacity": max(configuredCapacity(config)-len(connectors), 0),
	}, opts.timeout)
	if err != nil {
		return err
	}
	if claimStatus == http.StatusNoContent {
		if err := consumeConnectorExits(workerStatusPath, provisionerID, connectors); err != nil {
			return err
		}
		// Re-read attachment state after the claim round-trip too. The first
		// observation in this iteration can race a connector status truncate/write,
		// while by the time we project idle status the replacement may already have
		// published its connected run id.
		if err := observeConnectors(stateDir, workerStatusPath, provisionerID, statusReporter, connectors); err != nil {
			return err
		}
		status, connector := managedConnectorProjection(connectors)
		payload := map[string]any{"status": status, "provisioner_id": provisionerID}
		if connector != nil {
			payload["managed_connectors"] = managedConnectorsPayload(connectors)
			if status == "connected" {
				payload["progress"] = progressPayload(map[string]any{"stage": "connected", "connector_run_id": connector.connectorRunID})
				payload["connector_run_id"] = connector.connectorRunID
			} else {
				progress := map[string]any{
					"stage":         status,
					"dry_run":       false,
					"restart_count": connector.restartCount,
					"exit_code":     connector.lastExitCode,
					"root":          connector.root,
					"launch":        redactLaunch(connector.argv),
				}
				if connector.process != nil && connector.process.Process != nil {
					progress["pid"] = connector.process.Process.Pid
				}
				payload["progress"] = progressPayload(progress)
			}
		}
		if err := writeWorkerStatus(workerStatusPath, payload); err != nil {
			return err
		}
		fmt.Printf("Status: %s\n", status)
		switch status {
		case "idle":
			fmt.Println("No pending requests.")
		case "connected":
			fmt.Println("No pending requests; managed connector is attached.")
		case "connector_restart_pending":
			fmt.Println("No pending requests; managed connector restart is pending.")
		default:
			fmt.Println("No pending requests; managed connector is still running.")
		}
		return nil
	}

	claim, err := expectSuccess(claimStatus, claimPayload, "claim", nil)
	if err != nil {
		return err
	}
	action := firstNonEmpty(stringValue(claim["action"]), "create")
	request := mapValue(claim, "device_request")
	connect := mapValue(claim, "connect")
	launch := mapValue(claim, "launch")
	requestID := stringValue(request["id"])
	if requestID == "" {
		return provisionerError{code: "claim.request_id_missing", message: "claim response missing request id"}
	}

	if action == "stop" {
		stopped := stopManagedConnector(requestID, connectors, config, stateDir)
		cleanup, _ := stopped["cleanup"].(map[string]any)
		stopSummary := map[string]any{}
		for key, value := range stopped {
			if key != "cleanup" {
				stopSummary[key] = value
			}
		}
		progress := progressPayload(map[string]any{"stage": "stopped", "stop": stopSummary, "cleanup": cleanup})
		if err := statusCallback(apiBaseURL, token, orgID, provisionerID, requestID, "stopped", opts.timeout, map[string]any{
			"failure_code":    nil,
			"failure_message": nil,
			"progress":        progress,
		}); err != nil {
			return err
		}
		if err := writeWorkerStatus(workerStatusPath, map[string]any{
			"status":               "stopped",
			"progress":             progress,
			"provisioner_id":       provisionerID,
			"provision_request_id": requestID,
			"stop":                 stopped,
		}); err != nil {
			return err
		}
		fmt.Printf("device request %s: stopped\n", requestID)
		return nil
	}

	if action != "create" {
		return provisionerError{code: "claim.unsupported_action", message: "unsupported claim action: " + action}
	}

	plan, err := buildLaunch(config, connect, launch, stateDir, requestID)
	if err != nil {
		var pe provisionerError
		if errors.As(err, &pe) {
			_ = statusCallback(apiBaseURL, token, orgID, provisionerID, requestID, "failed", opts.timeout, map[string]any{
				"failure_code":    pe.code,
				"failure_message": pe.message,
				"progress":        progressPayload(map[string]any{"stage": "preflight_failed"}),
			})
			return pe
		}
		return preflightFilesystemFailed(err, workerStatusPath, apiBaseURL, token, orgID, provisionerID, requestID, opts.timeout)
	}

	if !opts.start {
		progress := progressPayload(map[string]any{
			"stage":   "preflight_complete",
			"dry_run": true,
			"root":    plan.root,
			"launch":  redactLaunch(plan.argv),
		})
		if err := statusCallback(apiBaseURL, token, orgID, provisionerID, requestID, "preflight_complete", opts.timeout, map[string]any{"progress": progress}); err != nil {
			return err
		}
		if err := writeWorkerStatus(workerStatusPath, map[string]any{
			"status":               "preflight_complete",
			"progress":             progress,
			"dry_run":              true,
			"pid":                  nil,
			"provisioner_id":       provisionerID,
			"provision_request_id": requestID,
			"root":                 plan.root,
			"launch":               redactLaunch(plan.argv),
		}); err != nil {
			return err
		}
		fmt.Printf("Dry run passed for device request %s.\n", requestID)
		fmt.Println("Connector was not started.")
		fmt.Println("Next: stop/recreate the request from BridgeForTeams, then rerun with --once --start.")
		return nil
	}

	if err := startManagedConnector(opts, stateDir, workerStatusPath, apiBaseURL, token, orgID, provisionerID, requestID, connectors, plan, "starting_connector"); err != nil {
		return err
	}
	fmt.Printf("Started connector for device request %s.\n", requestID)
	fmt.Println("Status: waiting_for_attach")
	return nil
}

func managedConnectorProjection(connectors map[string]*managedConnector) (string, *managedConnector) {
	if len(connectors) == 0 {
		return "idle", nil
	}

	allAttached := true
	var selected *managedConnector
	for _, connector := range connectors {
		if selected == nil {
			selected = connector
		}
		if connector.process == nil || connector.process.Process == nil {
			return "connector_restart_pending", connector
		}
		if !connector.attached {
			allAttached = false
			selected = connector
		}
	}
	if allAttached {
		return "connected", selected
	}
	return "running", selected
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
		fmt.Println("Mode: start connector")
	} else {
		fmt.Println("Mode: dry run (connector not started)")
	}
	fmt.Printf("Status path: %s\n", workerStatusPath)
	fmt.Println("")

	connectors := map[string]*managedConnector{}
	if opts.start {
		if err := materializeManagedConnectors(opts, config, stateDir, workerStatusPath, apiBaseURL, token, orgID, "", connectors); err != nil {
			return err
		}
	}

	var register map[string]any
	for {
		if opts.start {
			if err := reapConnectors(stateDir, workerStatusPath, "", nil, connectors); err != nil {
				return err
			}
		}
		httpStatus, response, requestErr := postJSON(apiBaseURL, token, fmt.Sprintf("/v1/orgs/%s/runners", orgID), provisionerPayload(config, len(connectors), nil), opts.timeout)
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
	statusReporter := newStatusReporter(apiBaseURL, token, orgID, provisionerID, opts.timeout)
	defer statusReporter.stop()

	iteration := 0
	for {
		iteration++
		err := runWorkerIteration(opts, config, stateDir, workerStatusPath, apiBaseURL, token, orgID, provisionerID, statusReporter, connectors)
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

func runWorkerIteration(opts runOptions, config map[string]any, stateDir, workerStatusPath, apiBaseURL, token, orgID, provisionerID string, statusReporter *statusReporter, connectors map[string]*managedConnector) error {
	if err := reapConnectors(stateDir, workerStatusPath, provisionerID, statusReporter, connectors); err != nil {
		return err
	}
	if err := reconcileRejectedManagedConnectors(statusReporter, config, stateDir, workerStatusPath, provisionerID, connectors); err != nil {
		return err
	}
	installFailures, err := agentVMMInstallFailureReports(stateDir)
	if err != nil {
		return err
	}
	httpStatus, response, err := postJSON(apiBaseURL, token, fmt.Sprintf("/v1/orgs/%s/runners/%s/heartbeat", orgID, provisionerID), provisionerPayload(config, len(connectors), installFailures), opts.timeout)
	heartbeat, err := expectSuccess(httpStatus, response, "heartbeat", err)
	if err != nil {
		return err
	}
	if err := persistAgentVMMInstallDescriptor(stateDir, heartbeat); err != nil {
		return err
	}
	if err := acknowledgeAgentVMMInstallFailures(config, stateDir, heartbeat); err != nil {
		return err
	}
	// Enrollment is a separately authorized identity operation. Complete it
	// before a release target can stop this control iteration for update.
	if err := applyAgentVMMInstallDescriptor(opts, config, stateDir, workerStatusPath, heartbeat); err != nil {
		fmt.Fprintf(os.Stderr, "Agent VMM managed installation failed: %v\n", err)
	}
	exclusiveUpdate, updateAdvisory, err := applyProvisionerUpdates(opts, config, stateDir, workerStatusPath, connectors, heartbeat)
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
	if err := consumeConnectorExits(workerStatusPath, provisionerID, connectors); err != nil {
		return err
	}
	if err := observeConnectors(stateDir, workerStatusPath, provisionerID, statusReporter, connectors); err != nil {
		return err
	}
	if err := claimOnce(opts, config, stateDir, workerStatusPath, apiBaseURL, token, orgID, provisionerID, statusReporter, connectors); err != nil {
		return err
	}
	return retainWorkerStatusAdvisory(workerStatusPath, "agent_vmm_update", updateAdvisory)
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

type preprocessOptions struct {
	input   string
	output  string
	timeout time.Duration
}

type fallbackCommand struct {
	tool string
	args []string
}

type fallbackPlan struct {
	kind       string
	outputMode string
	commands   []fallbackCommand
}

type fallbackExecutor interface {
	LookPath(string) (string, error)
	Run(context.Context, string, ...string) ([]byte, error)
}

type systemFallbackExecutor struct{}

func (systemFallbackExecutor) LookPath(name string) (string, error) {
	return exec.LookPath(name)
}

func (systemFallbackExecutor) Run(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).CombinedOutput()
}

func parsePreprocessArgs(args []string) (preprocessOptions, error) {
	var opts preprocessOptions
	fs := flag.NewFlagSet("preprocess", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.StringVar(&opts.input, "input", "", "local input file path")
	fs.StringVar(&opts.output, "output", "", "local output file or directory path")
	fs.DurationVar(&opts.timeout, "timeout", 2*time.Minute, "local preprocessing timeout")
	if err := fs.Parse(args); err != nil {
		return opts, provisionerError{code: "preprocess.arguments", message: err.Error()}
	}
	if fs.NArg() != 0 || strings.TrimSpace(opts.input) == "" || strings.TrimSpace(opts.output) == "" {
		return opts, provisionerError{
			code:    "preprocess.arguments",
			message: "use bft-runner preprocess --input <local-file> --output <local-file-or-directory>",
		}
	}
	if opts.timeout <= 0 {
		return opts, provisionerError{code: "preprocess.arguments", message: "timeout must be positive"}
	}
	return opts, nil
}

func runPreprocess(opts preprocessOptions, runner fallbackExecutor) error {
	info, err := os.Stat(opts.input)
	if err != nil || info.IsDir() {
		return provisionerError{code: "preprocess.input_unavailable", message: "input is not a readable local file: " + opts.input}
	}

	plan, err := fallbackPlanFor(opts.input, opts.output)
	if err != nil {
		return err
	}
	if err := prepareFallbackOutput(plan.outputMode, opts.output); err != nil {
		return provisionerError{code: "preprocess.output_unavailable", message: err.Error()}
	}

	ctx, cancel := context.WithTimeout(context.Background(), opts.timeout)
	defer cancel()

	tool, output, err := invokeFallbackPlan(ctx, runner, plan)
	if err != nil {
		return err
	}
	if plan.outputMode == "stdout" {
		if err := os.WriteFile(opts.output, output, 0o600); err != nil {
			return provisionerError{code: "preprocess.output_unavailable", message: err.Error()}
		}
	}
	if err := verifyFallbackOutput(plan.outputMode, opts.output); err != nil {
		return err
	}

	fmt.Println("BridgeForTeams fallback preprocessing")
	fmt.Printf("Kind: %s\n", plan.kind)
	fmt.Printf("Tool: %s\n", tool)
	fmt.Printf("Input: %s\n", opts.input)
	fmt.Printf("Output: %s\n", opts.output)
	return nil
}

func fallbackPlanFor(input, output string) (fallbackPlan, error) {
	ext := strings.ToLower(filepath.Ext(input))
	switch ext {
	case ".pdf":
		return fallbackPlan{kind: "pdf-to-text", outputMode: "file", commands: []fallbackCommand{
			{tool: "pdftotext", args: []string{input, output}},
		}}, nil
	case ".json":
		return fallbackPlan{kind: "json", outputMode: "stdout", commands: []fallbackCommand{
			{tool: "jq", args: []string{".", input}},
		}}, nil
	case ".gif", ".heic", ".heif", ".tif", ".tiff", ".bmp":
		return fallbackPlan{kind: "image-to-png", outputMode: "file", commands: []fallbackCommand{
			{tool: "magick", args: []string{input + "[0]", output}},
		}}, nil
	case ".docx", ".odt", ".rtf", ".html", ".htm", ".epub", ".tex":
		return fallbackPlan{kind: "document-to-markdown", outputMode: "file", commands: []fallbackCommand{
			{tool: "pandoc", args: []string{input, "-t", "gfm", "-o", output}},
		}}, nil
	case ".xls", ".xlsx":
		return fallbackPlan{kind: "spreadsheet-to-html", outputMode: "directory", commands: []fallbackCommand{
			{tool: "libreoffice", args: []string{"--headless", "--convert-to", "html", "--outdir", output, input}},
			{tool: "soffice", args: []string{"--headless", "--convert-to", "html", "--outdir", output, input}},
		}}, nil
	case ".ppt", ".pptx":
		return fallbackPlan{kind: "presentation-to-html", outputMode: "directory", commands: []fallbackCommand{
			{tool: "libreoffice", args: []string{"--headless", "--convert-to", "html", "--outdir", output, input}},
			{tool: "soffice", args: []string{"--headless", "--convert-to", "html", "--outdir", output, input}},
		}}, nil
	case ".zip":
		return fallbackPlan{kind: "archive-expand", outputMode: "directory", commands: []fallbackCommand{
			{tool: "7z", args: []string{"x", "-y", "-o" + output, input}},
			{tool: "7zz", args: []string{"x", "-y", "-o" + output, input}},
			{tool: "unzip", args: []string{"-o", input, "-d", output}},
		}}, nil
	case ".7z", ".rar":
		return fallbackPlan{kind: "archive-expand", outputMode: "directory", commands: []fallbackCommand{
			{tool: "7z", args: []string{"x", "-y", "-o" + output, input}},
			{tool: "7zz", args: []string{"x", "-y", "-o" + output, input}},
		}}, nil
	case ".mp3", ".wav", ".m4a", ".aac", ".flac", ".ogg":
		return fallbackPlan{kind: "audio-to-wav", outputMode: "file", commands: []fallbackCommand{
			{tool: "ffmpeg", args: []string{"-y", "-i", input, "-vn", "-ac", "1", "-ar", "16000", output}},
		}}, nil
	case ".mp4", ".mov", ".mkv", ".webm", ".avi":
		return fallbackPlan{kind: "video-first-frame", outputMode: "file", commands: []fallbackCommand{
			{tool: "ffmpeg", args: []string{"-y", "-i", input, "-frames:v", "1", output}},
		}}, nil
	default:
		return fallbackPlan{}, provisionerError{
			code: "preprocess.unsupported_format",
			message: "no reliable installed-tool fallback for " + ext +
				"; keep the original attachment and report the unsupported format",
		}
	}
}

func prepareFallbackOutput(mode, output string) error {
	if mode == "directory" {
		return os.MkdirAll(output, 0o700)
	}
	return os.MkdirAll(filepath.Dir(output), 0o700)
}

func invokeFallbackPlan(ctx context.Context, runner fallbackExecutor, plan fallbackPlan) (string, []byte, error) {
	var found bool
	var lastErr error
	for _, command := range plan.commands {
		path, err := runner.LookPath(command.tool)
		if err != nil {
			continue
		}
		found = true
		output, err := runner.Run(ctx, path, command.args...)
		if err == nil {
			return command.tool, output, nil
		}
		lastErr = fmt.Errorf("%s: %w: %s", command.tool, err, firstOutputLine(output))
	}
	if !found {
		return "", nil, provisionerError{
			code:    "preprocess.tool_missing",
			message: "required local fallback tool is missing; run bft-runner doctor and install the reported dependency",
		}
	}
	return "", nil, provisionerError{code: "preprocess.failed", message: lastErr.Error()}
}

func verifyFallbackOutput(mode, output string) error {
	info, err := os.Stat(output)
	if err != nil {
		return provisionerError{code: "preprocess.no_output", message: "fallback command produced no output: " + output}
	}
	if mode == "directory" {
		if !info.IsDir() {
			return provisionerError{code: "preprocess.no_output", message: "fallback output is not a directory: " + output}
		}
		entries, err := os.ReadDir(output)
		if err != nil {
			return provisionerError{code: "preprocess.no_output", message: err.Error()}
		}
		for _, entry := range entries {
			entryInfo, err := entry.Info()
			if err == nil && !entryInfo.IsDir() && entryInfo.Size() > 0 {
				return nil
			}
		}
		return provisionerError{code: "preprocess.no_output", message: "fallback command produced an empty output directory: " + output}
	}
	if info.IsDir() || info.Size() == 0 {
		return provisionerError{code: "preprocess.no_output", message: "fallback command produced an empty output: " + output}
	}
	return nil
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
	workdir, err := runnerWorkdir(config)
	if err != nil {
		return err
	}
	salixConnect, err := requirePath(config, "salix_connect")
	if err != nil {
		return err
	}
	if !executable(salixConnect) {
		return provisionerError{code: "preflight.salix_connect_not_executable", message: "salix-connect is not executable: " + salixConnect}
	}
	vmm, err := observeManagedVMM(config)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(stateDir, 0o755); err != nil {
		return provisionerError{code: "preflight.state_dir_not_ready", message: "state_dir is not writable"}
	}
	if err := os.MkdirAll(filepath.Join(workdir, "agents"), 0o755); err != nil {
		return provisionerError{code: "preflight.workdir_not_ready", message: "runner workdir or connector workdir is not writable"}
	}
	fmt.Println("BridgeForTeams runner")
	fmt.Println("Doctor passed")
	fmt.Printf("Config: %s\n", expandUser(opts.configPath))
	fmt.Printf("State: %s\n", stateDir)
	fmt.Printf("Workdir: %s\n", workdir)
	fmt.Printf("Runtime probe: %s runtime-probe\n", salixConnect)
	fmt.Printf("Agent VMM: %s (%s)\n", vmm.State, vmm.Freshness)
	printFallbackTooling(os.Stdout, checkFallbackTooling())
	return nil
}

type fallbackToolStatus struct {
	name   string
	status string
	detail string
}

type fallbackToolCommand struct {
	name       string
	candidates [][]string
}

func checkFallbackTooling() []fallbackToolStatus {
	checks := []fallbackToolCommand{
		{name: "jq", candidates: [][]string{{"jq", "--version"}}},
		{name: "ImageMagick", candidates: [][]string{{"magick", "-version"}}},
		{name: "pandoc", candidates: [][]string{{"pandoc", "--version"}}},
		{name: "pdftotext", candidates: [][]string{{"pdftotext", "-v"}}},
		{name: "LibreOffice", candidates: [][]string{{"libreoffice", "--version"}, {"soffice", "--version"}}},
		{name: "ffmpeg", candidates: [][]string{{"ffmpeg", "-version"}}},
		{name: "7z", candidates: [][]string{{"7z", "i"}, {"7zz", "i"}}},
	}

	statuses := make([]fallbackToolStatus, 0, len(checks))
	for _, check := range checks {
		statuses = append(statuses, checkFallbackCommand(check))
	}
	return statuses
}

func checkFallbackCommand(check fallbackToolCommand) fallbackToolStatus {
	for _, candidate := range check.candidates {
		if len(candidate) == 0 {
			continue
		}
		path, err := exec.LookPath(candidate[0])
		if err != nil {
			continue
		}

		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		output, err := exec.CommandContext(ctx, path, candidate[1:]...).CombinedOutput()
		cancel()
		if err == nil {
			return fallbackToolStatus{name: check.name, status: "ok", detail: firstOutputLine(output)}
		}
	}

	return fallbackToolStatus{name: check.name, status: "missing", detail: "optional fallback unavailable"}
}

func firstOutputLine(output []byte) string {
	for _, line := range strings.Split(string(output), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			line = strings.Map(func(r rune) rune {
				if r < 0x20 || r == 0x7f {
					return -1
				}
				return r
			}, line)
			if len(line) > 160 {
				return line[:160]
			}
			return line
		}
	}
	return "available"
}

func printFallbackTooling(w io.Writer, statuses []fallbackToolStatus) {
	fmt.Fprintln(w, "Fallback tooling (required only when native input is unavailable):")
	for _, status := range statuses {
		fmt.Fprintf(w, "- %s: %s (%s)\n", status.name, status.status, status.detail)
	}
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
	if requestID := stringValue(status["provision_request_id"]); requestID != "" {
		fmt.Printf("Provision request: %s\n", requestID)
	}
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
			message: "ask an administrator to run /Library/PrivilegedHelperTools/agent-vmm-service-executor " + action +
				" --job runner; do not run the service-user-owned bft-runner as root",
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

func max(a, b int) int {
	if a > b {
		return a
	}
	return b
}
