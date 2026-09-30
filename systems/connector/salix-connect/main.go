package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/gorilla/websocket"
	"github.com/klauspost/compress/zstd"
)

const (
	maxOutput                        = 64 * 1024
	maxProcessBytes                  = 2 * 1024 * 1024
	maxFile                          = 10 * 1024 * 1024
	chunkSize                        = 256 * 1024
	maxArchiveBytes                  = 64 * 1024 * 1024
	maxArchiveFile                   = 32 * 1024 * 1024
	componentName                    = "salix-connect"
	externalRuntimeStateRelativePath = "external-runtime/state.db"

	// scopeLocalFileRead restricts the connector to serving read_ref for the
	// Electron-managed local attachment index. Every other remote method is
	// refused locally. Credential-scoped connectors also enforce this on the
	// Server; Comma-started connectors use their generation-fenced reported scope
	// only as a trusted routing/readiness projection.
	scopeLocalFileRead = "local_file_read"

	minReconnectBackoff          = time.Second
	maxReconnectBackoff          = 30 * time.Second
	externalInputCatchupTimeout  = 30 * time.Second
	externalRuntimeCheckInterval = 10 * time.Second
	webSocketReadTimeout         = 45 * time.Second
	maxWebSocketMessageBytes     = 16 * 1024 * 1024
	maxConcurrentRequests        = 16
	maxConcurrentStreamWrites    = 4
	maxPendingWriteStreams       = 16
	connectorInstanceHeader      = "X-Salix-Connector-Instance-ID"
)

var (
	webSocketWriteTimeout = 20 * time.Second
	buildReleaseID        = "development"
	buildCommit           = "unknown"
	buildBuiltAt          = "unknown"
)

type config struct {
	deviceMode          bool
	deviceStateRoot     string
	externalStateRoot   string
	deviceWorkspaceID   string
	stdio               bool
	vmServer            bool
	runtimeAgent        bool
	listen              string
	configPath          string
	runNonce            string
	parentLifelineFD    int
	parentLifelinePipe  string
	shutdownRequestPath string
	server              string
	token               string
	statusPath          string
	name                string
	alias               string
	root                string
	reconnect           bool

	computerUseHelperApp   string
	computerUseSocketPath  string
	computerUseRuntimePath string
	localFileIndexRoot     string
	runtimeNamespace       string
	runtimeRoot            string
	scope                  string

	meetURL          string
	meetCallbackHost string
	meetCallbackPort int

	computeRuntimeURL            string
	computeRuntimeBootstrapToken string
	computeRuntimeWorkloadID     string
	computeRuntimeInstanceID     string
	computeRuntimeEpoch          string
	computeRuntimeGeneration     int
	computeRuntimeKind           string
	computeRuntimeProvider       string
	computeRuntimeTenantID       string
	computeRuntimeProjectID      string

	systemInfoInterval time.Duration

	workspaceArchiveEnabled        bool
	workspaceArchiveIdle           time.Duration
	workspaceArchiveRestoreTimeout time.Duration

	androidEnabled      bool
	androidSDKRoot      string
	androidRuntimeRoot  string
	androidAVDHome      string
	androidProfilesFile string
	androidSerial       string
	androidGPU          string
}

type connector struct {
	cloudRuntimeRequests  int
	cloudRuntimeParkUntil time.Time
	cloudRuntimeParkToken string
	cloudRuntimeQuiesced  bool
	cloudRuntimeReleased  bool
	cloudRuntimeMu        sync.Mutex

	deviceAccessMu            sync.Mutex
	deviceRuntimeMu           sync.RWMutex
	cfg                       config
	runtimePingInterval       time.Duration
	root                      string
	scopeMu                   sync.Mutex
	scope                     string
	commandContext            context.Context
	cancelCommandContext      context.CancelFunc
	processStartedAt          int64
	connectorRunID            string
	deviceID                  string
	connectorID               string
	ownerUserID               string
	connectionGeneration      int64
	processInstanceID         string
	statusMu                  sync.Mutex
	remoteMu                  sync.Mutex
	remoteReady               bool
	connectionMu              sync.Mutex
	activeConnection          *connectionSession
	beforeRequestAdmission    func(*connectionSession, message)
	afterConnectionPublished  func(*connectionSession)
	cleanupQueue              chan io.Closer
	requestSlots              chan struct{}
	requestMu                 sync.Mutex
	requestOperations         map[string]*requestOperation
	requestReplayBytes        int
	fatalErrors               chan error
	fatalSignal               chan struct{}
	fatalOnce                 sync.Once
	fatalMu                   sync.Mutex
	fatalErr                  error
	processes                 map[string]*managedProcess
	processMu                 sync.Mutex
	dependencyMu              sync.Mutex
	dependencyInstall         *dependencyInstallJob
	beforeManagedProcessStart func()
	runtimeInventory          *runtimeInventory
	runtimeAuthSlots          chan struct{}
	runtimeControlSlots       chan struct{}

	runtimeMu              sync.Mutex
	runtimePending         map[string]runtimePendingRequest
	runtimeRequestSequence atomic.Uint64
	runtimeProxySlots      chan struct{}
	runtimeImplementations map[string]externalRuntimeImplementation
	computeExecutionMu     sync.Mutex
	computeExecutionTarget map[string]any
	runtimeExecutionSlots  map[string]chan struct{}
	runtimeOperations      runtimeOperationCoordinator
	// Consecutive failed recovery checks per obligation key; owned by the
	// externalRuntimeHealthLoop goroutine (applyRecoveryFailureBudget).
	externalRuntimeRecoveryFailures map[string]externalRuntimeRecoveryStreak
	externalRuntimeIdentityPruneAt  time.Time
	bridgeMu                        sync.Mutex
	bridgeURL                       string
	bridgeServer                    *http.Server
	runtimeRoutes                   map[string]string
	salixCLIDirs                    map[string]string
	externalRuntimeState            *externalRuntimeState
	externalWorkspaceRoot           string
	externalWorkspaceError          error
	workspaceArchiver               *workspaceArchiver

	workspaceNoticeMu       sync.Mutex
	workspaceRuntimeNotices map[string]string

	computerUseImageMu         sync.Mutex
	computerUseImagesScheduled bool
	computerUseMu              sync.Mutex
	computerUseAuthToken       string
	android                    *androidProvider

	meetMu           sync.Mutex
	meetServer       *http.Server
	meetBaseURL      string
	meetCallbackURL  string
	meetTokens       map[string]string
	meetSessions     map[string]string
	meetingArtifacts map[string]meetingArtifact

	sendMu          sync.Mutex
	activeTransport *runtimeTransport
}

type runtimeTransport struct {
	send        contextMessageSender
	done        chan struct{}
	closeOnce   sync.Once
	catchupOnce sync.Once
}

type runtimePendingRequest struct {
	transport *runtimeTransport
	reply     chan message
}

var errRuntimeTransportUnavailable = errors.New("connector is offline; Salix tools require a Server connection")

type authError struct {
	status int
	body   string
}

func (e authError) Error() string {
	if e.body != "" {
		return fmt.Sprintf("connector auth failed: HTTP %d: %s", e.status, strings.TrimSpace(e.body))
	}
	return fmt.Sprintf("connector auth failed: HTTP %d", e.status)
}

type websocketHandshakeError struct {
	status int
	body   string
	err    error
}

func (e websocketHandshakeError) Error() string {
	if e.body != "" {
		return fmt.Sprintf("websocket handshake failed: HTTP %d: %s", e.status, strings.TrimSpace(e.body))
	}
	if e.err != nil {
		return fmt.Sprintf("websocket handshake failed: HTTP %d: %v", e.status, e.err)
	}
	return fmt.Sprintf("websocket handshake failed: HTTP %d", e.status)
}

func (e websocketHandshakeError) Unwrap() error {
	return e.err
}

type localRequestError struct {
	method string
	err    error
}

func (e localRequestError) Error() string {
	if e.method == "" {
		return "local request failed: " + e.err.Error()
	}
	return fmt.Sprintf("local request %s failed: %v", e.method, e.err)
}

func (e localRequestError) Unwrap() error {
	return e.err
}

type connectorBuildInfo struct {
	Component string `json:"component"`
	Version   string `json:"version"`
	ReleaseID string `json:"release_id"`
	Commit    string `json:"commit"`
	BuiltAt   string `json:"built_at"`
	GOOS      string `json:"goos"`
	GOARCH    string `json:"goarch"`
	GoVersion string `json:"go_version"`
}

type connectorStatusFile struct {
	Mode                    string             `json:"mode"`
	State                   string             `json:"state"`
	Scope                   string             `json:"scope"`
	LocalFileIndexVersion   int                `json:"local_file_index_version"`
	Server                  string             `json:"server,omitempty"`
	ConnectorRunID          string             `json:"connector_run_id,omitempty"`
	DeviceID                string             `json:"device_id,omitempty"`
	ConnectorID             string             `json:"connector_id,omitempty"`
	LastConnected           int64              `json:"last_connected_at,omitempty"`
	LastErrorClass          string             `json:"last_error_class,omitempty"`
	LastErrorMessage        string             `json:"last_error_message,omitempty"`
	ConsecutiveFailures     int                `json:"consecutive_failures,omitempty"`
	ReconnectBackoffSeconds float64            `json:"reconnect_backoff_seconds,omitempty"`
	LastMetadataSentAt      int64              `json:"last_metadata_sent_at,omitempty"`
	ComponentRelease        connectorBuildInfo `json:"component_release"`
	UpdatedAt               int64              `json:"updated_at"`
}

type managedProcess struct {
	name      string
	cmd       *exec.Cmd
	stdin     io.WriteCloser
	stdinSlot chan struct{}
	stdout    *processOutput
	stderr    *processOutput
	done      chan struct{}
	startedAt int64

	mu        sync.Mutex
	status    string
	exitCode  *int
	exitError string
}

type codexRuntime struct {
	implementation *codexRuntimeImplementation
	command        string
	generation     string
	cmd            *exec.Cmd
	listenURL      string
	connectTimeout time.Duration
	readLimit      int64
	ws             *websocket.Conn
	wsMu           sync.Mutex
	exited         chan struct{}
	done           chan struct{}
	doneOnce       sync.Once
	stopOnce       sync.Once
	initMu         sync.Mutex

	writeMu                        sync.Mutex
	mu                             sync.Mutex
	nextID                         int
	pending                        map[string]chan map[string]any
	initialized                    bool
	authEpoch                      uint64
	subscriptionMu                 sync.Mutex
	subscriptionRevision           int64
	subscriptionCredentialRevision string
	subscriptionRefreshing         bool
	subscriptionNeedsLogin         bool
	subscriptionAccountID          string
	subscriptionChatGPTID          string
	// Modeled in tla/connector/RuntimeAuthReadiness.tla.
	// fullReadinessProven means the cached overall readiness fields were
	// committed by a full probe of this exact process generation while auth was
	// ready. Incremental non-ready auth evidence invalidates the proof.
	fullReadinessProven bool
}

type codexRPCError struct {
	method  string
	code    int
	message string
}

var errCodexAppServerUnavailable = errors.New("codex app-server unavailable")

func (e *codexRPCError) Error() string {
	if e.message == "" {
		return fmt.Sprintf("codex %s: RPC error %d", e.method, e.code)
	}
	return fmt.Sprintf("codex %s: %s", e.method, e.message)
}

type codexRuntimeSession struct {
	inputMu                  sync.Mutex // holds the complete batch until the native thread is ready
	mu                       sync.Mutex
	sessionID                string
	token                    string
	threadID                 string
	activeTurnID             string
	lastCompletedTurnID      string
	lastCompletedDispatchID  string
	lastCompletedExecutionID string
	dispatchID               string
	executionID              string
	workState                string
	failureIssue             string
	failureMessage           string
	turnStartedSeq           uint64
	recoveryPending          bool
	recoveryMessage          string
	persistencePending       bool
	runtime                  *codexRuntime
	threadRuntime            *codexRuntime // generation that completed native start/resume
	recoveryInput            externalRuntimeInput
	stopDone                 chan struct{}
}

type codexRuntimeImplementation struct {
	connector        *connector
	activityMu       sync.RWMutex
	activityRevision atomic.Uint64
	mu               sync.Mutex
	runtimes         map[string]*codexRuntime
	sessions         map[string]*codexRuntimeSession
	sessionOrder     []string
	sessionIndex     map[string]int
	threads          map[string]string
	auth             *runtimeAuthCoordinator
	authQuarantined  map[string]bool
	connectTimeout   time.Duration
	closed           bool
}

func (i *codexRuntimeImplementation) beginActivity() func() {
	i.activityMu.RLock()
	i.activityRevision.Add(1)
	return i.activityMu.RUnlock
}

type processOutput struct {
	mu         sync.Mutex
	data       []byte
	baseOffset int64
	nextOffset int64
	notify     chan struct{}
}

type message struct {
	ID                   string         `json:"id,omitempty"`
	Type                 string         `json:"type,omitempty"`
	Method               string         `json:"method,omitempty"`
	ConnectorRunID       string         `json:"connector_run_id,omitempty"`
	DeviceID             string         `json:"device_id,omitempty"`
	ConnectorID          string         `json:"connector_id,omitempty"`
	OwnerUserID          string         `json:"owner_user_id,omitempty"`
	ConnectionGeneration int64          `json:"connection_generation,omitempty"`
	Params               map[string]any `json:"params,omitempty"`
	Result               any            `json:"result,omitempty"`
	Error                string         `json:"error,omitempty"`
	Stream               *streamData    `json:"stream,omitempty"`
	Capabilities         map[string]any `json:"capabilities,omitempty"`
	Skills               *[]any         `json:"skills,omitempty"`
	SystemInfo           map[string]any `json:"system_info,omitempty"`
	ConnectorHealth      map[string]any `json:"connector_health,omitempty"`
}

var codexAppBundleCommandPaths = defaultCodexAppBundleCommandPaths

type streamData struct {
	Channel string `json:"channel,omitempty"`
	Data    string `json:"data,omitempty"`
	EOF     bool   `json:"eof,omitempty"`
	Seq     int    `json:"seq,omitempty"`
}

type statResult struct {
	Path       string `json:"path"`
	Kind       string `json:"kind"`
	Size       int64  `json:"size"`
	Mode       string `json:"mode"`
	ModifiedAt int64  `json:"modified_at"`
}

