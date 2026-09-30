package release

import (
	"errors"
	"fmt"
	"slices"
	"time"
)

const CurrentStateSchemaVersion = 4

type Mode string

const (
	ModeOnline        Mode = "online"
	ModeExclusive     Mode = "exclusive"
	ModeBlockedLegacy Mode = "blocked_legacy"
)

var legacyUpgradeStepIDs = []string{
	"salix-20260728000103",
	"salix-20260729000001",
	"salix-20260729000002",
}

type Plan struct {
	SchemaVersion      int               `json:"schemaVersion"`
	ManifestDigest     string            `json:"manifestDigest"`
	RequiredMode       Mode              `json:"requiredMode"`
	PendingIDs         []string          `json:"pendingIDs"`
	PendingSteps       []MigrationStepV2 `json:"pendingSteps"`
	ProviderPendingIDs []string          `json:"providerPendingIDs"`
	Facts              map[string]string `json:"facts,omitempty"`
}

type MigrationStepV2 struct {
	Owner          string                  `json:"owner"`
	Store          string                  `json:"store"`
	Version        int64                   `json:"version"`
	Source         string                  `json:"source"`
	Checksum       string                  `json:"checksum"`
	ID             string                  `json:"id"`
	Phase          string                  `json:"phase"`
	Compatibility  map[string]bool         `json:"compatibility"`
	Execution      MigrationExecutionFacts `json:"execution"`
	Safety         MigrationSafetyFacts    `json:"safety"`
	Postconditions []string                `json:"postconditions"`
	Repair         string                  `json:"repair"`
}

type MigrationExecutionFacts struct {
	Transactional     bool `json:"transactional"`
	Idempotent        bool `json:"idempotent"`
	TimeoutSeconds    int  `json:"timeoutSeconds"`
	LockBudgetSeconds int  `json:"lockBudgetSeconds"`
}

type MigrationSafetyFacts struct {
	Destructive      bool   `json:"destructive"`
	BackupRequired   bool   `json:"backupRequired"`
	RollbackStrategy string `json:"rollbackStrategy"`
}

func (p Plan) Validate() error {
	return p.validate(false)
}

// ValidateLegacyUpgrade is intentionally separate from Validate: only the
// dedicated command may persist blocked_legacy and accept the three frozen
// Salix steps. Ordinary releases continue to reject blocked_legacy before any
// executor or workload mutation.
// TLA: tla/salix/SalixLegacyUpgrade.tla::RunMigration.
func (p Plan) ValidateLegacyUpgrade() error {
	return p.validate(true)
}

