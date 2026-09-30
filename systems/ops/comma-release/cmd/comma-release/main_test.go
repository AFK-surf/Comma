package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/AFK-surf/comma/systems/ops/comma-release/release"
)

func TestPlanCommandIsPureAndStable(t *testing.T) {
	pending := release.MigrationStepV2{ID: "a", Owner: "test", Store: "postgres", Version: 1, Source: "test", Checksum: "sha256:test", Phase: "expand", Compatibility: map[string]bool{"oldRuntimeRead": true, "oldRuntimeWrite": true, "newRuntimeRead": true, "newRuntimeWrite": true}, Execution: release.MigrationExecutionFacts{Transactional: true, TimeoutSeconds: 300, LockBudgetSeconds: 5}, Safety: release.MigrationSafetyFacts{RollbackStrategy: "none"}, Postconditions: []string{"complete"}, Repair: "exact_retry"}
	p := release.Plan{SchemaVersion: 2, ManifestDigest: "sha256:" + string(bytes.Repeat([]byte("a"), 64)), RequiredMode: release.ModeOnline, PendingIDs: []string{"a"}, PendingSteps: []release.MigrationStepV2{pending}}
	if err := p.Validate(); err != nil {
		t.Fatal(err)
	}
	in := bytes.NewReader(release.Encode(p))
	var out bytes.Buffer
	if err := run(context.Background(), []string{"plan"}, in, &out); err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(out.Bytes(), []byte(p.ManifestDigest)) {
		t.Fatalf("output: %s", out.String())
	}
	var decoded release.Plan
	if err := json.Unmarshal(out.Bytes(), &decoded); err != nil || len(decoded.PendingSteps) != 1 || decoded.PendingSteps[0].Owner != "test" || decoded.PendingSteps[0].Safety.RollbackStrategy != "none" {
		t.Fatalf("plan command lost V2 contract facts: %#v err=%v", decoded, err)
	}
}

func TestPublicStateOmitsRawRecoveryAndApplyResources(t *testing.T) {
	state := release.State{
		SchemaVersion: release.CurrentStateSchemaVersion,
		Environment:   "staging", ReleaseID: "release-1", Image: "image", Phase: release.PhaseApplying,
		ManifestDigest: "manifest", RequiredMode: release.ModeExclusive, CurrentPending: []string{"step"},
		Helm:          release.HelmFacts{SnapshotRevision: 2},
		ApplyEvidence: &release.ApplyEvidence{ManifestDigest: "applied", HelmRevision: 3},
		UpdatedAt:     time.Unix(1, 0).UTC(),
	}
	body, err := json.Marshal(publicState(state))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(body, []byte("must-not-log")) || bytes.Contains(body, []byte(`"resources"`)) || bytes.Contains(body, []byte("snapshotRevisions")) {
		t.Fatalf("public state leaked raw resources: %s", body)
	}
	for _, expected := range []string{"\"snapshotRevision\":2", "applied", "manifest"} {
		if !bytes.Contains(body, []byte(expected)) {
			t.Fatalf("public state omitted %q: %s", expected, body)
		}
	}
}

func TestPublicStateRedactsLifecycleEpochFencingToken(t *testing.T) {
	now := time.Now().UTC()
	state := release.State{
		SchemaVersion: release.CurrentStateSchemaVersion,
		ReleaseID:     "lifecycle-v1",
		Phase:         release.PhaseVerifying,
		Helm:          release.HelmFacts{SnapshotRevision: 1, ServingRevision: 1, MaintenanceRevision: 2},
		LifecycleWriterEpoch: &release.LifecycleWriterEpochFacts{
			Required: true, Status: "active", Generation: 7,
			FencingToken: "must-not-log-fencing-token", LeaseExpiresAt: now.Add(time.Minute),
			DrainedAt: now, LastInventoryAt: now,
		},
	}
	body, err := json.Marshal(publicState(state))
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(body, []byte("must-not-log")) || bytes.Contains(body, []byte("fencingToken")) {
		t.Fatalf("public state leaked lifecycle epoch token: %s", body)
	}
	for _, expected := range []string{
		`"status":"active"`,
		`"generation":7`,
	} {
		if !bytes.Contains(body, []byte(expected)) {
			t.Fatalf("public state omitted lifecycle epoch evidence %q: %s", expected, body)
		}
	}
}

