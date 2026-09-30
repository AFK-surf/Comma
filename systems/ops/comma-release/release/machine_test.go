package release

import (
	"slices"
	"strings"
	"testing"
	"time"
)

func testPlan(t *testing.T, mode Mode) Plan {
	t.Helper()
	p := Plan{SchemaVersion: 2, ManifestDigest: "sha256:" + strings.Repeat("a", 64), RequiredMode: mode}
	p.PendingSteps = append(p.PendingSteps, testMigrationStep("schema-1", "expand"))
	if mode == ModeExclusive {
		p.PendingSteps = append(p.PendingSteps, testMigrationStep("cut-1", "exclusive"))
	}
	slices.SortFunc(p.PendingSteps, func(a, b MigrationStepV2) int { return strings.Compare(a.ID, b.ID) })
	p.PendingIDs = migrationIDs(p.PendingSteps)
	if err := p.Validate(); err != nil {
		t.Fatal(err)
	}
	return p
}

func testMigrationStep(id, phase string) MigrationStepV2 {
	return MigrationStepV2{ID: id, Owner: "test", Store: "postgres", Version: 1, Source: "test", Checksum: "sha256:test", Phase: phase, Compatibility: map[string]bool{"oldRuntimeRead": true, "oldRuntimeWrite": true, "newRuntimeRead": true, "newRuntimeWrite": true}, Execution: MigrationExecutionFacts{Transactional: true, TimeoutSeconds: 300, LockBudgetSeconds: 5}, Safety: MigrationSafetyFacts{RollbackStrategy: "none"}, Postconditions: []string{"complete"}, Repair: "exact_retry"}
}

func TestPlanDigestDeterministic(t *testing.T) {
	a := testPlan(t, ModeOnline)
	b := testPlan(t, ModeOnline)
	if a.ManifestDigest != b.ManifestDigest {
		t.Fatalf("digests differ: %s %s", a.ManifestDigest, b.ManifestDigest)
	}
}

func TestPlanPreservesManifestDependencyOrder(t *testing.T) {
	repair := testMigrationStep("comma-20260723000014", "expand")
	dependent := testMigrationStep("comma-20260723000007", "expand")
	cutover := testMigrationStep("comma-20260723000003", "exclusive")
	plan := Plan{
		SchemaVersion:  2,
		ManifestDigest: "sha256:" + strings.Repeat("a", 64),
		RequiredMode:   ModeExclusive,
		PendingSteps:   []MigrationStepV2{repair, cutover, dependent},
		PendingIDs:     []string{repair.ID, cutover.ID, dependent.ID},
	}

	if err := plan.Validate(); err != nil {
		t.Fatal(err)
	}
	if got := plan.CorePending(); !slices.Equal(got, plan.PendingIDs) {
		t.Fatalf("core pending order changed: got %v want %v", got, plan.PendingIDs)
	}
	if got := plan.PendingMigrationPhases("expand"); !slices.Equal(got, []string{repair.ID, dependent.ID}) {
		t.Fatalf("online phase order changed: got %v", got)
	}

	plan.PendingIDs = []string{dependent.ID, cutover.ID, repair.ID}
	if err := plan.Validate(); err == nil {
		t.Fatal("permuted pending IDs must not authorize differently ordered step facts")
	}
}

func TestOnlineAndExclusiveTransitions(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mode   Mode
		phases []Phase
	}{
		{"online", ModeOnline, []Phase{PhasePlanned, PhaseOnline, PhaseApplying, PhaseVerifying, PhaseSucceeded}},
		{"exclusive", ModeExclusive, []Phase{PhasePlanned, PhaseOnline, PhaseQuiescing, PhaseCutover, PhaseApplying, PhaseVerifying, PhaseSucceeded}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			now := time.Unix(1, 0)
			s := NewState("staging", "r1", "image", 1, now)
			p := testPlan(t, tc.mode)
			var err error
			s, err = Reduce(s, EventPlan, &p, now)
			if err != nil {
				t.Fatal(err)
			}
			events := []Event{EventOnlineStarted, EventOnlineDone}
			if tc.mode == ModeExclusive {
				events = append(events, EventQuiesced, EventCutoverFenced, EventCutoverDone)
			}
			events = append(events, EventApplied, EventVerified)
			for _, e := range events {
				s, err = Reduce(s, e, nil, now)
				if err != nil {
					t.Fatal(err)
				}
			}
			if s.Phase != PhaseSucceeded {
				t.Fatalf("got %s", s.Phase)
			}
		})
	}
}

func TestPlanDriftAndMonotonicPending(t *testing.T) {
	now := time.Unix(1, 0)
	s := NewState("staging", "r1", "image", 1, now)
	p := testPlan(t, ModeOnline)
	s, _ = Reduce(s, EventPlan, &p, now)
	drift := p
	drift.ManifestDigest = "sha256:changed"
	if _, err := Reduce(s, EventPlan, &drift, now); err == nil {
		t.Fatal("expected digest drift")
	}
	shrunk := p
	shrunk.PendingIDs = nil
	shrunk.PendingSteps = nil
	// A recomputed runtime plan keeps the static manifest digest while pending facts shrink.
	if err := s.ValidatePlan(shrunk); err != nil {
		t.Fatal(err)
	}
	s.CurrentPending = shrunk.CorePending()
	if err := s.ValidatePlan(p); err == nil {
		t.Fatal("completed pending step reappeared")
	}

	ordered := Plan{
		SchemaVersion:  2,
		ManifestDigest: "sha256:" + strings.Repeat("b", 64),
		RequiredMode:   ModeOnline,
		PendingSteps: []MigrationStepV2{
			testMigrationStep("comma-20260723000014", "expand"),
			testMigrationStep("comma-20260723000007", "expand"),
		},
	}
	ordered.PendingIDs = migrationIDs(ordered.PendingSteps)
	state := NewState("staging", "r-ordered", "image", 1, now)
	state, _ = Reduce(state, EventPlan, &ordered, now)

	reordered := ordered
	reordered.PendingSteps = slices.Clone(ordered.PendingSteps)
	reordered.PendingSteps[0], reordered.PendingSteps[1] = reordered.PendingSteps[1], reordered.PendingSteps[0]
	reordered.PendingIDs = migrationIDs(reordered.PendingSteps)
	if err := state.ValidatePlan(reordered); err == nil {
		t.Fatal("reordered pending steps must fail durable plan drift validation")
	}
}

func TestRecoveryBoundary(t *testing.T) {
	now := time.Unix(1, 0)
	s := NewState("staging", "r1", "image", 1, now)
	s.Phase = PhaseQuiescing
	before, err := Reduce(s, EventRecover, nil, now)
	if err != nil || before.Phase != PhaseRecovering {
		t.Fatalf("%#v %v", before, err)
	}
	s.CutoverMayHaveStarted = true
	after, err := Reduce(s, EventRecover, nil, now)
	if err != nil || after.Phase != PhaseForwardOnly {
		t.Fatalf("%#v %v", after, err)
	}
}

func TestDeterministicAttempts(t *testing.T) {
	s := State{ReleaseID: "2026.07.17+abc", Attempts: []JobAttempt{{Stage: "online", Attempt: 1}}}
	a := NextAttempt(s, "online")
	if a.Attempt != 2 || a.Name != "comma-release-2026-07-17-abc-online-2" {
		t.Fatalf("%#v", a)
	}
}
