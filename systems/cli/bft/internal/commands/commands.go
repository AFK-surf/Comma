package commands

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"time"

	"github.com/AFK-surf/comma/systems/cli/bft/internal/client"
	"github.com/AFK-surf/comma/systems/cli/bft/internal/config"
	"github.com/AFK-surf/comma/systems/cli/bft/internal/output"
)

var version = "0.1.0-dev"

const maxDeviceLoginWait = 7 * 24 * time.Hour

type envFunc func(string) string

type commonOptions struct {
	json           bool
	defaultJSON    bool
	quiet          bool
	nonInteractive bool
	outputFormat   string
	fields         string
	configPath     string
	url            string
	apiBaseURL     string
	envName        string
	tokenEnv       string
}

type runtime struct {
	stdout           io.Writer
	stderr           io.Writer
	env              envFunc
	defaultJSON      bool
	vmmRunnerFactory func(string, string) VMMRunner
}

func Run(args []string, stdout, stderr io.Writer, env envFunc) int {
	rt := runtime{
		stdout:           stdout,
		stderr:           stderr,
		env:              env,
		defaultJSON:      shouldDefaultJSON(stdout),
		vmmRunnerFactory: func(lifecyclePath, cliPath string) VMMRunner { return newLocalVMMRunner(lifecyclePath, cliPath) },
	}
	if len(args) == 0 {
		fmt.Fprint(stdout, helpText())
		return output.ExitOK
	}

	switch args[0] {
	case "-h", "--help", "help":
		fmt.Fprint(stdout, helpText())
		return output.ExitOK
	case "version":
		return rt.version(args[1:])
	case "update":
		return rt.update(args[1:])
	case "commands", "schema":
		opts, err := parseCommon(args[1:], rt.defaultJSON)
		if err.ExitCode != 0 {
			return output.RenderError(stderr, opts.outputOptions(), err)
		}
		return rt.render(opts.outputOptions(), commandSchema(), func() string {
			return commandsText()
		}, output.ExitOK)
	case "completion":
		return rt.completion(args[1:])
	case "agent":
		return rt.agent(args[1:])
	case "auth":
		return rt.auth(args[1:])
	case "context":
		return rt.context(args[1:])
	case "orgs":
		return rt.orgs(args[1:])
	case "projects":
		return rt.projects(args[1:])
	case "agents":
		return rt.agents(args[1:])
	case "devices":
		return rt.devices(args[1:])
	case "conversations":
		return rt.conversations(args[1:])
	case "sso":
		return rt.sso(args[1:])
	case "feishu":
		return rt.feishu(args[1:])
	case "slack":
		return rt.slack(args[1:])
	case "meetings":
		return rt.meetings(args[1:])
	case "runners":
		return rt.runners(args[1:])
	case "compute-node":
		return rt.computeNode(args[1:])
	case "onboarding":
		return rt.onboarding(args[1:])
	default:
		return output.RenderError(stderr, rt.fallbackOutputOptions(args), output.Usage(
			"unknown_command",
			"Unknown BFT CLI command: "+strings.Join(args, " ")+".",
			map[string]any{"command": args[0]},
		))
	}
}

func (rt runtime) computeNode(args []string) int {
	operation, flagArgs, topicErr := splitTopicArgs(args)
	if topicErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), topicErr)
	}
	fs, opts := rt.newFlagSet("bft compute-node")
	confirm := fs.Bool("confirm-mutating", false, "confirm a local compute-node lifecycle change")
	purge := fs.Bool("purge", false, "also remove local Agent VMM Host data and logs")
	requestID := fs.String("request", "", "stable opaque operation request id")
	if err := parse(fs, flagArgs, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if operation == "help" || operation == "" {
		if operation == "" {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("missing_compute_node_command", "Run bft compute-node install, status, repair, stop, or remove.", nil))
		}
		return rt.render(opts.outputOptions(), computeNodeHelpData(), func() string {
			return computeNodeHelpText()
		}, output.ExitOK)
	}
	if !computeNodeOperations()[operation] {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("unknown_compute_node_command", "Unknown compute-node command.", map[string]any{
			"command":   operation,
			"supported": computeNodeOperationNames(),
		}))
	}
	if *purge && operation != "remove" {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("purge_only_for_remove", "Pass --purge only with bft compute-node remove.", map[string]any{"command": operation}))
	}
	if operation != "status" && !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the local compute-node change.", map[string]any{
			"command": "compute-node." + operation,
		}))
	}
	if operation != "status" && strings.TrimSpace(*requestID) == "" {
		*requestID = fmt.Sprintf("bft-compute-node-%d", time.Now().UnixNano())
	}

	helperPath := resolveVMMLifecyclePath(rt.env)
	if err := validateVMMLifecycleHelper(helperPath); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	cliPath := resolveVMMCLIPath(rt.env, helperPath)
	if operation == "status" {
		if err := validateVMMCLI(cliPath); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
	}
	runnerFactory := rt.vmmRunnerFactory
	if runnerFactory == nil {
		runnerFactory = func(lifecyclePath, cliPath string) VMMRunner { return newLocalVMMRunner(lifecyclePath, cliPath) }
	}
	runner := runnerFactory(helperPath, cliPath)
	ctx, cancel := context.WithTimeout(context.Background(), vmmOperationTimeout(operation))
	defer cancel()

	switch operation {
	case "status":
		status, statusErr := runner.Status(ctx)
		if statusErr != nil && !status.LastKnown {
			return output.RenderError(rt.stderr, opts.outputOptions(), vmmStatusError(helperPath, statusErr))
		}
		data := computeNodeStatusData(helperPath, status, statusErr)
		return rt.render(opts.outputOptions(), data, func() string {
			return computeNodeStatusText(data)
		}, output.ExitOK)
	case "install":
		if err := runner.Install(ctx, *requestID); err != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), vmmLifecycleOperationError(operation, helperPath, err))
		}
		if err := validateVMMCLI(cliPath); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		status, statusErr := runner.Status(ctx)
		if statusErr != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), vmmLifecycleOperationError("observe", helperPath, statusErr))
		}
		if vmmReadiness(status) != "ready" {
			return output.RenderError(rt.stderr, opts.outputOptions(), vmmNotReadyError(helperPath, status))
		}
	case "repair":
		if err := runner.Repair(ctx, *requestID); err != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), vmmLifecycleOperationError(operation, helperPath, err))
		}
	case "stop":
		if err := runner.Stop(ctx, *requestID); err != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), vmmLifecycleOperationError(operation, helperPath, err))
		}
	case "remove":
		if err := runner.Remove(ctx, *purge, *requestID); err != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), vmmLifecycleOperationError(operation, helperPath, err))
		}
	}

	data := computeNodeOperationData(operation, helperPath, *purge, *requestID)
	return rt.render(opts.outputOptions(), data, func() string {
		return computeNodeOperationText(data)
	}, output.ExitOK)
}

func (rt runtime) version(args []string) int {
	fs, opts := rt.newFlagSet("bft version")
	check := fs.Bool("check", false, "check the configured BFT deployment for a newer CLI release")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}

	data := map[string]any{
		"mode":            "version",
		"version":         version,
		"current_version": version,
	}

	if *check {
		cfg, cfgErr := config.Load(opts.configPath, config.Env(rt.env))
		if cfgErr != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_config", Message: "Could not read local BFT CLI config.", Details: map[string]any{"reason": cfgErr.Error()}})
		}
		baseURL, baseErr := resolveBase(opts, cfg, rt.env)
		if baseErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), baseErr)
		}
		release, releaseErr := fetchPublicRelease(context.Background(), baseURL)
		if releaseErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), releaseErr)
		}
		latest := stringField(release, "release_id")
		data["api_base_url"] = baseURL
		data["latest_version"] = latest
		data["release"] = release
		data["update_state"] = versionUpdateState(version, latest)
		data["next_action"] = versionNextAction(version, latest)
	}

	return rt.render(opts.outputOptions(), data, func() string { return versionText(data) }, output.ExitOK)
}

func (rt runtime) update(args []string) int {
	fs, opts := rt.newFlagSet("bft update")
	execute := fs.Bool("execute", false, "execute the installer on this machine")
	confirm := fs.Bool("confirm-mutating", false, "confirm local binary update")
	installDir := fs.String("install-dir", "", "override BFT_CLI_INSTALL_DIR for the installer")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if *execute && !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating to execute a local bft update.", map[string]any{"command": "bft.update"}))
	}

	cfg, cfgErr := config.Load(opts.configPath, config.Env(rt.env))
	if cfgErr != nil {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_config", Message: "Could not read local BFT CLI config.", Details: map[string]any{"reason": cfgErr.Error()}})
	}
	baseURL, baseErr := resolveBase(opts, cfg, rt.env)
	if baseErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), baseErr)
	}
	release, releaseErr := fetchPublicRelease(context.Background(), baseURL)
	if releaseErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), releaseErr)
	}

	installURL := stringField(release, "install_url")
	if strings.TrimSpace(installURL) == "" {
		installURL = strings.TrimRight(baseURL, "/") + "/v1/cli/install.sh"
	}
	latest := stringField(release, "release_id")
	command := bftUpdateCommand(installURL, *installDir)
	data := map[string]any{
		"mode":            "bft_update",
		"api_base_url":    baseURL,
		"current_version": version,
		"latest_version":  latest,
		"update_state":    versionUpdateState(version, latest),
		"release":         release,
		"command":         command,
		"execute":         *execute,
		"executed":        false,
		"next_action":     "Review the installer command, then rerun with --execute --confirm-mutating to update this machine.",
	}

	if *execute {
		if err := runShellCommand(context.Background(), command, rt.stderr); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		data["executed"] = true
		data["next_action"] = "Run bft version --check to verify the installed CLI release."
	}

	return rt.render(opts.outputOptions(), data, func() string { return bftUpdateText(data) }, output.ExitOK)
}

