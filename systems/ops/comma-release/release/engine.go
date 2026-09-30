package release

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"time"
)

type JobSpec struct {
	Name, Stage, Image, ManifestDigest string
	BundleName                         string
	Attempt                            int
	AllowedStepIDs                     []string
	Fence                              string
	LifecycleEpoch                     *LifecycleEpochSpec
	RuntimeRelease                     *State
}

type Platform interface {
	Preflight(context.Context, []byte) (string, error)
	CurrentHelmRevision(context.Context) (int, error)
	EnsureBundle(context.Context, string, []byte) (string, error)
	RunPlan(context.Context, State) (Plan, error)
	RunJob(context.Context, JobSpec) error
	StartJob(context.Context, JobSpec) error
	AttemptStatus(context.Context, State, JobAttempt) (string, error)
	AbortAttempts(context.Context, State) error
	RunLifecycleEpoch(context.Context, LifecycleEpochSpec) (LifecycleEpochEvidence, error)
	VerifyLifecycleV1(context.Context, State) error
	Quiesce(context.Context, State) (int, error)
	Apply(context.Context, State) (ApplyEvidence, error)
	Verify(context.Context, State) (ApplyEvidence, error)
	Restore(context.Context, State) error
	Cleanup(context.Context, State) error
}

type Engine struct {
	Store                       StateStore
	Platform                    Platform
	Now                         func() time.Time
	ProviderWait                func(context.Context, time.Duration) error
	ProviderPoll                time.Duration
	ProviderBudget              time.Duration
	ProviderRetries             int
	ChartReference              string
	ChartDigest                 string
	RequireLifecycleWriterEpoch bool
	LifecycleEpochLease         time.Duration
	AuthorizeShutdown           func(context.Context, State) error
}

func (e Engine) Prepare(ctx context.Context, environment, releaseID, image string, bundle []byte) (State, error) {
	return e.prepare(ctx, false, environment, releaseID, image, bundle)
}

func (e Engine) PrepareLegacyUpgrade(ctx context.Context, environment, releaseID, image string, bundle []byte) (State, error) {
	if e.RequireLifecycleWriterEpoch {
		return State{}, errors.New("legacy upgrade cannot be combined with the Session lifecycle hard cut")
	}
	return e.prepare(ctx, true, environment, releaseID, image, bundle)
}

func (e Engine) prepare(ctx context.Context, legacyUpgrade bool, environment, releaseID, image string, bundle []byte) (State, error) {
	if environment == "" || releaseID == "" || image == "" {
		return State{}, errors.New("environment, release id, and image are required")
	}
	valuesDigest, err := e.Platform.Preflight(ctx, bundle)
	if err != nil {
		return State{}, fmt.Errorf("helm preflight before release mutation: %w", err)
	}
	snapshotRevision, err := e.Platform.CurrentHelmRevision(ctx)
	if err != nil {
		return State{}, err
	}
	existing, loadErr := e.Store.Load(ctx)
	if loadErr == nil && existing.State.Phase == PhaseForwardOnly {
		return existing.State, errors.New("release requires explicit phase-specific --resume-forward repair before a new prepare")
	}
	existingLegacyUpgrade := loadErr == nil && existing.State.RequiredMode == ModeBlockedLegacy
	legacyContinuation := existingLegacyUpgrade && existing.State.Phase == PhaseForwardOnly
	if loadErr == nil && existingLegacyUpgrade == legacyUpgrade && existing.State.ReleaseID == releaseID && existing.State.Environment == environment && existing.State.Image == image && replaceableTerminal(existing.State) {
		if existing.State.Artifacts.ChartReference != e.ChartReference || existing.State.Artifacts.ChartDigest != e.ChartDigest {
			return State{}, errors.New("immutable chart identity drift for completed release")
		}
		return existing.State, nil
	}
	if loadErr == nil && !replaceableTerminal(existing.State) {
		if existingLegacyUpgrade != legacyUpgrade {
			return State{}, fmt.Errorf("active release legacy-upgrade mode does not match the requested operation")
		}
		if existing.State.ReleaseID != releaseID || existing.State.Environment != environment || existing.State.Image != image {
			return State{}, fmt.Errorf("active release %q already owns %s", existing.State.ReleaseID, environment)
		}
		bundleName := BundleName(bundle)
		if existing.State.BundleName != bundleName {
			return State{}, errors.New("candidate bundle drift for active release")
		}
		if existing.State.Artifacts.ChartReference != e.ChartReference || existing.State.Artifacts.ChartDigest != e.ChartDigest {
			return State{}, errors.New("immutable chart identity drift for active release")
		}
		existingRequiresEpoch := existing.State.LifecycleWriterEpoch != nil &&
			existing.State.LifecycleWriterEpoch.Required
		if existingRequiresEpoch != e.RequireLifecycleWriterEpoch {
			return State{}, errors.New("session lifecycle hard-cut opt-in drift for active release")
		}
		actual, err := e.Platform.EnsureBundle(ctx, bundleName, bundle)
		if err != nil {
			return State{}, err
		}
		if actual != bundleName {
			return State{}, errors.New("content-addressed bundle name mismatch")
		}
		if existing.State.Phase != PhasePrepared && existing.State.Phase != PhasePlanned {
			return existing.State, nil
		}
		record := existing
		plan, err := e.runPlan(ctx, &record)
		if err != nil {
			return State{}, err
		}
		if err = validateLegacyUpgradeEntry(record.State, plan, legacyContinuation); err != nil {
			return State{}, err
		}
		next, err := Reduce(record.State, EventPlan, &plan, e.now())
		if err != nil {
			return State{}, err
		}
		record.State = next
		updated, err := e.Store.Update(ctx, record)
		return updated.State, err
	} else if loadErr != nil && !errors.Is(loadErr, ErrNotFound) {
		return State{}, loadErr
	}
	bundleName := BundleName(bundle)
	actual, err := e.Platform.EnsureBundle(ctx, bundleName, bundle)
	if err != nil {
		return State{}, err
	}
	if actual != bundleName {
		return State{}, errors.New("content-addressed bundle name mismatch")
	}
	state := NewState(environment, releaseID, image, snapshotRevision, e.now())
	if legacyUpgrade {
		state = NewLegacyUpgradeState(environment, releaseID, image, snapshotRevision, e.now())
	}
	if e.RequireLifecycleWriterEpoch {
		state.LifecycleWriterEpoch = &LifecycleWriterEpochFacts{Required: true}
	}
	state.Artifacts = ArtifactFacts{ImageDigest: image, ChartReference: e.ChartReference, ChartDigest: e.ChartDigest, ValuesDigest: valuesDigest}
	state.BundleName = bundleName
	var record Record
	if loadErr == nil {
		existing.State = state
		record, err = e.Store.Update(ctx, existing)
	} else {
		record, err = e.Store.Create(ctx, state)
	}
	if errors.Is(err, ErrConflict) {
		return State{}, errors.New("another release claimed the environment")
	}
	if err != nil {
		return State{}, err
	}
	plan, err := e.runPlan(ctx, &record)
	if err != nil {
		return State{}, err
	}
	if err = validateLegacyUpgradeEntry(record.State, plan, legacyContinuation); err != nil {
		return State{}, err
	}
	next, err := Reduce(record.State, EventPlan, &plan, e.now())
	if err != nil {
		return State{}, err
	}
	record.State = next
	updated, err := e.Store.Update(ctx, record)
	return updated.State, err
}

