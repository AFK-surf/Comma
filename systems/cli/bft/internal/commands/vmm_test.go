package commands

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/AFK-surf/comma/systems/cli/bft/internal/output"
)

func TestLocalVMMRunnerMapsComputeNodeOperationsToOneHelper(t *testing.T) {
	var calls []string
	runner := &localVMMRunner{
		path:        "/tmp/agent-vmm-lifecycle",
		inspectPath: "/tmp/agent-vmm",
		command: func(_ context.Context, path string, args []string) ([]byte, []byte, error) {
			calls = append(calls, path+" "+strings.Join(args, " "))
			return []byte(`{"version":1,"state":"healthy","freshness":"current","facts":{"hostLoaded":true}}`), nil, nil
		},
	}

	if err := runner.Install(context.Background(), "request-install"); err != nil {
		t.Fatal(err)
	}
	if err := runner.Repair(context.Background(), "request-repair"); err != nil {
		t.Fatal(err)
	}
	if err := runner.Stop(context.Background(), "request-stop"); err != nil {
		t.Fatal(err)
	}
	if err := runner.Remove(context.Background(), false, "request-remove"); err != nil {
		t.Fatal(err)
	}
	if err := runner.Remove(context.Background(), true, "request-purge"); err != nil {
		t.Fatal(err)
	}

	want := []string{
		"/tmp/agent-vmm-lifecycle install --request-id request-install",
		"/tmp/agent-vmm-lifecycle repair --request-id request-repair",
		"/tmp/agent-vmm-lifecycle drain --request-id request-stop",
		"/tmp/agent-vmm-lifecycle uninstall --request-id request-remove",
		"/tmp/agent-vmm-lifecycle uninstall --purge --request-id request-purge",
	}
	if strings.Join(calls, "\n") != strings.Join(want, "\n") {
		t.Fatalf("helper calls = %v, want %v", calls, want)
	}
}

func TestComputeNodeUsesOperationSpecificBudgets(t *testing.T) {
	if vmmOperationTimeout("status") != 6*time.Second ||
		vmmOperationTimeout("stop") < 40*time.Second ||
		vmmOperationTimeout("repair") < 2*time.Minute ||
		vmmOperationTimeout("install") < 10*time.Minute ||
		vmmOperationTimeout("remove") < time.Minute {
		t.Fatalf("operation budgets status=%s stop=%s repair=%s install=%s remove=%s",
			vmmOperationTimeout("status"), vmmOperationTimeout("stop"), vmmOperationTimeout("repair"), vmmOperationTimeout("install"), vmmOperationTimeout("remove"))
	}
}

func TestLocalVMMRunnerStatusUsesPublicInspectContract(t *testing.T) {
	var call string
	runner := &localVMMRunner{
		path:        "/tmp/agent-vmm-lifecycle",
		inspectPath: "/tmp/agent-vmm",
		command: func(_ context.Context, path string, args []string) ([]byte, []byte, error) {
			call = path + " " + strings.Join(args, " ")
			return []byte(`{"version":1,"state":"healthy","freshness":"current","facts":{"hostLoaded":true,"hostReadable":true}}`), nil, nil
		},
	}
	status, err := runner.Status(context.Background())
	if err != nil || status.Facts["hostReadable"] != true {
		t.Fatalf("status=%#v err=%v", status, err)
	}
	if call != "/tmp/agent-vmm inspect --json --lifecycle-helper /tmp/agent-vmm-lifecycle" {
		t.Fatalf("inspect call = %q", call)
	}
}

func TestResolveVMMLifecyclePathUsesSharedHostRuntimeByDefault(t *testing.T) {
	home := filepath.Join(t.TempDir(), "home")
	got := resolveVMMLifecyclePath(func(key string) string {
		if key == vmmHomeEnv {
			return home
		}
		return ""
	})
	want := filepath.Join(home, filepath.FromSlash(sharedVMMLifecyclePath))
	if got != want {
		t.Fatalf("default helper path = %q, want %q", got, want)
	}
}

