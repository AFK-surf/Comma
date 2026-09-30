package commands

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	"github.com/AFK-surf/comma/systems/cli/bft/internal/output"
)

func helpText() string {
	return `BFT CLI

Human mode:
  bft auth login
  bft auth status
  bft auth orgs list
  bft auth orgs add
  bft auth orgs revoke --org acme
  bft version --check
  bft update
  bft compute-node status
  bft compute-node install --confirm-mutating
  bft compute-node repair --confirm-mutating
  bft compute-node stop --confirm-mutating
  bft compute-node remove --confirm-mutating
  bft orgs list --limit 20 --filter acme
  bft projects list --org acme --limit 20
  bft agents list --org acme --project bridge --role worker
  bft agents runtimes --org acme --project bridge --include-unavailable
  bft agents create --org acme --project bridge --name codex-worker --role worker --runtime-kind external --device-id dev_123 --runtime-id runtime_codex --device-runtime-id devrt_123 --confirm-mutating
  bft agents rebind --org acme --project bridge --agent codex-worker --runtime devrt_123 --confirm-mutating
  bft devices list --org acme --project bridge
  bft devices create --org acme --project bridge --runner studio --confirm-mutating
  bft conversations list --org acme --project bridge --limit 100
  bft conversations show --org acme --project bridge --conversation task-123 --json
  bft conversations send --org acme --project bridge --conversation task-123 --text "run the smoke check" --request smoke-1 --confirm-mutating
  bft conversations trace --org acme --project bridge --conversation task-123 --participant worker --json
  bft conversations delivery --org acme --project bridge --conversation task-123 --participant worker --json
  bft conversations redeliver --org acme --project bridge --conversation task-123 --participant ptp1_... --message msg1_... --request recovery-20260722-1 --confirm-mutating
  bft context --org acme --project bridge
  bft sso checks --org acme
  bft feishu app plan --org acme --app-id cli_app --bot
  bft feishu app upsert --org acme --app-id cli_app --bot --app-secret-env BFT_FEISHU_APP_SECRET --confirm-mutating
  bft feishu setup --org acme --project bridge
  bft feishu connect ensure --org acme --project bridge --app-id cli_app --confirm-mutating
  bft feishu checks --org acme --project bridge
  bft runners install-command --org acme --confirm-mutating
  bft runners list --org acme
  bft onboarding smoke --step cli-login --org acme
  bft slack setup --org acme --project bridge
  bft slack connects list --org acme --project bridge
  bft slack connects create --org acme --project bridge --app-id A123 --client-id 123.abc --client-secret-env BFT_SLACK_CLIENT_SECRET --signing-secret-env BFT_SLACK_SIGNING_SECRET --inbound-agent agent_123 --confirm-mutating
  bft meetings calendar status --org acme --project bridge --limit 20
  bft meetings replay --org acme --project bridge --meeting mtg_123 --request replay-1
  bft meetings replay --org acme --project bridge --meeting mtg_123 --request replay-2 --run-model --confirm-mutating
  bft completion zsh

Agent mode:
  Non-TTY stdout defaults to exactly one JSON object; use --json explicitly in TTYs.
  Add --output text to force human text output in redirected or piped runs.
  Add --non-interactive to fail fast instead of prompting.
  Add --quiet to suppress nonessential text output.
  Add --fields id,name to keep only selected top-level JSON data fields.
  Use --limit and --filter on list commands to bound context usage.
  Inspect command metadata with bft commands --json.
  Inspect compact workflow guidance with bft agent help onboarding --json.

Environment:
  BFT_URL, BFT_ENV, BFT_API_BASE_URL, BFT_CLI_TOKEN, BFT_CLI_CONFIG.
  Use --env staging for staging, --url for self-hosted/local deployments.

Exit codes:
  0 success, 2 onboarding step needs manual action, 64 usage/context/auth error,
  66 not found, 69 runtime unavailable, 70 unexpected error.
`
}

func computeNodeHelpData() map[string]any {
	return map[string]any{
		"mode":              "compute_node_help",
		"helper_env":        vmmLifecycleEnv,
		"default_helper":    "~/" + sharedVMMLifecyclePath,
		"commands":          computeNodeOperationNames(),
		"mutating_commands": []string{"install", "repair", "stop", "remove"},
		"confirm_flag":      "--confirm-mutating",
		"status_semantics": map[string]any{
			"unreadable":    "The helper could not be read.",
			"last_known":    "A prior observation is returned as last-known when the same runner instance loses readability.",
			"runner_online": "Local VMM status does not observe BFT runner heartbeat.",
		},
	}
}

func computeNodeHelpText() string {
	return "Compute node (local Agent VMM Host runtime)\n" +
		"  bft compute-node status\n" +
		"  bft compute-node install --confirm-mutating\n" +
		"  bft compute-node repair --confirm-mutating\n" +
		"  bft compute-node stop --confirm-mutating\n" +
		"  bft compute-node remove --confirm-mutating [--purge]\n\n" +
		"Helper: " + vmmLifecycleEnv + " (default ~/" + sharedVMMLifecyclePath + ")\n" +
		"Status keeps unreadable/last-known state and never treats VMM ready as runner online.\n"
}

func computeNodeOperationData(operation, path string, purge bool, requestID string) map[string]any {
	data := map[string]any{
		"mode":                  "compute_node_lifecycle",
		"operation":             operation,
		"helper_action":         computeNodeHelperAction(operation),
		"helper_path":           path,
		"confirm_mutating":      operation != "status",
		"executed":              true,
		"request_id":            requestID,
		"runner_online":         "unknown",
		"node_admission":        "unknown",
		"node_admission_source": "server_only",
		"readiness_statement":   "This local lifecycle result proves neither BFT runner connectivity nor server Node admission.",
	}
	if operation == "remove" {
		data["purge"] = purge
	}
	if operation == "install" {
		data["readiness_observed"] = true
		data["vmm_readiness"] = "ready"
	}
	data["next_action"] = "Run bft compute-node status for local VMM facts, then bft runners list for a recent runner heartbeat."
	return data
}

func computeNodeOperationText(data map[string]any) string {
	lines := []string{
		"Compute node operation: " + stringField(data, "operation"),
		"Helper action: " + stringField(data, "helper_action"),
		"Executed: " + fmt.Sprint(data["executed"]),
	}
	if data["operation"] == "remove" {
		lines = append(lines, "Purge: "+fmt.Sprint(data["purge"]))
	}
	lines = append(lines, "Next: "+stringField(data, "next_action"))
	return strings.Join(lines, "\n") + "\n"
}