func validateLegacyUpgradeEntry(state State, plan Plan, continuation bool) error {
	if state.RequiredMode != ModeBlockedLegacy || state.ManifestDigest != "" {
		return nil
	}
	if len(plan.PendingLegacyUpgradeIDs()) == 0 && !continuation {
		return errors.New("legacy upgrade requires at least one pending audited Salix legacy step")
	}
	return nil
}

func BundleName(bundle []byte) string {
	sum := sha256.Sum256(bundle)
	return "comma-release-bundle-" + hex.EncodeToString(sum[:20])
}

func (e Engine) Migrate(ctx context.Context) (State, error) {
	record, err := e.Store.Load(ctx)
	if err != nil {
		return State{}, err
	}
	switch record.State.Phase {
	case PhaseApplying, PhaseVerifying, PhaseSucceeded:
		return record.State, nil
	case PhasePrepared, PhasePlanned, PhaseOnline, PhaseQuiescing, PhaseCutover:
	default:
		return State{}, invalid(record.State.Phase, EventOnlineStarted)
	}
	state := record.State
	plan, err := e.runPlan(ctx, &record)
	if err != nil {
		return State{}, err
	}
	state = record.State
	if state.Phase == PhasePrepared || state.Phase == PhasePlanned {
		state, err = Reduce(state, EventPlan, &plan, e.now())
	} else {
		err = state.ValidatePlan(plan)
		if err == nil {
			state.CurrentPending = plan.CorePending()
		}
	}
	if err != nil {
		return State{}, err
	}
	// Approval precedes online migrations and the writer fence. Recovery keeps its existing safety authority.
	if state.Environment == "staging" && (state.RequiredMode != ModeOnline || (state.LifecycleWriterEpoch != nil && state.LifecycleWriterEpoch.Required)) && !state.CutoverMayHaveStarted {
		if e.AuthorizeShutdown == nil {
			return state, errors.New("staging shutdown requires a human issue approval")
		}
		if err = e.AuthorizeShutdown(ctx, state); err != nil {
			return state, err
		}
	}
	record.State = state
	if record.State.Phase == PhasePlanned {
		record.State, err = Reduce(record.State, EventOnlineStarted, nil, e.now())
		if err != nil {
			return State{}, err
		}
		if record, err = e.Store.Update(ctx, record); err != nil {
			return State{}, err
		}
	}
	if record.State.Phase == PhaseOnline {
		onlineIDs := plan.PendingMigrationPhases("expand", "local_seed")
		onlineStage := "online"
		if record.State.RequiredMode == ModeBlockedLegacy {
			onlineStage = "legacy-online"
		}
		if err = e.runStage(ctx, &record, onlineStage, onlineIDs, plan); err != nil {
			return record.State, err
		}
		record.State.CurrentPending = without(record.State.CurrentPending, onlineIDs)
		record.State, err = Reduce(record.State, EventOnlineDone, nil, e.now())
		if err != nil {
			return State{}, err
		}
		if record, err = e.Store.Update(ctx, record); err != nil {
			return State{}, err
		}
	}
	if record.State.Phase == PhaseQuiescing {
		if err = e.ensureLifecycleEpochActive(ctx, &record); err != nil {
			return record.State, err
		}
		var revision int
		if revision, err = e.Platform.Quiesce(ctx, record.State); err != nil {
			return record.State, err
		}
		record.State.Helm.MaintenanceRevision = revision
		record.State.MaintenanceStartedAt = e.now().UTC()
		record.State.Helm.AppliedRevisions = append(record.State.Helm.AppliedRevisions, revision)
		if record, err = e.Store.Update(ctx, record); err != nil {
			return State{}, err
		}
		if err = e.assertLifecycleEpoch(ctx, &record); err != nil {
			return record.State, err
		}
		record.State, err = Reduce(record.State, EventQuiesced, nil, e.now())
		if err != nil {
			return State{}, err
		}
		if record, err = e.Store.Update(ctx, record); err != nil {
			return State{}, err
		}
	}
	if record.State.Phase == PhaseCutover {
		if err = e.ensureLifecycleEpochActive(ctx, &record); err != nil {
			return record.State, err
		}
		if err = e.assertLifecycleEpoch(ctx, &record); err != nil {
			return record.State, err
		}
		if !record.State.CutoverMayHaveStarted {
			record.State, err = Reduce(record.State, EventCutoverFenced, nil, e.now())
			if err != nil {
				return State{}, err
			}
			if record, err = e.Store.Update(ctx, record); err != nil {
				return State{}, err
			}
		}
		cutoverPhases := []string{"exclusive"}
		cutoverStage := "cutover"
		if record.State.RequiredMode == ModeBlockedLegacy {
			cutoverPhases = []string{"legacy", "exclusive"}
			cutoverStage = "legacy-cutover"
		}
		cutoverIDs := plan.PendingMigrationPhases(cutoverPhases...)
		if err = e.runStage(ctx, &record, cutoverStage, cutoverIDs, plan); err != nil {
			return record.State, err
		}
		record.State.CurrentPending = without(record.State.CurrentPending, cutoverIDs)
		record.State, err = Reduce(record.State, EventCutoverDone, nil, e.now())
		if err != nil {
			return State{}, err
		}
	}
	return e.save(ctx, record)
}