func TestComputeNodeInstallRequiresInstallThenReadyObservation(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "lifecycle.log")
	helper := writeVMMHelper(t, `{"hostInstalled":true,"hostLoaded":true,"hostReadable":true,"hostHealthy":true}`)
	contents, err := os.ReadFile(helper)
	if err != nil {
		t.Fatal(err)
	}
	script := strings.Replace(string(contents), "set -eu\n", "set -eu\nprintf '%s\\n' \"$*\" >> "+strconv.Quote(logPath)+"\n", 1)
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}

	exitCode, stdout, stderr := runCLI(t, []string{
		"compute-node", "install", "--confirm-mutating", "--request=request-install", "--json",
	}, map[string]string{vmmLifecycleEnv: helper, vmmCLIEnv: helper})
	if exitCode != output.ExitOK || stderr != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if got := strings.TrimSpace(readTestFile(t, logPath)); got != "install --request-id request-install\ninspect --json --lifecycle-helper "+helper {
		t.Fatalf("lifecycle calls = %q", got)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["helper_action"] != "install" {
		t.Fatalf("helper action = %#v", data["helper_action"])
	}
}

func TestComputeNodeInstallFailsClosedWhenObservationIsNotReady(t *testing.T) {
	helper := writeVMMHelper(t, `{"hostInstalled":true,"hostLoaded":true,"hostReadable":true,"hostHealthy":false}`)
	exitCode, stdout, stderr := runCLI(t, []string{
		"compute-node", "install", "--confirm-mutating", "--request=request-install", "--json",
	}, map[string]string{vmmLifecycleEnv: helper, vmmCLIEnv: helper})
	if exitCode != output.ExitUnavailable || stdout != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stderr, &body)
	if body["error"].(map[string]any)["code"] != "vmm_not_ready" {
		t.Fatalf("error = %#v", body)
	}
}

func TestLocalVMMRunnerKeepsLastKnownStatusWhenHelperBecomesUnreadable(t *testing.T) {
	statusJSON := []byte(`{"hostLoaded":true,"hostReadable":true}`)
	callCount := 0
	runner := &localVMMRunner{
		path:        "/tmp/agent-vmm-lifecycle",
		inspectPath: "/tmp/agent-vmm",
		command: func(_ context.Context, _ string, _ []string) ([]byte, []byte, error) {
			callCount++
			if callCount == 1 {
				return []byte(`{"version":1,"state":"healthy","freshness":"current","facts":` + string(statusJSON) + `}`), nil, nil
			}
			return nil, []byte("permission denied"), errors.New("exit status 1")
		},
	}

	first, err := runner.Status(context.Background())
	if err != nil || first.Readability != "readable" || first.LastKnown {
		t.Fatalf("first status = %#v err=%v", first, err)
	}
	second, err := runner.Status(context.Background())
	if err == nil || second.Readability != "unreadable" || !second.LastKnown {
		t.Fatalf("second status = %#v err=%v", second, err)
	}
	if second.Facts["hostLoaded"] != true {
		t.Fatalf("last-known facts = %#v", second.Facts)
	}
}

func TestComputeNodeMutatingCommandsRequireConfirmation(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{
		"compute-node", "stop", "--json",
	}, map[string]string{
		vmmLifecycleEnv: filepath.Join(t.TempDir(), "missing-helper"),
	})

	if exitCode != output.ExitUsage {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stderr, &body)
	if body["error"].(map[string]any)["code"] != "confirm_mutating_required" {
		t.Fatalf("error = %#v", body)
	}
}

func TestComputeNodeRemoveUsesLifecycleWhenManagedCLIIsMissing(t *testing.T) {
	helper := writeVMMHelper(t, `{}`)
	missingCLI := filepath.Join(t.TempDir(), "missing-agent-vmm")
	exitCode, stdout, stderr := runCLI(t, []string{
		"compute-node", "remove", "--confirm-mutating", "--request=request-remove", "--json",
	}, map[string]string{vmmLifecycleEnv: helper, vmmCLIEnv: missingCLI})
	if exitCode != output.ExitOK || stderr != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	if !strings.Contains(stdout, `"helper_action": "uninstall"`) {
		t.Fatalf("remove output = %s", stdout)
	}
}

