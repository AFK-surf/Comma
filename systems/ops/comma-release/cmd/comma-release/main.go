package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/AFK-surf/comma/systems/ops/comma-release/release"
)

const (
	exitUsage       = 2
	exitForwardOnly = 4
	exitUnhealthy   = 5
)

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdin, os.Stdout); err != nil {
		var e *exitError
		if errors.As(err, &e) {
			fmt.Fprintln(os.Stderr, e.err)
			os.Exit(e.code)
		}
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

type exitError struct {
	code int
	err  error
}

func (e *exitError) Error() string { return e.err.Error() }

func run(ctx context.Context, args []string, stdin io.Reader, stdout io.Writer) error {
	if len(args) > 0 && args[0] == "vmm-certificates" {
		return runVMMCertificates(ctx, args[1:], stdin, stdout)
	}
	if len(args) == 0 || len(args) > 3 {
		return &exitError{exitUsage, errors.New("usage: comma-release <plan|status|observe|reconcile|legacy-upgrade|prepare|migrate|sync-provider|finish-agent-configuration|publish-runtime-release|apply|verify|recover|repair> [--resume-forward] [--retry-failed]")}
	}
	command := args[0]
	replaceRelease := ""
	if command == "repair" {
		if len(args) != 3 || args[1] != "--replace-release" || args[2] == "" {
			return &exitError{exitUsage, errors.New("usage: comma-release repair --replace-release OLD_RELEASE_ID")}
		}
		replaceRelease = args[2]
		args = args[:1]
	}
	resumeForward, retryFailed := false, false
	seenFlags := map[string]bool{}
	for _, flag := range args[1:] {
		if seenFlags[flag] {
			return &exitError{exitUsage, fmt.Errorf("duplicate option %q", flag)}
		}
		seenFlags[flag] = true
		switch flag {
		case "--resume-forward":
			resumeForward = true
		case "--retry-failed":
			retryFailed = true
		default:
			return &exitError{exitUsage, fmt.Errorf("unknown option %q", flag)}
		}
	}
	if retryFailed && !resumeForward {
		return &exitError{exitUsage, errors.New("--retry-failed requires --resume-forward")}
	}
	resumePhase := release.Phase("")
	if resumeForward {
		switch command {
		case "migrate":
			resumePhase = release.PhaseCutover
		case "apply":
			resumePhase = release.PhaseApplying
		case "verify":
			resumePhase = release.PhaseVerifying
		default:
			return &exitError{exitUsage, fmt.Errorf("--resume-forward is not valid for %q", command)}
		}
	}
	if retryFailed && resumePhase != release.PhaseCutover {
		return &exitError{exitUsage, errors.New("--retry-failed is valid only for migrate forward recovery")}
	}
	if command == "plan" {
		var plan release.Plan
		body, err := io.ReadAll(stdin)
		if err != nil {
			return err
		}
		if len(strings.TrimSpace(string(body))) == 0 {
			body = []byte(os.Getenv("COMMA_RELEASE_PLAN_JSON"))
		}
		if err = json.Unmarshal(body, &plan); err != nil {
			return &exitError{exitUsage, fmt.Errorf("invalid plan envelope: %w", err)}
		}
		if err = plan.Validate(); err != nil {
			return err
		}
		return writeJSON(stdout, plan)
	}

	root := os.Getenv("COMMA_REPO_ROOT")
	if root == "" {
		var err error
		root, err = os.Getwd()
		if err != nil {
			return err
		}
	}
	specPath := os.Getenv("COMMA_RELEASE_ENV_SPEC")
	if specPath == "" {
		specPath = filepath.Join(root, "systems/ops/comma-release/environments", os.Getenv("COMMA_ENVIRONMENT")+".json")
	}
	var spec release.EnvironmentSpec
	body, err := os.ReadFile(specPath)
	if err != nil {
		return err
	}
	if err = json.Unmarshal(body, &spec); err != nil {
		return err
	}
	if spec.SchemaVersion != 1 {
		return errors.New("unsupported environment spec")
	}
	if err = release.LoadEnvironmentSpec(&spec, os.Getenv); err != nil {
		return err
	}
	kubectl := release.ExecRunner{Name: "kubectl"}
	store := release.KubectlStore{Runner: kubectl, Namespace: spec.Namespace}
	if command == "status" {
		record, loadErr := store.Load(ctx)
		if loadErr != nil {
			return loadErr
		}
		return writeJSON(stdout, publicState(record.State))
	}
	if command == "observe" {
		record, observeErr := store.Load(ctx)
		if observeErr != nil {
			return observeErr
		}
		observation := release.Observe(record.State, time.Now(), 20*time.Minute, 15*time.Minute, 30*time.Minute)
		if writeErr := writeJSON(stdout, observation); writeErr != nil {
			return writeErr
		}
		if !observation.Healthy {
			return &exitError{exitUnhealthy, errors.New("release observer found unhealthy durable facts")}
		}
		return nil
	}
	helmBinary := os.Getenv("COMMA_HELM_BIN")
	if helmBinary == "" {
		helmBinary = "helm"
	}
	chartReference := os.Getenv("COMMA_CHART_REF")
	if chartReference == "" {
		record, loadErr := store.Load(ctx)
		if loadErr == nil {
			chartReference = record.State.Artifacts.ChartReference
		} else if !errors.Is(loadErr, release.ErrNotFound) {
			return loadErr
		}
	}
	if chartReference == "" {
		return &exitError{exitUsage, errors.New("COMMA_CHART_REF is required until an immutable OCI chart reference exists in release state")}
	}
	chartDigest, err := release.OCIChartDigest(chartReference)
	if err != nil {
		return &exitError{exitUsage, err}
	}
	helm := release.HelmAdapter{Runner: release.ExecRunner{Name: helmBinary}, Release: "comma", Namespace: spec.Namespace,
		Chart: chartReference, HistoryMax: release.DefaultHelmHistoryMax, Timeout: 20 * time.Minute}
	platform := release.KubectlPlatform{Kubectl: kubectl, Gcloud: release.ExecRunner{Name: "gcloud"}, Curl: release.ExecRunner{Name: "curl"}, Helm: helm, Spec: spec}
	hardCut, err := lifecycleHardCutOptIn()
	if err != nil {
		return &exitError{exitUsage, err}
	}
	engine := release.Engine{
		Store: store, Platform: platform, ChartReference: chartReference, ChartDigest: chartDigest,
		RequireLifecycleWriterEpoch: hardCut,
		AuthorizeShutdown: release.GitHubShutdownApproval{
			Repository:  os.Getenv("GITHUB_REPOSITORY"),
			NotifyIssue: shutdownSlackNotifier(spec, release.ExecRunner{Name: "gcloud"}),
		}.Authorize,
	}
	var state release.State
	if resumeForward {
		releaseID := os.Getenv("COMMA_RELEASE_ID")
		if releaseID == "" {
			return &exitError{exitUsage, errors.New("COMMA_RELEASE_ID is required for forward recovery fencing")}
		}
		if _, err = engine.ResumeForward(ctx, releaseID, resumePhase, retryFailed); err != nil {
			return err
		}
	}
	switch command {
	case "prepare", "reconcile", "legacy-upgrade", "repair":
		releaseID, image := os.Getenv("COMMA_RELEASE_ID"), os.Getenv("COMMA_IMAGE")
		if releaseID == "" || image == "" {
			return &exitError{exitUsage, errors.New("COMMA_RELEASE_ID and COMMA_IMAGE are required")}
		}
		if !immutableCommaImage.MatchString(image) {
			return &exitError{exitUsage, errors.New("COMMA_IMAGE must use an immutable image digest")}
		}
		var bundle []byte
		bundle, err = buildBundle(ctx, spec, release.ExecRunner{Name: "gcloud"}, kubectl)
		if err != nil {
			return err
		}
		if command == "repair" {
			state, err = engine.PrepareRepair(ctx, spec.Environment, releaseID, image, bundle, replaceRelease)
		} else if command == "legacy-upgrade" {
			state, err = engine.PrepareLegacyUpgrade(ctx, spec.Environment, releaseID, image, bundle)
		} else {
			state, err = engine.Prepare(ctx, spec.Environment, releaseID, image, bundle)
		}
		if err == nil && (command == "reconcile" || command == "legacy-upgrade" || command == "repair") {
			state, err = engine.Reconcile(ctx)
			if err == nil {
				err = platform.FinishAgentConfiguration(ctx, state)
			}
			if err == nil {
				err = platform.PublishRuntimeRelease(ctx, state)
			}
		}
	case "migrate":
		state, err = engine.Migrate(ctx)
	case "finish-agent-configuration", "publish-runtime-release":
		record, loadErr := store.Load(ctx)
		if loadErr != nil {
			return loadErr
		}
		state = record.State
		if command == "publish-runtime-release" {
			err = platform.PublishRuntimeRelease(ctx, state)
		} else {
			err = platform.FinishAgentConfiguration(ctx, state)
		}
	case "sync-provider":
		state, err = engine.SyncProvider(ctx)
	case "apply":
		state, err = engine.Apply(ctx)
	case "verify":
		state, err = engine.Verify(ctx)
	case "recover":
		releaseID := os.Getenv("COMMA_RELEASE_ID")
		if releaseID == "" {
			return &exitError{exitUsage, errors.New("COMMA_RELEASE_ID is required for recovery fencing")}
		}
		state, err = engine.Recover(ctx, releaseID)
	default:
		return &exitError{exitUsage, fmt.Errorf("unknown command %q", command)}
	}
	if err != nil {
		return err
	}
	if err = writeJSON(stdout, publicState(state)); err != nil {
		return err
	}
	return stateExitError(state)
}

var immutableCommaImage = regexp.MustCompile(`^ghcr\.io/afk-surf/comma@sha256:[0-9a-f]{64}$`)

func lifecycleHardCutOptIn() (bool, error) {
	switch os.Getenv("COMMA_SESSION_LIFECYCLE_HARD_CUT") {
	case "":
		return false, nil
	case "1":
		return true, nil
	default:
		return false, errors.New("COMMA_SESSION_LIFECYCLE_HARD_CUT must be exactly 1 when enabled")
	}
}

func stateExitError(state release.State) error {
	if state.Phase == release.PhaseForwardOnly {
		return &exitError{exitForwardOnly, errors.New("cutover may have started; recovery is forward-only")}
	}
	return nil
}

type stateSummary struct {
	SchemaVersion         int                          `json:"schemaVersion"`
	Environment           string                       `json:"environment"`
	ReleaseID             string                       `json:"releaseId"`
	Image                 string                       `json:"image"`
	Artifacts             release.ArtifactFacts        `json:"artifacts"`
	Helm                  release.HelmFacts            `json:"helm"`
	Phase                 release.Phase                `json:"phase"`
	ManifestDigest        string                       `json:"manifestDigest,omitempty"`
	RequiredMode          release.Mode                 `json:"requiredMode,omitempty"`
	InitialPending        []string                     `json:"initialPending,omitempty"`
	CurrentPending        []string                     `json:"currentPending,omitempty"`
	Attempts              []release.JobAttempt         `json:"jobAttempts,omitempty"`
	BundleName            string                       `json:"bundleName,omitempty"`
	ApplyManifestDigest   string                       `json:"applyManifestDigest,omitempty"`
	LifecycleWriterEpoch  *lifecycleWriterEpochSummary `json:"lifecycleWriterEpoch,omitempty"`
	CutoverMayHaveStarted bool                         `json:"cutoverMayHaveStarted"`
	MaintenanceStartedAt  time.Time                    `json:"maintenanceStartedAt,omitempty"`
	ForwardPhase          release.Phase                `json:"forwardPhase,omitempty"`
	Provider              release.ProviderFacts        `json:"provider"`
	LastError             string                       `json:"lastError,omitempty"`
	UpdatedAt             time.Time                    `json:"updatedAt"`
}

type lifecycleWriterEpochSummary struct {
	Required        bool      `json:"required"`
	Status          string    `json:"status,omitempty"`
	Generation      int64     `json:"generation,omitempty"`
	LeaseExpiresAt  time.Time `json:"leaseExpiresAt,omitempty"`
	DrainedAt       time.Time `json:"drainedAt,omitempty"`
	LastInventoryAt time.Time `json:"lastInventoryAt,omitempty"`
	ReleasedAt      time.Time `json:"releasedAt,omitempty"`
}

func publicState(state release.State) stateSummary {
	result := stateSummary{
		SchemaVersion: state.SchemaVersion,
		Environment:   state.Environment, ReleaseID: state.ReleaseID,
		Image: state.Image, Artifacts: state.Artifacts, Helm: state.Helm, Phase: state.Phase, ManifestDigest: state.ManifestDigest, RequiredMode: state.RequiredMode,
		InitialPending: state.InitialPending, CurrentPending: state.CurrentPending,
		Attempts:   state.Attempts,
		BundleName: state.BundleName, CutoverMayHaveStarted: state.CutoverMayHaveStarted, MaintenanceStartedAt: state.MaintenanceStartedAt,
		ForwardPhase: state.ForwardPhase, Provider: state.Provider,
		LastError: state.LastError, UpdatedAt: state.UpdatedAt,
	}
	if state.ApplyEvidence != nil {
		result.ApplyManifestDigest = state.ApplyEvidence.ManifestDigest
	}
	if state.LifecycleWriterEpoch != nil {
		epoch := state.LifecycleWriterEpoch
		result.LifecycleWriterEpoch = &lifecycleWriterEpochSummary{
			Required: epoch.Required, Status: epoch.Status, Generation: epoch.Generation,
			LeaseExpiresAt: epoch.LeaseExpiresAt, DrainedAt: epoch.DrainedAt,
			LastInventoryAt: epoch.LastInventoryAt,
			ReleasedAt:      epoch.ReleasedAt,
		}
	}
	return result
}

func writeJSON(w io.Writer, value any) error {
	encoder := json.NewEncoder(w)
	encoder.SetEscapeHTML(false)
	return encoder.Encode(value)
}