func pendingAttemptIDs(state State, stage string) ([]string, bool) {
	for i := len(state.Attempts) - 1; i >= 0; i-- {
		attempt := state.Attempts[i]
		if attempt.Stage == stage && attempt.Status == "pending" {
			return slices.Clone(attempt.AllowedStepIDs), true
		}
	}
	return nil, false
}

func (e Engine) SyncProvider(ctx context.Context) (State, error) {
	return e.syncProvider(ctx, 0)
}

func (e Engine) syncProvider(ctx context.Context, maxAttempt int) (State, error) {
	record, err := e.Store.Load(ctx)
	if err != nil {
		return State{}, err
	}
	if record.State.Phase != PhaseSucceeded {
		return State{}, errors.New("provider convergence starts only after core succeeded")
	}
	if record.State.Provider.Status == "succeeded" {
		return record.State, nil
	}
	if record.State.Provider.JobName != "" {
		attempt := JobAttempt{Stage: "provider", Attempt: record.State.Provider.Attempt, Name: record.State.Provider.JobName, Status: "pending", AllowedStepIDs: record.State.Provider.AllowedIDs}
		status, statusErr := e.Platform.AttemptStatus(ctx, record.State, attempt)
		if statusErr != nil {
			record.State.Provider.Status = "degraded"
			record.State.Provider.LastError = statusErr.Error()
			record.State.Provider.UpdatedAt = e.now().UTC()
			return e.save(ctx, record)
		}
		switch status {
		case "complete":
			record.State.Provider.Status = "succeeded"
			record.State.Provider.LastError = ""
		case "active":
			record.State.Provider.Status = "running"
		case "failed":
			record.State.Provider.Status = "degraded"
			record.State.Provider.LastError = "provider job failed"
			record.State.Provider.JobName = ""
		case "missing":
			record.State.Provider.JobName = ""
		default:
			return State{}, fmt.Errorf("unknown provider job status %q", status)
		}
		record.State.Provider.UpdatedAt = e.now().UTC()
		if record.State.Provider.JobName != "" {
			return e.save(ctx, record)
		}
	}
	ids := slices.Clone(record.State.Provider.AllowedIDs)
	if len(ids) == 0 {
		record.State.Provider.Status = "succeeded"
		record.State.Provider.UpdatedAt = e.now().UTC()
		return e.save(ctx, record)
	}
	if maxAttempt > 0 && record.State.Provider.Attempt >= maxAttempt {
		record.State.Provider.Status = "degraded"
		if record.State.Provider.LastError == "" {
			record.State.Provider.LastError = fmt.Sprintf("provider convergence exhausted %d bounded attempts", maxAttempt)
		}
		record.State.Provider.UpdatedAt = e.now().UTC()
		return e.save(ctx, record)
	}
	record.State.Provider.Attempt++
	record.State.Provider.JobName = JobName(record.State.ReleaseID, "provider", record.State.Provider.Attempt)
	record.State.Provider.AllowedIDs = slices.Clone(ids)
	record.State.Provider.Status = "running"
	record.State.Provider.LastError = ""
	if record.State.Provider.StartedAt.IsZero() {
		record.State.Provider.StartedAt = e.now().UTC()
	}
	record.State.Provider.UpdatedAt = e.now().UTC()
	if record, err = e.Store.Update(ctx, record); err != nil {
		return State{}, err
	}
	spec := JobSpec{Name: record.State.Provider.JobName, Stage: "provider", Image: record.State.Image, ManifestDigest: record.State.ManifestDigest, BundleName: record.State.BundleName, Attempt: record.State.Provider.Attempt, AllowedStepIDs: ids, Fence: record.State.ReleaseID + ":" + record.State.ManifestDigest}
	if err = e.Platform.StartJob(ctx, spec); err != nil {
		record.State.Provider.Status = "degraded"
		record.State.Provider.LastError = err.Error()
		record.State.Provider.UpdatedAt = e.now().UTC()
	}
	return e.save(ctx, record)
}