func (rt runtime) auth(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_auth_command", "Run bft auth login, bft auth status, bft auth orgs, or bft auth logout.", nil))
	}
	switch args[0] {
	case "login":
		fs, opts := rt.newFlagSet("bft auth login")
		clientName := fs.String("client-name", defaultCLIClientName(), "device name shown in the dashboard approval screen")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		return rt.authDeviceLogin(opts, *clientName)
	case "status":
		fs, opts := rt.newFlagSet("bft auth status")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		cfg, err := config.Load(opts.configPath, config.Env(rt.env))
		if err != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_config", Message: "Could not read local BFT CLI config.", Details: map[string]any{"reason": err.Error()}})
		}
		tokenConfigured := strings.TrimSpace(cfg.Token) != ""
		data := map[string]any{
			"mode":             "auth_status",
			"api_base_url":     cfg.APIBaseURL,
			"config_path":      config.Path(opts.configPath, config.Env(rt.env)),
			"token_configured": tokenConfigured,
			"expires_at":       cfg.ExpiresAt,
			"granted_orgs":     orgRefsData(cfg.GrantedOrgs),
		}
		exit := output.ExitOK
		if !tokenConfigured {
			exit = output.ExitUsage
		}
		return rt.render(opts.outputOptions(), data, func() string {
			if tokenConfigured {
				return fmt.Sprintf("BFT CLI session configured.\nAPI base: %s\nExpires at: %s\nAuthorized orgs: %s\n", fallback(cfg.APIBaseURL, "unknown"), fallback(cfg.ExpiresAt, "unknown"), orgRefsSummary(cfg.GrantedOrgs))
			}
			return "BFT CLI session is not configured. Run bft auth login.\n"
		}, exit)
	case "orgs":
		return rt.authOrgs(args[1:])
	case "logout":
		fs, opts := rt.newFlagSet("bft auth logout")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		path := config.Path(opts.configPath, config.Env(rt.env))
		cfg, cfgErr := config.Load(opts.configPath, config.Env(rt.env))
		if cfgErr != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_config", Message: "Could not read local BFT CLI config.", Details: map[string]any{"reason": cfgErr.Error()}})
		}

		tokens := []string{}
		seenTokens := map[string]bool{}
		envToken, _ := config.ResolveToken(config.Options{TokenEnv: opts.tokenEnv}, config.Config{}, config.Env(rt.env))
		for _, token := range []string{envToken, cfg.Token} {
			token = strings.TrimSpace(token)
			if token == "" || seenTokens[token] {
				continue
			}
			tokens = append(tokens, token)
			seenTokens[token] = true
		}

		serverRevoked := false
		if len(tokens) > 0 {
			baseURL, baseErr := resolveBase(opts, cfg, rt.env)
			if baseErr.ExitCode != 0 {
				return output.RenderError(rt.stderr, opts.outputOptions(), baseErr)
			}
			for _, token := range tokens {
				if _, apiErr := client.New(baseURL, token).AuthLogout(context.Background()); apiErr.ExitCode != 0 {
					return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
				}
			}
			serverRevoked = true
		}

		cfg.Token = ""
		cfg.ExpiresAt = ""
		cfg.GrantedOrgs = nil
		if err := config.Persist(opts.configPath, config.Env(rt.env), cfg); err != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "config_persist_failed", Message: "Could not update local BFT CLI config.", Details: map[string]any{"reason": err.Error()}})
		}
		return rt.render(opts.outputOptions(), map[string]any{"mode": "auth_logout", "config_path": path, "token_configured": false, "server_revoked": serverRevoked}, func() string {
			if serverRevoked {
				return "BFT CLI session revoked and local config cleared.\n"
			}
			return "BFT CLI local config cleared.\n"
		}, output.ExitOK)
	default:
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_auth_command", "Unknown auth command.", map[string]any{"command": args[0]}))
	}
}

func (rt runtime) authDeviceLogin(opts *commonOptions, clientName string) int {
	cfg, cfgErr := config.Load(opts.configPath, config.Env(rt.env))
	if cfgErr != nil {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_config", Message: "Could not read local BFT CLI config.", Details: map[string]any{"reason": cfgErr.Error()}})
	}
	baseURL, baseErr := resolveBase(opts, cfg, rt.env)
	if baseErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), baseErr)
	}

	api := client.New(baseURL, "")
	start, apiErr := api.AuthDeviceStart(context.Background(), clientName)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}

	deviceCode := stringField(start, "device_code")
	userCode := stringField(start, "user_code")
	verificationURI := stringField(start, "verification_uri")
	verificationURIComplete := stringField(start, "verification_uri_complete")
	if strings.TrimSpace(deviceCode) == "" || strings.TrimSpace(userCode) == "" || strings.TrimSpace(verificationURI) == "" || strings.TrimSpace(verificationURIComplete) == "" {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_auth_device_start", Message: "BFT API did not return a complete CLI device login request."})
	}

	rt.writeDeviceLoginInstructions(opts.outputOptions(), verificationURIComplete, userCode)

	interval := intField(start, "interval_seconds", 5)
	deadline := deviceLoginDeadline(time.Now(), stringField(start, "expires_at"))
	for {
		if !time.Now().Before(deadline) {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_device_login_expired", Message: "CLI device login expired before approval.", Details: map[string]any{"user_code": userCode}})
		}

		poll, pollErr := api.AuthDevicePoll(context.Background(), deviceCode)
		if pollErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), pollErr)
		}

		switch stringField(poll, "status") {
		case "approved":
			loginMeta := map[string]any{
				"verification_uri":          verificationURI,
				"user_code":                 userCode,
				"verification_uri_complete": verificationURIComplete,
			}
			return rt.persistAuthLoginResult(opts, baseURL, poll, loginMeta)
		case "pending":
			interval = intField(poll, "interval_seconds", interval)
			sleepFor := time.Duration(normalizePollInterval(interval)) * time.Second
			remaining := time.Until(deadline)
			if remaining <= 0 {
				return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_device_login_expired", Message: "CLI device login expired before approval.", Details: map[string]any{"user_code": userCode}})
			}
			if remaining < sleepFor {
				sleepFor = remaining
			}
			time.Sleep(sleepFor)
		case "cancelled":
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_device_login_cancelled", Message: "CLI device login was cancelled in the dashboard.", Details: map[string]any{"user_code": userCode}})
		case "expired":
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_device_login_expired", Message: "CLI device login expired before approval.", Details: map[string]any{"user_code": userCode}})
		case "consumed":
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_device_login_consumed", Message: "CLI device login was already consumed.", Details: map[string]any{"user_code": userCode}})
		default:
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_auth_device_poll", Message: "BFT API returned an unknown CLI device login status.", Details: map[string]any{"status": stringField(poll, "status")}})
		}
	}
}

func (rt runtime) persistAuthLoginResult(opts *commonOptions, baseURL string, data map[string]any, loginMeta map[string]any) int {
	token := stringField(data, "token")
	if strings.TrimSpace(token) == "" {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_auth_device_poll", Message: "BFT API did not return a CLI token."})
	}
	expiresAt := stringField(data, "expires_at")
	grantedOrgs := extractOrgRefs(data["granted_orgs"])
	persisted := config.Config{APIBaseURL: baseURL, Token: token, ExpiresAt: expiresAt, GrantedOrgs: grantedOrgs}
	if err := config.Persist(opts.configPath, config.Env(rt.env), persisted); err != nil {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "config_persist_failed", Message: "Could not save local BFT CLI config.", Details: map[string]any{"reason": err.Error()}})
	}

	configPath := config.Path(opts.configPath, config.Env(rt.env))
	result := map[string]any{
		"mode":             "auth_login",
		"api_base_url":     baseURL,
		"config_path":      configPath,
		"token_configured": true,
		"expires_at":       expiresAt,
		"granted_orgs":     orgRefsData(grantedOrgs),
	}
	for key, value := range loginMeta {
		result[key] = value
	}

	return rt.render(opts.outputOptions(), result, func() string {
		return fmt.Sprintf("BFT CLI login saved.\nAPI base: %s\nConfig: %s\nToken stored: true\nExpires at: %s\nAuthorized orgs: %s\n", baseURL, configPath, fallback(expiresAt, "unknown"), orgRefsSummary(grantedOrgs))
	}, output.ExitOK)
}

func (rt runtime) writeDeviceLoginInstructions(opts output.Options, verificationURI, userCode string) {
	if opts.Quiet || opts.JSON {
		return
	}
	fmt.Fprintf(rt.stdout, "Open this URL to approve BFT CLI login:\n%s\nUser code: %s\nWaiting for approval...\n", verificationURI, userCode)
}

func (rt runtime) authOrgs(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_auth_orgs_command", "Run bft auth orgs list, bft auth orgs add, or bft auth orgs revoke --org <org>.", nil))
	}
	switch args[0] {
	case "list":
		fs, opts := rt.newFlagSet("bft auth orgs list")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		cfg, err := config.Load(opts.configPath, config.Env(rt.env))
		if err != nil {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_config", Message: "Could not read local BFT CLI config.", Details: map[string]any{"reason": err.Error()}})
		}
		data := map[string]any{
			"mode":         "auth_orgs",
			"granted_orgs": orgRefsData(cfg.GrantedOrgs),
			"config_path":  config.Path(opts.configPath, config.Env(rt.env)),
		}
		return rt.render(opts.outputOptions(), data, func() string {
			return "Authorized orgs: " + orgRefsSummary(cfg.GrantedOrgs) + "\n"
		}, output.ExitOK)
	case "add":
		fs, opts := rt.newFlagSet("bft auth orgs add")
		clientName := fs.String("client-name", defaultCLIClientName(), "device name shown in the dashboard approval screen")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		return rt.authOrgsAdd(opts, *clientName)
	case "revoke":
		fs, opts := rt.newFlagSet("bft auth orgs revoke")
		org := fs.String("org", "", "org id or slug to revoke from this CLI session")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("org", *org); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		return rt.authOrgsRevoke(opts, *org)
	default:
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_auth_orgs_command", "Run bft auth orgs list, bft auth orgs add, or bft auth orgs revoke --org <org>.", map[string]any{"command": strings.Join(args, " ")}))
	}
}

func (rt runtime) authOrgsAdd(opts *commonOptions, clientName string) int {
	cfg, cfgErr := config.Load(opts.configPath, config.Env(rt.env))
	if cfgErr != nil {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_config", Message: "Could not read local BFT CLI config.", Details: map[string]any{"reason": cfgErr.Error()}})
	}
	baseURL, baseErr := resolveBase(opts, cfg, rt.env)
	if baseErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), baseErr)
	}
	token, tokenEnv := config.ResolveToken(config.Options{TokenEnv: opts.tokenEnv}, cfg, config.Env(rt.env))
	if strings.TrimSpace(token) == "" {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("missing_api_token", "Run bft auth login first.", map[string]any{"token_env": tokenEnv}))
	}

	api := client.New(baseURL, token)
	start, apiErr := api.AuthOrgGrantStart(context.Background(), clientName)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}

	deviceCode := stringField(start, "device_code")
	userCode := stringField(start, "user_code")
	verificationURI := stringField(start, "verification_uri")
	verificationURIComplete := stringField(start, "verification_uri_complete")
	if strings.TrimSpace(deviceCode) == "" || strings.TrimSpace(userCode) == "" || strings.TrimSpace(verificationURI) == "" || strings.TrimSpace(verificationURIComplete) == "" {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_auth_org_grant_start", Message: "BFT API did not return a complete CLI org authorization request."})
	}

	rt.writeOrgGrantInstructions(opts.outputOptions(), verificationURIComplete, userCode)

	interval := intField(start, "interval_seconds", 5)
	deadline := deviceLoginDeadline(time.Now(), stringField(start, "expires_at"))
	for {
		if !time.Now().Before(deadline) {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_org_grant_expired", Message: "CLI org authorization expired before approval.", Details: map[string]any{"user_code": userCode}})
		}

		poll, pollErr := api.AuthOrgGrantPoll(context.Background(), deviceCode)
		if pollErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), pollErr)
		}

		switch stringField(poll, "status") {
		case "approved":
			return rt.persistAuthOrgGrantResult(opts, cfg, baseURL, poll, map[string]any{
				"verification_uri":          verificationURI,
				"user_code":                 userCode,
				"verification_uri_complete": verificationURIComplete,
			})
		case "pending":
			interval = intField(poll, "interval_seconds", interval)
			sleepFor := time.Duration(normalizePollInterval(interval)) * time.Second
			remaining := time.Until(deadline)
			if remaining <= 0 {
				return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_org_grant_expired", Message: "CLI org authorization expired before approval.", Details: map[string]any{"user_code": userCode}})
			}
			if remaining < sleepFor {
				sleepFor = remaining
			}
			time.Sleep(sleepFor)
		case "cancelled":
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_org_grant_cancelled", Message: "CLI org authorization was cancelled in the dashboard.", Details: map[string]any{"user_code": userCode}})
		case "expired":
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_org_grant_expired", Message: "CLI org authorization expired before approval.", Details: map[string]any{"user_code": userCode}})
		case "consumed":
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitUsage, Code: "cli_org_grant_consumed", Message: "CLI org authorization was already consumed.", Details: map[string]any{"user_code": userCode}})
		default:
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_auth_org_grant_poll", Message: "BFT API returned an unknown CLI org authorization status.", Details: map[string]any{"status": stringField(poll, "status")}})
		}
	}
}