func (p Plan) validate(legacyUpgrade bool) error {
	if p.SchemaVersion != 2 {
		return fmt.Errorf("unsupported plan schema %d", p.SchemaVersion)
	}
	if !validSHA256Digest(p.ManifestDigest) {
		return errors.New("valid migration manifest V2 digest is required")
	}
	if p.RequiredMode == ModeBlockedLegacy && !legacyUpgrade {
		// TLA: tla/salix/SalixLegacyMigrationRelease.tla::RejectLegacyPlan.
		return errors.New("pending legacy migration requires an explicit audited upgrade; automatic zero-replica cutover is forbidden")
	}
	if p.RequiredMode != ModeOnline && p.RequiredMode != ModeExclusive &&
		(!legacyUpgrade || p.RequiredMode != ModeBlockedLegacy) {
		return fmt.Errorf("unsupported V2 required mode %q", p.RequiredMode)
	}
	seen := map[string]bool{}
	derivedMode := ModeOnline
	legacyPending := false
	for _, step := range p.PendingSteps {
		if step.ID == "" || step.Owner == "" || step.Store == "" || step.Version <= 0 || step.Source == "" || step.Checksum == "" || seen[step.ID] || step.Repair == "" || len(step.Postconditions) == 0 {
			return fmt.Errorf("invalid migration V2 pending step %q", step.ID)
		}
		if step.Store != "postgres" && step.Store != "clickhouse" {
			return fmt.Errorf("migration V2 step %q has unsupported store %q", step.ID, step.Store)
		}
		seen[step.ID] = true
		if step.Phase != "expand" && step.Phase != "exclusive" && step.Phase != "local_seed" &&
			(!legacyUpgrade || step.Phase != "legacy") {
			return fmt.Errorf("migration V2 phase %q cannot execute in a core release", step.Phase)
		}
		if step.Phase == "legacy" {
			if !slices.Contains(legacyUpgradeStepIDs, step.ID) {
				return fmt.Errorf("migration V2 legacy step %q is outside the audited upgrade scope", step.ID)
			}
			if step.Owner != "salix_store" || step.Store != "postgres" {
				return fmt.Errorf("migration V2 legacy step %q has drifted from its Salix/Postgres owner", step.ID)
			}
			if step.Compatibility["oldRuntimeRead"] && step.Compatibility["oldRuntimeWrite"] &&
				step.Compatibility["newRuntimeRead"] && step.Compatibility["newRuntimeWrite"] {
				return fmt.Errorf("migration V2 legacy step %q no longer declares an incompatible runtime boundary", step.ID)
			}
			legacyPending = true
		}
		for _, key := range []string{"oldRuntimeRead", "oldRuntimeWrite", "newRuntimeRead", "newRuntimeWrite"} {
			if _, ok := step.Compatibility[key]; !ok {
				return fmt.Errorf("migration V2 step %q is missing compatibility fact %q", step.ID, key)
			}
		}
		if len(step.Compatibility) != 4 {
			return fmt.Errorf("migration V2 step %q has unknown compatibility facts", step.ID)
		}
		if step.Phase == "local_seed" {
			for key, compatible := range step.Compatibility {
				if !compatible {
					return fmt.Errorf("migration V2 %s step %q is incompatible at %q", step.Phase, step.ID, key)
				}
			}
		}
		if step.Phase == "exclusive" {
			derivedMode = ModeExclusive
		}
		for _, postcondition := range step.Postconditions {
			if postcondition == "" {
				return fmt.Errorf("migration V2 step %q has an empty postcondition", step.ID)
			}
		}
		if step.Execution.TimeoutSeconds <= 0 || step.Execution.LockBudgetSeconds <= 0 {
			return fmt.Errorf("migration V2 step %q has invalid budgets", step.ID)
		}
		if !slices.Contains([]string{"none", "compensating", "reversible_manual"}, step.Safety.RollbackStrategy) || (step.Safety.Destructive && !step.Safety.BackupRequired) {
			return fmt.Errorf("migration V2 step %q has invalid safety facts", step.ID)
		}
		if !step.Execution.Transactional && (!step.Execution.Idempotent || len(step.Postconditions) == 0 || step.Repair == "") {
			return fmt.Errorf("non-transactional migration V2 step %q lacks retry facts", step.ID)
		}
		if step.Phase == "expand" && step.Safety.RollbackStrategy != "none" {
			return fmt.Errorf("expand migration V2 step %q cannot declare rollback", step.ID)
		}
	}
	if legacyPending {
		derivedMode = ModeBlockedLegacy
	}
	if p.RequiredMode != derivedMode {
		return fmt.Errorf("requiredMode %q does not match derived %q", p.RequiredMode, derivedMode)
	}
	if !slices.Equal(p.PendingIDs, migrationIDs(p.PendingSteps)) {
		return errors.New("migration V2 pending IDs do not match pending step facts")
	}
	if !slices.IsSorted(p.ProviderPendingIDs) {
		return errors.New("provider pending IDs must use canonical order")
	}
	if len(p.ProviderPendingIDs) > 1 {
		return errors.New("provider pending IDs contain duplicates")
	}
	for _, id := range p.ProviderPendingIDs {
		if id != "billing-provider" {
			return fmt.Errorf("unsupported provider pending ID %q", id)
		}
	}
	return nil
}

func migrationIDs(steps []MigrationStepV2) []string {
	ids := make([]string, 0, len(steps))
	for _, step := range steps {
		ids = append(ids, step.ID)
	}
	return ids
}

func (p Plan) CorePending() []string {
	return slices.Clone(p.PendingIDs)
}