// ConvergeProvider owns one bounded provider completion window after the core
// release succeeds. A later high-level reconcile starts a new bounded window
// from the same durable Job/state facts; no workflow loop or observer mutation
// path is required.
func (e Engine) ConvergeProvider(ctx context.Context) (State, error) {
	record, err := e.Store.Load(ctx)
	if err != nil {
		return State{}, err
	}
	if record.State.Phase != PhaseSucceeded {
		return State{}, errors.New("provider convergence starts only after core succeeded")
	}
	if record.State.Provider.Status == "succeeded" {
		return record.State, nil
	}
	poll := e.ProviderPoll
	if poll <= 0 {
		poll = 5 * time.Second
	}
	budget := e.ProviderBudget
	if budget <= 0 {
		budget = 15 * time.Minute
		if record.State.Environment == "staging" {
			budget = 30 * time.Minute
		}
	}
	retries := e.ProviderRetries
	if retries <= 0 {
		retries = 3
	}
	maxAttempt := record.State.Provider.Attempt + retries
	deadline := e.now().Add(budget)
	state := record.State
	for {
		state, err = e.syncProvider(ctx, maxAttempt)
		if err != nil || state.Provider.Status == "succeeded" {
			return state, err
		}
		if state.Provider.Status == "degraded" && state.Provider.JobName == "" && state.Provider.Attempt >= maxAttempt {
			return state, nil
		}
		if !e.now().Before(deadline) {
			return e.degradeProvider(ctx, state.ReleaseID, fmt.Sprintf("provider convergence exceeded %s bounded window", budget))
		}
		if err = e.waitProvider(ctx, poll); err != nil {
			return state, err
		}
	}
}

func (e Engine) degradeProvider(ctx context.Context, releaseID, reason string) (State, error) {
	record, err := e.Store.Load(ctx)
	if err != nil {
		return State{}, err
	}
	if record.State.ReleaseID != releaseID || record.State.Phase != PhaseSucceeded {
		return State{}, errors.New("provider convergence fence changed while marking degraded")
	}
	if record.State.Provider.Status == "succeeded" {
		return record.State, nil
	}
	record.State.Provider.Status = "degraded"
	record.State.Provider.LastError = reason
	record.State.Provider.UpdatedAt = e.now().UTC()
	return e.save(ctx, record)
}

func (e Engine) waitProvider(ctx context.Context, delay time.Duration) error {
	if e.ProviderWait != nil {
		return e.ProviderWait(ctx, delay)
	}
	timer := time.NewTimer(delay)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}

// Reconcile is the single high-level core transaction entrypoint. It advances
// only from durable state and dispatches provider convergence after core
// success without making provider availability part of the core result.
func (e Engine) Reconcile(ctx context.Context) (State, error) {
	for range 8 {
		record, err := e.Store.Load(ctx)
		if err != nil {
			return State{}, err
		}
		switch record.State.Phase {
		case PhasePrepared, PhasePlanned, PhaseOnline, PhaseQuiescing, PhaseCutover:
			if _, err = e.Migrate(ctx); err != nil {
				return record.State, err
			}
		case PhaseApplying:
			if _, err = e.Apply(ctx); err != nil {
				return record.State, err
			}
		case PhaseVerifying:
			if _, err = e.Verify(ctx); err != nil {
				return record.State, err
			}
		case PhaseSucceeded:
			if err = e.releaseLifecycleEpoch(ctx, &record); err != nil {
				return record.State, fmt.Errorf("release lifecycle writer epoch after v1 verification: %w", err)
			}
			return e.ConvergeProvider(ctx)
		case PhaseRecovered, PhaseForwardOnly:
			return record.State, nil
		default:
			return State{}, fmt.Errorf("cannot reconcile phase %q", record.State.Phase)
		}
	}
	return State{}, errors.New("release reconcile exceeded bounded phase transitions")
}

func (e Engine) Apply(ctx context.Context) (State, error) {
	record, err := e.Store.Load(ctx)
	if err != nil {
		return State{}, err
	}
	if record.State.Phase != PhaseApplying {
		return State{}, invalid(record.State.Phase, EventApplied)
	}
	if err = e.ensureLifecycleEpochActive(ctx, &record); err != nil {
		return record.State, err
	}
	evidence, applyErr := e.Platform.Apply(ctx, record.State)
	if applyErr != nil {
		err = applyErr
		return record.State, err
	}
	record.State.ApplyEvidence = &evidence
	record.State.Helm.CandidateRevision = evidence.HelmRevision
	record.State.Helm.AppliedRevisions = append(record.State.Helm.AppliedRevisions, evidence.HelmRevision)
	if record, err = e.Store.Update(ctx, record); err != nil {
		return State{}, err
	}
	record.State, err = Reduce(record.State, EventApplied, nil, e.now())
	if err != nil {
		return State{}, err
	}
	return e.save(ctx, record)
}