func main() {
	if len(os.Args) > 1 && os.Args[1] == "cache-cleanup" {
		if len(os.Args) != 2 {
			fatal(errors.New("cache-cleanup takes no arguments"))
		}
		if err := cleanupGeneratedHomeCaches(filepath.Join(getenv("SALIX_VM_WORKSPACE", "/workspace"), ".salix", "sprite-home")); err != nil {
			fatal(err)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "version" {
		if err := runVersionCommand(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "salix-connect version: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "runtime-probe" {
		if err := runRuntimeProbeCommand(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "salix-connect runtime-probe: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "runtime-cli" {
		if err := runSalixRuntimeCLI(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "salix: %v\n", err)
			os.Exit(1)
		}
		return
	}
	if len(os.Args) > 1 && os.Args[1] == "comma-client" {
		if err := runCommaClientCLI(os.Args[2:]); err != nil {
			fmt.Fprintf(os.Stderr, "comma: %v\n", err)
			os.Exit(1)
		}
		return
	}

	cfg := parseFlags()
	c, err := newConnector(cfg)
	if err != nil {
		fatal(err)
	}
	defer c.shutdownComputerUseDaemon()
	defer c.closeExternalRuntimes()
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if cfg.parentLifelineFD >= 3 || cfg.parentLifelinePipe != "" {
		lifeline, err := openParentLifeline(cfg)
		if err != nil {
			fatal(err)
		}
		defer lifeline.Close()
		go watchParentLifeline(ctx, lifeline, stop)
	}
	if cfg.runNonce != "" && (cfg.scope == scopeLocalFileRead || cfg.deviceMode) {
		go watchScopeControl(ctx, os.Stdin, c)
	}
	if cfg.shutdownRequestPath != "" {
		go watchShutdownRequest(ctx, cfg.shutdownRequestPath, cfg.runNonce, stop)
	}
	go c.externalRuntimeHealthLoop(ctx, externalRuntimeCheckInterval)
	go c.externalRuntimeWorkspaceArchiveLoop(ctx)

	if cfg.stdio {
		logf("salix-connect stdio: root=%s", c.root)
		err := c.runStdio(ctx)
		if err != nil && !errors.Is(err, context.Canceled) {
			fatal(err)
		}
		return
	}

	if cfg.runtimeAgent || cfg.vmServer {
		mode := "runtime-agent"
		if cfg.vmServer && !cfg.runtimeAgent {
			mode = "legacy-vm-server"
		}
		logf("salix-connect %s: listen=%s root=%s", mode, cfg.listen, c.root)
		if cfg.runtimeAgent && computeRuntimeConfigured(cfg) {
			go func() {
				if err := c.prepareComputeRuntime(ctx); err != nil {
					logf("compute runtime initialization failed: %v", err)
					return
				}
				c.computeRuntimeInputLoop(ctx)
			}()
		}
		err := c.runVMServer(ctx)
		if err != nil && !errors.Is(err, context.Canceled) && !errors.Is(err, http.ErrServerClosed) {
			fatal(err)
		}
		return
	}

	if cfg.server == "" {
		fatal(errors.New("--server is required unless --stdio is set"))
	}
	if cfg.token == "" {
		fatal(errors.New("--connector-token or SALIX_CONNECTOR_TOKEN is required in remote mode"))
	}

	logf("salix-connect remote: mode=%s server=%s root=%s", cfg.mode(), cfg.server, c.root)
	err = c.runRemote(ctx)
	if err != nil && !errors.Is(err, context.Canceled) {
		fatal(err)
	}
}

func runVersionCommand(args []string) error {
	fs := flag.NewFlagSet("version", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	jsonOutput := fs.Bool("json", false, "print version as JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}
	info := currentBuildInfo()
	if *jsonOutput {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(info)
	}
	fmt.Fprintf(os.Stdout, "%s %s (%s, built %s)\n", info.Component, info.ReleaseID, info.Commit, info.BuiltAt)
	return nil
}

func runRuntimeProbeCommand(args []string) error {
	fs := flag.NewFlagSet("runtime-probe", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	jsonOutput := fs.Bool("json", false, "print runtime probe as JSON")
	if err := fs.Parse(args); err != nil {
		return err
	}

	report := runtimeProbeReport()
	if *jsonOutput {
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		if err := enc.Encode(report); err != nil {
			return err
		}
	} else {
		printRuntimeProbeText(report)
	}

	if report["ready"] != true {
		return errors.New(defaultString(stringParam(report, "last_error"), "no usable external runtime found"))
	}
	return nil
}

func runtimeProbeReport() map[string]any {
	workspaceRoot, workspaceErr := resolveExternalRuntimeWorkspaceRoot()
	if workspaceErr == nil {
		workspaceErr = prepareExternalRuntimeWorkspace(workspaceRoot)
	}
	runtimes := detectAgentRuntimes(workspaceErr)
	ready := false
	for _, runtime := range runtimes {
		if runtime["ready"] == true {
			ready = true
			break
		}
	}

	lastError := ""
	if len(runtimes) == 0 {
		lastError = "no supported external runtime command found"
	} else if !ready {
		errors := make([]string, 0, len(runtimes))
		for _, runtime := range runtimes {
			if text := strings.TrimSpace(stringParam(runtime, "last_error")); text != "" {
				errors = append(errors, text)
			}
		}
		lastError = strings.Join(errors, "; ")
	}

	status := "available"
	if !ready {
		status = "unavailable"
	}

	return map[string]any{
		"status":               status,
		"ready":                ready,
		"agent_runtimes":       runtimes,
		"readiness_checked_at": time.Now().UnixMilli(),
		"last_error":           lastError,
	}
}

func printRuntimeProbeText(report map[string]any) {
	fmt.Fprintln(os.Stdout, "Salix runtime probe")
	fmt.Fprintf(os.Stdout, "Status: %s\n", stringParam(report, "status"))
	if err := stringParam(report, "last_error"); err != "" {
		fmt.Fprintf(os.Stdout, "Reason: %s\n", err)
	}
	runtimes, _ := report["agent_runtimes"].([]map[string]any)
	for _, item := range runtimes {
		fmt.Fprintf(os.Stdout, "- %s %s ready=%t auth_ready=%t app_server_startable=%t\n",
			stringParam(item, "provider"),
			stringParam(item, "command"),
			item["ready"] == true,
			item["auth_ready"] == true,
			item["app_server_startable"] == true,
		)
		if err := stringParam(item, "last_error"); err != "" {
			fmt.Fprintf(os.Stdout, "  error: %s\n", err)
		}
	}
}

func currentBuildInfo() connectorBuildInfo {
	releaseID := defaultString(strings.TrimSpace(buildReleaseID), "development")
	return connectorBuildInfo{
		Component: componentName,
		Version:   releaseID,
		ReleaseID: releaseID,
		Commit:    defaultString(strings.TrimSpace(buildCommit), "unknown"),
		BuiltAt:   defaultString(strings.TrimSpace(buildBuiltAt), "unknown"),
		GOOS:      runtime.GOOS,
		GOARCH:    runtime.GOARCH,
		GoVersion: runtime.Version(),
	}
}

func parseFlags() config {
	var cfg config
	flag.StringVar(&cfg.configPath, "config", getenv("SALIX_CONNECTOR_CONFIG", ""), "connector config JSON path")
	flag.StringVar(&cfg.runNonce, "run-nonce", getenv("SALIX_CONNECTOR_RUN_NONCE", ""), "Electron Main run identity nonce")
	flag.IntVar(&cfg.parentLifelineFD, "parent-lifeline-fd", getenvInt("SALIX_CONNECTOR_PARENT_LIFELINE_FD", -1), "inherited pipe fd closed when Electron Main exits")
	flag.StringVar(&cfg.parentLifelinePipe, "parent-lifeline-pipe", getenv("SALIX_CONNECTOR_PARENT_LIFELINE_PIPE", ""), "Windows named pipe closed when Electron Main exits")
	flag.StringVar(&cfg.shutdownRequestPath, "shutdown-request-file", getenv("SALIX_CONNECTOR_SHUTDOWN_REQUEST_FILE", ""), "nonce-authenticated cooperative shutdown request file")
	flag.BoolVar(&cfg.stdio, "stdio", false, "serve connector protocol on stdin/stdout")
	flag.BoolVar(&cfg.workspaceArchiveEnabled, "workspace-archive", getenvBool("SALIX_WORKSPACE_ARCHIVE", true), "archive external runtime workspaces idle for the configured threshold and restore them on next input")
	flag.BoolVar(&cfg.vmServer, "vm-server", getenvBool("SALIX_VM_CONNECT_SERVER", false), "serve connector protocol over HTTP/WebSocket for cloud VM gateways")
	flag.BoolVar(&cfg.runtimeAgent, "runtime-agent", getenvBool("SALIX_RUNTIME_AGENT", false), "serve the shared External Worker Runtime Agent over HTTP/WebSocket")
	flag.StringVar(&cfg.listen, "listen", getenv("SALIX_RUNTIME_AGENT_LISTEN", getenv("SALIX_VM_CONNECT_LISTEN", ":8080")), "listen address for --runtime-agent")
	flag.StringVar(&cfg.server, "server", getenv("SALIX_SERVER", ""), "Salix ws:// or wss:// server")
	flag.StringVar(&cfg.token, "connector-token", getenv("SALIX_CONNECTOR_TOKEN", ""), "connector token")
	flag.StringVar(&cfg.statusPath, "status-file", getenv("SALIX_CONNECTOR_STATUS_FILE", ""), "write connector status JSON to this path")
	flag.StringVar(&cfg.name, "name", getenv("SALIX_CONNECTOR_NAME", hostname()), "connector name")
	flag.StringVar(&cfg.alias, "alias", getenv("SALIX_CONNECTOR_ALIAS", ""), "tool-facing alias")
	flag.StringVar(&cfg.root, "root", getenv("SALIX_CONNECTOR_ROOT", "."), "base directory for relative paths")
	flag.StringVar(&cfg.externalStateRoot, "state-root", "", "absolute directory for managed runtime state (defaults to root)")
	flag.BoolVar(&cfg.reconnect, "reconnect", true, "reconnect remote WebSocket with backoff")
	flag.StringVar(&cfg.scope, "scope", getenv("SALIX_CONNECTOR_SCOPE", ""), "capability scope: empty (full) or local_file_read")
	flag.StringVar(&cfg.localFileIndexRoot, "local-file-index", getenv("SALIX_LOCAL_FILE_INDEX", ""), "Electron-managed local attachment index root")
	flag.BoolVar(&cfg.androidEnabled, "android", getenvBool("SALIX_ANDROID_ENABLED", false), "enable the Connector-owned Android emulator")
	flag.StringVar(&cfg.androidSDKRoot, "android-sdk-root", getenv("SALIX_ANDROID_SDK_ROOT", ""), "Android SDK root")
	flag.StringVar(&cfg.androidRuntimeRoot, "android-runtime-root", getenv("SALIX_ANDROID_RUNTIME_ROOT", ""), "private Android runtime and lease staging root")
	flag.StringVar(&cfg.androidAVDHome, "android-avd-home", getenv("SALIX_ANDROID_AVD_HOME", ""), "Android AVD home")
	flag.StringVar(&cfg.androidProfilesFile, "android-profiles-file", getenv("SALIX_ANDROID_PROFILES_FILE", ""), "administrator-installed Android profile manifest")
	flag.StringVar(&cfg.androidSerial, "android-serial", getenv("SALIX_ANDROID_SERIAL", "emulator-5554"), "fixed Android emulator serial")
	flag.StringVar(&cfg.androidGPU, "android-gpu", getenv("SALIX_ANDROID_GPU", "swiftshader_indirect"), "Android emulator GPU mode")
	flag.StringVar(&cfg.meetURL, "meet-url", getenv("SALIX_MEET_URL", ""), "base URL of a local meetnative serve HTTP runtime; enables the meeting runtime")
	flag.StringVar(&cfg.meetCallbackHost, "meet-callback-host", getenv("SALIX_MEET_CALLBACK_HOST", ""), "host the meetnative HTTP runtime should call back on (default 127.0.0.1; set when meetnative cannot reach loopback)")
	flag.IntVar(&cfg.meetCallbackPort, "meet-callback-port", getenvInt("SALIX_MEET_CALLBACK_PORT", 0), "fixed local port for the meetnative callback listener (0 = ephemeral). Pin a per-instance port so callback URLs held by meetnative survive a connector restart")
	flag.StringVar(&cfg.computeRuntimeURL, "compute-runtime-url", getenv("SALIX_COMPUTE_RUNTIME_URL", ""), "Salix Compute Runtime carrier URL")
	flag.StringVar(&cfg.computeRuntimeBootstrapToken, "compute-runtime-bootstrap-token", getenv("SALIX_COMPUTE_RUNTIME_BOOTSTRAP_TOKEN", ""), "short-lived Salix Compute Runtime bootstrap credential")
	flag.StringVar(&cfg.computeRuntimeWorkloadID, "compute-runtime-workload-id", getenv("SALIX_COMPUTE_WORKLOAD_ID", ""), "exact Salix Compute Workload identity")
	flag.StringVar(&cfg.computeRuntimeInstanceID, "compute-runtime-instance-id", getenv("SALIX_COMPUTE_RUNTIME_INSTANCE_ID", ""), "exact Salix RuntimeInstance identity")
	flag.StringVar(&cfg.computeRuntimeEpoch, "compute-runtime-epoch", getenv("SALIX_COMPUTE_CONNECTION_EPOCH", ""), "exact Salix RuntimeInstance connection epoch")
	registerRetiredFlags(flag.CommandLine)
	cfg.computeRuntimeGeneration = getenvInt("SALIX_COMPUTE_GENERATION", 0)
	cfg.computeRuntimeKind = getenv("SALIX_COMPUTE_RUNTIME_KIND", "")
	cfg.computeRuntimeProvider = getenv("SALIX_COMPUTE_RUNTIME_PROVIDER", "")
	cfg.computeRuntimeTenantID = getenv("SALIX_COMPUTE_TENANT_ID", "")
	cfg.computeRuntimeProjectID = getenv("SALIX_COMPUTE_PROJECT_ID", "")
	intervalSec := flag.Int("system-info-interval", getenvInt("SALIX_CONNECTOR_SYSTEM_INFO_INTERVAL", 300), "seconds between periodic system-info reports (0 disables)")
	workspaceArchiveIdleSec := flag.Int("workspace-archive-idle-seconds", getenvInt("SALIX_WORKSPACE_ARCHIVE_IDLE_SECONDS", int(workspaceArchiveIdleDefault/time.Second)), "seconds of inactivity before an external runtime workspace is archived (0 uses the default)")
	workspaceArchiveRestoreTimeoutSec := flag.Int("workspace-archive-restore-timeout-seconds", getenvInt("SALIX_WORKSPACE_ARCHIVE_RESTORE_TIMEOUT_SECONDS", int(workspaceArchiveRestoreTimeoutDefault/time.Second)), "seconds to wait for a workspace archive restore before treating it as failed (0 uses the default)")
	flag.BoolVar(&cfg.deviceMode, "device", false, "Connect a Comma-managed device with read-only access by default")
	flag.Parse()
	cfg.systemInfoInterval = time.Duration(*intervalSec) * time.Second
	cfg.workspaceArchiveIdle = time.Duration(*workspaceArchiveIdleSec) * time.Second
	cfg.workspaceArchiveRestoreTimeout = time.Duration(*workspaceArchiveRestoreTimeoutSec) * time.Second
	explicit := map[string]bool{}
	flag.Visit(func(f *flag.Flag) {
		explicit[f.Name] = true
	})
	if cfg.configPath != "" {
		if err := applyConfigFile(&cfg, explicit); err != nil {
			fatal(err)
		}
	}
	if cfg.deviceMode && cfg.configPath == "" && !explicit["scope"] {
		cfg.scope = scopeLocalFileRead
	}
	normalizeConfig(&cfg)
	lifelineExplicit := explicit["parent-lifeline-fd"] || explicit["parent-lifeline-pipe"]
	if cfg.scope == scopeLocalFileRead && !cfg.deviceMode &&
		(!explicit["config"] || !explicit["run-nonce"] || !explicit["shutdown-request-file"] || !lifelineExplicit) {
		fatal(errors.New("scope local_file_read requires explicit --config, --run-nonce, --shutdown-request-file, and parent-lifeline arguments"))
	}
	if cfg.scope == scopeLocalFileRead && !cfg.deviceMode && runtime.GOOS == "windows" && !explicit["parent-lifeline-pipe"] {
		fatal(errors.New("scope local_file_read requires --parent-lifeline-pipe on Windows"))
	}
	if cfg.scope == scopeLocalFileRead && !cfg.deviceMode && runtime.GOOS != "windows" && !explicit["parent-lifeline-fd"] {
		fatal(errors.New("scope local_file_read requires --parent-lifeline-fd on this platform"))
	}
	return cfg
}

type fileConfig struct {
	Connector struct {
		Device          bool   `json:"device"`
		DeviceStateRoot string `json:"device_state_root"`
		WorkspaceID     string `json:"workspace_id"`
		Server          string `json:"server"`
		ConnectorToken  string `json:"connector_token"`
		Name            string `json:"name"`
		Alias           string `json:"alias"`
		Root            string `json:"root"`
		Reconnect       *bool  `json:"reconnect"`
		Scope           string `json:"scope"`
	} `json:"connector"`
	Status struct {
		Path string `json:"path"`
	} `json:"status"`
	Electron struct {
		LocalFileIndexRoot string `json:"local_file_index_root"`
		RunNonce           string `json:"run_nonce"`
		RuntimeNamespace   string `json:"runtime_namespace"`
		RuntimeRoot        string `json:"runtime_root"`
	} `json:"electron"`
}

func applyConfigFile(cfg *config, explicit map[string]bool) error {
	data, err := os.ReadFile(cfg.configPath)
	if err != nil {
		return fmt.Errorf("read --config: %w", err)
	}
	var fc fileConfig
	if err := json.Unmarshal(data, &fc); err != nil {
		return fmt.Errorf("decode --config: %w", err)
	}
	conn := fc.Connector
	if fc.Status.Path != "" && !explicit["status-file"] {
		cfg.statusPath = fc.Status.Path
	}
	if conn.Server != "" && !explicit["server"] {
		cfg.server = conn.Server
	}
	if conn.ConnectorToken != "" && !explicit["connector-token"] {
		cfg.token = conn.ConnectorToken
	}
	if conn.Name != "" && !explicit["name"] {
		cfg.name = conn.Name
	}
	if conn.Alias != "" && !explicit["alias"] {
		cfg.alias = conn.Alias
	}
	if conn.Root != "" && !explicit["root"] {
		cfg.root = conn.Root
	}
	if conn.Reconnect != nil && !explicit["reconnect"] {
		cfg.reconnect = *conn.Reconnect
	}
	if conn.Scope != "" && !explicit["scope"] {
		cfg.scope = conn.Scope
	}
	if !explicit["device"] {
		cfg.deviceMode = conn.Device
	}
	cfg.deviceStateRoot = conn.DeviceStateRoot
	cfg.deviceWorkspaceID = conn.WorkspaceID
	if fc.Electron.LocalFileIndexRoot != "" && !explicit["local-file-index"] {
		cfg.localFileIndexRoot = fc.Electron.LocalFileIndexRoot
	}
	if fc.Electron.RuntimeNamespace != "" {
		cfg.runtimeNamespace = fc.Electron.RuntimeNamespace
	}
	if fc.Electron.RuntimeRoot != "" {
		cfg.runtimeRoot = fc.Electron.RuntimeRoot
	}
	if fileNonce := strings.TrimSpace(fc.Electron.RunNonce); fileNonce != "" {
		if explicit["run-nonce"] && strings.TrimSpace(cfg.runNonce) != fileNonce {
			return errors.New("--run-nonce does not match electron.run_nonce in config")
		}
		if !explicit["run-nonce"] {
			cfg.runNonce = fileNonce
		}
	}
	return nil
}

func normalizeConfig(cfg *config) {
	cfg.server = strings.TrimSpace(cfg.server)
	cfg.token = strings.TrimSpace(cfg.token)
	cfg.runNonce = strings.ToLower(strings.TrimSpace(cfg.runNonce))
	cfg.parentLifelinePipe = strings.TrimSpace(cfg.parentLifelinePipe)
	cfg.shutdownRequestPath = strings.TrimSpace(cfg.shutdownRequestPath)
	cfg.statusPath = strings.TrimSpace(cfg.statusPath)
	if cfg.statusPath == "" && cfg.configPath != "" {
		cfg.statusPath = cfg.configPath + ".status.json"
	}
	cfg.scope = strings.TrimSpace(cfg.scope)
	switch cfg.scope {
	case "", scopeLocalFileRead:
	default:
		// An unknown scope must never silently widen to full capability.
		fatal(fmt.Errorf("unknown connector scope %q; supported: %q", cfg.scope, scopeLocalFileRead))
	}
	if cfg.scope == scopeLocalFileRead && !cfg.deviceMode && cfg.localFileIndexRoot == "" {
		fatal(errors.New("scope local_file_read requires a local file index root"))
	}
	cfg.runtimeNamespace = strings.TrimSpace(cfg.runtimeNamespace)
	cfg.runtimeRoot = strings.TrimSpace(cfg.runtimeRoot)
	cfg.computerUseHelperApp = defaultString(strings.TrimSpace(cfg.computerUseHelperApp), defaultComputerUseHelperAppPath())
	cfg.computerUseSocketPath = defaultString(strings.TrimSpace(cfg.computerUseSocketPath), computerUseSocketPathForRuntime(cfg.runtimeNamespace, cfg.runtimeRoot))
	cfg.computerUseRuntimePath = strings.TrimSpace(cfg.computerUseRuntimePath)
	if cfg.computerUseRuntimePath == "" && cfg.runtimeRoot != "" {
		cfg.computerUseRuntimePath = filepath.Join(cfg.runtimeRoot, "computer-use")
	}
	cfg.localFileIndexRoot = strings.TrimSpace(cfg.localFileIndexRoot)
	cfg.androidSDKRoot = cleanOptionalPath(cfg.androidSDKRoot)
	cfg.androidRuntimeRoot = cleanOptionalPath(cfg.androidRuntimeRoot)
	cfg.androidAVDHome = cleanOptionalPath(cfg.androidAVDHome)
	cfg.androidProfilesFile = cleanOptionalPath(cfg.androidProfilesFile)
	cfg.androidSerial = strings.TrimSpace(cfg.androidSerial)
	cfg.androidGPU = strings.TrimSpace(cfg.androidGPU)
	if cfg.localFileIndexRoot != "" {
		if absolute, err := filepath.Abs(cfg.localFileIndexRoot); err == nil {
			cfg.localFileIndexRoot = filepath.Clean(absolute)
		}
	}
}

// retiredFlags are command-line flags that earlier connector releases accepted.
// Supervisors and launch configurations may still pass them; they parse and
// have no effect.
var retiredFlags = []string{
	"exec-runner",
	"fin-supervisor",
	"fin-dir",
	"fin-agent",
	"fin-evidence-jsonl",
	"fin-sedarwin",
	"direct-file-ops",
}

type discardFlagValue struct{}

func (discardFlagValue) String() string   { return "" }
func (discardFlagValue) Set(string) error { return nil }

func registerRetiredFlags(fs *flag.FlagSet) {
	for _, name := range retiredFlags {
		fs.Var(discardFlagValue{}, name, "")
	}
	fs.Usage = func() {
		fmt.Fprintf(fs.Output(), "Usage of %s:\n", fs.Name())
		visible := flag.NewFlagSet(fs.Name(), flag.ContinueOnError)
		visible.SetOutput(fs.Output())
		fs.VisitAll(func(f *flag.Flag) {
			if f.Usage != "" {
				visible.Var(f.Value, f.Name, f.Usage)
			}
		})
		visible.PrintDefaults()
	}
}

func (cfg config) mode() string {
	return "static"
}

func runSalixRuntimeCLI(args []string) error {
	if len(args) == 0 || args[0] == "-h" || args[0] == "--help" || args[0] == "help" {
		printSalixRuntimeCLIUsage()
		return nil
	}
	if args[0] == "version" || args[0] == "--version" || args[0] == "-v" {
		fmt.Fprintln(os.Stdout, "salix runtime cli")
		return nil
	}
	if args[0] == "computer-use" {
		return runComputerUseRuntimeCLI(args[1:])
	}

	runtimeContext := strings.TrimSpace(os.Getenv("SALIX_RUNTIME_CONTEXT"))
	if runtimeContext == "" {
		return errors.New("SALIX_RUNTIME_CONTEXT is not set; run salix inside an external runtime session")
	}

	bridgeURL := strings.TrimRight(os.Getenv("SALIX_CONNECT_URL"), "/")
	if bridgeURL == "" {
		return errors.New("SALIX_CONNECT_URL is not set")
	}

	switch args[0] {
	case "tools":
		return salixRuntimeCLIRequest("GET", bridgeURL+"/runtime/"+url.PathEscape(runtimeContext)+"/tools", nil)
	case "tool":
		if len(args) < 3 || args[1] != "call" {
			return errors.New("usage: salix tool call <tool_name> --json '{...}'")
		}
		toolName := args[2]
		body := "{}"
		for i := 3; i < len(args); i++ {
			if args[i] == "-h" || args[i] == "--help" || args[i] == "help" {
				helpBody, _ := json.Marshal(map[string]string{"tool": toolName})
				return salixRuntimeCLIRequest(
					"POST",
					bridgeURL+"/runtime/"+url.PathEscape(runtimeContext)+"/tool/help",
					strings.NewReader(string(helpBody)),
				)
			}
			if args[i] == "--json" {
				if i+1 >= len(args) {
					return errors.New("--json requires a JSON object")
				}
				body = args[i+1]
				i++
			}
		}
		if !json.Valid([]byte(body)) {
			return errors.New("--json must be valid JSON")
		}
		return salixRuntimeCLIRequest(
			"POST",
			bridgeURL+"/runtime/"+url.PathEscape(runtimeContext)+"/tool/"+url.PathEscape(toolName),
			strings.NewReader(body),
		)
	default:
		return fmt.Errorf("unknown salix command: %s", args[0])
	}
}

func printSalixRuntimeCLIUsage() {
	fmt.Fprintln(os.Stdout, "usage: salix tools | salix tool call <tool_name> --json '{...}' | salix computer-use <action> [--config path] [--json '{...}'")
	fmt.Fprintln(os.Stdout, "examples:")
	fmt.Fprintln(os.Stdout, "  salix tools")
	fmt.Fprintln(os.Stdout, "  salix tool call help --json '{\"tool\":\"im_api.internal.send_message\"}'")
	fmt.Fprintln(os.Stdout, "  salix tool call im_api.internal.send_message --json '{\"connect_id\":\"internal\",\"conversation_id\":\"task-...\",\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}'")
}

func salixRuntimeCLIRequest(method, endpoint string, body io.Reader) error {
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	client := &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return err
	}
	if len(raw) > 0 {
		_, _ = os.Stdout.Write(raw)
		if raw[len(raw)-1] != '\n' {
			_, _ = os.Stdout.Write([]byte("\n"))
		}
	}
	if resp.StatusCode >= 400 {
		return fmt.Errorf("tool gateway returned HTTP %d", resp.StatusCode)
	}
	return nil
}

func newConnector(cfg config) (*connector, error) {
	if cfg.externalStateRoot != "" {
		if !filepath.IsAbs(cfg.externalStateRoot) {
			return nil, errors.New("state-root must be an absolute directory")
		}
		if err := os.MkdirAll(cfg.externalStateRoot, 0700); err != nil {
			return nil, err
		}
	}
	normalizeConfig(&cfg)
	if err := validateConfig(cfg); err != nil {
		return nil, err
	}
	root, err := filepath.Abs(cfg.root)
	if err != nil {
		return nil, err
	}
	absRoot := root
	root, err = filepath.EvalSymlinks(absRoot)
	if err != nil {
		if os.IsNotExist(err) {
			if mkErr := os.MkdirAll(absRoot, 0o755); mkErr != nil {
				return nil, mkErr
			}
			root, err = filepath.EvalSymlinks(absRoot)
		}
		if err != nil {
			return nil, err
		}
	}
	externalWorkspaceRoot, externalWorkspaceError := resolveExternalRuntimeWorkspaceRoot()
	commandContext, cancelCommandContext := context.WithCancel(context.Background())
	if cfg.scope == scopeLocalFileRead {
		cancelCommandContext()
	}
	c := &connector{
		cfg:                             cfg,
		root:                            root,
		scope:                           cfg.scope,
		commandContext:                  commandContext,
		cancelCommandContext:            cancelCommandContext,
		processStartedAt:                time.Now().UnixMilli(),
		cleanupQueue:                    make(chan io.Closer, cleanupQueueSize),
		requestSlots:                    make(chan struct{}, maxConcurrentRequests),
		requestOperations:               map[string]*requestOperation{},
		processInstanceID:               randomHex(16),
		fatalErrors:                     make(chan error, 1),
		fatalSignal:                     make(chan struct{}),
		processes:                       map[string]*managedProcess{},
		runtimeInventory:                newRuntimeInventory(),
		runtimeAuthSlots:                make(chan struct{}, runtimeAuthConcurrency),
		runtimeControlSlots:             make(chan struct{}, runtimeControlConcurrency),
		runtimePending:                  map[string]runtimePendingRequest{},
		externalRuntimeRecoveryFailures: map[string]externalRuntimeRecoveryStreak{},
		runtimeProxySlots:               make(chan struct{}, maxConcurrentRequests),
		runtimeRoutes:                   map[string]string{},
		salixCLIDirs:                    map[string]string{},
		externalWorkspaceRoot:           externalWorkspaceRoot,
		externalWorkspaceError:          externalWorkspaceError,
		workspaceArchiver:               newWorkspaceArchiver(externalWorkspaceRoot, cfg.workspaceArchiveEnabled, cfg.workspaceArchiveIdle, cfg.workspaceArchiveRestoreTimeout),
		workspaceRuntimeNotices:         map[string]string{},
	}
	androidCfg := cfg
	androidCfg.root = root
	if androidCfg.androidRuntimeRoot != "" && !filepath.IsAbs(androidCfg.androidRuntimeRoot) {
		androidCfg.androidRuntimeRoot = filepath.Join(root, androidCfg.androidRuntimeRoot)
	}
	c.android = newAndroidProvider(androidCfg)
	c.runtimeInventory.workspaceReadiness = c.externalRuntimeWorkspaceReadiness
	if err := c.loadDeviceAccess(); err != nil {
		return nil, err
	}
	c.discoverDeviceRuntimes()

	// A scope-limited connector serves read_ref only. It must not open the
	// host-wide external runtime database (whose exclusive lock would break
	// concurrent scoped connectors sharing one --root), start recovery
	// workers, or instantiate any agent runtime implementation.
	if cfg.scope == scopeLocalFileRead && !cfg.deviceMode {
		c.externalRuntimeState = newDisabledExternalRuntimeState(c)
		c.runtimeImplementations = map[string]externalRuntimeImplementation{}
		go c.cleanupLoop()
		return c, nil
	}

	state, err := newExternalRuntimeState(c)
	if err != nil {
		return nil, fmt.Errorf("open external runtime state: %w", err)
	}
	c.externalRuntimeState = state
	c.workspaceArchiver.runtimeState = state
	go c.cleanupLoop()
	codexImplementation := newCodexRuntimeImplementation(c)
	c.runtimeImplementations = map[string]externalRuntimeImplementation{
		"codex":  codexImplementation,
		"pi":     newPiRuntimeImplementation(c),
		"kimi":   newKimiRuntimeImplementation(c),
		"claude": newClaudeRuntimeImplementation(c),
	}
	c.runtimeInventory.run = func(target runtimeProbeTarget) map[string]any {
		c.cloudRuntimeMu.Lock()
		c.cloudRuntimeRequests++
		c.cloudRuntimeMu.Unlock()
		defer func() { c.cloudRuntimeMu.Lock(); c.cloudRuntimeRequests--; c.cloudRuntimeMu.Unlock() }()
		_, leave, admitted := c.deviceRuntimeAdmission(context.Background())
		if !admitted {
			return map[string]any{"kind": "external", "provider": target.provider, "command": target.identityMaterial, "identity_material": target.identityMaterial, "status": "unavailable", "ready": false, "readiness_issue": "permission_required"}
		}
		defer leave()
		if target.provider == "codex" {
			return codexImplementation.probeRuntimeTarget(target)
		}
		if target.provider == "claude" && c.cfg.runtimeAgent &&
			c.cfg.computeRuntimeKind == "external_worker" && c.cfg.computeRuntimeProvider == "claude" {
			return portableRuntimeEntryWithClaudeIsolation("claude", target.identityMaterial, "agent-sdk-stream-json", []string{"stdio"}, true)
		}
		return probeAgentRuntimeTarget(target)
	}
	c.runtimeInventory.commitGuard = codexImplementation.commitRuntimeProbe
	if err := c.externalRuntimeState.load(); err != nil {
		c.closeExternalRuntimes()
		return nil, fmt.Errorf("load external runtime recovery state: %w", err)
	}
	// A pinned meetnative callback port must be receivable from process
	// start: terminal callbacks for meetings joined before a restart arrive
	// before any new join would lazily re-create the listener. Failing to
	// bind a pinned port is fatal — a silent fallback would reopen exactly
	// the restart window the pin exists to close. Ephemeral setups keep the
	// lazy bind; a fresh random port is useless to the callback-URL snapshot
	// meetnative captured at join time anyway. Scope-limited connectors
	// return above and never bind: they share --root with siblings and serve
	// no meeting runtime.
	if meetingRuntimeConfigured(cfg) && cfg.meetCallbackPort > 0 {
		if _, err := c.ensureMeetingCallback(); err != nil {
			c.closeExternalRuntimes()
			return nil, fmt.Errorf("bind pinned meeting callback port %d: %w", cfg.meetCallbackPort, err)
		}
	}
	if cfg.computerUseRuntimePath != "" {
		dir := filepath.Join(cfg.computerUseRuntimePath, "screenshots")
		if _, err := os.Stat(dir); err == nil {
			c.computerUseImageMu.Lock()
			_, _, err := c.sweepComputerUseImages(dir)
			c.computerUseImageMu.Unlock()
			if err != nil {
				fmt.Fprintf(os.Stderr, "computer_use screenshot cleanup failed: %v\n", err)
			}
		}
	}
	return c, nil
}

func validateConfig(cfg config) error {
	if cfg.scope == scopeLocalFileRead && !cfg.deviceMode {
		if !validRunNonce(cfg.runNonce) {
			return errors.New("scope local_file_read requires a 128-bit hexadecimal run nonce")
		}
		hasFD := cfg.parentLifelineFD >= 3
		hasPipe := cfg.parentLifelinePipe != ""
		if hasFD == hasPipe {
			return errors.New("scope local_file_read requires exactly one parent lifeline")
		}
		if cfg.shutdownRequestPath == "" {
			return errors.New("scope local_file_read requires a cooperative shutdown request file")
		}
	}
	return nil
}

var runNoncePattern = regexp.MustCompile(`^[a-f0-9]{32}$`)

func validRunNonce(nonce string) bool {
	return runNoncePattern.MatchString(strings.ToLower(strings.TrimSpace(nonce)))
}

func openParentLifeline(cfg config) (*os.File, error) {
	if cfg.parentLifelinePipe == "" {
		file := os.NewFile(uintptr(cfg.parentLifelineFD), "comma-parent-lifeline")
		if file == nil {
			return nil, fmt.Errorf("open --parent-lifeline-fd %d", cfg.parentLifelineFD)
		}
		return file, nil
	}

	// Electron begins listening before spawn. A short retry closes the tiny
	// listen/connect race; if Main died before accept, the child fails closed
	// instead of starting without a lifeline.
	deadline := time.Now().Add(5 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		file, err := os.OpenFile(cfg.parentLifelinePipe, os.O_RDONLY, 0)
		if err == nil {
			return file, nil
		}
		lastErr = err
		time.Sleep(25 * time.Millisecond)
	}
	return nil, fmt.Errorf("open --parent-lifeline-pipe: %w", lastErr)
}

// Modeled in tla/connector/ConnectorProcessContainment.tla: the lifeline and
// exact-nonce shutdown request are independent process-containment evidence;
// recovery still needs a fresh complete absence observation before cleanup.
// watchParentLifeline converts the inherited pipe's EOF into connector
// cancellation. Electron Main owns the other end; normal close, crash, and
// forcible termination all close it in the kernel. Bytes are ignored so an
// accidental write cannot be interpreted as a keepalive or extend lifetime.
func watchParentLifeline(ctx context.Context, reader io.Reader, cancel context.CancelFunc) {
	buffer := make([]byte, 64)
	for {
		_, err := reader.Read(buffer)
		if err != nil {
			if ctx.Err() == nil {
				cancel()
			}
			return
		}
		if ctx.Err() != nil {
			return
		}
	}
}

type scopeControlCommand struct {
	Type     string  `json:"type"`
	RunNonce string  `json:"run_nonce"`
	Scope    *string `json:"scope"`
}

// watchScopeControl consumes the private stdin owned by the Electron Main
// process which spawned this exact run. The run nonce prevents a delayed write
// for an old child from mutating its successor. Invalid input is ignored and
// EOF has no lifetime semantics; the independent parent lifeline owns process
// containment.
func watchScopeControl(ctx context.Context, reader io.Reader, c *connector) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 256), 4*1024)
	for scanner.Scan() {
		if ctx.Err() != nil {
			return
		}
		var command scopeControlCommand
		if err := json.Unmarshal(scanner.Bytes(), &command); err != nil ||
			command.Type != "set_scope" ||
			command.Scope == nil ||
			!constantTimeTextEqual(strings.ToLower(strings.TrimSpace(command.RunNonce)), c.cfg.runNonce) {
			continue
		}
		if err := c.setCurrentScope(*command.Scope); err != nil {
			continue
		}
		if err := c.publishCachedMetadata(); err == nil {
			// The status-file scope is the Main/UI acknowledgement. It advances
			// only after the replacement metadata entered the live transport.
			// On failure, periodic metadata retry will write the acknowledgement.
			c.writeStatusMetadataSent("")
		}
		go c.refreshDeviceRuntimes()
	}
}

func constantTimeTextEqual(left, right string) bool {
	if len(left) != len(right) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(left), []byte(right)) == 1
}

func (c *connector) currentScope() string {
	c.scopeMu.Lock()
	defer c.scopeMu.Unlock()
	return c.scope
}

func (c *connector) commandAdmissionContext(parent context.Context) (context.Context, context.CancelFunc, bool) {
	c.scopeMu.Lock()
	if c.scope == scopeLocalFileRead {
		c.scopeMu.Unlock()
		return parent, func() {}, false
	}
	if c.commandContext == nil {
		// A few internal/legacy construction paths instantiate connector
		// directly instead of using newConnector. Preserve their full-scope
		// semantics while still installing the same cancellable downgrade gate.
		c.commandContext, c.cancelCommandContext = context.WithCancel(context.Background())
	}
	gate := c.commandContext
	c.scopeMu.Unlock()

	ctx, cancel := context.WithCancel(parent)
	stopGate := context.AfterFunc(gate, cancel)
	return ctx, func() {
		stopGate()
		cancel()
	}, true
}

func (c *connector) setCurrentScope(scope string) error {
	c.deviceAccessMu.Lock()
	defer c.deviceAccessMu.Unlock()
	scope = strings.TrimSpace(scope)
	if scope != "" && scope != scopeLocalFileRead {
		return fmt.Errorf("unsupported connector scope %q", scope)
	}
	if err := c.persistDeviceAccess(scope); err != nil {
		return err
	}

	c.scopeMu.Lock()
	if c.scope == scope {
		c.scopeMu.Unlock()
		return nil
	}
	if scope == scopeLocalFileRead {
		cancel := c.cancelCommandContext
		c.scope = scopeLocalFileRead
		c.scopeMu.Unlock()
		if cancel != nil {
			cancel()
		}
		c.abortActivePendingWritesForScope("write_stream cancelled: connector scope restricted")
		c.stopManagedProcesses()
		if c.cfg.deviceMode {
			c.deviceRuntimeMu.Lock()
			for _, implementation := range c.runtimeImplementations {
				if codex, ok := implementation.(*codexRuntimeImplementation); ok {
					codex.pause()
				} else {
					implementation.Close()
				}
			}
			c.discoverDeviceRuntimes()
			c.deviceRuntimeMu.Unlock()
		}
		return nil
	}

	ctx, cancel := context.WithCancel(context.Background())
	c.scope = ""
	c.commandContext = ctx
	c.cancelCommandContext = cancel
	c.scopeMu.Unlock()
	if c.cfg.deviceMode && c.externalRuntimeState != nil {
		c.externalRuntimeState.wake()
	}
	return nil
}

func (c *connector) abortActivePendingWritesForScope(reason string) {
	c.connectionMu.Lock()
	session := c.activeConnection
	c.connectionMu.Unlock()
	if session != nil {
		session.abortPendingWritesForScope(reason)
	}
}

func (c *connector) stopManagedProcesses() {
	c.processMu.Lock()
	processes := make([]*managedProcess, 0, len(c.processes))
	for _, process := range c.processes {
		if process.isRunning() {
			processes = append(processes, process)
		}
	}
	c.processMu.Unlock()
	for _, process := range processes {
		killProcessGroup(process.cmd)
	}
}

type cooperativeShutdownRequest struct {
	RunNonce string `json:"runNonce"`
}

// watchShutdownRequest gives a restarted Main a PID-free way to stop the exact
// run it discovered. The request is durable under the run directory and is
// accepted only when its 128-bit nonce matches this process's argv/config
// identity. Recovery still has to observe process absence after this request;
// writing the file is never termination proof by itself.
func watchShutdownRequest(
	ctx context.Context,
	path string,
	runNonce string,
	cancel context.CancelFunc,
) {
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		data, err := os.ReadFile(path)
		if err == nil {
			var request cooperativeShutdownRequest
			if json.Unmarshal(data, &request) == nil && request.RunNonce == runNonce {
				cancel()
				return
			}
		}
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}
	}
}