func (p Plan) PendingMigrationPhases(phases ...string) []string {
	allowed := map[string]bool{}
	for _, phase := range phases {
		allowed[phase] = true
	}
	var ids []string
	for _, step := range p.PendingSteps {
		if allowed[step.Phase] {
			ids = append(ids, step.ID)
		}
	}
	return ids
}

func (p Plan) PendingLegacyUpgradeIDs() []string {
	return p.PendingMigrationPhases("legacy")
}

type Phase string

const (
	PhasePrepared    Phase = "prepared"
	PhasePlanned     Phase = "planned"
	PhaseOnline      Phase = "migrating_online"
	PhaseQuiescing   Phase = "quiescing"
	PhaseCutover     Phase = "cutover"
	PhaseApplying    Phase = "applying"
	PhaseVerifying   Phase = "verifying"
	PhaseSucceeded   Phase = "succeeded"
	PhaseRecovering  Phase = "recovering"
	PhaseRecovered   Phase = "recovered"
	PhaseForwardOnly Phase = "forward_only"
)

func (s State) validatePhaseFacts() error {
	if s.SchemaVersion != CurrentStateSchemaVersion {
		return fmt.Errorf("unsupported release state schema %d", s.SchemaVersion)
	}
	if s.RequiredMode == ModeBlockedLegacy && s.LifecycleWriterEpoch != nil {
		return errors.New("legacy upgrade cannot be combined with the Session lifecycle hard cut")
	}
	if s.Helm.SnapshotRevision <= 0 || s.Helm.ServingRevision <= 0 {
		return errors.New("release state V4 requires durable Helm snapshot and serving revisions")
	}
	if s.CutoverMayHaveStarted && s.Helm.MaintenanceRevision <= 0 {
		return errors.New("cutover-fenced release state requires a maintenance Helm revision")
	}
	if err := s.validateLifecycleWriterEpoch(); err != nil {
		return err
	}
	switch s.Phase {
	case PhasePrepared, PhasePlanned, PhaseOnline, PhaseQuiescing, PhaseCutover,
		PhaseApplying, PhaseVerifying, PhaseSucceeded, PhaseRecovering, PhaseRecovered,
		PhaseForwardOnly:
	default:
		return fmt.Errorf("unsupported release state phase %q", s.Phase)
	}

	if s.Phase == PhaseForwardOnly {
		switch s.ForwardPhase {
		case PhaseCutover, PhaseApplying, PhaseVerifying:
			return nil
		default:
			return fmt.Errorf("unsupported release state forward phase %q", s.ForwardPhase)
		}
	}
	if s.ForwardPhase != "" {
		return fmt.Errorf("release state phase %q cannot carry forward phase %q", s.Phase, s.ForwardPhase)
	}
	return nil
}

func (s State) validateLifecycleWriterEpoch() error {
	epoch := s.LifecycleWriterEpoch
	if epoch == nil {
		return nil
	}
	if !epoch.Required {
		return errors.New("lifecycle writer epoch facts cannot be persisted when the hard cut is disabled")
	}
	switch epoch.Status {
	case "", "acquiring", "active", "released":
	default:
		return fmt.Errorf("unsupported lifecycle writer epoch status %q", epoch.Status)
	}
	if epoch.Status == "acquiring" {
		if len(epoch.FencingToken) < 32 || epoch.OperationAttempt <= 0 {
			return errors.New("acquiring lifecycle writer epoch requires durable token and operation attempt")
		}
	}
	if epoch.Status == "active" {
		if epoch.Generation <= 0 || len(epoch.FencingToken) < 32 || epoch.LeaseExpiresAt.IsZero() || epoch.DrainedAt.IsZero() {
			return errors.New("active lifecycle writer epoch requires durable generation, token, lease, and drain evidence")
		}
	}
	if epoch.Status == "released" {
		if epoch.Generation <= 0 || epoch.ReleasedAt.IsZero() || epoch.FencingToken != "" {
			return errors.New("released lifecycle writer epoch facts are incomplete")
		}
	}
	if slices.Contains([]Phase{PhaseCutover, PhaseApplying, PhaseVerifying, PhaseForwardOnly}, s.Phase) &&
		epoch.Status != "active" {
		return fmt.Errorf("release phase %q requires an active lifecycle writer epoch", s.Phase)
	}
	if s.Phase == PhaseSucceeded && epoch.Status != "active" && epoch.Status != "released" {
		return errors.New("succeeded lifecycle hard cut requires active or released epoch evidence")
	}
	if s.Phase == PhaseRecovered && (epoch.Status == "acquiring" || epoch.Status == "active") {
		return errors.New("recovered pre-cutover release cannot retain an acquiring or active lifecycle writer epoch")
	}
	return nil
}