func (rt runtime) authOrgsRevoke(opts *commonOptions, org string) int {
	cfg, cfgErr := config.Load(opts.configPath, config.Env(rt.env))
	if cfgErr != nil {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "invalid_config", Message: "Could not read local BFT CLI config.", Details: map[string]any{"reason": cfgErr.Error()}})
	}
	baseURL, baseErr := resolveBase(opts, cfg, rt.env)
	if baseErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), baseErr)
	}
	token, tokenEnv := config.ResolveToken(config.Options{TokenEnv: opts.tokenEnv}, cfg, config.Env(rt.env))
	if strings.TrimSpace(token) == "" {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("missing_api_token", "Run bft auth login first.", map[string]any{"token_env": tokenEnv}))
	}

	data, apiErr := client.New(baseURL, token).AuthOrgRevoke(context.Background(), org)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}

	return rt.persistAuthOrgGrantResult(opts, cfg, baseURL, data, map[string]any{
		"revoked": data["revoked"],
		"org":     data["org"],
	})
}

func (rt runtime) persistAuthOrgGrantResult(opts *commonOptions, cfg config.Config, baseURL string, data map[string]any, meta map[string]any) int {
	grantedOrgs := extractOrgRefs(data["granted_orgs"])
	cfg.APIBaseURL = baseURL
	cfg.GrantedOrgs = grantedOrgs
	if err := config.Persist(opts.configPath, config.Env(rt.env), cfg); err != nil {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Error{ExitCode: output.ExitSoftware, Code: "config_persist_failed", Message: "Could not update local BFT CLI config.", Details: map[string]any{"reason": err.Error()}})
	}

	result := map[string]any{
		"mode":         stringField(data, "mode"),
		"api_base_url": baseURL,
		"config_path":  config.Path(opts.configPath, config.Env(rt.env)),
		"granted_orgs": orgRefsData(grantedOrgs),
	}
	if result["mode"] == "" {
		result["mode"] = "auth_orgs"
	}
	for key, value := range meta {
		result[key] = value
	}

	return rt.render(opts.outputOptions(), result, func() string {
		return "BFT CLI authorized orgs updated.\nAuthorized orgs: " + orgRefsSummary(grantedOrgs) + "\n"
	}, output.ExitOK)
}

func (rt runtime) writeOrgGrantInstructions(opts output.Options, verificationURI, userCode string) {
	if opts.Quiet || opts.JSON {
		return
	}
	fmt.Fprintf(rt.stdout, "Open this URL to authorize more orgs for this BFT CLI session:\n%s\nUser code: %s\nWaiting for approval...\n", verificationURI, userCode)
}

func (rt runtime) agent(args []string) int {
	if len(args) == 0 || args[0] != "help" {
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("missing_agent_command", "Run bft agent help <topic>.", nil))
	}
	fs, opts := rt.newFlagSet("bft agent help")
	topic, flagArgs, topicErr := splitTopicArgs(args[1:])
	if topicErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), topicErr)
	}
	if err := parse(fs, flagArgs, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if topic == "" {
		topic = "overview"
	}
	data, ok := agentHelp(topic)
	if !ok {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("unknown_agent_help_topic", "Unknown agent help topic.", map[string]any{"topic": topic, "supported_topics": agentHelpTopics()}))
	}
	return rt.render(opts.outputOptions(), data, func() string { return agentHelpText(data) }, output.ExitOK)
}

func (rt runtime) completion(args []string) int {
	fs, opts := rt.newFlagSet("bft completion")
	shell, flagArgs, topicErr := splitTopicArgs(args)
	if topicErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), topicErr)
	}
	if err := parse(fs, flagArgs, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if shell == "" {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("missing_completion_shell", "Run bft completion bash, zsh, or fish.", nil))
	}
	script, ok := completionScript(shell)
	if !ok {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("unknown_completion_shell", "Unsupported completion shell.", map[string]any{"shell": shell, "supported_shells": completionShells()}))
	}
	data := map[string]any{"mode": "completion", "shell": shell, "script": script}
	return rt.render(opts.outputOptions(), data, func() string { return script }, output.ExitOK)
}

func (rt runtime) context(args []string) int {
	fs, opts := rt.newFlagSet("bft context")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	data, apiErr := api.Get(context.Background(), "/v1/cli/context", map[string]string{"org": *org, "project": *project})
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string {
		return contextText(data)
	}, output.ExitOK)
}

func (rt runtime) orgs(args []string) int {
	if len(args) > 0 && args[0] != "list" {
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_orgs_command", "Run bft orgs list.", map[string]any{"command": args[0]}))
	}
	remaining := args
	if len(remaining) > 0 {
		remaining = remaining[1:]
	}
	fs, opts := rt.newFlagSet("bft orgs list")
	limit := fs.Int("limit", defaultListLimit, "maximum rows to return")
	filter := fs.String("filter", "", "case-insensitive substring filter")
	if err := parse(fs, remaining, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := validateListLimit(*limit); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	data, apiErr := api.Get(context.Background(), "/v1/cli/orgs", listQuery(*limit, *filter))
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	data = boundList(data, "orgs", *limit, *filter)
	return rt.render(opts.outputOptions(), data, func() string { return tableText(data, "orgs") }, output.ExitOK)
}

func (rt runtime) projects(args []string) int {
	if len(args) == 0 || args[0] != "list" {
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("missing_projects_command", "Run bft projects list --org <org>.", nil))
	}
	args = args[1:]
	fs, opts := rt.newFlagSet("bft projects list")
	org := fs.String("org", "", "org id or slug")
	limit := fs.Int("limit", defaultListLimit, "maximum rows to return")
	filter := fs.String("filter", "", "case-insensitive substring filter")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := validateListLimit(*limit); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	query := listQuery(*limit, *filter)
	query["org"] = *org
	data, apiErr := api.Get(context.Background(), "/v1/cli/projects", query)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	data = boundList(data, "projects", *limit, *filter)
	return rt.render(opts.outputOptions(), data, func() string { return tableText(data, "projects") }, output.ExitOK)
}

func (rt runtime) agents(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_agents_command", "Run bft agents list, runtimes, create, or rebind.", nil))
	}

	switch args[0] {
	case "list":
		return rt.agentsList(args[1:])
	case "runtimes":
		return rt.agentsRuntimes(args[1:])
	case "create":
		return rt.agentsCreate(args[1:])
	case "rebind":
		return rt.agentsRebind(args[1:])
	default:
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_agents_command", "Run bft agents list, runtimes, create, or rebind.", map[string]any{"command": strings.Join(args, " ")}))
	}
}

func (rt runtime) agentsList(args []string) int {
	fs, opts := rt.newFlagSet("bft agents list")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	role := fs.String("role", "", "optional role filter: router or worker")
	limit := fs.Int("limit", defaultListLimit, "canonical page size (up to 500 records)")
	filter := fs.String("filter", "", "case-insensitive substring filter within the page")
	cursor := fs.String("cursor", "", "continue from the previous next_cursor")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := validateListLimit(*limit); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	query := listQuery(*limit, *filter)
	if strings.TrimSpace(*cursor) != "" {
		query["cursor"] = strings.TrimSpace(*cursor)
	}
	if strings.TrimSpace(*role) != "" {
		query["role"] = strings.TrimSpace(*role)
	}
	data, apiErr := api.Get(context.Background(), projectAgentsPath(*org, *project), query)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	data = boundList(data, "agents", *limit, *filter)
	return rt.render(opts.outputOptions(), data, func() string { return agentsText(data) }, output.ExitOK)
}

func (rt runtime) agentsRuntimes(args []string) int {
	fs, opts := rt.newFlagSet("bft agents runtimes")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	includeUnavailable := fs.Bool("include-unavailable", false, "include runtimes that are visible but not currently bindable")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	data, apiErr := api.Get(context.Background(), projectAgentRuntimesPath(*org, *project), nil)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	data = filterAgentRuntimes(data, *includeUnavailable)
	return rt.render(opts.outputOptions(), data, func() string { return agentRuntimesText(data) }, output.ExitOK)
}

func (rt runtime) agentsCreate(args []string) int {
	fs, opts := rt.newFlagSet("bft agents create")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	name := fs.String("name", "", "agent display name")
	role := fs.String("role", "worker", "agent role: router or worker")
	runtimeKind := fs.String("runtime-kind", "internal", "runtime kind: internal or external")
	runtimeProvider := fs.String("runtime-provider", "codex", "external runtime provider")
	deviceID := fs.String("device-id", "", "device id for external runtime")
	runtimeID := fs.String("runtime-id", "", "runtime id on the selected device")
	deviceRuntimeID := fs.String("device-runtime-id", "", "stable device runtime id")
	confirm := fs.Bool("confirm-mutating", false, "confirm mutating write")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := validateAgentRole(*role); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := validateAgentRuntimeFlags(*runtimeKind, *runtimeProvider, *deviceID, *runtimeID, *deviceRuntimeID); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the agent role and device runtime target.", map[string]any{"command": "agents.create"}))
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	body := map[string]any{
		"role": strings.TrimSpace(*role),
	}
	putIfPresent(body, "name", *name)
	if strings.TrimSpace(*runtimeKind) == "external" {
		body["runtime_config"] = map[string]any{
			"kind":              "external",
			"provider":          strings.TrimSpace(*runtimeProvider),
			"device_id":         strings.TrimSpace(*deviceID),
			"runtime_id":        strings.TrimSpace(*runtimeID),
			"device_runtime_id": strings.TrimSpace(*deviceRuntimeID),
		}
	}
	data, apiErr := api.Post(context.Background(), projectAgentsPath(*org, *project), body)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return agentText("Agent created.", data) }, output.ExitOK)
}

func (rt runtime) agentsRebind(args []string) int {
	fs, opts := rt.newFlagSet("bft agents rebind")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	agent := fs.String("agent", "", "agent id, Salix agent id, or unique name")
	runtimeRef := fs.String("runtime", "", "device_runtime_id or unique runtime reference from bft agents runtimes")
	deviceRef := fs.String("device", "", "optional device id, device name, or connector_run_id to disambiguate runtime")
	confirm := fs.Bool("confirm-mutating", false, "confirm external agent runtime rebind")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("agent", *agent); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("runtime", *runtimeRef); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the agent and runtime target.", map[string]any{"command": "agents.rebind"}))
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	body := map[string]any{"runtime": strings.TrimSpace(*runtimeRef)}
	putIfPresent(body, "device", *deviceRef)
	data, apiErr := api.Patch(context.Background(), projectAgentRuntimePath(*org, *project, *agent), body)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return agentText("Agent runtime rebind accepted. Reconcile pending.", data) }, output.ExitOK)
}

