package main

import (
	"bytes"
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
	update["component"] = "computer-use-helper"
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

func TestWorkerContinuesIndependentWorkAfterManagedInstallFailure(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "agent-vmm-lifecycle")
	controlApplied := filepath.Join(root, "control-applied")
	writeExecutable(t, helper, `#!/bin/sh
if [ "$1" = registration-enable ]; then
  : > `+strconv.Quote(controlApplied)+`
  printf '{"requestId":"%s","outcome":"succeeded"}\n' "$5"
  exit 0
fi
printf '%s\n' '{"operationId":"operation-1","outcome":"failed","attempt":1,"failureStage":"appliance-install","failureCode":"upstream_unavailable","failureMessage":"temporary","retryable":true}'
exit 9
`)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if strings.HasSuffix(request.URL.Path, "/heartbeat") {
			replyJSON(w, http.StatusOK, map[string]any{
				"agent_vmm_registration": map[string]any{
					"version": 1, "registration_id": "registration-1", "request_id": "operation-1", "claim_url": "https://example.test/exchange",
					"ticket": "secret-value", "expires_at": "2099-01-01T00:00:00Z",
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
	statusPath := filepath.Join(root, "status.json")
	if err := runWorkerIteration(runOptions{start: true, timeout: time.Second}, testAgentVMMConfig(helper), stateDir,
		statusPath, server.URL, "token", "org", "runner"); err != nil {
		t.Fatalf("iteration failed after local install failure: %v", err)
	}
	if status, err := os.ReadFile(statusPath); err != nil || !bytes.Contains(status, []byte(`"status":"online"`)) {
		t.Fatalf("managed install failure blocked the iteration status: status=%s err=%v", status, err)
	}
	if _, err := os.Stat(controlApplied); err != nil {
		t.Fatalf("managed install failure blocked independent control work: %v", err)
	}
	if _, err := os.Stat(agentVMMRegistrationDescriptorPath(stateDir, "registration-1")); err != nil {
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
test "$1" = registration-claim
payload=$(cat)
case "$payload" in *ticket*secret-value*) ;; *) exit 8 ;; esac
: > "`+applied+`"
printf '%s\n' '{"operationId":"native-receipt","requestId":"operation-1","targetRegistrationId":"registration-1","outcome":"succeeded"}'
`)

	var heartbeats atomic.Int32
	artifactServer := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_, _ = io.WriteString(w, "not trusted by the release client")
	}))
	defer artifactServer.Close()
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, request *http.Request) {
		if !strings.HasSuffix(request.URL.Path, "/heartbeat") {
			replyJSON(w, http.StatusNotFound, map[string]any{"error": "not_found"})
			return
		}
		heartbeats.Add(1)
		response := map[string]any{
			"agent_vmm_registration": map[string]any{
				"version": 1, "registration_id": "registration-1", "request_id": "operation-1",
				"claim_url": "https://example.test/exchange",
				"ticket":    "secret-value", "expires_at": "2099-01-01T00:00:00Z",
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

	if err := runWorkerIteration(opts, config, stateDir, statusPath, server.URL, "token", "org", "runner"); err != nil {
		t.Fatalf("first iteration failed: %v", err)
	}
	pendingPath := agentVMMRegistrationDescriptorPath(stateDir, "registration-1")
	if heartbeats.Load() != 1 {
		t.Fatalf("first iteration heartbeat count = %d, want 1", heartbeats.Load())
	}
	if _, err := os.Stat(applied); err != nil {
		t.Fatalf("operator-owned system update blocked the managed install: %v", err)
	}
	if _, err := os.Stat(pendingPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("completed descriptor was retained: %v", err)
	}
	if status, err := os.ReadFile(statusPath); err != nil || bytes.Contains(status, []byte("secret-value")) || !bytes.Contains(status, []byte(`"status":"online"`)) || !bytes.Contains(status, []byte(`"agent_vmm_update":{"failure_code":"agent_vmm.administrator_update_required"`)) {
		t.Fatalf("managed install/update status=%s err=%v", status, err)
	}

	if err := runWorkerIteration(opts, config, stateDir, statusPath, server.URL, "token", "org", "runner"); err != nil {
		t.Fatalf("pending install iteration failed: %v", err)
	}
	if heartbeats.Load() != 2 {
		t.Fatalf("pending install did not continue heartbeat: heartbeat count = %d", heartbeats.Load())
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
test "$1" = registration-drain
test "$2" = --registration-id
test "$3" = registration-1
test "$4" = --request-id
test "$5" = registration-registration-1-r3-draining
test "$6" = --service-type
test "$7" = daemon
test "$8" = --service-user
test -n "$9"
printf '{"requestId":"%s","operationId":"native-control","outcome":"succeeded"}\n' "$5"
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
	if err := applyAgentVMMControls(runOptions{start: true}, config, root, statusPath, heartbeat); err != nil {
		t.Fatal(err)
	}
	if got := stringValue(config["_agent_vmm_control_cursor"]); got != "operation-1" {
		t.Fatalf("control cursor = %q", got)
	}
	status, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(status, []byte("agent_vmm_control_applied")) || bytes.Contains(status, []byte("ticket")) {
		t.Fatalf("unexpected control status: %s", status)
	}

	if err := applyAgentVMMControls(runOptions{start: true}, config, root, statusPath, map[string]any{"agent_vmm_controls": map[string]any{"version": 1, "items": []any{}, "next_cursor": nil}}); err != nil {
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

	if err := applyAgentVMMControls(runOptions{start: true}, config, t.TempDir(), filepath.Join(t.TempDir(), "status.json"), heartbeat); err != nil {
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
	server *httptest.Server
	mu     sync.Mutex
	calls  []bridgeCall
}

func newFakeBridge() *fakeBridge {
	bridge := &fakeBridge{}
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
		replyJSON(w, http.StatusOK, map[string]any{"runner": map[string]any{"id": "prov_1", "status": "online"}})
	default:
		replyJSON(w, http.StatusNotFound, map[string]any{"error": "not_found"})
	}
}

func (b *fakeBridge) snapshot() []bridgeCall {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]bridgeCall(nil), b.calls...)
}

func (b *fakeBridge) record(call bridgeCall) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.calls = append(b.calls, call)
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

func TestAgentVMMReleaseRequiresStableReleaseIdentity(t *testing.T) {
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
	info, verified := agentVMMRelease(config)
	if !verified || info["version"] != "test" || info["release_id"] != "test" || info["artifact_digest"] != digest {
		t.Fatalf("stable release identity was not accepted: verified=%v info=%v", verified, info)
	}

	writeExecutable(t, helper, "#!/bin/sh\nprintf '{\"component\":\"agent-vmm-host\",\"version\":\"test\"}\\n'\n")
	if _, verified = agentVMMRelease(config); verified {
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

func runProvisionerOutput(t *testing.T, bridge *fakeBridge, root string) (int, string, string) {
	t.Helper()
	configPath := filepath.Join(root, "runner.json")
	config := map[string]any{
		"api_base_url": bridge.url(),
		"org_id":       "org_test",
		"runner_token": "bft_provisioner_secret",
		"runner":       map[string]any{"stable_id": "lab-mac-mini", "name": "Lab Mac mini"},
		"paths":        map[string]any{"state_dir": filepath.Join(root, "state")},
	}
	raw, _ := json.Marshal(config)
	if err := os.WriteFile(configPath, raw, 0o600); err != nil {
		t.Fatal(err)
	}

	cmd := exec.Command("go", "run", ".", "dry-run")
	cmd.Env = append(os.Environ(), "BFT_CONFIG_PATH="+configPath)
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

func TestDryRunRegistersAndHeartbeatsOnly(t *testing.T) {
	bridge := newFakeBridge()
	defer bridge.close()
	root := t.TempDir()
	code, stdout, stderr := runProvisionerOutput(t, bridge, root)
	if code != 0 {
		t.Fatalf("dry run failed: %s", stderr)
	}
	want := []string{"/v1/orgs/org_test/runners", "/v1/orgs/org_test/runners/prov_1/heartbeat"}
	if got := paths(bridge.snapshot()); !slices.Equal(got, want) {
		t.Fatalf("dry run calls = %v, want %v", got, want)
	}
	if strings.Contains(stdout+stderr, "bft_provisioner_secret") {
		t.Fatalf("dry run leaked token: %s%s", stdout, stderr)
	}
	status, err := loadJSON(filepath.Join(root, "state", "runner-status.json"))
	if err != nil || status["status"] != "online" || status["provisioner_id"] != "prov_1" {
		t.Fatalf("dry run status = %v, err = %v", status, err)
	}
}

func paths(calls []bridgeCall) []string {
	values := make([]string, 0, len(calls))
	for _, call := range calls {
		values = append(values, call.Path)
	}
	return values
}

func TestDoctorAndStatusCommandsDoNotEchoToken(t *testing.T) {
	bridge := newFakeBridge()
	defer bridge.close()
	root := t.TempDir()
	code, _, stderr := runProvisionerOutput(t, bridge, root)
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
		if strings.Contains(output, "bft_provisioner_secret") {
			t.Fatalf("%s leaked token: %s", command, output)
		}
		if !strings.Contains(output, "BridgeForTeams runner") {
			t.Fatalf("%s missing heading: %s", command, output)
		}
	}
}

func TestSystemServiceMutationsRequireDirectProtectedExecutor(t *testing.T) {
	service := serviceConfig{domain: "system", label: "com.bridgeforteams.runner"}
	for _, action := range []string{"start", "stop", "remove"} {
		for _, euid := range []int{0, 502} {
			err := validateServicePermission(service, action, euid)
			var pe provisionerError
			if !errors.As(err, &pe) || pe.code != "service.system_administrator_action_required" || !strings.Contains(pe.message, "/Library/PrivilegedHelperTools/bft-runner-service-executor "+action) {
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

func TestLocallyDisposedControlReportsOnceAndOtherRegistrationStillApplies(t *testing.T) {
	root := t.TempDir()
	helper := filepath.Join(root, "lifecycle")
	calls := filepath.Join(root, "calls")
	writeExecutable(t, helper, `#!/bin/sh
printf '%s\n' "$3" >> "`+calls+`"
if [ "$3" = registration-A ]; then
printf '%s\n' '{"requestId":"registration-registration-A-r3-enabled","failureCode":"local_disposed","retryable":false,"outcome":"failed"}'
exit 1
fi
printf '{"requestId":"%s","outcome":"succeeded"}\n' "$5"
`)
	config := testAgentVMMConfig(helper)
	heartbeat := map[string]any{"agent_vmm_controls": map[string]any{"version": 1, "items": []any{
		map[string]any{"operation_id": "operation-A", "registration_id": "registration-A", "registration_revision": 3, "state": "enabled"},
		map[string]any{"operation_id": "operation-B", "registration_id": "registration-B", "registration_revision": 3, "state": "enabled"},
	}, "next_cursor": "operation-B"}}
	for attempt := 0; attempt < 2; attempt++ {
		if err := applyAgentVMMControls(runOptions{start: true}, config, root, filepath.Join(root, "status.json"), heartbeat); err != nil {
			t.Fatal(err)
		}
	}
	result, err := os.ReadFile(calls)
	if err != nil {
		t.Fatal(err)
	}
	if string(result) != "registration-A\nregistration-B\nregistration-A\nregistration-B\n" {
		t.Fatalf("controls=%s", result)
	}
	reports, err := agentVMMRegistrationFailureReports(root)
	if err != nil || len(reports) != 1 || stringValue(mapFromValue(reports[0])["failure_code"]) != "agent_vmm.local_disposed" {
		t.Fatalf("reports=%v err=%v", reports, err)
	}
	if stringValue(config["_agent_vmm_control_cursor"]) != "operation-B" {
		t.Fatal("terminal A blocked B page advancement")
	}
}