func (c *connector) runRemote(ctx context.Context) error {
	runCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		select {
		case <-c.fatalSignal:
			cancel()
		case <-runCtx.Done():
		}
	}()
	c.writeStatus("starting", "", nil)
	defer func() {
		if ctx.Err() != nil {
			c.writeStatus("stopped", "", nil)
		}
	}()
	backoff := minReconnectBackoff
	for {
		if fatalErr := c.connectorFatal(); fatalErr != nil {
			return fatalErr
		}
		c.resetRemoteConnected()
		err := c.runRemoteOnce(runCtx)
		if ctx.Err() != nil {
			return ctx.Err()
		}
		if fatalErr := c.connectorFatal(); fatalErr != nil {
			return fatalErr
		}
		if terminalConnectionError(err) {
			return err
		}
		if !c.cfg.reconnect {
			return err
		}
		if c.consumeRemoteConnected() {
			backoff = minReconnectBackoff
		}
		sleepFor := jitterBackoff(backoff)
		if err != nil {
			logf("connection lost: %v", err)
			if isAuthError(err) {
				// A scoped connector is supervised by Electron Main, which owns
				// credential recovery by re-minting and respawning. A revoked or
				// expired credential is therefore terminal here: exiting keeps an
				// orphaned child from living forever behind a dead token,
				// cross-platform and without host process inspection.
				if c.cfg.scope == scopeLocalFileRead {
					c.writeStatus("auth_required", "", err)
					return fmt.Errorf("connector credential rejected for %s scope: %w", scopeLocalFileRead, err)
				}
				c.writeStatus("auth_required", "", err, sleepFor)
				backoff = minReconnectBackoff
			} else {
				c.writeStatus("reconnecting", "", err, sleepFor)
			}
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-c.fatalSignal:
			return c.connectorFatal()
		case <-time.After(sleepFor):
		}
		if backoff < maxReconnectBackoff {
			backoff *= 2
			if backoff > maxReconnectBackoff {
				backoff = maxReconnectBackoff
			}
		}
	}
}

func terminalConnectionError(err error) bool {
	return errors.Is(err, errConnectionWorkersStuck) || isConnectorFatal(err)
}

func (c *connector) runRemoteOnce(ctx context.Context) (resultErr error) {
	c.writeStatus("connecting", c.cfg.server, nil)
	wsURL, err := c.connectURL(c.cfg.server)
	if err != nil {
		return err
	}
	header := http.Header{}
	header.Set("Authorization", "Bearer "+c.cfg.token)
	header.Set(connectorInstanceHeader, c.processInstanceID)

	dialer := websocket.Dialer{HandshakeTimeout: 15 * time.Second}
	ws, resp, err := dialer.DialContext(ctx, wsURL, header)
	if err != nil {
		if resp != nil {
			body, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
			_ = resp.Body.Close()
			if resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden {
				return authError{status: resp.StatusCode, body: string(body)}
			}
			return websocketHandshakeError{status: resp.StatusCode, body: string(body), err: err}
		}
		return err
	}
	writer := newWebSocketWriter(ws)
	session := c.claimConnection(ctx, writer.SendContext, writer.Close)
	session.sendReply = writer.SendContextBeforeWrite
	fatalResult := make(chan error, 1)
	go func() {
		select {
		case fatalErr := <-c.fatalErrors:
			fatalResult <- fatalErr
			writer.Close(fatalErr)
		case <-session.ctx.Done():
		}
	}()
	defer func() {
		select {
		case fatalErr := <-fatalResult:
			resultErr = fatalErr
		default:
		}
		session.close(defaultError(resultErr, errWebSocketClosed))
		c.releaseConnection(session)
		if !session.wait() {
			resultErr = errConnectionWorkersStuck
		}
	}()
	ws.SetReadLimit(maxWebSocketMessageBytes)
	refreshReadDeadline := func() error {
		return ws.SetReadDeadline(time.Now().Add(webSocketReadTimeout))
	}
	if err := refreshReadDeadline(); err != nil {
		return err
	}
	ws.SetPongHandler(func(string) error { return refreshReadDeadline() })

	if err := c.probeAndPublish(ctx, "connect", session.send); err != nil {
		return err
	}
	c.writeStatusMetadataSent(c.cfg.server)

	deactivate := c.activateRuntimeTransport(session.sendCtx)
	defer deactivate()
	runtimeTransport := c.getActiveTransport()

	done := make(chan struct{})
	defer close(done)
	go c.systemInfoLoop(session.send, done, c.cfg.server)

	for {
		var msg message
		if err := ws.ReadJSON(&msg); err != nil {
			return err
		}
		if err := refreshReadDeadline(); err != nil {
			return err
		}
		if !c.connectionActive(session) {
			return errors.New("connection replaced")
		}
		switch msg.Type {
		case "connected":
			connectorRunID := msg.ConnectorRunID
			if connectorRunID != "" {
				if !c.setIdentity(session, connectorRunID, msg.DeviceID, msg.ConnectorID, msg.OwnerUserID, msg.ConnectionGeneration) {
					continue
				}
				c.markRemoteConnected()
				logf("connected: connector_run_id=%s", connectorRunID)
				c.writeStatus("connected", c.cfg.server, nil)
				c.onRuntimeConnected(session.ctx, runtimeTransport)
			}
		case "heartbeat":
			if err := writer.Enqueue(message{Type: "heartbeat"}); err != nil {
				return err
			}
			continue
		case "request":
			if !session.startRequest(msg, nil) {
				if err := writer.Enqueue(overloadRequestError(msg)); err != nil {
					return err
				}
			}
		case "response", "error":
			c.completeRuntimeProxy(msg)
		case "stream":
			if msg.Stream != nil && msg.Stream.Channel == "ack" {
				session.handleStream(msg)
			} else if !session.startStream(msg, nil) {
				session.finishPendingWrite(msg.ID)
				if err := writer.Enqueue(overloadStreamError(msg)); err != nil {
					return err
				}
			}
		}
	}
}

func isAuthError(err error) bool {
	var auth authError
	return errors.As(err, &auth)
}

func (c *connector) connectURL(server string) (string, error) {
	base := strings.TrimRight(server, "/")
	if strings.HasPrefix(base, "http://") {
		base = "ws://" + strings.TrimPrefix(base, "http://")
	}
	if strings.HasPrefix(base, "https://") {
		base = "wss://" + strings.TrimPrefix(base, "https://")
	}
	u, err := url.Parse(base + "/v1/connect")
	if err != nil {
		return "", err
	}
	q := u.Query()
	q.Set("name", c.cfg.name)
	if c.cfg.alias != "" {
		q.Set("alias", c.cfg.alias)
	}
	q.Set("os", runtime.GOOS)
	q.Set("arch", runtime.GOARCH)
	// Presence is intentional even for the existing full value (the empty
	// string): Server registration uses it to fence this connection generation
	// from a predecessor's stale scope projection before first metadata.
	q.Set("scope", c.currentScope())
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func (c *connector) writeStatus(state, server string, err error, reconnectBackoff ...time.Duration) {
	if c.cfg.statusPath == "" {
		return
	}
	c.statusMu.Lock()
	defer c.statusMu.Unlock()

	previous := c.readConnectorStatusLocked()
	server = c.statusServer(server)
	if server == "" {
		server = previous.Server
	}
	now := time.Now().Unix()
	connectorRunID, deviceID, connectorID := c.connectionIdentity()
	status := connectorStatusFile{
		Mode:                    c.cfg.mode(),
		State:                   state,
		Scope:                   c.currentScope(),
		LocalFileIndexVersion:   localFileIndexVersion,
		Server:                  server,
		ConnectorRunID:          connectorRunID,
		DeviceID:                deviceID,
		ConnectorID:             connectorID,
		LastConnected:           previous.LastConnected,
		LastErrorClass:          previous.LastErrorClass,
		LastErrorMessage:        previous.LastErrorMessage,
		ConsecutiveFailures:     previous.ConsecutiveFailures,
		ReconnectBackoffSeconds: previous.ReconnectBackoffSeconds,
		LastMetadataSentAt:      previous.LastMetadataSentAt,
		ComponentRelease:        currentBuildInfo(),
		UpdatedAt:               now,
	}
	if state == "connected" {
		status.LastConnected = now
		status.LastErrorClass = ""
		status.LastErrorMessage = ""
		status.ConsecutiveFailures = 0
		status.ReconnectBackoffSeconds = 0
	}
	if err != nil {
		status.LastErrorClass = classifyConnectorError(err)
		status.LastErrorMessage = err.Error()
		if state != "connected" && state != "stopped" && state != "stopping" {
			status.ConsecutiveFailures = previous.ConsecutiveFailures + 1
		}
	}
	if len(reconnectBackoff) > 0 {
		status.ReconnectBackoffSeconds = durationSeconds(reconnectBackoff[0])
	} else if state == "starting" || state == "minting_token" || state == "connecting" || state == "connected" {
		status.ReconnectBackoffSeconds = 0
	}
	c.writeConnectorStatusLocked(status)
}

func (c *connector) writeStatusMetadataSent(server string) {
	if c.cfg.statusPath == "" {
		return
	}
	c.statusMu.Lock()
	defer c.statusMu.Unlock()

	status := c.readConnectorStatusLocked()
	if status.State == "" {
		return
	}
	status.Mode = c.cfg.mode()
	status.Scope = c.currentScope()
	status.LocalFileIndexVersion = localFileIndexVersion
	if resolvedServer := c.statusServer(server); resolvedServer != "" {
		status.Server = resolvedServer
	}
	status.ConnectorRunID, status.DeviceID, status.ConnectorID = c.connectionIdentity()
	status.LastMetadataSentAt = time.Now().Unix()
	status.ComponentRelease = currentBuildInfo()
	status.UpdatedAt = status.LastMetadataSentAt
	c.writeConnectorStatusLocked(status)
}

func (c *connector) writeStatusLocalRequestError(err error) {
	if c.cfg.statusPath == "" || err == nil {
		return
	}
	c.statusMu.Lock()
	defer c.statusMu.Unlock()

	status := c.readConnectorStatusLocked()
	if status.State == "" {
		return
	}
	status.Mode = c.cfg.mode()
	// Scope is an acknowledgement of successfully published metadata, not a
	// general status snapshot. A request error racing a scope transition must
	// preserve the last acknowledged value until writeStatusMetadataSent.
	status.LocalFileIndexVersion = localFileIndexVersion
	status.Server = c.statusServer(status.Server)
	status.ConnectorRunID, status.DeviceID, status.ConnectorID = c.connectionIdentity()
	status.LastErrorClass = classifyConnectorError(err)
	status.LastErrorMessage = err.Error()
	status.ComponentRelease = currentBuildInfo()
	status.UpdatedAt = time.Now().Unix()
	c.writeConnectorStatusLocked(status)
}

func (c *connector) readConnectorStatusLocked() connectorStatusFile {
	var status connectorStatusFile
	data, err := os.ReadFile(c.cfg.statusPath)
	if err != nil {
		return status
	}
	_ = json.Unmarshal(data, &status)
	return status
}

func (c *connector) writeConnectorStatusLocked(status connectorStatusFile) {
	if mkErr := os.MkdirAll(filepath.Dir(c.cfg.statusPath), 0o755); mkErr != nil {
		return
	}
	tmp := fmt.Sprintf("%s.%d.tmp", c.cfg.statusPath, os.Getpid())
	data, jsonErr := json.MarshalIndent(status, "", "  ")
	if jsonErr != nil {
		return
	}
	if writeErr := os.WriteFile(tmp, append(data, '\n'), 0o600); writeErr != nil {
		return
	}
	_ = os.Chmod(tmp, 0o600)
	_ = os.Rename(tmp, c.cfg.statusPath)
	_ = os.Chmod(c.cfg.statusPath, 0o600)
}

func (c *connector) statusServer(server string) string {
	server = strings.TrimSpace(server)
	if server != "" {
		return server
	}
	return strings.TrimSpace(c.cfg.server)
}

func (c *connector) resetRemoteConnected() {
	c.remoteMu.Lock()
	c.remoteReady = false
	c.remoteMu.Unlock()
}

func (c *connector) markRemoteConnected() {
	c.remoteMu.Lock()
	c.remoteReady = true
	c.remoteMu.Unlock()
}

func (c *connector) consumeRemoteConnected() bool {
	c.remoteMu.Lock()
	defer c.remoteMu.Unlock()
	ready := c.remoteReady
	c.remoteReady = false
	return ready
}

func jitterBackoff(base time.Duration) time.Duration {
	if base <= 0 {
		return minReconnectBackoff
	}
	buf := []byte{0, 0}
	if _, err := rand.Read(buf); err != nil {
		return base
	}
	// 80%..120%, then clamp to the global maximum so large fleets do not
	// reconnect in lockstep while a single connector still has a bounded delay.
	n := int(buf[0])<<8 | int(buf[1])
	factorPermille := 800 + n%401
	delay := base * time.Duration(factorPermille) / 1000
	if delay < minReconnectBackoff {
		delay = minReconnectBackoff
	}
	if delay > maxReconnectBackoff {
		delay = maxReconnectBackoff
	}
	return delay
}

func durationSeconds(d time.Duration) float64 {
	if d <= 0 {
		return 0
	}
	ms := d.Milliseconds()
	if ms <= 0 {
		return 0.001
	}
	return float64(ms) / 1000
}

func classifyConnectorError(err error) string {
	if err == nil {
		return ""
	}
	var auth authError
	if errors.As(err, &auth) {
		return "auth"
	}
	var local localRequestError
	if errors.As(err, &local) {
		return "local_request"
	}
	var handshake websocketHandshakeError
	if errors.As(err, &handshake) {
		if handshake.status >= 500 {
			return "server"
		}
		return "websocket_handshake"
	}
	var dns *net.DNSError
	if errors.As(err, &dns) {
		return "dns"
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return "server"
	}
	message := strings.ToLower(err.Error())
	switch {
	case strings.Contains(message, "no such host"):
		return "dns"
	case strings.Contains(message, "tls") || strings.Contains(message, "certificate"):
		return "tls"
	case strings.Contains(message, "bad handshake") || strings.Contains(message, "websocket"):
		return "websocket_handshake"
	case strings.Contains(message, "connection refused") || strings.Contains(message, "connection reset") || strings.Contains(message, "timeout"):
		return "server"
	case strings.Contains(message, "json") || strings.Contains(message, "protocol"):
		return "protocol"
	default:
		return "unknown"
	}
}

func (c *connector) runStdio(ctx context.Context) error {
	send := newLineSender(os.Stdout)
	session := c.claimConnection(ctx, func(_ context.Context, m message) error { return send(m, nil) }, nil)
	session.sendReply = func(_ context.Context, reply message, beforeWrite func()) error {
		return send(reply, beforeWrite)
	}
	defer func() {
		session.close(errWebSocketClosed)
		c.releaseConnection(session)
		session.wait()
	}()
	deactivate := c.activateRuntimeTransport(session.sendCtx)
	defer deactivate()
	runtimeTransport := c.getActiveTransport()
	inputDone := make(chan error, 1)
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
		for scanner.Scan() {
			line := strings.TrimSpace(scanner.Text())
			if line == "" {
				continue
			}
			var msg message
			if err := json.Unmarshal([]byte(line), &msg); err != nil {
				continue
			}
			switch msg.Type {
			case "connected":
				connectorRunID := msg.ConnectorRunID
				if connectorRunID != "" {
					c.setIdentity(session, connectorRunID, msg.DeviceID, msg.ConnectorID, msg.OwnerUserID, msg.ConnectionGeneration)
					logf("connected (stdio): connector_run_id=%s", connectorRunID)
					c.onRuntimeConnected(session.ctx, runtimeTransport)
				}
			case "heartbeat":
				_ = session.send(message{Type: "heartbeat"})
			case "request":
				if !session.startRequest(msg, nil) {
					_ = session.send(overloadRequestError(msg))
				}
			case "response", "error":
				c.completeRuntimeProxy(msg)
			case "stream":
				if msg.Stream != nil && msg.Stream.Channel == "ack" {
					session.handleStream(msg)
				} else if !session.startStream(msg, nil) {
					session.finishPendingWrite(msg.ID)
					_ = session.send(overloadStreamError(msg))
				}
			}
		}
		inputDone <- scanner.Err()
	}()

	// Native readiness probes may take seconds. Start consuming stdin first so
	// the carrier keeps receiving heartbeat echoes while the initial cache is built.
	if err := c.probeAndPublish(ctx, "connect", session.send); err != nil {
		return err
	}
	c.writeStatusMetadataSent("")

	done := make(chan struct{})
	defer close(done)
	go c.systemInfoLoop(session.send, done, "")
	select {
	case err := <-inputDone:
		return err
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (c *connector) runVMServer(ctx context.Context) error {
	if err := c.ensureWorkspaceMarker(); err != nil {
		return err
	}

	server := &http.Server{Addr: c.cfg.listen, Handler: c.vmHTTPHandler(ctx)}
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = server.Shutdown(shutdownCtx)
	}()
	serverResult := make(chan error, 1)
	go func() { serverResult <- server.ListenAndServe() }()
	select {
	case err := <-serverResult:
		return err
	case err := <-c.fatalErrors:
		_ = server.Close()
		<-serverResult
		return err
	}
}

func (c *connector) vmHTTPHandler(ctx context.Context) http.Handler {
	_ = c.ensureWorkspaceMarker()
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", c.handleVMHealth)
	mux.HandleFunc("/readyz", c.handleVMReady)
	mux.HandleFunc("/connect", c.handleVMConnect(ctx))
	mux.HandleFunc("/archive", c.handleVMArchive)
	mux.HandleFunc("/archive/export", c.handleDurableArchiveExport)
	return mux
}

func (c *connector) handleVMHealth(w http.ResponseWriter, _ *http.Request) {
	writeJSONResponse(w, http.StatusOK, map[string]any{"ok": true})
}

func (c *connector) handleVMReady(w http.ResponseWriter, _ *http.Request) {
	writeJSONResponse(w, http.StatusOK, map[string]any{
		"ok":                       true,
		"ready":                    true,
		"connector_version":        connectorVersion(),
		"connector_build_revision": connectorBuildRevision,
		"boot_id":                  c.bootID(),
		"workspace_marker":         c.workspaceMarkerPath(),
		"workspace_marked":         fileExists(c.workspaceMarkerPath()),
		"workspace_dirty":          fileExists(c.dirtyMarkerPath()),
		"env_message_version":      "json-v1",
	})
}

// Set at image build time. This is release provenance, not a security signature.
var connectorBuildRevision = "dev"

func (c *connector) handleVMConnect(ctx context.Context) http.HandlerFunc {
	upgrader := websocket.Upgrader{CheckOrigin: func(_ *http.Request) bool { return true }}
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		c.serveVMWebSocket(ctx, ws)
	}
}

func (c *connector) serveVMWebSocket(ctx context.Context, ws *websocket.Conn) {
	writer := newWebSocketWriter(ws)
	session := c.claimConnection(ctx, writer.SendContext, writer.Close)
	session.sendReply = writer.SendContextBeforeWrite
	defer func() {
		session.close(errWebSocketClosed)
		c.releaseConnection(session)
		if !session.wait() {
			c.reportFatal(errConnectionWorkersStuck)
		}
	}()
	ws.SetReadLimit(maxWebSocketMessageBytes)
	refreshReadDeadline := func() error {
		return ws.SetReadDeadline(time.Now().Add(webSocketReadTimeout))
	}
	if err := refreshReadDeadline(); err != nil {
		return
	}
	ws.SetPongHandler(func(string) error { return refreshReadDeadline() })
	if err := c.probeAndPublish(ctx, "connect", session.send); err != nil {
		return
	}
	deactivate := c.activateRuntimeTransport(session.sendCtx)
	defer deactivate()
	runtimeTransport := c.getActiveTransport()

	done := make(chan struct{})
	defer close(done)
	go c.systemInfoLoop(session.send, done, "")

	for {
		var msg message
		if err := ws.ReadJSON(&msg); err != nil {
			break
		}
		if err := refreshReadDeadline(); err != nil {
			break
		}
		if !c.connectionActive(session) {
			break
		}
		switch msg.Type {
		case "connected":
			connectorRunID := msg.ConnectorRunID
			if connectorRunID != "" {
				if !c.setIdentity(session, connectorRunID, msg.DeviceID, msg.ConnectorID, msg.OwnerUserID, msg.ConnectionGeneration) {
					continue
				}
				logf("connected (runtime-agent): connector_run_id=%s", connectorRunID)
				c.onRuntimeConnected(session.ctx, runtimeTransport)
				c.startRestoredDependencyInstall()
			}
		case "heartbeat":
			if err := writer.Enqueue(message{Type: "heartbeat"}); err != nil {
				return
			}
		case "request":
			if !session.startRequest(msg, c.markWorkspaceDirty) {
				if err := writer.Enqueue(overloadRequestError(msg)); err != nil {
					return
				}
			}
		case "response", "error":
			c.completeRuntimeProxy(msg)
		case "stream":
			if msg.Stream != nil && msg.Stream.Channel == "ack" {
				session.handleStream(msg)
			} else if !session.startStream(msg, c.markWorkspaceDirty) {
				session.finishPendingWrite(msg.ID)
				if err := writer.Enqueue(overloadStreamError(msg)); err != nil {
					return
				}
			}
		}
	}
}

