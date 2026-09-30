package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestVerifyComponentTargetBindsExactComponentDigestAndURL(t *testing.T) {
	config := map[string]any{}
	digest := strings.Repeat("a", 64)
	url := "https://releases.example.test/darwin-arm64/agent-vmm"
	update := map[string]any{
		"component": "agent-vmm-host",
		"sha256":    digest,
		"size":      42,
	}

	if err := verifyComponentTarget(config, "agent-vmm", update, url); err != nil {
		t.Fatal(err)
	}
	if err := verifyComponentTarget(config, "agent-vmm", update, "https://releases.example.test/__BFT_PLATFORM__/agent-vmm"); err == nil {
		t.Fatal("non-exact platform URL was accepted")
	}
	update["component"] = "salix-connect"
	if err := verifyComponentTarget(config, "agent-vmm", update, url); err == nil {
		t.Fatal("cross-component target was accepted")
	}
}

func TestRootAtomicJSONWritePreservesServiceOwnership(t *testing.T) {
	if os.Geteuid() != 0 {
		t.Skip("requires root to reproduce the administrator update ceremony")
	}
	const serviceUID = 65534
	const serviceGID = 65534
	root := t.TempDir()
	existingPath := filepath.Join(root, "runner.json")
	if err := os.WriteFile(existingPath, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(existingPath, serviceUID, serviceGID); err != nil {
		t.Fatal(err)
	}
	if err := writeJSON(existingPath, map[string]any{"updated": true}, 0o600); err != nil {
		t.Fatal(err)
	}
	assertFileOwner(t, existingPath, serviceUID, serviceGID)

	stateDir := filepath.Join(root, "state")
	if err := os.Mkdir(stateDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chown(stateDir, serviceUID, serviceGID); err != nil {
		t.Fatal(err)
	}
	newStatusPath := filepath.Join(stateDir, "runner-status.json")
	if err := writeJSON(newStatusPath, map[string]any{"status": "ready"}, 0o644); err != nil {
		t.Fatal(err)
	}
	assertFileOwner(t, newStatusPath, serviceUID, serviceGID)
}

func TestAtomicJSONWriteCarriesForwardExistingOwner(t *testing.T) {
	root := t.TempDir()
	path := filepath.Join(root, "runner.json")
	if err := os.WriteFile(path, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	expected := info.Sys().(*syscall.Stat_t)

	originalChown := chownAtomicJSONFile
	t.Cleanup(func() { chownAtomicJSONFile = originalChown })
	var called bool
	chownAtomicJSONFile = func(_ *os.File, uid, gid int) error {
		called = true
		if uid != int(expected.Uid) || gid != int(expected.Gid) {
			t.Fatalf("atomic replacement owner = %d:%d, want %d:%d", uid, gid, expected.Uid, expected.Gid)
		}
		return nil
	}
	if err := writeJSON(path, map[string]any{"updated": true}, 0o600); err != nil {
		t.Fatal(err)
	}
	if !called {
		t.Fatal("atomic replacement did not carry forward the protected file owner")
	}
}

func assertFileOwner(t *testing.T, path string, expectedUID, expectedGID uint32) {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	owner, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		t.Fatalf("%s does not expose Unix ownership", path)
	}
	if owner.Uid != expectedUID || owner.Gid != expectedGID {
		t.Fatalf("%s owner = %d:%d, want %d:%d", path, owner.Uid, owner.Gid, expectedUID, expectedGID)
	}
}

func TestHostRuntimeServiceArgumentsUseInstalledServiceIdentity(t *testing.T) {
	for _, test := range []struct {
		name     string
		launchd  map[string]any
		expected []string
	}{
		{
			name: "system daemon keeps the non-root install user under a root updater",
			launchd: map[string]any{
				"domain":       "system",
				"service_user": "bftvmm",
			},
			expected: []string{"--service-type", "daemon", "--service-user", "bftvmm"},
		},
		{
			name: "gui service keeps its installed user",
			launchd: map[string]any{
				"domain":       "gui/501",
				"service_user": "alice",
			},
			expected: []string{"--service-type", "agent", "--service-user", "alice"},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			actual, err := hostRuntimeServiceArguments(map[string]any{"launchd": test.launchd})
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(actual, test.expected) {
				t.Fatalf("service arguments = %q, want %q", actual, test.expected)
			}
		})
	}

	if _, err := hostRuntimeServiceArguments(map[string]any{"launchd": map[string]any{"domain": "system"}}); err == nil {
		t.Fatal("missing installed service user was accepted")
	}
}

func TestHostRuntimeOperationDoesNotUseTheShortProbeTimeout(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	writeExecutable(t, helper, "#!/bin/sh\nsleep 3\n")

	if err := runHostRuntimeOperation(helper, []string{"install"}); err != nil {
		t.Fatalf("lifecycle install was killed by the short version/status probe timeout: %v", err)
	}
}

func TestManagedVMMObservationUsesPublicInspectContract(t *testing.T) {
	root := t.TempDir()
	lifecycle := filepath.Join(root, "agent-vmm-lifecycle")
	cli := filepath.Join(root, "agent-vmm")
	logPath := filepath.Join(root, "arguments.log")
	writeExecutable(t, lifecycle, "#!/bin/sh\nexit 0\n")
	writeExecutable(t, cli, "#!/bin/sh\nprintf '%s\\n' \"$*\" > "+strconv.Quote(logPath)+"\nprintf '%s\\n' '{\"version\":1,\"state\":\"healthy\",\"freshness\":\"current\",\"partial\":false}'\n")
	config := map[string]any{
		"paths":   map[string]any{"host_runtime_lifecycle": lifecycle, "host_runtime_cli": cli},
		"launchd": map[string]any{"domain": "system", "service_user": "bftvmm"},
	}
	observation, err := observeManagedVMM(config)
	if err != nil || observation.State != "healthy" || observation.Freshness != "current" {
		t.Fatalf("observation=%+v err=%v", observation, err)
	}
	want := "inspect --json --lifecycle-helper " + lifecycle + " --service-type daemon --service-user bftvmm\n"
	raw, readErr := os.ReadFile(logPath)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if got := string(raw); got != want {
		t.Fatalf("inspect arguments=%q want=%q", got, want)
	}
}

func TestManagedVMMObservationRejectsInvalidContract(t *testing.T) {
	root := t.TempDir()
	lifecycle := filepath.Join(root, "agent-vmm-lifecycle")
	cli := filepath.Join(root, "agent-vmm")
	writeExecutable(t, lifecycle, "#!/bin/sh\nexit 0\n")
	writeExecutable(t, cli, "#!/bin/sh\nprintf '%s\\n' '{\"state\":\"healthy\"}'\n")
	_, err := observeManagedVMM(map[string]any{
		"paths":   map[string]any{"host_runtime_lifecycle": lifecycle, "host_runtime_cli": cli},
		"launchd": map[string]any{"domain": "gui/501", "service_user": "alice"},
	})
	var typed provisionerError
	if !errors.As(err, &typed) || typed.code != "agent_vmm.inspect_invalid" {
		t.Fatalf("invalid contract error=%v", err)
	}
}

func testAgentVMMConfig(helper string) map[string]any {
	return map[string]any{
		"paths":   map[string]any{"host_runtime_lifecycle": helper},
		"launchd": map[string]any{"domain": "system", "service_user": "bftvmm"},
	}
}

func TestDownloadArtifactRejectsOversizeAndUndersizeBeforePublishing(t *testing.T) {
	for _, test := range []struct {
		name     string
		body     string
		expected uint64
		chunked  bool
	}{
		{name: "oversize chunked response", body: "123456", expected: 5, chunked: true},
		{name: "undersize declared response", body: "1234", expected: 5},
	} {
		t.Run(test.name, func(t *testing.T) {
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				if test.chunked {
					w.WriteHeader(http.StatusOK)
					w.(http.Flusher).Flush()
				}
				_, _ = io.WriteString(w, test.body)
			}))
			defer server.Close()

			target := filepath.Join(t.TempDir(), "artifact")
			_, err := downloadArtifact(server.URL, time.Second, test.expected, strings.Repeat("a", 64), target, 0o600)
			if !errors.Is(err, errArtifactSizeMismatch) {
				t.Fatalf("expected size mismatch, got %v", err)
			}
			if _, statErr := os.Stat(target); !errors.Is(statErr, os.ErrNotExist) {
				t.Fatalf("mismatched artifact was published: %v", statErr)
			}
			if _, statErr := os.Stat(target + ".download"); !errors.Is(statErr, os.ErrNotExist) {
				t.Fatalf("partial artifact was retained: %v", statErr)
			}
		})
	}
}

func TestCurrentConnectorRunIDIgnoresTransientPartialStatus(t *testing.T) {
	stateDir := t.TempDir()
	requestID := "req_partial_status"
	path := connectorStatusPath(stateDir, requestID)
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}

	runID, err := currentConnectorRunIDFromStatus(stateDir, requestID)
	if err != nil {
		t.Fatal(err)
	}
	if runID != "" {
		t.Fatalf("partial status projected run id %q", runID)
	}

	if err := os.WriteFile(path, []byte(`{"state":"connected","connector_run_id":"run-1"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	runID, err = currentConnectorRunIDFromStatus(stateDir, requestID)
	if err != nil {
		t.Fatal(err)
	}
	if runID != "run-1" {
		t.Fatalf("run id = %q", runID)
	}
}

func TestRestoreComponentReplacesPopulatedBundle(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "Agent VMM Host.app")
	backup := target + ".previous"
	if err := os.MkdirAll(filepath.Join(target, "Contents", "Helpers"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(target, "Contents", "Helpers", "new"), []byte("bad"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(backup, "Contents", "Helpers"), 0o755); err != nil {
		t.Fatal(err)
	}
	oldHelper := filepath.Join(backup, "Contents", "Helpers", "old")
	if err := os.WriteFile(oldHelper, []byte("good"), 0o600); err != nil {
		t.Fatal(err)
	}

	if err := restoreComponent(target, backup, true); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(target, "Contents", "Helpers", "old")); err != nil || string(got) != "good" {
		t.Fatalf("restored helper = %q, %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(target, "Contents", "Helpers", "new")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("bad helper survived rollback: %v", err)
	}
}

func TestAgentVMMInstallDescriptorIsPipedToLifecycleHelper(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	script := `#!/bin/sh
set -eu
test "$1" = install
test "$2" = --disable-personal-mesh-pairing
test "$3" = --request-id
test "$4" = operation-1
test "$5" = --operation-stdin
test "$6" = --service-type
test "$7" = daemon
test "$8" = --service-user
test -n "$9"
payload=$(cat)
case "$payload" in *one_time_secret*secret-value*) ;; *) exit 8 ;; esac
printf '%s\n' '{"operationId":"operation-1","outcome":"succeeded","secretDisposition":"destroy_completed"}'
`
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	statusPath := filepath.Join(root, "status.json")
	heartbeat := map[string]any{"agent_vmm_install": map[string]any{
		"version": 1, "operation_id": "operation-1", "exchange_url": "https://example.test/exchange",
		"one_time_secret": "secret-value", "expires_at": "2099-01-01T00:00:00Z",
	}}
	config := map[string]any{
		"paths":   map[string]any{"host_runtime_lifecycle": helper},
		"launchd": map[string]any{"domain": "system", "service_user": "bftvmm"},
	}
	if err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, statusPath, heartbeat); err != nil {
		t.Fatal(err)
	}
	status, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(status, []byte("secret-value")) || !bytes.Contains(status, []byte("agent_vmm_install_applied")) {
		t.Fatalf("status leaked secret or missed outcome: %s", status)
	}
}

func TestAgentVMMInstallDescriptorSurvivesHelperFailureAndRetriesWithoutRedelivery(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	attemptPath := filepath.Join(root, "attempt")
	script := `#!/bin/sh