func (e Engine) Verify(ctx context.Context) (State, error) {
	record, err := e.Store.Load(ctx)
	if err != nil {
		return State{}, err
	}
	if record.State.Phase == PhaseSucceeded {
		return e.finishSucceededLifecycleEpoch(ctx, record)
	}
	if record.State.Phase != PhaseVerifying {
		return State{}, invalid(record.State.Phase, EventVerified)
	}
	if err = e.ensureLifecycleEpochActive(ctx, &record); err != nil {
		return record.State, err
	}
	var evidence ApplyEvidence
	if evidence, err = e.Platform.Verify(ctx, record.State); err != nil {
		return record.State, err
	}
	if record.State.LifecycleWriterEpoch != nil &&
		record.State.LifecycleWriterEpoch.Required {
		if err = e.Platform.VerifyLifecycleV1(ctx, record.State); err != nil {
			return record.State, fmt.Errorf("verify lifecycle-v1 hard-cut ingress contract: %w", err)
		}
		if err = e.assertLifecycleEpoch(ctx, &record); err != nil {
			return record.State, err
		}
	}
	if evidence.HelmRevision > 0 {
		record.State.Helm.ServingRevision = evidence.HelmRevision
		record.State.Helm.AppliedRevisions = append(record.State.Helm.AppliedRevisions, evidence.HelmRevision)
	}
	record.State, err = Reduce(record.State, EventVerified, nil, e.now())
	if err != nil {
		return State{}, err
	}
	if record, err = e.Store.Update(ctx, record); err != nil {
		return State{}, err
	}
	return e.finishSucceededLifecycleEpoch(ctx, record)
}

func (e Engine) Recover(ctx context.Context, expectedReleaseID ...string) (State, error) {
	record, err := e.Store.Load(ctx)
	if err != nil {
		return State{}, err
	}
	if len(expectedReleaseID) != 1 || expectedReleaseID[0] == "" {
		return State{}, errors.New("expected release id is required for recovery")
	}
	if record.State.ReleaseID != expectedReleaseID[0] {
		return State{}, fmt.Errorf("recovery fence mismatch: active release is %q", record.State.ReleaseID)
	}
	if record.State.Phase == PhaseSucceeded {
		if err = e.releaseLifecycleEpoch(ctx, &record); err != nil {
			return record.State, fmt.Errorf("release lifecycle writer epoch after durable success: %w", err)
		}
		return record.State, nil
	}
	if record.State.Phase == PhaseForwardOnly {
		return record.State, nil
	}
	if record.State.Phase == PhaseRecovered {
		if hasAbortableAttempts(record.State) {
			if err = e.Platform.AbortAttempts(ctx, record.State); err != nil {
				return record.State, fmt.Errorf("abort recovered release attempts: %w", err)
			}
			markAbortableAttemptsAborted(&record.State)
			if record, err = e.Store.Update(ctx, record); err != nil {
				return State{}, err
			}
		}
		if hasUnsettledLifecycleEpochAcquire(record.State.LifecycleWriterEpoch) {
			// Older V4 runners could mark recovery terminal after an acquire
			// committed but before its evidence was acknowledged. Re-open only
			// that exact durable intent so the same token can recover the
			// generation, persist it, and release it before returning terminal.
			record.State.Phase = PhaseRecovering
			record.State.UpdatedAt = e.now().UTC()
			if record, err = e.Store.Update(ctx, record); err != nil {
				return State{}, fmt.Errorf("reopen unresolved lifecycle writer epoch recovery: %w", err)
			}
			if err = e.releaseLifecycleEpoch(ctx, &record); err != nil {
				return record.State, fmt.Errorf("release unresolved lifecycle writer epoch after recovery: %w", err)
			}
			if record.State, err = Reduce(record.State, EventRecovered, nil, e.now()); err != nil {
				return State{}, err
			}
			return e.save(ctx, record)
		}
		if err = e.releaseLifecycleEpoch(ctx, &record); err != nil {
			return record.State, err
		}
		return record.State, nil
	}
	failedPhase := record.State.Phase
	record.State, err = Reduce(record.State, EventRecover, nil, e.now())
	if err != nil {
		return State{}, err
	}
	if record.State.Phase == PhaseForwardOnly {
		record.State.ForwardPhase = failedPhase
		if failedPhase == PhaseCutover || failedPhase == PhaseApplying || failedPhase == PhaseVerifying {
			if err = e.Platform.Restore(ctx, record.State); err != nil {
				record.State.LastError = "maintenance revision restore failed"
				_, _ = e.Store.Update(ctx, record)
				return record.State, fmt.Errorf("restore maintenance revision: %w", err)
			}
		}
		return e.save(ctx, record)
	}
	if record, err = e.Store.Update(ctx, record); err != nil {
		return State{}, fmt.Errorf("claim recovery ownership: %w", err)
	}
	if err = e.Platform.AbortAttempts(ctx, record.State); err != nil {
		return record.State, fmt.Errorf("abort release attempts: %w", err)
	}
	markAbortableAttemptsAborted(&record.State)
	if recoveryNeedsHelmRollback(failedPhase) {
		if err = e.Platform.Restore(ctx, record.State); err != nil {
			return record.State, fmt.Errorf("restore Helm snapshot revision: %w", err)
		}
	}
	if err = e.releaseLifecycleEpoch(ctx, &record); err != nil {
		return record.State, fmt.Errorf("release lifecycle writer epoch after recovery: %w", err)
	}
	record.State, err = Reduce(record.State, EventRecovered, nil, e.now())
	if err != nil {
		return State{}, err
	}
	return e.save(ctx, record)
}