func (c *connector) handleVMArchive(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodPost {
		c.handleProviderMigrationImport(w, r)
		return
	}
	var state *externalRuntimeState
	restoreOperation := r.URL.Query().Get("operation")
	restoreReceipt := filepath.Join(c.runtimeStateRoot(), "provider-import", "archive-restore.json")
	managed := strings.TrimSpace(os.Getenv("SALIX_MANAGED_RUNTIME_ROOT")) != ""
	if managed {
		c.cloudRuntimeMu.Lock()
		defer c.cloudRuntimeMu.Unlock()
		c.expireCloudRuntimeQuiesce()
		state = c.externalRuntimeState
		if r.Method == http.MethodGet && (!c.cloudRuntimeQuiesced || c.cloudRuntimeReleased) {
			http.Error(w, "managed archive requires quiescence", http.StatusConflict)
			return
		}
		if r.Method == http.MethodPut {
			if restoreOperation != "" {
				if !cloudMigrationOperation.MatchString(restoreOperation) {
					http.Error(w, "invalid restore operation", 400)
					return
				}
				raw, err := os.ReadFile(restoreReceipt)
				if err == nil {
					var receipt cloudProviderMigration
					if json.Unmarshal(raw, &receipt) == nil && receipt.Operation == restoreOperation && receipt.Phase == "restored" {
						writeJSONResponse(w, 200, map[string]any{"ok": true})
						return
					}
					http.Error(w, "restore conflict or partial restore requires fresh target", 409)
					return
				}
				if !os.IsNotExist(err) {
					http.Error(w, "restore receipt unavailable", 500)
					return
				}
			}
			c.connectionMu.Lock()
			defer c.connectionMu.Unlock()
			if c.activeConnection != nil || !state.emptyArchiveTarget() {
				http.Error(w, "restore requires an unused connector", http.StatusConflict)
				return
			}
		}
	}
	switch r.Method {
	case http.MethodGet:
		// Complete the bounded archive before acknowledging it. A late tar error
		// must never produce a successful checkpoint followed by resource deletion.
		archive, err := os.CreateTemp("", "salix-archive-*")
		if err != nil {
			http.Error(w, "archive storage unavailable", 500)
			return
		}
		defer os.Remove(archive.Name())
		defer archive.Close()
		err = writeTarGzState(&archiveLimitWriter{writer: archive, remaining: maxArchiveBytes}, c.root, state)
		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		if _, err = archive.Seek(0, io.SeekStart); err != nil {
			http.Error(w, err.Error(), 500)
			return
		}
		w.Header().Set("Content-Type", "application/gzip")
		w.Header().Set("X-Salix-Archive-Format", "tar.gz")
		_, _ = io.Copy(w, archive)
	case http.MethodPut:
		if managed && restoreOperation != "" {
			if err := writeProviderMigration(restoreReceipt, cloudProviderMigration{Operation: restoreOperation, Phase: "restoring"}); err != nil {
				http.Error(w, "restore receipt unavailable", 500)
				return
			}
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxArchiveBytes)
		if err := restoreTarGzState(r.Body, c.root, state); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if managed && restoreOperation != "" {
			if err := syncDirectory(c.root); err != nil {
				http.Error(w, "restore sync failed", 500)
				return
			}
			if err := writeProviderMigration(restoreReceipt, cloudProviderMigration{Operation: restoreOperation, Phase: "restored"}); err != nil {
				http.Error(w, "restore receipt unavailable", 500)
				return
			}
		}
		c.markWorkspaceDirty()
		writeJSONResponse(w, http.StatusOK, map[string]any{"ok": true})
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

type archiveLimitWriter struct {
	writer    io.Writer
	remaining int64
}

func (w *archiveLimitWriter) Write(data []byte) (int, error) {
	if int64(len(data)) > w.remaining {
		return 0, errors.New("archive exceeds compressed size limit")
	}
	n, err := w.writer.Write(data)
	w.remaining -= int64(n)
	return n, err
}

func (c *connector) ensureWorkspaceMarker() error {
	marker := c.workspaceMarkerPath()
	if err := os.MkdirAll(filepath.Dir(marker), 0o755); err != nil {
		return err
	}
	if fileExists(marker) {
		return nil
	}
	return os.WriteFile(marker, []byte(`{"kind":"salix-vm-workspace"}`+"\n"), 0o644)
}

func (c *connector) workspaceMarkerPath() string {
	return filepath.Join(c.root, ".salix-vm-workspace.json")
}

func (c *connector) dirtyMarkerPath() string {
	return filepath.Join(c.root, ".salix-vm-dirty")
}

func (c *connector) bootID() string {
	if id := os.Getenv("SALIX_VM_BOOT_ID"); id != "" {
		return id
	}
	return hostname() + "-" + strconv.Itoa(os.Getpid())
}

func (c *connector) markWorkspaceDirty() {
	_ = os.WriteFile(c.dirtyMarkerPath(), []byte(strconv.FormatInt(time.Now().UnixMilli(), 10)+"\n"), 0o644)
}

func writeJSONResponse(w http.ResponseWriter, status int, body map[string]any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeTarGz(w io.Writer, root string) error { return writeTarGzState(w, root, nil) }

func writeTarGzState(w io.Writer, root string, state *externalRuntimeState) error {
	return writeTarGzTrees(context.Background(), w, []archiveTree{{root, "."}}, state, maxArchiveFile)
}

// Every source root and destination prefix is supplied by its archive owner.
// The migration uses this same codec with an explicit, reviewed scope.
type archiveTree struct{ source, prefix string }

func writeTarGzTrees(ctx context.Context, w io.Writer, trees []archiveTree, state *externalRuntimeState, fileLimit int64) error {
	return writeTarTrees(ctx, w, trees, state, fileLimit, "gzip")
}

func writeTarZstTrees(ctx context.Context, w io.Writer, trees []archiveTree, state *externalRuntimeState, fileLimit int64) error {
	return writeTarTrees(ctx, w, trees, state, fileLimit, "zstd")
}

func writeTarTrees(ctx context.Context, w io.Writer, trees []archiveTree, state *externalRuntimeState, fileLimit int64, codec string) error {
	var err error
	for i := range trees {
		trees[i].source, err = filepath.EvalSymlinks(trees[i].source)
		if err != nil {
			return err
		}
	}
	snapshotPath := ""
	stateRoot := ""
	if state != nil {
		stateRoot, err = filepath.EvalSymlinks(state.connector.runtimeStateRoot())
		if err != nil {
			return err
		}
		snapshotPath, err = filepath.EvalSymlinks(state.db.Path())
		if err != nil {
			return err
		}
	}
	var compressor io.WriteCloser
	switch codec {
	case "gzip":
		compressor = gzip.NewWriter(w)
	case "zstd":
		compressor, err = zstd.NewWriter(w, zstd.WithEncoderLevel(zstd.SpeedFastest), zstd.WithEncoderConcurrency(2))
		if err != nil {
			return err
		}
	default:
		return errors.New("unsupported archive codec")
	}
	defer compressor.Close()
	tw := tar.NewWriter(&contextArchiveWriter{ctx: ctx, writer: compressor})
	defer tw.Close()

	seen := map[string]bool{}
	var expanded int64
	for _, tree := range trees {
		root := tree.source
		walkErr := filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
			if err := ctx.Err(); err != nil {
				return err
			}
			if err != nil {
				return err
			}
			if path == root {
				return nil
			}
			rel, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			rel = filepath.ToSlash(rel)
			if rel == "." || strings.HasPrefix(rel, "../") || rel == ".." {
				return nil
			}
			if state != nil && filepath.Clean(path) == snapshotPath {
				return nil
			}
			if state != nil && (path == filepath.Join(stateRoot, "provider-import") || path == filepath.Join(stateRoot, "provider-migration") || path == filepath.Join(stateRoot, "provider-migration.json") || path == filepath.Join(stateRoot, "durable-archive")) {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if isExternalRuntimeStatePath(rel) {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			if skipRegenerableArchiveCache(filepath.ToSlash(filepath.Join(tree.prefix, rel)), path, d) {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
			info, err := d.Info()
			if err != nil {
				return err
			}
			var archiveContent []byte
			if state != nil && filepath.Clean(path) == state.connector.dependencyManifestPath() {
				archiveContent, err = state.connector.archivedDependencyManifest()
				if err != nil {
					return err
				}
				infoSize := int64(len(archiveContent))
				if infoSize > fileLimit {
					return errors.New("dependency declaration archive too large")
				}
			}
			if info.Mode().IsRegular() {
				actualSize := info.Size()
				if archiveContent != nil {
					actualSize = int64(len(archiveContent))
				}
				if actualSize > migrationByteLimit-expanded {
					return errors.New("archive expanded size exceeds limit")
				}
				expanded += actualSize
			}
			link := ""
			if info.Mode()&os.ModeSymlink != 0 {
				resolved, err := filepath.EvalSymlinks(path)
				if err != nil {
					return err
				}
				destination, err := archiveTreeDestination(trees, resolved)
				if err != nil {
					return err
				}
				link, err = filepath.Rel(filepath.Dir(filepath.Join(tree.prefix, rel)), destination)
				if err != nil {
					return err
				}
			} else if !info.IsDir() && !info.Mode().IsRegular() {
				return fmt.Errorf("unsupported archive entry: %s", rel)
			}
			if info.Mode().IsRegular() && info.Size() > fileLimit {
				return fmt.Errorf("archive file too large: %s", rel)
			}
			header, err := tar.FileInfoHeader(info, filepath.ToSlash(link))
			if err != nil {
				return err
			}
			header.Name = filepath.ToSlash(filepath.Join(tree.prefix, rel))
			if archiveContent != nil {
				header.Size = int64(len(archiveContent))
			}
			if seen[header.Name] {
				return errors.New("selected roots contain colliding archive paths")
			}
			seen[header.Name] = true
			if err := tw.WriteHeader(header); err != nil {
				return err
			}
			if d.IsDir() || link != "" {
				return nil
			}
			if archiveContent != nil {
				_, err := tw.Write(archiveContent)
				return err
			}
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			copyErr := copyMigrationFile(ctx, tw, f, info.Size())
			closeErr := f.Close()
			if copyErr != nil {
				return copyErr
			}
			return closeErr
		})
		if walkErr != nil {
			return walkErr
		}
	}
	if state != nil {
		if err := state.writeArchiveSnapshot(tw, migrationByteLimit-expanded); err != nil {
			return err
		}
	}
	if err := tw.Close(); err != nil {
		return err
	}
	return compressor.Close()
}

type contextArchiveWriter struct {
	ctx    context.Context
	writer io.Writer
}

func (w *contextArchiveWriter) Write(p []byte) (int, error) {
	if err := w.ctx.Err(); err != nil {
		return 0, err
	}
	return w.writer.Write(p)
}

func archiveTreeDestination(trees []archiveTree, path string) (string, error) {
	for _, tree := range trees {
		rel, err := filepath.Rel(tree.source, path)
		if err == nil && rel != ".." && !strings.HasPrefix(rel, "../") {
			return filepath.Join(tree.prefix, rel), nil
		}
	}
	return "", errors.New("archive path is outside the selected source roots")
}

func restoreTarGz(r io.Reader, root string) error { return restoreTarGzState(r, root, nil) }

func restoreTarGzState(r io.Reader, root string, state *externalRuntimeState) error {
	return restoreTarGzStateLimit(r, root, state, maxArchiveFile)
}

func restoreTarGzStateLimit(r io.Reader, root string, state *externalRuntimeState, fileLimit int64) error {
	return restoreTarStateLimit(r, root, state, fileLimit, "gzip")
}

func restoreTarZstStateLimit(r io.Reader, root string, state *externalRuntimeState, fileLimit int64) error {
	return restoreTarStateLimit(r, root, state, fileLimit, "zstd")
}

func restoreTarStateLimit(r io.Reader, root string, state *externalRuntimeState, fileLimit int64, codec string) error {
	var canonicalErr error
	root, canonicalErr = filepath.EvalSymlinks(root)
	if canonicalErr != nil {
		return canonicalErr
	}
	snapshotPath := ""
	if state != nil {
		snapshotPath, canonicalErr = filepath.EvalSymlinks(state.db.Path())
		if canonicalErr != nil {
			return canonicalErr
		}
	}
	var snapshot *os.File
	defer func() {
		if snapshot != nil {
			snapshot.Close()
			os.Remove(snapshot.Name())
		}
	}()
	var stream io.Reader
	switch codec {
	case "gzip":
		gz, err := gzip.NewReader(r)
		if err != nil {
			return err
		}
		defer gz.Close()
		stream = gz
	case "zstd":
		decoder, err := zstd.NewReader(r, zstd.WithDecoderConcurrency(2))
		if err != nil {
			return err
		}
		defer decoder.Close()
		stream = decoder
	default:
		return errors.New("unsupported archive codec")
	}
	tr := tar.NewReader(stream)
	links := []tar.Header{}
	directories := []tar.Header{}
	changedDirectories := make(map[string]struct{})
	var expanded int64
	for {
		header, err := tr.Next()
		if errors.Is(err, io.EOF) {
			for _, link := range links {
				target, err := safeArchiveTarget(root, link.Name)
				if err != nil {
					return err
				}
				resolved, err := safeArchiveTarget(root, filepath.Join(filepath.Dir(link.Name), link.Linkname))
				if err != nil || filepath.IsAbs(link.Linkname) {
					return fmt.Errorf("archive link escapes workspace: %s", link.Name)
				}
				if err := rejectSymlinkPath(root, resolved); err != nil {
					return err
				}
				if _, err := os.Stat(resolved); err != nil {
					return err
				}
				if err := ensureSafeArchiveParent(root, target); err != nil {
					return err
				}
				if err := os.Symlink(link.Linkname, target); err != nil {
					return err
				}
				changedDirectories[filepath.Dir(target)] = struct{}{}
			}
			for i := len(directories) - 1; i >= 0; i-- {
				directory := directories[i]
				target, err := safeArchiveTarget(root, directory.Name)
				if err != nil {
					return err
				}
				if err := rejectSymlinkPath(root, target); err != nil {
					return err
				}
				if err := os.Chmod(target, os.FileMode(directory.Mode)&0777); err != nil {
					return err
				}
			}
			if err := syncRestoredDirectories(changedDirectories); err != nil {
				return err
			}
			if state != nil && snapshot != nil {
				if err := snapshot.Close(); err != nil {
					return err
				}
				return state.restoreArchiveSnapshot(snapshot.Name())
			}
			return nil
		}
		if err != nil {
			return err
		}
		if header.Size < 0 || header.Size > migrationByteLimit-expanded {
			return errors.New("archive expanded size limit exceeded")
		}
		expanded += header.Size
		target, err := safeArchiveTarget(root, header.Name)
		if err != nil {
			return err
		}
		rel, _ := filepath.Rel(root, target)
		if state != nil && filepath.ToSlash(rel) == externalRuntimeStateRelativePath {
			if snapshot != nil || header.Typeflag != tar.TypeReg || header.Size < 0 || header.Size > fileLimit {
				return errors.New("invalid managed state snapshot")
			}
			snapshot, err = os.CreateTemp("", "salix-state-*")
			if err != nil {
				return err
			}
			if _, err := io.CopyN(snapshot, tr, header.Size); err != nil {
				return err
			}
			continue
		}
		if state != nil && filepath.Clean(target) == snapshotPath {
			return errors.New("archive cannot overwrite live runtime state")
		}
		if isExternalRuntimeStatePath(rel) {
			continue
		}
		switch header.Typeflag {
		case tar.TypeDir:
			if err := rejectSymlinkPath(root, target); err != nil {
				return err
			}
			if err := os.MkdirAll(target, 0o700); err != nil {
				return err
			}
			directories = append(directories, *header)
		case tar.TypeReg, tar.TypeRegA:
			if header.Size > fileLimit {
				return fmt.Errorf("archive file too large: %s", header.Name)
			}
			if err := ensureSafeArchiveParent(root, target); err != nil {
				return err
			}
			if err := rejectExistingSymlink(target); err != nil {
				return err
			}
			f, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, os.FileMode(header.Mode)&0o777)
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, io.LimitReader(tr, fileLimit+1)); err != nil {
				_ = f.Close()
				return err
			}
			if header.Size < 0 {
				_ = f.Close()
				return fmt.Errorf("archive file has invalid size: %s", header.Name)
			}
			if err := f.Chmod(os.FileMode(header.Mode) & 0777); err != nil {
				_ = f.Close()
				return err
			}
			if err := f.Sync(); err != nil {
				_ = f.Close()
				return err
			}
			if err := f.Close(); err != nil {
				return err
			}
			changedDirectories[filepath.Dir(target)] = struct{}{}
		case tar.TypeSymlink:
			links = append(links, *header)
		case tar.TypeLink:
			return fmt.Errorf("archive hard links are not supported: %s", header.Name)
		default:
			return fmt.Errorf("unsupported archive entry: %s", header.Name)
		}
	}
}

func syncRestoredDirectories(changed map[string]struct{}) error {
	directories := make([]string, 0, len(changed))
	for directory := range changed {
		directories = append(directories, directory)
	}
	sort.Slice(directories, func(i, j int) bool {
		return len(directories[i]) > len(directories[j])
	})
	for _, directory := range directories {
		if err := syncDirectory(directory); err != nil {
			return err
		}
	}
	return nil
}

func isExternalRuntimeStatePath(path string) bool {
	path = strings.ToLower(filepath.ToSlash(filepath.Clean(path)))
	return path == externalRuntimeStateRelativePath || path == "external-runtime/active" ||
		strings.HasPrefix(path, "external-runtime/active/")
}

func skipRegenerableArchiveCache(path, sourcePath string, entry os.DirEntry) bool {
	path = strings.TrimPrefix(filepath.ToSlash(filepath.Clean(path)), "./")
	const home = ".salix/sprite-home/"
	const connectorHome = home + ".local/share/salix/connector-home/"
	for _, root := range []string{home, connectorHome} {
		if relative, found := strings.CutPrefix(path, root); found {
			if entry.IsDir() && archiveHomeCacheDirs[relative] {
				return true
			}
			if !entry.IsDir() && relative == ".hex/cache.ets" {
				return true
			}
		}
	}
	if !entry.IsDir() {
		return false
	}
	relative, found := strings.CutPrefix(path, connectorHome+".comma/workspaces/")
	if !found {
		return false
	}
	parts := strings.Split(relative, "/")
	if len(parts) < 2 {
		return false
	}
	for _, part := range parts[1:] {
		if part == ".git" {
			return false
		}
	}
	// Installation environments may contain local edits or user files.
	switch entry.Name() {
	case ".tox", ".nox", ".pixi", "__pypackages__":
		return false
	default:
		return workspaceArchiveSkipDirs[entry.Name()]
	}
}

var archiveHomeCacheDirs = map[string]bool{
	".cache": true, ".ccache": true, ".npm/_cacache": true,
	".cargo/registry/cache": true, ".cargo/registry/src": true, ".cargo/git/checkouts": true,
	".gradle/caches": true, ".gradle/daemon": true, ".gradle/wrapper/dists": true,
	".android/cache": true, ".android/build-cache": true,
	".m2/repository": true, ".ivy2/cache": true, ".sbt/boot": true,
	".hex/packages": true, ".rebar3/cache": true,
	".yarn/cache": true, ".yarn/berry/cache": true, ".pnpm-store": true,
	".local/share/pnpm/store": true, "go/pkg/mod": true, ".nuget/packages": true,
	".pub-cache": true, "Library/Caches": true,
	"Library/Developer/Xcode/DerivedData": true,
}

func safeArchiveTarget(root, name string) (string, error) {
	clean := filepath.Clean(filepath.FromSlash(name))
	if clean == "." || strings.HasPrefix(clean, ".."+string(filepath.Separator)) || clean == ".." || filepath.IsAbs(clean) {
		return "", fmt.Errorf("archive path escapes workspace: %s", name)
	}
	target := filepath.Join(root, clean)
	rel, err := filepath.Rel(root, target)
	if err != nil {
		return "", err
	}
	if strings.HasPrefix(rel, ".."+string(filepath.Separator)) || rel == ".." {
		return "", fmt.Errorf("archive path escapes workspace: %s", name)
	}
	return target, nil
}

func ensureSafeArchiveParent(root, target string) error {
	parent := filepath.Dir(target)
	rel, err := filepath.Rel(root, parent)
	if err != nil {
		return err
	}
	if rel == "." {
		return nil
	}
	current := root
	for _, part := range strings.Split(rel, string(filepath.Separator)) {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		switch {
		case err == nil:
			if info.Mode()&os.ModeSymlink != 0 {
				return fmt.Errorf("archive path crosses symlink: %s", current)
			}
			if !info.IsDir() {
				return fmt.Errorf("archive path parent is not a directory: %s", current)
			}
		case errors.Is(err, os.ErrNotExist):
			if err := os.Mkdir(current, 0o755); err != nil && !errors.Is(err, os.ErrExist) {
				return err
			}
			if err := rejectExistingSymlink(current); err != nil {
				return err
			}
		default:
			return err
		}
	}
	return nil
}

func rejectSymlinkPath(root, target string) error {
	if err := ensureSafeArchiveParent(root, target); err != nil {
		return err
	}
	return rejectExistingSymlink(target)
}

func rejectExistingSymlink(path string) error {
	info, err := os.Lstat(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("archive path crosses symlink: %s", path)
	}
	return nil
}

func fileExists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func connectorVersion() string {
	if v := os.Getenv("SALIX_CONNECTOR_VERSION"); v != "" {
		return v
	}
	return "dev"
}

func newLineSender(w io.Writer) func(message, func()) error {
	var mu sync.Mutex
	enc := json.NewEncoder(w)
	return func(m message, beforeWrite func()) error {
		mu.Lock()
		defer mu.Unlock()
		if beforeWrite != nil {
			beforeWrite()
		}
		return enc.Encode(m)
	}
}

func (c *connector) metadata() message {
	return c.metadataWithRuntimeProbeEvidence(nil)
}

func (c *connector) metadataWithRuntimeProbeEvidence(probed []map[string]any) message {
	emptySkills := []any{}
	build := currentBuildInfo()

	if c.currentScope() == scopeLocalFileRead {
		// A scoped connector claims only what its dispatch gate can serve.
		// It must never advertise exec, processes, runtimes, or computer use,
		// so the server never treats this device as a command environment.
		capabilities := map[string]any{
			"scope":                    scopeLocalFileRead,
			"persistent_processes":     false,
			"computer_use_tool":        false,
			"host_access_required":     false,
			"execution_boundary":       "local-file-read-only",
			"runtime_probe":            false,
			"meeting_runtime":          false,
			"local_file_import_v1":     c.localFileImportAvailable(),
			"local_file_index_version": localFileIndexVersion,
			"component_versions": map[string]any{
				componentName: build.ReleaseID,
			},
			"component_releases": map[string]any{
				componentName: build,
			},
		}
		if c.cfg.deviceMode {
			capabilities["agent_runtimes"] = c.deviceRuntimeObservations()
			capabilities["device_access"] = true
		}
		return message{
			Type:            "metadata",
			Capabilities:    capabilities,
			Skills:          &emptySkills,
			SystemInfo:      c.deviceSystemInfo(),
			ConnectorHealth: c.connectorHealth(),
		}
	}

	agentRuntimes := []map[string]any{}
	if c.externalRuntimesEnabled() {
		agentRuntimes = c.runtimeInventory.snapshot()
		for _, entry := range agentRuntimes {
			c.projectManagedRuntimeReadiness(entry)
		}
		attachRuntimeProbeEvidence(agentRuntimes, probed)
		c.externalRuntimeState.attachRuntimeSessionSnapshots(agentRuntimes)
		agentRuntimes = append(agentRuntimes, c.detectMeetingRuntime()...)
	}
	capabilities := map[string]any{
		"scope":                    c.currentScope(),
		"persistent_processes":     true,
		"computer_use_tool":        c.computerUseAvailable(),
		"android_device_tool":      c.android.available(),
		"host_access_required":     false,
		"execution_boundary":       "connector-direct",
		"runtime_probe":            c.externalRuntimesEnabled(),
		"meeting_runtime":          c.externalRuntimesEnabled() && meetingRuntimeConfigured(c.cfg),
		"local_file_import_v1":     c.localFileImportAvailable(),
		"local_file_index_version": localFileIndexVersion,
		"component_versions": map[string]any{
			componentName: build.ReleaseID,
		},
		"component_releases": map[string]any{
			componentName: build,
		},
	}
	if c.android.configured() {
		capabilities["android"] = c.android.metadata()
	}
	if c.externalRuntimesEnabled() {
		capabilities["agent_runtimes"] = agentRuntimes
	}
	if c.cfg.deviceMode {
		capabilities["device_access"] = true
	}
	if runtimeAuthAvailable(agentRuntimes) {
		capabilities["runtime_auth_v1"] = true
	}
	return message{
		Type:            "metadata",
		Capabilities:    capabilities,
		Skills:          &emptySkills,
		SystemInfo:      c.deviceSystemInfo(),
		ConnectorHealth: c.connectorHealth(),
	}
}

func (c *connector) localFileImportAvailable() bool {
	return c.cfg.localFileIndexRoot != ""
}

func attachRuntimeProbeEvidence(runtimes, probed []map[string]any) {
	evidence := map[string]map[string]any{}
	for _, runtime := range probed {
		if _, ok := runtime[runtimeProbeFrameEvidence].(*runtimeProbePublication); ok {
			evidence[runtimeObservationKey(runtime)] = runtime
		}
	}
	for _, runtime := range runtimes {
		if observed := evidence[runtimeObservationKey(runtime)]; observed != nil {
			runtime["probe_trigger"] = observed["probe_trigger"]
			runtime["probe_duration_ms"] = observed["probe_duration_ms"]
		}
	}
}

func (c *connector) publishRuntimeProbeMetadata(
	ctx context.Context,
	send func(message) error,
	probed []map[string]any,
) error {
	claimed := make([]map[string]any, 0, len(probed))
	claimedPublications := map[*runtimeProbePublication]struct{}{}
	waiting := map[*runtimeProbePublication]struct{}{}
	for _, runtime := range probed {
		publication, ok := runtime[runtimeProbeFrameEvidence].(*runtimeProbePublication)
		if !ok {
			continue
		}
		if publication.claimed.CompareAndSwap(false, true) {
			claimed = append(claimed, runtime)
			claimedPublications[publication] = struct{}{}
		} else {
			waiting[publication] = struct{}{}
		}
	}

	if len(claimedPublications) == 0 && len(waiting) == 0 {
		return send(c.metadata())
	}
	if len(claimedPublications) > 0 {
		err := send(c.metadataWithRuntimeProbeEvidence(claimed))
		for publication := range claimedPublications {
			publication.complete(err)
		}
		if err != nil {
			return err
		}
	}
	for publication := range waiting {
		if err := publication.wait(ctx); err != nil {
			return err
		}
	}
	return nil
}

func (c *connector) publishCachedMetadata() error {
	c.connectionMu.Lock()
	session := c.activeConnection
	c.connectionMu.Unlock()
	if session == nil {
		return errors.New("connector metadata transport is unavailable")
	}
	if err := session.send(c.metadata()); err != nil {
		logf("publish cached connector metadata failed: %v", err)
		return err
	}
	return nil
}

// systemInfoLoop periodically publishes the current host observation through
// the same metadata path as connect. The timer must not run the full runtime
// inventory probe: that work can start external processes and exceed the
// system-info interval. Retry/close semantics are checked by
// tla/connector/PeriodicSystemInfoRetry.tla.
func (c *connector) systemInfoLoop(send func(message) error, done <-chan struct{}, server string) {
	c.systemInfoLoopWithPublish(
		func() error {
			return c.publishPeriodicSystemInfo(send)
		},
		done,
		server,
	)
}

func (c *connector) systemInfoLoopWithPublish(publish func() error, done <-chan struct{}, server string) {
	if c.cfg.systemInfoInterval <= 0 {
		return
	}
	ticker := time.NewTicker(c.cfg.systemInfoInterval)
	defer ticker.Stop()
	for {
		select {
		case <-done:
			return
		case <-ticker.C:
			if err := publish(); err != nil {
				logf("periodic system info publish failed; retrying: %v", err)
				continue
			}
			c.writeStatusMetadataSent(server)
		}
	}
}

func (c *connector) publishPeriodicSystemInfo(send func(message) error) error {
	return send(c.metadata())
}

func (c *connector) probeAndPublish(ctx context.Context, trigger string, send func(message) error) error {
	// A scoped connector must not discover or probe agent runtimes at all —
	// probing can launch runtime processes (e.g. a Codex app-server), which a
	// read_ref-only runtime has no authority to do. Publish the minimal
	// scoped metadata instead.
	if c.currentScope() == scopeLocalFileRead || !c.externalRuntimesEnabled() {
		c.discoverDeviceRuntimes()
		return send(c.metadata())
	}
	runtimes, err := c.runtimeInventory.probe(ctx, "", "", trigger)
	if err != nil {
		return err
	}
	return c.publishRuntimeProbeMetadata(ctx, send, runtimes)
}

func (c *connector) methodRuntimeProbe(
	ctx context.Context,
	session *connectionSession,
	params map[string]any,
) (map[string]any, error) {
	provider := strings.TrimSpace(stringParam(params, "provider"))
	identityMaterial := strings.TrimSpace(stringParam(params, "identity_material"))
	if provider != "" && provider != "codex" && provider != "pi" && provider != "kimi" && provider != "claude" {
		return nil, errors.New("unsupported runtime provider")
	}
	runtimes, err := c.runtimeInventory.probe(ctx, provider, identityMaterial, "operator")
	if err != nil {
		return nil, err
	}
	if err := c.publishRuntimeProbeMetadata(ctx, session.send, runtimes); err != nil {
		return nil, err
	}
	summaries := make([]map[string]any, 0, len(runtimes))
	for _, runtime := range runtimes {
		summaries = append(summaries, mapTake(runtime,
			"provider", "identity_material", "model", "model_provider", "reasoning_effort",
			"version", "version_detected", "auth_ready",
			"auth",
			"native_server_startable", "ready", "status", "readiness_issue", "readiness_message",
			"readiness_checked_at", "readiness_valid_until", "probe_trigger", "probe_duration_ms",
		))
	}
	return map[string]any{"runtimes": summaries}, nil
}

func mapTake(source map[string]any, keys ...string) map[string]any {
	result := make(map[string]any, len(keys))
	for _, key := range keys {
		if value, ok := source[key]; ok && value != nil && value != "" {
			result[key] = value
		}
	}
	return result
}

func (c *connector) connectorHealth() map[string]any {
	c.processMu.Lock()
	managedProcesses := len(c.processes)
	c.processMu.Unlock()
	resumable, recoverable, inputBatches, runtimeEvents := c.externalRuntimeState.healthCounts()
	settlementActionRequired, oldestSettlementSeconds :=
		c.externalRuntimeState.executionBudgetHealth(time.Now())
	hostOrphans, hostOrphansActionRequired := c.externalRuntimeState.hostOrphanBudgetHealth()
	return map[string]any{
		"schema_version":                       1,
		"observed_at":                          time.Now().UnixMilli(),
		"process_started_at":                   c.processStartedAt,
		"request_inflight":                     len(c.requestSlots),
		"request_capacity":                     cap(c.requestSlots),
		"runtime_proxy_inflight":               len(c.runtimeProxySlots),
		"runtime_proxy_capacity":               cap(c.runtimeProxySlots),
		"managed_processes":                    managedProcesses,
		"resumable_runtime_sessions":           resumable,
		"recoverable_runtime_sessions":         recoverable,
		"pending_input_batches":                inputBatches,
		"pending_runtime_events":               runtimeEvents,
		"runtime_settlements_action_required":  settlementActionRequired,
		"oldest_runtime_settlement_seconds":    oldestSettlementSeconds,
		"runtime_host_orphans":                 hostOrphans,
		"runtime_host_orphans_action_required": hostOrphansActionRequired,
	}
}

func detectAgentRuntimes(workspaceErr error) []map[string]any {
	paths := detectCodexCommands()
	runtimes := codexRuntimeEntries(paths)
	runtimes = append(runtimes, detectPortableRuntime("pi", "pi", "rpc", []string{"stdio"}, nil)...)
	runtimes = append(runtimes, detectPortableRuntime("kimi", "kimi", "server", []string{"http", "ws"}, defaultKimiCommandPaths())...)
	runtimes = append(runtimes, detectPortableRuntime("claude", "claude", "agent-sdk-stream-json", []string{"stdio"}, defaultClaudeCommandPaths())...)
	applyExternalRuntimeWorkspaceReadiness(runtimes, workspaceErr)
	return runtimes
}

func applyExternalRuntimeWorkspaceReadiness(runtimes []map[string]any, workspaceErr error) {
	if workspaceErr == nil {
		return
	}
	for _, runtime := range runtimes {
		runtime["ready"] = false
		runtime["status"] = "unavailable"
		runtime["readiness_issue"] = "workspace_unavailable"
		runtime["readiness_message"] = externalRuntimeWorkspaceReadinessMessage(workspaceErr)
		runtime["last_error"] = workspaceErr.Error()
	}
}

func codexRuntimeEntries(paths []string) []map[string]any {
	runtimes := make([]map[string]any, 0, len(paths))
	for _, path := range paths {
		runtimes = append(runtimes, codexRuntimeEntry(path, detectCodexReadiness(path)))
	}
	return runtimes
}

func codexRuntimeEntry(path string, readiness map[string]any) map[string]any {
	runtime := map[string]any{
		"kind":                    "external",
		"provider":                "codex",
		"status":                  codexReadinessStatus(readiness),
		"version":                 readiness["version"],
		"version_detected":        readiness["version_detected"],
		"command":                 path,
		"identity_material":       path,
		"app_server_startable":    readiness["app_server_startable"],
		"native_server_startable": readiness["native_server_startable"],
		"auth_ready":              readiness["auth_ready"],
		"auth":                    readiness["auth"],
		"ready":                   readiness["ready"],
		"readiness_checked_at":    readiness["readiness_checked_at"],
		"readiness_valid_until":   readiness["readiness_valid_until"],
		"readiness_issue":         readiness["readiness_issue"],
		"readiness_message":       readiness["readiness_message"],
		"last_error":              readiness["last_error"],
		"transports":              []string{"ws"},
		"protocol_versions":       []string{"app-server"},
	}
	putNonEmpty(runtime, "model", readiness["model"])
	putNonEmpty(runtime, "model_provider", readiness["model_provider"])
	putNonEmpty(runtime, "reasoning_effort", readiness["reasoning_effort"])
	return runtime
}

func detectCodexCommands() []string {
	path, err := exec.LookPath("codex")
	paths := []string{}
	seen := map[string]bool{}
	for _, path := range managedRuntimeCommands("codex") {
		paths = appendUniquePath(paths, seen, path)
	}
	if err == nil {
		paths = appendUniquePath(paths, seen, path)
	}

	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if dir == "" {
			continue
		}
		candidate := filepath.Join(dir, "codex")
		if executable(candidate) {
			paths = appendUniquePath(paths, seen, candidate)
		}
	}

	if len(paths) == 0 {
		for _, candidate := range codexAppBundleCommandPaths() {
			if executable(candidate) {
				paths = appendUniquePath(paths, seen, candidate)
			}
		}
	}

	return paths
}

func defaultCodexAppBundleCommandPaths() []string {
	paths := []string{
		"/Applications/Codex.app/Contents/Resources/codex",
		"/Applications/Codex.app/Contents/MacOS/codex",
		"/Applications/ChatGPT.app/Contents/Resources/codex",
	}
	if home, err := os.UserHomeDir(); err == nil {
		for _, bundle := range []string{"Codex.app", "ChatGPT.app"} {
			paths = append(paths, filepath.Join(home, "Applications", bundle, "Contents", "Resources", "codex"))
		}
	}
	if runtime.GOOS == "darwin" {
		paths = append(paths, "/opt/homebrew/bin/codex", "/usr/local/bin/codex")
	}
	return paths
}

func appendUniquePath(paths []string, seen map[string]bool, path string) []string {
	normalized := normalizeCodexCommandPath(path)
	if normalized == "" || seen[normalized] {
		return paths
	}
	seen[normalized] = true
	return append(paths, normalized)
}

func normalizeCodexCommandPath(path string) string {
	path = strings.TrimSpace(path)
	if path == "" {
		return ""
	}
	if !filepath.IsAbs(path) {
		return ""
	}
	return filepath.Clean(path)
}

// Resolve standalone bundle resources only at execution. The discovered entry
// path remains the runtime identity when an installer changes its symlink.
func codexExecutionPath(path string) string {
	resolved, err := filepath.EvalSymlinks(path)
	if err == nil && executable(filepath.Join(filepath.Dir(resolved), "codex-code-mode-host")) {
		return resolved
	}
	return path
}

func executable(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode()&0o111 != 0
}

func detectCodexReadiness(path string) map[string]any {
	checkedAt := time.Now().UnixMilli()
	config := detectCodexExecutionConfig()
	version, versionDetected, versionErr := codexVersion(path)
	auth, appServerStartable, appServerErr := codexAppServerReadiness(path, config["model"])
	authReady := codexAuthSnapshotReady(auth)
	authErr := ""
	if stringParam(auth, "status") == "unauthenticated" {
		authErr = "account/read returned no authenticated account"
	}
	ready := versionDetected && authReady && appServerStartable
	issue, message := codexReadinessDetail(versionErr, authErr, appServerErr)

	readiness := map[string]any{
		"version":                 defaultString(version, "unknown"),
		"version_detected":        versionDetected,
		"app_server_startable":    appServerStartable,
		"native_server_startable": appServerStartable,
		"auth_ready":              authReady,
		"auth":                    auth,
		"ready":                   ready,
		"readiness_checked_at":    checkedAt,
		"readiness_valid_until":   checkedAt + runtimeReadinessValidity.Milliseconds(),
		"last_error":              codexReadinessError(versionErr, authErr, appServerErr),
	}
	putNonEmpty(readiness, "readiness_issue", issue)
	putNonEmpty(readiness, "readiness_message", message)
	putNonEmpty(readiness, "model", config["model"])
	putNonEmpty(readiness, "model_provider", config["model_provider"])
	putNonEmpty(readiness, "reasoning_effort", config["reasoning_effort"])
	return readiness
}

func codexReadinessDetail(versionErr, authErr, appServerErr string) (string, string) {
	switch {
	case strings.TrimSpace(versionErr) != "":
		return "runtime_probe_failed", "The Codex version probe failed."
	case strings.TrimSpace(authErr) != "":
		return "authentication_required", "Codex reports no authenticated account."
	case strings.Contains(appServerErr, "configured model"):
		return "model_unavailable", "The configured Codex model is unavailable."
	case strings.TrimSpace(appServerErr) != "":
		if strings.Contains(appServerErr, "start failed") || strings.Contains(appServerErr, "exited before") {
			return "native_server_unavailable", "The Codex native server could not be started."
		}
		if strings.Contains(appServerErr, "timed out") {
			return "native_server_unavailable", "The Codex native server handshake timed out."
		}
		return "native_server_unavailable", "The Codex native server could not complete its readiness handshake."
	default:
		return "", ""
	}
}

func codexReadinessStatus(readiness map[string]any) string {
	if ready, _ := readiness["ready"].(bool); ready {
		return "available"
	}
	return "unavailable"
}

func codexVersion(path string) (string, bool, string) {
	out, err := runCodexCheck(path, "--version")
	text := strings.TrimSpace(out)
	if err != nil {
		return defaultString(text, "unknown"), false, "version check failed: " + diagnosticMessage(err, text)
	}
	if text == "" {
		return "unknown", false, "version check returned empty output"
	}
	return text, true, ""
}

func runCodexCheck(path string, args ...string) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, codexExecutionPath(path), args...)
	out, err := cmd.CombinedOutput()
	if ctx.Err() != nil {
		return string(out), ctx.Err()
	}
	return string(out), err
}