func TestLifecycleHardCutOptInIsExplicitAndStrict(t *testing.T) {
	t.Setenv("COMMA_SESSION_LIFECYCLE_HARD_CUT", "")
	if enabled, err := lifecycleHardCutOptIn(); err != nil || enabled {
		t.Fatalf("empty opt-in = %v, %v", enabled, err)
	}
	t.Setenv("COMMA_SESSION_LIFECYCLE_HARD_CUT", "1")
	if enabled, err := lifecycleHardCutOptIn(); err != nil || !enabled {
		t.Fatalf("enabled opt-in = %v, %v", enabled, err)
	}
	for _, invalid := range []string{"true", "0", "yes"} {
		t.Setenv("COMMA_SESSION_LIFECYCLE_HARD_CUT", invalid)
		if _, err := lifecycleHardCutOptIn(); err == nil {
			t.Fatalf("accepted ambiguous hard-cut opt-in %q", invalid)
		}
	}
}

func TestPlanRejectsUnknownMigrationPhase(t *testing.T) {
	body := []byte(`{"schemaVersion":2,"manifestDigest":"x","requiredMode":"online","pendingIDs":["a"],"pendingSteps":[{"id":"a","owner":"test","store":"postgres","version":1,"source":"test","checksum":"sha256:test","phase":"mystery","execution":{"transactional":true,"timeoutSeconds":300,"lockBudgetSeconds":5},"safety":{"rollbackStrategy":"none"},"postconditions":["complete"],"repair":"retry"}],"providerPendingIDs":[]}`)
	if err := run(context.Background(), []string{"plan"}, bytes.NewReader(body), &bytes.Buffer{}); err == nil {
		t.Fatal("expected rejection")
	}
}

func TestPlanRejectsLegacyV1Envelope(t *testing.T) {
	body := []byte(`{"schemaVersion":1,"manifestDigest":"legacy","requiredMode":"online","steps":[]}`)
	if err := run(context.Background(), []string{"plan"}, bytes.NewReader(body), &bytes.Buffer{}); err == nil {
		t.Fatal("legacy V1 execution envelope was accepted")
	}
}

func TestUsageListsTerminalAndAuditedLegacyUpgradeCommands(t *testing.T) {
	err := run(context.Background(), nil, bytes.NewReader(nil), &bytes.Buffer{})
	var exit *exitError
	if !errors.As(err, &exit) || exit.code != exitUsage {
		t.Fatalf("usage error = %v", err)
	}
	want := "usage: comma-release <plan|status|observe|reconcile|legacy-upgrade|prepare|migrate|sync-provider|finish-agent-configuration|publish-runtime-release|apply|verify|recover> [--resume-forward] [--retry-failed]"
	if exit.err.Error() != want {
		t.Fatalf("usage = %q, want %q", exit.err, want)
	}
}

func TestResumeForwardFlagIsLimitedToForwardStageCommands(t *testing.T) {
	var exit *exitError
	err := run(context.Background(), []string{"recover", "--resume-forward"}, bytes.NewReader(nil), &bytes.Buffer{})
	if !errors.As(err, &exit) || exit.code != exitUsage {
		t.Fatalf("invalid resume flag returned %v", err)
	}
}

func TestNormalReleaseIdentityRequiresImageDigest(t *testing.T) {
	digest := "ghcr.io/afk-surf/comma@sha256:" + string(bytes.Repeat([]byte("a"), 64))
	if !immutableCommaImage.MatchString(digest) {
		t.Fatalf("immutable digest was rejected: %s", digest)
	}
	for _, value := range []string{
		"ghcr.io/afk-surf/comma:sha-deadbee",
		"ghcr.io/afk-surf/comma:latest",
		"ghcr.io/afk-surf/comma@sha256:deadbee",
	} {
		if immutableCommaImage.MatchString(value) {
			t.Fatalf("mutable or malformed image identity was accepted: %s", value)
		}
	}
}