func (rt runtime) devices(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_devices_command", "Run bft devices list, create, stop, or disconnect.", nil))
	}

	switch args[0] {
	case "list":
		fs, opts := rt.newFlagSet("bft devices list")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		limit := fs.Int("limit", defaultListLimit, "maximum devices to return")
		filter := fs.String("filter", "", "case-insensitive device filter")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("org", *org); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("project", *project); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := validateListLimit(*limit); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		query := listQuery(*limit, *filter)
		query["org"] = *org
		query["project"] = *project
		data, apiErr := api.Get(context.Background(), projectDevicesPath(*org, *project), query)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		data = boundList(data, "devices", *limit, *filter)
		return rt.render(opts.outputOptions(), data, func() string { return devicesText(data) }, output.ExitOK)

	case "create":
		fs, opts := rt.newFlagSet("bft devices create")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		runner := fs.String("runner", "", "runner id, stable id, or unique name")
		name := fs.String("name", "", "device name")
		alias := fs.String("alias", "", "device alias")
		confirm := fs.Bool("confirm-mutating", false, "confirm project device creation")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("org", *org); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("project", *project); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("runner", *runner); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if !*confirm {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the target runner.", map[string]any{"command": "devices.create"}))
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		attrs := map[string]any{}
		putIfPresent(attrs, "runner", *runner)
		putIfPresent(attrs, "name", *name)
		putIfPresent(attrs, "alias", *alias)
		data, apiErr := api.Post(context.Background(), projectDevicesPath(*org, *project), attrs)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return deviceMutationText("Device request created.", data) }, output.ExitOK)

	case "stop":
		fs, opts := rt.newFlagSet("bft devices stop")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		request := fs.String("request", "", "device request id")
		confirm := fs.Bool("confirm-mutating", false, "confirm device request stop")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("org", *org); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("project", *project); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("request", *request); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if !*confirm {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the device request.", map[string]any{"command": "devices.stop"}))
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		data, apiErr := api.Post(context.Background(), projectDevicesPath(*org, *project)+"/requests/"+urlPathEscape(*request)+"/stop", nil)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return deviceMutationText("Device request stop requested.", data) }, output.ExitOK)

	case "disconnect":
		fs, opts := rt.newFlagSet("bft devices disconnect")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		device := fs.String("device", "", "device id")
		confirm := fs.Bool("confirm-mutating", false, "confirm device disconnect")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("org", *org); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("project", *project); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("device", *device); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if !*confirm {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the device.", map[string]any{"command": "devices.disconnect"}))
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		data, apiErr := api.Post(context.Background(), projectDevicePath(*org, *project, *device)+"/disconnect", nil)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return deviceMutationText("Device disconnected.", data) }, output.ExitOK)
	}

	return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_devices_command", "Unknown devices command.", map[string]any{"command": strings.Join(args, " ")}))
}

func (rt runtime) conversations(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_conversations_command", "Run bft conversations list, show, messages, send, trace, delivery, or redeliver.", nil))
	}

	switch args[0] {
	case "list":
		fs, opts := rt.newFlagSet("bft conversations list")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		limit := fs.Int("limit", defaultConversationLimit, "maximum conversations to return")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("org", *org); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("project", *project); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := validateConversationLimit(*limit); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		data, apiErr := api.Get(context.Background(), "/v1/cli/conversations", map[string]string{"org": *org, "project": *project, "limit": strconv.Itoa(*limit)})
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return conversationsText(data) }, output.ExitOK)

	case "show":
		fs, opts := rt.newFlagSet("bft conversations show")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		conversationID := fs.String("conversation", "", "conversation id")
		messageLimit := fs.Int("message-limit", defaultConversationLimit, "maximum recent messages to include")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := requireConversationFlags(*org, *project, *conversationID, *messageLimit); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		data, apiErr := api.Get(context.Background(), "/v1/cli/conversations/"+urlPathEscape(*conversationID), map[string]string{"org": *org, "project": *project, "message_limit": strconv.Itoa(*messageLimit)})
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return conversationDetailText(data) }, output.ExitOK)

	case "messages":
		fs, opts := rt.newFlagSet("bft conversations messages")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		conversationID := fs.String("conversation", "", "conversation id")
		limit := fs.Int("limit", defaultConversationLimit, "maximum messages to return")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := requireConversationFlags(*org, *project, *conversationID, *limit); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		data, apiErr := api.Get(context.Background(), "/v1/cli/conversations/"+urlPathEscape(*conversationID)+"/messages", map[string]string{"org": *org, "project": *project, "limit": strconv.Itoa(*limit)})
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return conversationMessagesText(data) }, output.ExitOK)

	case "send":
		fs, opts := rt.newFlagSet("bft conversations send")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		conversationID := fs.String("conversation", "", "conversation id")
		messageText := fs.String("text", "", "message text")
		requestID := fs.String("request", "", "stable opaque send request id")
		confirm := fs.Bool("confirm-mutating", false, "confirm conversation message send")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := requireConversationFlags(*org, *project, *conversationID, 1); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		for _, required := range []struct{ name, value string }{{"text", *messageText}, {"request", *requestID}} {
			if err := require(required.name, required.value); err.ExitCode != 0 {
				return output.RenderError(rt.stderr, opts.outputOptions(), err)
			}
		}
		if len([]byte(strings.TrimSpace(*messageText))) > 32_000 {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("conversation_message_too_large", "Conversation message must be at most 32,000 bytes.", nil))
		}
		if !*confirm {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the conversation and message.", map[string]any{"command": "conversations.send"}))
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		body := map[string]any{"org": *org, "project": *project, "text": strings.TrimSpace(*messageText), "request_id": strings.TrimSpace(*requestID)}
		data, apiErr := api.Post(context.Background(), "/v1/cli/conversations/"+urlPathEscape(*conversationID)+"/messages", body)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return conversationSendText(data) }, output.ExitOK)

	case "trace":
		fs, opts := rt.newFlagSet("bft conversations trace")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		conversationID := fs.String("conversation", "", "conversation id")
		participantID := fs.String("participant", "", "conversation participant id")
		limit := fs.Int("limit", defaultConversationLimit, "maximum trace rows to return")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := requireConversationFlags(*org, *project, *conversationID, *limit); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		query := map[string]string{"org": *org, "project": *project, "limit": strconv.Itoa(*limit)}
		if strings.TrimSpace(*participantID) != "" {
			query["participant"] = strings.TrimSpace(*participantID)
		}
		data, apiErr := api.Get(context.Background(), "/v1/cli/conversations/"+urlPathEscape(*conversationID)+"/trace", query)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return conversationTraceText(data) }, output.ExitOK)

	case "delivery":
		fs, opts := rt.newFlagSet("bft conversations delivery")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		conversationID := fs.String("conversation", "", "conversation id")
		participantID := fs.String("participant", "", "conversation participant id")
		messageID := fs.String("message", "", "optional conversation message id")
		limit := fs.Int("limit", defaultConversationLimit, "maximum delivery records to return")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := requireConversationFlags(*org, *project, *conversationID, *limit); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("participant", *participantID); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		query := map[string]string{
			"org":         *org,
			"project":     *project,
			"participant": strings.TrimSpace(*participantID),
			"limit":       strconv.Itoa(*limit),
		}
		if strings.TrimSpace(*messageID) != "" {
			query["message"] = strings.TrimSpace(*messageID)
		}
		data, apiErr := api.Get(context.Background(), "/v1/cli/conversations/"+urlPathEscape(*conversationID)+"/delivery", query)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return conversationDeliveryText(data) }, output.ExitOK)

	case "redeliver":
		fs, opts := rt.newFlagSet("bft conversations redeliver")
		org := fs.String("org", "", "org id or slug")
		project := fs.String("project", "", "project id or slug")
		conversationID := fs.String("conversation", "", "conversation id")
		participantID := fs.String("participant", "", "target agent participant id")
		messageID := fs.String("message", "", "existing conversation message id")
		requestID := fs.String("request", "", "stable opaque redelivery request id")
		confirm := fs.Bool("confirm-mutating", false, "confirm conversation message redelivery")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := requireConversationFlags(*org, *project, *conversationID, 1); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		for _, required := range []struct{ name, value string }{
			{"participant", *participantID},
			{"message", *messageID},
			{"request", *requestID},
		} {
			if err := require(required.name, required.value); err.ExitCode != 0 {
				return output.RenderError(rt.stderr, opts.outputOptions(), err)
			}
		}
		if !*confirm {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the conversation, participant, message, and recovery request id.", map[string]any{"command": "conversations.redeliver"}))
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		body := map[string]any{
			"org":            *org,
			"project":        *project,
			"participant_id": strings.TrimSpace(*participantID),
			"message_id":     strings.TrimSpace(*messageID),
			"request_id":     strings.TrimSpace(*requestID),
		}
		data, apiErr := api.Post(context.Background(), "/v1/cli/conversations/"+urlPathEscape(*conversationID)+"/redeliver", body)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return conversationRedeliveryText(data) }, output.ExitOK)

	default:
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_conversations_command", "Run bft conversations list, show, messages, send, trace, delivery, or redeliver.", map[string]any{"command": args[0]}))
	}
}

func (rt runtime) sso(args []string) int {
	if len(args) == 0 || args[0] != "checks" {
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("missing_sso_command", "Run bft sso checks --org <org>.", nil))
	}
	fs, opts := rt.newFlagSet("bft sso checks")
	org := fs.String("org", "", "org id or slug")
	if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	data, apiErr := api.Post(context.Background(), "/v1/cli/sso/checks", map[string]any{"org": *org})
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return checksText("SSO checks", data) }, output.ExitOK)
}

func (rt runtime) feishu(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_feishu_command", "Run bft feishu app, setup, connect, or checks.", nil))
	}
	switch args[0] {
	case "app":
		return rt.feishuApp(args[1:])
	case "setup":
		return rt.feishuSetup(args[1:], false)
	case "connect":
		if len(args) > 1 && args[1] == "ensure" {
			return rt.feishuSetup(args[2:], true)
		}
	case "checks":
		return rt.feishuChecks(args[1:])
	}
	return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_feishu_command", "Unknown Feishu command.", map[string]any{"command": strings.Join(args, " ")}))
}

func (rt runtime) feishuApp(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_feishu_app_command", "Run bft feishu app plan or upsert.", nil))
	}
	fs, opts := rt.newFlagSet("bft feishu app " + args[0])
	org := fs.String("org", "", "org id or slug")
	appID := fs.String("app-id", "", "Feishu app id")
	displayName := fs.String("display-name", "", "display name")
	appSecretEnv := fs.String("app-secret-env", "", "environment variable containing App Secret")
	verificationTokenEnv := fs.String("verification-token-env", "", "environment variable containing Verification Token")
	encryptKeyEnv := fs.String("encrypt-key-env", "", "environment variable containing Encrypt Key")
	bot := fs.Bool("bot", false, "enable bot surface")
	sso := fs.Bool("sso", false, "enable SSO surface")
	dryRun := fs.Bool("dry-run", false, "preview without writing")
	confirm := fs.Bool("confirm-mutating", false, "confirm mutating write")
	if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("app-id", *appID); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	attrs := map[string]any{
		"app_id":      *appID,
		"bot_enabled": *bot,
		"sso_enabled": *sso,
	}
	putIfPresent(attrs, "display_name", *displayName)
	putSecretFromEnv(attrs, "app_secret", *appSecretEnv, rt.env)
	putSecretFromEnv(attrs, "verification_token", *verificationTokenEnv, rt.env)
	putSecretFromEnv(attrs, "encrypt_key", *encryptKeyEnv, rt.env)

	plan := feishuAppPlan(*org, attrs, *appSecretEnv, *verificationTokenEnv, *encryptKeyEnv)
	if args[0] == "plan" || *dryRun {
		return rt.render(opts.outputOptions(), plan, func() string { return "Feishu app plan.\nWill mutate: false\n" }, output.ExitOK)
	}
	if args[0] != "upsert" {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("unknown_feishu_app_command", "Run bft feishu app plan or upsert.", map[string]any{"command": args[0]}))
	}
	if !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the dry-run output.", map[string]any{"command": "feishu.app.upsert"}))
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	data, apiErr := api.Post(context.Background(), "/v1/cli/feishu/apps", map[string]any{"org": *org, "attrs": attrs})
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return "Feishu app saved.\nSecrets printed: false\n" }, output.ExitOK)
}