// ResumeForward explicitly re-enters the exact phase that recovery fenced after
// the irreversible cutover boundary. The caller must then invoke the matching
// idempotent stage command; recovery itself never guesses or executes it.
func (e Engine) ResumeForward(ctx context.Context, expectedReleaseID string, expectedPhase Phase, retryFailed ...bool) (State, error) {
	record, err := e.Store.Load(ctx)
	if err != nil {
		return State{}, err
	}
	if expectedReleaseID == "" || record.State.ReleaseID != expectedReleaseID {
		return State{}, fmt.Errorf("forward resume fence mismatch: active release is %q", record.State.ReleaseID)
	}
	if record.State.Phase != PhaseForwardOnly || !record.State.CutoverMayHaveStarted {
		return State{}, errors.New("release is not awaiting forward recovery")
	}
	if record.State.ForwardPhase != expectedPhase {
		return State{}, fmt.Errorf("forward recovery requires phase %q, not %q", record.State.ForwardPhase, expectedPhase)
	}
	switch expectedPhase {
	case PhaseCutover, PhaseApplying, PhaseVerifying:
	default:
		return State{}, fmt.Errorf("phase %q cannot be resumed forward", expectedPhase)
	}
	stage := ""
	if expectedPhase == PhaseCutover {
		stage = "cutover"
		if record.State.RequiredMode == ModeBlockedLegacy {
			stage = "legacy-cutover"
		}
	}
	if stage != "" {
		for i := len(record.State.Attempts) - 1; i >= 0; i-- {
			attempt := record.State.Attempts[i]
			if attempt.Stage != stage {
				continue
			}
			if attempt.Status == "complete" {
				break
			} else if attempt.Status == "failed" {
				status, statusErr := e.Platform.AttemptStatus(ctx, record.State, attempt)
				if statusErr != nil {
					return State{}, statusErr
				}
				switch status {
				case "active", "complete", "missing":
					record.State.Attempts[i].Status = "pending"
				case "failed":
					if len(retryFailed) != 1 || !retryFailed[0] {
						return State{}, fmt.Errorf("forward %s attempt is %s; --retry-failed is required", stage, status)
					}
				default:
					return State{}, fmt.Errorf("forward %s attempt has unknown runtime status %q", stage, status)
				}
			} else if attempt.Status != "pending" {
				return State{}, fmt.Errorf("forward %s attempt has unknown durable status %q", stage, attempt.Status)
			}
			break
		}
	}
	record.State.Phase = expectedPhase
	record.State.ForwardPhase = ""
	record.State.UpdatedAt = e.now().UTC()
	return e.save(ctx, record)
}

func hasAbortableAttempts(state State) bool {
	return slices.ContainsFunc(state.Attempts, func(attempt JobAttempt) bool {
		return attempt.Status != "complete" && attempt.Status != "aborted"
	})
}

func markAbortableAttemptsAborted(state *State) {
	for i := range state.Attempts {
		if state.Attempts[i].Status != "complete" && state.Attempts[i].Status != "aborted" {
			state.Attempts[i].Status = "aborted"
		}
	}
}

func recoveryNeedsHelmRollback(phase Phase) bool {
	return phase == PhaseQuiescing || phase == PhaseCutover || phase == PhaseApplying ||
		phase == PhaseVerifying || phase == PhaseRecovering
}

func (e Engine) ensureLifecycleEpochActive(ctx context.Context, record *Record) error {
	epoch := record.State.LifecycleWriterEpoch
	if epoch == nil || !epoch.Required {
		return nil
	}
	action := LifecycleEpochAcquire
	if epoch.Status == "active" {
		action = LifecycleEpochRenew
	}
	_, err := e.runLifecycleEpochAction(ctx, record, action)
	return err
}

func (e Engine) assertLifecycleEpoch(ctx context.Context, record *Record) error {
	epoch := record.State.LifecycleWriterEpoch
	if epoch == nil || !epoch.Required {
		return nil
	}
	_, err := e.runLifecycleEpochAction(ctx, record, LifecycleEpochAssert)
	return err
}

func (e Engine) releaseLifecycleEpoch(ctx context.Context, record *Record) error {
	epoch := record.State.LifecycleWriterEpoch
	if epoch == nil || !epoch.Required || epoch.Status == "released" {
		return nil
	}
	if hasUnsettledLifecycleEpochAcquire(epoch) {
		if _, err := e.resumeLifecycleEpochAcquire(ctx, record); err != nil {
			return fmt.Errorf("settle lifecycle writer epoch acquire before release: %w", err)
		}
		epoch = record.State.LifecycleWriterEpoch
	}
	if epoch.Status == "" {
		return nil
	}
	_, err := e.runLifecycleEpochAction(ctx, record, LifecycleEpochRelease)
	return err
}

