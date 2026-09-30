package release

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
)

type memoryStore struct {
	record       Record
	exists       bool
	updateCalls  int
	failUpdateAt int
}

func (s *memoryStore) Load(context.Context) (Record, error) {
	if !s.exists {
		return Record{}, ErrNotFound
	}
	return s.record, nil
}
func (s *memoryStore) Create(_ context.Context, state State) (Record, error) {
	if s.exists && !terminal(s.record.State.Phase) {
		return Record{}, ErrConflict
	}
	s.exists = true
	s.record = Record{State: state, Version: "1"}
	return s.record, nil
}
func (s *memoryStore) Update(_ context.Context, r Record) (Record, error) {
	s.updateCalls++
	if s.failUpdateAt > 0 && s.updateCalls == s.failUpdateAt {
		return Record{}, errors.New("injected state update failure")
	}
	if r.Version != s.record.Version {
		return Record{}, ErrConflict
	}
	r.Version = r.Version + "x"
	s.record = r
	return r, nil
}

type fakePlatform struct {
	plan                                  Plan
	plans                                 []Plan
	quiesced, restored, applied, verified bool
	restoreCalls                          int
	abortCalls                            int
	abortErr                              error
	callOrder                             []string
	attemptStatus                         string
	attemptStatuses                       []string
	attemptStatusErr                      error
	attemptStatusCalls                    int
	jobs                                  []JobSpec
	applyEvidence                         ApplyEvidence
	fail                                  string
	cleanupCalls                          int
	cleanupDeletesSnapshot                bool
	snapshotCandidateAvailable            bool
	currentHelmRevision                   int
	currentHelmRevisionErr                error
	ensureBundleCalls                     int
	onRunJob                              func(JobSpec)
	lifecycleEpochOps                     []LifecycleEpochSpec
	lifecycleV1Verified                   bool
	failLifecycleAction                   LifecycleEpochAction
	failLifecycleOccurrence               int
	onRunLifecycleEpoch                   func(LifecycleEpochSpec, int) (LifecycleEpochEvidence, error, bool)
}

func (f *fakePlatform) Preflight(context.Context, []byte) (string, error) {
	f.callOrder = append(f.callOrder, "preflight")
	if f.fail == "preflight" {
		return "", errors.New("invalid Helm values")
	}
	return "sha256:values", nil
}

func (f *fakePlatform) CurrentHelmRevision(context.Context) (int, error) {
	f.callOrder = append(f.callOrder, "helm-status")
	if f.currentHelmRevisionErr != nil {
		return 0, f.currentHelmRevisionErr
	}
	if f.currentHelmRevision == 0 {
		return 1, nil
	}
	return f.currentHelmRevision, nil
}
func (f *fakePlatform) EnsureBundle(_ context.Context, n string, _ []byte) (string, error) {
	f.ensureBundleCalls++
	return n, nil
}
func (f *fakePlatform) RunPlan(context.Context, State) (Plan, error) {
	if len(f.plans) > 0 {
		plan := f.plans[0]
		f.plans = f.plans[1:]
		return plan, nil
	}
	return f.plan, nil
}
func (f *fakePlatform) RunJob(_ context.Context, j JobSpec) error {
	f.jobs = append(f.jobs, j)
	f.callOrder = append(f.callOrder, "job:"+j.Stage)
	if f.onRunJob != nil {
		f.onRunJob(j)
	}
	if f.fail == j.Stage {
		return errors.New("failed")
	}
	f.plan.PendingIDs = without(f.plan.PendingIDs, j.AllowedStepIDs)
	f.plan.PendingSteps = slices.DeleteFunc(f.plan.PendingSteps, func(step MigrationStepV2) bool { return slices.Contains(j.AllowedStepIDs, step.ID) })
	return nil
}

func (f *fakePlatform) RunLifecycleEpoch(_ context.Context, spec LifecycleEpochSpec) (LifecycleEpochEvidence, error) {
	f.lifecycleEpochOps = append(f.lifecycleEpochOps, spec)
	f.callOrder = append(f.callOrder, "lifecycle:"+string(spec.Action))
	occurrence := 0
	for _, operation := range f.lifecycleEpochOps {
		if operation.Action == spec.Action {
			occurrence++
		}
	}
	if f.onRunLifecycleEpoch != nil {
		if evidence, err, handled := f.onRunLifecycleEpoch(spec, occurrence); handled {
			return evidence, err
		}
	}
	if f.fail == "lifecycle:"+string(spec.Action) {
		return LifecycleEpochEvidence{}, errors.New("lifecycle epoch failed")
	}
	if f.failLifecycleAction == spec.Action && f.failLifecycleOccurrence == occurrence {
		return LifecycleEpochEvidence{}, errors.New("lifecycle epoch failed")
	}
	generation := spec.Generation
	if generation == 0 {
		generation = 1
	}
	now := time.Now().UTC()
	evidence := LifecycleEpochEvidence{
		SchemaVersion: 1, Action: spec.Action, Status: "active",
		ReleaseID: spec.ReleaseID, Generation: generation,
		LeaseExpiresAt: now.Add(5 * time.Minute), DrainedAt: now,
	}
	if spec.Action == LifecycleEpochRelease {
		evidence.Status = "released"
		evidence.ReleasedAt = now
	}
	return evidence, nil
}

func (f *fakePlatform) VerifyLifecycleV1(context.Context, State) error {
	f.lifecycleV1Verified = true
	f.callOrder = append(f.callOrder, "lifecycle-v1")
	if f.fail == "lifecycle-v1" {
		return errors.New("old serving replica")
	}
	return nil
}