func detectCodexExecutionConfig() map[string]string {
	config := map[string]string{}
	path := codexConfigPath()
	if path == "" {
		return config
	}
	values, err := readTopLevelStringConfig(path)
	if err != nil {
		return config
	}
	putStringConfig(config, "model", values["model"])
	putStringConfig(config, "model_provider", values["model_provider"])
	putStringConfig(config, "reasoning_effort", firstNonBlankString(values["model_reasoning_effort"], values["reasoning_effort"]))
	return config
}

func codexConfigPath() string {
	home := strings.TrimSpace(os.Getenv("CODEX_HOME"))
	if home == "" {
		userHome, err := os.UserHomeDir()
		if err != nil || strings.TrimSpace(userHome) == "" {
			return ""
		}
		home = filepath.Join(userHome, ".codex")
	}
	return filepath.Join(home, "config.toml")
}

func readTopLevelStringConfig(path string) (map[string]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	values := map[string]string{}
	section := ""
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimSpace(stripTomlComment(scanner.Text()))
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.TrimSpace(strings.Trim(line, "[]"))
			continue
		}
		if section != "" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		key = strings.TrimSpace(key)
		if key == "" {
			continue
		}
		if parsed := parseTomlStringValue(value); parsed != "" {
			values[key] = parsed
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return values, nil
}

func stripTomlComment(line string) string {
	var quote rune
	escaped := false
	for i, r := range line {
		if escaped {
			escaped = false
			continue
		}
		if quote == '"' && r == '\\' {
			escaped = true
			continue
		}
		if quote != 0 {
			if r == quote {
				quote = 0
			}
			continue
		}
		if r == '"' || r == '\'' {
			quote = r
			continue
		}
		if r == '#' {
			return line[:i]
		}
	}
	return line
}

func parseTomlStringValue(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	if len(value) >= 2 {
		if value[0] == '"' && value[len(value)-1] == '"' {
			if unquoted, err := strconv.Unquote(value); err == nil {
				return strings.TrimSpace(unquoted)
			}
			return ""
		}
		if value[0] == '\'' && value[len(value)-1] == '\'' {
			return strings.TrimSpace(value[1 : len(value)-1])
		}
	}
	return strings.Trim(value, " \t")
}

func putStringConfig(config map[string]string, key, value string) {
	if strings.TrimSpace(value) != "" {
		config[key] = strings.TrimSpace(value)
	}
}

func firstNonBlankString(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func putNonEmpty(m map[string]any, key string, value any) {
	switch v := value.(type) {
	case string:
		if strings.TrimSpace(v) != "" {
			m[key] = strings.TrimSpace(v)
		}
	default:
		if value != nil {
			m[key] = value
		}
	}
}

func codexAppServerReadiness(path, configuredModel string) (map[string]any, bool, string) {
	failedAuth := codexAuthIssueSnapshot("auth_probe_failed", time.Now().UnixMilli())
	listenURL, err := reserveLocalWebsocketURL()
	if err != nil {
		return failedAuth, false, "reserve app-server listener failed: " + diagnosticMessage(err, "")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, codexExecutionPath(path), codexAppServerArgs(listenURL)...)
	configureProcessGroup(cmd)
	var output lockedBuffer
	cmd.Stdout = &output
	cmd.Stderr = &output
	if err := cmd.Start(); err != nil {
		return failedAuth, false, "app-server start failed: " + diagnosticMessage(err, "")
	}

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()

	finished := false
	defer func() {
		if finished {
			return
		}
		if cmd.Process != nil {
			killProcessGroup(cmd)
		}
		select {
		case <-done:
		case <-time.After(time.Second):
		}
	}()

	dialer := websocket.Dialer{HandshakeTimeout: time.Second}
	var lastErr error
	for {
		ws, _, err := dialer.DialContext(ctx, listenURL, nil)
		if err == nil {
			auth, probeErr := probeCodexAppServer(ctx, ws, configuredModel)
			_ = ws.Close()
			if probeErr != nil {
				return failedAuth, false, "app-server protocol probe failed: " + diagnosticMessage(probeErr, output.String())
			}
			return auth, true, ""
		}
		lastErr = err

		select {
		case waitErr := <-done:
			finished = true
			if waitErr == nil {
				return failedAuth, false, "app-server exited before accepting websocket"
			}
			return failedAuth, false, "app-server exited before accepting websocket: " + diagnosticMessage(waitErr, output.String())
		case <-ctx.Done():
			killProcessGroup(cmd)
			waitErr := <-done
			finished = true
			return failedAuth, false, "app-server websocket probe timed out: " + diagnosticMessage(defaultError(lastErr, defaultError(waitErr, ctx.Err())), output.String())
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func codexAppServerArgs(listenURL string) []string {
	return []string{"app-server", "--disable", "tool_suggest", "--listen", listenURL}
}

func probeCodexAppServer(ctx context.Context, ws *websocket.Conn, configuredModel string) (map[string]any, error) {
	if _, err := codexProbeRPC(ctx, ws, 1, "initialize", map[string]any{
		"clientInfo":   map[string]any{"name": "salix-readiness", "title": "Salix Readiness", "version": "0.1.0"},
		"capabilities": map[string]any{"experimentalApi": true, "requestAttestation": false},
	}); err != nil {
		return nil, err
	}

	account, err := codexProbeRPC(ctx, ws, 2, "account/read", map[string]any{"refreshToken": false})
	if err != nil {
		return nil, err
	}
	auth, err := codexAuthSnapshotFromAccount(account, time.Now().UnixMilli())
	if err != nil {
		return nil, err
	}
	if !codexAuthSnapshotReady(auth) {
		return auth, nil
	}

	models, err := codexProbeRPC(ctx, ws, 3, "model/list", map[string]any{
		"includeHidden": true,
		"limit":         1000,
	})
	if err != nil {
		return nil, err
	}
	configuredModel = strings.TrimSpace(configuredModel)
	if configuredModel == "" {
		return auth, nil
	}
	items, _ := models["data"].([]any)
	for _, item := range items {
		model, _ := item.(map[string]any)
		if stringParam(model, "model") == configuredModel || stringParam(model, "id") == configuredModel {
			return auth, nil
		}
	}
	return nil, fmt.Errorf("configured model %q is not available to this Codex client", configuredModel)
}

func codexProbeRPC(ctx context.Context, ws *websocket.Conn, id int, method string, params map[string]any) (map[string]any, error) {
	if deadline, ok := ctx.Deadline(); ok {
		_ = ws.SetWriteDeadline(deadline)
		_ = ws.SetReadDeadline(deadline)
	}
	if err := ws.WriteJSON(map[string]any{"id": id, "method": method, "params": params}); err != nil {
		return nil, fmt.Errorf("%s request: %w", method, err)
	}
	for {
		var message map[string]any
		if err := ws.ReadJSON(&message); err != nil {
			return nil, fmt.Errorf("%s response: %w", method, err)
		}
		if fmt.Sprint(message["id"]) != strconv.Itoa(id) {
			continue
		}
		if rpcErr := mapParam(message, "error"); len(rpcErr) != 0 {
			return nil, fmt.Errorf("%s rejected: %s", method, defaultString(stringParam(rpcErr, "message"), "unknown error"))
		}
		result := mapParam(message, "result")
		if result == nil {
			return nil, fmt.Errorf("%s returned no result", method)
		}
		return result, nil
	}
}

func codexReadinessError(messages ...string) string {
	var nonblank []string
	for _, message := range messages {
		message = strings.TrimSpace(message)
		if message != "" {
			nonblank = append(nonblank, truncateDiagnostic(message))
		}
	}
	return strings.Join(nonblank, "; ")
}

func diagnosticMessage(err error, output string) string {
	message := ""
	if err != nil {
		message = err.Error()
	}
	output = strings.TrimSpace(output)
	if output != "" {
		if message != "" {
			message += ": "
		}
		message += output
	}
	return truncateDiagnostic(message)
}

func truncateDiagnostic(message string) string {
	message = strings.TrimSpace(message)
	if len(message) <= 300 {
		return message
	}
	return message[:297] + "..."
}

func defaultError(primary error, fallback error) error {
	if primary != nil {
		return primary
	}
	return fallback
}

// systemInfo reports host facts (OS, hostname, CPU, memory) to Salix on connect.
// Stdlib-only and cross-platform/best-effort: fields that can't be determined
// are simply omitted.
func systemInfo() map[string]any {
	info := map[string]any{
		"hostname":     hostname(),
		"os_type":      runtime.GOOS,
		"arch":         runtime.GOARCH,
		"cpu_count":    runtime.NumCPU(),
		"go_version":   runtime.Version(),
		"collected_at": time.Now().UnixMilli(),
	}
	if model := cpuModel(); model != "" {
		info["cpu_model"] = model
	}
	if mem := memoryTotal(); mem > 0 {
		info["memory_total"] = mem
	}
	if v := osVersion(); v != "" {
		info["os_version"] = v
	}
	return info
}

func cpuModel() string {
	switch runtime.GOOS {
	case "linux":
		if data, err := os.ReadFile("/proc/cpuinfo"); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				if strings.HasPrefix(strings.ToLower(line), "model name") {
					if i := strings.Index(line, ":"); i >= 0 {
						return strings.TrimSpace(line[i+1:])
					}
				}
			}
		}
	case "darwin":
		if out, err := exec.Command("sysctl", "-n", "machdep.cpu.brand_string").Output(); err == nil {
			return strings.TrimSpace(string(out))
		}
	}
	return ""
}

func memoryTotal() int64 {
	switch runtime.GOOS {
	case "linux":
		if data, err := os.ReadFile("/proc/meminfo"); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				if strings.HasPrefix(line, "MemTotal:") {
					fields := strings.Fields(line)
					if len(fields) >= 2 {
						if kb, perr := strconv.ParseInt(fields[1], 10, 64); perr == nil {
							return kb * 1024
						}
					}
				}
			}
		}
	case "darwin":
		if out, err := exec.Command("sysctl", "-n", "hw.memsize").Output(); err == nil {
			if n, perr := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64); perr == nil {
				return n
			}
		}
	}
	return 0
}

func osVersion() string {
	switch runtime.GOOS {
	case "linux", "darwin":
		if out, err := exec.Command("uname", "-sr").Output(); err == nil {
			return strings.TrimSpace(string(out))
		}
	}
	return ""
}

func (c *connector) requestReply(ctx context.Context, session *connectionSession, msg message) message {
	result, err := c.dispatchSession(ctx, session, msg.ID, msg.Method, msg.Params)
	if err != nil {
		wrapped := localRequestError{method: msg.Method, err: err}
		c.writeStatusLocalRequestError(wrapped)
		return message{ID: msg.ID, Type: "error", Error: fmt.Sprintf("%s: %v", msg.Method, err)}
	}
	return message{ID: msg.ID, Type: "response", Result: result}
}

func overloadRequestError(msg message) message {
	return message{
		ID:    msg.ID,
		Type:  "error",
		Error: fmt.Sprintf("%s: connector request capacity exhausted", msg.Method),
	}
}

func overloadStreamError(msg message) message {
	return message{
		ID:     msg.ID,
		Type:   "stream",
		Error:  "connector stream capacity exhausted",
		Stream: &streamData{Channel: "done", EOF: true},
	}
}

func (s *connectionSession) handleStream(msg message) {
	if msg.ID == "" || msg.Stream == nil {
		return
	}
	if msg.Stream.Channel == "ack" {
		s.completePendingAck(msg.ID, msg.Stream.Seq, msg.Error)
		return
	}
	if s.connector.currentScope() == scopeLocalFileRead {
		// Request admission cannot protect later stream frames. Downgrade
		// synchronously detaches every pending writer, and this per-frame gate
		// closes the race with a frame received after the scope transition.
		s.abortPendingWrite(msg.ID)
		return
	}
	p := s.pendingWrite(msg.ID)
	if p == nil {
		return
	}
	if msg.Stream.Data != "" {
		raw, err := base64.StdEncoding.DecodeString(msg.Stream.Data)
		if err != nil {
			s.finishPendingWrite(msg.ID)
			_ = s.send(message{ID: msg.ID, Type: "stream", Error: err.Error(), Stream: &streamData{Channel: "done", EOF: true}})
			return
		}
		if _, err := p.write(raw); err != nil {
			s.finishPendingWrite(msg.ID)
			_ = s.send(message{ID: msg.ID, Type: "stream", Error: err.Error(), Stream: &streamData{Channel: "done", EOF: true}})
			return
		}
		if !msg.Stream.EOF {
			_ = s.send(message{ID: msg.ID, Type: "stream", Stream: &streamData{Channel: "ack", Seq: msg.Stream.Seq}})
		}
	}
	if msg.Stream.EOF {
		size := p.currentSize()
		s.finishPendingWrite(msg.ID)
		data, _ := json.Marshal(map[string]any{"size": size})
		_ = s.send(message{ID: msg.ID, Type: "stream", Stream: &streamData{Channel: "done", Data: string(data), EOF: true}})
	}
}

func (c *connector) dispatchSession(ctx context.Context, session *connectionSession, id, method string, params map[string]any) (any, error) {
	if strings.TrimSpace(os.Getenv("SALIX_MANAGED_RUNTIME_ROOT")) != "" && !strings.HasPrefix(method, "cloud_runtime_") {
		c.cloudRuntimeMu.Lock()
		c.expireCloudRuntimeQuiesce()
		if c.cloudRuntimeQuiesced {
			c.cloudRuntimeMu.Unlock()
			return nil, errors.New("cloud runtime is idle; reconnect before sending requests")
		}
		c.cloudRuntimeRequests++
		c.cloudRuntimeMu.Unlock()
		defer func() { c.cloudRuntimeMu.Lock(); c.cloudRuntimeRequests--; c.cloudRuntimeMu.Unlock() }()
	}

	if c.cfg.deviceMode && method == "device_access" {
		return c.methodDeviceAccess(params)
	}
	// The scope gate must precede every method so a scoped connector can never
	// execute commands, touch host files, or drive runtimes regardless of what
	// the remote side asks for. This is authoritative for a Comma-started full
	// bearer; credential-scoped connectors additionally enforce it Server-side.
	deviceRead := c.cfg.deviceMode && (method == "read" || method == "list" || method == "stat" || method == "read_stream")
	if method != "read_ref" && !deviceRead {
		var admitted bool
		var cancel context.CancelFunc
		ctx, cancel, admitted = c.commandAdmissionContext(ctx)
		if !admitted {
			return nil, fmt.Errorf("method %q is not permitted for a %s connector", method, scopeLocalFileRead)
		}
		defer cancel()
	}
	switch method {
	case "exec":
		return c.methodExec(ctx, id, params)
	case "read":
		return c.methodRead(params)
	case "write":
		return c.methodWrite(params)
	case "delete":
		return c.methodDelete(params)
	case "stat":
		return c.methodStat(params)
	case "list":
		return c.methodList(params)
	case "glob":
		return c.methodGlob(params)
	case "grep":
		return c.methodGrep(params)
	case "computer_use":
		return c.methodComputerUse(ctx, params), nil
	case "android":
		return c.android.handle(ctx, id, params), nil
	case "read_stream":
		return c.methodReadStreamFrames(ctx, session, id, params)
	case "read_ref":
		return c.methodReadRefFrames(ctx, session, id, params)
	case "meeting_artifact_read":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodMeetingArtifactReadStreamFrames(ctx, session, id, params)
	case "write_stream":
		return c.prepareWriteStream(ctx, session, id, params)
	case "process_start":
		return c.methodProcessStart(ctx, params, session.send)
	case "process_list":
		return c.methodProcessList(params)
	case "process_write":
		return c.methodProcessWrite(ctx, params)
	case "process_tail":
		return c.methodProcessTail(ctx, params)
	case "process_stop":
		return c.methodProcessStop(ctx, params)
	case "dependency_installations":
		return c.methodDependencyInstallations(params)
	case "http_request":
		return c.methodHTTPRequest(ctx, params)
	case "cloud_runtime_quiesce", "cloud_runtime_release", "cloud_runtime_resume":
		return c.methodCloudRuntimeLifecycle(ctx, method, params)
	case "agent_runtime_input":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodAgentRuntimeInput(ctx, params)
	case "agent_runtime_stop":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodAgentRuntimeStop(ctx, params)
	case "session_migration_prepare", "session_migration_export", "session_migration_import", "session_migration_retire", "session_migration_status", "session_migration_discard":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodSessionMigration(ctx, strings.TrimPrefix(method, "session_migration_"), params)
	case "runtime_probe":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodRuntimeProbe(ctx, session, params)
	case "runtime_auth_status", "runtime_auth_verify", "runtime_auth_input_begin", "runtime_auth_input_submit", "runtime_auth_input_cancel":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.connectedPrivateRuntimeAuth(ctx, session, method, params)
	case "runtime_auth_subscription":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodRuntimeAuthSubscription(ctx, session, params)
	case "runtime_auth_read":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodRuntimeAuthRead(ctx, params)
	case "runtime_auth_login_start":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		if len(mapParam(params, "target")) > 0 {
			return c.connectedPrivateRuntimeAuth(ctx, session, method, params)
		}
		return c.methodRuntimeAuthLoginStart(ctx, params)
	case "runtime_auth_login_cancel":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodRuntimeAuthLoginCancel(ctx, params)
	case "meeting_join":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodMeetingJoin(ctx, params)
	case "meeting_send_chat":
		if err := c.ensureExternalRuntimesAvailable(); err != nil {
			return nil, err
		}
		return c.methodMeetingSendChat(ctx, params)
	case "meeting_session_status":
		return c.methodMeetingSessionStatus(ctx, params)
	default:
		return nil, fmt.Errorf("unknown method: %s", method)
	}
}

func (c *connector) ensureExternalRuntimesAvailable() error {
	if !c.externalRuntimesEnabled() {
		return errors.New("external runtimes are disabled for this Connector process")
	}
	return nil
}

func (c *connector) externalRuntimesEnabled() bool {
	// Attachment-only startup stays restricted. Device mode owns native
	// adapters, but execution still requires the current access grant.
	return c.cfg.deviceMode || strings.TrimSpace(c.cfg.scope) != scopeLocalFileRead
}

func (c *connector) resolve(path string) (string, error) {
	if path == "" {
		path = "."
	}
	full := path
	if !filepath.IsAbs(full) {
		full = filepath.Join(c.root, full)
	}
	full, err := filepath.Abs(full)
	if err != nil {
		return "", err
	}
	return filepath.Clean(full), nil
}

func (c *connector) resolveRootOnly(full string) (string, error) {
	resolved, err := resolveExistingPrefix(full)
	if err != nil {
		return "", err
	}
	if !pathInsideRoot(c.root, resolved) {
		return "", errors.New("path escapes connector root")
	}
	return resolved, nil
}

func resolveExistingPrefix(path string) (string, error) {
	current := filepath.Clean(path)
	missing := []string{}

	for {
		resolved, err := filepath.EvalSymlinks(current)
		if err == nil {
			resolved = filepath.Clean(resolved)
			for _, part := range missing {
				resolved = filepath.Join(resolved, part)
			}
			return resolved, nil
		}
		if !os.IsNotExist(err) {
			return "", err
		}

		parent := filepath.Dir(current)
		if parent == current {
			return "", err
		}
		missing = append([]string{filepath.Base(current)}, missing...)
		current = parent
	}
}

func pathInsideRoot(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	if err != nil {
		return false
	}
	return rel == "." || (rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) && !filepath.IsAbs(rel))
}

func (c *connector) methodExec(ctx context.Context, _ string, params map[string]any) (map[string]any, error) {
	command := stringParam(params, "command")
	if command == "" {
		return nil, errors.New("'command' is required")
	}
	cwd, err := c.resolve(defaultString(stringParam(params, "working_dir"), "."))
	if err != nil {
		return nil, err
	}
	timeout := time.Duration(intParam(params, "timeout", 120)) * time.Second
	if timeout <= 0 {
		timeout = 120 * time.Second
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	cmd := commandContextWithProcessGroup(runCtx, "/bin/sh", "-c", command)
	cmd.Dir = cwd
	cmd.Env = execEnv(params["env"])
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &limitWriter{buf: &stdout, limit: maxOutput}
	cmd.Stderr = &limitWriter{buf: &stderr, limit: maxOutput}
	err = cmd.Run()
	if runCtx.Err() == context.DeadlineExceeded {
		return map[string]any{"exit_code": -1, "stdout": "", "stderr": fmt.Sprintf("timed out after %s", timeout), "truncated": false, "status": "timeout"}, nil
	}
	exitCode := 0
	if err != nil {
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		} else {
			return nil, err
		}
	}
	return map[string]any{
		"exit_code": exitCode,
		"stdout":    stdout.String(),
		"stderr":    stderr.String(),
		"truncated": stdout.Len() >= maxOutput || stderr.Len() >= maxOutput,
		"status":    "completed",
	}, nil
}