func (rt runtime) feishuSetup(args []string, ensureConnect bool) int {
	fs, opts := rt.newFlagSet("bft feishu setup")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	appID := fs.String("app-id", "", "Feishu app id")
	appName := fs.String("app-name", "", "Feishu app name")
	connectID := fs.String("connect-id", "", "connect id")
	confirm := fs.Bool("confirm-mutating", false, "confirm mutating write")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if ensureConnect && !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the setup output.", map[string]any{"command": "feishu.connect.ensure"}))
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	body := map[string]any{"org": *org, "project": *project, "ensure_connect": ensureConnect}
	putIfPresent(body, "app_id", *appID)
	putIfPresent(body, "app_name", *appName)
	putIfPresent(body, "connect_id", *connectID)
	path := "/v1/cli/feishu/setup"
	if ensureConnect {
		path = "/v1/cli/feishu/connect"
	}
	data, apiErr := api.Post(context.Background(), path, body)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return feishuSetupText(data) }, output.ExitOK)
}

func (rt runtime) feishuChecks(args []string) int {
	fs, opts := rt.newFlagSet("bft feishu checks")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	connectID := fs.String("connect-id", "", "connect id")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	body := map[string]any{"org": *org, "project": *project}
	putIfPresent(body, "connect_id", *connectID)
	data, apiErr := api.Post(context.Background(), "/v1/cli/feishu/checks", body)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return checksText("Feishu checks", data) }, output.ExitOK)
}

func (rt runtime) slack(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_slack_command", "Run bft slack setup or bft slack connects.", nil))
	}
	switch args[0] {
	case "setup":
		return rt.slackSetup(args[1:])
	case "connects":
		return rt.slackConnects(args[1:])
	default:
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_slack_command", "Run bft slack setup or bft slack connects.", map[string]any{"command": strings.Join(args, " ")}))
	}
}

func (rt runtime) meetings(args []string) int {
	if len(args) >= 1 && args[0] == "replay" {
		return rt.meetingsReplay(args[1:])
	}
	if len(args) < 2 || args[0] != "calendar" || args[1] != "status" {
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("missing_meetings_command", "Run bft meetings calendar status or bft meetings replay.", nil))
	}

	fs, opts := rt.newFlagSet("bft meetings calendar status")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	connectID := fs.String("connect", "", "Slack connect id")
	limit := fs.Int("limit", defaultCalendarStatusLimit, "maximum projected meetings to return")
	if err := parse(fs, args[2:], opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if *limit < 1 || *limit > maxCalendarStatusLimit {
		err := output.Usage("invalid_limit", "Pass --limit between 1 and 50.", map[string]any{"limit": *limit, "min": 1, "max": maxCalendarStatusLimit})
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}

	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	query := map[string]string{
		"org":     *org,
		"project": *project,
		"limit":   strconv.Itoa(*limit),
	}
	if strings.TrimSpace(*connectID) != "" {
		query["connect_id"] = strings.TrimSpace(*connectID)
	}
	data, apiErr := api.Get(context.Background(), "/v1/cli/meetings/calendar/status", query)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return meetingCalendarStatusText(data) }, meetingCalendarStatusExit(data))
}

func (rt runtime) meetingsReplay(args []string) int {
	fs, opts := rt.newFlagSet("bft meetings replay")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	meetingID := fs.String("meeting", "", "stored terminal meeting id")
	requestID := fs.String("request", "", "stable idempotency request id")
	runModel := fs.Bool("run-model", false, "run the configured meeting-summary model after structural checks")
	confirm := fs.Bool("confirm-mutating", false, "confirm the billable model replay")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	for name, value := range map[string]string{"org": *org, "project": *project, "meeting": *meetingID, "request": *requestID} {
		if err := require(name, value); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
	}
	if *runModel && !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating to acknowledge the configured model calls. Replay never writes Slack, Canvas, or Linear.", map[string]any{"command": "meetings.replay"}))
	}
	if !*runModel && *confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_without_model", "Pass --confirm-mutating only together with --run-model.", nil))
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api.HTTPClient.Timeout = 5 * time.Minute
	data, apiErr := api.Post(context.Background(), "/v1/cli/meetings/replay", map[string]any{
		"org":                  *org,
		"project":              *project,
		"meeting_id":           strings.TrimSpace(*meetingID),
		"request_id":           strings.TrimSpace(*requestID),
		"run_model":            *runModel,
		"confirm_model_replay": *confirm,
	})
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return meetingReplayText(data) }, meetingReplayExit(data))
}

func (rt runtime) slackSetup(args []string) int {
	fs, opts := rt.newFlagSet("bft slack setup")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	appName := fs.String("app-name", "", "Slack app name")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	body := map[string]any{"org": *org, "project": *project}
	putIfPresent(body, "app_name", *appName)
	data, apiErr := api.Post(context.Background(), "/v1/cli/slack/setup", body)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return slackSetupText(data) }, output.ExitOK)
}

func (rt runtime) slackConnects(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_slack_connects_command", "Run bft slack connects list, create, update, disable, enable, or delete.", nil))
	}
	switch args[0] {
	case "list":
		return rt.slackConnectsList(args[1:])
	case "create":
		return rt.slackConnectsCreate(args[1:])
	case "update":
		return rt.slackConnectsUpdate(args[1:])
	case "disable", "enable", "delete":
		return rt.slackConnectsLifecycle(args[0], args[1:])
	default:
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_slack_connects_command", "Run bft slack connects list, create, update, disable, enable, or delete.", map[string]any{"command": strings.Join(args, " ")}))
	}
}

func (rt runtime) slackConnectsList(args []string) int {
	fs, opts := rt.newFlagSet("bft slack connects list")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	data, apiErr := api.Get(context.Background(), slackConnectsPath(*org, *project), nil)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return slackConnectsText(data) }, output.ExitOK)
}

func (rt runtime) slackConnectsCreate(args []string) int {
	fs, opts := rt.newFlagSet("bft slack connects create")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	appName := fs.String("app-name", "", "Slack app name")
	appID := fs.String("app-id", "", "Slack app id")
	clientID := fs.String("client-id", "", "Slack client id")
	clientSecretEnv := fs.String("client-secret-env", "", "environment variable containing Slack client secret")
	signingSecretEnv := fs.String("signing-secret-env", "", "environment variable containing Slack signing secret")
	inboundAgent := fs.String("inbound-agent", "", "Salix agent id that should receive inbound Slack messages")
	confirm := fs.Bool("confirm-mutating", false, "confirm mutating write")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("app-id", *appID); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("client-id", *clientID); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the Slack app credentials.", map[string]any{"command": "slack.connects.create"}))
	}
	resolvedClientSecret, secretErr := requiredSecretEnv("client-secret", *clientSecretEnv, rt.env)
	if secretErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), secretErr)
	}
	resolvedSigningSecret, signingErr := requiredSecretEnv("signing-secret", *signingSecretEnv, rt.env)
	if signingErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), signingErr)
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	body := map[string]any{
		"app_id":         *appID,
		"client_id":      *clientID,
		"client_secret":  resolvedClientSecret,
		"signing_secret": resolvedSigningSecret,
	}
	putIfPresent(body, "app_name", *appName)
	putIfPresent(body, "inbound_agent_id", *inboundAgent)
	data, apiErr := api.Post(context.Background(), slackConnectsPath(*org, *project), body)
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return slackConnectText("Slack connect created.", data) }, output.ExitOK)
}

func (rt runtime) slackConnectsUpdate(args []string) int {
	fs, opts := rt.newFlagSet("bft slack connects update")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	connectID := fs.String("connect", "", "Slack connect id")
	inboundAgent := fs.String("inbound-agent", "", "Salix agent id that should receive inbound Slack messages")
	confirm := fs.Bool("confirm-mutating", false, "confirm mutating write")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("connect", *connectID); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("inbound-agent", *inboundAgent); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the target connect and inbound agent.", map[string]any{"command": "slack.connects.update"}))
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	path := slackConnectsPath(*org, *project) + "/" + urlPathEscape(*connectID)
	data, apiErr := api.Patch(context.Background(), path, map[string]any{"inbound_agent_id": *inboundAgent})
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return slackConnectText("Slack connect updated.", data) }, output.ExitOK)
}

func (rt runtime) slackConnectsLifecycle(action string, args []string) int {
	fs, opts := rt.newFlagSet("bft slack connects " + action)
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	connectID := fs.String("connect", "", "Slack connect id")
	confirm := fs.Bool("confirm-mutating", false, "confirm mutating write")
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("org", *org); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("project", *project); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if err := require("connect", *connectID); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	if !*confirm {
		return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the target connect.", map[string]any{"command": "slack.connects." + action}))
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	path := slackConnectsPath(*org, *project) + "/" + urlPathEscape(*connectID)
	var data map[string]any
	var apiErr output.Error
	if action == "delete" {
		data, apiErr = api.Delete(context.Background(), path, nil)
	} else {
		data, apiErr = api.Post(context.Background(), path+"/"+action, nil)
	}
	if apiErr.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
	}
	return rt.render(opts.outputOptions(), data, func() string { return slackConnectText("Slack connect "+action+"d.", data) }, output.ExitOK)
}

func (rt runtime) runners(args []string) int {
	if len(args) == 0 {
		return output.RenderError(rt.stderr, rt.defaultOutputOptions(), output.Usage("missing_runners_command", "Run bft runners install-command or list.", nil))
	}
	switch args[0] {
	case "install-command":
		fs, opts := rt.newFlagSet("bft runners install-command")
		org := fs.String("org", "", "org id or slug")
		runner := fs.String("runner", "", "existing runner id or stable id to reinstall")
		confirm := fs.Bool("confirm-mutating", false, "confirm one-time runner install command creation")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("org", *org); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if !*confirm {
			return output.RenderError(rt.stderr, opts.outputOptions(), output.Usage("confirm_mutating_required", "Pass --confirm-mutating after reviewing the target organization and runner.", map[string]any{"command": "runners.install-command"}))
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		path := orgRunnersPath(*org) + "/install-command"
		if strings.TrimSpace(*runner) != "" {
			path += "?runner=" + url.QueryEscape(strings.TrimSpace(*runner))
		}
		data, apiErr := api.Post(context.Background(), path, nil)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		return rt.render(opts.outputOptions(), data, func() string { return runnerInstallText(data) }, output.ExitOK)
	case "list":
		fs, opts := rt.newFlagSet("bft runners list")
		org := fs.String("org", "", "org id or slug")
		limit := fs.Int("limit", defaultListLimit, "maximum rows to return")
		filter := fs.String("filter", "", "case-insensitive substring filter")
		if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := require("org", *org); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		if err := validateListLimit(*limit); err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), err)
		}
		query := listQuery(*limit, *filter)
		data, apiErr := api.Get(context.Background(), orgRunnersPath(*org), query)
		if apiErr.ExitCode != 0 {
			return output.RenderError(rt.stderr, opts.outputOptions(), apiErr)
		}
		data = boundList(data, "runners", *limit, *filter)
		return rt.render(opts.outputOptions(), data, func() string { return runnersText(data) }, output.ExitOK)
	}
	return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("unknown_runners_command", "Unknown runner command.", map[string]any{"command": strings.Join(args, " ")}))
}