func TestReconcileCompletesCoreBeforeProviderDispatch(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	plan := testPlan(t, ModeOnline)
	plan.ProviderPendingIDs = []string{"billing-provider"}
	platform := &fakePlatform{plan: plan, fail: "provider"}
	engine := Engine{Store: store, Platform: platform, Now: time.Now, ProviderRetries: 1,
		ProviderWait: func(context.Context, time.Duration) error { return nil }}
	if _, err := engine.Prepare(ctx, "staging", "r1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	state, err := engine.Reconcile(ctx)
	if err != nil || state.Phase != PhaseSucceeded || state.Provider.Status != "degraded" || !platform.applied || !platform.verified {
		t.Fatalf("reconcile did not isolate provider: %#v err=%v platform=%#v", state, err, platform)
	}
}

func TestApplyPersistsHelmRevision(t *testing.T) {
	state := NewState("staging", "repair", "image", 1, time.Now())
	state.Phase = PhaseApplying
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{applyEvidence: ApplyEvidence{ManifestDigest: "sha256:apply", HelmRevision: 12}}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}
	got, err := engine.Apply(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	if got.Helm.CandidateRevision != 12 || !slices.Equal(got.Helm.AppliedRevisions, []int{12}) {
		t.Fatalf("Helm evidence was not persisted: %#v", got.Helm)
	}
}

func TestPreparePersistsAndFencesTheExactChartIdentity(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	reference := "oci://ghcr.io/afk-surf/charts/comma@sha256:" + strings.Repeat("a", 64)
	digest := "sha256:" + strings.Repeat("a", 64)
	engine := Engine{Store: store, Platform: platform, Now: time.Now, ChartReference: reference, ChartDigest: digest}

	state, err := engine.Prepare(ctx, "staging", "r1", "image", []byte("bundle"))
	if err != nil {
		t.Fatal(err)
	}
	if state.Artifacts.ChartReference != reference || state.Artifacts.ChartDigest != digest {
		t.Fatalf("durable chart identity = %#v", state.Artifacts)
	}

	drifted := engine
	drifted.ChartReference = "oci://ghcr.io/afk-surf/charts/comma@sha256:" + strings.Repeat("b", 64)
	drifted.ChartDigest = "sha256:" + strings.Repeat("b", 64)
	if _, err = drifted.Prepare(ctx, "staging", "r1", "image", []byte("bundle")); err == nil || !strings.Contains(err.Error(), "chart identity drift") {
		t.Fatalf("active release accepted chart drift: %v", err)
	}
}

func TestMigratePreservesManifestDependencyOrderInOnlineJob(t *testing.T) {
	ctx := context.Background()
	repair := testMigrationStep("comma-20260723000014", "expand")
	dependent := testMigrationStep("comma-20260723000007", "expand")
	plan := Plan{
		SchemaVersion:  2,
		ManifestDigest: "sha256:" + strings.Repeat("a", 64),
		RequiredMode:   ModeOnline,
		PendingSteps:   []MigrationStepV2{repair, dependent},
		PendingIDs:     []string{repair.ID, dependent.ID},
	}
	if err := plan.Validate(); err != nil {
		t.Fatal(err)
	}

	store := &memoryStore{}
	platform := &fakePlatform{plan: plan}
	platform.onRunJob = func(spec JobSpec) {
		if spec.Stage == "online" &&
			!slices.Equal(spec.AllowedStepIDs, []string{repair.ID, dependent.ID}) {
			t.Fatalf("online job dependency order changed: got %v", spec.AllowedStepIDs)
		}
	}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	if _, err := engine.Prepare(ctx, "staging", "r1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestCutoverFenceIsDurableBeforeExclusiveJob(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeExclusive)}
	platform.onRunJob = func(spec JobSpec) {
		if spec.Stage == "cutover" && !store.record.State.CutoverMayHaveStarted {
			t.Fatal("cutover Job started before durable fence")
		}
	}
	engine := Engine{AuthorizeShutdown: func(context.Context, State) error { return nil }, Store: store, Platform: platform, Now: time.Now}
	if _, err := engine.Prepare(ctx, "staging", "r1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestLifecycleHardCutForcesExclusiveEpochAcrossOnlinePlanAndReleasesAfterV1Verify(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}
	if _, err := engine.Prepare(ctx, "staging", "lifecycle-v1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	migrated, err := engine.Migrate(ctx)
	if err != nil || migrated.Phase != PhaseApplying || !platform.quiesced {
		t.Fatalf("hard cut did not enter exclusive path: state=%#v err=%v", migrated, err)
	}
	if _, err = engine.Apply(ctx); err != nil {
		t.Fatal(err)
	}
	verified, err := engine.Verify(ctx)
	if err != nil {
		t.Fatal(err)
	}
	epoch := verified.LifecycleWriterEpoch
	if verified.Phase != PhaseSucceeded || epoch == nil || epoch.Status != "released" ||
		epoch.Generation != 1 || epoch.FencingToken != "" || !platform.lifecycleV1Verified {
		t.Fatalf("lifecycle epoch did not close after v1 verify: %#v", verified)
	}
	var verifyIndex, lifecycleV1Index, assertIndex, releaseIndex = -1, -1, -1, -1
	for index, call := range platform.callOrder {
		switch call {
		case "verify":
			verifyIndex = index
		case "lifecycle-v1":
			lifecycleV1Index = index
		case "lifecycle:assert":
			assertIndex = index
		case "lifecycle:release":
			releaseIndex = index
		}
	}
	if verifyIndex < 0 || lifecycleV1Index <= verifyIndex || assertIndex <= lifecycleV1Index ||
		releaseIndex <= assertIndex || platform.cleanupCalls != 1 {
		t.Fatalf("epoch release ordering/calls = %#v", platform.callOrder)
	}
}

func TestLifecycleHardCutIngressFailureKeepsEpochHeldBeforeSuccess(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline), fail: "lifecycle-v1"}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}
	if _, err := engine.Prepare(ctx, "staging", "lifecycle-v1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Apply(ctx); err != nil {
		t.Fatal(err)
	}
	state, err := engine.Verify(ctx)
	if err == nil || !strings.Contains(err.Error(), "hard-cut ingress contract") {
		t.Fatalf("lifecycle ingress failure was accepted: state=%#v err=%v", state, err)
	}
	epoch := state.LifecycleWriterEpoch
	if state.Phase != PhaseVerifying || epoch == nil || epoch.Status != "active" {
		t.Fatalf("lifecycle ingress failure did not retain the active verify fence: %#v", state)
	}
	if slices.Contains(platform.callOrder, "lifecycle:release") || platform.cleanupCalls != 0 {
		t.Fatalf("failed lifecycle ingress verification released/cleaned up: %#v", platform.callOrder)
	}
}

func TestLifecycleHardCutStopsBeforeActualRolloutWhenPreflightFenceChanges(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}
	if _, err := engine.Prepare(ctx, "staging", "lifecycle-v1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	platform.fail = "lifecycle:renew"
	state, err := engine.Apply(ctx)
	if err == nil || state.Phase != PhaseApplying || platform.applied {
		t.Fatalf("split preflight reached actual rollout: state=%#v err=%v", state, err)
	}
}

func TestLifecycleHardCutRunnerLossAfterVerifyKeepsGateClosedUntilResumeReleasesIt(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}
	if _, err := engine.Prepare(ctx, "staging", "lifecycle-v1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	if _, err := engine.Apply(ctx); err != nil {
		t.Fatal(err)
	}
	platform.fail = "lifecycle:release"
	state, err := engine.Verify(ctx)
	if err == nil || state.Phase != PhaseSucceeded ||
		state.LifecycleWriterEpoch == nil || state.LifecycleWriterEpoch.Status != "active" {
		t.Fatalf("runner loss reopened or lost the epoch: state=%#v err=%v", state, err)
	}
	platform.fail = ""
	resumed, err := engine.Reconcile(ctx)
	if err != nil || resumed.LifecycleWriterEpoch.Status != "released" {
		t.Fatalf("succeeded release did not recover epoch ownership: state=%#v err=%v", resumed, err)
	}
}

func TestRecoverSucceededLifecycleEpochSettlementIsNarrowAndRetryable(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC()
	activeState := func() State {
		state := NewState("staging", "lifecycle-v1", "image", 1, now)
		state.Phase = PhaseSucceeded
		state.LifecycleWriterEpoch = &LifecycleWriterEpochFacts{
			Required: true, Status: "active", Generation: 1,
			FencingToken: strings.Repeat("a", 64), OperationAttempt: 4,
			LeaseExpiresAt: now.Add(time.Minute), DrainedAt: now,
		}
		return state
	}

	t.Run("active epoch is released without repeating terminal work", func(t *testing.T) {
		store := &memoryStore{exists: true, record: Record{Version: "1", State: activeState()}}
		platform := &fakePlatform{}
		engine := Engine{Store: store, Platform: platform, Now: func() time.Time { return now }}

		got, err := engine.Recover(ctx, "lifecycle-v1")
		if err != nil || got.Phase != PhaseSucceeded || got.LifecycleWriterEpoch.Status != "released" {
			t.Fatalf("succeeded recovery did not release active epoch: state=%#v err=%v", got, err)
		}
		if len(platform.lifecycleEpochOps) != 1 ||
			platform.lifecycleEpochOps[0].Action != LifecycleEpochRelease ||
			platform.cleanupCalls != 0 || platform.restored || len(platform.jobs) != 0 {
			t.Fatalf("succeeded recovery repeated terminal work: ops=%#v platform=%#v", platform.lifecycleEpochOps, platform)
		}
	})

	t.Run("released epoch remains a no-op", func(t *testing.T) {
		state := activeState()
		state.LifecycleWriterEpoch.Status = "released"
		state.LifecycleWriterEpoch.FencingToken = ""
		state.LifecycleWriterEpoch.ReleasedAt = now
		store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
		platform := &fakePlatform{}
		engine := Engine{Store: store, Platform: platform, Now: func() time.Time { return now }}

		got, err := engine.Recover(ctx, "lifecycle-v1")
		if err != nil || got.LifecycleWriterEpoch.Status != "released" ||
			len(platform.lifecycleEpochOps) != 0 || platform.cleanupCalls != 0 || platform.restored {
			t.Fatalf("released succeeded recovery was not a no-op: state=%#v err=%v platform=%#v", got, err, platform)
		}
	})

	t.Run("failed release remains active and the next recovery retries", func(t *testing.T) {
		store := &memoryStore{exists: true, record: Record{Version: "1", State: activeState()}}
		platform := &fakePlatform{
			failLifecycleAction:     LifecycleEpochRelease,
			failLifecycleOccurrence: 1,
		}
		engine := Engine{Store: store, Platform: platform, Now: func() time.Time { return now }}

		first, err := engine.Recover(ctx, "lifecycle-v1")
		if err == nil || first.Phase != PhaseSucceeded || first.LifecycleWriterEpoch.Status != "active" {
			t.Fatalf("failed release lost durable success or active epoch: state=%#v err=%v", first, err)
		}
		second, err := engine.Recover(ctx, "lifecycle-v1")
		if err != nil || second.LifecycleWriterEpoch.Status != "released" {
			t.Fatalf("second succeeded recovery did not retry release: state=%#v err=%v", second, err)
		}
		if len(platform.lifecycleEpochOps) != 2 ||
			platform.lifecycleEpochOps[0].Action != LifecycleEpochRelease ||
			platform.lifecycleEpochOps[1].Action != LifecycleEpochRelease ||
			platform.lifecycleEpochOps[0].Token != platform.lifecycleEpochOps[1].Token ||
			platform.lifecycleEpochOps[0].Generation != platform.lifecycleEpochOps[1].Generation ||
			platform.cleanupCalls != 0 || platform.restored {
			t.Fatalf("release retry changed identity or repeated terminal work: %#v", platform.lifecycleEpochOps)
		}
	})
}