func (c *connector) methodHTTPRequest(ctx context.Context, params map[string]any) (map[string]any, error) {
	rawMethod := strings.ToUpper(defaultString(stringParam(params, "method"), http.MethodPost))
	switch rawMethod {
	case http.MethodGet, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
	default:
		return nil, fmt.Errorf("unsupported HTTP method: %s", rawMethod)
	}

	rawURL := stringParam(params, "url")
	if rawURL == "" {
		return nil, errors.New("'url' is required")
	}
	parsed, err := url.Parse(rawURL)
	if err != nil || parsed.Scheme == "" || parsed.Host == "" {
		return nil, errors.New("'url' must be an absolute http or https URL")
	}
	if parsed.Scheme != "http" && parsed.Scheme != "https" {
		return nil, errors.New("'url' must use http or https")
	}

	timeout := time.Duration(intParam(params, "timeout_seconds", 120)) * time.Second
	if timeout <= 0 {
		timeout = 120 * time.Second
	}
	runCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	body := stringParam(params, "body")
	req, err := http.NewRequestWithContext(runCtx, rawMethod, rawURL, strings.NewReader(body))
	if err != nil {
		return nil, err
	}
	for key, value := range mapParam(params, "headers") {
		if key == "" {
			continue
		}
		req.Header.Set(key, stringFromAny(value))
	}
	if body != "" && req.Header.Get("Content-Type") == "" {
		req.Header.Set("Content-Type", "application/json")
	}

	client := &http.Client{
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	limit := int64(intParam(params, "max_bytes", maxFile))
	if limit <= 0 || limit > maxFile {
		limit = maxFile
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	truncated := int64(len(raw)) > limit
	if truncated {
		raw = raw[:limit]
	}

	headers := map[string]any{}
	for key, values := range resp.Header {
		items := make([]any, 0, len(values))
		for _, value := range values {
			items = append(items, value)
		}
		headers[key] = items
	}

	return map[string]any{
		"status":     resp.StatusCode,
		"headers":    headers,
		"body":       string(raw),
		"truncated":  truncated,
		"final_url":  resp.Request.URL.String(),
		"method":     rawMethod,
		"body_bytes": len(raw),
	}, nil
}

func execEnv(raw any) []string {
	values := map[string]string{}
	order := []string{}
	for _, item := range os.Environ() {
		key, value, ok := strings.Cut(item, "=")
		if !ok {
			continue
		}
		if _, exists := values[key]; !exists {
			order = append(order, key)
		}
		values[key] = value
	}
	m, ok := raw.(map[string]any)
	if !ok {
		out := make([]string, 0, len(order))
		for _, key := range order {
			out = append(out, key+"="+values[key])
		}
		return out
	}
	for k, v := range m {
		if _, exists := values[k]; !exists {
			order = append(order, k)
		}
		values[k] = fmt.Sprint(v)
	}
	out := make([]string, 0, len(order))
	for _, key := range order {
		out = append(out, key+"="+values[key])
	}
	return out
}

func processStartEnv(raw any) []string {
	values := map[string]string{}
	order := []string{}
	for _, key := range processStartBaseEnvKeys() {
		if value, ok := os.LookupEnv(key); ok {
			values[key] = value
			order = append(order, key)
		}
	}
	m, ok := raw.(map[string]any)
	if ok {
		for k, v := range m {
			if _, exists := values[k]; !exists {
				order = append(order, k)
			}
			values[k] = fmt.Sprint(v)
		}
	}
	out := make([]string, 0, len(order))
	for _, key := range order {
		out = append(out, key+"="+values[key])
	}
	return out
}

func processStartBaseEnvKeys() []string {
	return []string{
		"PATH",
		"HOME",
		"USER",
		"LOGNAME",
		"SHELL",
		"TMPDIR",
		"TEMP",
		"TMP",
		"LANG",
		"LC_ALL",
		"LC_CTYPE",
		"SSL_CERT_FILE",
		"SSL_CERT_DIR",
		"NODE_EXTRA_CA_CERTS",
	}
}

func randomHex(n int) string {
	buf := make([]byte, n)
	if _, err := rand.Read(buf); err != nil {
		return strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	return hex.EncodeToString(buf)
}

type limitWriter struct {
	buf   *bytes.Buffer
	limit int
}

type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

func (w *limitWriter) Write(p []byte) (int, error) {
	remaining := w.limit - w.buf.Len()
	if remaining > 0 {
		if len(p) > remaining {
			w.buf.Write(p[:remaining])
		} else {
			w.buf.Write(p)
		}
	}
	return len(p), nil
}

func (c *connector) methodRead(params map[string]any) (map[string]any, error) {
	full, err := c.resolve(stringParam(params, "path"))
	if err != nil {
		return nil, err
	}
	f, err := os.Open(full)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	data, err := io.ReadAll(io.LimitReader(f, maxFile+1))
	if err != nil {
		return nil, err
	}
	truncated := len(data) > maxFile
	if truncated {
		data = data[:maxFile]
	}
	text := string(data)
	offset := intParam(params, "offset", 0)
	limit := intParam(params, "limit", 0)
	if offset > 0 || limit > 0 {
		lines := splitLinesAfter(text)
		end := len(lines)
		if limit > 0 && offset+limit < end {
			end = offset + limit
		}
		if offset > len(lines) {
			text = ""
		} else {
			text = strings.Join(lines[offset:end], "")
		}
	}
	return map[string]any{"content": text, "size": len(data), "truncated": truncated}, nil
}

func (c *connector) methodWrite(params map[string]any) (map[string]any, error) {
	full, err := c.resolve(stringParam(params, "path"))
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return nil, err
	}
	flag := os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	if stringParam(params, "mode") == "append" {
		flag = os.O_CREATE | os.O_WRONLY | os.O_APPEND
	}
	raw := []byte(stringParam(params, "content"))
	if len(raw) > maxFile {
		return nil, errors.New("content exceeds 10MB cap")
	}
	f, err := os.OpenFile(full, flag, 0o644)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	if _, err := f.Write(raw); err != nil {
		return nil, err
	}
	return map[string]any{"size": len(raw)}, nil
}

func (c *connector) methodDelete(params map[string]any) (map[string]any, error) {
	full, err := c.resolve(stringParam(params, "path"))
	if err != nil {
		return nil, err
	}
	if boolParam(params, "recursive") {
		err = os.RemoveAll(full)
	} else {
		err = os.Remove(full)
	}
	return map[string]any{"deleted": true}, err
}

func (c *connector) methodStat(params map[string]any) (statResult, error) {
	full, err := c.resolve(stringParam(params, "path"))
	if err != nil {
		return statResult{}, err
	}
	st, err := os.Stat(full)
	if err != nil {
		return statResult{}, err
	}
	kind := "file"
	if st.IsDir() {
		kind = "dir"
	}
	return statResult{Path: stringParam(params, "path"), Kind: kind, Size: st.Size(), Mode: fmt.Sprintf("%#o", st.Mode().Perm()), ModifiedAt: st.ModTime().Unix()}, nil
}

func (c *connector) methodList(params map[string]any) (map[string]any, error) {
	full, err := c.resolve(defaultString(stringParam(params, "path"), "."))
	if err != nil {
		return nil, err
	}
	entries, err := os.ReadDir(full)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(entries))
	for _, ent := range entries {
		info, err := ent.Info()
		if err != nil {
			continue
		}
		kind := "file"
		if info.IsDir() {
			kind = "dir"
		}
		out = append(out, map[string]any{"name": ent.Name(), "kind": kind, "size": info.Size(), "modified_at": info.ModTime().Unix()})
	}
	sort.Slice(out, func(i, j int) bool { return out[i]["name"].(string) < out[j]["name"].(string) })
	return map[string]any{"entries": out}, nil
}

func (c *connector) methodGlob(params map[string]any) (map[string]any, error) {
	base, err := c.resolve(defaultString(stringParam(params, "path"), "."))
	if err != nil {
		return nil, err
	}
	pattern := defaultString(stringParam(params, "pattern"), "*")
	var matches []string
	err = filepath.WalkDir(base, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		display := c.displayPath(path)
		ok, _ := filepath.Match(pattern, filepath.Base(path))
		if !ok {
			ok, _ = filepath.Match(pattern, strings.TrimPrefix(filepath.ToSlash(display), "/"))
		}
		if ok {
			matches = append(matches, display)
		}
		return nil
	})
	sort.Strings(matches)
	truncated := len(matches) > 1000
	if truncated {
		matches = matches[:1000]
	}
	return map[string]any{"matches": matches, "truncated": truncated}, err
}

func (c *connector) methodGrep(params map[string]any) (map[string]any, error) {
	base, err := c.resolve(defaultString(stringParam(params, "path"), "."))
	if err != nil {
		return nil, err
	}
	re, err := regexp.Compile(stringParam(params, "pattern"))
	if err != nil {
		return nil, err
	}
	glob := stringParam(params, "glob")
	var matches []map[string]any
	err = filepath.WalkDir(base, func(path string, d os.DirEntry, err error) error {
		if err != nil || d.IsDir() {
			return nil
		}
		if glob != "" {
			ok, _ := filepath.Match(glob, filepath.Base(path))
			if !ok {
				return nil
			}
		}
		f, err := os.Open(path)
		if err != nil {
			return nil
		}
		defer f.Close()
		scanner := bufio.NewScanner(f)
		scanner.Buffer(make([]byte, 64*1024), maxFile)
		line := 0
		for scanner.Scan() {
			line++
			text := scanner.Text()
			if re.MatchString(text) {
				matches = append(matches, map[string]any{"path": c.displayPath(path), "line": line, "text": text})
				if len(matches) >= 1000 {
					return io.EOF
				}
			}
		}
		return nil
	})
	truncated := errors.Is(err, io.EOF)
	if truncated {
		err = nil
	}
	return map[string]any{"matches": matches, "truncated": truncated}, err
}

func (c *connector) displayPath(path string) string {
	if rel, err := filepath.Rel(c.root, path); err == nil && rel != "." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator)) && rel != ".." {
		return "/" + filepath.ToSlash(rel)
	}
	return filepath.ToSlash(path)
}

func (c *connector) methodReadStreamFrames(ctx context.Context, session *connectionSession, id string, params map[string]any) (map[string]any, error) {
	full, err := c.resolve(stringParam(params, "path"))
	if err != nil {
		return nil, err
	}
	st, err := os.Stat(full)
	if err != nil {
		return nil, err
	}
	f, err := os.Open(full)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	buf := make([]byte, 64*1024)
	seq := 0
	var sent int64
	for {
		n, readErr := f.Read(buf)
		if n > 0 {
			seq++
			sent += int64(n)
			eof := sent >= st.Size()
			frame := message{ID: id, Type: "stream", Stream: &streamData{Channel: "data", Data: base64.StdEncoding.EncodeToString(buf[:n]), EOF: eof, Seq: seq}}
			if err := session.sendReadStreamFrame(ctx, id, seq, frame); err != nil {
				return nil, err
			}
		}
		if readErr == io.EOF {
			if st.Size() == 0 {
				seq++
				_ = session.send(message{ID: id, Type: "stream", Stream: &streamData{Channel: "data", Data: "", EOF: true, Seq: seq}})
			}
			break
		}
		if readErr != nil {
			return nil, readErr
		}
	}
	return map[string]any{"size": st.Size()}, nil
}

func (s *connectionSession) sendReadStreamFrame(ctx context.Context, id string, seq int, frame message) error {
	key := streamAckKey(id, seq)
	ch := make(chan string, 1)

	s.pendingMu.Lock()
	s.pendingAcks[key] = ch
	s.pendingMu.Unlock()

	if err := s.send(frame); err != nil {
		s.deletePendingAck(key)
		return err
	}

	timer := time.NewTimer(60 * time.Second)
	defer timer.Stop()
	select {
	case errText := <-ch:
		if errText != "" {
			return errors.New(errText)
		}
		return nil
	case <-ctx.Done():
		s.deletePendingAck(key)
		return ctx.Err()
	case <-timer.C:
		s.deletePendingAck(key)
		return errors.New("read_stream ack timeout")
	}
}

func (s *connectionSession) completePendingAck(id string, seq int, errText string) {
	key := streamAckKey(id, seq)
	s.pendingMu.Lock()
	ch := s.pendingAcks[key]
	delete(s.pendingAcks, key)
	s.pendingMu.Unlock()
	if ch != nil {
		ch <- errText
	}
}

func (s *connectionSession) deletePendingAck(key string) {
	s.pendingMu.Lock()
	delete(s.pendingAcks, key)
	s.pendingMu.Unlock()
}

func streamAckKey(id string, seq int) string {
	return id + ":" + strconv.Itoa(seq)
}

func (c *connector) prepareWriteStream(ctx context.Context, session *connectionSession, id string, params map[string]any) (map[string]any, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	pending, err := session.reservePendingWrite(id)
	if err != nil {
		return nil, err
	}
	reserved := true
	defer func() {
		if reserved {
			session.finishPendingWrite(id)
		}
	}()
	full, err := c.resolve(stringParam(params, "path"))
	if err != nil {
		return nil, err
	}
	if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
		return nil, err
	}
	flag := os.O_CREATE | os.O_WRONLY | os.O_TRUNC
	if stringParam(params, "mode") == "append" {
		flag = os.O_CREATE | os.O_WRONLY | os.O_APPEND
	}
	f, err := os.OpenFile(full, flag, 0o644)
	if err != nil {
		return nil, err
	}
	if !session.activatePendingWrite(id, pending, f) {
		return nil, context.Canceled
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	reserved = false
	return map[string]any{"status": "ready"}, nil
}

func (c *connector) ensureRuntimeBridge() (string, error) {
	c.bridgeMu.Lock()
	defer c.bridgeMu.Unlock()

	if c.bridgeURL != "" {
		return c.bridgeURL, nil
	}

	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}

	server := &http.Server{Handler: http.HandlerFunc(c.handleRuntimeBridgeHTTP)}
	c.bridgeServer = server
	c.bridgeURL = "http://" + ln.Addr().String()

	go func() {
		if err := server.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			logf("runtime bridge stopped: %v", err)
		}
	}()

	return c.bridgeURL, nil
}

func (c *connector) handleRuntimeBridgeHTTP(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.EscapedPath(), "/")
	token, route, ok := c.runtimeBridgeTokenAndRoute(path)
	if !ok || token == "" || route == "" {
		http.Error(w, "runtime context is not associated with a Salix runtime session", http.StatusNotFound)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxFile+1))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if len(body) > maxFile {
		http.Error(w, "request body exceeds 10MB cap", http.StatusRequestEntityTooLarge)
		return
	}

	params := map[string]any{
		"capability_token": token,
		"method":           r.Method,
		"route_path":       "/" + route,
		"raw_query":        r.URL.RawQuery,
		"headers":          runtimeProxyHeaders(r.Header),
		"body_base64":      base64.StdEncoding.EncodeToString(body),
	}

	result, err := c.sendRuntimeProxy(r.Context(), params)
	if err != nil {
		if errors.Is(err, errRuntimeTransportUnavailable) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(http.StatusServiceUnavailable)
			_ = json.NewEncoder(w).Encode(map[string]string{
				"code":  "connector_offline",
				"error": err.Error(),
			})
			return
		}
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}

	writeRuntimeBridgeResult(w, result)
}

func writeRuntimeBridgeResult(w http.ResponseWriter, result map[string]any) {
	for key, value := range mapParam(result, "headers") {
		if text := fmt.Sprint(value); text != "" {
			w.Header().Set(key, text)
		}
	}

	status := intFromAny(result["status"], http.StatusOK)
	if status < 100 || status > 599 {
		status = http.StatusOK
	}
	w.WriteHeader(status)

	switch {
	case stringParam(result, "body_base64") != "":
		if raw, err := base64.StdEncoding.DecodeString(stringParam(result, "body_base64")); err == nil {
			_, _ = w.Write(raw)
		}
	case stringParam(result, "body") != "":
		_, _ = io.WriteString(w, stringParam(result, "body"))
	}
}

func (c *connector) runtimeBridgeTokenAndRoute(path string) (string, string, bool) {
	first, rest, ok := strings.Cut(path, "/")
	if !ok || first == "" || rest == "" {
		return "", "", false
	}

	if first != "runtime" {
		return "", "", false
	}

	runtimeContext, route, ok := strings.Cut(rest, "/")
	if !ok || runtimeContext == "" || route == "" {
		return "", "", false
	}
	c.bridgeMu.Lock()
	token := c.runtimeRoutes[runtimeContext]
	c.bridgeMu.Unlock()
	if token == "" {
		return "", "", false
	}
	return token, route, true
}

func (c *connector) registerRuntimeRoute(runtimeContext, token string) {
	if runtimeContext == "" || token == "" {
		return
	}
	c.bridgeMu.Lock()
	c.runtimeRoutes[runtimeContext] = token
	c.bridgeMu.Unlock()
}

func (c *connector) removeRuntimeRoute(runtimeContext string) {
	c.bridgeMu.Lock()
	delete(c.runtimeRoutes, runtimeContext)
	c.bridgeMu.Unlock()
}

func runtimeProxyHeaders(headers http.Header) map[string]any {
	out := map[string]any{}
	for key, values := range headers {
		out[strings.ToLower(key)] = strings.Join(values, ",")
	}
	return out
}

func (c *connector) activateRuntimeTransport(send contextMessageSender) func() {
	transport := &runtimeTransport{
		send: send,
		done: make(chan struct{}),
	}
	c.sendMu.Lock()
	c.activeTransport = transport
	c.sendMu.Unlock()
	if c.externalRuntimeState != nil {
		c.externalRuntimeState.wake()
	}
	return func() {
		c.sendMu.Lock()
		if c.activeTransport == transport {
			c.activeTransport = nil
		}
		c.sendMu.Unlock()
		transport.close()
		c.failRuntimePending(transport)
		if auth := c.runtimeAuthCoordinator(); auth != nil {
			auth.runtimeCarrierClosed(transport)
		}
	}
}

func (c *connector) onRuntimeConnected(ctx context.Context, transport *runtimeTransport) {
	// Only an executable device can request pending server input. A later
	// grant requests catch-up through refreshDeviceRuntimes.
	if !c.externalRuntimesEnabled() || c.currentScope() == scopeLocalFileRead {
		return
	}
	go c.replayRuntimeObservations()
	transport.catchupOnce.Do(func() { go c.catchUpExternalRuntimeInputs(ctx, transport) })
}

// catchUpExternalRuntimeInputs sends one payload-free hint per connection
// generation. Server wakes the normal Session owners, which still deliver
// messages through agent_runtime_input and Connector's durable inbox.
func (c *connector) catchUpExternalRuntimeInputs(ctx context.Context, transport *runtimeTransport) {
	requestCtx, cancel := context.WithTimeout(ctx, externalInputCatchupTimeout)
	defer cancel()
	reply, err := c.sendRuntimeRequest(requestCtx, transport, nil, message{
		ID:     c.nextRuntimeRequestID("runtime_catchup_"),
		Type:   "request",
		Method: "agent_runtime_catchup",
	})
	if err == nil && reply.Type != "error" && reply.Error == "" {
		return
	}
	if err == nil {
		err = errors.New(defaultString(reply.Error, "reconnect catch-up rejected"))
	}
	if ctx.Err() == nil && !errors.Is(err, errRuntimeTransportUnavailable) {
		logf("external runtime reconnect catch-up unavailable: %v", err)
	}
}

func (t *runtimeTransport) close() {
	t.closeOnce.Do(func() { close(t.done) })
}

func (c *connector) getActiveTransport() *runtimeTransport {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	return c.activeTransport
}

func (c *connector) sendRuntimeProxy(ctx context.Context, params map[string]any) (map[string]any, error) {
	requestCtx, cancel := context.WithTimeout(ctx, 60*time.Second)
	defer cancel()
	select {
	case c.runtimeProxySlots <- struct{}{}:
		defer func() { <-c.runtimeProxySlots }()
	case <-requestCtx.Done():
		return nil, requestCtx.Err()
	}

	transport := c.getActiveTransport()
	if transport == nil {
		return nil, errRuntimeTransportUnavailable
	}
	id := c.nextRuntimeRequestID("runtime_")
	reply, err := c.sendRuntimeRequest(requestCtx, transport, nil, message{ID: id, Type: "request", Method: "runtime_proxy", Params: params})
	if err != nil {
		return nil, fmt.Errorf("%w; delivery result unconfirmed: %v", errRuntimeTransportUnavailable, err)
	}
	if reply.Type == "error" || reply.Error != "" {
		return nil, errors.New(defaultString(reply.Error, "runtime proxy error"))
	}
	if result, ok := reply.Result.(map[string]any); ok {
		return result, nil
	}
	return map[string]any{"value": reply.Result}, nil
}

// These IDs correlate replies within one Connector lifetime. They carry no
// durable identity or authority. Concurrent requests must not share a clock ID.
func (c *connector) nextRuntimeRequestID(prefix string) string {
	return prefix + strconv.FormatUint(c.runtimeRequestSequence.Add(1), 36)
}

func (c *connector) sendRuntimeRequest(ctx context.Context, transport *runtimeTransport, canceled <-chan struct{}, request message) (message, error) {
	replies := make(chan message, 1)
	c.runtimeMu.Lock()
	if c.runtimePending == nil {
		c.runtimePending = map[string]runtimePendingRequest{}
	}
	c.runtimePending[request.ID] = runtimePendingRequest{transport: transport, reply: replies}
	c.runtimeMu.Unlock()
	defer c.deleteRuntimePending(request.ID, replies)
	if err := transport.send(ctx, request); err != nil {
		return message{}, fmt.Errorf("%w: %v", errRuntimeTransportUnavailable, err)
	}
	select {
	case reply := <-replies:
		return reply, nil
	case <-transport.done:
		return message{}, errRuntimeTransportUnavailable
	case <-canceled:
		return message{}, errors.New("runtime request canceled")
	case <-ctx.Done():
		return message{}, ctx.Err()
	}
}

func (c *connector) completeRuntimeProxy(msg message) {
	if msg.ID == "" {
		return
	}
	c.runtimeMu.Lock()
	pending, ok := c.runtimePending[msg.ID]
	delete(c.runtimePending, msg.ID)
	c.runtimeMu.Unlock()
	if ok {
		pending.reply <- msg
	}
}

func (c *connector) deleteRuntimePending(id string, expected chan message) {
	c.runtimeMu.Lock()
	if c.runtimePending[id].reply == expected {
		delete(c.runtimePending, id)
	}
	c.runtimeMu.Unlock()
}

func (c *connector) failRuntimePending(transport *runtimeTransport) {
	c.runtimeMu.Lock()
	for id, request := range c.runtimePending {
		if request.transport == transport {
			delete(c.runtimePending, id)
		}
	}
	c.runtimeMu.Unlock()
}

// RuntimePIDs exposes the pids of live shared codex app-server processes.
// Idle-session cleanup never terminates these.
func (i *codexRuntimeImplementation) RuntimePIDs() []int {
	i.mu.Lock()
	defer i.mu.Unlock()
	pids := make([]int, 0, len(i.runtimes))
	for _, runtime := range i.runtimes {
		if runtime != nil && runtime.cmd != nil && runtime.cmd.Process != nil {
			pids = append(pids, runtime.cmd.Process.Pid)
		}
	}
	return pids
}

func newCodexRuntimeImplementation(c *connector) *codexRuntimeImplementation {
	implementation := &codexRuntimeImplementation{
		connector:       c,
		runtimes:        map[string]*codexRuntime{},
		sessions:        map[string]*codexRuntimeSession{},
		sessionIndex:    map[string]int{},
		threads:         map[string]string{},
		authQuarantined: map[string]bool{},
		connectTimeout:  10 * time.Second,
	}
	implementation.auth = newRuntimeAuthCoordinator(implementation)
	return implementation
}

func (i *codexRuntimeImplementation) Send(ctx context.Context, input externalRuntimeInput) (map[string]any, string, error) {
	defer i.beginActivity()()
	c := i.connector
	nativeInput := codexRuntimeInput(input.messages)
	session := i.session(input.sessionID)
	session.inputMu.Lock()
	defer session.inputMu.Unlock()
	if err := i.persistSessionRecovery(session); err != nil {
		return nil, "", err
	}
	session.mu.Lock()
	previousRuntime := session.runtime
	threadRuntime := session.threadRuntime
	previousCommand := session.recoveryInput.command
	if (previousRuntime != nil && previousRuntime.command != input.command) ||
		(previousCommand != "" && previousCommand != input.command) {
		session.mu.Unlock()
		return nil, "", errors.New("external runtime session command changed")
	}
	threadID := session.threadID
	activeTurnID := session.activeTurnID
	recoveryPending := session.recoveryPending
	recoveryMessage := session.recoveryMessage
	executionID := session.executionID
	workState := session.workState
	session.mu.Unlock()
	// Keep lazy identity resume distinct from an interrupted active execution:
	// only the latter carries a recovery
	// instruction into the native turn.
	if !recoveryPending {
		recoveryMessage = ""
	}
	runtime, err := i.ensureRuntime(ctx, input, session)
	if err != nil {
		return nil, "", err
	}
	if err := runtime.ensureTaskInitialized(ctx); err != nil {
		return nil, "", err
	}
	bindThread := false
	if threadID != "" && previousRuntime == runtime && threadRuntime == runtime {
		ready, probeErr := runtime.threadReady(ctx, threadID)
		if probeErr != nil {
			if !isCodexAppServerUnavailable(probeErr) {
				return nil, "", probeErr
			}
			if err := stopExternalRuntime(ctx, runtime.terminate, runtime.done); err != nil {
				return nil, "", err
			}
			runtime, err = i.ensureRuntime(ctx, input, session)
			if err != nil {
				return nil, "", err
			}
			if err := runtime.ensureTaskInitialized(ctx); err != nil {
				return nil, "", err
			}
		} else if !ready {
			if boolParam(input.payload, "require_native_resume") {
				return nil, "", errors.New("migrated native Codex thread is missing; restore its files before retrying")
			}
			threadID, err = runtime.startNewThread(ctx, input)
			if err != nil {
				return nil, "", err
			}
			if recoveryPending {
				recoveryMessage = externalRuntimeRecreatedMessage
			}
			bindThread = true
		}
	}
	if !bindThread && (threadID == "" || previousRuntime != runtime || threadRuntime != runtime) {
		recoveryMessage = ""
		candidateThreadID := threadID
		if candidateThreadID == "" {
			candidateThreadID = stringParam(input.payload, "thread_id")
		}
		if candidateThreadID == "" {
			if boolParam(input.payload, "require_native_resume") {
				return nil, "", errors.New("migrated Codex Session has no native identity")
			}
			threadID, err = runtime.startNewThread(ctx, input)
		} else {
			var recreated bool
			threadID, recreated, err = i.resumeOrRecreateThread(ctx, runtime, input, candidateThreadID)
			if recoveryPending {
				recoveryMessage = externalRuntimeRecoveryMessage
				if recreated {
					recoveryMessage = externalRuntimeRecreatedMessage
				}
			}
		}
		if err != nil {
			return nil, "", err
		}
		bindThread = true
	}
	if bindThread {
		activeTurnID = ""
	}
	if input.executionID == "" {
		return nil, "", errors.New("prepared execution id is required")
	}
	if activeTurnID != "" && executionID != "" && executionID != input.executionID {
		return nil, "", errors.New("prepared execution id changed during active codex execution")
	}
	executionID = input.executionID
	input.executionID = executionID
	if bindThread {
		if err := i.bindSessionThread(session, runtime, input, threadID, recoveryMessage); err != nil {
			return nil, "", err
		}
	} else {
		session.mu.Lock()
		if session.runtime != runtime {
			session.mu.Unlock()
			return nil, "", errors.New("codex app-server exited")
		}
		session.token = input.token
		session.recoveryInput = externalRuntimeRecoveryInput(input, "thread_id", threadID)
		session.persistencePending = true
		session.dispatchID = input.dispatchID
		session.executionID = executionID
		if activeTurnID == "" || workState != "running" {
			session.workState = "starting"
			session.failureIssue = ""
			session.failureMessage = ""
		}
		session.mu.Unlock()
		if err := i.persistSessionRecovery(session); err != nil {
			return nil, "", err
		}
	}
	c.registerRuntimeRoute(threadID, input.token)

	if activeTurnID != "" {
		if err := runtime.steer(ctx, threadID, activeTurnID, nativeInput); err != nil {
			return nil, "", err
		}
	} else {
		if recoveryMessage != "" {
			nativeInput = append([]map[string]any{textInput(recoveryMessage)}, nativeInput...)
		}
		session.mu.Lock()
		turnStartedSeq := session.turnStartedSeq
		session.mu.Unlock()
		turnID, err := runtime.startTurn(ctx, threadID, nativeInput, input.model)
		if err != nil {
			if recoveryMessage != "" {
				session.mu.Lock()
				accepted := session.runtime == runtime && session.turnStartedSeq > turnStartedSeq
				if accepted {
					session.recoveryPending = false
					session.recoveryMessage = ""
				}
				session.mu.Unlock()
				if accepted {
					if err := c.externalRuntimeState.markExecutionRecovered("codex", input.sessionID, input.token); err != nil {
						logf("persist accepted runtime recovery failed: %v", err)
					}
					return map[string]any{"thread_id": threadID}, executionID, nil
				}
			}
			return nil, "", err
		}
		session.mu.Lock()
		if recoveryMessage != "" {
			session.recoveryPending = false
			session.recoveryMessage = ""
		}
		if session.lastCompletedTurnID != turnID {
			session.activeTurnID = turnID
		}
		session.mu.Unlock()
		if recoveryMessage != "" {
			if err := c.externalRuntimeState.markExecutionRecovered("codex", input.sessionID, input.token); err != nil {
				logf("persist accepted runtime recovery failed: %v", err)
			}
		}
	}

	return map[string]any{"thread_id": threadID}, executionID, nil
}

