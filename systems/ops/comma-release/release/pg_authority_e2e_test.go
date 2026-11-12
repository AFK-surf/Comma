package release

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// This uses the release engine and generated Job boot against real BEAM and
// PostgreSQL. The existing platform fixture stands in for the Kubernetes API.
type pgAuthorityPlatform struct {
	*fakePlatform
	systems    string
	failImport bool
}

func (p *pgAuthorityPlatform) beam(ctx context.Context, mode string, job *JobSpec) ([]byte, error) {
	command := exec.CommandContext(ctx, "mix", "run", "--no-compile", "--no-start", "ops/comma-release/release/testdata/pg-authority/release.exs", mode)
	command.Dir = p.systems
	command.Env = append(os.Environ(), "MIX_ENV=test", "ERL_FLAGS=+S 4:4", "VERIFIED_KERNEL_PREBUILT=1", "SALIX_TEST_DB=comma_pg_release_e2e")
	if job != nil {
		manifest := (KubectlPlatform{Spec: EnvironmentSpec{Namespace: "local"}}).jobManifest(*job, map[string]string{})
		template := manifest["spec"].(map[string]any)["template"].(map[string]any)
		container := template["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)
		for _, item := range container["env"].([]any) {
			entry := item.(map[string]any)
			name := entry["name"].(string)
			if name == "COMMA_RELEASE_BOOT_EXPRESSION" || name == "COMMA_RELEASE_EXPRESSION" {
				expression := entry["value"].(string)
				if name == "COMMA_RELEASE_EXPRESSION" {
					// Use the existing planner seam for unrelated serving owners. The
					// executor, migration source, importers and completion ledger are real.
					expression = "PGAuthorityReleaseFixture.cutover(fn -> " + strings.TrimSuffix(expression, ")") + ", plan: &PGAuthorityReleaseFixture.plan/0) end)"
				}
				command.Env = append(command.Env, name+"="+expression)
			}
		}
	}
	output, err := command.CombinedOutput()
	if err != nil {
		return output, fmt.Errorf("BEAM %s: %w\n%s", mode, err, output)
	}
	return output, nil
}

func (p *pgAuthorityPlatform) RunPlan(ctx context.Context, _ State) (Plan, error) {
	output, err := p.beam(ctx, "plan", nil)
	if err != nil {
		return Plan{}, err
	}
	const marker = "PG_RELEASE_RESULT:"
	for _, line := range strings.Split(string(output), "\n") {
		if strings.HasPrefix(line, marker) {
			var plan Plan
			err = json.Unmarshal([]byte(strings.TrimPrefix(line, marker)), &plan)
			return plan, err
		}
	}
	return Plan{}, fmt.Errorf("BEAM plan omitted its result: %s", output)
}

func (p *pgAuthorityPlatform) RunJob(ctx context.Context, spec JobSpec) error {
	p.jobs = append(p.jobs, spec)
	mode := "cutover"
	if p.failImport {
		mode = "fail-cutover"
	}
	_, err := p.beam(ctx, mode, &spec)
	return err
}

func (p *pgAuthorityPlatform) Apply(ctx context.Context, state State) (ApplyEvidence, error) {
	if _, err := p.beam(ctx, "verify", nil); err != nil {
		return ApplyEvidence{}, err
	}
	return p.fakePlatform.Apply(ctx, state)
}

func TestPGAuthorityReleaseImportsBeforeApply(t *testing.T) {
	if os.Getenv("COMMA_RELEASE_PG_E2E") != "1" {
		t.Skip("set COMMA_RELEASE_PG_E2E=1 with local PostgreSQL and a compiled test BEAM")
	}
	_, source, _, _ := runtime.Caller(0)
	platform := &pgAuthorityPlatform{fakePlatform: &fakePlatform{}, systems: filepath.Clean(filepath.Join(filepath.Dir(source), "../../..")), failImport: true}
	ctx := context.Background()
	if _, err := platform.beam(ctx, "seed", nil); err != nil {
		t.Fatal(err)
	}
	store := &memoryStore{}
	engine := Engine{Store: store, Platform: platform, Now: func() time.Time { return bubbleStart }, AuthorizeShutdown: func(context.Context, State) error { return nil }}
	prepared, err := engine.Prepare(ctx, "staging", "pg-authority-local", "candidate", []byte("bundle"))
	if err != nil {
		t.Fatal(err)
	}
	if prepared.RequiredMode != ModeExclusive {
		t.Fatalf("mode=%s", prepared.RequiredMode)
	}
	if _, err = engine.Migrate(ctx); err == nil {
		t.Fatal("invalid Conversation source must fail the cutover")
	}
	if _, err = engine.Apply(ctx); err == nil || platform.applied {
		t.Fatal("failed import allowed Apply")
	}
	recovered, err := engine.Recover(ctx, "pg-authority-local")
	if err != nil || recovered.Phase != PhaseForwardOnly || !recovered.CutoverMayHaveStarted {
		t.Fatalf("recovery=%#v, %v", recovered, err)
	}
	platform.failImport = false
	platform.attemptStatus = "failed"
	if _, err = engine.ResumeForward(ctx, "pg-authority-local", PhaseCutover, true); err != nil {
		t.Fatal(err)
	}
	migrated, err := engine.Migrate(ctx)
	if err != nil || migrated.Phase != PhaseApplying {
		t.Fatalf("migration=%#v, %v", migrated, err)
	}
	if _, err = engine.Apply(ctx); err != nil || !platform.applied {
		t.Fatalf("Apply=%v", err)
	}
}