set -eu
payload=$(cat)
case "$payload" in *one_time_secret*secret-value*) ;; *) exit 8 ;; esac
if [ ! -f "` + attemptPath + `" ]; then
  : > "` + attemptPath + `"
  printf '%s\n' '{"operationId":"operation-1","outcome":"failed","attempt":1,"failureStage":"appliance-install","failureCode":"upstream_unavailable","failureMessage":"install service returned HTTP 503","retryable":true}'
  exit 9
fi
printf '%s\n' '{"operationId":"operation-1","outcome":"succeeded","secretDisposition":"destroy_completed"}'
`
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	statusPath := filepath.Join(root, "status.json")
	heartbeat := map[string]any{"agent_vmm_install": map[string]any{
		"version": 1, "operation_id": "operation-1", "exchange_url": "https://example.test/exchange",
		"one_time_secret": "secret-value", "expires_at": "2099-01-01T00:00:00Z",
	}}
	config := testAgentVMMConfig(helper)
	if err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, statusPath, heartbeat); err == nil {
		t.Fatal("first helper failure was not reported")
	}
	pendingPath := agentVMMInstallDescriptorPath(root, "operation-1")
	info, err := os.Stat(pendingPath)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("pending descriptor was not durably private: %v mode=%v", err, info)
	}
	if err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, statusPath, map[string]any{}); err != nil {
		t.Fatalf("pending descriptor was not retried: %v", err)
	}
	if _, err := os.Stat(pendingPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("applied descriptor was not removed: %v", err)
	}
}

func TestAgentVMMInstallPermanentFailureClearsBearerAndReportsStage(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	script := `#!/bin/sh
set -eu
if [ "${1:-}" = "install-operation-ack" ]; then
  : > "$0.acked"
  exit 0
fi
cat >/dev/null
printf '%s\n' '{"operationId":"operation-1","outcome":"failed","attempt":1,"failureStage":"reconnect","failureCode":"install_failed","failureMessage":"managed trust bundle is invalid","retryable":false,"secretDisposition":"destroy_terminal"}'
exit 9
`
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	statusPath := filepath.Join(root, "status.json")
	heartbeat := map[string]any{"agent_vmm_install": map[string]any{
		"version": 1, "operation_id": "operation-1", "exchange_url": "https://example.test/exchange",
		"one_time_secret": "secret-value", "expires_at": "2099-01-01T00:00:00Z",
	}}
	config := testAgentVMMConfig(helper)
	err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, statusPath, heartbeat)
	if err == nil || !strings.Contains(err.Error(), "reconnect") {
		t.Fatalf("permanent failure was not reported with its stage: %v", err)
	}
	if _, statErr := os.Stat(agentVMMInstallDescriptorPath(root, "operation-1")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("terminal failure retained bearer descriptor: %v", statErr)
	}
	reports, reportErr := agentVMMInstallFailureReports(root)
	if reportErr != nil || len(reports) != 1 || stringValue(reports[0].(map[string]any)["operation_id"]) != "operation-1" ||
		stringValue(reports[0].(map[string]any)["failure_code"]) != "agent_vmm.install_failed" {
		t.Fatalf("terminal failure was not durably reportable: reports=%v err=%v", reports, reportErr)
	}
	payload := provisionerPayload(config, 0, reports)
	if len(payload["agent_vmm_install_failures"].([]any)) != 1 {
		t.Fatalf("heartbeat payload omitted terminal report: %v", payload)
	}
	if err := acknowledgeAgentVMMInstallFailures(config, root, map[string]any{
		"agent_vmm_install_failure_acks": []any{"operation-1"},
	}); err != nil {
		t.Fatalf("terminal report acknowledgement failed: %v", err)
	}
	if _, statErr := os.Stat(agentVMMInstallFailurePath(root, "operation-1")); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("acknowledged terminal report was retained: %v", statErr)
	}
	if _, statErr := os.Stat(helper + ".acked"); statErr != nil {
		t.Fatalf("Server acknowledgement did not trigger helper-owned plan cleanup: %v", statErr)
	}
	status, readErr := os.ReadFile(statusPath)
	if readErr != nil || bytes.Contains(status, []byte("secret-value")) ||
		!bytes.Contains(status, []byte("managed trust bundle is invalid")) || !bytes.Contains(status, []byte("reconnect")) {
		t.Fatalf("terminal status missed safe diagnostics or leaked bearer: %s err=%v", status, readErr)
	}
}

func TestAgentVMMInstallNonRetryableRetainKeepsDescriptorWithoutTerminalReport(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	script := `#!/bin/sh
set -eu
cat >/dev/null
printf '%s\n' '{"operationId":"operation-1","outcome":"failed","attempt":1,"failureStage":"appliance-install","failureCode":"install_failed","failureMessage":"persist install plan: permission denied","retryable":false,"secretDisposition":"retain"}'
exit 9
`
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	statusPath := filepath.Join(root, "status.json")
	heartbeat := map[string]any{"agent_vmm_install": map[string]any{
		"version": 1, "operation_id": "operation-1", "exchange_url": "https://example.test/exchange",
		"one_time_secret": "secret-value", "expires_at": "2099-01-01T00:00:00Z",
	}}
	config := testAgentVMMConfig(helper)
	err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, statusPath, heartbeat)
	if err == nil || !strings.Contains(err.Error(), "retained local recovery material") {
		t.Fatalf("retained local failure was not diagnosed: %v", err)
	}
	if _, statErr := os.Stat(agentVMMInstallDescriptorPath(root, "operation-1")); statErr != nil {
		t.Fatalf("retained local failure removed descriptor: %v", statErr)
	}
	if reports, reportErr := agentVMMInstallFailureReports(root); reportErr != nil || len(reports) != 0 {
		t.Fatalf("retained local failure was terminalized: reports=%v err=%v", reports, reportErr)
	}
	status, readErr := os.ReadFile(statusPath)
	if readErr != nil || !bytes.Contains(status, []byte("agent_vmm_install_local_failure")) || bytes.Contains(status, []byte("secret-value")) {
		t.Fatalf("retained local failure status invalid: %s err=%v", status, readErr)
	}
}

func TestExpiredAgentVMMInstallDescriptorDropsBearerAndUsesDurableResume(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	script := `#!/bin/sh
set -eu
test "$1" = install
test "$2" = --disable-personal-mesh-pairing
test "$3" = --request-id
test "$4" = operation-1
test "$5" = --resume-operation
test "$6" = operation-1
printf '%s\n' '{"operationId":"operation-1","outcome":"succeeded","secretDisposition":"destroy_completed"}'
`
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	statusPath := filepath.Join(root, "status.json")
	pendingPath := agentVMMInstallDescriptorPath(root, "operation-1")
	descriptor := map[string]any{
		"version": 1, "operation_id": "operation-1", "exchange_url": "https://example.test/exchange",
		"one_time_secret": "expired-secret", "expires_at": "2020-01-01T00:00:00Z",
	}
	if err := writeJSON(pendingPath, descriptor, 0o600); err != nil {
		t.Fatal(err)
	}
	config := testAgentVMMConfig(helper)
	if err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, statusPath, map[string]any{}); err != nil {
		t.Fatalf("durable resume failed: %v", err)
	}
	if _, err := os.Stat(pendingPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expired bearer descriptor was retained: %v", err)
	}
	status, err := os.ReadFile(statusPath)
	if err != nil || bytes.Contains(status, []byte("expired-secret")) || !bytes.Contains(status, []byte("agent_vmm_install_applied")) {
		t.Fatalf("expired descriptor status leaked bearer or missed recovery: %s err=%v", status, err)
	}
}

func TestExpiredAgentVMMInstallDescriptorWithoutPlanBecomesActionRequired(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	if err := os.WriteFile(helper, []byte("#!/bin/sh\nprintf '%s\\n' '{\"operationId\":\"operation-1\",\"outcome\":\"failed\",\"attempt\":1,\"failureStage\":\"install-managed\",\"failureCode\":\"install_failed\",\"failureMessage\":\"managed install plan is unavailable\",\"retryable\":false,\"secretDisposition\":\"destroy_terminal\"}'\nexit 9\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	statusPath := filepath.Join(root, "status.json")
	pendingPath := agentVMMInstallDescriptorPath(root, "operation-1")
	descriptor := map[string]any{
		"version": 1, "operation_id": "operation-1", "exchange_url": "https://example.test/exchange",
		"one_time_secret": "expired-secret", "expires_at": "2020-01-01T00:00:00Z",
	}
	if err := writeJSON(pendingPath, descriptor, 0o600); err != nil {
		t.Fatal(err)
	}
	config := testAgentVMMConfig(helper)
	err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, statusPath, map[string]any{})
	if err == nil || !strings.Contains(err.Error(), "requires operator action") {
		t.Fatalf("expired descriptor without plan did not fail closed: %v", err)
	}
	if _, statErr := os.Stat(pendingPath); !errors.Is(statErr, os.ErrNotExist) {
		t.Fatalf("expired bearer descriptor was retained: %v", statErr)
	}
	status, readErr := os.ReadFile(statusPath)
	if readErr != nil || bytes.Contains(status, []byte("expired-secret")) || !bytes.Contains(status, []byte("agent_vmm_install_action_required")) {
		t.Fatalf("expired descriptor status leaked bearer or missed action required: %s err=%v", status, readErr)
	}
}

func TestExpiredAgentVMMInstallDescriptorRetryableResumeKeepsSafeTrigger(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	attemptPath := filepath.Join(root, "attempt")
	script := `#!/bin/sh
set -eu
test "$1" = install
test "$5" = --resume-operation
test "$6" = operation-1
if [ ! -f "` + attemptPath + `" ]; then
  : > "` + attemptPath + `"
  printf '%s\n' '{"operationId":"operation-1","outcome":"failed","attempt":2,"failureStage":"appliance-install","failureCode":"upstream_unavailable","failureMessage":"install service returned HTTP 503","retryable":true}'
  exit 9