func (rt runtime) onboarding(args []string) int {
	if len(args) == 0 || args[0] != "smoke" {
		return output.RenderError(rt.stderr, rt.fallbackOutputOptions(args), output.Usage("missing_onboarding_command", "Run bft onboarding smoke --step <step>.", nil))
	}
	fs, opts := rt.newFlagSet("bft onboarding smoke")
	step := fs.String("step", "context", "onboarding step")
	org := fs.String("org", "", "org id or slug")
	project := fs.String("project", "", "project id or slug")
	appID := fs.String("app-id", "", "Feishu app id")
	larkCLI := fs.String("lark-cli", "lark-cli", "lark/Feishu CLI path")
	assistLarkAppInit := fs.Bool("assist-lark-app-init", false, "emit an assisted lark-cli config init --new gate without running it")
	targetChatID := fs.String("target-chat-id", "", "target chat id")
	targetChatName := fs.String("target-chat-name", "", "target chat name")
	runID := fs.String("run-id", "default", "run id")
	if err := parse(fs, args[1:], opts); err.ExitCode != 0 {
		return output.RenderError(rt.stderr, opts.outputOptions(), err)
	}
	ranAt := time.Now().UTC().Format(time.RFC3339)
	payload, exitCode := rt.onboardingPayload(opts, *step, *org, *project, *appID, *larkCLI, *assistLarkAppInit, *targetChatID, *targetChatName, *runID, ranAt)
	return rt.render(opts.outputOptions(), payload, func() string { return onboardingText(payload) }, exitCode)
}

func (rt runtime) onboardingPayload(opts *commonOptions, step, org, project, appID, larkCLI string, assistLarkAppInit bool, targetChatID, targetChatName, runID, ranAt string) (map[string]any, int) {
	gates := []map[string]any{}
	commands := []map[string]any{{"command_id": "onboarding.smoke." + step, "exit_code": output.ExitOK}}
	exitCode := output.ExitOK

	switch step {
	case "cli-login":
		api, err := rt.apiClient(opts)
		if err.ExitCode != 0 {
			gates = append(gates, assistedGate("auth.status", "BFT CLI API session", "Run bft auth login, approve the device login in the dashboard, then rerun this step."))
			exitCode = output.ExitNeedsManual
		} else if _, apiErr := api.Get(context.Background(), "/v1/cli/orgs", nil); apiErr.ExitCode != 0 {
			gates = append(gates, map[string]any{"gate_id": "auth.status", "label": "BFT CLI API session", "classification": "blocked", "status": "fail", "reason_class": apiErr.Code, "required": true, "next_action": apiErr.Message, "evidence": apiErr.Details, "redacted": true})
			exitCode = apiErr.ExitCode
		} else {
			gates = append(gates, okGate("auth.status", "BFT CLI API session", "CLI session can reach the BFT API."))
		}
	case "context":
		if org == "" || project == "" {
			gates = append(gates, assistedGate("context", "BFT org and Agent Swarm context", "Pass --org and --project, then rerun this step."))
			exitCode = output.ExitNeedsManual
		} else {
			api, err := rt.apiClient(opts)
			if err.ExitCode != 0 {
				gates = append(gates, assistedGate("auth.status", "BFT CLI API session", "Run bft auth login, approve the device login in the dashboard, then rerun this step."))
				exitCode = output.ExitNeedsManual
			} else if data, apiErr := api.Get(context.Background(), "/v1/cli/context", map[string]string{"org": org, "project": project}); apiErr.ExitCode != 0 {
				gates = append(gates, map[string]any{"gate_id": "context", "label": "BFT org and Agent Swarm context", "classification": "blocked", "status": "fail", "reason_class": apiErr.Code, "required": true, "next_action": apiErr.Message, "evidence": apiErr.Details, "redacted": true})
				exitCode = apiErr.ExitCode
			} else {
				gates = append(gates, okGateWithEvidence("context", "BFT org and Agent Swarm context", "BFT org/project context resolved.", data["context"]))
			}
		}
	case "feishu-cli":
		if larkAvailable(larkCLI) {
			gates = append(gates, okGate("lark-cli.ready", "Lark/Feishu CLI readiness", "lark-cli is discoverable; continue to bft onboarding smoke --step feishu-app."))
			if assistLarkAppInit {
				gates = append(gates, assistedGate("lark-cli.config-init.new", "Feishu app creation via lark-cli", "Ask the admin to run lark-cli config init --new and finish the browser/app creation flow, then rerun with --step feishu-app."))
				exitCode = output.ExitNeedsManual
			}
		} else {
			gates = append(gates, assistedGate("lark-cli.ready", "Lark/Feishu CLI readiness", "Install lark-cli or pass --lark-cli with the correct path, then rerun."))
			exitCode = output.ExitNeedsManual
		}
	case "target-group":
		if targetChatID != "" || targetChatName != "" {
			gates = append(gates, okGateWithEvidence("target_group.selected", "Target Feishu group selected", "Target Feishu group selected; add the bot and run first-message smoke.", map[string]any{"target_chat_id_configured": targetChatID != "", "target_chat_name_configured": targetChatName != ""}))
		} else {
			gates = append(gates, assistedGate("target_group.selected", "Target Feishu group selected", "Pass --target-chat-id or --target-chat-name after the user identifies the Feishu group."))
			exitCode = output.ExitNeedsManual
		}
	case "first-message":
		gates = append(gates, map[string]any{"gate_id": "bot.first_message", "label": "First message round-trips", "classification": "manual", "status": "needs_manual", "reason_class": "real_feishu_message_required", "required": true, "next_action": "Send a real @Bridge message in the target Feishu group and verify a reply.", "evidence": map[string]any{}, "redacted": true})
		exitCode = output.ExitNeedsManual
	case "runner":
		payload, code := rt.runnerSmoke(opts, org)
		gates = append(gates, payload...)
		exitCode = code
	case "sso", "admin-login", "feishu-app", "feishu-connect", "feishu-checks":
		gates, exitCode = rt.apiBackedSmoke(opts, step, org, project, appID)
	default:
		gates = append(gates, map[string]any{"gate_id": "onboarding." + step, "label": "Onboarding " + step, "classification": "blocked", "status": "fail", "reason_class": "invalid_onboarding_step", "required": true, "next_action": "Use bft commands --json to inspect supported onboarding steps.", "evidence": map[string]any{"step": step}, "redacted": true})
		exitCode = output.ExitUsage
	}

	status := onboardingStatus(gates)
	if status == "needs_manual" && exitCode == output.ExitOK {
		exitCode = output.ExitNeedsManual
	}
	if status == "blocked" && exitCode == output.ExitOK {
		exitCode = output.ExitUnavailable
	}
	if len(commands) > 0 {
		commands[0]["exit_code"] = exitCode
	}
	return map[string]any{
		"mode":           "onboarding_smoke",
		"schema_version": "bft.onboarding_smoke.v1",
		"status":         status,
		"run_id":         runID,
		"step_id":        step,
		"depends_on":     dependsOn(step),
		"resume_key": map[string]any{
			"step_id":          step,
			"org":              emptyNil(org),
			"project":          emptyNil(project),
			"app_id":           emptyNil(appID),
			"lark_cli":         emptyNil(larkCLI),
			"assist_lark_init": assistLarkAppInit,
			"target_chat_id":   emptyNil(targetChatID),
			"target_chat_name": emptyNil(targetChatName),
		},
		"ran_at":      ranAt,
		"next_action": nextAction(gates, status),
		"summary":     summary(gates),
		"gates":       gates,
		"commands":    commands,
	}, exitCode
}

func (rt runtime) apiBackedSmoke(opts *commonOptions, step, org, project, appID string) ([]map[string]any, int) {
	if org == "" {
		return []map[string]any{assistedGate("onboarding."+step, "Onboarding "+step, "Pass --org, then rerun this step.")}, output.ExitNeedsManual
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return []map[string]any{assistedGate("auth.status", "BFT CLI API session", "Run bft auth login, approve the device login in the dashboard, then rerun this step.")}, output.ExitNeedsManual
	}
	switch step {
	case "sso":
		data, apiErr := api.Post(context.Background(), "/v1/cli/sso/checks", map[string]any{"org": org})
		if apiErr.ExitCode != 0 {
			return []map[string]any{blockedGate("sso", "Feishu SSO checks", apiErr)}, apiErr.ExitCode
		}
		return gatesFromChecks(data), output.ExitOK
	case "admin-login":
		data, apiErr := api.Post(context.Background(), "/v1/cli/sso/checks", map[string]any{"org": org})
		if apiErr.ExitCode != 0 {
			return []map[string]any{blockedGate("sso.admin_login", "Current admin has signed in with Feishu SSO", apiErr)}, apiErr.ExitCode
		}
		gate, _ := data["admin_login"].(map[string]any)
		if gate == nil {
			return []map[string]any{assistedGate("sso.admin_login", "Current admin has signed in with Feishu SSO", "Sign in through Feishu SSO as an org admin, generate a fresh CLI login command, then rerun.")}, output.ExitNeedsManual
		}
		return []map[string]any{normalizeGate(gate)}, output.ExitOK
	case "feishu-app":
		data, apiErr := api.Get(context.Background(), "/v1/cli/feishu/apps/selected", map[string]string{"org": org, "app_id": appID})
		if apiErr.ExitCode != 0 {
			return []map[string]any{blockedGate("feishu.app.selected", "Feishu app binding selected", apiErr)}, apiErr.ExitCode
		}
		selected, _ := data["selected_app"].(map[string]any)
		if selected != nil && selected["binding"] != nil {
			return []map[string]any{okGateWithEvidence("feishu.app.selected", "Feishu app binding selected", "Feishu app binding is available; continue to feishu-connect.", selected)}, output.ExitOK
		}
		return []map[string]any{assistedGate("feishu.app.selected", "Feishu app binding selected", "Save a bot-enabled Feishu app binding, then rerun this step.")}, output.ExitNeedsManual
	case "feishu-connect":
		if project == "" {
			return []map[string]any{assistedGate("feishu.connect.ensure", "Feishu connect ensure", "Pass --project, then rerun this step.")}, output.ExitNeedsManual
		}
		body := map[string]any{"org": org, "project": project}
		putIfPresent(body, "app_id", appID)
		data, apiErr := api.Post(context.Background(), "/v1/cli/feishu/setup", body)
		if apiErr.ExitCode != 0 {
			return []map[string]any{blockedGate("feishu.connect.ensure", "Feishu connect ensure", apiErr)}, apiErr.ExitCode
		}
		if data["connect"] != nil {
			return []map[string]any{okGateWithEvidence("feishu.connect.ensure", "Feishu connect ensure", "Feishu connect exists; continue to feishu-checks.", data)}, output.ExitOK
		}
		return []map[string]any{assistedGate("feishu.connect.ensure", "Feishu connect ensure", "Run bft feishu connect ensure --confirm-mutating after reviewing setup output.")}, output.ExitNeedsManual
	case "feishu-checks":
		if project == "" {
			return []map[string]any{assistedGate("feishu.checks", "Feishu checks", "Pass --project, then rerun this step.")}, output.ExitNeedsManual
		}
		data, apiErr := api.Post(context.Background(), "/v1/cli/feishu/checks", map[string]any{"org": org, "project": project})
		if apiErr.ExitCode != 0 {
			return []map[string]any{blockedGate("feishu.checks", "Feishu checks", apiErr)}, apiErr.ExitCode
		}
		return gatesFromChecks(data), output.ExitOK
	}
	return []map[string]any{assistedGate("onboarding."+step, "Onboarding "+step, "This step is not implemented yet.")}, output.ExitNeedsManual
}