func TestRecoverSettlesCommittedAcquireAfterAcknowledgementLoss(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	var committedToken string
	platform.onRunLifecycleEpoch = func(spec LifecycleEpochSpec, occurrence int) (LifecycleEpochEvidence, error, bool) {
		if spec.Action != LifecycleEpochAcquire {
			return LifecycleEpochEvidence{}, nil, false
		}
		durable := store.record.State.LifecycleWriterEpoch
		if durable == nil || durable.Status != "acquiring" ||
			durable.FencingToken != spec.Token ||
			durable.OperationAttempt != spec.Attempt {
			return LifecycleEpochEvidence{}, errors.New("acquire intent was not durable before the external call"), true
		}
		if occurrence == 1 {
			// Model the database transaction committing before the controller
			// loses the Kubernetes Job acknowledgement/evidence read.
			committedToken = spec.Token
			return LifecycleEpochEvidence{}, errors.New("acquire acknowledgement lost after commit"), true
		}
		if spec.Token != committedToken {
			return LifecycleEpochEvidence{}, errors.New("acquire retry changed the committed fencing token"), true
		}
		now := time.Now().UTC()
		return LifecycleEpochEvidence{
			SchemaVersion: 1, Action: LifecycleEpochAcquire, Status: "active",
			ReleaseID: spec.ReleaseID, Generation: 1,
			LeaseExpiresAt: now.Add(5 * time.Minute), DrainedAt: now,
		}, nil, true
	}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}

	if _, err := engine.Prepare(ctx, "staging", "lifecycle-v1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	failed, err := engine.Migrate(ctx)
	if err == nil || failed.Phase != PhaseQuiescing ||
		failed.LifecycleWriterEpoch == nil ||
		failed.LifecycleWriterEpoch.Status != "acquiring" ||
		failed.LifecycleWriterEpoch.FencingToken != committedToken ||
		failed.LifecycleWriterEpoch.OperationAttempt != 1 {
		t.Fatalf("acknowledgement loss did not retain durable acquire intent: state=%#v err=%v", failed, err)
	}

	recovered, err := engine.Recover(ctx, "lifecycle-v1")
	if err != nil || recovered.Phase != PhaseRecovered ||
		recovered.LifecycleWriterEpoch.Status != "released" ||
		recovered.LifecycleWriterEpoch.FencingToken != "" {
		t.Fatalf("recovery did not settle and release committed acquire: state=%#v err=%v", recovered, err)
	}
	operations := platform.lifecycleEpochOps
	if len(operations) != 3 ||
		operations[0].Action != LifecycleEpochAcquire ||
		operations[1].Action != LifecycleEpochAcquire ||
		operations[2].Action != LifecycleEpochRelease ||
		operations[0].Token == "" ||
		operations[0].Token != operations[1].Token ||
		operations[1].Token != operations[2].Token ||
		operations[2].Generation != 1 ||
		operations[0].Attempt != 1 ||
		operations[1].Attempt != 1 ||
		operations[2].Attempt != 2 {
		t.Fatalf("acquire settlement changed identity or ordering: %#v", operations)
	}
}

func TestRecoverWaitsForExactPendingLifecycleAcquireBeforeRelease(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	acquireCalls := 0
	platform.onRunLifecycleEpoch = func(spec LifecycleEpochSpec, _ int) (LifecycleEpochEvidence, error, bool) {
		if spec.Action != LifecycleEpochAcquire {
			return LifecycleEpochEvidence{}, nil, false
		}
		acquireCalls++
		if spec.Attempt != 1 {
			return LifecycleEpochEvidence{}, fmt.Errorf("recovery replaced pending acquire with attempt %d", spec.Attempt), true
		}
		if acquireCalls <= 2 {
			return LifecycleEpochEvidence{}, errors.New("exact acquire Job is still pending"), true
		}
		now := time.Now().UTC()
		return LifecycleEpochEvidence{
			SchemaVersion: 1, Action: LifecycleEpochAcquire, Status: "active",
			ReleaseID: spec.ReleaseID, Generation: 1,
			LeaseExpiresAt: now.Add(5 * time.Minute), DrainedAt: now,
		}, nil, true
	}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}

	if _, err := engine.Prepare(ctx, "staging", "pending-lifecycle-v1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	failed, err := engine.Migrate(ctx)
	if err == nil || failed.LifecycleWriterEpoch == nil ||
		failed.LifecycleWriterEpoch.Status != "acquiring" ||
		failed.LifecycleWriterEpoch.OperationAttempt != 1 {
		t.Fatalf("pending acquire did not retain exact durable intent: state=%#v err=%v", failed, err)
	}

	stillPending, err := engine.Recover(ctx, "pending-lifecycle-v1")
	if err == nil || stillPending.Phase != PhaseRecovering ||
		stillPending.LifecycleWriterEpoch.Status != "acquiring" ||
		stillPending.LifecycleWriterEpoch.OperationAttempt != 1 {
		t.Fatalf("recovery terminalized a pending acquire: state=%#v err=%v", stillPending, err)
	}
	if len(platform.lifecycleEpochOps) != 2 ||
		platform.lifecycleEpochOps[0].Attempt != 1 ||
		platform.lifecycleEpochOps[1].Attempt != 1 {
		t.Fatalf("recovery did not reattach the exact acquire Job: %#v", platform.lifecycleEpochOps)
	}

	recovered, err := engine.Recover(ctx, "pending-lifecycle-v1")
	if err != nil || recovered.Phase != PhaseRecovered ||
		recovered.LifecycleWriterEpoch.Status != "released" {
		t.Fatalf("completed exact acquire did not settle before release: state=%#v err=%v", recovered, err)
	}
	operations := platform.lifecycleEpochOps
	if len(operations) != 4 ||
		operations[2].Action != LifecycleEpochAcquire ||
		operations[2].Attempt != 1 ||
		operations[3].Action != LifecycleEpochRelease ||
		operations[3].Attempt != 2 {
		t.Fatalf("pending acquire settlement changed Job identity or release order: %#v", operations)
	}
}

func TestRecoverSettlesLegacyTerminalEmptyStatusAcquireIntent(t *testing.T) {
	now := time.Now().UTC()
	token := strings.Repeat("b", 64)
	state := NewState("staging", "legacy-lifecycle-v1", "image", 1, now)
	state.Phase = PhaseRecovered
	state.LifecycleWriterEpoch = &LifecycleWriterEpochFacts{
		Required: true, FencingToken: token, OperationAttempt: 1,
	}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{}
	engine := Engine{Store: store, Platform: platform, Now: func() time.Time { return now }}

	got, err := engine.Recover(context.Background(), "legacy-lifecycle-v1")
	if err != nil || got.Phase != PhaseRecovered ||
		got.LifecycleWriterEpoch.Status != "released" ||
		got.LifecycleWriterEpoch.FencingToken != "" {
		t.Fatalf("legacy empty-status intent did not settle: state=%#v err=%v", got, err)
	}
	if len(platform.lifecycleEpochOps) != 2 ||
		platform.lifecycleEpochOps[0].Action != LifecycleEpochAcquire ||
		platform.lifecycleEpochOps[1].Action != LifecycleEpochRelease ||
		platform.lifecycleEpochOps[0].Token != token ||
		platform.lifecycleEpochOps[1].Token != token {
		t.Fatalf("legacy intent settlement changed identity: %#v", platform.lifecycleEpochOps)
	}
}

func TestLifecycleHardCutFenceAssertionStopsWithoutCutoverOrRollout(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline), fail: "lifecycle:assert"}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}
	if _, err := engine.Prepare(ctx, "staging", "lifecycle-v1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	state, err := engine.Migrate(ctx)
	if err == nil || state.Phase != PhaseQuiescing || !platform.quiesced || platform.applied {
		t.Fatalf("failed fence assertion did not stop release: state=%#v err=%v", state, err)
	}
	if state.CutoverMayHaveStarted || state.LifecycleWriterEpoch.Status != "active" {
		t.Fatalf("fence assertion failure crossed cutover or dropped DB fence: %#v", state)
	}
}