fi
printf '%s\n' '{"operationId":"operation-1","outcome":"succeeded","secretDisposition":"destroy_completed"}'
`
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	statusPath := filepath.Join(root, "status.json")
	pendingPath := agentVMMInstallDescriptorPath(root, "operation-1")
	descriptor := map[string]any{
		"version": 1, "operation_id": "operation-1", "exchange_url": "https://example.test/exchange",
		"one_time_secret": "expired-secret", "expires_at": "2020-01-01T00:00:00Z",
	}
	if err := writeJSON(pendingPath, descriptor, 0o600); err != nil {
		t.Fatal(err)
	}
	config := testAgentVMMConfig(helper)
	if err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, statusPath, map[string]any{}); err == nil || !strings.Contains(err.Error(), "retryable") {
		t.Fatalf("expired durable resume did not remain retryable: %v", err)
	}
	trigger, err := os.ReadFile(pendingPath)
	if err != nil || bytes.Contains(trigger, []byte("expired-secret")) ||
		!bytes.Contains(trigger, []byte(`"resume_operation":true`)) {
		t.Fatalf("safe resume trigger missing or retained bearer: %s err=%v", trigger, err)
	}
	if reports, err := agentVMMInstallFailureReports(root); err != nil || len(reports) != 0 {
		t.Fatalf("retryable resume was terminalized: reports=%v err=%v", reports, err)
	}
	if err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, statusPath, map[string]any{}); err != nil {
		t.Fatalf("safe same-operation resume trigger was not retried: %v", err)
	}
	if _, err := os.Stat(pendingPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("successful resume retained trigger: %v", err)
	}
}

func TestAgentVMMInstallDescriptorsArePersistedPerOperation(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	script := `#!/bin/sh
set -eu
payload=$(cat)
case "$payload" in
  *operation-1*) operation=operation-1 ;;
  *operation-2*) operation=operation-2 ;;
  *) exit 8 ;;
esac
printf '{"operationId":"%s","outcome":"failed","attempt":1,"failureStage":"exchange","failureCode":"upstream_unavailable","failureMessage":"temporary","retryable":true}\n' "$operation"
exit 9
`
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	config := testAgentVMMConfig(helper)
	for _, operationID := range []string{"operation-1", "operation-2"} {
		heartbeat := map[string]any{"agent_vmm_install": map[string]any{
			"version": 1, "operation_id": operationID, "exchange_url": "https://example.test/exchange",
			"one_time_secret": "secret-" + operationID, "expires_at": "2099-01-01T00:00:00Z",
		}}
		if err := applyAgentVMMInstallDescriptor(runOptions{start: true}, config, root, filepath.Join(root, "status.json"), heartbeat); err == nil {
			t.Fatalf("%s retryable failure was not reported", operationID)
		}
	}
	for _, operationID := range []string{"operation-1", "operation-2"} {
		if _, err := os.Stat(agentVMMInstallDescriptorPath(root, operationID)); err != nil {
			t.Fatalf("%s descriptor was overwritten or lost: %v", operationID, err)
		}
	}
}

func TestWorkerContinuesIndependentWorkAfterManagedInstallFailure(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	controlApplied := filepath.Join(root, "control-applied")
	writeExecutable(t, helper, `#!/bin/sh
if [ "$1" = registration-state ]; then
  : > `+strconv.Quote(controlApplied)+`
  printf '%s\n' '{"outcome":"succeeded"}'
  exit 0
fi
printf '%s\n' '{"operationId":"operation-1","outcome":"failed","attempt":1,"failureStage":"appliance-install","failureCode":"upstream_unavailable","failureMessage":"temporary","retryable":true}'
exit 9
`)
	var claims atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if strings.HasSuffix(request.URL.Path, "/claim") {
			claims.Add(1)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if strings.HasSuffix(request.URL.Path, "/heartbeat") {
			replyJSON(w, http.StatusOK, map[string]any{
				"agent_vmm_install": map[string]any{
					"version": 1, "operation_id": "operation-1", "exchange_url": "https://example.test/exchange",
					"one_time_secret": "secret-value", "expires_at": "2099-01-01T00:00:00Z",
				},
				"agent_vmm_controls": map[string]any{"version": 1, "items": []any{map[string]any{
					"operation_id": "control-1", "registration_id": "registration-1", "registration_revision": 1, "state": "enabled",
				}}},
			})
			return
		}
		replyJSON(w, http.StatusNotFound, map[string]any{"error": "not_found"})
	}))
	defer server.Close()

	stateDir := filepath.Join(root, "state")
	if err := runWorkerIteration(runOptions{start: true, timeout: time.Second}, testAgentVMMConfig(helper), stateDir,
		filepath.Join(root, "status.json"), server.URL, "token", "org", "runner", nil, map[string]*managedConnector{}); err != nil {
		t.Fatalf("iteration failed after local install failure: %v", err)
	}
	if claims.Load() != 1 {
		t.Fatalf("managed install failure blocked independent claim work: claims=%d", claims.Load())
	}
	if _, err := os.Stat(controlApplied); err != nil {
		t.Fatalf("managed install failure blocked independent control work: %v", err)
	}
	if _, err := os.Stat(agentVMMInstallDescriptorPath(stateDir, "operation-1")); err != nil {
		t.Fatalf("retryable install operation was not retained: %v", err)
	}
}

func TestWorkerReportsDaemonUpdateAndStillAppliesExplicitInstall(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	applied := filepath.Join(root, "install-applied")
	writeExecutable(t, helper, `#!/bin/sh
set -eu
if [ "$1" = version ]; then
  printf '%s\n' '{"component":"agent-vmm-host","version":"release-1","release_id":"release-1"}'
  exit 0