func (rt runtime) runnerSmoke(opts *commonOptions, org string) ([]map[string]any, int) {
	if org == "" {
		return []map[string]any{assistedGate("runner.heartbeat", "Runner heartbeat", "Pass --org, then rerun this step.")}, output.ExitNeedsManual
	}
	api, err := rt.apiClient(opts)
	if err.ExitCode != 0 {
		return []map[string]any{assistedGate("auth.status", "BFT CLI API session", "Run bft auth login, approve the device login in the dashboard, then rerun this step.")}, output.ExitNeedsManual
	}
	data, apiErr := api.Get(context.Background(), orgRunnersPath(org), nil)
	if apiErr.ExitCode != 0 {
		return []map[string]any{blockedGate("runner.heartbeat", "Runner heartbeat", apiErr)}, apiErr.ExitCode
	}
	summary, _ := data["summary"].(map[string]any)
	if ready, _ := summary["ready"].(bool); ready {
		return []map[string]any{okGateWithEvidence("runner.heartbeat", "Runner heartbeat", "A runner has a recent heartbeat.", summary)}, output.ExitOK
	}
	return []map[string]any{map[string]any{"gate_id": "runner.heartbeat", "label": "Runner heartbeat", "classification": "assisted", "status": "needs_manual", "reason_class": "runner_missing", "required": true, "next_action": "After operator approval, run bft runners install-command --org " + org + " --confirm-mutating, execute the returned command on the target machine, start bft-runner there, then rerun.", "evidence": summary, "redacted": true}}, output.ExitNeedsManual
}

func (rt runtime) apiClient(opts *commonOptions) (client.Client, output.Error) {
	cfg, cfgErr := config.Load(opts.configPath, config.Env(rt.env))
	if cfgErr != nil {
		return client.Client{}, output.Error{ExitCode: output.ExitSoftware, Code: "invalid_config", Message: "Could not read local BFT CLI config.", Details: map[string]any{"reason": cfgErr.Error()}}
	}
	baseURL, baseErr := resolveBase(opts, cfg, rt.env)
	if baseErr.ExitCode != 0 {
		return client.Client{}, baseErr
	}
	token, tokenEnv := config.ResolveToken(config.Options{TokenEnv: opts.tokenEnv}, cfg, config.Env(rt.env))
	if strings.TrimSpace(token) == "" {
		return client.Client{}, output.Usage("missing_api_token", "Run bft auth login first.", map[string]any{"token_env": tokenEnv})
	}
	return client.New(baseURL, token), output.Error{}
}

func resolveBase(opts *commonOptions, cfg config.Config, env envFunc) (string, output.Error) {
	base, err := config.ResolveBaseURL(config.Options{
		ConfigPath: opts.configPath,
		URL:        opts.url,
		APIBaseURL: opts.apiBaseURL,
		EnvName:    opts.envName,
		TokenEnv:   opts.tokenEnv,
	}, cfg, config.Env(env))
	if err == nil {
		return base, output.Error{}
	}
	if unknown, ok := err.(config.UnknownEnvironmentError); ok {
		return "", output.Usage("unknown_bft_environment", "Unknown BFT environment. Use --env prod, --env staging, --env local, or pass --url for self-hosted deployments.", map[string]any{"env": unknown.Env, "supported_envs": config.SupportedEnvs()})
	}
	return "", output.Error{ExitCode: output.ExitSoftware, Code: "api_base_url_failed", Message: "Could not resolve BFT API URL.", Details: map[string]any{"reason": err.Error()}}
}

func newFlagSet(name string) (*flag.FlagSet, *commonOptions) {
	opts := &commonOptions{}
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	fs.BoolVar(&opts.json, "json", false, "write JSON to stdout")
	fs.BoolVar(&opts.quiet, "quiet", false, "suppress nonessential text output")
	fs.BoolVar(&opts.nonInteractive, "non-interactive", false, "fail instead of prompting")
	fs.StringVar(&opts.outputFormat, "output", "", "output format: json or text")
	fs.StringVar(&opts.fields, "fields", "", "comma-separated top-level JSON data fields to include")
	fs.StringVar(&opts.configPath, "config", "", "config path")
	fs.StringVar(&opts.url, "url", "", "BFT base URL for self-hosted/local deployments")
	fs.StringVar(&opts.apiBaseURL, "api-base-url", "", "deprecated alias for --url")
	fs.StringVar(&opts.envName, "env", "", "BFT environment: prod, staging, local")
	fs.StringVar(&opts.tokenEnv, "token-env", "", "environment variable containing a CLI token")
	return fs, opts
}

func (rt runtime) newFlagSet(name string) (*flag.FlagSet, *commonOptions) {
	fs, opts := newFlagSet(name)
	opts.defaultJSON = rt.defaultJSON
	return fs, opts
}

func parse(fs *flag.FlagSet, args []string, opts *commonOptions) output.Error {
	if err := fs.Parse(args); err != nil {
		return output.Usage("invalid_arguments", err.Error(), nil)
	}
	if outputFlag := fs.Lookup("output"); outputFlag != nil {
		format := strings.TrimSpace(strings.ToLower(outputFlag.Value.String()))
		if format != "" && format != "json" && format != "text" {
			return output.Usage("invalid_output_format", "Unsupported output format.", map[string]any{"format": outputFlag.Value.String(), "supported_formats": []string{"json", "text"}})
		}
		if jsonFlag := fs.Lookup("json"); jsonFlag != nil && jsonFlag.Value.String() == "true" && format == "text" {
			return output.Usage("conflicting_output_format", "Use either --json or --output text.", map[string]any{"json": true, "output": "text"})
		}
		fields := ""
		if fieldsFlag := fs.Lookup("fields"); fieldsFlag != nil {
			fields = strings.TrimSpace(fieldsFlag.Value.String())
		}
		if fields != "" && !opts.jsonEnabled() {
			return output.Usage("fields_require_json", "Use --fields only with JSON output. Add --json, --output json, or pipe stdout.", map[string]any{"fields": fields})
		}
	}
	if rest := fs.Args(); len(rest) > 0 {
		return output.Usage("unexpected_arguments", "Unexpected command arguments.", map[string]any{"args": rest})
	}
	return output.Error{}
}

func parseCommon(args []string, defaultJSON bool) (commonOptions, output.Error) {
	fs, opts := newFlagSet("bft commands")
	opts.defaultJSON = defaultJSON
	if err := parse(fs, args, opts); err.ExitCode != 0 {
		return *opts, err
	}
	return *opts, output.Error{}
}

func (opts commonOptions) outputOptions() output.Options {
	return output.Options{JSON: opts.jsonEnabled(), Quiet: opts.quiet, Fields: parseFields(opts.fields)}
}

func (opts commonOptions) jsonEnabled() bool {
	format := strings.ToLower(strings.TrimSpace(opts.outputFormat))
	if format == "text" {
		return false
	}
	return opts.defaultJSON || opts.json || format == "json"
}

func (rt runtime) defaultOutputOptions() output.Options {
	return output.Options{JSON: rt.defaultJSON}
}

func (rt runtime) fallbackOutputOptions(args []string) output.Options {
	return output.Options{JSON: outputJSONFromArgs(args, rt.defaultJSON)}
}

func outputJSONFromArgs(args []string, defaultJSON bool) bool {
	jsonEnabled := defaultJSON
	for i := 0; i < len(args); i++ {
		arg := args[i]
		switch {
		case arg == "--json":
			jsonEnabled = true
		case arg == "--output" && i+1 < len(args):
			switch strings.ToLower(strings.TrimSpace(args[i+1])) {
			case "json":
				jsonEnabled = true
			case "text":
				jsonEnabled = false
			}
			i++
		case strings.HasPrefix(arg, "--output="):
			switch strings.ToLower(strings.TrimSpace(strings.TrimPrefix(arg, "--output="))) {
			case "json":
				jsonEnabled = true
			case "text":
				jsonEnabled = false
			}
		}
	}
	return jsonEnabled
}

func (rt runtime) render(opts output.Options, data any, text func() string, exitCode int) int {
	return output.RenderSuccess(rt.stdout, opts, data, text, exitCode)
}

func shouldDefaultJSON(stdout io.Writer) bool {
	file, ok := stdout.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	if err != nil {
		return false
	}
	return info.Mode()&os.ModeCharDevice == 0
}

const (
	defaultListLimit           = 50
	defaultConversationLimit   = 100
	defaultCalendarStatusLimit = 20
	maxListLimit               = 200
	maxCalendarStatusLimit     = 50
)

func validateListLimit(limit int) output.Error {
	if limit < 1 || limit > maxListLimit {
		return output.Usage("invalid_limit", "Pass --limit between 1 and "+strconv.Itoa(maxListLimit)+".", map[string]any{"limit": limit, "min": 1, "max": maxListLimit})
	}
	return output.Error{}
}

func validateConversationLimit(limit int) output.Error {
	if limit < 1 {
		return output.Usage("invalid_limit", "Pass a positive limit.", map[string]any{"limit": limit, "min": 1})
	}
	return output.Error{}
}

func validateAgentRole(role string) output.Error {
	switch strings.TrimSpace(role) {
	case "router", "worker":
		return output.Error{}
	default:
		return output.Usage("invalid_role", "Pass --role router or worker.", map[string]any{"role": role})
	}
}

func validateAgentRuntimeFlags(kind, provider, deviceID, runtimeID, deviceRuntimeID string) output.Error {
	switch strings.TrimSpace(kind) {
	case "internal":
		return output.Error{}
	case "external":
		if strings.TrimSpace(provider) != "codex" {
			return output.Usage("invalid_runtime_provider", "Pass --runtime-provider codex.", map[string]any{"runtime_provider": provider})
		}
		if err := require("device-id", deviceID); err.ExitCode != 0 {
			return err
		}
		if err := require("runtime-id", runtimeID); err.ExitCode != 0 {
			return err
		}
		if err := require("device-runtime-id", deviceRuntimeID); err.ExitCode != 0 {
			return err
		}
		return output.Error{}
	default:
		return output.Usage("invalid_runtime_kind", "Pass --runtime-kind internal or external.", map[string]any{"runtime_kind": kind})
	}
}

func listQuery(limit int, filter string) map[string]string {
	query := map[string]string{"limit": strconv.Itoa(limit)}
	if strings.TrimSpace(filter) != "" {
		query["filter"] = strings.TrimSpace(filter)
	}
	return query
}

func boundList(data map[string]any, key string, limit int, filter string) map[string]any {
	items, ok := data[key].([]any)
	if !ok {
		return data
	}
	filtered := make([]any, 0, len(items))
	for _, item := range items {
		if itemMatches(item, filter) {
			filtered = append(filtered, item)
		}
	}
	returned := filtered
	truncated := false
	if len(returned) > limit {
		returned = returned[:limit]
		truncated = true
	}
	data[key] = returned
	data["list"] = map[string]any{
		"collection": key,
		"limit":      limit,
		"filter":     emptyNil(strings.TrimSpace(filter)),
		"available":  len(items),
		"matched":    len(filtered),
		"returned":   len(returned),
		"truncated":  truncated,
	}
	return data
}

func filterAgentRuntimes(data map[string]any, includeUnavailable bool) map[string]any {
	if includeUnavailable {
		return data
	}
	runtimes, _ := data["runtimes"].([]any)
	filtered := make([]any, 0, len(runtimes))
	for _, raw := range runtimes {
		row, _ := raw.(map[string]any)
		if runtimeBindable(row) {
			filtered = append(filtered, raw)
		}
	}
	result := make(map[string]any, len(data))
	for key, value := range data {
		result[key] = value
	}
	result["runtimes"] = filtered
	return result
}