func hasUnsettledLifecycleEpochAcquire(epoch *LifecycleWriterEpochFacts) bool {
	return epoch != nil && epoch.Required &&
		(epoch.Status == "acquiring" || epoch.Status == "") &&
		epoch.FencingToken != "" && epoch.OperationAttempt > 0
}

func (e Engine) finishSucceededLifecycleEpoch(ctx context.Context, record Record) (State, error) {
	if record.State.Phase != PhaseSucceeded {
		return State{}, invalid(record.State.Phase, EventVerified)
	}
	if err := e.releaseLifecycleEpoch(ctx, &record); err != nil {
		return record.State, fmt.Errorf("release lifecycle writer epoch after v1 verification: %w", err)
	}
	if err := e.Platform.Cleanup(ctx, record.State); err != nil {
		return record.State, fmt.Errorf("cleanup succeeded release: %w", err)
	}
	return record.State, nil
}

func (e Engine) runLifecycleEpochAction(ctx context.Context, record *Record, action LifecycleEpochAction) (LifecycleEpochEvidence, error) {
	epoch := record.State.LifecycleWriterEpoch
	if epoch == nil || !epoch.Required {
		return LifecycleEpochEvidence{}, nil
	}
	if action == LifecycleEpochAcquire && epoch.FencingToken == "" {
		token, err := newLifecycleEpochToken()
		if err != nil {
			return LifecycleEpochEvidence{}, err
		}
		epoch.FencingToken = token
	}
	if action != LifecycleEpochAcquire && (epoch.Status != "active" || epoch.Generation <= 0 || epoch.FencingToken == "") {
		return LifecycleEpochEvidence{}, fmt.Errorf("lifecycle writer epoch %s requires an active durable fence", action)
	}
	epoch.OperationAttempt++
	if action == LifecycleEpochAcquire {
		epoch.Status = "acquiring"
	}
	var err error
	if *record, err = e.Store.Update(ctx, *record); err != nil {
		return LifecycleEpochEvidence{}, err
	}
	return e.executeLifecycleEpochAction(ctx, record, action)
}

func (e Engine) resumeLifecycleEpochAcquire(ctx context.Context, record *Record) (LifecycleEpochEvidence, error) {
	if !hasUnsettledLifecycleEpochAcquire(record.State.LifecycleWriterEpoch) {
		return LifecycleEpochEvidence{}, errors.New("no durable lifecycle writer epoch acquire to resume")
	}
	return e.executeLifecycleEpochAction(ctx, record, LifecycleEpochAcquire)
}

func (e Engine) executeLifecycleEpochAction(ctx context.Context, record *Record, action LifecycleEpochAction) (LifecycleEpochEvidence, error) {
	epoch := record.State.LifecycleWriterEpoch
	lease := e.LifecycleEpochLease
	if lease <= 0 {
		lease = 5 * time.Minute
	}
	leaseSeconds := int(lease.Round(time.Second) / time.Second)
	if leaseSeconds < 1 || leaseSeconds > 3600 {
		return LifecycleEpochEvidence{}, errors.New("lifecycle writer epoch lease must be within 1s..1h")
	}
	spec := LifecycleEpochSpec{
		Action:       action,
		ReleaseID:    record.State.ReleaseID,
		Image:        record.State.Image,
		BundleName:   record.State.BundleName,
		Token:        epoch.FencingToken,
		Generation:   epoch.Generation,
		Attempt:      epoch.OperationAttempt,
		LeaseSeconds: leaseSeconds,
	}
	evidence, runErr := e.Platform.RunLifecycleEpoch(ctx, spec)
	if runErr != nil {
		record.State.LastError = "lifecycle writer epoch " + string(action) + " failed"
		*record, _ = e.Store.Update(ctx, *record)
		return LifecycleEpochEvidence{}, runErr
	}
	if err := validateLifecycleEpochEvidence(evidence, spec); err != nil {
		record.State.LastError = "lifecycle writer epoch evidence invalid"
		*record, _ = e.Store.Update(ctx, *record)
		return LifecycleEpochEvidence{}, err
	}
	epoch = record.State.LifecycleWriterEpoch
	epoch.Generation = evidence.Generation
	epoch.LeaseExpiresAt = evidence.LeaseExpiresAt
	epoch.DrainedAt = evidence.DrainedAt
	switch action {
	case LifecycleEpochRelease:
		epoch.Status = "released"
		epoch.ReleasedAt = evidence.ReleasedAt
		epoch.FencingToken = ""
	default:
		epoch.Status = "active"
	}
	record.State.LastError = ""
	var err error
	if *record, err = e.Store.Update(ctx, *record); err != nil {
		return LifecycleEpochEvidence{}, err
	}
	return evidence, nil
}