func computeNodeStatusText(data map[string]any) string {
	lines := []string{
		"Compute node status",
		"Readability: " + stringField(data, "readability"),
		"Last known: " + fmt.Sprint(data["last_known"]),
		"VMM readiness: " + stringField(data, "vmm_readiness"),
		"Runner online: " + stringField(data, "runner_online"),
		"Note: " + stringField(data, "readiness_statement"),
	}
	if next := stringField(data, "next_action"); next != "" {
		lines = append(lines, "Next: "+next)
	}
	return strings.Join(lines, "\n") + "\n"
}

func commandSchema() map[string]any {
	return map[string]any{
		"mode":           "commands",
		"schema_version": output.SchemaVersion,
		"global_flags": []map[string]any{
			{"name": "--json", "description": "write exactly one JSON object to stdout"},
			{"name": "--output json|text", "description": "select output format"},
			{"name": "--fields", "description": "comma-separated top-level JSON data fields to include"},
			{"name": "--quiet", "description": "suppress nonessential text output"},
			{"name": "--non-interactive", "description": "fail fast instead of prompting"},
			{"name": "--config", "description": "path to local bft config"},
			{"name": "--url", "description": "BFT base URL for self-hosted/local deployments"},
			{"name": "--env", "description": "BFT environment: prod, staging, local"},
			{"name": "--token-env", "description": "environment variable containing a CLI token"},
		},
		"exit_codes": map[string]any{
			"0":  "success",
			"2":  "onboarding step needs manual/operator action",
			"64": "usage/context/auth input error",
			"66": "not found",
			"69": "BFT/backend/runtime unavailable",
			"70": "unexpected CLI/backend error",
		},
		"commands": []map[string]any{
			{"name": "agent help", "example": "bft agent help onboarding --json", "mutates": false},
			{"name": "completion", "example": "bft completion zsh", "mutates": false},
			{"name": "auth login", "example": "bft auth login --output text", "mutates": true},
			{"name": "auth status", "example": "bft auth status --json", "mutates": false},
			{"name": "auth orgs list", "example": "bft auth orgs list --json", "mutates": false},
			{"name": "auth orgs add", "example": "bft auth orgs add --output text", "mutates": true},
			{"name": "auth orgs revoke", "example": "bft auth orgs revoke --org acme --json", "mutates": true},
			{"name": "auth logout", "example": "bft auth logout --json", "mutates": true},
			{"name": "version", "example": "bft version --check --json", "mutates": false},
			{"name": "update", "example": "bft update --execute --confirm-mutating --json", "mutates": true},
			{"name": "compute-node install", "example": "bft compute-node install --confirm-mutating --json", "mutates": true, "requires_confirm": true},
			{"name": "compute-node status", "example": "bft compute-node status --json", "mutates": false},
			{"name": "compute-node repair", "example": "bft compute-node repair --confirm-mutating --json", "mutates": true, "requires_confirm": true},
			{"name": "compute-node stop", "example": "bft compute-node stop --confirm-mutating --json", "mutates": true, "requires_confirm": true},
			{"name": "compute-node remove", "example": "bft compute-node remove --confirm-mutating --json", "mutates": true, "requires_confirm": true},
			{"name": "context", "example": "bft context --org acme --project support --json", "mutates": false},
			{"name": "orgs list", "example": "bft orgs list --limit 20 --filter acme --json", "mutates": false, "bounded": true},
			{"name": "projects list", "example": "bft projects list --org acme --limit 20 --json", "mutates": false, "bounded": true},
			{"name": "agents list", "example": "bft agents list --org acme --project support --role worker --json", "mutates": false, "bounded": true},
			{"name": "agents runtimes", "example": "bft agents runtimes --org acme --project support --include-unavailable --json", "mutates": false},
			{"name": "agents create", "example": "bft agents create --org acme --project support --name codex-worker --role worker --runtime-kind external --device-id dev_123 --runtime-id runtime_codex --device-runtime-id devrt_123 --confirm-mutating --json", "mutates": true},
			{"name": "agents rebind", "example": "bft agents rebind --org acme --project support --agent codex-worker --runtime devrt_123 --confirm-mutating --json", "mutates": true},
			{"name": "devices list", "example": "bft devices list --org acme --project support --limit 20 --json", "mutates": false, "bounded": true},
			{"name": "devices create", "example": "bft devices create --org acme --project support --runner studio --confirm-mutating --json", "mutates": true},
			{"name": "devices stop", "example": "bft devices stop --org acme --project support --request req_123 --confirm-mutating --json", "mutates": true},
			{"name": "devices disconnect", "example": "bft devices disconnect --org acme --project support --device dev_123 --confirm-mutating --json", "mutates": true},
			{"name": "conversations list", "example": "bft conversations list --org acme --project support --limit 100 --json", "mutates": false, "bounded": true},
			{"name": "conversations show", "example": "bft conversations show --org acme --project support --conversation task-123 --json", "mutates": false, "bounded": true},
			{"name": "conversations messages", "example": "bft conversations messages --org acme --project support --conversation task-123 --limit 100 --json", "mutates": false, "bounded": true},
			{"name": "conversations send", "example": "bft conversations send --org acme --project support --conversation task-123 --text 'run the smoke check' --request smoke-1 --confirm-mutating --json", "mutates": true, "bounded": true, "requires_confirm": true},
			{"name": "conversations trace", "example": "bft conversations trace --org acme --project support --conversation task-123 --participant worker --limit 100 --json", "mutates": false, "bounded": true},
			{"name": "conversations delivery", "example": "bft conversations delivery --org acme --project support --conversation task-123 --participant worker --limit 100 --json", "mutates": false, "bounded": true},
			{"name": "conversations redeliver", "example": "bft conversations redeliver --org acme --project support --conversation task-123 --participant ptp1_... --message msg1_... --request recovery-1 --confirm-mutating --json", "mutates": true, "bounded": true},
			{"name": "sso checks", "example": "bft sso checks --org acme --json", "mutates": false},
			{"name": "feishu app plan", "example": "bft feishu app plan --org acme --app-id cli_app --json", "mutates": false},
			{"name": "feishu app upsert", "example": "bft feishu app upsert --org acme --app-id cli_app --confirm-mutating --json", "mutates": true},
			{"name": "feishu setup", "example": "bft feishu setup --org acme --project support --json", "mutates": false},
			{"name": "feishu connect ensure", "example": "bft feishu connect ensure --org acme --project support --confirm-mutating --json", "mutates": true},
			{"name": "feishu checks", "example": "bft feishu checks --org acme --project support --json", "mutates": false},
			{"name": "runners install-command", "example": "bft runners install-command --org acme --confirm-mutating --json", "mutates": true, "requires_confirm": true},
			{"name": "runners list", "example": "bft runners list --org acme --limit 20 --json", "mutates": false, "bounded": true},
			{"name": "onboarding smoke", "example": "bft onboarding smoke --step cli-login --org acme --json", "mutates": false},
			{"name": "slack setup", "example": "bft slack setup --org acme --project support --json", "mutates": false},
			{"name": "slack connects list", "example": "bft slack connects list --org acme --project support --json", "mutates": false},
			{"name": "slack connects create", "example": "bft slack connects create --org acme --project support --app-id A123 --client-id 123.abc --client-secret-env BFT_SLACK_CLIENT_SECRET --signing-secret-env BFT_SLACK_SIGNING_SECRET --inbound-agent agent_123 --confirm-mutating --json", "mutates": true},
			{"name": "slack connects update", "example": "bft slack connects update --org acme --project support --connect conn_123 --inbound-agent agent_456 --confirm-mutating --json", "mutates": true},
			{"name": "slack connects disable", "example": "bft slack connects disable --org acme --project support --connect conn_123 --confirm-mutating --json", "mutates": true},
			{"name": "slack connects enable", "example": "bft slack connects enable --org acme --project support --connect conn_123 --confirm-mutating --json", "mutates": true},
			{"name": "slack connects delete", "example": "bft slack connects delete --org acme --project support --connect conn_123 --confirm-mutating --json", "mutates": true},
			{"name": "meetings calendar status", "example": "bft meetings calendar status --org acme --project support --limit 20 --json", "mutates": false, "bounded": true},
			{"name": "meetings replay", "example": "bft meetings replay --org acme --project support --meeting mtg_123 --request acceptance-1 --run-model --confirm-mutating --json", "mutates": true, "bounded": true, "delivery_writes": false},
		},
	}
}