func TestLifecycleHardCutSecondFenceAssertionStopsBeforeIrreversibleFenceAndCanRecover(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{
		plan:                    testPlan(t, ModeOnline),
		failLifecycleAction:     LifecycleEpochAssert,
		failLifecycleOccurrence: 2,
	}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}
	if _, err := engine.Prepare(ctx, "staging", "lifecycle-v1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	state, err := engine.Migrate(ctx)
	if err == nil || state.Phase != PhaseCutover || state.CutoverMayHaveStarted ||
		platform.applied {
		t.Fatalf("second fence assertion crossed irreversible fence: state=%#v err=%v", state, err)
	}
	recovered, err := engine.Recover(ctx, "lifecycle-v1")
	if err != nil || recovered.Phase != PhaseRecovered || !platform.restored ||
		recovered.LifecycleWriterEpoch == nil ||
		recovered.LifecycleWriterEpoch.Status != "released" {
		t.Fatalf("pre-cutover inventory stop did not recover safely: state=%#v err=%v", recovered, err)
	}
}

func TestLifecycleActiveTerminalStateCannotBeReplacedByAnotherRelease(t *testing.T) {
	now := time.Now().UTC()
	state := NewState("staging", "lifecycle-v1", "image", 1, now)
	state.Phase = PhaseSucceeded
	state.BundleName = BundleName([]byte("bundle"))
	state.Artifacts = ArtifactFacts{ChartReference: "chart", ChartDigest: "sha256:chart"}
	state.LifecycleWriterEpoch = &LifecycleWriterEpochFacts{
		Required: true, Status: "active", Generation: 3,
		FencingToken: strings.Repeat("a", 64), LeaseExpiresAt: now.Add(time.Minute),
		DrainedAt: now,
	}
	store := &memoryStore{
		exists: true,
		record: Record{
			State:   state,
			Version: "1",
		},
	}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		ChartReference: "chart", ChartDigest: "sha256:chart",
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}
	_, err := engine.Prepare(
		context.Background(),
		"staging",
		"next-release",
		"next-image",
		[]byte("next-bundle"),
	)
	if err == nil || !strings.Contains(err.Error(), `active release "lifecycle-v1"`) {
		t.Fatalf("active epoch terminal state was replaceable: state=%#v err=%v", store.record.State, err)
	}
	if store.record.State.ReleaseID != "lifecycle-v1" ||
		store.record.State.LifecycleWriterEpoch.FencingToken == "" {
		t.Fatalf("replacement lost the durable epoch owner: %#v", store.record.State)
	}
}

func TestLifecycleAcquireIntentTerminalStateCannotBeReplacedByAnotherRelease(t *testing.T) {
	now := time.Now().UTC()
	token := strings.Repeat("c", 64)
	state := NewState("staging", "lifecycle-v1", "image", 1, now)
	state.Phase = PhaseRecovered
	state.BundleName = BundleName([]byte("bundle"))
	state.Artifacts = ArtifactFacts{ChartReference: "chart", ChartDigest: "sha256:chart"}
	state.LifecycleWriterEpoch = &LifecycleWriterEpochFacts{
		Required: true, FencingToken: token, OperationAttempt: 1,
	}
	store := &memoryStore{
		exists: true,
		record: Record{
			State:   state,
			Version: "1",
		},
	}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	engine := Engine{
		Store: store, Platform: platform, Now: time.Now,
		ChartReference: "chart", ChartDigest: "sha256:chart",
		RequireLifecycleWriterEpoch: true,
		AuthorizeShutdown:           func(context.Context, State) error { return nil },
	}

	_, err := engine.Prepare(
		context.Background(),
		"staging",
		"next-release",
		"next-image",
		[]byte("next-bundle"),
	)
	if err == nil || !strings.Contains(err.Error(), `active release "lifecycle-v1"`) {
		t.Fatalf("unsettled acquire terminal state was replaceable: state=%#v err=%v", store.record.State, err)
	}
	if store.record.State.ReleaseID != "lifecycle-v1" ||
		store.record.State.LifecycleWriterEpoch.FencingToken != token {
		t.Fatalf("replacement lost the durable acquire intent: %#v", store.record.State)
	}
}

func TestNonTransactionalAttemptPersistsRepairFacts(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	plan := testPlan(t, ModeOnline)
	plan.PendingSteps[0].Execution.Transactional = false
	plan.PendingSteps[0].Execution.Idempotent = true
	plan.PendingSteps[0].Postconditions = []string{"statement-a", "ledger"}
	plan.PendingSteps[0].Repair = "repair_exact_statement_then_retry"
	platform := &fakePlatform{plan: plan}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}
	if _, err := engine.Prepare(ctx, "staging", "r1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	state, err := engine.Migrate(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var facts []MigrationAttemptFact
	for _, attempt := range state.Attempts {
		if attempt.Stage == "online" {
			facts = attempt.MigrationFacts
		}
	}
	if len(facts) != 1 || facts[0].Repair != "repair_exact_statement_then_retry" || !slices.Equal(facts[0].Postconditions, []string{"statement-a", "ledger"}) {
		t.Fatalf("missing partial-apply facts: %#v", facts)
	}
}
func (f *fakePlatform) StartJob(_ context.Context, j JobSpec) error {
	f.jobs = append(f.jobs, j)
	if f.fail == "provider" {
		return errors.New("provider unavailable")
	}
	return nil
}
func (f *fakePlatform) AbortAttempts(context.Context, State) error {
	f.abortCalls++
	f.callOrder = append(f.callOrder, "abort")
	return f.abortErr
}
func (f *fakePlatform) AttemptStatus(context.Context, State, JobAttempt) (string, error) {
	f.attemptStatusCalls++
	if f.attemptStatusErr != nil {
		return "", f.attemptStatusErr
	}
	if len(f.attemptStatuses) > 0 {
		status := f.attemptStatuses[0]
		f.attemptStatuses = f.attemptStatuses[1:]
		return status, nil
	}
	if f.attemptStatus == "" {
		return "missing", nil
	}
	return f.attemptStatus, nil
}

func TestResumeForwardUsesLatestNonCompleteAttempt(t *testing.T) {
	ctx := context.Background()
	plan := testPlan(t, ModeExclusive)
	state := NewState("staging", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseForwardOnly
	state.ForwardPhase = PhaseCutover
	state.CutoverMayHaveStarted = true
	state.RequiredMode = ModeExclusive
	state.ManifestDigest = plan.ManifestDigest
	state.InitialPending = plan.CorePending()
	state.CurrentPending = plan.CorePending()
	state.Attempts = []JobAttempt{
		{Stage: "cutover", Attempt: 1, Name: JobName(state.ReleaseID, "cutover", 1), Status: "failed", AllowedStepIDs: plan.PendingMigrationPhases("exclusive")},
		{Stage: "cutover", Attempt: 2, Name: JobName(state.ReleaseID, "cutover", 2), Status: "pending", AllowedStepIDs: plan.PendingMigrationPhases("exclusive")},
	}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{plan: plan, attemptStatus: "failed"}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	if _, err := engine.ResumeForward(ctx, "release-1", PhaseCutover); err != nil {
		t.Fatal(err)
	}
	got, err := engine.Migrate(ctx)
	if err != nil || got.Phase != PhaseApplying || platform.attemptStatusCalls != 0 {
		t.Fatalf("latest attempt resume = %#v, %v; status calls=%d", got, err, platform.attemptStatusCalls)
	}
	if got.Attempts[0].Status != "failed" || got.Attempts[1].Status != "complete" || len(platform.jobs) != 1 || platform.jobs[0].Name != state.Attempts[1].Name {
		t.Fatalf("resume did not preserve attempt ordering: state=%#v jobs=%#v", got.Attempts, platform.jobs)
	}
}
func (f *fakePlatform) Quiesce(context.Context, State) (int, error) {
	f.quiesced = true
	if f.fail == "quiesce" {
		return 0, errors.New("partial quiesce")
	}
	return 2, nil
}
func (f *fakePlatform) Apply(context.Context, State) (ApplyEvidence, error) {
	f.applied = true
	if f.applyEvidence.HelmRevision != 0 {
		return f.applyEvidence, nil
	}
	return ApplyEvidence{ManifestDigest: "sha256:apply", HelmRevision: 3}, nil
}
func (f *fakePlatform) Verify(context.Context, State) (ApplyEvidence, error) {
	f.verified = true
	f.callOrder = append(f.callOrder, "verify")
	return ApplyEvidence{HelmRevision: 4}, nil
}
func (f *fakePlatform) Restore(context.Context, State) error {
	if f.cleanupDeletesSnapshot && !f.snapshotCandidateAvailable {
		return errors.New("snapshot candidate was garbage collected")
	}
	f.restored = true
	f.restoreCalls++
	f.callOrder = append(f.callOrder, "restore")
	return nil
}
func (f *fakePlatform) Cleanup(context.Context, State) error {
	f.cleanupCalls++
	if f.fail == "cleanup" {
		return errors.New("cleanup failed")
	}
	if f.cleanupDeletesSnapshot {
		f.snapshotCandidateAvailable = false
	}
	return nil
}

func TestPrepareStopsBeforeAnyMutationWhenHelmPreflightFails(t *testing.T) {
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline), fail: "preflight"}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	if _, err := engine.Prepare(context.Background(), "staging", "release-1", "image", []byte("bundle")); err == nil || !strings.Contains(err.Error(), "helm preflight before release mutation") {
		t.Fatalf("invalid Helm values reached release mutation: %v", err)
	}
	if store.exists || len(platform.jobs) != 0 || !slices.Equal(platform.callOrder, []string{"preflight"}) {
		t.Fatalf("preflight failure mutated release facts: store=%v jobs=%#v calls=%#v", store.exists, platform.jobs, platform.callOrder)
	}
}