fi
test "$1" = install
payload=$(cat)
case "$payload" in *one_time_secret*secret-value*) ;; *) exit 8 ;; esac
: > "`+applied+`"
printf '%s\n' '{"operationId":"operation-1","outcome":"succeeded","secretDisposition":"destroy_completed"}'
`)

	var heartbeats atomic.Int32
	var claims atomic.Int32
	artifactServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "not trusted by the release client")
	}))
	defer artifactServer.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if strings.HasSuffix(request.URL.Path, "/claim") {
			claims.Add(1)
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if !strings.HasSuffix(request.URL.Path, "/heartbeat") {
			replyJSON(w, http.StatusNotFound, map[string]any{"error": "not_found"})
			return
		}
		heartbeats.Add(1)
		response := map[string]any{
			"agent_vmm_install": map[string]any{
				"version": 1, "operation_id": "operation-1",
				"exchange_url":    "https://example.test/exchange",
				"one_time_secret": "secret-value", "expires_at": "2099-01-01T00:00:00Z",
			},
		}
		response["updates"] = map[string]any{"agent-vmm": map[string]any{
			"component": "agent-vmm-host", "artifact_url": artifactServer.URL + "/agent-vmm.zip",
			"release_id": "release-2", "sha256": strings.Repeat("a", 64), "size": 42,
		}}
		replyJSON(w, http.StatusOK, response)
	}))
	defer server.Close()

	stateDir := filepath.Join(root, "state")
	statusPath := filepath.Join(root, "status.json")
	config := testAgentVMMConfig(helper)
	opts := runOptions{start: true, timeout: time.Second}
	connectors := map[string]*managedConnector{}

	if err := runWorkerIteration(opts, config, stateDir, statusPath, server.URL, "token", "org", "runner", nil, connectors); err != nil {
		t.Fatalf("first iteration failed: %v", err)
	}
	pendingPath := agentVMMInstallDescriptorPath(stateDir, "operation-1")
	if heartbeats.Load() != 1 {
		t.Fatalf("first iteration heartbeat count = %d, want 1", heartbeats.Load())
	}
	if claims.Load() != 1 {
		t.Fatalf("administrator-owned update blocked normal runner work: claim count = %d, want 1", claims.Load())
	}
	if _, err := os.Stat(applied); err != nil {
		t.Fatalf("operator-owned system update blocked the managed install: %v", err)
	}
	if _, err := os.Stat(pendingPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("completed descriptor was retained: %v", err)
	}
	if status, err := os.ReadFile(statusPath); err != nil || bytes.Contains(status, []byte("secret-value")) || !bytes.Contains(status, []byte(`"status":"idle"`)) || !bytes.Contains(status, []byte(`"agent_vmm_update":{"failure_code":"agent_vmm.administrator_update_required"`)) {
		t.Fatalf("managed install/update status=%s err=%v", status, err)
	}

	if err := runWorkerIteration(opts, config, stateDir, statusPath, server.URL, "token", "org", "runner", nil, connectors); err != nil {
		t.Fatalf("pending install iteration failed: %v", err)
	}
	if heartbeats.Load() != 2 {
		t.Fatalf("pending install did not continue heartbeat: heartbeat count = %d", heartbeats.Load())
	}
	if claims.Load() != 2 {
		t.Fatalf("repeated administrator-owned update blocked normal runner work: claim count = %d, want 2", claims.Load())
	}
	if _, err := os.Stat(pendingPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("replayed completed descriptor was retained: %v", err)
	}
}

func TestDaemonAgentVMMUpdateReportsAdministratorBoundaryWithoutExecutingCLI(t *testing.T) {
	root := t.TempDir()
	lifecycle := filepath.Join(root, "agent-vmm-lifecycle")
	cli := filepath.Join(root, "agent-vmm")
	marker := filepath.Join(root, "cli-ran")
	writeExecutable(t, lifecycle, "#!/bin/sh\nprintf '%s\\n' '{\"component\":\"agent-vmm-host\",\"version\":\"release-1\",\"release_id\":\"release-1\"}'\n")
	writeExecutable(t, cli, "#!/bin/sh\n: > "+strconv.Quote(marker)+"\n")
	exclusive, advisory, err := applyAgentVMMUpdate(runOptions{}, map[string]any{
		"paths":   map[string]any{"host_runtime_lifecycle": lifecycle, "host_runtime_cli": cli},
		"launchd": map[string]any{"domain": "system", "service_user": "bftvmm"},
	}, map[string]any{
		"component": "agent-vmm-host", "release_id": "release-2",
		"artifact_url": "https://releases.example.test/Agent-VMM-Host.zip", "sha256": strings.Repeat("a", 64), "size": 42,
	})
	if err != nil || exclusive {
		t.Fatalf("exclusive=%t err=%v", exclusive, err)
	}
	if _, err := os.Stat(marker); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("daemon update executed service-user CLI: %v", err)
	}
	if stringValue(advisory["status"]) != "agent_vmm_administrator_update_required" || stringValue(mapValue(advisory, "progress")["target_release_id"]) != "release-2" {
		t.Fatalf("advisory=%+v", advisory)
	}
}

func TestLoginAgentUpdateInvokesPackagedManagedCLIWithStableTarget(t *testing.T) {
	root := t.TempDir()
	lifecycle := filepath.Join(root, "agent-vmm-lifecycle")
	cli := filepath.Join(root, "agent-vmm")
	argumentsPath := filepath.Join(root, "args")
	writeExecutable(t, lifecycle, "#!/bin/sh\nprintf '%s\\n' '{\"component\":\"agent-vmm-host\",\"version\":\"release-1\",\"release_id\":\"release-1\"}'\n")
	writeExecutable(t, cli, "#!/bin/sh\nprintf '%s\\n' \"$*\" > "+strconv.Quote(argumentsPath)+"\nrequest_id=; while [ \"$#\" -gt 0 ]; do if [ \"$1\" = --request-id ]; then request_id=$2; break; fi; shift; done\nprintf '{\"version\":1,\"command\":\"update\",\"state\":\"succeeded\",\"stage\":\"complete\",\"disposition\":\"continue_normal_work\",\"facts\":{\"target_release_id\":\"release-2\",\"request_id\":\"%s\"}}\\n' \"$request_id\"\n")
	configPath := filepath.Join(root, "runner.json")
	config := map[string]any{
		"paths":        map[string]any{"host_runtime_lifecycle": lifecycle, "host_runtime_cli": cli},
		"launchd":      map[string]any{"domain": "gui/501", "service_user": "alice"},
		"capabilities": map[string]any{"component_digests": map[string]any{"agent-vmm-host": strings.Repeat("1", 64)}},
	}
	if err := writeJSON(configPath, config, 0o600); err != nil {
		t.Fatal(err)
	}
	update := map[string]any{
		"component": "agent-vmm-host", "release_id": "release-2",
		"artifact_url": "https://releases.example.test/Agent-VMM-Host.zip", "sha256": strings.Repeat("b", 64), "size": 42,
	}
	exclusive, advisory, err := applyAgentVMMUpdate(runOptions{configPath: configPath}, config, update)
	if err != nil || exclusive || stringValue(advisory["status"]) != "agent_vmm_update_succeeded" {
		t.Fatalf("exclusive=%t advisory=%+v err=%v", exclusive, advisory, err)
	}
	arguments, err := os.ReadFile(argumentsPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(arguments)
	for _, expected := range []string{"update --json --request-id agent-vmm-update-", "--target-release-id release-2", "--artifact-sha256 " + strings.Repeat("b", 64), "--artifact-size 42", "--service-type agent --service-user alice"} {
		if !strings.Contains(text, expected) {
			t.Fatalf("arguments %q missing %q", text, expected)
		}
	}
	persisted, err := loadJSON(configPath)
	if err != nil || stringValue(mapValue(mapValue(persisted, "capabilities"), "component_digests")["agent-vmm-host"]) != strings.Repeat("b", 64) {
		t.Fatalf("persisted config=%+v err=%v", persisted, err)
	}
}

func TestLoginAgentUpdateRetryDispositionKeepsNormalWorkEnabled(t *testing.T) {
	root := t.TempDir()
	lifecycle := filepath.Join(root, "agent-vmm-lifecycle")
	cli := filepath.Join(root, "agent-vmm")
	writeExecutable(t, lifecycle, "#!/bin/sh\nprintf '%s\\n' '{\"component\":\"agent-vmm-host\",\"version\":\"release-1\",\"release_id\":\"release-1\"}'\n")
	writeExecutable(t, cli, "#!/bin/sh\nrequest_id=; while [ \"$#\" -gt 0 ]; do if [ \"$1\" = --request-id ]; then request_id=$2; break; fi; shift; done\nprintf '{\"version\":1,\"command\":\"update\",\"state\":\"retry_wait\",\"stage\":\"download\",\"disposition\":\"retry_same_request_at\",\"issue\":{\"code\":\"update_download_unavailable\",\"message\":\"network unavailable\",\"layer\":\"lifecycle\",\"retryable\":true},\"facts\":{\"target_release_id\":\"release-2\",\"request_id\":\"%s\",\"attempt\":1,\"max_attempts\":3,\"retry_at\":\"2099-01-01T00:00:00Z\"}}\\n' \"$request_id\"\n")
	configPath := filepath.Join(root, "runner.json")
	originalDigest := strings.Repeat("1", 64)
	config := map[string]any{
		"paths":        map[string]any{"host_runtime_lifecycle": lifecycle, "host_runtime_cli": cli},
		"launchd":      map[string]any{"domain": "gui/501", "service_user": "alice"},
		"capabilities": map[string]any{"component_digests": map[string]any{"agent-vmm-host": originalDigest}},
	}
	if err := writeJSON(configPath, config, 0o600); err != nil {
		t.Fatal(err)
	}
	exclusive, advisory, err := applyAgentVMMUpdate(runOptions{configPath: configPath}, config, map[string]any{
		"component": "agent-vmm-host", "release_id": "release-2",
		"artifact_url": "https://releases.example.test/Agent-VMM-Host.zip", "sha256": strings.Repeat("b", 64), "size": 42,
	})
	if err != nil || exclusive || stringValue(mapValue(advisory, "agent_vmm_update")["disposition"]) != "retry_same_request_at" {
		t.Fatalf("exclusive=%t advisory=%+v err=%v", exclusive, advisory, err)
	}
	persisted, loadErr := loadJSON(configPath)
	if loadErr != nil || stringValue(mapValue(mapValue(persisted, "capabilities"), "component_digests")["agent-vmm-host"]) != originalDigest {
		t.Fatalf("retry advisory changed persisted digest: config=%+v err=%v", persisted, loadErr)
	}
}

func TestLoginAgentUpdateProcessFailureBecomesBoundedAdvisory(t *testing.T) {
	root := t.TempDir()
	lifecycle := filepath.Join(root, "agent-vmm-lifecycle")
	cli := filepath.Join(root, "agent-vmm")
	writeExecutable(t, lifecycle, "#!/bin/sh\nprintf '%s\\n' '{\"component\":\"agent-vmm-host\",\"version\":\"release-1\",\"release_id\":\"release-1\"}'\n")
	writeExecutable(t, cli, "#!/bin/sh\nprintf '%s\\n' 'download failed before a JSON result' >&2\nexit 1\n")
	configPath := filepath.Join(root, "runner.json")
	config := map[string]any{
		"paths":        map[string]any{"host_runtime_lifecycle": lifecycle, "host_runtime_cli": cli},
		"launchd":      map[string]any{"domain": "gui/501", "service_user": "alice"},
		"capabilities": map[string]any{"component_digests": map[string]any{"agent-vmm-host": strings.Repeat("1", 64)}},
	}
	exclusive, advisory, err := applyAgentVMMUpdate(runOptions{configPath: configPath}, config, map[string]any{
		"component": "agent-vmm-host", "release_id": "release-2",
		"artifact_url": "https://releases.example.test/Agent-VMM-Host.zip", "sha256": strings.Repeat("b", 64), "size": 42,
	})
	if err != nil || exclusive || stringValue(advisory["failure_code"]) != "agent_vmm.update_result_invalid" || stringValue(mapValue(advisory, "agent_vmm_update")["disposition"]) != "terminal_action_required" {
		t.Fatalf("exclusive=%t advisory=%+v err=%v", exclusive, advisory, err)
	}
}

func TestBoundedCommandOutputConsumesButDoesNotBufferOverflow(t *testing.T) {
	output := &boundedOutputBuffer{limit: 4}
	written, err := output.Write([]byte("123456"))
	if err != nil || written != 6 || output.buffer.String() != "1234" || !output.overflow {
		t.Fatalf("written=%d output=%q overflow=%t err=%v", written, output.buffer.String(), output.overflow, err)
	}
}

func TestLoginAgentUpdateRejectsResultForDifferentRequest(t *testing.T) {
	root := t.TempDir()
	lifecycle := filepath.Join(root, "agent-vmm-lifecycle")
	cli := filepath.Join(root, "agent-vmm")
	writeExecutable(t, lifecycle, "#!/bin/sh\nprintf '%s\\n' '{\"component\":\"agent-vmm-host\",\"version\":\"release-1\",\"release_id\":\"release-1\"}'\n")
	writeExecutable(t, cli, "#!/bin/sh\nprintf '%s\\n' '{\"version\":1,\"command\":\"update\",\"state\":\"succeeded\",\"stage\":\"complete\",\"facts\":{\"target_release_id\":\"release-2\",\"request_id\":\"different-request\"}}'\n")
	configPath := filepath.Join(root, "runner.json")
	originalDigest := strings.Repeat("1", 64)
	config := map[string]any{
		"paths":        map[string]any{"host_runtime_lifecycle": lifecycle, "host_runtime_cli": cli},
		"launchd":      map[string]any{"domain": "gui/501", "service_user": "alice"},
		"capabilities": map[string]any{"component_digests": map[string]any{"agent-vmm-host": originalDigest}},
	}
	if err := writeJSON(configPath, config, 0o600); err != nil {
		t.Fatal(err)
	}
	exclusive, advisory, err := applyAgentVMMUpdate(runOptions{configPath: configPath}, config, map[string]any{
		"component": "agent-vmm-host", "release_id": "release-2",
		"artifact_url": "https://releases.example.test/Agent-VMM-Host.zip", "sha256": strings.Repeat("b", 64), "size": 42,
	})
	if err != nil || exclusive || stringValue(advisory["failure_code"]) != "agent_vmm.update_result_invalid" || stringValue(mapValue(advisory, "agent_vmm_update")["disposition"]) != "terminal_action_required" {
		t.Fatalf("exclusive=%t advisory=%+v err=%v", exclusive, advisory, err)
	}
	persisted, loadErr := loadJSON(configPath)
	if loadErr != nil || stringValue(mapValue(mapValue(persisted, "capabilities"), "component_digests")["agent-vmm-host"]) != originalDigest {
		t.Fatalf("unbound result changed persisted config=%+v err=%v", persisted, loadErr)
	}
}

func TestKeepRunningAfterControlErrorOnlyRetriesTransientFailures(t *testing.T) {
	opts := runOptions{loop: true}
	if keepRunningAfterControlError(opts, controlPlaneError{status: http.StatusUnauthorized}) {
		t.Fatal("permanent authorization failure was retried")
	}
	if !keepRunningAfterControlError(opts, controlPlaneError{status: http.StatusServiceUnavailable}) {
		t.Fatal("transient server failure was not retried")
	}
	if !keepRunningAfterControlError(opts, controlPlaneError{cause: errors.New("network unavailable")}) {
		t.Fatal("transport failure was not retried")
	}
}

func TestAgentVMMRegistrationControlsAreExactAndAdvanceOnlyAfterApply(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	script := `#!/bin/sh
set -eu
test "$1" = registration-state
test "$2" = --registration-id
test "$3" = registration-1
test "$4" = --state
test "$5" = draining
test "$6" = --request-id
test "$7" = operation-1-r3
test "$8" = --service-type
test "$9" = daemon
test "${10}" = --service-user
test -n "${11}"
printf '%s\n' '{"operationId":"local-control","outcome":"succeeded"}'
`
	if err := os.WriteFile(helper, []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	config := map[string]any{
		"paths":   map[string]any{"host_runtime_lifecycle": helper},
		"launchd": map[string]any{"domain": "system", "service_user": "bftvmm"},
	}
	statusPath := filepath.Join(root, "status.json")
	heartbeat := map[string]any{"agent_vmm_controls": map[string]any{
		"version": 1,
		"items": []any{map[string]any{
			"operation_id": "operation-1", "registration_id": "registration-1",
			"registration_revision": 3, "state": "draining",
		}},
		"next_cursor": "operation-1",
	}}
	if err := applyAgentVMMControls(runOptions{start: true}, config, statusPath, heartbeat); err != nil {
		t.Fatal(err)
	}
	if got := stringValue(config["_agent_vmm_control_cursor"]); got != "operation-1" {
		t.Fatalf("control cursor = %q", got)
	}
	status, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(status, []byte("agent_vmm_control_applied")) || bytes.Contains(status, []byte("one_time_secret")) {
		t.Fatalf("unexpected control status: %s", status)
	}

	if err := applyAgentVMMControls(runOptions{start: true}, config, statusPath, map[string]any{"agent_vmm_controls": map[string]any{"version": 1, "items": []any{}, "next_cursor": nil}}); err != nil {
		t.Fatal(err)
	}
	if _, exists := config["_agent_vmm_control_cursor"]; exists {
		t.Fatal("completed control page did not reset cursor")
	}
}

func TestEmptyAgentVMMControlsDoNotRequireAVMMHelper(t *testing.T) {
	config := map[string]any{}
	heartbeat := map[string]any{"agent_vmm_controls": map[string]any{
		"version": 1, "items": []any{}, "next_cursor": nil,
	}}

	if err := applyAgentVMMControls(runOptions{start: true}, config, filepath.Join(t.TempDir(), "status.json"), heartbeat); err != nil {
		t.Fatalf("empty control page failed without a VMM helper: %v", err)
	}
	if _, exists := config["_agent_vmm_control_cursor"]; exists {
		t.Fatal("empty control page retained a completed cursor")
	}
}

type bridgeCall struct {
	Method        string         `json:"method"`
	Path          string         `json:"path"`
	Authorization string         `json:"authorization,omitempty"`
	Payload       map[string]any `json:"payload,omitempty"`
}

type fakeBridge struct {
	server          *httptest.Server
	scenario        string
	secret          string
	mu              sync.Mutex
	calls           []bridgeCall
	statusCallbacks []map[string]any
	claimCount      int
}

func newFakeBridge(scenario string) *fakeBridge {
	bridge := &fakeBridge{scenario: scenario, secret: "salix_conn_worker_secret"}
	bridge.server = httptest.NewServer(http.HandlerFunc(bridge.handle))
	return bridge
}

func (b *fakeBridge) close() {
	b.server.Close()
}

func (b *fakeBridge) url() string {
	return b.server.URL
}

func (b *fakeBridge) handle(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet {
		b.record(bridgeCall{Method: r.Method, Path: r.URL.Path, Authorization: r.Header.Get("authorization")})
		if r.URL.Path == "/v1/orgs/org_test/runners/prov_1/provision-requests/req_1" {
			status := "waiting_for_attach"
			response := map[string]any{"id": "req_1", "status": status}
			if b.scenario == "claim_then_connected" {
				response["status"] = "connected"
				response["connector_run_id"] = "env_stale_request"
			}
			replyJSON(w, http.StatusOK, map[string]any{"provision_request": response})
			return
		}
		replyJSON(w, http.StatusNotFound, map[string]any{"error": "not_found"})
		return
	}

	var payload map[string]any
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&payload)
	}
	b.record(bridgeCall{Method: r.Method, Path: r.URL.Path, Authorization: r.Header.Get("authorization"), Payload: payload})

	switch r.URL.Path {
	case "/v1/orgs/org_test/runners":
		replyJSON(w, http.StatusCreated, map[string]any{
			"runner": map[string]any{
				"id":        "prov_1",
				"org_id":    "org_test",
				"stable_id": payload["stable_id"],
				"name":      payload["name"],
				"status":    "online",
			},
		})
	case "/v1/orgs/org_test/runners/prov_1/heartbeat":
		response := map[string]any{"runner": map[string]any{"id": "prov_1", "status": "online"}}
		replyJSON(w, http.StatusOK, response)
	case "/v1/orgs/org_test/runners/prov_1/claim":
		b.mu.Lock()
		b.claimCount++
		claimCount := b.claimCount
		scenario := b.scenario
		b.mu.Unlock()

		if scenario == "idle" || ((scenario == "claim_then_idle" || scenario == "claim_then_connected") && claimCount > 1) {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		if scenario == "claim_then_stop" && claimCount > 1 {
			replyJSON(w, http.StatusOK, map[string]any{
				"action": "stop",
				"device_request": map[string]any{
					"id":     "req_1",
					"status": "stopping",
					"name":   "prod-mac",
				},
				"connect": map[string]any{},
				"launch": map[string]any{
					"provision_request_id": "req_1",
					"connector_run_id":     "env_prod",
					"name":                 "prod-mac",
					"alias":                "prod",
				},
			})
			return
		}
		replyJSON(w, http.StatusOK, map[string]any{
			"action": "create",
			"device_request": map[string]any{
				"id":     "req_1",
				"status": "preflight",
				"name":   "prod-mac",
			},
			"connect": map[string]any{
				"token":  b.secret,
				"server": "ws://salix.example.test",
				"env": map[string]any{
					"SALIX_SERVER":          "ws://salix.example.test",
					"SALIX_CONNECTOR_TOKEN": b.secret,
				},
			},
			"launch": map[string]any{
				"name":  "prod-mac",
				"alias": "prod",
				"root":  "agents/bft_req_1",
			},
		})
	case "/v1/orgs/org_test/runners/prov_1/provision-requests/req_1/status":
		b.mu.Lock()
		b.statusCallbacks = append(b.statusCallbacks, payload)
		b.mu.Unlock()
		response := map[string]any{"id": "req_1"}
		for key, value := range payload {
			response[key] = value
		}
		replyJSON(w, http.StatusOK, map[string]any{"provision_request": response})
	default:
		replyJSON(w, http.StatusNotFound, map[string]any{"error": "not_found"})
	}
}

func (b *fakeBridge) record(call bridgeCall) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.calls = append(b.calls, call)
}

func (b *fakeBridge) snapshot() ([]bridgeCall, []map[string]any, int) {
	b.mu.Lock()
	defer b.mu.Unlock()
	calls := append([]bridgeCall(nil), b.calls...)
	callbacks := append([]map[string]any(nil), b.statusCallbacks...)
	return calls, callbacks, b.claimCount
}

func replyJSON(w http.ResponseWriter, status int, payload map[string]any) {
	raw, _ := json.Marshal(payload)
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write(raw)
}

func writeExecutable(t *testing.T, path string, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o755); err != nil {
		t.Fatal(err)
	}
}

func TestComponentBuildInfoRequiresStableReleaseIdentity(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	writeExecutable(t, helper, "#!/bin/sh\nprintf '{\"component\":\"agent-vmm-host\",\"version\":\"test\",\"release_id\":\"test\"}\\n'\n")

	digest := strings.Repeat("a", 64)
	config := map[string]any{
		"paths": map[string]any{"host_runtime_lifecycle": helper},
		"capabilities": map[string]any{
			"component_digests": map[string]any{"agent-vmm-host": digest},
		},
	}
	info, verified := componentBuildInfo(config, "agent-vmm")
	if !verified || info["version"] != "test" || info["release_id"] != "test" || info["artifact_digest"] != digest {
		t.Fatalf("stable release identity was not accepted: verified=%v info=%v", verified, info)
	}

	writeExecutable(t, helper, "#!/bin/sh\nprintf '{\"component\":\"agent-vmm-host\",\"version\":\"test\"}\\n'\n")
	if _, verified = componentBuildInfo(config, "agent-vmm"); verified {
		t.Fatal("version-only lifecycle output was accepted without release_id")
	}
}

func TestProvisionerCapabilitiesProjectAgentVMMRelease(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	writeExecutable(t, helper, "#!/bin/sh\nprintf '{\"component\":\"agent-vmm-host\",\"version\":\"comma-release-1\",\"release_id\":\"comma-release-1\"}\\n'\n")
	digest := strings.Repeat("c", 64)
	config := map[string]any{
		"paths": map[string]any{"host_runtime_lifecycle": helper},
		"capabilities": map[string]any{
			"component_digests": map[string]any{"agent-vmm-host": digest},
		},
	}
	capabilities := provisionerCapabilities(config)
	if got := mapValue(capabilities, "component_versions")["agent-vmm-host"]; got != "comma-release-1" {
		t.Fatalf("Agent VMM version = %v", got)
	}
	if got := mapValue(capabilities, "component_digests")["agent-vmm-host"]; got != digest {
		t.Fatalf("Agent VMM digest = %v", got)
	}
	if got := mapValue(mapValue(capabilities, "component_releases"), "agent-vmm-host")["release_id"]; got != "comma-release-1" {
		t.Fatalf("Agent VMM release = %v", got)
	}
}

func runProvisionerOutput(t *testing.T, bridge *fakeBridge, root string, extraArgs []string, configOverrides map[string]any, salixConnectOverride string) (int, string, string) {
	t.Helper()
	stateDir := filepath.Join(root, "state")
	workdir := filepath.Join(root, "work")
	binDir := filepath.Join(root, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	salixConnect := filepath.Join(binDir, "salix-connect")
	if salixConnectOverride != "" {
		salixConnect = salixConnectOverride
	}
	configPath := filepath.Join(root, "runner.json")
	config := map[string]any{
		"api_base_url": bridge.url(),
		"org_id":       "org_test",
		"runner_token": "bft_provisioner_secret",
		"runner":       map[string]any{"stable_id": "lab-mac-mini", "name": "Lab Mac mini"},
		"paths": map[string]any{
			"salix_connect": salixConnect,
			"workdir":       workdir,
			"state_dir":     stateDir,
		},
	}
	for key, value := range configOverrides {
		config[key] = value
	}
	raw, _ := json.Marshal(config)
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	args := []string{"run", "--config", configPath}
	if len(extraArgs) == 0 {
		args = append(args, "--once")
	} else {
		args = append(args, extraArgs...)
	}
	cmd := exec.Command("go", append([]string{"run", "."}, args...)...)
	cmd.Dir = "."
	var stdout bytes.Buffer
	var stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	exitCode := 0
	if err != nil {
		exitCode = 1
		var exitErr *exec.ExitError
		if errors.As(err, &exitErr) {
			exitCode = exitErr.ExitCode()
		}
	}
	return exitCode, stdout.String(), stderr.String()
}

func readStatus(t *testing.T, root string) map[string]any {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(root, "state", "runner-status.json"))
	if err != nil {
		t.Fatal(err)
	}
	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatal(err)
	}
	return payload
}

func jsonString(t *testing.T, value any) string {
	t.Helper()
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

func statuses(callbacks []map[string]any) []string {
	values := make([]string, 0, len(callbacks))
	for _, callback := range callbacks {
		values = append(values, callback["status"].(string))
	}
	return values
}

func paths(calls []bridgeCall) []string {
	values := make([]string, 0, len(calls))
	for _, call := range calls {
		values = append(values, call.Path)
	}
	return values
}

func TestDryRunClaimsRequestAndReportsPreflightComplete(t *testing.T) {
	bridge := newFakeBridge("claim")
	defer bridge.close()
	root := t.TempDir()
	writeExecutable(t, filepath.Join(root, "bin", "salix-connect"), "#!/bin/sh\nexit 0\n")

	code, stdout, stderr := runProvisionerOutput(t, bridge, root, nil, nil, "")
	if code != 0 {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if strings.Contains(stdout+stderr, bridge.secret) {
		t.Fatal("connector token leaked to process output")
	}
	calls, callbacks, _ := bridge.snapshot()
	allPaths := strings.Join(paths(calls), "\n")
	for _, want := range []string{
		"/v1/orgs/org_test/runners",
		"/v1/orgs/org_test/runners/prov_1/heartbeat",
		"/v1/orgs/org_test/runners/prov_1/claim",
	} {
		if !strings.Contains(allPaths, want) {
			t.Fatalf("missing call %s in %s", want, allPaths)
		}
	}
	if got := statuses(callbacks); strings.Join(got, ",") != "preflight_complete" {
		t.Fatalf("callbacks=%v", got)
	}
	progress := callbacks[len(callbacks)-1]["progress"].(map[string]any)
	if progress["stage"] != "preflight_complete" || progress["dry_run"] != true {
		t.Fatalf("bad progress: %#v", progress)
	}
	if _, err := os.Stat(filepath.Join(root, "work", "agents", "bft_req_1")); err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"Dry run passed", "Connector was not started", "stop/recreate the request"} {
		if !strings.Contains(stdout, want) {
			t.Fatalf("stdout missing %q:\n%s", want, stdout)
		}
	}
	status := readStatus(t, root)
	if status["status"] != "preflight_complete" || status["dry_run"] != true {
		t.Fatalf("bad status: %#v", status)
	}
	if strings.Contains(jsonString(t, status)+jsonString(t, callbacks), bridge.secret) {
		t.Fatal("connector token leaked to status payload")
	}
}

func TestIdleClaimWritesIdleStatus(t *testing.T) {
	bridge := newFakeBridge("idle")
	defer bridge.close()
	root := t.TempDir()
	writeExecutable(t, filepath.Join(root, "bin", "salix-connect"), "#!/bin/sh\nexit 0\n")

	code, stdout, stderr := runProvisionerOutput(t, bridge, root, nil, nil, "")
	if code != 0 {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if !strings.Contains(stdout, "Status: idle") || !strings.Contains(stdout, "No pending requests") {
		t.Fatalf("bad stdout:\n%s", stdout)
	}
	status := readStatus(t, root)
	if status["status"] != "idle" {
		t.Fatalf("bad status: %#v", status)
	}
	_, callbacks, _ := bridge.snapshot()
	if len(callbacks) != 0 {
		t.Fatalf("callbacks=%v", callbacks)
	}
}

func TestLoopClaimsAgainAfterIdleWithoutStartingConnector(t *testing.T) {
	bridge := newFakeBridge("idle")
	defer bridge.close()
	root := t.TempDir()
	writeExecutable(t, filepath.Join(root, "bin", "salix-connect"), "#!/bin/sh\nexit 0\n")

	code, _, stderr := runProvisionerOutput(t, bridge, root, []string{"--loop", "--interval", "0.01", "--max-iterations", "3"}, nil, "")
	if code != 0 {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	calls, callbacks, _ := bridge.snapshot()
	claimCount := 0
	heartbeatCount := 0
	for _, call := range calls {
		if call.Path == "/v1/orgs/org_test/runners/prov_1/claim" {
			claimCount++
		}
		if call.Path == "/v1/orgs/org_test/runners/prov_1/heartbeat" {
			heartbeatCount++
		}
	}
	if claimCount != 3 || heartbeatCount != 3 {
		t.Fatalf("claim=%d heartbeat=%d", claimCount, heartbeatCount)
	}
	if len(callbacks) != 0 {
		t.Fatalf("callbacks=%v", callbacks)
	}
}

func TestStartLoopRestartsConnectorAfterUnexpectedExitWithoutEchoingToken(t *testing.T) {
	bridge := newFakeBridge("claim_then_idle")
	defer bridge.close()
	root := t.TempDir()
	salixConnect := filepath.Join(root, "bin", "salix-connect")
	writeExecutable(t, salixConnect, `#!/bin/sh
if [ "$1" = "version" ]; then
  printf '{"version":"test"}\n'
  exit 0
fi
printf 'started\n' >> "$BFT_WORKDIR/started.log"
if [ "$(wc -l < "$BFT_WORKDIR/started.log" | tr -d ' ')" = "1" ]; then
  exit 7
fi
while true; do sleep 1; done
`)

	code, stdout, stderr := runProvisionerOutput(t, bridge, root, []string{"--start", "--loop", "--interval", "0.02", "--max-iterations", "10"}, nil, salixConnect)
	if code != 0 {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if !strings.Contains(stdout, "Status: running") || !strings.Contains(stdout, "managed connector is still running") {
		t.Fatalf("bad stdout:\n%s", stdout)
	}
	if strings.Contains(stdout+stderr, bridge.secret) {
		t.Fatal("connector token leaked")
	}
	_, callbacks, claimCount := bridge.snapshot()
	if claimCount < 1 {
		t.Fatal("expected claim")
	}
	want := "starting_connector,waiting_for_attach,starting_connector,waiting_for_attach"
	if got := strings.Join(statuses(callbacks), ","); got != want {
		t.Fatalf("callbacks=%s", got)
	}
	if callbacks[2]["restart_count"].(float64) != 1 || callbacks[2]["progress"].(map[string]any)["stage"] != "restarting_connector" {
		t.Fatalf("bad restart callback: %#v", callbacks[2])
	}
	started, err := os.ReadFile(filepath.Join(root, "work", "started.log"))
	if err != nil {
		t.Fatal(err)
	}
	if len(strings.Split(strings.TrimSpace(string(started)), "\n")) != 2 || strings.Contains(string(started), bridge.secret) {
		t.Fatalf("bad started log: %q", started)
	}
	status := readStatus(t, root)
	if strings.Contains(jsonString(t, status)+jsonString(t, callbacks), bridge.secret) {
		t.Fatal("connector token leaked to status")
	}
	managed := status["managed_connectors"].([]any)[0].(map[string]any)
	_ = syscall.Kill(int(managed["pid"].(float64)), syscall.SIGTERM)
}

func TestRejectedProvisionRequestStopsStaleConnectorAndReleasesCapacity(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/orgs/org_test/runners/runner-1/provision-requests/request-stale" {
			t.Fatalf("unexpected authority request: %s %s", r.Method, r.URL.Path)
		}
		replyJSON(w, http.StatusNotFound, map[string]any{"error": "provision_request_not_found"})
	}))
	defer server.Close()

	stateDir := t.TempDir()
	if err := os.MkdirAll(connectorConfigDir(stateDir), 0o700); err != nil {
		t.Fatal(err)
	}
	requestID := "request-stale"
	if err := os.WriteFile(connectorConfigPath(stateDir, requestID), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(connectorStatusPath(stateDir, requestID), []byte("{}"), 0o600); err != nil {
		t.Fatal(err)
	}
	connectors := map[string]*managedConnector{
		requestID: {requestID: requestID},
	}
	reporter := newStatusReporter(server.URL, "token", "org_test", "runner-1", time.Second)
	defer reporter.stop()
	if !reporter.verifyRequest(requestID) {
		t.Fatal("request authority check was not queued")
	}

	statusPath := filepath.Join(stateDir, "runner-status.json")
	deadline := time.Now().Add(time.Second)
	for connectors[requestID] != nil && time.Now().Before(deadline) {
		if err := reconcileRejectedManagedConnectors(reporter, map[string]any{}, stateDir, statusPath, "runner-1", connectors); err != nil {
			t.Fatal(err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	if connectors[requestID] != nil {
		t.Fatal("server-rejected connector still consumed local capacity")
	}
	for _, path := range []string{connectorConfigPath(stateDir, requestID), connectorStatusPath(stateDir, requestID)} {
		if _, err := os.Stat(path); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("stale connector credential was retained at %s: %v", path, err)
		}
	}
	rawStatus, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatal(err)
	}
	var status map[string]any
	if err := json.Unmarshal(rawStatus, &status); err != nil {
		t.Fatal(err)
	}
	if status["status"] != "stale_connector_removed" || len(status["managed_connectors"].([]any)) != 0 {
		t.Fatalf("unexpected stale connector status: %#v", status)
	}
}

func TestStartLoopReportsLocalConnectorStateWithoutEchoingToken(t *testing.T) {
	bridge := newFakeBridge("claim_then_connected")
	defer bridge.close()
	root := t.TempDir()
	salixConnect := filepath.Join(root, "bin", "salix-connect")
	writeExecutable(t, salixConnect, `#!/bin/sh
if [ "$1" = "version" ]; then
  printf '{"version":"test"}\n'
  exit 0
fi
printf 'started\n' >> "$BFT_WORKDIR/started.log"
config=""
while [ "$#" -gt 0 ]; do
  if [ "$1" = "--config" ]; then
    shift
    config="$1"
  fi
  shift
done
status_path="${config%.json}.status.json"
mkdir -p "$(dirname "$status_path")"
cat > "$status_path" <<'JSON'
{"state":"connected","connector_run_id":"env_prod"}
JSON
while true; do sleep 1; done
`)

	code, stdout, stderr := runProvisionerOutput(t, bridge, root, []string{"--start", "--loop", "--interval", "0.05", "--max-iterations", "20"}, nil, salixConnect)
	if code != 0 {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if !strings.Contains(stdout, "Status: connected") || !strings.Contains(stdout, "managed connector is attached") || strings.Contains(stdout, "Status: idle") {
		t.Fatalf("bad stdout:\n%s", stdout)
	}
	if strings.Contains(stdout+stderr, bridge.secret) {
		t.Fatal("connector token leaked")
	}
	calls, callbacks, _ := bridge.snapshot()
	verificationCount := 0
	for _, call := range calls {
		if call.Method == http.MethodGet {
			if call.Path != "/v1/orgs/org_test/runners/prov_1/provision-requests/req_1" {
				t.Fatalf("unexpected connector authority read: %s", call.Path)
			}
			verificationCount++
		}
	}
	if verificationCount != 1 {
		t.Fatalf("attach transition authority reads=%d, want 1", verificationCount)
	}
	if got := strings.Join(statuses(callbacks), ","); got != "starting_connector,waiting_for_attach" {
		t.Fatalf("callbacks=%s", got)
	}
	status := readStatus(t, root)
	if status["status"] != "connected" || status["progress"].(map[string]any)["stage"] != "connected" {
		t.Fatalf("bad status: %#v", status)
	}
	managed := status["managed_connectors"].([]any)[0].(map[string]any)
	if managed["attached"] != true || managed["connector_run_id"] != "env_prod" {
		t.Fatalf("bad managed connector: %#v", managed)
	}
	if strings.Contains(jsonString(t, calls)+jsonString(t, callbacks)+jsonString(t, status), bridge.secret) {
		t.Fatal("connector token leaked")
	}
	_ = syscall.Kill(int(managed["pid"].(float64)), syscall.SIGTERM)
}

func TestStartLoopHandlesStopActionWithoutEchoingToken(t *testing.T) {
	bridge := newFakeBridge("claim_then_stop")
	defer bridge.close()
	root := t.TempDir()
	salixConnect := filepath.Join(root, "bin", "salix-connect")
	writeExecutable(t, salixConnect, `#!/bin/sh
if [ "$1" = "version" ]; then
  printf '{"version":"test"}\n'
  exit 0
fi
printf 'started\n' >> "$BFT_WORKDIR/started.log"
while true; do sleep 1; done
`)

	code, stdout, stderr := runProvisionerOutput(t, bridge, root, []string{"--start", "--loop", "--interval", "0.05", "--max-iterations", "2"}, nil, salixConnect)
	if code != 0 {
		t.Fatalf("exit=%d stderr=%s", code, stderr)
	}
	if !strings.Contains(stdout, "device request req_1: stopped") || strings.Contains(stdout+stderr, bridge.secret) {
		t.Fatalf("bad output stdout=%s stderr=%s", stdout, stderr)
	}
	_, callbacks, _ := bridge.snapshot()
	if got := strings.Join(statuses(callbacks), ","); got != "starting_connector,waiting_for_attach,stopped" {
		t.Fatalf("callbacks=%s", got)
	}
	status := readStatus(t, root)
	if status["status"] != "stopped" || status["progress"].(map[string]any)["stage"] != "stopped" {
		t.Fatalf("bad status: %#v", status)
	}
	if status["stop"].(map[string]any)["managed"] != true {
		t.Fatalf("bad stop payload: %#v", status["stop"])
	}
	if status["progress"].(map[string]any)["cleanup"].(map[string]any)["mode"] != "preserve" {
		t.Fatalf("bad cleanup: %#v", status["progress"])
	}
	if _, err := os.Stat(filepath.Join(root, "work", "agents", "bft_req_1")); err != nil {
		t.Fatal(err)
	}
	if strings.Contains(jsonString(t, callbacks)+jsonString(t, status), bridge.secret) {
		t.Fatal("connector token leaked")
	}
}

func TestStartLoopCleanupPolicyRemovesManagedRootOnStop(t *testing.T) {
	bridge := newFakeBridge("claim_then_stop")
	defer bridge.close()
	root := t.TempDir()
	salixConnect := filepath.Join(root, "bin", "salix-connect")
	writeExecutable(t, salixConnect, `#!/bin/sh
if [ "$1" = "version" ]; then
  printf '{"version":"test"}\n'
  exit 0
fi
printf data > "$BFT_WORKDIR/agents/bft_req_1/owned.txt"
while true; do sleep 1; done
`)

	code, stdout, stderr := runProvisionerOutput(t, bridge, root, []string{"--start", "--loop", "--interval", "0.05", "--max-iterations", "2"}, map[string]any{"cleanup_policy": map[string]any{"mode": "remove_on_stop"}}, salixConnect)
	if code != 0 {
		t.Fatalf("exit=%d stdout=%s stderr=%s", code, stdout, stderr)
	}
	_, callbacks, _ := bridge.snapshot()
	stopped := callbacks[len(callbacks)-1]
	cleanup := stopped["progress"].(map[string]any)["cleanup"].(map[string]any)
	if stopped["status"] != "stopped" || cleanup["mode"] != "remove_on_stop" {
		t.Fatalf("bad stopped payload: %#v", stopped)
	}
	if !strings.Contains(jsonString(t, cleanup["removed"]), "root") {
		t.Fatalf("expected root cleanup: %#v", cleanup)
	}
	if _, err := os.Stat(filepath.Join(root, "work", "agents", "bft_req_1")); !os.IsNotExist(err) {
		t.Fatalf("managed root still exists: %v", err)
	}
	status := readStatus(t, root)
	if strings.Contains(jsonString(t, callbacks)+jsonString(t, status), bridge.secret) {
		t.Fatal("connector token leaked")
	}
}

func TestPreflightFailuresReportFailedStatusWithoutEchoingToken(t *testing.T) {
	tests := []struct {
		name        string
		setup       func(root string) string
		wantCode    string
		wantFailure string
	}{
		{
			name: "salix connect missing",
			setup: func(root string) string {
				return filepath.Join(root, "bin", "missing-salix-connect")
			},
			wantCode:    "preflight.salix_connect_not_executable",
			wantFailure: "preflight.salix_connect_not_executable",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			bridge := newFakeBridge("claim")
			defer bridge.close()
			root := t.TempDir()
			override := tt.setup(root)
			code, stdout, stderr := runProvisionerOutput(t, bridge, root, nil, nil, override)
			if code == 0 {
				t.Fatal("expected failure")
			}
			if !strings.Contains(stderr, tt.wantCode) || strings.Contains(stdout+stderr, bridge.secret) {
				t.Fatalf("bad output stdout=%s stderr=%s", stdout, stderr)
			}
			_, callbacks, _ := bridge.snapshot()
			if len(callbacks) != 1 {
				t.Fatalf("callbacks=%v", callbacks)
			}
			if callbacks[0]["status"] != "failed" || callbacks[0]["failure_code"] != tt.wantFailure {
				t.Fatalf("bad callback: %#v", callbacks[0])
			}
		})
	}
}

func TestStartFailureReportsFailedStatusWithoutEchoingToken(t *testing.T) {
	bridge := newFakeBridge("claim")
	defer bridge.close()
	root := t.TempDir()
	salixConnect := filepath.Join(root, "bin", "salix-connect")
	writeExecutable(t, salixConnect, "#!/missing/salix-interpreter\n")

	code, stdout, stderr := runProvisionerOutput(t, bridge, root, []string{"--once", "--start"}, nil, salixConnect)
	if code == 0 {
		t.Fatal("expected failure")
	}
	if !strings.Contains(stderr, "connector.start_failed") || strings.Contains(stdout+stderr, bridge.secret) {
		t.Fatalf("bad output stdout=%s stderr=%s", stdout, stderr)
	}
	_, callbacks, _ := bridge.snapshot()
	if got := strings.Join(statuses(callbacks), ","); got != "starting_connector,failed" {
		t.Fatalf("callbacks=%s", got)
	}
	failed := callbacks[len(callbacks)-1]
	if failed["failure_code"] != "connector.start_failed" || failed["progress"].(map[string]any)["stage"] != "connector_start_failed" {
		t.Fatalf("bad failed callback: %#v", failed)
	}
	status := readStatus(t, root)
	if status["status"] != "connector_start_failed" {
		t.Fatalf("bad status: %#v", status)
	}
}

func TestWorkdirPreflightFailureReportsFailedStatusWithoutEchoingToken(t *testing.T) {
	bridge := newFakeBridge("claim")
	defer bridge.close()
	root := t.TempDir()
	writeExecutable(t, filepath.Join(root, "bin", "salix-connect"), "#!/bin/sh\nexit 0\n")
	blockedWorkdir := filepath.Join(root, "not-a-directory")
	if err := os.WriteFile(blockedWorkdir, []byte("file blocks the runner workdir"), 0o644); err != nil {
		t.Fatal(err)
	}
	paths := map[string]any{
		"salix_connect": filepath.Join(root, "bin", "salix-connect"),
		"workdir":       blockedWorkdir,
		"state_dir":     filepath.Join(root, "state"),
	}

	code, stdout, stderr := runProvisionerOutput(t, bridge, root, nil, map[string]any{"paths": paths}, "")
	if code == 0 {
		t.Fatal("expected failure")
	}
	if !strings.Contains(stderr, "preflight.workdir_not_ready") || strings.Contains(stdout+stderr, bridge.secret) {
		t.Fatalf("bad output stdout=%s stderr=%s", stdout, stderr)
	}
	_, callbacks, _ := bridge.snapshot()
	if callbacks[0]["failure_code"] != "preflight.workdir_not_ready" {
		t.Fatalf("bad callback: %#v", callbacks[0])
	}
	status := readStatus(t, root)
	if status["status"] != "preflight_failed" || status["failure_code"] != "preflight.workdir_not_ready" {
		t.Fatalf("bad status: %#v", status)
	}
}

func TestDoctorAndStatusCommandsDoNotEchoToken(t *testing.T) {
	bridge := newFakeBridge("idle")
	defer bridge.close()
	root := t.TempDir()
	writeExecutable(t, filepath.Join(root, "bin", "salix-connect"), "#!/bin/sh\nexit 0\n")
	code, _, stderr := runProvisionerOutput(t, bridge, root, nil, nil, "")
	if code != 0 {
		t.Fatalf("setup failed: %s", stderr)
	}

	configPath := filepath.Join(root, "runner.json")
	config, err := loadJSON(configPath)
	if err != nil {
		t.Fatal(err)
	}
	lifecycle := filepath.Join(root, "bin", "agent-vmm-lifecycle")
	cli := filepath.Join(root, "bin", "agent-vmm")
	writeExecutable(t, lifecycle, "#!/bin/sh\nexit 0\n")
	writeExecutable(t, cli, "#!/bin/sh\nprintf '%s\\n' '{\"version\":1,\"state\":\"healthy\",\"freshness\":\"current\",\"partial\":false}'\n")
	paths := mapValue(config, "paths")
	paths["host_runtime_lifecycle"] = lifecycle
	paths["host_runtime_cli"] = cli
	config["launchd"] = map[string]any{"domain": "gui/501", "service_user": "runner"}
	if err := writeJSON(configPath, config, 0o600); err != nil {
		t.Fatal(err)
	}
	for _, command := range []string{"doctor", "status"} {
		cmd := exec.Command("go", "run", ".", command, "--config", configPath)
		var stdout bytes.Buffer
		var stderr bytes.Buffer
		cmd.Stdout = &stdout
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			t.Fatalf("%s failed: %v stderr=%s", command, err, stderr.String())
		}
		output := stdout.String() + stderr.String()
		if strings.Contains(output, "bft_provisioner_secret") || strings.Contains(output, bridge.secret) {
			t.Fatalf("%s leaked token: %s", command, output)
		}
		if !strings.Contains(output, "BridgeForTeams runner") {
			t.Fatalf("%s missing heading: %s", command, output)
		}
		if command == "doctor" {
			for _, want := range []string{
				"Fallback tooling (required only",
				"- jq:",
				"- pandoc:",
				"- pdftotext:",
				"- LibreOffice:",
				"- ffmpeg:",
				"- 7z:",
			} {
				if !strings.Contains(output, want) {
					t.Fatalf("doctor missing %q: %s", want, output)
				}
			}
		}
	}
}

type fakeFallbackExecutor struct {
	paths map[string]string
	calls []fallbackCommand
	run   func(string, []string) ([]byte, error)
}

func (f *fakeFallbackExecutor) LookPath(name string) (string, error) {
	if path := f.paths[name]; path != "" {
		return path, nil
	}
	return "", exec.ErrNotFound
}

func (f *fakeFallbackExecutor) Run(_ context.Context, name string, args ...string) ([]byte, error) {
	f.calls = append(f.calls, fallbackCommand{tool: name, args: append([]string(nil), args...)})
	return f.run(name, args)
}

func TestPreprocessInvokesJQAndWritesResult(t *testing.T) {
	root := t.TempDir()
	input := filepath.Join(root, "input.json")
	output := filepath.Join(root, "output.json")
	if err := os.WriteFile(input, []byte(`{"answer":42}`), 0o600); err != nil {
		t.Fatal(err)
	}

	fake := &fakeFallbackExecutor{
		paths: map[string]string{"jq": "/tools/jq"},
		run: func(_ string, _ []string) ([]byte, error) {
			return []byte("{\n  \"answer\": 42\n}\n"), nil
		},
	}
	if err := runPreprocess(preprocessOptions{input: input, output: output, timeout: time.Second}, fake); err != nil {
		t.Fatal(err)
	}
	if len(fake.calls) != 1 || fake.calls[0].tool != "/tools/jq" {
		t.Fatalf("expected jq invocation, got %#v", fake.calls)
	}
	got, err := os.ReadFile(output)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(got), `"answer": 42`) {
		t.Fatalf("unexpected fallback output: %s", got)
	}
}

func TestPreprocessInvokesImageMagickForUnsupportedImage(t *testing.T) {
	root := t.TempDir()
	input := filepath.Join(root, "input.heic")
	output := filepath.Join(root, "output.png")
	if err := os.WriteFile(input, []byte("heic"), 0o600); err != nil {
		t.Fatal(err)
	}

	fake := &fakeFallbackExecutor{
		paths: map[string]string{"magick": "/tools/magick"},
		run: func(_ string, args []string) ([]byte, error) {
			if len(args) != 2 || args[0] != input+"[0]" || args[1] != output {
				t.Fatalf("unexpected ImageMagick args: %#v", args)
			}
			return nil, os.WriteFile(output, []byte("png"), 0o600)
		},
	}
	if err := runPreprocess(preprocessOptions{input: input, output: output, timeout: time.Second}, fake); err != nil {
		t.Fatal(err)
	}
	if len(fake.calls) != 1 || fake.calls[0].tool != "/tools/magick" {
		t.Fatalf("expected ImageMagick invocation, got %#v", fake.calls)
	}
}

func TestPreprocessInvokesPDFText(t *testing.T) {
	root := t.TempDir()
	input := filepath.Join(root, "report.pdf")
	output := filepath.Join(root, "report.txt")
	if err := os.WriteFile(input, []byte("%PDF"), 0o600); err != nil {
		t.Fatal(err)
	}

	fake := &fakeFallbackExecutor{
		paths: map[string]string{"pdftotext": "/tools/pdftotext"},
		run: func(_ string, args []string) ([]byte, error) {
			if len(args) != 2 || args[0] != input || args[1] != output {
				t.Fatalf("unexpected pdftotext args: %#v", args)
			}
			return nil, os.WriteFile(output, []byte("extracted text"), 0o600)
		},
	}
	if err := runPreprocess(preprocessOptions{input: input, output: output, timeout: time.Second}, fake); err != nil {
		t.Fatal(err)
	}
	if len(fake.calls) != 1 || fake.calls[0].tool != "/tools/pdftotext" {
		t.Fatalf("expected pdftotext invocation, got %#v", fake.calls)
	}
}

func TestPreprocessInvokesLibreOfficeForOfficeFormats(t *testing.T) {
	for _, extension := range []string{".xls", ".xlsx", ".ppt", ".pptx"} {
		t.Run(extension, func(t *testing.T) {
			root := t.TempDir()
			input := filepath.Join(root, "input"+extension)
			output := filepath.Join(root, "converted")
			if err := os.WriteFile(input, []byte("office"), 0o600); err != nil {
				t.Fatal(err)
			}

			fake := &fakeFallbackExecutor{
				paths: map[string]string{"libreoffice": "/tools/libreoffice"},
				run: func(_ string, args []string) ([]byte, error) {
					if len(args) != 6 || args[0] != "--headless" || args[1] != "--convert-to" ||
						args[2] != "html" || args[3] != "--outdir" || args[4] != output || args[5] != input {
						t.Fatalf("unexpected LibreOffice args: %#v", args)
					}
					return nil, os.WriteFile(filepath.Join(output, "input.html"), []byte("<html>content</html>"), 0o600)
				},
			}
			if err := runPreprocess(preprocessOptions{input: input, output: output, timeout: time.Second}, fake); err != nil {
				t.Fatal(err)
			}
			if len(fake.calls) != 1 || fake.calls[0].tool != "/tools/libreoffice" {
				t.Fatalf("expected LibreOffice invocation, got %#v", fake.calls)
			}
		})
	}
}

func TestPreprocessFailsExplicitlyForUnsupportedFormat(t *testing.T) {
	root := t.TempDir()
	input := filepath.Join(root, "blob.bin")
	if err := os.WriteFile(input, []byte("unknown"), 0o600); err != nil {
		t.Fatal(err)
	}
	err := runPreprocess(
		preprocessOptions{input: input, output: filepath.Join(root, "out.txt"), timeout: time.Second},
		&fakeFallbackExecutor{},
	)
	var pe provisionerError
	if !errors.As(err, &pe) || pe.code != "preprocess.unsupported_format" {
		t.Fatalf("expected explicit unsupported format, got %#v", err)
	}
}

func TestPreprocessFailsExplicitlyWhenToolMissing(t *testing.T) {
	root := t.TempDir()
	input := filepath.Join(root, "input.json")
	if err := os.WriteFile(input, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	err := runPreprocess(
		preprocessOptions{input: input, output: filepath.Join(root, "out.json"), timeout: time.Second},
		&fakeFallbackExecutor{paths: map[string]string{}},
	)
	var pe provisionerError
	if !errors.As(err, &pe) || pe.code != "preprocess.tool_missing" {
		t.Fatalf("expected explicit missing tool, got %#v", err)
	}
}

func TestSystemServiceMutationsRequireDirectProtectedExecutor(t *testing.T) {
	service := serviceConfig{domain: "system", label: "com.bridgeforteams.runner"}
	for _, action := range []string{"start", "stop", "remove"} {
		for _, euid := range []int{0, 502} {
			err := validateServicePermission(service, action, euid)
			var pe provisionerError
			if !errors.As(err, &pe) || pe.code != "service.system_administrator_action_required" || !strings.Contains(pe.message, "/Library/PrivilegedHelperTools/agent-vmm-service-executor "+action+" --job runner") {
				t.Fatalf("%s euid=%d: expected protected-executor action, got %#v", action, euid, err)
			}
		}
	}
	if err := validateServicePermission(service, "status", 502); err != nil {
		t.Fatalf("status must remain readable without administrator access: %v", err)
	}
}

func TestSystemServiceRejectsConfigSelectedJob(t *testing.T) {
	if err := validateFixedSystemService(serviceConfig{domain: "system", label: "com.example.forged", sourcePlist: "/tmp/forged.plist", installPlist: "/Library/LaunchDaemons/forged.plist"}); err == nil || !strings.Contains(err.Error(), "fixed BFT runner job") {
		t.Fatalf("forged system target err=%v", err)
	}
	if err := validateFixedSystemService(serviceConfig{domain: "system", label: "com.bridgeforteams.runner"}); err != nil {
		t.Fatal(err)
	}
}

func TestBuildLaunchResolvesConnectorRootUnderWorkdir(t *testing.T) {
	root := t.TempDir()
	salixConnect := filepath.Join(root, "bin", "salix-connect")
	writeExecutable(t, salixConnect, "#!/bin/sh\nexit 0\n")
	workdir := filepath.Join(root, "existing-work")
	want := filepath.Join(workdir, "agents", "bft_req_1")
	if err := os.MkdirAll(want, 0o700); err != nil {
		t.Fatal(err)
	}
	ownedFile := filepath.Join(want, "user.txt")
	if err := os.WriteFile(ownedFile, []byte("preserved"), 0o600); err != nil {
		t.Fatal(err)
	}
	config := map[string]any{"paths": map[string]any{
		"salix_connect": salixConnect, "workdir": workdir, "state_dir": filepath.Join(root, "state"),
	}}
	launch := map[string]any{"name": "prod-mac", "alias": "prod", "root": "agents/bft_req_1"}
	connect := map[string]any{"server": "ws://salix.example.test", "token": "secret"}
	plan, err := buildLaunch(config, connect, launch, filepath.Join(root, "state"), "req_1")
	if err != nil {
		t.Fatal(err)
	}
	if plan.root != want {
		t.Fatalf("root = %q, want %q", plan.root, want)
	}
	connector := mapValue(plan.config, "connector")
	if connector["root"] != want || connector["name"] != "prod-mac" || connector["alias"] != "prod" {
		t.Fatalf("connector config = %#v", connector)
	}
	if data, err := os.ReadFile(ownedFile); err != nil || string(data) != "preserved" {
		t.Fatalf("existing workspace file changed: %q, %v", data, err)
	}
}

func TestBuildLaunchDefaultsConnectorRootFromRequestID(t *testing.T) {
	root := t.TempDir()
	salixConnect := filepath.Join(root, "bin", "salix-connect")
	writeExecutable(t, salixConnect, "#!/bin/sh\nexit 0\n")
	config := map[string]any{"paths": map[string]any{"salix_connect": salixConnect, "workdir": filepath.Join(root, "work"), "state_dir": filepath.Join(root, "state")}}
	connect := map[string]any{"server": "ws://salix.example.test", "token": "secret"}

	plan, err := buildLaunch(config, connect, map[string]any{"name": "prod-mac"}, filepath.Join(root, "state"), "3f2c-req")
	if err != nil {
		t.Fatalf("buildLaunch: %v", err)
	}
	if want := filepath.Join(root, "work", "agents", "bft_3f2c_req"); plan.root != want {
		t.Fatalf("root = %q, want %q", plan.root, want)
	}
}