func runtimeBindable(runtime map[string]any) bool {
	status := strings.TrimSpace(stringField(runtime, "status"))
	return (status == "available" || status == "ready") &&
		runtimeFlagNotFalse(runtime, "ready") &&
		runtimeFlagNotFalse(runtime, "auth_ready") &&
		runtimeFlagNotFalse(runtime, "app_server_startable")
}

func runtimeFlagNotFalse(runtime map[string]any, key string) bool {
	if runtime == nil {
		return true
	}
	value, ok := runtime[key]
	if !ok || value == nil {
		return true
	}
	switch typed := value.(type) {
	case bool:
		return typed
	case string:
		return strings.ToLower(strings.TrimSpace(typed)) != "false"
	default:
		return true
	}
}

func itemMatches(item any, filter string) bool {
	needle := strings.ToLower(strings.TrimSpace(filter))
	if needle == "" {
		return true
	}
	switch value := item.(type) {
	case map[string]any:
		for _, raw := range value {
			if strings.Contains(strings.ToLower(fmt.Sprint(raw)), needle) {
				return true
			}
		}
		return false
	default:
		return strings.Contains(strings.ToLower(fmt.Sprint(value)), needle)
	}
}

func splitTopicArgs(args []string) (string, []string, output.Error) {
	var topic string
	flagArgs := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if strings.HasPrefix(arg, "-") {
			flagArgs = append(flagArgs, arg)
			if flagNeedsValue(arg) && !strings.Contains(arg, "=") {
				if i+1 >= len(args) {
					return "", flagArgs, output.Usage("invalid_arguments", "flag needs an argument: "+arg, map[string]any{"flag": arg})
				}
				i++
				flagArgs = append(flagArgs, args[i])
			}
			continue
		}
		if topic != "" {
			return "", flagArgs, output.Usage("unexpected_arguments", "Pass at most one positional argument.", map[string]any{"args": []string{topic, arg}})
		}
		topic = arg
	}
	return topic, flagArgs, output.Error{}
}

func flagNeedsValue(arg string) bool {
	name := strings.SplitN(arg, "=", 2)[0]
	switch name {
	case "--output", "--fields", "--config", "--url", "--api-base-url", "--env", "--token-env", "--client-name":
		return true
	default:
		return false
	}
}

func parseFields(value string) []string {
	parts := strings.Split(value, ",")
	fields := make([]string, 0, len(parts))
	for _, part := range parts {
		field := strings.TrimSpace(part)
		if field != "" {
			fields = append(fields, field)
		}
	}
	return fields
}

func require(name, value string) output.Error {
	if strings.TrimSpace(value) == "" {
		return output.Usage("missing_"+strings.ReplaceAll(name, "-", "_"), "Pass --"+name+".", map[string]any{"flag": "--" + name})
	}
	return output.Error{}
}

func requireConversationFlags(org, project, conversationID string, limit int) output.Error {
	if err := require("org", org); err.ExitCode != 0 {
		return err
	}
	if err := require("project", project); err.ExitCode != 0 {
		return err
	}
	if err := require("conversation", conversationID); err.ExitCode != 0 {
		return err
	}
	return validateConversationLimit(limit)
}

func urlPathEscape(value string) string {
	return url.PathEscape(strings.TrimSpace(value))
}

func slackConnectsPath(org, project string) string {
	return "/v1/orgs/" + urlPathEscape(org) + "/projects/" + urlPathEscape(project) + "/im/slack/connects"
}

func projectAgentsPath(org, project string) string {
	return "/v1/orgs/" + urlPathEscape(org) + "/projects/" + urlPathEscape(project) + "/agents"
}

func projectAgentRuntimesPath(org, project string) string {
	return projectAgentsPath(org, project) + "/runtimes"
}

func projectAgentRuntimePath(org, project, agent string) string {
	return projectAgentsPath(org, project) + "/" + urlPathEscape(agent) + "/runtime"
}

func projectDevicesPath(org, project string) string {
	return "/v1/orgs/" + urlPathEscape(org) + "/projects/" + urlPathEscape(project) + "/devices"
}

func orgRunnersPath(org string) string {
	return "/v1/orgs/" + urlPathEscape(org) + "/runners"
}

func projectDevicePath(org, project, device string) string {
	return projectDevicesPath(org, project) + "/" + urlPathEscape(device)
}

func putIfPresent(target map[string]any, key, value string) {
	if strings.TrimSpace(value) != "" {
		target[key] = value
	}
}

func putSecretFromEnv(target map[string]any, key, envName string, env envFunc) {
	if strings.TrimSpace(envName) == "" {
		return
	}
	if value := env(envName); strings.TrimSpace(value) != "" {
		target[key] = value
	}
}

func requiredSecretEnv(name, envName string, env envFunc) (string, output.Error) {
	if strings.TrimSpace(envName) == "" {
		return "", output.Usage("missing_"+strings.ReplaceAll(name, "-", "_")+"_env", "Pass --"+name+"-env with an environment variable containing the secret.", map[string]any{"flag": "--" + name + "-env"})
	}
	value := env(envName)
	if strings.TrimSpace(value) == "" {
		return "", output.Usage("empty_"+strings.ReplaceAll(name, "-", "_")+"_env", "The environment variable passed to --"+name+"-env is empty.", map[string]any{"env": envName})
	}
	return value, output.Error{}
}

func fallback(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return value
}

func extractOrgRefs(value any) []config.OrgRef {
	raw, ok := value.([]any)
	if !ok {
		return nil
	}
	orgs := make([]config.OrgRef, 0, len(raw))
	seen := map[string]bool{}
	for _, item := range raw {
		row, ok := item.(map[string]any)
		if !ok {
			continue
		}
		org := config.OrgRef{
			ID:   strings.TrimSpace(stringField(row, "id")),
			Slug: strings.TrimSpace(stringField(row, "slug")),
			Name: strings.TrimSpace(stringField(row, "name")),
		}
		key := firstNonEmpty(org.ID, org.Slug, org.Name)
		if key == "" || seen[key] {
			continue
		}
		seen[key] = true
		orgs = append(orgs, org)
	}
	return orgs
}

func orgRefsData(orgs []config.OrgRef) []map[string]any {
	data := make([]map[string]any, 0, len(orgs))
	for _, org := range orgs {
		data = append(data, map[string]any{
			"id":   org.ID,
			"slug": org.Slug,
			"name": org.Name,
		})
	}
	return data
}

func orgRefsSummary(orgs []config.OrgRef) string {
	if len(orgs) == 0 {
		return "(none)"
	}
	labels := make([]string, 0, len(orgs))
	for _, org := range orgs {
		label := firstNonEmpty(org.Name, org.Slug, org.ID)
		if slug := strings.TrimSpace(org.Slug); slug != "" && label != slug {
			label += " (" + slug + ")"
		}
		labels = append(labels, label)
	}
	return strings.Join(labels, ", ")
}

func emptyNil(value string) any {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	return value
}

func defaultCLIClientName() string {
	hostname, err := os.Hostname()
	if err == nil && strings.TrimSpace(hostname) != "" {
		return "bft CLI on " + strings.TrimSpace(hostname)
	}
	return "bft CLI"
}

func intField(m map[string]any, key string, fallback int) int {
	switch value := m[key].(type) {
	case int:
		return value
	case int64:
		return int(value)
	case float64:
		return int(value)
	case json.Number:
		parsed, err := value.Int64()
		if err == nil {
			return int(parsed)
		}
	default:
		return fallback
	}
	return fallback
}

func normalizePollInterval(seconds int) int {
	if seconds < 1 {
		return 1
	}
	if seconds > 60 {
		return 60
	}
	return seconds
}

func deviceLoginDeadline(startedAt time.Time, expiresAt string) time.Time {
	fallback := startedAt.Add(maxDeviceLoginWait)
	parsed, ok := parseDeviceLoginDeadline(expiresAt)
	if !ok || parsed.After(fallback) {
		return fallback
	}
	return parsed
}

func parseDeviceLoginDeadline(value string) (time.Time, bool) {
	value = strings.TrimSpace(value)
	if value == "" {
		return time.Time{}, false
	}
	deadline, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return time.Time{}, false
	}
	return deadline, true
}

func fetchPublicRelease(ctx context.Context, baseURL string) (map[string]any, output.Error) {
	endpoint := strings.TrimRight(baseURL, "/") + "/v1/cli/release"
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, output.Error{ExitCode: output.ExitSoftware, Code: "release_request_failed", Message: "Could not build BFT CLI release request.", Details: map[string]any{"reason": err.Error()}}
	}
	req.Header.Set("Accept", "application/json")

	httpClient := &http.Client{Timeout: 15 * time.Second}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, output.Error{ExitCode: output.ExitUnavailable, Code: "release_unavailable", Message: "Could not reach the BFT CLI release endpoint.", Details: map[string]any{"reason": err.Error()}, Retryable: true}
	}
	defer resp.Body.Close()

	var envelope map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return nil, output.Error{ExitCode: output.ExitUnavailable, Code: "unexpected_release_response", Message: "BFT CLI release endpoint returned non-JSON output.", Details: map[string]any{"http_status": resp.StatusCode, "reason": err.Error()}, Retryable: resp.StatusCode >= 500}
	}
	if ok, _ := envelope["ok"].(bool); ok {
		data, _ := envelope["data"].(map[string]any)
		if data == nil {
			data = map[string]any{}
		}
		return data, output.Error{}
	}

	apiErr, _ := envelope["error"].(map[string]any)
	code, _ := apiErr["code"].(string)
	message, _ := apiErr["message"].(string)
	details, _ := apiErr["details"].(map[string]any)
	if code == "" {
		code = "release_error"
	}
	if message == "" {
		message = fmt.Sprintf("BFT CLI release request failed with HTTP %d.", resp.StatusCode)
	}
	return nil, output.Error{ExitCode: output.ExitUnavailable, Code: code, Message: message, Details: details, Retryable: resp.StatusCode >= 500}
}

func versionUpdateState(current, latest string) string {
	current = strings.TrimSpace(current)
	latest = strings.TrimSpace(latest)
	if latest == "" || latest == "latest" {
		return "unknown"
	}
	if current == latest {
		return "current"
	}
	return "available"
}

func versionNextAction(current, latest string) string {
	switch versionUpdateState(current, latest) {
	case "available":
		return "Run bft update --execute --confirm-mutating to install the configured CLI release."
	case "current":
		return "The local bft CLI matches the configured release."
	default:
		return "Run bft update to reinstall from the configured deployment if needed."
	}
}

func bftUpdateCommand(installURL, installDir string) string {
	command := "curl -fsSL " + shellQuote(installURL)
	if strings.TrimSpace(installDir) != "" {
		return command + " | BFT_CLI_INSTALL_DIR=" + shellQuote(installDir) + " sh"
	}
	return command + " | sh"
}

func runShellCommand(ctx context.Context, command string, stderr io.Writer) output.Error {
	if strings.TrimSpace(command) == "" {
		return output.Error{ExitCode: output.ExitSoftware, Code: "missing_shell_command", Message: "No shell command was returned to execute."}
	}
	cmd := exec.CommandContext(ctx, "sh", "-c", command)
	cmd.Stdout = stderr
	cmd.Stderr = stderr
	if err := cmd.Run(); err != nil {
		return output.Error{ExitCode: output.ExitUnavailable, Code: "shell_command_failed", Message: "The local shell command failed.", Details: map[string]any{"reason": err.Error()}, Retryable: false}
	}
	return output.Error{}
}

func shellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\"'\"'") + "'"
}

func larkAvailable(path string) bool {
	if strings.Contains(path, "/") {
		info, err := os.Stat(path)
		return err == nil && !info.IsDir()
	}
	_, err := exec.LookPath(path)
	return err == nil
}
