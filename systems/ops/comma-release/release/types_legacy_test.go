package release

import (
	"context"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestPlanRejectsPendingLegacyMigrationInsteadOfEnteringExclusiveMode(t *testing.T) {
	plan := testPlan(t, ModeOnline)
	plan.RequiredMode = Mode("blocked_legacy")
	plan.PendingIDs = []string{"salix-legacy"}
	plan.PendingSteps = []MigrationStepV2{testMigrationStep("salix-legacy", "legacy")}

	err := plan.Validate()
	if err == nil || !strings.Contains(err.Error(), "automatic zero-replica cutover is forbidden") {
		t.Fatalf("expected explicit legacy-migration rejection, got %v", err)
	}
}

func TestPlanAllowsOnlineExpandStepThatFailsClosedForOldRuntime(t *testing.T) {
	plan := testPlan(t, ModeOnline)
	step := testMigrationStep("salix-online-fail-closed", "expand")
	step.Compatibility["oldRuntimeRead"] = false
	step.Compatibility["oldRuntimeWrite"] = false
	plan.PendingIDs = []string{step.ID}
	plan.PendingSteps = []MigrationStepV2{step}

	if err := plan.Validate(); err != nil {
		t.Fatalf("online expand step should permit bounded mixed-version failure: %v", err)
	}
}

func TestPlanRejectsIncompatibleLocalSeedStep(t *testing.T) {
	plan := testPlan(t, ModeOnline)
	step := testMigrationStep("comma-incompatible-local-seed", "local_seed")
	step.Compatibility["oldRuntimeWrite"] = false
	plan.PendingIDs = []string{step.ID}
	plan.PendingSteps = []MigrationStepV2{step}

	err := plan.Validate()
	if err == nil || !strings.Contains(err.Error(), "local_seed") {
		t.Fatalf("incompatible local seed step must fail validation, got %v", err)
	}
}

func TestBlockedLegacyPlanCannotReachMigrationOrWorkloadMutation(t *testing.T) {
	plan := testPlan(t, ModeOnline)
	plan.RequiredMode = Mode("blocked_legacy")
	plan.PendingIDs = []string{"salix-legacy"}
	plan.PendingSteps = []MigrationStepV2{testMigrationStep("salix-legacy", "legacy")}

	store := &memoryStore{}
	platform := &fakePlatform{plan: plan}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	_, err := engine.Prepare(context.Background(), "staging", "legacy", "image", []byte("bundle"))
	if err == nil || !strings.Contains(err.Error(), "automatic zero-replica cutover is forbidden") {
		t.Fatalf("expected plan-stage legacy rejection, got %v", err)
	}
	if platform.quiesced || platform.applied || platform.verified || len(platform.jobs) != 0 {
		t.Fatalf("blocked legacy plan mutated the serving path: platform=%#v", platform)
	}
	if !store.exists || store.record.State.Phase != PhasePrepared {
		t.Fatalf("expected only a failed prepared release claim, got %#v", store.record.State)
	}
}

func TestAuditedLegacyUpgradeUsesDedicatedStagesAndStartsOnlyTheCandidate(t *testing.T) {
	ctx := context.Background()
	plan := auditedLegacyUpgradePlan(t)
	store := &memoryStore{}
	platform := &fakePlatform{plan: plan}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	prepared, err := engine.PrepareLegacyUpgrade(ctx, "production", "legacy-r1", "image", []byte("bundle"))
	if err != nil {
		t.Fatal(err)
	}
	if prepared.RequiredMode != ModeBlockedLegacy {
		t.Fatalf("legacy upgrade identity was not durable: %#v", prepared)
	}

	state, err := engine.Reconcile(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if state.Phase != PhaseSucceeded || !platform.quiesced || !platform.applied || !platform.verified {
		t.Fatalf("legacy upgrade did not reach verified candidate serving: state=%#v platform=%#v", state, platform)
	}
	if len(platform.jobs) != 2 || platform.jobs[0].Stage != "legacy-online" || platform.jobs[1].Stage != "legacy-cutover" {
		t.Fatalf("legacy upgrade used ordinary or reordered stages: %#v", platform.jobs)
	}
	wantCutover := []string{
		"salix-20260728000103",
		"salix-20260729000001",
		"salix-20260729000002",
		"salix-exclusive-after-legacy",
	}
	if got := platform.jobs[1].AllowedStepIDs; !slices.Equal(got, wantCutover) {
		t.Fatalf("legacy cutover ids = %v, want %v", got, wantCutover)
	}
}

func TestAuditedLegacyUpgradeRejectsAnUnreservedLegacyStep(t *testing.T) {
	plan := auditedLegacyUpgradePlan(t)
	plan.PendingSteps[1].ID = "salix-unreserved-legacy"
	plan.PendingIDs = migrationIDs(plan.PendingSteps)

	if err := plan.ValidateLegacyUpgrade(); err == nil ||
		!strings.Contains(err.Error(), "outside the audited upgrade scope") {
		t.Fatalf("unreserved legacy step must fail closed, got %v", err)
	}
}

func auditedLegacyUpgradePlan(t *testing.T) Plan {
	t.Helper()
	online := testMigrationStep("salix-online-before-legacy", "expand")
	exclusive := testMigrationStep("salix-exclusive-after-legacy", "exclusive")
	steps := []MigrationStepV2{online}
	for index, id := range legacyUpgradeStepIDs {
		step := testMigrationStep(id, "legacy")
		step.Owner = "salix_store"
		step.Version = int64(index + 1)
		step.Compatibility["oldRuntimeWrite"] = false
		step.Execution.Transactional = false
		step.Execution.Idempotent = true
		step.Safety.BackupRequired = true
		steps = append(steps, step)
	}
	steps = append(steps, exclusive)
	plan := Plan{
		SchemaVersion:  2,
		ManifestDigest: "sha256:" + strings.Repeat("b", 64),
		RequiredMode:   ModeBlockedLegacy,
		PendingSteps:   steps,
	}
	plan.PendingIDs = migrationIDs(plan.PendingSteps)
	if err := plan.ValidateLegacyUpgrade(); err != nil {
		t.Fatal(err)
	}
	return plan
}