func TestPrepareStopsBeforeBundleAndStateMutationWhenHelmReleaseIsUnavailable(t *testing.T) {
	store := &memoryStore{}
	platform := &fakePlatform{
		plan:                   testPlan(t, ModeOnline),
		currentHelmRevisionErr: errors.New("Helm release comma has no deployed baseline; bootstrap is required"),
	}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	_, err := engine.Prepare(context.Background(), "staging", "release-1", "image", []byte("bundle"))
	if err == nil || !strings.Contains(err.Error(), "bootstrap is required") {
		t.Fatalf("missing Helm baseline error = %v", err)
	}
	if store.exists || store.updateCalls != 0 || platform.ensureBundleCalls != 0 || len(platform.jobs) != 0 {
		t.Fatalf("missing Helm baseline mutated release: store=%v updates=%d bundles=%d jobs=%#v", store.exists, store.updateCalls, platform.ensureBundleCalls, platform.jobs)
	}
	if !slices.Equal(platform.callOrder, []string{"preflight", "helm-status"}) {
		t.Fatalf("calls before Helm baseline rejection = %#v", platform.callOrder)
	}
}

func TestPrepareExistingStateRequiresDeployedHelmBeforeAnyMutationOrTerminalReturn(t *testing.T) {
	for _, phase := range []Phase{PhasePrepared, PhaseSucceeded} {
		t.Run(string(phase), func(t *testing.T) {
			bundle := []byte("bundle")
			state := NewState("staging", "release-1", "image", 7, time.Unix(1, 0))
			state.Phase = phase
			state.BundleName = BundleName(bundle)
			store := &memoryStore{exists: true, record: Record{State: state, Version: "1"}}
			platform := &fakePlatform{currentHelmRevisionErr: errors.New("Helm release comma must be bootstrapped before coordinator mutation")}
			engine := Engine{Store: store, Platform: platform, Now: time.Now}

			_, err := engine.Prepare(context.Background(), state.Environment, state.ReleaseID, state.Image, bundle)
			if err == nil || !strings.Contains(err.Error(), "must be bootstrapped") {
				t.Fatalf("existing %s release without Helm error = %v", phase, err)
			}
			if store.updateCalls != 0 || platform.ensureBundleCalls != 0 || len(platform.jobs) != 0 || store.record.Version != "1" {
				t.Fatalf("existing %s release mutated without Helm: updates=%d bundles=%d jobs=%#v record=%#v", phase, store.updateCalls, platform.ensureBundleCalls, platform.jobs, store.record)
			}
		})
	}
}

func TestEngineOnlineOnlyNeverQuiesces(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	e := Engine{Store: store, Platform: platform, Now: func() time.Time { return time.Unix(1, 0) }}
	if _, err := e.Prepare(ctx, "staging", "r1", "image", []byte("bundle")); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Migrate(ctx); err != nil {
		t.Fatal(err)
	}
	if platform.quiesced {
		t.Fatal("online release quiesced")
	}
	applied, err := e.Apply(ctx)
	if err != nil {
		t.Fatal(err)
	}
	if applied.ApplyEvidence == nil || applied.ApplyEvidence.ManifestDigest != "sha256:apply" {
		t.Fatalf("apply evidence was not persisted: %#v", applied.ApplyEvidence)
	}
	s, err := e.Verify(ctx)
	if err != nil || s.Phase != PhaseSucceeded {
		t.Fatalf("%#v %v", s, err)
	}
	if _, err := e.SyncProvider(ctx); err != nil {
		t.Fatal(err)
	}
}

func TestVerifyPersistsSucceededBeforeCandidateCleanup(t *testing.T) {
	ctx := context.Background()
	state := NewState("staging", "release-1", "image", 1, time.Now())
	state.Phase = PhaseVerifying
	state.Helm.SnapshotRevision = 20
	store := &memoryStore{
		exists:       true,
		record:       Record{Version: "1", State: state},
		failUpdateAt: 1,
	}
	platform := &fakePlatform{
		cleanupDeletesSnapshot:     true,
		snapshotCandidateAvailable: true,
	}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	if _, err := engine.Verify(ctx); err == nil || !strings.Contains(err.Error(), "injected state update failure") {
		t.Fatalf("verify state update failure = %v", err)
	}
	if platform.cleanupCalls != 0 || !platform.snapshotCandidateAvailable {
		t.Fatalf("candidate cleanup ran before terminal state was durable: calls=%d available=%v", platform.cleanupCalls, platform.snapshotCandidateAvailable)
	}
	recovered, err := engine.Recover(ctx, "release-1")
	if err != nil || recovered.Phase != PhaseRecovered || !platform.restored {
		t.Fatalf("recover after terminal save failure = %#v, %v; platform=%#v", recovered, err, platform)
	}
}

func TestCleanupFailureLeavesDurableSuccessAndRecoveryIsNoop(t *testing.T) {
	ctx := context.Background()
	state := NewState("staging", "release-1", "image", 1, time.Now())
	state.Phase = PhaseVerifying
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{fail: "cleanup"}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	got, err := engine.Verify(ctx)
	if err == nil || !strings.Contains(err.Error(), "cleanup succeeded release") || got.Phase != PhaseSucceeded || store.record.State.Phase != PhaseSucceeded {
		t.Fatalf("cleanup failure lost durable success: state=%#v durable=%#v err=%v", got, store.record.State, err)
	}
	recovered, err := engine.Recover(ctx, "release-1")
	if err != nil || recovered.Phase != PhaseSucceeded || platform.restored {
		t.Fatalf("terminal recovery should be a no-op: state=%#v err=%v restored=%v", recovered, err, platform.restored)
	}
}

func TestEngineCutoverFailureIsForwardOnly(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeExclusive), fail: "cutover"}
	e := Engine{AuthorizeShutdown: func(context.Context, State) error { return nil }, Store: store, Platform: platform, Now: time.Now}
	_, _ = e.Prepare(ctx, "staging", "r1", "image", []byte("bundle"))
	if _, err := e.Migrate(ctx); err == nil {
		t.Fatal("expected cutover failure")
	}
	s, err := e.Recover(ctx, "r1")
	if err != nil || s.Phase != PhaseForwardOnly || !platform.restored {
		t.Fatalf("%#v %v", s, err)
	}
}

func TestEngineOnlineFailureDoesNotRewriteUnchangedServingSnapshot(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline), fail: "online"}
	e := Engine{Store: store, Platform: platform, Now: time.Now}
	_, _ = e.Prepare(ctx, "staging", "r1", "image", []byte("bundle"))
	_, _ = e.Migrate(ctx)
	s, err := e.Recover(ctx, "r1")
	if err != nil || s.Phase != PhaseRecovered || platform.restored {
		t.Fatalf("%#v %v", s, err)
	}
}

func TestPrepareIsIdempotentAfterResponseLoss(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	e := Engine{Store: store, Platform: platform, Now: time.Now}
	first, err := e.Prepare(ctx, "staging", "r1", "image", []byte("bundle"))
	if err != nil {
		t.Fatal(err)
	}
	second, err := e.Prepare(ctx, "staging", "r1", "image", []byte("bundle"))
	if err != nil {
		t.Fatal(err)
	}
	if first.ReleaseID != second.ReleaseID || second.Phase != PhasePlanned {
		t.Fatalf("%#v", second)
	}
	if _, err = e.Prepare(ctx, "staging", "r2", "other", []byte("bundle")); err == nil {
		t.Fatal("concurrent release was accepted")
	}
}

func TestPrepareRejectsBundleDriftForActiveRelease(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline)}
	e := Engine{Store: store, Platform: platform, Now: time.Now}
	if _, err := e.Prepare(ctx, "staging", "r1", "image", []byte("bundle-a")); err != nil {
		t.Fatal(err)
	}
	if _, err := e.Prepare(ctx, "staging", "r1", "image", []byte("bundle-b")); err == nil {
		t.Fatal("active release accepted different candidate bundle")
	}
}

