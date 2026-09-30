package release

import "time"

type AlertFact struct {
	Kind      string        `json:"kind"`
	ReleaseID string        `json:"releaseId"`
	Phase     Phase         `json:"phase"`
	Age       time.Duration `json:"age"`
}

type Observation struct {
	Healthy bool        `json:"healthy"`
	Alerts  []AlertFact `json:"alerts"`
}

// Observe evaluates one bounded durable record. It performs no child scan and
// is safe for an external watchdog outside the release runner failure domain.
func Observe(state State, now time.Time, stuckAfter, providerDegradedAfter, outageBudget time.Duration) Observation {
	now = now.UTC()
	add := func(result *Observation, kind string, since time.Time) {
		age := time.Duration(0)
		if !since.IsZero() && now.After(since) {
			age = now.Sub(since)
		}
		result.Alerts = append(result.Alerts, AlertFact{Kind: kind, ReleaseID: state.ReleaseID, Phase: state.Phase, Age: age})
	}
	result := Observation{Healthy: true}
	if state.Phase == PhaseForwardOnly {
		add(&result, "forward_only", state.UpdatedAt)
	}
	if state.Phase == PhaseRecovering && state.LastError != "" {
		add(&result, "recovery_failed", state.UpdatedAt)
	}
	if !terminal(state.Phase) && stuckAfter > 0 && now.Sub(state.UpdatedAt) >= stuckAfter {
		add(&result, "stuck", state.UpdatedAt)
	}
	if !state.MaintenanceStartedAt.IsZero() && state.Phase != PhaseSucceeded && outageBudget > 0 && now.Sub(state.MaintenanceStartedAt) >= outageBudget {
		add(&result, "outage_budget_exceeded", state.MaintenanceStartedAt)
	}
	providerSince := state.Provider.StartedAt
	if providerSince.IsZero() {
		providerSince = state.Provider.UpdatedAt
	}
	if state.Provider.Status == "degraded" || state.Provider.Status == "failed" || ((state.Provider.Status == "pending" || state.Provider.Status == "running") && providerDegradedAfter > 0 && !providerSince.IsZero() && now.Sub(providerSince) >= providerDegradedAfter) {
		add(&result, "provider_degraded", providerSince)
	}
	result.Healthy = len(result.Alerts) == 0
	return result
}