func TestComputeNodeStatusSeparatesVMMReadinessFromRunnerOnline(t *testing.T) {
	helper := writeVMMHelper(t, `{"hostInstalled":true,"hostLoaded":true,"hostReadable":true,"hostHealthy":true,"applianceInstalled":true,"applianceHealthy":true,"controllerActive":true,"inventoryComplete":true,"salixReady":true}`)
	exitCode, stdout, stderr := runCLI(t, []string{
		"compute-node", "status", "--json",
	}, map[string]string{vmmLifecycleEnv: helper, vmmCLIEnv: helper})

	if exitCode != output.ExitOK || stderr != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stdout, &body)
	data := body["data"].(map[string]any)
	if data["vmm_readiness"] != "ready" || data["vmm_ready"] != true {
		t.Fatalf("VMM readiness = %#v", data)
	}
	if data["runner_online"] != "unknown" {
		t.Fatalf("runner_online = %#v", data["runner_online"])
	}
	if data["node_admission"] != "unknown" || data["node_admission_source"] != "server_only" {
		t.Fatalf("node admission = %#v", data)
	}
	if strings.Contains(stdout, `"salix_ready"`) {
		t.Fatalf("status fabricated Salix readiness: %s", stdout)
	}
	if !strings.Contains(data["readiness_statement"].(string), "proves neither") {
		t.Fatalf("readiness statement = %#v", data["readiness_statement"])
	}
}

func TestVMMReadinessDoesNotInferServerAdmission(t *testing.T) {
	facts := map[string]any{
		"hostInstalled": true, "hostLoaded": true, "hostReadable": true, "hostHealthy": true,
		"applianceInstalled": true, "applianceHealthy": true,
		"controllerActive": true, "inventoryComplete": true,
		"salixReady": false,
	}
	if got := vmmReadiness(VMMStatus{State: "healthy", Freshness: "current", Facts: facts}); got != "ready" {
		t.Fatalf("readiness=%q", got)
	}
}

func TestVMMReadinessRequiresCurrentCompleteDirectObservation(t *testing.T) {
	tests := []struct {
		name   string
		status VMMStatus
		want   string
	}{
		{name: "current", status: VMMStatus{State: "healthy", Freshness: "current"}, want: "ready"},
		{name: "stale", status: VMMStatus{State: "healthy", Freshness: "stale"}, want: "not_ready"},
		{name: "unknown freshness", status: VMMStatus{State: "healthy", Freshness: "unknown"}, want: "unknown"},
		{name: "partial", status: VMMStatus{State: "healthy", Freshness: "current", Partial: true}, want: "not_ready"},
		{name: "last known", status: VMMStatus{State: "healthy", Freshness: "current", LastKnown: true}, want: "unknown"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := vmmReadiness(test.status); got != test.want {
				t.Fatalf("readiness=%q want=%q", got, test.want)
			}
		})
	}
}