func TestFailedStageGetsExplicitNewAttempt(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeOnline), fail: "online"}
	e := Engine{Store: store, Platform: platform, Now: time.Now}
	_, _ = e.Prepare(ctx, "staging", "r1", "image", []byte("bundle"))
	if _, err := e.Migrate(ctx); err == nil {
		t.Fatal("expected first failure")
	}
	platform.fail = ""
	state, err := e.Migrate(ctx)
	if err != nil {
		t.Fatal(err)
	}
	var online []JobAttempt
	for _, attempt := range state.Attempts {
		if attempt.Stage == "online" {
			online = append(online, attempt)
		}
	}
	if len(online) != 2 || online[0].Status != "failed" || online[1].Attempt != 2 || online[1].Status != "complete" {
		t.Fatalf("%#v", state.Attempts)
	}
}

func TestPendingAttemptIsResumedAfterRunnerLoss(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{exists: true}
	store.record = Record{Version: "1", State: State{
		ReleaseID: "r1", Image: "image", BundleName: "bundle", ManifestDigest: "digest",
		Attempts: []JobAttempt{{Stage: "online", Attempt: 1, Name: "comma-release-r1-online-1", Status: "pending", AllowedStepIDs: []string{"schema-1"}}},
	}}
	platform := &fakePlatform{}
	e := Engine{Store: store, Platform: platform, Now: time.Now}
	record := store.record
	if err := e.runStage(ctx, &record, "online", nil, testPlan(t, ModeOnline)); err != nil {
		t.Fatal(err)
	}
	if len(record.State.Attempts) != 1 || record.State.Attempts[0].Status != "complete" {
		t.Fatalf("pending attempt was not reused: %#v", record.State.Attempts)
	}
	if len(platform.jobs) != 1 || platform.jobs[0].Name != "comma-release-r1-online-1" || len(platform.jobs[0].AllowedStepIDs) != 1 {
		t.Fatalf("wrong resumed job: %#v", platform.jobs)
	}
}

func TestIndependentRecoveryWakeupConvergesAfterRunnerLossInEveryPhase(t *testing.T) {
	tests := []struct {
		name              string
		phase             Phase
		cutoverMayStarted bool
		wantPhase         Phase
		wantRestore       bool
	}{
		{name: "plan", phase: PhasePrepared, wantPhase: PhaseRecovered},
		{name: "schema", phase: PhaseOnline, wantPhase: PhaseRecovered},
		{name: "quiesce", phase: PhaseQuiescing, wantPhase: PhaseRecovered, wantRestore: true},
		{name: "cutover", phase: PhaseCutover, cutoverMayStarted: true, wantPhase: PhaseForwardOnly, wantRestore: true},
		{name: "apply online", phase: PhaseApplying, wantPhase: PhaseRecovered, wantRestore: true},
		{name: "apply after cutover", phase: PhaseApplying, cutoverMayStarted: true, wantPhase: PhaseForwardOnly, wantRestore: true},
		{name: "rollout online", phase: PhaseVerifying, wantPhase: PhaseRecovered, wantRestore: true},
		{name: "rollout after cutover", phase: PhaseVerifying, cutoverMayStarted: true, wantPhase: PhaseForwardOnly, wantRestore: true},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			state := NewState(
				"staging",
				"runner-loss",
				"image",
				1,
				time.Unix(1, 0),
			)
			state.Phase = tc.phase
			state.CutoverMayHaveStarted = tc.cutoverMayStarted
			if tc.phase == PhasePrepared {
				state.Attempts = []JobAttempt{{Stage: "plan", Attempt: 1, Name: JobName(state.ReleaseID, "plan", 1), Status: "pending"}}
			}
			if tc.phase == PhaseOnline {
				state.Attempts = []JobAttempt{{Stage: "online", Attempt: 1, Name: JobName(state.ReleaseID, "online", 1), Status: "pending"}}
			}
			store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
			platform := &fakePlatform{}

			// Model a separately scheduled watchdog process: it owns no state from the
			// vanished runner and can only load the durable record and call Recover.
			wakeup := Engine{Store: store, Platform: platform, Now: func() time.Time { return time.Unix(2, 0) }}
			got, err := wakeup.Recover(context.Background(), "runner-loss")
			if err != nil || got.Phase != tc.wantPhase {
				t.Fatalf("recovery = %#v, %v; want phase %s", got, err, tc.wantPhase)
			}
			if tc.wantPhase == PhaseForwardOnly && got.ForwardPhase != tc.phase {
				t.Fatalf("forward phase = %s, want %s", got.ForwardPhase, tc.phase)
			}
			if platform.restored != tc.wantRestore {
				t.Fatalf("snapshot restore = %v, want %v", platform.restored, tc.wantRestore)
			}
			wantRestoreCalls := 0
			if tc.wantRestore {
				wantRestoreCalls = 1
			}
			if platform.restoreCalls != wantRestoreCalls {
				t.Fatalf("snapshot restore calls = %d, want %d", platform.restoreCalls, wantRestoreCalls)
			}
			persisted, err := store.Load(context.Background())
			if err != nil || persisted.State.Phase != tc.wantPhase || persisted.State.ReleaseID != "runner-loss" || persisted.State.CutoverMayHaveStarted != tc.cutoverMayStarted {
				t.Fatalf("terminal recovery state was not durable: %#v, %v", persisted.State, err)
			}
			if len(platform.jobs) != 0 || platform.applied || platform.verified {
				t.Fatalf("recovery executed a release stage: %#v", platform)
			}
			wantAbortCalls := 1
			if tc.wantPhase == PhaseForwardOnly {
				wantAbortCalls = 0
			}
			if platform.abortCalls != wantAbortCalls {
				t.Fatalf("abort calls = %d, want %d", platform.abortCalls, wantAbortCalls)
			}

			secondWakeup := Engine{Store: store, Platform: platform, Now: func() time.Time { return time.Unix(3, 0) }}
			again, err := secondWakeup.Recover(context.Background(), "runner-loss")
			if err != nil || again.Phase != tc.wantPhase || platform.restoreCalls != wantRestoreCalls {
				t.Fatalf("repeated wakeup = %#v, %v; restore calls = %d", again, err, platform.restoreCalls)
			}
		})
	}
}