func validateLifecycleEpochEvidence(evidence LifecycleEpochEvidence, spec LifecycleEpochSpec) error {
	if evidence.SchemaVersion != 1 || evidence.Action != spec.Action ||
		evidence.ReleaseID != spec.ReleaseID || evidence.Generation <= 0 {
		return errors.New("lifecycle writer epoch evidence identity mismatch")
	}
	if spec.Generation > 0 && evidence.Generation != spec.Generation {
		return errors.New("lifecycle writer epoch generation changed during fenced operation")
	}
	if spec.Action == LifecycleEpochRelease {
		if evidence.Status != "released" || evidence.ReleasedAt.IsZero() {
			return errors.New("lifecycle writer epoch release evidence is incomplete")
		}
		return nil
	}
	if evidence.Status != "active" || evidence.LeaseExpiresAt.IsZero() || evidence.DrainedAt.IsZero() {
		return errors.New("lifecycle writer epoch active evidence is incomplete")
	}
	return nil
}

func newLifecycleEpochToken() (string, error) {
	body := make([]byte, 32)
	if _, err := rand.Read(body); err != nil {
		return "", fmt.Errorf("generate lifecycle writer epoch token: %w", err)
	}
	return hex.EncodeToString(body), nil
}

func without(values, removed []string) []string {
	set := map[string]bool{}
	for _, value := range removed {
		set[value] = true
	}
	result := make([]string, 0, len(values))
	for _, value := range values {
		if !set[value] {
			result = append(result, value)
		}
	}
	return result
}

func (e Engine) runPlan(ctx context.Context, record *Record) (Plan, error) {
	attemptIndex := -1
	for i := len(record.State.Attempts) - 1; i >= 0; i-- {
		if record.State.Attempts[i].Stage == "plan" && record.State.Attempts[i].Status == "pending" {
			attemptIndex = i
			break
		}
	}
	if attemptIndex == -1 {
		attempt := NextAttempt(record.State, "plan")
		record.State.Attempts = append(record.State.Attempts, attempt)
		attemptIndex = len(record.State.Attempts) - 1
		var err error
		*record, err = e.Store.Update(ctx, *record)
		if err != nil {
			return Plan{}, err
		}
	}
	plan, err := e.Platform.RunPlan(ctx, record.State)
	if err != nil {
		record.State.Attempts[attemptIndex].Status = "failed"
		record.State.LastError = "plan failed"
		*record, _ = e.Store.Update(ctx, *record)
		return Plan{}, err
	}
	record.State.Attempts[attemptIndex].Status = "complete"
	record.State.LastError = ""
	var saveErr error
	*record, saveErr = e.Store.Update(ctx, *record)
	return plan, saveErr
}

func (e Engine) runStage(ctx context.Context, record *Record, stage string, ids []string, plan Plan) error {
	attemptIndex := -1
	for i := len(record.State.Attempts) - 1; i >= 0; i-- {
		attempt := record.State.Attempts[i]
		if attempt.Stage == stage && attempt.Status == "pending" {
			attemptIndex = i
			ids = slices.Clone(attempt.AllowedStepIDs)
			break
		}
	}
	if attemptIndex == -1 {
		if len(ids) == 0 {
			return nil
		}
		attempt := NextAttempt(record.State, stage)
		attempt.AllowedStepIDs = slices.Clone(ids)
		for _, step := range plan.PendingSteps {
			if slices.Contains(ids, step.ID) && !step.Execution.Transactional {
				attempt.MigrationFacts = append(attempt.MigrationFacts, MigrationAttemptFact{StepID: step.ID, Transactional: false, Idempotent: step.Execution.Idempotent, Postconditions: slices.Clone(step.Postconditions), Repair: step.Repair})
			}
		}
		record.State.Attempts = append(record.State.Attempts, attempt)
		attemptIndex = len(record.State.Attempts) - 1
		var err error
		*record, err = e.Store.Update(ctx, *record)
		if err != nil {
			return err
		}
	}
	attempt := record.State.Attempts[attemptIndex]
	fence := record.State.ReleaseID + ":" + record.State.ManifestDigest
	spec := JobSpec{Name: attempt.Name, Stage: stage, Image: record.State.Image, ManifestDigest: record.State.ManifestDigest, BundleName: record.State.BundleName, Attempt: attempt.Attempt, AllowedStepIDs: ids, Fence: fence}
	runErr := e.Platform.RunJob(ctx, spec)
	if runErr != nil {
		record.State.Attempts[attemptIndex].Status = "failed"
		record.State.LastError = stage + " failed"
		*record, _ = e.Store.Update(ctx, *record)
		return runErr
	}
	record.State.Attempts[attemptIndex].Status = "complete"
	record.State.LastError = ""
	var err error
	*record, err = e.Store.Update(ctx, *record)
	return err
}

func (e Engine) save(ctx context.Context, record Record) (State, error) {
	updated, err := e.Store.Update(ctx, record)
	return updated.State, err
}
func (e Engine) now() time.Time {
	if e.Now != nil {
		return e.Now()
	}
	return time.Now()
}
func terminal(p Phase) bool {
	return p == PhaseSucceeded || p == PhaseRecovered || p == PhaseForwardOnly
}

func replaceableTerminal(state State) bool {
	if state.LifecycleWriterEpoch != nil &&
		(state.LifecycleWriterEpoch.Status == "active" ||
			hasUnsettledLifecycleEpochAcquire(state.LifecycleWriterEpoch)) {
		return false
	}
	return terminal(state.Phase)
}

func Encode(v any) []byte { body, _ := json.Marshal(v); return body }