type JobAttempt struct {
	Stage          string                 `json:"stage"`
	Attempt        int                    `json:"attempt"`
	Name           string                 `json:"name"`
	Status         string                 `json:"status"`
	AllowedStepIDs []string               `json:"allowedStepIds"`
	MigrationFacts []MigrationAttemptFact `json:"migrationFacts,omitempty"`
}

type MigrationAttemptFact struct {
	StepID         string   `json:"stepId"`
	Transactional  bool     `json:"transactional"`
	Idempotent     bool     `json:"idempotent"`
	Postconditions []string `json:"postconditions"`
	Repair         string   `json:"repair"`
}

type ProviderFacts struct {
	Status     string    `json:"status"`
	Attempt    int       `json:"attempt"`
	JobName    string    `json:"jobName,omitempty"`
	AllowedIDs []string  `json:"allowedStepIds,omitempty"`
	LastError  string    `json:"lastError,omitempty"`
	StartedAt  time.Time `json:"startedAt,omitempty"`
	UpdatedAt  time.Time `json:"updatedAt,omitempty"`
}

type ApplyEvidence struct {
	ManifestDigest string `json:"manifestDigest"`
	HelmRevision   int    `json:"helmRevision,omitempty"`
}

type LifecycleEpochAction string

const (
	LifecycleEpochAcquire LifecycleEpochAction = "acquire"
	LifecycleEpochRenew   LifecycleEpochAction = "renew"
	LifecycleEpochAssert  LifecycleEpochAction = "assert"
	LifecycleEpochRelease LifecycleEpochAction = "release"
)

type LifecycleWriterEpochFacts struct {
	Required         bool      `json:"required"`
	Status           string    `json:"status,omitempty"`
	Generation       int64     `json:"generation,omitempty"`
	FencingToken     string    `json:"fencingToken,omitempty"`
	OperationAttempt int       `json:"operationAttempt,omitempty"`
	LeaseExpiresAt   time.Time `json:"leaseExpiresAt,omitempty"`
	DrainedAt        time.Time `json:"drainedAt,omitempty"`
	// Retained only so strict V4 decoding accepts state written before the
	// inventory gate was removed. New releases do not set or require it.
	LastInventoryAt time.Time `json:"lastInventoryAt,omitempty"`
	ReleasedAt      time.Time `json:"releasedAt,omitempty"`
}

type LifecycleEpochSpec struct {
	Action       LifecycleEpochAction
	ReleaseID    string
	Image        string
	BundleName   string
	Token        string
	Generation   int64
	Attempt      int
	LeaseSeconds int
}

type LifecycleEpochEvidence struct {
	SchemaVersion  int                  `json:"schema_version"`
	Action         LifecycleEpochAction `json:"action"`
	Status         string               `json:"status"`
	ReleaseID      string               `json:"release_id"`
	Generation     int64                `json:"generation"`
	LeaseExpiresAt time.Time            `json:"lease_expires_at"`
	DrainedAt      time.Time            `json:"drained_at"`
	ReleasedAt     time.Time            `json:"released_at,omitempty"`
}

type ArtifactFacts struct {
	ImageDigest    string `json:"imageDigest,omitempty"`
	ChartReference string `json:"chartReference,omitempty"`
	ChartDigest    string `json:"chartDigest,omitempty"`
	ValuesDigest   string `json:"valuesDigest,omitempty"`
}