func commandsText() string {
	return "Use bft commands --json for machine-readable command metadata.\n"
}

func completionShells() []string {
	return []string{"bash", "zsh", "fish"}
}

func completionScript(shell string) (string, bool) {
	words := "agent agents auth commands completion context compute-node conversations devices feishu help meetings calendar replay onboarding orgs projects schema slack sso update version runners add revoke install-command list runtimes rebind show messages send trace delivery redeliver connects create stop disconnect update disable enable delete install status repair remove purge --json --output --quiet --non-interactive --config --url --env --token-env --limit --message-limit --conversation --participant --message --text --filter --org --role --runner --name --alias --request --agent --runtime --device --include-unavailable --runtime-kind --runtime-provider --device-id --runtime-id --device-runtime-id --execute --run-model --confirm-mutating --purge --app-name --app-id --client-secret-env --signing-secret-env --inbound-agent --connect --meeting"
	switch shell {
	case "bash":
		return `_bft_completion() {
  local cur
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=( $(compgen -W "` + words + `" -- "$cur") )
}
complete -F _bft_completion bft
`, true
	case "zsh":
		return `#compdef bft
_bft() {
  local -a commands
  commands=(` + strings.Join(strings.Fields(words), " ") + `)
  compadd -- $commands
}
_bft "$@"
`, true
	case "fish":
		lines := []string{}
		for _, word := range strings.Fields(words) {
			lines = append(lines, "complete -c bft -f -a "+word)
		}
		return strings.Join(lines, "\n") + "\n", true
	default:
		return "", false
	}
}

func agentHelpTopics() []string {
	return []string{"overview", "onboarding", "auth", "compute-node", "feishu", "runners", "devices", "output"}
}

func agentHelp(topic string) (map[string]any, bool) {
	topics := map[string]map[string]any{
		"overview": {
			"summary": "Use bft as a thin, non-interactive wrapper around /v1/cli/* APIs.",
			"rules": []string{
				"Prefer --json in TTYs; redirected or piped stdout defaults to JSON.",
				"Use --fields when a command returns more data than the current step needs.",
				"Use --limit and --filter on list commands.",
				"Do not pass raw secrets as command-line arguments.",
				"Do not run mutating commands without an explicit --confirm-mutating flag.",
			},
			"commands": []string{
				"bft commands --json",
				"bft auth status --json",
				"bft onboarding smoke --step cli-login --json",
			},
			"next_action": "Run bft commands --json, then ask for the narrow command needed for the current step.",
		},
		"onboarding": {
			"summary": "Run one onboarding smoke step at a time and use next_action as the handoff.",
			"rules": []string{
				"Start with cli-login, then context, then the provider-specific step.",
				"Treat exit 2 as operator action needed, not a failed test.",
				"Rerun the same --step after the user completes a browser, Feishu, Slack, or machine action.",
			},
			"commands": []string{
				"bft onboarding smoke --step cli-login --json",
				"bft onboarding smoke --step context --org <org> --project <project> --json",
				"bft onboarding smoke --step feishu-checks --org <org> --project <project> --json",
			},
			"next_action": "Run the current smoke step and follow the first incomplete gate.",
		},
		"auth": {
			"summary": "Agents should authenticate through CLI-started device login or token env vars, not browser automation.",
			"rules": []string{
				"Run bft auth login to create a device login request, then approve it in the dashboard.",
				"Use --env staging or --url only when the target environment is explicit.",
				"Never print or copy the persisted CLI token.",
			},
			"commands": []string{
				"bft auth login --output text",
				"bft auth status --json",
				"bft orgs list --limit 20 --json",
			},
			"next_action": "If auth status is missing, run bft auth login and approve the device login in the dashboard.",
		},
		"compute-node": {
			"summary": "Manage the local Agent VMM Host runtime; local VMM readiness is not runner online evidence.",
			"rules": []string{
				"Status uses the versioned agent-vmm inspect contract. Set BFT_VMM_CLI only for an explicit test or development CLI.",
				"Mutations use the lifecycle owner. Set BFT_VMM_LIFECYCLE only for an explicit test or development helper.",
				"Use --confirm-mutating for install, repair, stop, and remove.",
				"Treat unreadable status as unreadable or last-known; do not turn it into a fresh false readiness claim.",
				"Use bft runners list for the BFT runner heartbeat; VMM ready does not mean runner online.",
			},
			"commands": []string{
				"bft compute-node status --json",
				"bft compute-node install --confirm-mutating --json",
				"bft compute-node repair --confirm-mutating --json",
				"bft compute-node stop --confirm-mutating --json",
				"bft compute-node remove --confirm-mutating --json",
			},
			"next_action": "Run compute-node status for local facts, then bft runners list for a recent runner heartbeat.",
		},
		"feishu": {
			"summary": "Feishu setup is assisted: CLI can verify BFT state, but Feishu console/group actions may remain manual.",
			"rules": []string{
				"Use feishu app plan or --dry-run before upsert.",
				"Use --confirm-mutating only after user approval.",
				"Do not claim first-message success without real Feishu message evidence or an explicit waiver.",
			},
			"commands": []string{
				"bft onboarding smoke --step feishu-cli --lark-cli lark-cli --assist-lark-app-init --json",
				"bft feishu app plan --org <org> --app-id <app> --json",
				"bft feishu connect ensure --org <org> --project <project> --app-id <app> --confirm-mutating --json",
				"bft feishu checks --org <org> --project <project> --json",
			},
			"next_action": "Run the narrow Feishu smoke/check command and stop at the first manual Feishu gate.",
		},
		"runners": {
			"summary": "Runner setup needs both install-command generation and a real runner heartbeat.",
			"rules": []string{
				"Ask the operator to approve the target organization and runner before generating the install command.",
				"After approval, generate exactly one install command and execute its returned command immediately without a second generation request.",
				"Do not print or repeat the returned one-time install command; execute it only on the target machine.",
				"Use bft-runner on the target machine for local foreground/status/log/service operations.",
				"Use runners list with --limit/--filter before deciding readiness.",
				"Treat runner setup as ready only after a recent online runner is visible.",
			},
			"commands": []string{
				"bft runners install-command --org <org> --confirm-mutating --json",
				"bft runners list --org <org> --limit 20 --json",
				"bft onboarding smoke --step runner --org <org> --json",
			},
			"next_action": "Run runners list after the install command has been executed on the target machine.",
		},
		"devices": {
			"summary": "Project devices are created from org runners and expose Salix connector runs plus discovered runtimes.",
			"rules": []string{
				"List runners before creating a project device, then pass the selected runner id, stable id, or unique name explicitly.",
				"Use devices list to inspect device requests, current connector runs, device ids, and runtime counts.",
				"Use devices stop for a pending or running device request.",
				"Use devices disconnect for the stable device whose current connection should stop.",
			},
			"commands": []string{
				"bft runners list --org <org> --limit 20 --json",
				"bft devices create --org <org> --project <project> --runner <id-or-stable-id-or-name> --confirm-mutating --json",
				"bft devices list --org <org> --project <project> --limit 20 --json",
				"bft devices stop --org <org> --project <project> --request <request_id> --confirm-mutating --json",
				"bft devices disconnect --org <org> --project <project> --device <device_id> --confirm-mutating --json",
			},
			"next_action": "Run bft runners list, choose the target runner, then create the project device.",
		},
		"output": {
			"summary": "JSON output is the automation contract; stdout carries results, stderr carries errors.",
			"rules": []string{
				"Non-TTY stdout defaults to JSON; pass --output text only when human text is required.",
				"Parse schema_version and ok before data.",
				"Use exit 2 for manual continuation and 64 for usage/auth input problems.",
				"Use next_action instead of guessing recovery steps.",
			},
			"commands": []string{
				"bft version --json",
				"bft commands --json",
				"bft agent help output --json",
			},
			"next_action": "If a command fails in JSON mode, parse stderr and follow error.next_action.",
		},
	}
	data, ok := topics[topic]
	if !ok {
		return nil, false
	}
	data["mode"] = "agent_help"
	data["topic"] = topic
	data["supported_topics"] = agentHelpTopics()
	return data, true
}

