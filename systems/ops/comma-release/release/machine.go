package release

import (
	"errors"
	"fmt"
	"slices"
	"time"
)

type Event string

const (
	EventPlan          Event = "plan"
	EventOnlineStarted Event = "online_started"
	EventOnlineDone    Event = "online_done"
	EventQuiesced      Event = "quiesced"
	EventCutoverFenced Event = "cutover_fenced"
	EventCutoverDone   Event = "cutover_done"
	EventApplied       Event = "applied"
	EventVerified      Event = "verified"
	EventRecover       Event = "recover"
	EventRecovered     Event = "recovered"
)

func Reduce(state State, event Event, plan *Plan, now time.Time) (State, error) {
	next := state
	switch event {
	case EventPlan:
		if state.Phase != PhasePrepared && state.Phase != PhasePlanned {
			return state, invalid(state.Phase, event)
		}
		if plan == nil {
			return state, errors.New("plan required")
		}
		if err := state.ValidatePlan(*plan); err != nil {
			return state, err
		}
		pending := plan.CorePending()
		if next.ManifestDigest == "" {
			next.ManifestDigest = plan.ManifestDigest
			next.InitialPending = slices.Clone(pending)
		}
		next.RequiredMode = plan.RequiredMode
		next.CurrentPending = pending
		next.Provider.AllowedIDs = slices.Clone(plan.ProviderPendingIDs)
		if len(next.Provider.AllowedIDs) == 0 {
			next.Provider.Status = "succeeded"
		} else {
			next.Provider.Status = "pending"
		}
		next.Phase = PhasePlanned
	case EventOnlineStarted:
		if state.Phase != PhasePlanned {
			return state, invalid(state.Phase, event)
		}
		next.Phase = PhaseOnline
	case EventOnlineDone:
		if state.Phase != PhaseOnline {
			return state, invalid(state.Phase, event)
		}
		if state.RequiresExclusiveDeployment() {
			next.Phase = PhaseQuiescing
		} else {
			next.Phase = PhaseApplying
		}
	case EventQuiesced:
		if state.Phase != PhaseQuiescing {
			return state, invalid(state.Phase, event)
		}
		next.Phase = PhaseCutover
	case EventCutoverFenced:
		if state.Phase != PhaseCutover {
			return state, invalid(state.Phase, event)
		}
		next.CutoverMayHaveStarted = true
	case EventCutoverDone:
		if state.Phase != PhaseCutover {
			return state, invalid(state.Phase, event)
		}
		next.Phase = PhaseApplying
	case EventApplied:
		if state.Phase != PhaseApplying {
			return state, invalid(state.Phase, event)
		}
		next.Phase = PhaseVerifying
	case EventVerified:
		if state.Phase != PhaseVerifying {
			return state, invalid(state.Phase, event)
		}
		next.Phase = PhaseSucceeded
	case EventRecover:
		if state.Phase == PhaseSucceeded || state.Phase == PhaseRecovered {
			return state, invalid(state.Phase, event)
		}
		if state.CutoverMayHaveStarted {
			next.Phase = PhaseForwardOnly
		} else {
			next.Phase = PhaseRecovering
		}
	case EventRecovered:
		if state.Phase != PhaseRecovering {
			return state, invalid(state.Phase, event)
		}
		next.Phase = PhaseRecovered
	default:
		return state, fmt.Errorf("unknown event %q", event)
	}
	next.UpdatedAt = now.UTC()
	return next, nil
}

func invalid(phase Phase, event Event) error {
	return fmt.Errorf("event %q is invalid from phase %q", event, phase)
}

func JobName(releaseID, stage string, attempt int) string {
	return fmt.Sprintf("comma-release-%s-%s-%d", sanitize(releaseID), sanitize(stage), attempt)
}

func NextAttempt(state State, stage string) JobAttempt {
	n := 1
	for _, a := range state.Attempts {
		if a.Stage == stage && a.Attempt >= n {
			n = a.Attempt + 1
		}
	}
	return JobAttempt{Stage: stage, Attempt: n, Name: JobName(state.ReleaseID, stage, n), Status: "pending"}
}

func sanitize(s string) string {
	out := make([]byte, 0, len(s))
	for i := range len(s) {
		c := s[i]
		if c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' {
			out = append(out, c)
		} else {
			out = append(out, '-')
		}
	}
	for len(out) > 0 && out[len(out)-1] == '-' {
		out = out[:len(out)-1]
	}
	if len(out) > 40 {
		out = out[:40]
	}
	return string(out)
}
