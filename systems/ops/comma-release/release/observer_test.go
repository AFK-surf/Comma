package release

import (
	"slices"
	"testing"
	"time"
)

func TestObserverTruthTableIsBoundedAndIndependent(t *testing.T) {
	now := time.Unix(10_000, 0).UTC()
	tests := []struct {
		name  string
		state State
		want  []string
	}{
		{"healthy", State{ReleaseID: "r", Phase: PhaseSucceeded, Provider: ProviderFacts{Status: "succeeded"}, UpdatedAt: now}, nil},
		{"stuck", State{ReleaseID: "r", Phase: PhaseApplying, UpdatedAt: now.Add(-21 * time.Minute)}, []string{"stuck"}},
		{"forward", State{ReleaseID: "r", Phase: PhaseForwardOnly, UpdatedAt: now.Add(-time.Minute)}, []string{"forward_only"}},
		{"recovery", State{ReleaseID: "r", Phase: PhaseRecovering, LastError: "restore failed", UpdatedAt: now}, []string{"recovery_failed"}},
		{"provider", State{ReleaseID: "r", Phase: PhaseSucceeded, Provider: ProviderFacts{Status: "running", StartedAt: now.Add(-16 * time.Minute)}, UpdatedAt: now}, []string{"provider_degraded"}},
		{"outage", State{ReleaseID: "r", Phase: PhaseCutover, MaintenanceStartedAt: now.Add(-31 * time.Minute), UpdatedAt: now}, []string{"outage_budget_exceeded"}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := Observe(tc.state, now, 20*time.Minute, 15*time.Minute, 30*time.Minute)
			kinds := make([]string, len(got.Alerts))
			for i := range got.Alerts {
				kinds[i] = got.Alerts[i].Kind
			}
			if !slices.Equal(kinds, tc.want) || got.Healthy != (len(tc.want) == 0) {
				t.Fatalf("%#v", got)
			}
		})
	}
}