func agentHelpText(data map[string]any) string {
	lines := []string{"Agent help: " + stringField(data, "topic"), stringField(data, "summary"), ""}
	if commands, _ := data["commands"].([]string); len(commands) > 0 {
		lines = append(lines, "Commands:")
		for _, command := range commands {
			lines = append(lines, "  "+command)
		}
	}
	lines = append(lines, "", "Next: "+stringField(data, "next_action"))
	return strings.Join(lines, "\n") + "\n"
}

func versionText(data map[string]any) string {
	lines := []string{"bft " + stringField(data, "version")}
	if state := stringField(data, "update_state"); state != "" {
		lines = append(lines, "Update state: "+state)
		if latest := stringField(data, "latest_version"); latest != "" {
			lines = append(lines, "Configured release: "+latest)
		}
		if next := stringField(data, "next_action"); next != "" {
			lines = append(lines, "Next: "+next)
		}
	}
	return strings.Join(lines, "\n") + "\n"
}

func bftUpdateText(data map[string]any) string {
	lines := []string{"BFT CLI update"}
	if state := stringField(data, "update_state"); state != "" {
		lines = append(lines, "Update state: "+state)
	}
	if latest := stringField(data, "latest_version"); latest != "" {
		lines = append(lines, "Configured release: "+latest)
	}
	lines = append(lines, stringField(data, "command"))
	lines = append(lines, "Executed: "+fmt.Sprint(data["executed"]))
	if next := stringField(data, "next_action"); next != "" {
		lines = append(lines, "Next: "+next)
	}
	return strings.Join(lines, "\n") + "\n"
}

func contextText(data map[string]any) string {
	context, _ := data["context"].(map[string]any)
	org, _ := context["org"].(map[string]any)
	project, _ := context["project"].(map[string]any)
	return fmt.Sprintf("Org: %s (%s)\nAgent Swarm: %s (%s)\n",
		stringField(org, "name"), stringField(org, "slug"), stringField(project, "name"), stringField(project, "slug"))
}

func tableText(data map[string]any, key string) string {
	items, _ := data[key].([]any)
	lines := []string{"slug\tname\tid"}
	for _, item := range items {
		row, _ := item.(map[string]any)
		lines = append(lines, fmt.Sprintf("%s\t%s\t%s", stringField(row, "slug"), stringField(row, "name"), stringField(row, "id")))
	}
	if footer := listFooter(data); footer != "" {
		lines = append(lines, footer)
	}
	return strings.Join(lines, "\n") + "\n"
}

func conversationsText(data map[string]any) string {
	conversations, _ := data["conversations"].([]any)
	lines := []string{"conversation_id\tkind\tstatus\ttitle"}
	for _, raw := range conversations {
		row, _ := raw.(map[string]any)
		lines = append(lines, fmt.Sprintf("%s\t%s\t%s\t%s", stringField(row, "conversation_id"), stringField(row, "kind"), fallback(stringField(row, "status"), "active"), stringField(row, "title")))
	}
	return strings.Join(lines, "\n") + "\n"
}

func conversationDetailText(data map[string]any) string {
	conversation, _ := data["conversation"].(map[string]any)
	participants, _ := data["participants"].([]any)
	messages, _ := data["messages"].([]any)
	return fmt.Sprintf("Conversation: %s\nKind: %s\nStatus: %s\nParticipants: %d\nMessages returned: %d\n", stringField(conversation, "conversation_id"), stringField(conversation, "kind"), fallback(stringField(conversation, "status"), "active"), len(participants), len(messages))
}

