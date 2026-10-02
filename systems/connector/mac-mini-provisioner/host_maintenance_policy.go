package main

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

// This is the lifecycle owner's local negative fact, not a BFT grant. Check it
// before invoking even an older helper. The current helper also serializes its
// mutation against maintenance; this preflight does not replace that lock.
func checkHostMaintenancePolicy(lifecycle, operationID string) error {
	suffix := filepath.Join("Library", "Application Support", "Agent VMM Host", "current", "Agent VMM Host.app", "Contents", "Helpers", "agent-vmm-lifecycle")
	clean := filepath.Clean(lifecycle)
	if !strings.HasSuffix(clean, string(os.PathSeparator)+suffix) {
		// Explicit test/development helpers are outside the shared installation.
		return nil
	}
	home := strings.TrimSuffix(clean, string(os.PathSeparator)+suffix)
	return readHostMaintenancePolicy(filepath.Join(home, "Library", "Application Support", "Agent VMM Maintenance", "state.json"), operationID)
}

func readHostMaintenancePolicy(path, operationID string) error {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	if err != nil || len(data) > 4<<20 {
		return provisionerError{code: "agent_vmm.maintenance_unreadable", message: "Local Host maintenance policy is unreadable; automatic setup is paused."}
	}
	var policy struct {
		Version         int             `json:"version"`
		ActiveRequest   string          `json:"activeRequest"`
		Uninstalled     *bool           `json:"uninstalled"`
		BlockedInstalls map[string]bool `json:"blockedInstalls"`
	}
	if json.Unmarshal(data, &policy) != nil || policy.Version != 1 || policy.Uninstalled == nil {
		return provisionerError{code: "agent_vmm.maintenance_unreadable", message: "Local Host maintenance policy is invalid; automatic setup is paused."}
	}
	if policy.BlockedInstalls[operationID] {
		return provisionerError{code: "agent_vmm.local_disposed", message: "This exact installation was removed by the local Host owner."}
	}
	if policy.ActiveRequest != "" || *policy.Uninstalled {
		return provisionerError{code: "agent_vmm.maintenance_required", message: "The local owner is maintaining Agent VMM or has uninstalled it. Continue local maintenance before automatic setup."}
	}
	return nil
}
