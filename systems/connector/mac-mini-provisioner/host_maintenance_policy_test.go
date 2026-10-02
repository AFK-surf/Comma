package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestHostMaintenancePolicySurvivesAbsentOrOldHelper(t *testing.T) {
	home := t.TempDir()
	helper := filepath.Join(home, "Library", "Application Support", "Agent VMM Host", "current", "Agent VMM Host.app", "Contents", "Helpers", "agent-vmm-lifecycle")
	policy := filepath.Join(home, "Library", "Application Support", "Agent VMM Maintenance", "state.json")
	if err := checkHostMaintenancePolicy(helper, "old-install"); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(policy), 0700); err != nil {
		t.Fatal(err)
	}
	for _, test := range []struct{ data, operation, code string }{
		{`{"version":1,"uninstalled":true}`, "new", "agent_vmm.maintenance_required"},
		{`{"version":1,"uninstalled":false,"activeRequest":"maintenance-1"}`, "new", "agent_vmm.maintenance_required"},
		{`{"version":1,"uninstalled":false,"blockedInstalls":{"old-install":true}}`, "old-install", "agent_vmm.local_disposed"},
		{`{"version":1,"uninstalled":false,"blockedInstalls":{"old-install":true}}`, "new-install", ""},
		{`{"version":2,"uninstalled":false}`, "new", "agent_vmm.maintenance_unreadable"},
		{`{"version":1}`, "new", "agent_vmm.maintenance_unreadable"},
		{`{`, "new", "agent_vmm.maintenance_unreadable"},
	} {
		if err := os.WriteFile(policy, []byte(test.data), 0600); err != nil {
			t.Fatal(err)
		}
		err := checkHostMaintenancePolicy(helper, test.operation)
		if test.code == "" {
			if err != nil {
				t.Fatal(err)
			}
			continue
		}
		if err == nil || provisionerFailureCode(err, "unknown") != test.code {
			t.Fatalf("policy %s returned %v, expected %s", test.data, err, test.code)
		}
	}
}