func conversationMessagesText(data map[string]any) string {
	messages, _ := data["messages"].([]any)
	lines := []string{"message_id\tactor_type\tparticipant_id\tcreated_at"}
	for _, raw := range messages {
		row, _ := raw.(map[string]any)
		lines = append(lines, fmt.Sprintf("%s\t%s\t%s\t%s", stringField(row, "message_id"), stringField(row, "actor_type"), stringField(row, "participant_id"), fmt.Sprint(row["created_at"])))
	}
	return strings.Join(lines, "\n") + "\n"
}

func conversationSendText(data map[string]any) string {
	message, _ := data["message"].(map[string]any)
	return fmt.Sprintf("Conversation message sent: %s\n", fallback(stringField(message, "message_id"), "accepted"))
}

func conversationTraceText(data map[string]any) string {
	trace, _ := data["trace"].(map[string]any)
	events, _ := trace["events"].([]any)
	return fmt.Sprintf(
		"Trace participant: %s\nTrace agent: %s\nTrace session: %s\nEvents returned: %d\n",
		stringField(data, "trace_participant_id"),
		stringField(data, "trace_agent_id"),
		stringField(data, "trace_session_id"),
		len(events),
	)
}

func conversationDeliveryText(data map[string]any) string {
	delivery, _ := data["delivery"].(map[string]any)
	deliveries, _ := delivery["deliveries"].([]any)
	lines := []string{
		fmt.Sprintf("Delivery participant: %s", stringField(data, "participant_id")),
		fmt.Sprintf("Delivery records: %d", len(deliveries)),
		"message_id\ttarget_actor\tstatus\ttarget_session\tsession_status\terror",
	}
	for _, raw := range deliveries {
		row, _ := raw.(map[string]any)
		session, _ := row["session"].(map[string]any)
		delivery, _ := row["delivery"].(map[string]any)
		lines = append(lines, fmt.Sprintf(
			"%s\t%s\t%s\t%s\t%s\t%s",
			stringField(row, "message_id"),
			stringField(row, "target_actor_type"),
			stringField(row, "status"),
			stringField(row, "target_session_id"),
			stringField(session, "status"),
			stringField(delivery, "last_error"),
		))
	}
	return strings.Join(lines, "\n") + "\n"
}

func conversationRedeliveryText(data map[string]any) string {
	redelivery, _ := data["redelivery"].(map[string]any)
	return fmt.Sprintf("Conversation message redelivery: %s\n", fallback(stringField(redelivery, "delivery_status"), "accepted"))
}

func agentsText(data map[string]any) string {
	agents, _ := data["agents"].([]any)
	lines := []string{"id\tsalix_agent_id\tname\trole\tstatus\truntime_kind\truntime_status\tdevice_id\truntime_id\tdevice_runtime_id\tconnector_run_id\tdevice_status"}
	for _, raw := range agents {
		row, _ := raw.(map[string]any)
		runtime, _ := row["runtime"].(map[string]any)
		lines = append(lines, fmt.Sprintf(
			"%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s",
			stringField(row, "id"),
			stringField(row, "salix_agent_id"),
			stringField(row, "name"),
			stringField(row, "role"),
			stringField(row, "status"),
			stringField(runtime, "kind"),
			stringField(runtime, "status"),
			stringField(runtime, "device_id"),
			stringField(runtime, "runtime_id"),
			stringField(runtime, "device_runtime_id"),
			stringField(runtime, "connector_run_id"),
			stringField(runtime, "device_status"),
		))
	}
	if lookupError, ok := data["runtime_lookup_error"]; ok {
		lines = append(lines, "runtime_lookup_error: "+fmt.Sprint(lookupError))
	}
	if lookupError, ok := data["salix_agent_lookup_error"]; ok {
		lines = append(lines, "salix_agent_lookup_error: "+fmt.Sprint(lookupError))
	}
	if cursor := stringField(data, "next_cursor"); cursor != "" {
		lines = append(lines, "next_cursor: "+cursor)
	}
	return strings.Join(lines, "\n") + "\n"
}

func agentText(prefix string, data map[string]any) string {
	agent, _ := data["agent"].(map[string]any)
	if agent == nil {
		return prefix + "\n"
	}

	listData := map[string]any{"agents": []any{agent}}
	for _, key := range []string{"runtime_lookup_error", "salix_agent_lookup_error"} {
		if value, ok := data[key]; ok {
			listData[key] = value
		}
	}

	return prefix + "\n" + agentsText(listData)
}

func agentRuntimesText(data map[string]any) string {
	runtimes, _ := data["runtimes"].([]any)
	lines := []string{"device_runtime_id\tdevice_id\tdevice_name\truntime_id\tstatus\tbindable\tready\tversion\tconnector_run_id"}
	for _, raw := range runtimes {
		row, _ := raw.(map[string]any)
		lines = append(lines, fmt.Sprintf(
			"%s\t%s\t%s\t%s\t%s\t%v\t%v\t%s\t%s",
			stringField(row, "device_runtime_id"),
			stringField(row, "device_id"),
			stringField(row, "device_name"),
			stringField(row, "runtime_id"),
			stringField(row, "status"),
			runtimeBindable(row),
			row["ready"],
			stringField(row, "version"),
			stringField(row, "connector_run_id"),
		))
	}
	return strings.Join(lines, "\n") + "\n"
}

func devicesText(data map[string]any) string {
	devices, _ := data["devices"].([]any)
	requests, _ := data["device_requests"].([]any)
	lines := []string{"Devices", "device_id\tstatus\tname\truntimes\tconnector_run_id"}
	for _, raw := range devices {
		row, _ := raw.(map[string]any)
		lines = append(lines, fmt.Sprintf(
			"%s\t%s\t%s\t%d\t%s",
			stringField(row, "device_id"),
			stringField(row, "status"),
			stringField(row, "name"),
			intField(row, "runtime_count", 0),
			stringField(row, "connector_run_id"),
		))
	}
	if len(devices) == 0 {
		lines = append(lines, "(none)")
	}

	lines = append(lines, "", "Device requests", "request_id\tstatus\tname\trunner\tconnector_run_id")
	for _, raw := range requests {
		row, _ := raw.(map[string]any)
		runner, _ := row["runner"].(map[string]any)
		lines = append(lines, fmt.Sprintf(
			"%s\t%s\t%s\t%s\t%s",
			stringField(row, "id"),
			stringField(row, "status"),
			stringField(row, "name"),
			firstNonEmpty(stringField(runner, "name"), stringField(runner, "id")),
			stringField(row, "connector_run_id"),
		))
	}
	if len(requests) == 0 {
		lines = append(lines, "(none)")
	}
	if footer := listFooter(data); footer != "" {
		lines = append(lines, footer)
	}
	if next := stringField(data, "next_action"); next != "" {
		lines = append(lines, "Next: "+next)
	}
	return strings.Join(lines, "\n") + "\n"
}