func (i *codexRuntimeImplementation) ReplayObservations() {
	i.mu.Lock()
	sessions := make([]*codexRuntimeSession, 0, len(i.sessions))
	for _, session := range i.sessions {
		sessions = append(sessions, session)
	}
	i.mu.Unlock()
	for _, session := range sessions {
		session.mu.Lock()
		if session.workState == "running" || session.workState == "settled" || session.workState == "failed" {
			event := standardRuntimeEvent("codex", "status", "connector/reconnected")
			event["state"] = session.workState
			if session.workState == "failed" {
				event["issue"] = session.failureIssue
				event["message"] = session.failureMessage
			}
			i.connector.forwardRuntimeEvent(
				session.token,
				attachRuntimeIdentity(event, session.dispatchID, session.executionID, session.workState),
			)
		}
		session.mu.Unlock()
	}
}

func (i *codexRuntimeImplementation) Restore(input externalRuntimeInput) error {
	defer i.beginActivity()()
	// Persistence creates the recovery obligation before any app-server attach
	// or thread resume attempt. Connector recovery tests cover this local owner.
	threadID := stringParam(input.payload, "thread_id")
	session := i.session(input.sessionID)
	session.mu.Lock()
	session.token = input.token
	session.threadID = threadID
	session.dispatchID = input.dispatchID
	session.executionID = input.executionID
	if input.executionID != "" {
		session.workState = "starting"
		session.failureIssue = ""
		session.failureMessage = ""
	}
	session.recoveryInput = input
	session.recoveryPending = true
	session.recoveryMessage = externalRuntimeRecoveryMessage
	session.persistencePending = false
	session.mu.Unlock()
	if threadID != "" {
		i.registerThread(input.sessionID, threadID)
		i.connector.registerRuntimeRoute(threadID, input.token)
	} else {
		// Retain this Session's recovery obligation without preventing other
		// Sessions from loading. Recovery needs the original durable input.
		logf("codex recovery requires its durable input batch session=%s execution=%s", input.sessionID, input.executionID)
	}
	return nil
}

func (i *codexRuntimeImplementation) Check(ctx context.Context, sessionID string) error {
	defer i.beginActivity()()
	i.mu.Lock()
	session := i.sessions[sessionID]
	i.mu.Unlock()
	if session == nil {
		return nil
	}
	if !session.inputMu.TryLock() {
		return nil
	}
	defer session.inputMu.Unlock()
	session.mu.Lock()
	missingThread := session.threadID == ""
	session.mu.Unlock()
	if missingThread {
		return errors.New("Unstarted Codex execution has no matching durable input batch. Restore the original input before recovery.")
	}
	if err := i.persistSessionRecovery(session); err != nil {
		return err
	}
	session.mu.Lock()
	runtime := session.runtime
	threadRuntime := session.threadRuntime
	input := session.recoveryInput
	threadID := session.threadID
	session.mu.Unlock()
	if runtime != nil && runtime.isRunning() && threadRuntime == runtime {
		// ExternalRuntimeRecovery retries every provider handshake step while the
		// persisted recovery obligation remains outstanding.
		if err := runtime.ensureTaskInitialized(ctx); err != nil {
			return err
		}
		ready, err := runtime.threadReady(ctx, threadID)
		if err != nil {
			if !isCodexAppServerUnavailable(err) {
				return err
			}
			if err := stopExternalRuntime(ctx, runtime.terminate, runtime.done); err != nil {
				return err
			}
		} else if ready {
			session.mu.Lock()
			pending := session.recoveryPending
			session.mu.Unlock()
			if !pending {
				return nil
			}
			return i.continueSessionRecovery(ctx, session, runtime, input, threadID)
		} else {
			threadID, err = runtime.startNewThread(ctx, input)
			if err != nil {
				return err
			}
			if err := i.bindSessionThread(session, runtime, input, threadID, externalRuntimeRecreatedMessage); err != nil {
				return err
			}
			return i.continueSessionRecovery(ctx, session, runtime, input, threadID)
		}
	}
	if !i.connector.externalRuntimeState.watched("codex", sessionID) {
		return nil
	}
	if input.command == "" || threadID == "" {
		return nil
	}
	runtime, err := i.ensureRuntime(ctx, input, session)
	if err != nil {
		return err
	}
	if err := runtime.ensureTaskInitialized(ctx); err != nil {
		return err
	}
	threadID, recreated, err := i.resumeOrRecreateThread(ctx, runtime, input, threadID)
	if err != nil {
		return err
	}
	recoveryMessage := externalRuntimeRecoveryMessage
	if recreated {
		recoveryMessage = externalRuntimeRecreatedMessage
	}
	if err := i.bindSessionThread(session, runtime, input, threadID, recoveryMessage); err != nil {
		return err
	}
	return i.continueSessionRecovery(ctx, session, runtime, input, threadID)
}

func (i *codexRuntimeImplementation) continueSessionRecovery(
	ctx context.Context,
	session *codexRuntimeSession,
	runtime *codexRuntime,
	input externalRuntimeInput,
	threadID string,
) error {
	session.mu.Lock()
	recoveryMessage := session.recoveryMessage
	turnStartedSeq := session.turnStartedSeq
	session.mu.Unlock()
	if recoveryMessage == "" {
		recoveryMessage = externalRuntimeRecoveryMessage
	}
	turnID, err := runtime.startTurn(
		ctx,
		threadID,
		[]map[string]any{textInput(recoveryMessage)},
		input.model,
	)
	if err != nil {
		session.mu.Lock()
		accepted := session.runtime == runtime && session.turnStartedSeq > turnStartedSeq
		if accepted {
			session.recoveryPending = false
			session.recoveryMessage = ""
		}
		session.mu.Unlock()
		if accepted {
			if settleErr := i.connector.externalRuntimeState.markExecutionRecovered(
				"codex", input.sessionID, input.token,
			); settleErr != nil {
				return settleErr
			}
			return nil
		}
		return err
	}
	session.mu.Lock()
	session.recoveryPending = false
	session.recoveryMessage = ""
	if session.lastCompletedTurnID != turnID {
		session.activeTurnID = turnID
	}
	session.mu.Unlock()
	if err := i.connector.externalRuntimeState.markExecutionRecovered(
		"codex", input.sessionID, input.token,
	); err != nil {
		return err
	}
	return nil
}

func (i *codexRuntimeImplementation) resumeOrRecreateThread(
	ctx context.Context,
	runtime *codexRuntime,
	input externalRuntimeInput,
	threadID string,
) (string, bool, error) {
	if _, err := runtime.resumeThread(ctx, input, threadID); err != nil {
		if !isCodexMissingThread(err) || boolParam(input.payload, "require_native_resume") {
			return "", false, err
		}
		newThreadID, startErr := runtime.startNewThread(ctx, input)
		if startErr != nil {
			return "", false, startErr
		}
		return newThreadID, true, nil
	}
	return threadID, false, nil
}

// bindSessionThread makes the connector's in-memory thread authoritative before
// attempting persistence. A failed write is retried for this same thread by the
// next Send or Check instead of creating another native thread.
func (i *codexRuntimeImplementation) bindSessionThread(
	session *codexRuntimeSession,
	runtime *codexRuntime,
	input externalRuntimeInput,
	threadID string,
	recoveryMessage string,
) error {
	recoveryInput := externalRuntimeRecoveryInput(input, "thread_id", threadID)
	session.mu.Lock()
	if session.runtime != runtime {
		session.mu.Unlock()
		return errCodexAppServerUnavailable
	}
	previousThreadID := session.threadID
	session.threadRuntime = runtime
	session.token = input.token
	session.threadID = threadID
	session.activeTurnID = ""
	session.dispatchID = input.dispatchID
	session.executionID = input.executionID
	if input.executionID != "" {
		session.workState = "starting"
		session.failureIssue = ""
		session.failureMessage = ""
	}
	session.recoveryInput = recoveryInput
	session.persistencePending = true
	session.recoveryPending = recoveryMessage != ""
	session.recoveryMessage = recoveryMessage
	session.mu.Unlock()
	i.mu.Lock()
	if i.threads[previousThreadID] == session.sessionID {
		delete(i.threads, previousThreadID)
	}
	i.threads[threadID] = session.sessionID
	i.mu.Unlock()
	if previousThreadID != threadID {
		i.connector.removeRuntimeRoute(previousThreadID)
	}
	i.connector.registerRuntimeRoute(threadID, input.token)
	return i.persistSessionRecovery(session)
}

// persistSessionRecovery is called with inputMu held, so a successful write can
// clear the pending bit without racing another recovery-input update.
func (i *codexRuntimeImplementation) persistSessionRecovery(session *codexRuntimeSession) error {
	session.mu.Lock()
	defer session.mu.Unlock()
	if !session.persistencePending {
		return nil
	}
	if err := i.connector.watchExternalRuntime("codex", session.recoveryInput); err != nil {
		return err
	}
	session.persistencePending = false
	return nil
}

func isCodexMissingThread(err error) bool {
	var rpcErr *codexRPCError
	if !errors.As(err, &rpcErr) ||
		(rpcErr.method != "thread/read" && rpcErr.method != "thread/resume") {
		return false
	}
	message := strings.ToLower(rpcErr.message)
	return strings.Contains(message, "no rollout found for thread id") ||
		strings.Contains(message, "thread not found")
}

func isCodexAppServerUnavailable(err error) bool {
	return errors.Is(err, errCodexAppServerUnavailable)
}

func (i *codexRuntimeImplementation) Close() {
	i.mu.Lock()
	i.closed = true
	i.mu.Unlock()
	i.pause()
}

// Device permission withdrawal stops native processes, but keeps this adapter
// available for the next explicit grant. Close is permanent owner shutdown.
func (i *codexRuntimeImplementation) pause() {
	i.mu.Lock()
	runtimes := make([]*codexRuntime, 0, len(i.runtimes))
	for _, runtime := range i.runtimes {
		runtimes = append(runtimes, runtime)
	}
	i.mu.Unlock()
	for _, runtime := range runtimes {
		runtime.close()
		<-runtime.done
	}
}

func codexRuntimeInput(messages []map[string]any) []map[string]any {
	input := make([]map[string]any, 0, len(messages))
	for _, message := range messages {
		input = append(input, textInput(stringParam(message, "content")))
	}
	return input
}

func (i *codexRuntimeImplementation) session(sessionID string) *codexRuntimeSession {
	i.mu.Lock()
	defer i.mu.Unlock()
	session := i.sessions[sessionID]
	if session == nil {
		session = &codexRuntimeSession{sessionID: sessionID}
		i.sessions[sessionID] = session
		appendRuntimeSessionID(&i.sessionOrder, &i.sessionIndex, sessionID)
	}
	return session
}

func (i *codexRuntimeImplementation) ensureRuntime(
	ctx context.Context,
	input externalRuntimeInput,
	session *codexRuntimeSession,
) (*codexRuntime, error) {
	c := i.connector
	bridgeURL, err := c.ensureRuntimeBridge()
	if err != nil {
		return nil, err
	}
	i.mu.Lock()
	if i.closed {
		i.mu.Unlock()
		return nil, errCodexAppServerUnavailable
	}
	existing := i.runtimes[input.command]
	if existing != nil && existing.isRunning() {
		session.mu.Lock()
		session.runtime = existing
		session.token = input.token
		session.mu.Unlock()
		i.mu.Unlock()
		return existing, nil
	}
	runtime, err := i.startRuntime(input, bridgeURL)
	if err != nil {
		i.mu.Unlock()
		return nil, err
	}
	i.runtimes[input.command] = runtime
	session.mu.Lock()
	session.runtime = runtime
	session.token = input.token
	session.mu.Unlock()
	runtime.start()
	err = runtime.connect(ctx)
	i.mu.Unlock()
	if err != nil {
		if runtime.isRunning() {
			_ = stopExternalRuntime(ctx, runtime.terminate, runtime.done)
		}
		return nil, err
	}
	return runtime, nil
}

func (i *codexRuntimeImplementation) startRuntime(input externalRuntimeInput, bridgeURL string) (*codexRuntime, error) {
	return i.startRuntimeAtHome(input, bridgeURL, "")
}

func (i *codexRuntimeImplementation) startRuntimeAtHome(input externalRuntimeInput, bridgeURL, home string) (*codexRuntime, error) {
	c := i.connector
	cliDir, err := c.ensureSalixCLI("codex")
	if err != nil {
		return nil, err
	}
	command := input.command
	if command == "" {
		return nil, errors.New("agent_runtime_input requires discovered codex command")
	}
	listenURL, err := reserveLocalWebsocketURL()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command(codexExecutionPath(command), codexAppServerArgs(listenURL)...)
	configureProcessGroup(cmd)
	cmd.Dir = c.root
	cmd.Env = execEnv(map[string]any{
		"SALIX_CONNECT_URL": bridgeURL,
		"SALIX_CLI":         filepath.Join(cliDir, "salix"),
		"SALIX_ENV_ROOT":    c.root,
		"PATH":              runtimeCommandPath(command, cliDir),
	})

	if home != "" {
		cmd.Env = append(cmd.Env, "CODEX_HOME="+home)
	}

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	go func() { _, _ = io.Copy(io.Discard, stdout) }()
	go func() { _, _ = io.Copy(io.Discard, stderr) }()

	runtime := &codexRuntime{
		implementation: i,
		command:        command,
		generation:     randomHex(16),
		cmd:            cmd,
		listenURL:      listenURL,
		connectTimeout: i.connectTimeout,
		exited:         make(chan struct{}),
		done:           make(chan struct{}),
		nextID:         1,
		pending:        map[string]chan map[string]any{},
	}

	return runtime, nil
}

func (r *codexRuntime) start() {
	go r.wait()
}

func (r *codexRuntime) connect(ctx context.Context) error {
	connectTimeout := r.connectTimeout
	if connectTimeout <= 0 {
		connectTimeout = 10 * time.Second
	}
	wsCtx, cancel := context.WithTimeout(ctx, connectTimeout)
	defer cancel()
	ws, err := dialCodexWebsocket(wsCtx, r.listenURL, r.exited)
	if err != nil {
		return err
	}
	r.wsMu.Lock()
	if !r.isRunning() {
		r.wsMu.Unlock()
		_ = ws.Close()
		return errCodexAppServerUnavailable
	}
	r.ws = ws
	r.wsMu.Unlock()
	if r.readLimit > 0 {
		ws.SetReadLimit(r.readLimit)
	}
	go r.readLoop(ws)
	return nil
}

func (c *connector) ensureSalixCLI(provider string) (string, error) {
	c.bridgeMu.Lock()
	defer c.bridgeMu.Unlock()
	if dir := c.salixCLIDirs[provider]; dir != "" {
		return dir, nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", err
	}
	tempRoot := ""
	if c.cfg.runtimeAgent && c.cfg.computeRuntimeKind == "external_worker" {
		// Agent VMM containers keep the image root read-only. Their product
		// workspace is the writable boundary for runtime-owned shims. Use the
		// stable runtime role here because the one-time bootstrap token is
		// cleared after the carrier connects, before a provider's first Session.
		tempRoot = c.root
	}
	dir, err := os.MkdirTemp(tempRoot, ".salix-connect-cli-"+provider+"-")
	if err != nil {
		return "", err
	}
	path := filepath.Join(dir, "salix")
	prefix := ""
	if provider == "codex" {
		prefix = "SALIX_RUNTIME_CONTEXT=\"$CODEX_THREAD_ID\"; export SALIX_RUNTIME_CONTEXT\n"
	}
	script := "#!/bin/sh\n" + prefix + "exec " + shellQuote(exe) + " runtime-cli \"$@\"\n"
	if err := os.WriteFile(path, []byte(script), 0o755); err != nil {
		return "", err
	}
	c.salixCLIDirs[provider] = dir
	return dir, nil
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func reserveLocalWebsocketURL() (string, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return "", err
	}
	addr := ln.Addr().String()
	if err := ln.Close(); err != nil {
		return "", err
	}
	return "ws://" + addr, nil
}

func dialCodexWebsocket(ctx context.Context, endpoint string, exited <-chan struct{}) (*websocket.Conn, error) {
	dialer := websocket.Dialer{HandshakeTimeout: time.Second}
	var lastErr error
	for {
		ws, _, err := dialer.DialContext(ctx, endpoint, nil)
		if err == nil {
			return ws, nil
		}
		lastErr = err
		select {
		case <-exited:
			return nil, errCodexAppServerUnavailable
		case <-ctx.Done():
			if lastErr != nil {
				return nil, fmt.Errorf("connect codex app-server websocket: %w", lastErr)
			}
			return nil, ctx.Err()
		case <-time.After(100 * time.Millisecond):
		}
	}
}

func (r *codexRuntime) isRunning() bool {
	select {
	case <-r.exited:
		return false
	default:
		return true
	}
}

func (r *codexRuntime) wait() {
	err := r.cmd.Wait()
	close(r.exited)
	reason := "codex app-server exited"
	if err != nil {
		reason = "codex app-server exited: " + err.Error()
	}
	r.finish(reason, err != nil)
}

func (r *codexRuntime) close() {
	r.terminate()
}

func (r *codexRuntime) terminate() {
	r.stopOnce.Do(func() {
		r.wsMu.Lock()
		ws := r.ws
		r.wsMu.Unlock()
		if ws != nil {
			_ = ws.Close()
		}
		if r.cmd != nil && r.cmd.Process != nil {
			killProcessGroup(r.cmd)
		}
	})
}

func (r *codexRuntime) finish(reason string, recover bool) {
	r.doneOnce.Do(func() {
		r.terminate()
		r.closePending()
		if r.implementation != nil {
			r.implementation.handleRuntimeClosed(r, reason, recover)
		}
		close(r.done)
	})
}

func configureProcessGroup(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

func commandContextWithProcessGroup(ctx context.Context, name string, args ...string) *exec.Cmd {
	cmd := exec.CommandContext(ctx, name, args...)
	configureProcessGroup(cmd)
	cmd.Cancel = func() error {
		killProcessGroup(cmd)
		return nil
	}
	return cmd
}

func killProcessGroup(cmd *exec.Cmd) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	if groupID, err := syscall.Getpgid(cmd.Process.Pid); err == nil {
		_ = syscall.Kill(-groupID, syscall.SIGKILL)
		return
	}
	_ = cmd.Process.Kill()
}

func (r *codexRuntime) ensureTaskInitialized(ctx context.Context) error {
	if err := r.ensureInitialized(ctx); err != nil {
		return err
	}
	return r.ensureSubscription(ctx)
}

func (r *codexRuntime) ensureInitialized(ctx context.Context) error {
	r.initMu.Lock()
	defer r.initMu.Unlock()
	if r.initialized {
		return nil
	}
	if _, err := r.rpc(ctx, "initialize", map[string]any{
		"clientInfo":   map[string]any{"name": "salix", "title": "Salix", "version": "0.1.0"},
		"capabilities": map[string]any{"experimentalApi": true, "requestAttestation": false},
	}, 15*time.Second); err != nil {
		// A transport error or timeout is ambiguous: the app-server may have
		// applied initialize and lost the response, making a same-connection retry
		// invalid. An explicit JSON-RPC error is a complete rejection and leaves
		// this exact generation safe to observe or retry.
		var responseErr *codexRPCError
		if !errors.As(err, &responseErr) {
			if r.implementation != nil {
				r.implementation.retireUnusableRuntimeGeneration(r)
			} else {
				r.terminate()
			}
		}
		return err
	}
	r.initialized = true
	return nil
}

func (r *codexRuntime) startNewThread(ctx context.Context, input externalRuntimeInput) (string, error) {
	result, err := r.rpc(ctx, "thread/start", map[string]any{
		"approvalPolicy":        "never",
		"sandbox":               "danger-full-access",
		"serviceName":           "salix",
		"cwd":                   input.workspace,
		"baseInstructions":      input.systemPrompt,
		"developerInstructions": codexDeveloperInstructions(),
		// Persist the thread so the canonical external session can resume after reconnects.
		"ephemeral": false,
	}, 30*time.Second)
	if err != nil {
		return "", err
	}
	thread := mapParam(result, "thread")
	threadID := stringParam(thread, "id")
	if threadID == "" {
		return "", errors.New("thread/start returned no thread id")
	}
	return threadID, nil
}

func (r *codexRuntime) resumeThread(ctx context.Context, input externalRuntimeInput, threadID string) (string, error) {
	result, err := r.rpc(ctx, "thread/resume", map[string]any{
		"threadId":              threadID,
		"approvalPolicy":        "never",
		"sandbox":               "danger-full-access",
		"cwd":                   input.workspace,
		"baseInstructions":      input.systemPrompt,
		"developerInstructions": codexDeveloperInstructions(),
	}, 30*time.Second)
	if err != nil {
		return "", err
	}
	resumedThreadID := stringParam(mapParam(result, "thread"), "id")
	if resumedThreadID == "" {
		return "", errors.New("thread/resume returned no thread id")
	}
	if resumedThreadID != threadID {
		return "", fmt.Errorf("thread/resume returned thread id %q, want %q", resumedThreadID, threadID)
	}
	return resumedThreadID, nil
}

func (r *codexRuntime) threadReady(ctx context.Context, threadID string) (bool, error) {
	probeCtx, cancel := context.WithTimeout(ctx, externalRuntimeProbeTimeout)
	defer cancel()
	result, err := r.rpc(
		probeCtx,
		"thread/read",
		map[string]any{"threadId": threadID, "includeTurns": false},
		externalRuntimeProbeTimeout,
	)
	if err == nil {
		actualThreadID := stringParam(mapParam(result, "thread"), "id")
		if actualThreadID != threadID {
			return false, fmt.Errorf("codex thread/read returned thread id %q, want %q", actualThreadID, threadID)
		}
		return true, nil
	}
	if ctx.Err() != nil {
		return false, ctx.Err()
	}
	if isCodexMissingThread(err) {
		return false, nil
	}
	return false, err
}

func (r *codexRuntime) startTurn(ctx context.Context, threadID string, input []map[string]any, model string) (string, error) {
	params := map[string]any{
		"threadId":       threadID,
		"input":          input,
		"approvalPolicy": "never",
	}
	if model != "" {
		params["model"] = model
	}
	result, err := r.rpc(ctx, "turn/start", params, 30*time.Second)
	if err != nil {
		return "", err
	}
	turnID := stringParam(mapParam(result, "turn"), "id")
	if turnID == "" {
		return "", errors.New("turn/start returned no turn id")
	}
	return turnID, nil
}

func (r *codexRuntime) steer(ctx context.Context, threadID, activeTurnID string, input []map[string]any) error {
	if threadID == "" || activeTurnID == "" {
		return errors.New("no active codex turn to steer")
	}
	_, err := r.rpc(ctx, "turn/steer", map[string]any{
		"threadId":       threadID,
		"expectedTurnId": activeTurnID,
		"input":          input,
	}, 30*time.Second)
	return err
}

func (r *codexRuntime) rpc(ctx context.Context, method string, params map[string]any, timeout time.Duration) (map[string]any, error) {
	r.mu.Lock()
	id := strconv.Itoa(r.nextID)
	r.nextID++
	ch := make(chan map[string]any, 1)
	r.pending[id] = ch
	payload := map[string]any{"id": id, "method": method, "params": params}
	r.mu.Unlock()

	if err := r.sendCodexMessage(payload); err != nil {
		r.mu.Lock()
		delete(r.pending, id)
		r.mu.Unlock()
		return nil, err
	}

	select {
	case msg, ok := <-ch:
		if !ok {
			return nil, errCodexAppServerUnavailable
		}
		if errValue, ok := msg["error"]; ok && errValue != nil {
			rpcError := mapParam(msg, "error")
			if len(rpcError) > 0 {
				return nil, &codexRPCError{
					method:  method,
					code:    intParam(rpcError, "code", 0),
					message: stringParam(rpcError, "message"),
				}
			}
			return nil, fmt.Errorf("codex %s: %v", method, errValue)
		}
		return mapParam(msg, "result"), nil
	case <-time.After(timeout):
		r.mu.Lock()
		delete(r.pending, id)
		r.mu.Unlock()
		return nil, fmt.Errorf("codex %s timed out", method)
	case <-ctx.Done():
		r.mu.Lock()
		delete(r.pending, id)
		r.mu.Unlock()
		return nil, ctx.Err()
	}
}

func (r *codexRuntime) readLoop(ws *websocket.Conn) {
	defer r.closePending()
	for {
		var msg map[string]any
		if err := ws.ReadJSON(&msg); err != nil {
			// Release any RPC caller before taking the per-target auth fence below.
			r.closePending()
			if r.implementation != nil {
				r.implementation.auth.runtimeTransportClosed(r)
			} else {
				r.terminate()
			}
			return
		}
		r.handleCodexMessage(msg)
	}
}

func (r *codexRuntime) closePending() {
	r.mu.Lock()
	defer r.mu.Unlock()
	for id, ch := range r.pending {
		delete(r.pending, id)
		close(ch)
	}
}

func (r *codexRuntime) handleCodexMessage(msg map[string]any) {
	id := stringFromAny(msg["id"])
	method := stringFromAny(msg["method"])
	if id != "" && method == "" {
		r.mu.Lock()
		ch := r.pending[id]
		delete(r.pending, id)
		r.mu.Unlock()
		if ch != nil {
			ch <- msg
		}
		return
	}
	if method != "" {
		if id != "" {
			if method == "account/chatgptAuthTokens/refresh" {
				r.refreshSubscription(id, mapParam(msg, "params"))
				return
			}
			result := codexServerRequestResult(method)
			response := map[string]any{"result": result}
			if result == nil {
				response = map[string]any{"error": map[string]any{"code": -32601, "message": "unsupported app-server request: " + method}}
			}
			_ = r.writeCodexResponse(id, response)
		}
		if r.implementation != nil {
			r.implementation.forwardRuntimeEvent(r, msg)
		}
	}
}

func codexServerRequestResult(method string) map[string]any {
	switch method {
	case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
		return map[string]any{"decision": "acceptForSession"}
	case "execCommandApproval", "applyPatchApproval":
		return map[string]any{"decision": "approved_for_session"}
	case "item/permissions/requestApproval":
		return map[string]any{
			"permissions": map[string]any{
				"fileSystem": map[string]any{},
				"network":    map[string]any{"enabled": true},
			},
			"scope": "session",
		}
	case "item/tool/call":
		return map[string]any{
			"success": false,
			"contentItems": []any{
				map[string]any{
					"type": "inputText",
					"text": "Use `\"$SALIX_CLI\" tools` and `\"$SALIX_CLI\" tool call <tool_name> --json '{...}'` for Salix tools.",
				},
			},
		}
	case "item/tool/requestUserInput":
		return map[string]any{"answers": map[string]any{}}
	case "mcpServer/elicitation/request":
		return map[string]any{"action": "decline"}
	case "attestation/generate":
		return map[string]any{"token": ""}
	default:
		return nil
	}
}

