package main

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestRegistrationClaimRetainsSameRequestAfterUnknownResult(t *testing.T) {
	directory := t.TempDir()
	helper := filepath.Join(directory, "lifecycle")
	writeExecutable(t, helper, `#!/bin/sh
set -eu
test "$1" = registration-claim
test "$4" = native-request
test "$5" = --descriptor-stdin
payload=$(cat)
case "$payload" in *ticket*secret-ticket*) ;; *) exit 8 ;; esac
if [ ! -e "`+directory+`/accepted" ]; then
 : > "`+directory+`/accepted"
 printf '%s\n' '{"requestId":"native-request","targetRegistrationId":"registration","outcome":"failed","retryable":true}'
 exit 1
fi
printf '%s\n' '{"operationId":"native-receipt","requestId":"native-request","targetRegistrationId":"registration","outcome":"succeeded"}'
`)
	heartbeat := map[string]any{"agent_vmm_registration": map[string]any{"version": 1, "registration_id": "registration", "request_id": "native-request", "claim_url": "https://api.example.test/v1/compute/agent-vmm/registrations/claim", "ticket": "secret-ticket", "expires_at": "2099-01-01T00:00:00Z"}}
	config := testAgentVMMConfig(helper)
	status := filepath.Join(directory, "status.json")
	if err := applyAgentVMMRegistrationDescriptor(runOptions{start: true}, config, directory, status, heartbeat); err == nil {
		t.Fatal("unknown result unexpectedly succeeded")
	}
	if _, err := os.Stat(agentVMMRegistrationDescriptorPath(directory, "registration")); err != nil {
		t.Fatal(err)
	}
	if err := applyAgentVMMRegistrationDescriptor(runOptions{start: true}, config, directory, status, map[string]any{}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(agentVMMRegistrationDescriptorPath(directory, "registration")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("completed descriptor retained: %v", err)
	}
	raw, err := os.ReadFile(status)
	if err != nil || bytes.Contains(raw, []byte("secret-ticket")) {
		t.Fatalf("status leaked ticket: %s %v", raw, err)
	}
}
func TestRegistrationFailureAcknowledgementDoesNotMutateNativePlan(t *testing.T) {
	directory := t.TempDir()
	helper := filepath.Join(directory, "lifecycle")
	writeExecutable(t, helper, "#!/bin/sh\nexit 99\n")
	report := map[string]any{"registration_id": "registration", "failure_code": "agent_vmm.local_disposed"}
	if err := writeJSON(agentVMMRegistrationFailurePath(directory, "registration"), report, 0600); err != nil {
		t.Fatal(err)
	}
	if err := acknowledgeAgentVMMRegistrationFailures(testAgentVMMConfig(helper), directory, map[string]any{"agent_vmm_registration_failure_acks": []any{"registration"}}); err != nil {
		t.Fatal(err)
	}
	if reports, err := agentVMMRegistrationFailureReports(directory); err != nil || len(reports) != 0 {
		t.Fatalf("reports=%v err=%v", reports, err)
	}
}