type HelmFacts struct {
	Release             string `json:"release"`
	Namespace           string `json:"namespace"`
	SnapshotRevision    int    `json:"snapshotRevision,omitempty"`
	MaintenanceRevision int    `json:"maintenanceRevision,omitempty"`
	CandidateRevision   int    `json:"candidateRevision,omitempty"`
	ServingRevision     int    `json:"servingRevision,omitempty"`
	AppliedRevisions    []int  `json:"appliedRevisions,omitempty"`
}

type State struct {
	SchemaVersion         int                        `json:"schemaVersion"`
	Environment           string                     `json:"environment"`
	ReleaseID             string                     `json:"releaseId"`
	Image                 string                     `json:"image"`
	Artifacts             ArtifactFacts              `json:"artifacts"`
	Helm                  HelmFacts                  `json:"helm"`
	Phase                 Phase                      `json:"phase"`
	ManifestDigest        string                     `json:"manifestDigest,omitempty"`
	RequiredMode          Mode                       `json:"requiredMode,omitempty"`
	InitialPending        []string                   `json:"initialPending,omitempty"`
	CurrentPending        []string                   `json:"currentPending,omitempty"`
	Attempts              []JobAttempt               `json:"jobAttempts,omitempty"`
	BundleName            string                     `json:"bundleName,omitempty"`
	ApplyEvidence         *ApplyEvidence             `json:"applyEvidence,omitempty"`
	LifecycleWriterEpoch  *LifecycleWriterEpochFacts `json:"lifecycleWriterEpoch,omitempty"`
	CutoverMayHaveStarted bool                       `json:"cutoverMayHaveStarted"`
	MaintenanceStartedAt  time.Time                  `json:"maintenanceStartedAt,omitempty"`
	ForwardPhase          Phase                      `json:"forwardPhase,omitempty"`
	Provider              ProviderFacts              `json:"provider"`
	LastError             string                     `json:"lastError,omitempty"`
	UpdatedAt             time.Time                  `json:"updatedAt"`
}

func (s State) RequiresExclusiveDeployment() bool {
	return s.RequiredMode == ModeBlockedLegacy || s.RequiredMode == ModeExclusive ||
		(s.LifecycleWriterEpoch != nil && s.LifecycleWriterEpoch.Required)
}

func NewState(environment, releaseID, image string, snapshotRevision int, now time.Time) State {
	return State{SchemaVersion: CurrentStateSchemaVersion, Environment: environment, ReleaseID: releaseID, Image: image,
		Phase:     PhasePrepared,
		Helm:      HelmFacts{Release: "comma", Namespace: "comma", SnapshotRevision: snapshotRevision, ServingRevision: snapshotRevision},
		Provider:  ProviderFacts{Status: "pending"},
		UpdatedAt: now.UTC()}
}

func NewLegacyUpgradeState(environment, releaseID, image string, snapshotRevision int, now time.Time) State {
	state := NewState(environment, releaseID, image, snapshotRevision, now)
	state.RequiredMode = ModeBlockedLegacy
	return state
}

func (s State) ValidatePlan(plan Plan) error {
	var err error
	if s.RequiredMode == ModeBlockedLegacy {
		err = plan.ValidateLegacyUpgrade()
	} else {
		err = plan.Validate()
	}
	if err != nil {
		return err
	}
	pending := plan.CorePending()
	if s.ManifestDigest == "" {
		return nil
	}
	if s.ManifestDigest != plan.ManifestDigest {
		return errors.New("plan drift: manifest digest changed")
	}
	if !orderedSubset(pending, s.InitialPending) {
		return errors.New("plan drift: pending steps are not a monotonic subset")
	}
	if !orderedSubset(pending, s.CurrentPending) {
		return errors.New("plan drift: a completed step reappeared")
	}
	return nil
}

func orderedSubset(values, sequence []string) bool {
	next := 0
	for _, value := range sequence {
		if next < len(values) && values[next] == value {
			next++
		}
	}
	return next == len(values)
}

func cmpStrings(a, b string) int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}