func deviceMutationText(prefix string, data map[string]any) string {
	request, _ := data["device_request"].(map[string]any)
	device, _ := data["device"].(map[string]any)
	lines := []string{prefix}
	if request != nil {
		lines = append(lines, "Request: "+stringField(request, "id"))
		lines = append(lines, "Status: "+stringField(request, "status"))
		if runID := stringField(request, "connector_run_id"); runID != "" {
			lines = append(lines, "Connector run: "+runID)
		}
	}
	if device != nil {
		lines = append(lines, "Device: "+stringField(device, "device_id"))
		lines = append(lines, "Connector run: "+stringField(device, "connector_run_id"))
		lines = append(lines, "Status: "+stringField(device, "status"))
	}
	if next := stringField(data, "next_action"); next != "" {
		lines = append(lines, "Next: "+next)
	}
	return strings.Join(lines, "\n") + "\n"
}

func slackSetupText(data map[string]any) string {
	lines := []string{"Slack setup prepared."}
	if appsURL := stringField(data, "slack_apps_url"); appsURL != "" {
		lines = append(lines, "Slack apps: "+appsURL)
	}
	if redirectURL := stringField(data, "redirect_url"); redirectURL != "" {
		lines = append(lines, "OAuth redirect URL: "+redirectURL)
	}
	if eventsURL := stringField(data, "events_url"); eventsURL != "" {
		lines = append(lines, "Event request URL: "+eventsURL)
	}

	guide, _ := data["credential_guide"].([]any)
	if len(guide) > 0 {
		lines = append(lines, "Credential fields:")
		for _, raw := range guide {
			row, _ := raw.(map[string]any)
			field := stringField(row, "field")
			flag := stringField(row, "flag")
			source := stringField(row, "source")
			if field == "" && flag == "" && source == "" {
				continue
			}
			lines = append(lines, fmt.Sprintf("- %s (%s): %s", field, flag, source))
		}
	}
	if command := stringField(data, "create_connect_command"); command != "" {
		lines = append(lines, "Create router connect command:")
		lines = append(lines, command)
	}
	if command := stringField(data, "create_worker_connect_command"); command != "" {
		lines = append(lines, "Create worker connect command:")
		lines = append(lines, command)
	}
	return strings.Join(lines, "\n") + "\n"
}

func slackConnectsText(data map[string]any) string {
	connects, _ := data["connects"].([]any)
	lines := []string{"connect_id\tapp_id\tapp_name\tworkspace\tbot_user_id\tbot_username\tinbound_agent_id\tinstall_status\tdisabled\toauth_url"}
	for _, raw := range connects {
		row, _ := raw.(map[string]any)
		lines = append(lines, fmt.Sprintf(
			"%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%t\t%s",
			stringField(row, "connect_id"),
			stringField(row, "app_id"),
			stringField(row, "app_name"),
			slackWorkspaceField(row),
			stringField(row, "bot_user_id"),
			stringField(row, "bot_username"),
			stringField(row, "inbound_agent_id"),
			stringField(row, "install_status"),
			stringField(row, "disabled_at") != "",
			stringField(row, "oauth_url"),
		))
	}
	return strings.Join(lines, "\n") + "\n"
}

func slackWorkspaceField(connect map[string]any) string {
	if name := stringField(connect, "workspace_name"); name != "" {
		return name
	}
	return stringField(connect, "workspace_id")
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}

func slackConnectText(prefix string, data map[string]any) string {
	connect, _ := data["connect"].(map[string]any)
	if connect == nil {
		return prefix + "\n"
	}
	lines := []string{prefix}
	if id := stringField(connect, "connect_id"); id != "" {
		lines = append(lines, "Connect: "+id)
	}
	if appID := stringField(connect, "app_id"); appID != "" {
		lines = append(lines, "App: "+appID)
	}
	if workspace := slackWorkspaceField(connect); workspace != "" {
		lines = append(lines, "Workspace: "+workspace)
	}
	if bot := slackBotField(connect); bot != "" {
		lines = append(lines, "Bot user: "+bot)
	}
	if agentID := stringField(connect, "inbound_agent_id"); agentID != "" {
		lines = append(lines, "Inbound agent: "+agentID)
	}
	if installStatus := stringField(connect, "install_status"); installStatus != "" {
		lines = append(lines, "Install status: "+installStatus)
	}
	if oauthURL := stringField(data, "oauth_url"); oauthURL != "" {
		lines = append(lines, "OAuth URL: "+oauthURL)
	}
	return strings.Join(lines, "\n") + "\n"
}

func slackBotField(connect map[string]any) string {
	botID := stringField(connect, "bot_user_id")
	username := stringField(connect, "bot_username")
	if botID == "" {
		return ""
	}
	if username != "" {
		return botID + " (@" + username + ")"
	}
	return botID
}

func checksText(title string, data map[string]any) string {
	checks, _ := data["checks"].(map[string]any)
	gates, _ := checks["gates"].([]any)
	lines := []string{title}
	for _, raw := range gates {
		gate, _ := raw.(map[string]any)
		lines = append(lines, fmt.Sprintf("[%s] %s: %s", stringField(gate, "status"), stringField(gate, "gate_id"), stringField(gate, "next_action")))
	}
	if admin, _ := data["admin_login"].(map[string]any); admin != nil {
		lines = append(lines, fmt.Sprintf("[%s] %s: %s", stringField(admin, "status"), stringField(admin, "gate_id"), stringField(admin, "next_action")))
	}
	return strings.Join(lines, "\n") + "\n"
}