func TestForwardOnlyPhaseExitContract(t *testing.T) {
	for _, tc := range []struct {
		phase release.Phase
		code  int
	}{
		{phase: release.PhaseForwardOnly, code: exitForwardOnly},
		{phase: release.PhasePlanned, code: 0},
	} {
		err := stateExitError(release.State{Phase: tc.phase})
		if tc.code == 0 {
			if err != nil {
				t.Fatalf("phase %s returned %v", tc.phase, err)
			}
			continue
		}
		var exit *exitError
		if !errors.As(err, &exit) || exit.code != tc.code {
			t.Fatalf("phase %s exit = %#v, want %d", tc.phase, err, tc.code)
		}
	}
}

func TestSetNestedPreservesUnownedNestedConfig(t *testing.T) {
	target := map[string]any{
		"bridge_for_teams": map[string]any{
			"dashboard": map[string]any{
				"secret_key_base": "keep-secret",
				"server":          true,
			},
		},
	}
	setNested(target, "bridge_for_teams", map[string]any{
		"dashboard": map[string]any{"public_base_url": "https://teams.example"},
	})
	dashboard := target["bridge_for_teams"].(map[string]any)["dashboard"].(map[string]any)
	if dashboard["secret_key_base"] != "keep-secret" || dashboard["server"] != true || dashboard["public_base_url"] != "https://teams.example" {
		t.Fatalf("nested config was replaced instead of merged: %#v", dashboard)
	}
}

func TestCloudSQLInstanceNameIsNotCandidateSecretPayload(t *testing.T) {
	for _, name := range []string{
		"COMMA_RELEASE_COOKIE", "SALIX_CLOUDFLARE_ORIGIN_CERT", "SALIX_CLOUDFLARE_ORIGIN_KEY",
		"SALIX_SITES_CLOUDFLARE_ORIGIN_CERT", "SALIX_SITES_CLOUDFLARE_ORIGIN_KEY",
		"BFT_CLOUDFLARE_ORIGIN_CERT", "BFT_CLOUDFLARE_ORIGIN_KEY",
	} {
		t.Setenv(name, "test-value")
	}
	resources := candidateResources([]byte(`{"web":{"api_token":"secret"}}`), nil, nil, "redis://10.0.0.2:6379/0", nil)
	if len(resources) != 5 {
		t.Fatalf("candidate resources = %d, want five release Secrets", len(resources))
	}
	for _, resource := range resources {
		if strings.HasPrefix(resource.Name, "comma-bridge-db-") {
			t.Fatalf("non-secret Cloud SQL resource identity remained a candidate Secret: %s", resource.Name)
		}
		if _, ok := resource.Data["INSTANCE_CONNECTION_NAME"]; ok {
			t.Fatalf("non-secret Cloud SQL resource identity remained in %s", resource.Name)
		}
		body, err := json.Marshal(resource)
		if err != nil {
			t.Fatal(err)
		}
		if bytes.Contains(body, []byte(`"kind"`)) || bytes.Contains(body, []byte(`"binaryData"`)) {
			t.Fatalf("candidate retained generic Kubernetes resource shape: %s", body)
		}
	}
}

func TestReleaseEnvironmentRejectsAConfigFileFallback(t *testing.T) {
	for _, name := range []string{
		"COMMA_RELEASE_COOKIE",
		"SALIX_CLOUDFLARE_ORIGIN_CERT", "SALIX_CLOUDFLARE_ORIGIN_KEY",
		"SALIX_SITES_CLOUDFLARE_ORIGIN_CERT", "SALIX_SITES_CLOUDFLARE_ORIGIN_KEY",
		"BFT_CLOUDFLARE_ORIGIN_CERT", "BFT_CLOUDFLARE_ORIGIN_KEY", "COMMA_IMAGE",
		"COMMA_CHART_REF", "COMMA_TRACE_SAMPLE_RATIO", "COMMA_STATIC_IP", "COMMA_RELEASE_ID",
	} {
		t.Setenv(name, "configured")
	}
	t.Setenv("SALIX_CONFIG_JSON", "")
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "config.salix.prod.json"), []byte(`{"web":{"api_token":"file-only"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	t.Chdir(dir)

	err := validateEnvironment()
	if err == nil || err.Error() != "missing required release input SALIX_CONFIG_JSON" {
		t.Fatalf("file fallback was accepted: %v", err)
	}
}