func TestComputeNodeStaleInspectCannotCompleteInstall(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "agent-vmm")
	script := "#!/bin/sh\nset -eu\nif [ \"${1:-}\" = inspect ]; then\n  printf '%s\\n' '{\"version\":1,\"state\":\"healthy\",\"freshness\":\"stale\",\"partial\":false,\"facts\":{\"hostHealthy\":true}}'\nfi\n"
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	exitCode, stdout, stderr := runCLI(t, []string{"compute-node", "install", "--confirm-mutating", "--request=request-install", "--json"}, map[string]string{vmmLifecycleEnv: helper, vmmCLIEnv: helper})
	if exitCode != output.ExitUnavailable || stdout != "" || !strings.Contains(stderr, `"readiness": "not_ready"`) {
		t.Fatalf("exit=%d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
}

func TestComputeNodeStatusDoesNotPromoteStaleHealth(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "agent-vmm")
	script := "#!/bin/sh\nprintf '%s\\n' '{\"version\":1,\"state\":\"healthy\",\"freshness\":\"stale\",\"partial\":false,\"facts\":{\"hostHealthy\":true}}'\n"
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	exitCode, stdout, stderr := runCLI(t, []string{"compute-node", "status", "--json"}, map[string]string{vmmLifecycleEnv: helper, vmmCLIEnv: helper})
	if exitCode != output.ExitOK || stderr != "" || !strings.Contains(stdout, `"vmm_ready": false`) || !strings.Contains(stdout, `"vmm_freshness": "stale"`) {
		t.Fatalf("exit=%d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
}

func TestComputeNodeMissingHelperReturnsActionableError(t *testing.T) {
	helper := filepath.Join(t.TempDir(), "missing-agent-vmm-lifecycle")
	exitCode, stdout, stderr := runCLI(t, []string{
		"compute-node", "status", "--json",
	}, map[string]string{vmmLifecycleEnv: helper, vmmCLIEnv: helper})

	if exitCode != output.ExitNotFound || stdout != "" {
		t.Fatalf("exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var body map[string]any
	decodeJSON(t, stderr, &body)
	errorBody := body["error"].(map[string]any)
	if errorBody["code"] != "vmm_lifecycle_helper_not_found" {
		t.Fatalf("error = %#v", errorBody)
	}
	if !strings.Contains(errorBody["next_action"].(string), vmmLifecycleEnv) {
		t.Fatalf("next_action = %#v", errorBody["next_action"])
	}
}

func TestComputeNodeSchemaHelpAndCompletionExposeLifecycleCommands(t *testing.T) {
	exitCode, stdout, stderr := runCLI(t, []string{"commands", "--json"}, nil)
	if exitCode != output.ExitOK || stderr != "" {
		t.Fatalf("schema exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
	var schema map[string]any
	decodeJSON(t, stdout, &schema)
	commands := schema["data"].(map[string]any)["commands"].([]any)
	seen := map[string]bool{}
	for _, raw := range commands {
		seen[raw.(map[string]any)["name"].(string)] = true
	}
	for _, name := range []string{"compute-node install", "compute-node status", "compute-node repair", "compute-node stop", "compute-node remove"} {
		if !seen[name] {
			t.Fatalf("schema missing %q", name)
		}
	}

	exitCode, stdout, stderr = runCLI(t, []string{"compute-node", "help", "--json"}, nil)
	if exitCode != output.ExitOK || stderr != "" || !strings.Contains(stdout, vmmLifecycleEnv) {
		t.Fatalf("help exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}

	exitCode, stdout, stderr = runCLI(t, []string{"completion", "zsh"}, nil)
	if exitCode != output.ExitOK || stderr != "" || !strings.Contains(stdout, "compute-node") || !strings.Contains(stdout, "repair") {
		t.Fatalf("completion exit = %d stdout=%s stderr=%s", exitCode, stdout, stderr)
	}
}

func writeVMMHelper(t *testing.T, status string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "agent-vmm-lifecycle")
	state := "healthy"
	if strings.Contains(status, `"hostHealthy":false`) {
		state = "unhealthy"
	}
	script := "#!/bin/sh\nset -eu\nif [ \"${1:-}\" = status ]; then\n  printf '%s\\n' '" + status + "'\n  exit 0\nfi\nif [ \"${1:-}\" = inspect ]; then\n  printf '%s\\n' '" + `{"version":1,"state":"` + state + `","freshness":"current","facts":` + status + `}` + "'\n  exit 0\nfi\n"
	if err := os.WriteFile(path, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	return path
}

func readTestFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(data)
}

func TestComputeNodeStatusDataDoesNotInferReadinessFromPartialFacts(t *testing.T) {
	data := computeNodeStatusData("/tmp/helper", VMMStatus{
		Facts:       map[string]any{"hostLoaded": true},
		Readability: "readable",
	}, nil)
	if data["vmm_readiness"] != "unknown" {
		t.Fatalf("readiness = %#v", data["vmm_readiness"])
	}
	if _, ok := data["vmm_ready"]; ok {
		t.Fatalf("partial facts produced vmm_ready: %#v", data)
	}
}

func TestVMMStatusJSONUsesRawHelperFacts(t *testing.T) {
	runner := &localVMMRunner{
		path:        "/tmp/agent-vmm-lifecycle",
		inspectPath: "/tmp/agent-vmm",
		command: func(_ context.Context, _ string, _ []string) ([]byte, []byte, error) {
			return []byte(`{"version":1,"state":"healthy","freshness":"current","facts":{"applianceInstalled":false,"salixReady":false}}`), nil, nil
		},
	}
	status, err := runner.Status(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(status.Facts)
	if err != nil || !strings.Contains(string(encoded), `"salixReady":false`) {
		t.Fatalf("facts=%s err=%v", encoded, err)
	}
}