func meetingCalendarStatusText(data map[string]any) string {
	lines := strings.Split(strings.TrimSuffix(checksText("Meeting calendar status", data), "\n"), "\n")
	calendar, _ := data["calendar"].(map[string]any)
	lines = append(lines, fmt.Sprintf("Calendar health: %s (%s)", fallback(stringField(calendar, "health"), "unknown"), fallback(stringField(calendar, "reason"), "unknown")))
	if runtime, _ := calendar["runtime"].(map[string]any); runtime != nil {
		lines = append(lines, "Worker: "+fallback(stringField(runtime, "status"), "unknown"))
	}

	projection, _ := calendar["projection"].(map[string]any)
	if projection != nil {
		line := "Projection: " + fallback(stringField(projection, "state"), "unknown")
		if updated := unixMillisText(projection["updated_at"]); updated != "" {
			line += ", updated " + updated
		}
		lines = append(lines, line)
	}

	summary, _ := calendar["summary"].(map[string]any)
	if summary != nil {
		lines = append(lines, fmt.Sprintf("Candidates: %d; returned: %d; planned: %d; plan errors: %d; candidate errors: %d; autojoin errors: %d", intField(summary, "candidate_count", 0), intField(summary, "returned_count", 0), intField(summary, "planned_count", 0), intField(summary, "plan_error_count", 0), intField(summary, "candidate_error_count", 0), intField(summary, "autojoin_error_count", 0)))
	}

	events, _ := calendar["events"].([]any)
	if len(events) == 0 {
		lines = append(lines, "Events: none in the current eligible 24-hour projection")
	} else {
		lines = append(lines, "Events:")
		for _, raw := range events {
			event, _ := raw.(map[string]any)
			plan, _ := event["plan"].(map[string]any)
			preparation, _ := plan["preparation"].(map[string]any)
			autojoin, _ := event["autojoin"].(map[string]any)
			prep := fallback(stringField(preparation, "research_decision"), "pending")
			lines = append(lines, fmt.Sprintf("  %s | %s | plan=%s prep=%s autojoin=%s", fallback(unixMillisText(event["start_ms"]), "unknown time"), fallback(stringField(event, "title"), "Calendar meeting"), fallback(stringField(plan, "status"), "unknown"), prep, fallback(stringField(autojoin, "status"), "unknown")))
		}
	}
	return strings.Join(lines, "\n") + "\n"
}

func meetingReplayText(data map[string]any) string {
	replay, _ := data["replay"].(map[string]any)
	return fmt.Sprintf("Meeting replay: status=%s passed=%t mode=%s replayed=%t delivery_writes=false\n", fallback(stringField(replay, "status"), "unknown"), boolField(replay, "passed"), fallback(stringField(replay, "mode"), "unknown"), boolField(replay, "replayed"))
}

func meetingReplayExit(data map[string]any) int {
	replay, _ := data["replay"].(map[string]any)
	if boolField(replay, "passed") {
		return output.ExitOK
	}
	return output.ExitSoftware
}

func meetingCalendarStatusExit(data map[string]any) int {
	calendar, _ := data["calendar"].(map[string]any)
	if stringField(calendar, "health") == "unavailable" {
		return output.ExitUnavailable
	}

	checks, _ := data["checks"].(map[string]any)
	gates, _ := checks["gates"].([]any)
	for _, raw := range gates {
		gate, _ := raw.(map[string]any)
		if stringField(gate, "status") != "ok" {
			return output.ExitNeedsManual
		}
	}

	switch stringField(calendar, "health") {
	case "ok":
		return output.ExitOK
	case "unavailable":
		return output.ExitUnavailable
	default:
		return output.ExitNeedsManual
	}
}

func unixMillisText(value any) string {
	var milliseconds int64
	switch typed := value.(type) {
	case float64:
		milliseconds = int64(typed)
	case int64:
		milliseconds = typed
	case int:
		milliseconds = int64(typed)
	default:
		return ""
	}
	if milliseconds <= 0 {
		return ""
	}
	return time.UnixMilli(milliseconds).UTC().Format(time.RFC3339)
}

func feishuSetupText(data map[string]any) string {
	project, _ := data["project"].(map[string]any)
	lines := []string{"Feishu setup for " + stringField(project, "name")}

	if action := stringField(data, "action"); action != "" {
		lines = append(lines, "Action: "+action)
	}
	if callbackURL := stringField(data, "callback_url"); callbackURL != "" {
		lines = append(lines, "Callback URL: "+callbackURL)
	}

	if scopes, _ := data["required_scopes"].([]any); len(scopes) > 0 {
		lines = append(lines, "", "Required tenant scopes:")
		for _, scope := range scopes {
			if value, ok := scope.(string); ok && value != "" {
				lines = append(lines, "  "+value)
			}
		}
	}

	if payload := data["batch_import_payload"]; payload != nil {
		if encoded, err := json.MarshalIndent(payload, "", "  "); err == nil {
			lines = append(lines, "", "Batch-import JSON:", string(encoded))
		}
	}

	if events, _ := data["event_subscriptions"].([]any); len(events) > 0 {
		lines = append(lines, "", "Event subscriptions:")
		for _, event := range events {
			if value, ok := event.(string); ok && value != "" {
				lines = append(lines, "  "+value)
			}
		}
	}

	if checklist, _ := data["manual_checklist"].([]any); len(checklist) > 0 {
		lines = append(lines, "", "Manual checklist:")
		for index, item := range checklist {
			if value, ok := item.(string); ok && value != "" {
				lines = append(lines, fmt.Sprintf("  %d. %s", index+1, value))
			}
		}
	}

	if optionalScopes, _ := data["optional_scopes"].([]any); len(optionalScopes) > 0 {
		lines = append(lines, "", "Optional scopes:")
		for _, raw := range optionalScopes {
			scope, _ := raw.(map[string]any)
			if scopeID := stringField(scope, "scope"); scopeID != "" {
				line := "  " + scopeID
				if label := stringField(scope, "label"); label != "" {
					line += " - " + label
				}
				if note := stringField(scope, "note"); note != "" {
					line += ": " + note
				}
				lines = append(lines, line)
			}
		}
	}

	if next := stringField(data, "next_action"); next != "" {
		lines = append(lines, "", "Next: "+next)
	}
	return strings.Join(lines, "\n") + "\n"
}

func runnerInstallText(data map[string]any) string {
	org, _ := data["org"].(map[string]any)
	return fmt.Sprintf("Runner install command for %s.\n%s\nNext: %s\n", stringField(org, "slug"), stringField(data, "command"), stringField(data, "next_action"))
}

func runnersText(data map[string]any) string {
	org, _ := data["org"].(map[string]any)
	runners, _ := data["runners"].([]any)
	lines := []string{"Runners for " + stringField(org, "slug"), "name\tstatus\tlast_seen_at\tversion\tupdate"}
	for _, raw := range runners {
		p, _ := raw.(map[string]any)
		update := "current"
		if available, _ := p["update_available"].(bool); available {
			update = "available"
		}
		lines = append(lines, fmt.Sprintf("%s\t%s\t%s\t%s\t%s", stringField(p, "name"), stringField(p, "effective_status"), stringField(p, "last_seen_at"), stringField(p, "version"), update))
	}
	if footer := listFooter(data); footer != "" {
		lines = append(lines, footer)
	}
	lines = append(lines, "Next: "+stringField(data, "next_action"))
	return strings.Join(lines, "\n") + "\n"
}