func TestResumeForwardReusesExactInterruptedCutoverPhase(t *testing.T) {
	ctx := context.Background()
	plan := testPlan(t, ModeExclusive)
	state := NewState("staging", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseForwardOnly
	state.ForwardPhase = PhaseCutover
	state.CutoverMayHaveStarted = true
	state.RequiredMode = ModeExclusive
	state.ManifestDigest = plan.ManifestDigest
	state.InitialPending = plan.CorePending()
	state.CurrentPending = plan.CorePending()
	state.Attempts = []JobAttempt{{Stage: "cutover", Attempt: 1, Name: JobName(state.ReleaseID, "cutover", 1), Status: "failed", AllowedStepIDs: plan.PendingMigrationPhases("exclusive")}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{plan: plan, attemptStatus: "complete"}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	resumed, err := engine.ResumeForward(ctx, "release-1", PhaseCutover)
	if err != nil || resumed.Phase != PhaseCutover || resumed.ForwardPhase != "" {
		t.Fatalf("resume forward = %#v, %v", resumed, err)
	}
	got, err := engine.Migrate(ctx)
	if err != nil || got.Phase != PhaseApplying || got.Attempts[0].Status != "complete" {
		t.Fatalf("resumed cutover = %#v, %v", got, err)
	}
	if len(platform.jobs) != 1 || platform.jobs[0].Name != state.Attempts[0].Name {
		t.Fatalf("resume did not reuse the deterministic attempt: %#v", platform.jobs)
	}
}

func TestResumeForwardRejectsWrongPhaseWithoutMutation(t *testing.T) {
	state := NewState("staging", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseForwardOnly
	state.ForwardPhase = PhaseCutover
	state.CutoverMayHaveStarted = true
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	engine := Engine{Store: store, Platform: &fakePlatform{}, Now: time.Now}
	if _, err := engine.ResumeForward(context.Background(), "release-1", PhaseApplying); err == nil {
		t.Fatal("wrong forward phase was accepted")
	}
	persisted, _ := store.Load(context.Background())
	if persisted.State.Phase != PhaseForwardOnly || persisted.State.ForwardPhase != PhaseCutover {
		t.Fatalf("wrong resume mutated state: %#v", persisted.State)
	}
}

func TestProviderFailureIsIndependentOfCoreSucceeded(t *testing.T) {
	providerPlan := Plan{SchemaVersion: 2, ManifestDigest: "sha256:" + strings.Repeat("a", 64), RequiredMode: ModeOnline, ProviderPendingIDs: []string{"billing-provider"}}
	plan := providerPlan
	if err := plan.Validate(); err != nil {
		t.Fatal(err)
	}
	state := NewState("staging", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseSucceeded
	state.RequiredMode = ModeOnline
	state.ManifestDigest = plan.ManifestDigest
	state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{plan: plan, fail: "provider"}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	got, err := engine.SyncProvider(context.Background())
	if err != nil || got.Phase != PhaseSucceeded || got.Provider.Status != "degraded" {
		t.Fatalf("provider failure changed core result = %#v, %v", got, err)
	}
}

func TestProviderRetryEventuallyConvergesWithoutReopeningCore(t *testing.T) {
	plan := Plan{SchemaVersion: 2, ManifestDigest: "sha256:" + strings.Repeat("a", 64), RequiredMode: ModeOnline, ProviderPendingIDs: []string{"billing-provider"}}
	if err := plan.Validate(); err != nil {
		t.Fatal(err)
	}
	state := NewState("staging", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseSucceeded
	state.ManifestDigest = plan.ManifestDigest
	state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{plan: plan}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}
	running, err := engine.SyncProvider(context.Background())
	if err != nil || running.Provider.Status != "running" || running.Provider.Attempt != 1 {
		t.Fatalf("dispatch = %#v %v", running.Provider, err)
	}
	platform.attemptStatus = "failed"
	retried, err := engine.SyncProvider(context.Background())
	if err != nil || retried.Phase != PhaseSucceeded || retried.Provider.Status != "running" || retried.Provider.Attempt != 2 {
		t.Fatalf("retry = %#v %v", retried, err)
	}
	platform.attemptStatus = "complete"
	complete, err := engine.SyncProvider(context.Background())
	if err != nil || complete.Phase != PhaseSucceeded || complete.Provider.Status != "succeeded" {
		t.Fatalf("convergence = %#v %v", complete, err)
	}
}

func TestReconcileOwnsProviderCompletionUntilTerminal(t *testing.T) {
	plan := Plan{SchemaVersion: 2, ManifestDigest: "sha256:" + strings.Repeat("a", 64), RequiredMode: ModeOnline, ProviderPendingIDs: []string{"billing-provider"}}
	state := NewState("production", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseSucceeded
	state.ManifestDigest = plan.ManifestDigest
	state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{plan: plan, attemptStatuses: []string{"active", "complete"}}
	now := time.Unix(10, 0)
	engine := Engine{Store: store, Platform: platform, Now: func() time.Time { return now }, ProviderPoll: time.Second,
		ProviderWait: func(context.Context, time.Duration) error { now = now.Add(time.Second); return nil }}

	got, err := engine.Reconcile(context.Background())
	if err != nil || got.Phase != PhaseSucceeded || got.Provider.Status != "succeeded" || got.Provider.Attempt != 1 {
		t.Fatalf("automatic provider completion = %#v, %v", got, err)
	}
	if len(platform.jobs) != 1 || platform.attemptStatusCalls != 2 {
		t.Fatalf("provider cardinality = jobs=%#v statusCalls=%d", platform.jobs, platform.attemptStatusCalls)
	}
}

func TestReconcileSucceededReleasesActiveEpochWithoutRepeatingCleanup(t *testing.T) {
	plan := Plan{SchemaVersion: 2, ManifestDigest: "sha256:" + strings.Repeat("a", 64), RequiredMode: ModeOnline, ProviderPendingIDs: []string{"billing-provider"}}
	now := time.Unix(10, 0).UTC()
	state := NewState("production", "release-1", "image", 1, now)
	state.Phase = PhaseSucceeded
	state.ManifestDigest = plan.ManifestDigest
	state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
	state.LifecycleWriterEpoch = &LifecycleWriterEpochFacts{
		Required: true, Status: "active", Generation: 1,
		FencingToken: strings.Repeat("a", 64), LeaseExpiresAt: now.Add(time.Minute),
		DrainedAt: now, LastInventoryAt: now,
	}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{plan: plan, attemptStatus: "complete"}
	engine := Engine{
		Store: store, Platform: platform, Now: func() time.Time { return now },
		ProviderWait: func(context.Context, time.Duration) error { return nil },
	}

	got, err := engine.Reconcile(context.Background())
	if err != nil || got.Phase != PhaseSucceeded || got.Provider.Status != "succeeded" {
		t.Fatalf("succeeded reconcile = %#v, %v", got, err)
	}
	if got.LifecycleWriterEpoch == nil || got.LifecycleWriterEpoch.Status != "released" {
		t.Fatalf("active terminal lifecycle epoch was not released: %#v", got.LifecycleWriterEpoch)
	}
	if platform.cleanupCalls != 0 || len(platform.jobs) != 1 {
		t.Fatalf("succeeded reconcile repeated cleanup or skipped provider: cleanup=%d jobs=%#v", platform.cleanupCalls, platform.jobs)
	}
}

func TestReconcileRetriesFailedProviderWithinBoundedWindow(t *testing.T) {
	state := NewState("production", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseSucceeded
	state.ManifestDigest = "sha256:" + strings.Repeat("a", 64)
	state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{attemptStatuses: []string{"failed", "complete"}}
	now := time.Unix(10, 0)
	engine := Engine{Store: store, Platform: platform, Now: func() time.Time { return now }, ProviderPoll: time.Second,
		ProviderWait: func(context.Context, time.Duration) error { now = now.Add(time.Second); return nil }}

	got, err := engine.Reconcile(context.Background())
	if err != nil || got.Provider.Status != "succeeded" || got.Provider.Attempt != 2 || got.Phase != PhaseSucceeded {
		t.Fatalf("automatic provider retry = %#v, %v", got, err)
	}
	if len(platform.jobs) != 2 || platform.jobs[0].Name == platform.jobs[1].Name {
		t.Fatalf("provider retries were not deterministic distinct attempts: %#v", platform.jobs)
	}
}

func TestProviderTimeoutDegradesWithoutChangingCore(t *testing.T) {
	state := NewState("production", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseSucceeded
	state.ManifestDigest = "sha256:" + strings.Repeat("a", 64)
	state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{attemptStatus: "active"}
	now := time.Unix(10, 0)
	engine := Engine{Store: store, Platform: platform, Now: func() time.Time { return now }, ProviderPoll: time.Second, ProviderBudget: 2 * time.Second,
		ProviderWait: func(context.Context, time.Duration) error { now = now.Add(time.Second); return nil }}

	got, err := engine.Reconcile(context.Background())
	if err != nil || got.Phase != PhaseSucceeded || got.Provider.Status != "degraded" || !strings.Contains(got.Provider.LastError, "bounded window") {
		t.Fatalf("provider timeout = %#v, %v", got, err)
	}
	if len(platform.jobs) != 1 {
		t.Fatalf("provider timeout created %d jobs, want 1", len(platform.jobs))
	}
}

func TestProviderCancellationLeavesDurableAttemptForNextReconcile(t *testing.T) {
	state := NewState("production", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseSucceeded
	state.ManifestDigest = "sha256:" + strings.Repeat("a", 64)
	state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{attemptStatus: "active"}
	engine := Engine{Store: store, Platform: platform, Now: time.Now, ProviderPoll: time.Second,
		ProviderWait: func(context.Context, time.Duration) error { return context.Canceled }}

	interrupted, err := engine.Reconcile(context.Background())
	if !errors.Is(err, context.Canceled) || interrupted.Phase != PhaseSucceeded || interrupted.Provider.Status != "running" || interrupted.Provider.JobName == "" {
		t.Fatalf("provider cancellation = %#v, %v", interrupted, err)
	}
	platform.attemptStatus = "complete"
	platform.jobs = nil
	restarted := Engine{Store: store, Platform: platform, Now: time.Now, ProviderWait: func(context.Context, time.Duration) error { return nil }}
	complete, err := restarted.Reconcile(context.Background())
	if err != nil || complete.Provider.Status != "succeeded" || len(platform.jobs) != 0 {
		t.Fatalf("provider restart did not resume exact Job: %#v, %v jobs=%#v", complete, err, platform.jobs)
	}
}

func TestProviderRetryLimitIsPerReconcileWakeup(t *testing.T) {
	state := NewState("production", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseSucceeded
	state.ManifestDigest = "sha256:" + strings.Repeat("a", 64)
	state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{attemptStatus: "failed"}
	engine := Engine{Store: store, Platform: platform, Now: time.Now, ProviderRetries: 2,
		ProviderWait: func(context.Context, time.Duration) error { return nil }}

	first, err := engine.Reconcile(context.Background())
	if err != nil || first.Provider.Status != "degraded" || first.Provider.Attempt != 2 || first.Phase != PhaseSucceeded {
		t.Fatalf("first bounded retries = %#v, %v", first, err)
	}
	platform.attemptStatus = "complete"
	second, err := engine.Reconcile(context.Background())
	if err != nil || second.Provider.Status != "succeeded" || second.Provider.Attempt != 3 || second.Phase != PhaseSucceeded {
		t.Fatalf("later reconcile retry = %#v, %v", second, err)
	}
}

func TestRecoverAbortsAttemptsBeforeRestoringSnapshot(t *testing.T) {
	state := NewState("staging", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseQuiescing
	state.Attempts = []JobAttempt{{Stage: "online", Attempt: 1, Name: JobName(state.ReleaseID, "online", 1), Status: "pending"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{}

	got, err := (Engine{Store: store, Platform: platform, Now: time.Now}).Recover(context.Background(), "release-1")
	if err != nil || got.Phase != PhaseRecovered || got.Attempts[0].Status != "aborted" {
		t.Fatalf("recovery = %#v, %v", got, err)
	}
	if !slices.Equal(platform.callOrder, []string{"abort", "restore"}) {
		t.Fatalf("recovery call order = %v", platform.callOrder)
	}
}

func TestRecoverDoesNotPersistTerminalStateWhenAbortFails(t *testing.T) {
	state := NewState("staging", "release-1", "image", 1, time.Unix(1, 0))
	state.Attempts = []JobAttempt{{Stage: "plan", Attempt: 1, Name: JobName(state.ReleaseID, "plan", 1), Status: "pending"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{abortErr: errors.New("delete failed")}

	if _, err := (Engine{Store: store, Platform: platform, Now: time.Now}).Recover(context.Background(), "release-1"); err == nil || !strings.Contains(err.Error(), "abort release attempts") {
		t.Fatalf("abort failure was not returned: %v", err)
	}
	persisted, _ := store.Load(context.Background())
	if persisted.State.Phase != PhaseRecovering || persisted.State.Attempts[0].Status != "pending" {
		t.Fatalf("failed abort persisted false recovery: %#v", persisted.State)
	}
}

func TestRecoveredStateStillConvergesPendingAttempt(t *testing.T) {
	state := NewState("staging", "release-1", "image", 1, time.Unix(1, 0))
	state.Phase = PhaseRecovered
	state.Attempts = []JobAttempt{{Stage: "plan", Attempt: 1, Name: JobName(state.ReleaseID, "plan", 1), Status: "pending"}}
	store := &memoryStore{exists: true, record: Record{Version: "1", State: state}}
	platform := &fakePlatform{}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}

	got, err := engine.Recover(context.Background(), "release-1")
	if err != nil || got.Attempts[0].Status != "aborted" || platform.abortCalls != 1 {
		t.Fatalf("recovered convergence = %#v, %v; abort calls=%d", got, err, platform.abortCalls)
	}
	if _, err = engine.Recover(context.Background(), "release-1"); err != nil || platform.abortCalls != 1 {
		t.Fatalf("idempotent recovered convergence failed: %v; abort calls=%d", err, platform.abortCalls)
	}
}

type planKubectlRunner struct {
	objects       map[string][]byte
	plans         map[string]Plan
	createdJobs   []string
	lostPlan1Once bool
}

type preflightBypassPlatform struct{ *KubectlPlatform }

func (p *preflightBypassPlatform) Preflight(context.Context, []byte) (string, error) {
	return "sha256:test-values", nil
}

func (p *preflightBypassPlatform) CurrentHelmRevision(context.Context) (int, error) {
	return 1, nil
}

func (r *planKubectlRunner) Run(_ context.Context, body []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "jsonpath={.data.bundle\\.json}") {
		return []byte(`{}`), nil
	}
	if strings.Contains(joined, " get ") {
		for _, arg := range args {
			if strings.HasPrefix(arg, "configmap/") || strings.HasPrefix(arg, "job/") {
				object, ok := r.objects[arg]
				if !ok {
					return nil, errors.New("NotFound")
				}
				return object, nil
			}
		}
		return nil, errors.New("NotFound")
	}
	if strings.Contains(joined, "create -f -") {
		var object struct {
			Kind     string `json:"kind"`
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		}
		if err := json.Unmarshal(body, &object); err != nil {
			return nil, err
		}
		key := strings.ToLower(object.Kind) + "/" + object.Metadata.Name
		r.objects[key] = append([]byte(nil), body...)
		if object.Kind == "Job" {
			r.createdJobs = append(r.createdJobs, object.Metadata.Name)
			if strings.HasSuffix(object.Metadata.Name, "-plan-1") && !r.lostPlan1Once {
				r.lostPlan1Once = true
				return nil, errors.New("connection lost after create")
			}
		}
		return nil, nil
	}
	if strings.Contains(joined, " wait ") {
		return nil, nil
	}
	if strings.Contains(joined, " logs ") {
		for _, arg := range args {
			if strings.HasPrefix(arg, "job/") {
				plan, ok := r.plans[strings.TrimPrefix(arg, "job/")]
				if !ok {
					return nil, errors.New("missing scripted plan")
				}
				return json.Marshal(plan)
			}
		}
	}
	return nil, errors.New("unexpected kubectl call: " + joined)
}

func TestEngineAndKubernetesAdapterReuseLostPlanAttemptThenAdvance(t *testing.T) {
	ctx := context.Background()
	ready := testPlan(t, ModeOnline)
	runner := &planKubectlRunner{
		objects: map[string][]byte{},
		plans: map[string]Plan{
			"comma-release-r1-plan-1": ready,
			"comma-release-r1-plan-2": ready,
		},
	}
	platform := &preflightBypassPlatform{KubectlPlatform: &KubectlPlatform{
		Kubectl: runner,
		Spec:    EnvironmentSpec{Namespace: "comma-staging"},
	}}
	store := &memoryStore{}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}
	bundle, err := json.Marshal(CandidateBundle{SchemaVersion: 1, Replacements: map[string]string{}})
	if err != nil {
		t.Fatal(err)
	}

	first, err := engine.Prepare(ctx, "staging", "r1", "image", bundle)
	if err != nil || first.Phase != PhasePlanned {
		t.Fatalf("first prepare: %#v %v", first, err)
	}
	second, err := engine.Prepare(ctx, "staging", "r1", "image", bundle)
	if err != nil || second.Phase != PhasePlanned {
		t.Fatalf("second prepare: %#v %v", second, err)
	}
	want := []string{"comma-release-r1-plan-1", "comma-release-r1-plan-2"}
	if !slices.Equal(runner.createdJobs, want) {
		t.Fatalf("plan jobs = %#v, want %#v", runner.createdJobs, want)
	}
}

func TestPartialQuiesceRestoresSnapshotAndRepeatedRecoverIsIdempotent(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{}
	platform := &fakePlatform{plan: testPlan(t, ModeExclusive), fail: "quiesce"}
	e := Engine{AuthorizeShutdown: func(context.Context, State) error { return nil }, Store: store, Platform: platform, Now: time.Now}
	_, _ = e.Prepare(ctx, "staging", "r1", "image", []byte("bundle"))
	if _, err := e.Migrate(ctx); err == nil {
		t.Fatal("expected partial quiesce failure")
	}
	first, err := e.Recover(ctx, "r1")
	if err != nil || first.Phase != PhaseRecovered || !platform.restored {
		t.Fatalf("%#v %v", first, err)
	}
	second, err := e.Recover(ctx, "r1")
	if err != nil || second.Phase != PhaseRecovered {
		t.Fatalf("repeated recover was not idempotent: %#v %v", second, err)
	}
}

func TestStaleRecoveryFenceCannotTouchANewerRelease(t *testing.T) {
	ctx := context.Background()
	store := &memoryStore{exists: true, record: Record{Version: "1", State: State{ReleaseID: "release-b", Phase: PhaseOnline}}}
	platform := &fakePlatform{}
	e := Engine{Store: store, Platform: platform, Now: time.Now}
	before := store.record
	if _, err := e.Recover(ctx, "release-a"); err == nil {
		t.Fatal("stale recovery was accepted")
	}
	if store.record.State.ReleaseID != before.State.ReleaseID || store.record.State.Phase != before.State.Phase || platform.restored {
		t.Fatalf("stale recovery mutated active release: %#v", store.record.State)
	}
}