func (r *codexRuntime) writeCodexResponse(id string, payload map[string]any) error {
	payload["id"] = id
	return r.sendCodexMessage(payload)
}

func (r *codexRuntime) sendCodexMessage(payload map[string]any) error {
	r.writeMu.Lock()
	defer r.writeMu.Unlock()
	r.wsMu.Lock()
	ws := r.ws
	r.wsMu.Unlock()
	if ws == nil {
		return errCodexAppServerUnavailable
	}
	if err := ws.WriteJSON(payload); err != nil {
		return errCodexAppServerUnavailable
	}
	return nil
}

func (i *codexRuntimeImplementation) registerThread(sessionKey, threadID string) {
	if threadID == "" {
		return
	}
	i.mu.Lock()
	i.threads[threadID] = sessionKey
	i.mu.Unlock()
}

func (i *codexRuntimeImplementation) forwardEvent(event map[string]any) {
	i.forwardRuntimeEvent(nil, event)
}

func (i *codexRuntimeImplementation) forwardRuntimeEvent(runtime *codexRuntime, event map[string]any) {
	if runtime != nil {
		i.auth.handleNotification(runtime, event)
	}
	threadID := codexEventThreadID(event)

	i.mu.Lock()
	sessionKey := i.threads[threadID]
	session := i.sessions[sessionKey]
	i.mu.Unlock()
	if session == nil {
		return
	}

	standard := codexStandardEvent(event)
	session.mu.Lock()
	method := stringFromAny(event["method"])
	turnID := codexEventTurnID(event)
	dispatchID := session.dispatchID
	executionID := session.executionID
	workState := ""
	oldTurn := turnID != "" && turnID == session.lastCompletedTurnID
	currentTurn := turnID != "" && turnID == session.activeTurnID
	if oldTurn {
		dispatchID = session.lastCompletedDispatchID
		executionID = session.lastCompletedExecutionID
	} else if method == "turn/started" && turnID != "" &&
		(session.activeTurnID == "" || currentTurn) {
		session.activeTurnID = turnID
		session.turnStartedSeq++
		session.recoveryPending = false
		session.workState = "running"
		session.failureIssue = ""
		session.failureMessage = ""
		workState = "running"
		currentTurn = true
	} else if method == "turn/completed" && turnID != "" &&
		(currentTurn || (session.activeTurnID == "" && session.workState == "starting")) {
		session.lastCompletedTurnID = turnID
		session.lastCompletedDispatchID = dispatchID
		session.lastCompletedExecutionID = executionID
		if currentTurn {
			session.activeTurnID = ""
		}
		status := strings.ToLower(stringParam(mapParam(mapParam(event, "params"), "turn"), "status"))
		if status == "failed" || status == "error" {
			session.workState = "failed"
			workState = "failed"
			if standard != nil && session.failureIssue != "" {
				standard["issue"] = session.failureIssue
				standard["message"] = session.failureMessage
			}
		} else {
			session.workState = "settled"
			session.failureIssue = ""
			session.failureMessage = ""
			workState = "settled"
		}
	} else if standard != nil && session.workState == "running" &&
		(standard["type"] == "message" || standard["type"] == "thinking" || standard["type"] == "operation") &&
		(turnID == "" || currentTurn) {
		workState = "running"
	} else if turnID != "" && !currentTurn {
		dispatchID = ""
		executionID = ""
	}
	if standard != nil && standard["type"] == "error" && (turnID == "" || currentTurn) {
		session.failureIssue, session.failureMessage = normalizeRuntimeFailure(
			"codex", stringParam(standard, "code"), stringParam(standard, "message"),
		)
	}
	if method == "turn/completed" && (workState == "settled" || workState == "failed") && session.stopDone != nil {
		close(session.stopDone)
		session.stopDone = nil
	}
	token := session.token
	session.mu.Unlock()

	if standard != nil {
		transition := ""
		if method == "turn/started" && workState == externalRuntimeExecutionRunning {
			transition = externalRuntimeExecutionRunning
		} else if method == "turn/completed" &&
			(workState == externalRuntimeExecutionSettled || workState == "failed") {
			transition = externalRuntimeExecutionSettled
		}
		i.connector.forwardRuntimeExecutionEvent(
			"codex",
			session.sessionID,
			token,
			attachRuntimeIdentity(standard, dispatchID, executionID, workState),
			transition,
		)
	}
}

func (i *codexRuntimeImplementation) handleRuntimeClosed(runtime *codexRuntime, reason string, recover bool) {
	i.auth.runtimeClosed(runtime)
	i.mu.Lock()
	delete(i.authQuarantined, runtime.generation)
	if i.runtimes[runtime.command] == runtime {
		delete(i.runtimes, runtime.command)
	}
	allSessions := make([]*codexRuntimeSession, 0, len(i.sessions))
	for _, session := range i.sessions {
		if session != nil {
			allSessions = append(allSessions, session)
		}
	}
	i.mu.Unlock()

	for _, session := range allSessions {
		i.finishSession(runtime, session, reason, recover)
	}
}

// finishSession is the only Codex session transition for a runtime process
// exit, including exits before the app-server WebSocket or native thread exist.
// Its active recover branch retains an unexpected-exit obligation; an idle
// identity has no recovery obligation.
func (i *codexRuntimeImplementation) finishSession(
	runtime *codexRuntime,
	session *codexRuntimeSession,
	reason string,
	recover bool,
) {
	session.mu.Lock()
	if session.runtime != runtime {
		session.mu.Unlock()
		return
	}
	sessionID := session.sessionID
	threadID := session.threadID
	stoppedToken := session.token
	activeToken := ""
	dispatchID := ""
	executionID := ""
	recoveryPending := session.recoveryPending
	if session.workState == "starting" || session.workState == "running" {
		activeToken = session.token
		dispatchID = session.dispatchID
		executionID = session.executionID
		session.workState = "failed"
	}
	session.runtime = nil
	session.activeTurnID = ""
	recoveryPending = recover && (recoveryPending || activeToken != "")
	session.recoveryPending = recoveryPending
	if recoveryPending && session.recoveryMessage == "" {
		session.recoveryMessage = externalRuntimeRecoveryMessage
	}
	if !recoveryPending {
		session.recoveryMessage = ""
	}
	if !recover {
		session.token = ""
		session.threadID = ""
		session.lastCompletedTurnID = ""
		session.recoveryMessage = ""
		session.persistencePending = false
		session.recoveryInput = externalRuntimeInput{}
	}
	session.mu.Unlock()

	i.connector.removeRuntimeRoute(threadID)
	if activeToken != "" {
		transition := ""
		if recover {
			transition = externalRuntimeExecutionInterrupted
		}
		i.connector.forwardRuntimeExecutionEvent("codex", sessionID, activeToken, attachRuntimeIdentity(map[string]any{
			"type":     "error",
			"provider": "codex",
			"message":  reason,
		}, dispatchID, executionID, "failed"), transition)
	}
	if recover {
		return
	}
	i.mu.Lock()
	if i.threads[threadID] == sessionID {
		delete(i.threads, threadID)
	}
	i.mu.Unlock()
	i.connector.forgetExternalRuntime("codex", sessionID)
	event := standardRuntimeEvent("codex", "status", "runtime_stopped")
	event["state"] = "stopped"
	i.connector.forwardRuntimeEvent(stoppedToken, event)
}

// AbandonRecovery explicitly stops one execution whose recovery failure budget
// is exhausted. The durable obligation is
// removed first, gated on the sampled execution fence, so a replacement
// execution that started after the budget tripped is never the one abandoned.
// The in-memory session then detaches (mirroring finishSession's
// recover=false clearing, without its forwarding or forget, both already
// owned here), and the shared terminal observations are announced from the
// durable record — the failed execution event for work that never announced
// its interruption, then runtime_stopped. Pending inbox rows survive and
// redeliver into a fresh native thread on the next delivery pass.
func (i *codexRuntimeImplementation) AbandonRecovery(record externalRuntimeRecoveryRecord, reason string) bool {
	// An unstarted input must survive temporary Host or persistence failures.
	// Exhaustion cannot discard its claim and bypass the saved execution right.
	if stringParam(record.Payload, "thread_id") == "" {
		return false
	}
	sessionID := record.SessionID
	i.mu.Lock()
	session := i.sessions[sessionID]
	i.mu.Unlock()
	if session == nil {
		return i.connector.abandonRuntimeObligation(record, reason)
	}
	if !session.inputMu.TryLock() {
		return false
	}
	defer session.inputMu.Unlock()
	_, removed, err := i.connector.externalRuntimeState.forgetExecution(record)
	if err != nil {
		return false
	}
	if !removed {
		return true
	}
	session.mu.Lock()
	threadID := session.threadID
	if session.workState == "starting" || session.workState == "running" {
		session.workState = "failed"
	}
	session.runtime = nil
	session.activeTurnID = ""
	session.token = ""
	session.threadID = ""
	session.lastCompletedTurnID = ""
	session.recoveryPending = false
	session.recoveryMessage = ""
	session.persistencePending = false
	session.recoveryInput = externalRuntimeInput{}
	session.mu.Unlock()
	i.connector.removeRuntimeRoute(threadID)
	i.mu.Lock()
	if i.threads[threadID] == sessionID {
		delete(i.threads, threadID)
	}
	i.mu.Unlock()
	i.connector.announceAbandonedRecovery(record, reason)
	return true
}

func codexEventThreadID(event map[string]any) string {
	return stringParam(mapParam(event, "params"), "threadId")
}

func codexEventTurnID(event map[string]any) string {
	params := mapParam(event, "params")
	return defaultString(stringParam(params, "turnId"), stringParam(mapParam(params, "turn"), "id"))
}

func codexStandardEvent(native map[string]any) map[string]any {
	method := stringParam(native, "method")
	params := mapParam(native, "params")

	switch method {
	case "item/started", "item/completed":
		item := mapParam(params, "item")
		itemType := stringParam(item, "type")
		switch itemType {
		case "userMessage":
			return nil
		case "agentMessage":
			if method != "item/completed" {
				return nil
			}
			event := standardRuntimeEvent("codex", "message", itemType)
			event["role"] = "assistant"
			event["content"] = stringParam(item, "text")
			return event
		case "reasoning":
			if method != "item/completed" {
				return nil
			}
			event := standardRuntimeEvent("codex", "thinking", itemType)
			event["content"] = strings.TrimSpace(textList(item["summary"]) + "\n" + textList(item["content"]))
			return event
		default:
			if itemType == "" {
				return nil
			}
			event := standardRuntimeEvent("codex", "operation", itemType)
			event["operation_id"] = stringParam(item, "id")
			event["status"] = defaultString(stringParam(item, "status"), strings.TrimPrefix(method, "item/"))
			if command := stringParam(item, "command"); command != "" {
				event["input"] = map[string]any{"command": command, "cwd": stringParam(item, "cwd")}
			} else if input := item["input"]; input != nil {
				event["input"] = input
			}
			if output := item["aggregatedOutput"]; output != nil {
				event["output"] = output
			} else if output := item["output"]; output != nil {
				event["output"] = output
			}
			return event
		}

	case "turn/started", "turn/completed":
		turn := mapParam(params, "turn")
		event := standardRuntimeEvent("codex", "status", method)
		event["state"] = defaultString(stringParam(turn, "status"), strings.TrimPrefix(method, "turn/"))
		if usage := mapParam(turn, "usage"); len(usage) > 0 {
			event["usage"] = usage
		}
		return event

	case "thread/tokenUsage/updated":
		event := standardRuntimeEvent("codex", "usage", method)
		event["usage"] = params
		return event

	case "error":
		err := mapParam(params, "error")
		event := standardRuntimeEvent("codex", "error", method)
		event["code"] = stringParam(err, "code")
		event["message"] = defaultString(stringParam(err, "message"), stringParam(params, "message"))
		return event

	case "warning", "config/warning", "thread/status/changed", "context/compacted":
		event := standardRuntimeEvent("codex", "status", method)
		event["state"] = method
		return event
	default:
		return nil
	}
}

func codexDeveloperInstructions() string {
	return "You are running as an external Salix worker runtime.\n" +
		"Salix owns agent/session identity and tool authorization.\n" +
		externalRuntimeHostInstructions() + "\n" +
		"Assistant text is recorded only in the Salix runtime session; it is not visible in a Salix conversation.\n" +
		"Use `\"$SALIX_CLI\" tools` and `\"$SALIX_CLI\" tool call <tool_name> --json '{...}'` for Salix operations. SALIX_CLI is the absolute Connector-managed executable path and remains valid when a login shell resets PATH.\n" +
		"Send every user-visible IM reply through the relevant Salix tool before finishing the turn; ordinary assistant text is not a conversation reply.\n" +
		"Use the current runtime message context for source and session metadata.\n" +
		"Do not invent agent_id or session_id fields."
}

func externalRuntimeSystemPrompt(systemPrompt string) string {
	parts := []string{}
	if prompt := strings.TrimSpace(systemPrompt); prompt != "" {
		parts = append(parts, prompt)
	}
	parts = append(parts, externalRuntimeHostInstructions())
	return strings.Join(parts, "\n\n")
}

func externalRuntimeHostInstructions() string {
	return "Run commands on this connector host directly with your native shell.\n" +
		"The current working directory is an isolated session workspace and may be empty. " +
		"SALIX_ENV_ROOT is the Connector-managed local environment root. " +
		"When work needs an existing local project, inspect SALIX_ENV_ROOT first. Before modifying project files, use or create a task-specific worktree in the current session workspace; " +
		"do not guess from unrelated temporary directories or another session's workspace.\n" +
		"Use env.exec only for a different connected environment. Local shell execution does not go through FIN."
}

func sliceMapParam(params map[string]any, key string) []map[string]any {
	items, _ := params[key].([]any)
	out := make([]map[string]any, 0, len(items))
	for _, item := range items {
		if m, ok := item.(map[string]any); ok {
			out = append(out, m)
		}
	}
	return out
}

func textInput(text string) map[string]any {
	return map[string]any{"type": "text", "text": text, "text_elements": []any{}}
}

func (c *connector) methodProcessStart(ctx context.Context, params map[string]any, send func(message) error) (map[string]any, error) {
	name := stringParam(params, "process_name")
	if name == "" {
		name = "proc-" + strconv.FormatInt(time.Now().UnixNano(), 36)
	}
	command := stringParam(params, "command")
	if command == "" {
		return nil, errors.New("'command' is required")
	}

	c.processMu.Lock()
	if existing := c.processes[name]; existing != nil && existing.isRunning() {
		c.processMu.Unlock()
		return nil, fmt.Errorf("process %q is already running", name)
	}
	c.processMu.Unlock()

	cwd, err := c.resolve(defaultString(stringParam(params, "working_dir"), "."))
	if err != nil {
		return nil, err
	}
	rootGrants := stringSliceParam(params, "root_grants")
	enforceRoot := boolParam(params, "enforce_root") || len(rootGrants) > 0
	if enforceRoot {
		cwd, err = c.resolveRootOnly(cwd)
		if err != nil {
			if len(rootGrants) > 0 {
				return nil, errors.New("process working_dir is outside root_grants")
			}
			return nil, err
		}
	}
	if len(rootGrants) > 0 {
		if err := c.ensureProcessWorkingDirGranted(cwd, rootGrants); err != nil {
			return nil, errors.New("process working_dir is outside root_grants")
		}
	}

	cmd := exec.Command(command, stringSliceParam(params, "args")...)
	configureProcessGroup(cmd)
	cmd.Dir = cwd
	env := mapParam(params, "env")
	cmd.Env = processStartEnv(env)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return nil, err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		_ = stdin.Close()
		_ = stdout.Close()
		return nil, err
	}
	started := false
	defer func() {
		if started {
			return
		}
		_ = stdin.Close()
		_ = stdout.Close()
		_ = stderr.Close()
	}()

	proc := &managedProcess{
		name:      name,
		cmd:       cmd,
		stdin:     stdin,
		stdinSlot: make(chan struct{}, 1),
		stdout:    newProcessOutput(),
		stderr:    newProcessOutput(),
		done:      make(chan struct{}),
		startedAt: time.Now().UnixMilli(),
		status:    "starting",
	}

	// Registration and start share processMu with scope downgrade's snapshot.
	// Either downgrade cancels before this final check, or it waits until the
	// started process is visible and then kills it before acknowledging.
	c.processMu.Lock()
	defer c.processMu.Unlock()
	if c.beforeManagedProcessStart != nil {
		c.beforeManagedProcessStart()
	}
	if err := ctx.Err(); err != nil || c.currentScope() == scopeLocalFileRead {
		if err != nil {
			return nil, err
		}
		return nil, fmt.Errorf("process start is not permitted for a %s connector", scopeLocalFileRead)
	}
	if existing := c.processes[name]; existing != nil && existing.isRunning() {
		return nil, fmt.Errorf("process %q is already running", name)
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	started = true
	proc.setRunning()
	c.processes[name] = proc
	go func() { _, _ = io.Copy(proc.stdout, stdout) }()
	go func() { _, _ = io.Copy(proc.stderr, stderr) }()
	go proc.wait()

	return proc.summary(), nil
}

func (c *connector) ensureProcessWorkingDirGranted(cwd string, grants []string) error {
	if len(grants) == 0 {
		return nil
	}
	for _, grant := range grants {
		root, err := c.resolveGrantRoot(grant)
		if err != nil {
			continue
		}
		if pathInsideRoot(root, cwd) {
			return nil
		}
	}
	return errors.New("process working_dir is outside root_grants")
}

func (c *connector) resolveGrantRoot(grant string) (string, error) {
	full := strings.TrimSpace(grant)
	if full == "" {
		return "", errors.New("empty root grant")
	}
	if !filepath.IsAbs(full) {
		full = filepath.Join(c.root, full)
	}
	full, err := filepath.Abs(full)
	if err != nil {
		return "", err
	}
	return c.resolveRootOnly(filepath.Clean(full))
}

func (c *connector) methodProcessList(_params map[string]any) (map[string]any, error) {
	c.processMu.Lock()
	processes := make([]*managedProcess, 0, len(c.processes))
	for _, proc := range c.processes {
		processes = append(processes, proc)
	}
	c.processMu.Unlock()

	sort.Slice(processes, func(i, j int) bool { return processes[i].name < processes[j].name })
	out := make([]map[string]any, 0, len(processes))
	for _, proc := range processes {
		out = append(out, proc.summary())
	}
	return map[string]any{"processes": out}, nil
}

func (c *connector) methodProcessWrite(ctx context.Context, params map[string]any) (map[string]any, error) {
	proc, err := c.lookupProcess(stringParam(params, "process_name"))
	if err != nil {
		return nil, err
	}
	if !proc.isRunning() {
		return nil, fmt.Errorf("process %q is not running", proc.name)
	}

	data := stringParam(params, "data")
	if boolParam(params, "append_newline") {
		data += "\n"
	}
	if data == "" {
		return map[string]any{"bytes_written": 0}, nil
	}
	select {
	case proc.stdinSlot <- struct{}{}:
		defer func() { <-proc.stdinSlot }()
	case <-ctx.Done():
		return nil, ctx.Err()
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	deadlineWriter, ok := proc.stdin.(interface{ SetWriteDeadline(time.Time) error })
	if !ok {
		return nil, errors.New("process stdin does not support bounded writes")
	}
	deadline := time.Now().Add(30 * time.Second)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	if err := deadlineWriter.SetWriteDeadline(deadline); err != nil {
		return nil, err
	}
	watcherDone := make(chan struct{})
	watcherExited := make(chan struct{})
	go func() {
		defer close(watcherExited)
		select {
		case <-ctx.Done():
			_ = deadlineWriter.SetWriteDeadline(time.Now())
		case <-watcherDone:
		}
	}()
	n, err := io.WriteString(proc.stdin, data)
	close(watcherDone)
	<-watcherExited
	_ = deadlineWriter.SetWriteDeadline(time.Time{})
	if err != nil {
		return nil, err
	}
	return map[string]any{"bytes_written": n}, nil
}

func (c *connector) methodProcessTail(ctx context.Context, params map[string]any) (map[string]any, error) {
	proc, err := c.lookupProcess(stringParam(params, "process_name"))
	if err != nil {
		return nil, err
	}

	streamName := defaultString(stringParam(params, "stream"), "stdout")
	var output *processOutput
	switch streamName {
	case "stdout":
		output = proc.stdout
	case "stderr":
		output = proc.stderr
	default:
		return nil, errors.New("'stream' must be stdout or stderr")
	}

	from := int64Param(params, "from_offset", 0)
	maxBytes := intParam(params, "max_bytes", 64*1024)
	if maxBytes <= 0 {
		maxBytes = 64 * 1024
	}
	tailBytes := intParam(params, "tail_bytes", 0)
	waitSeconds := intParam(params, "wait_seconds", 0)

	data, base, next, notify := output.read(from, maxBytes, tailBytes)
	if data == "" && proc.isRunning() && waitSeconds > 0 {
		select {
		case <-notify:
			data, base, next, _ = output.read(from, maxBytes, tailBytes)
		case <-proc.done:
			data, base, next, _ = output.read(from, maxBytes, tailBytes)
		case <-time.After(time.Duration(waitSeconds) * time.Second):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}

	result := proc.summary()
	result["stream"] = streamName
	result["offset"] = base
	result["next_offset"] = next
	result["data"] = data
	result["truncated"] = base > from && tailBytes <= 0
	return result, nil
}

func (c *connector) methodProcessStop(ctx context.Context, params map[string]any) (map[string]any, error) {
	proc, err := c.lookupProcess(stringParam(params, "process_name"))
	if err != nil {
		return nil, err
	}

	if proc.isRunning() {
		_ = proc.cmd.Process.Signal(os.Interrupt)
		select {
		case <-proc.done:
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(2 * time.Second):
			_ = proc.cmd.Process.Kill()
			select {
			case <-proc.done:
			case <-ctx.Done():
				return nil, ctx.Err()
			}
		}
	}

	return proc.summary(), nil
}

func (c *connector) lookupProcess(name string) (*managedProcess, error) {
	if name == "" {
		return nil, errors.New("'process_name' is required")
	}
	c.processMu.Lock()
	proc := c.processes[name]
	c.processMu.Unlock()
	if proc == nil {
		return nil, fmt.Errorf("process %q not found", name)
	}
	return proc, nil
}

func newProcessOutput() *processOutput {
	return &processOutput{notify: make(chan struct{})}
}

func (b *processOutput) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()

	b.data = append(b.data, p...)
	b.nextOffset += int64(len(p))
	if len(b.data) > maxProcessBytes {
		drop := len(b.data) - maxProcessBytes
		b.data = append([]byte(nil), b.data[drop:]...)
		b.baseOffset += int64(drop)
	}
	close(b.notify)
	b.notify = make(chan struct{})
	return len(p), nil
}

func (b *processOutput) read(from int64, maxBytes, tailBytes int) (string, int64, int64, <-chan struct{}) {
	b.mu.Lock()
	defer b.mu.Unlock()

	if tailBytes > 0 {
		from = b.nextOffset - int64(tailBytes)
	}
	if from < b.baseOffset {
		from = b.baseOffset
	}
	if from > b.nextOffset {
		from = b.nextOffset
	}

	start := int(from - b.baseOffset)
	end := len(b.data)
	if maxBytes > 0 && start+maxBytes < end {
		end = start + maxBytes
	}

	return string(b.data[start:end]), from, b.baseOffset + int64(end), b.notify
}

func (p *managedProcess) setRunning() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.status = "running"
}

func (p *managedProcess) isRunning() bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.status == "running" || p.status == "starting"
}

func (p *managedProcess) wait() {
	err := p.cmd.Wait()
	p.mu.Lock()
	defer p.mu.Unlock()
	status := "exited"
	if err != nil {
		status = "failed"
		p.exitError = err.Error()
	}
	if p.cmd.ProcessState != nil {
		code := p.cmd.ProcessState.ExitCode()
		p.exitCode = &code
	}
	p.status = status
	close(p.done)
}

func (p *managedProcess) summary() map[string]any {
	p.mu.Lock()
	defer p.mu.Unlock()

	result := map[string]any{
		"process_name": p.name,
		"status":       p.status,
		"started_at":   p.startedAt,
	}
	if p.cmd != nil && p.cmd.Process != nil {
		result["pid"] = p.cmd.Process.Pid
	}
	if p.exitCode != nil {
		result["exit_code"] = *p.exitCode
	}
	if p.exitError != "" {
		result["error"] = p.exitError
	}
	return result
}

func stringParam(params map[string]any, key string) string {
	v, ok := params[key]
	if !ok || v == nil {
		return ""
	}
	return stringFromAny(v)
}

func stringFromAny(v any) string {
	if v == nil {
		return ""
	}
	switch t := v.(type) {
	case string:
		return t
	default:
		return fmt.Sprint(t)
	}
}

func stringSliceParam(params map[string]any, key string) []string {
	v, ok := params[key]
	if !ok || v == nil {
		return nil
	}
	switch t := v.(type) {
	case []string:
		return t
	case []any:
		out := make([]string, 0, len(t))
		for _, item := range t {
			out = append(out, fmt.Sprint(item))
		}
		return out
	default:
		return nil
	}
}

func mapParam(params map[string]any, key string) map[string]any {
	v, ok := params[key]
	if !ok || v == nil {
		return map[string]any{}
	}
	switch t := v.(type) {
	case map[string]any:
		out := make(map[string]any, len(t))
		for k, v := range t {
			out[k] = v
		}
		return out
	case map[string]string:
		out := make(map[string]any, len(t))
		for k, v := range t {
			out[k] = v
		}
		return out
	default:
		return map[string]any{}
	}
}

func intParam(params map[string]any, key string, fallback int) int {
	v, ok := params[key]
	if !ok || v == nil {
		return fallback
	}
	switch t := v.(type) {
	case float64:
		return int(t)
	case int:
		return t
	case json.Number:
		n, _ := t.Int64()
		return int(n)
	default:
		return fallback
	}
}

func intFromAny(v any, fallback int) int {
	switch t := v.(type) {
	case float64:
		return int(t)
	case int:
		return t
	case int64:
		return int(t)
	case json.Number:
		n, _ := t.Int64()
		return int(n)
	default:
		return fallback
	}
}

func int64Param(params map[string]any, key string, fallback int64) int64 {
	v, ok := params[key]
	if !ok || v == nil {
		return fallback
	}
	switch t := v.(type) {
	case float64:
		return int64(t)
	case int:
		return int64(t)
	case int64:
		return t
	case json.Number:
		n, _ := t.Int64()
		return n
	default:
		return fallback
	}
}

func boolParam(params map[string]any, key string) bool {
	v, _ := params[key].(bool)
	return v
}

func defaultString(v, fallback string) string {
	if v == "" {
		return fallback
	}
	return v
}

func splitLinesAfter(s string) []string {
	if s == "" {
		return nil
	}
	var lines []string
	for len(s) > 0 {
		i := strings.IndexByte(s, '\n')
		if i < 0 {
			lines = append(lines, s)
			break
		}
		lines = append(lines, s[:i+1])
		s = s[i+1:]
	}
	return lines
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func getenvInt(key string, fallback int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
}

func getenvBool(key string, fallback bool) bool {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		if b, err := strconv.ParseBool(v); err == nil {
			return b
		}
	}
	return fallback
}

func firstString(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "salix-connect"
	}
	return h
}

func logf(format string, args ...any) {
	fmt.Fprintf(os.Stderr, format+"\n", args...)
}

func fatal(err error) {
	fmt.Fprintf(os.Stderr, "salix-connect: %v\n", err)
	os.Exit(1)
}

func (c *connector) deviceSystemInfo() map[string]any {
	info := systemInfo()
	source := "connector"
	switch c.cfg.runtimeNamespace {
	case "@comma-dev":
		source = "comma_dev"
	case "@comma-staging":
		source = "comma_staging"
	case "@comma":
		source = "comma"
	}
	info["client_source"] = source
	return info
}