func listFooter(data map[string]any) string {
	meta, _ := data["list"].(map[string]any)
	if meta == nil {
		return ""
	}
	if truncated, _ := meta["truncated"].(bool); truncated {
		return fmt.Sprintf("Showing %v of %v matched rows. Increase --limit or narrow --filter.", meta["returned"], meta["matched"])
	}
	if meta["filter"] != nil {
		return fmt.Sprintf("Showing %v filtered rows.", meta["returned"])
	}
	return ""
}

func onboardingText(payload map[string]any) string {
	lines := []string{
		"Onboarding smoke step: " + stringField(payload, "step_id"),
		"Status: " + stringField(payload, "status"),
		"Next: " + stringField(payload, "next_action"),
		"",
	}
	gates, _ := payload["gates"].([]map[string]any)
	for _, gate := range gates {
		lines = append(lines, fmt.Sprintf("[%s] %s: %s", stringField(gate, "status"), stringField(gate, "gate_id"), stringField(gate, "next_action")))
	}
	return strings.Join(lines, "\n") + "\n"
}

func feishuAppPlan(org string, attrs map[string]any, appSecretEnv, verificationTokenEnv, encryptKeyEnv string) map[string]any {
	appID, _ := attrs["app_id"].(string)
	return map[string]any{
		"mode":        "feishu_app_plan",
		"org_ref":     org,
		"will_mutate": false,
		"attrs": map[string]any{
			"app_id":                        appID,
			"display_name":                  attrs["display_name"],
			"bot_enabled":                   attrs["bot_enabled"],
			"sso_enabled":                   attrs["sso_enabled"],
			"app_secret_configured":         appSecretEnv != "",
			"verification_token_configured": verificationTokenEnv != "",
			"encrypt_key_configured":        encryptKeyEnv != "",
		},
		"redaction": map[string]any{
			"secrets_printed": false,
		},
		"next_action": "Review the plan, then run bft feishu app upsert with --confirm-mutating.",
	}
}

func okGate(gateID, label, nextAction string) map[string]any {
	return okGateWithEvidence(gateID, label, nextAction, map[string]any{})
}

func okGateWithEvidence(gateID, label, nextAction string, evidence any) map[string]any {
	return map[string]any{
		"gate_id":        gateID,
		"label":          label,
		"classification": "automatic",
		"status":         "ok",
		"reason_class":   nil,
		"required":       true,
		"next_action":    nextAction,
		"evidence":       evidence,
		"redacted":       true,
	}
}

func assistedGate(gateID, label, nextAction string) map[string]any {
	return map[string]any{
		"gate_id":        gateID,
		"label":          label,
		"classification": "assisted",
		"status":         "needs_manual",
		"reason_class":   "operator_action_required",
		"required":       true,
		"next_action":    nextAction,
		"evidence":       map[string]any{},
		"redacted":       true,
	}
}

func blockedGate(gateID, label string, err output.Error) map[string]any {
	return map[string]any{
		"gate_id":        gateID,
		"label":          label,
		"classification": "blocked",
		"status":         "fail",
		"reason_class":   err.Code,
		"required":       true,
		"next_action":    err.Message,
		"evidence":       err.Details,
		"redacted":       true,
	}
}

func normalizeGate(gate map[string]any) map[string]any {
	normalized := map[string]any{}
	for key, value := range gate {
		normalized[key] = value
	}
	if _, ok := normalized["classification"]; !ok {
		if normalized["status"] == "ok" {
			normalized["classification"] = "automatic"
		} else {
			normalized["classification"] = "assisted"
		}
	}
	if _, ok := normalized["required"]; !ok {
		normalized["required"] = true
	}
	if _, ok := normalized["evidence"]; !ok {
		normalized["evidence"] = map[string]any{}
	}
	normalized["redacted"] = true
	return normalized
}

func gatesFromChecks(data map[string]any) []map[string]any {
	checks, _ := data["checks"].(map[string]any)
	rawGates, _ := checks["gates"].([]any)
	gates := make([]map[string]any, 0, len(rawGates))
	for _, raw := range rawGates {
		gate, _ := raw.(map[string]any)
		if gate != nil {
			gates = append(gates, normalizeGate(gate))
		}
	}
	return gates
}

func onboardingStatus(gates []map[string]any) string {
	status := "ok"
	for _, gate := range gates {
		if required, ok := gate["required"].(bool); ok && !required {
			continue
		}
		if gate["classification"] == "blocked" || gate["status"] == "fail" {
			return "blocked"
		}
		if gate["status"] == "needs_manual" || gate["status"] == "skipped" {
			status = "needs_manual"
		}
	}
	return status
}

func nextAction(gates []map[string]any, status string) string {
	if status == "ok" {
		return "This onboarding step is complete."
	}
	for _, gate := range gates {
		if required, ok := gate["required"].(bool); ok && !required {
			continue
		}
		if status == "blocked" && (gate["classification"] == "blocked" || gate["status"] == "fail") {
			return stringField(gate, "next_action")
		}
		if status == "needs_manual" && (gate["status"] == "needs_manual" || gate["status"] == "skipped") {
			return stringField(gate, "next_action")
		}
	}
	return "Inspect this step evidence and retry."
}

func summary(gates []map[string]any) map[string]any {
	result := map[string]any{"total": len(gates), "ok": 0, "needs_manual": 0, "blocked": 0, "skipped": 0}
	for _, gate := range gates {
		switch gate["status"] {
		case "ok":
			result["ok"] = result["ok"].(int) + 1
		case "needs_manual":
			result["needs_manual"] = result["needs_manual"].(int) + 1
		case "skipped":
			result["skipped"] = result["skipped"].(int) + 1
		}
		if gate["classification"] == "blocked" || gate["status"] == "fail" {
			result["blocked"] = result["blocked"].(int) + 1
		}
	}
	return result
}

func dependsOn(step string) []string {
	deps := map[string][]string{
		"org":            {},
		"sso":            {"org"},
		"admin-login":    {"sso"},
		"cli-login":      {"admin-login"},
		"context":        {"cli-login"},
		"feishu-cli":     {"context"},
		"feishu-app":     {"context", "feishu-cli"},
		"feishu-connect": {"feishu-app"},
		"feishu-checks":  {"feishu-connect"},
		"target-group":   {"feishu-checks"},
		"first-message":  {"target-group"},
		"runner":         {"context"},
	}
	if value, ok := deps[step]; ok {
		return value
	}
	return []string{}
}

func stringField(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	switch value := m[key].(type) {
	case string:
		return value
	case nil:
		return ""
	default:
		return fmt.Sprint(value)
	}
}

func boolField(m map[string]any, key string) bool {
	value, _ := m[key].(bool)
	return value
}

func sortedKeys(m map[string]any) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}
