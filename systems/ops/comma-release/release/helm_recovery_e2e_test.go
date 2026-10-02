package release

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHelmRecoveryE2E(t *testing.T) {
	if os.Getenv("COMMA_RELEASE_KUBERNETES_E2E") != "1" {
		t.Skip("set COMMA_RELEASE_KUBERNETES_E2E=1 on a disposable Kubernetes cluster")
	}
	baseNamespace := os.Getenv("COMMA_RELEASE_E2E_NAMESPACE")
	helmBinary := os.Getenv("COMMA_HELM_BIN")
	if baseNamespace == "" || helmBinary == "" {
		t.Fatal("COMMA_RELEASE_E2E_NAMESPACE and COMMA_HELM_BIN are required")
	}

	ctx := context.Background()
	kubectl := ExecRunner{Name: "kubectl"}
	namespace := baseNamespace + "-helm"
	if _, err := kubectl.Run(ctx, nil, "create", "namespace", namespace); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = kubectl.Run(context.Background(), nil, "delete", "namespace", namespace, "--wait=false")
	})
	helm := HelmAdapter{
		Runner: ExecRunner{Name: helmBinary}, Release: "comma", Namespace: namespace,
		Chart: filepath.Join("testdata", "recovery-chart"), Timeout: 5 * time.Minute,
		ValuesJSON: []byte("maintenance:\n  enabled: false\n"),
	}
	platform := KubectlPlatform{
		Kubectl: kubectl, Helm: helm,
		Spec: EnvironmentSpec{Environment: "e2e", Namespace: namespace, RuntimeServiceAccount: "runtime-local@local-project.iam.gserviceaccount.com"},
	}

	t.Run("missing Helm release fails before coordinator mutation", func(t *testing.T) {
		store := KubectlStore{Runner: kubectl, Namespace: namespace}
		engine := Engine{Store: store, Platform: platform, Now: time.Now}
		bundle := preflightBundle(t, "1.0")
		if _, err := engine.Prepare(ctx, "e2e", "no-helm", "example.invalid/comma@sha256:"+strings.Repeat("a", 64), bundle); err == nil || !strings.Contains(err.Error(), "no deployed releases") {
			t.Fatalf("Prepare without Helm release did not fail closed: %v", err)
		}
		assertKubernetesObjectMissing(t, kubectl, namespace, "configmap/comma-release-state")
		assertKubernetesObjectMissing(t, kubectl, namespace, "configmap/"+BundleName(bundle))
		assertNoReleaseJobs(t, kubectl, namespace)
	})

	upgrade := func(t *testing.T, maintenance bool) int {
		t.Helper()
		helm.ValuesJSON = []byte("maintenance:\n  enabled: " + map[bool]string{false: "false", true: "true"}[maintenance] + "\n")
		revision, err := helm.Upgrade(ctx, HelmUpgradeOptions{})
		if err != nil {
			t.Fatal(err)
		}
		return revision.Revision
	}
	installFixture := func(t *testing.T, maintenance bool) int {
		t.Helper()
		values := []byte("maintenance:\n  enabled: " + map[bool]string{false: "false", true: "true"}[maintenance] + "\n")
		if _, err := helm.Runner.Run(ctx, values,
			"install", helm.Release, helm.Chart,
			"--namespace", namespace, "--values", "-", "--timeout", helm.Timeout.String(), "--wait=watcher",
		); err != nil {
			t.Fatal(err)
		}
		revision, err := helm.Status(ctx)
		if err != nil {
			t.Fatal(err)
		}
		return revision.Revision
	}

	servingRevision := installFixture(t, false)
	maintenanceRevision := upgrade(t, true)

	t.Run("pre-cutover recovery rolls back the serving revision and waits for readiness", func(t *testing.T) {
		state := NewState("e2e", "pre-cutover", "image", servingRevision, time.Now())
		state.Phase = PhaseApplying
		store := &memoryStore{exists: true, record: Record{State: state, Version: "1"}}
		engine := Engine{Store: store, Platform: platform, Now: time.Now}

		recovered, err := engine.Recover(ctx, state.ReleaseID)
		if err != nil {
			t.Fatal(err)
		}
		if recovered.Phase != PhaseRecovered {
			t.Fatalf("recovery phase = %q, want %q", recovered.Phase, PhaseRecovered)
		}
		assertWorkloadReplicas(t, kubectl, namespace, "statefulset/comma", 1)
		assertWorkloadReplicas(t, kubectl, namespace, "deployment/comma-otel-collector", 1)
	})

	maintenanceRevision = upgrade(t, true)
	_ = upgrade(t, false)

	t.Run("post-cutover recovery restores maintenance and keeps writers absent", func(t *testing.T) {
		state := NewState("e2e", "post-cutover", "image", servingRevision, time.Now())
		state.Phase = PhaseApplying
		state.CutoverMayHaveStarted = true
		state.Helm.MaintenanceRevision = maintenanceRevision
		store := &memoryStore{exists: true, record: Record{State: state, Version: "1"}}
		engine := Engine{Store: store, Platform: platform, Now: time.Now}

		recovered, err := engine.Recover(ctx, state.ReleaseID)
		if err != nil {
			t.Fatal(err)
		}
		if recovered.Phase != PhaseForwardOnly || recovered.ForwardPhase != PhaseApplying {
			t.Fatalf("post-cutover recovery = %q/%q, want forward_only/applying", recovered.Phase, recovered.ForwardPhase)
		}
		assertWorkloadReplicas(t, kubectl, namespace, "statefulset/comma", 0)
		assertWorkloadReplicas(t, kubectl, namespace, "deployment/comma-otel-collector", 1)
	})

	t.Run("existing active and terminal state cannot bypass a missing Helm release", func(t *testing.T) {
		bundle := preflightBundle(t, "1.0")
		state := NewState("e2e", "existing-state", "example.invalid/comma@sha256:"+strings.Repeat("a", 64), servingRevision, time.Now())
		state.BundleName = BundleName(bundle)
		store := KubectlStore{Runner: kubectl, Namespace: namespace}
		record, err := store.Create(ctx, state)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = helm.Runner.Run(ctx, nil, "uninstall", helm.Release, "--namespace", namespace); err != nil {
			t.Fatal(err)
		}
		engine := Engine{Store: store, Platform: platform, Now: time.Now}

		for _, phase := range []Phase{PhasePrepared, PhaseSucceeded} {
			if phase == PhaseSucceeded {
				record.State.Phase = phase
				record, err = store.Update(ctx, record)
				if err != nil {
					t.Fatal(err)
				}
			}
			before := record.Version
			if _, err = engine.Prepare(ctx, state.Environment, state.ReleaseID, state.Image, bundle); err == nil || !strings.Contains(err.Error(), "no deployed releases") {
				t.Fatalf("existing %s state bypassed missing Helm release: %v", phase, err)
			}
			current, loadErr := store.Load(ctx)
			if loadErr != nil || current.Version != before {
				t.Fatalf("existing %s state mutated after Helm uninstall: version=%q/%q err=%v", phase, current.Version, before, loadErr)
			}
			assertKubernetesObjectMissing(t, kubectl, namespace, "configmap/"+state.BundleName)
			assertNoReleaseJobs(t, kubectl, namespace)
		}
	})
}

func assertKubernetesObjectMissing(t *testing.T, runner Runner, namespace, resource string) {
	t.Helper()
	if _, err := runner.Run(context.Background(), nil, "-n", namespace, "get", resource); err == nil || !containsNotFound(err.Error()) {
		t.Fatalf("%s unexpectedly exists or lookup did not return NotFound: %v", resource, err)
	}
}

func assertNoReleaseJobs(t *testing.T, runner Runner, namespace string) {
	t.Helper()
	body, err := runner.Run(context.Background(), nil, "-n", namespace, "get", "jobs", "-l", "app.kubernetes.io/name=comma-release", "-o", "json")
	if err != nil {
		t.Fatal(err)
	}
	var list struct {
		Items []json.RawMessage `json:"items"`
	}
	if json.Unmarshal(body, &list) != nil || len(list.Items) != 0 {
		t.Fatalf("release Jobs mutated before Helm bootstrap: %s", body)
	}
}

func assertWorkloadReplicas(t *testing.T, runner Runner, namespace, resource string, want int) {
	t.Helper()
	body, err := runner.Run(context.Background(), nil, "-n", namespace, "get", resource, "-o", "json")
	if err != nil {
		t.Fatal(err)
	}
	var workload struct {
		Spec struct {
			Replicas int `json:"replicas"`
		} `json:"spec"`
		Status struct {
			ReadyReplicas int `json:"readyReplicas"`
		} `json:"status"`
	}
	if json.Unmarshal(body, &workload) != nil || workload.Spec.Replicas != want || workload.Status.ReadyReplicas != want {
		t.Fatalf("%s replicas = spec:%d ready:%d, want %d", resource, workload.Spec.Replicas, workload.Status.ReadyReplicas, want)
	}
}

// Migration execution is covered by the namespace/database matrices. This
// fixture exercises real failed Helm/OrderedReady recovery and Pod replacement.
type helmRepairFixture struct {
	KubectlPlatform
	plan Plan
}

func (p *helmRepairFixture) Preflight(context.Context, []byte) (string, error) {
	return "sha256:repair-values", nil
}
func (p *helmRepairFixture) RunPlan(context.Context, State) (Plan, error) { return p.plan, nil }
func (p *helmRepairFixture) RunJob(context.Context, JobSpec) error        { return nil }
func (p *helmRepairFixture) Verify(ctx context.Context, state State) (ApplyEvidence, error) {
	if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "rollout", "status", "statefulset/comma", "--timeout=45s"); err != nil {
		return ApplyEvidence{}, err
	}
	revision, err := p.Helm.Status(ctx)
	return ApplyEvidence{HelmRevision: revision.Revision}, err
}

func TestHelmRepairE2E(t *testing.T) {
	if os.Getenv("COMMA_RELEASE_KUBERNETES_E2E") != "1" {
		t.Skip("requires disposable Kubernetes cluster")
	}
	namespace := os.Getenv("COMMA_RELEASE_E2E_NAMESPACE") + "-repair"
	kubectl := ExecRunner{Name: "kubectl"}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
	defer cancel()
	if _, err := kubectl.Run(ctx, nil, "create", "namespace", namespace); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = kubectl.Run(context.Background(), nil, "delete", "namespace", namespace, "--wait=false")
	})
	helm := HelmAdapter{Runner: ExecRunner{Name: os.Getenv("COMMA_HELM_BIN")}, Release: "comma", Namespace: namespace, Chart: filepath.Join("testdata", "recovery-chart"), Timeout: 8 * time.Second}
	healthy := []byte("maintenance:\n  enabled: false\nreplicas: 2\n")
	broken := []byte("maintenance:\n  enabled: false\nreplicas: 2\nunready: true\n")
	if _, err := helm.Runner.Run(ctx, healthy, "install", "comma", helm.Chart, "--namespace", namespace, "--values", "-", "--wait=watcher", "--timeout=90s"); err != nil {
		t.Fatal(err)
	}

	if _, err := helm.Runner.Run(ctx, broken, "upgrade", "comma", helm.Chart, "--namespace", namespace, "--values", "-"); err != nil {
		t.Fatal(err)
	}
	if _, err := kubectl.Run(ctx, nil, "-n", namespace, "rollout", "status", "statefulset/comma", "--timeout=5s"); err == nil {
		t.Fatal("broken template unexpectedly ready")
	}
	// Recreate ordinal 0 under the broken template to reproduce two bad Pods.
	if _, err := kubectl.Run(ctx, nil, "-n", namespace, "delete", "pod/comma-0", "--wait=true", "--timeout=15s"); err != nil {
		t.Fatal(err)
	}
	revision, err := helm.Status(ctx)
	if err != nil {
		t.Fatal(err)
	}
	store := KubectlStore{Runner: kubectl, Namespace: namespace}
	old := NewState("e2e", "broken-old", "registry.k8s.io/pause:3.10", revision.Revision, time.Now())
	old.Phase = PhaseApplying
	old.RequiredMode = ModeOnline
	old.ManifestDigest = "sha256:" + strings.Repeat("c", 64)
	old.Attempts = []JobAttempt{{Stage: "online", Attempt: 1, Name: JobName(old.ReleaseID, "online", 1), Status: "complete", AllowedStepIDs: []string{"already-applied"}}}
	if _, err = store.Create(ctx, old); err != nil {
		t.Fatal(err)
	}
	plan := testPlan(t, ModeOnline)
	plan.PendingIDs = nil
	plan.PendingSteps = nil
	platform := &helmRepairFixture{KubectlPlatform: KubectlPlatform{Kubectl: kubectl, Helm: helm, Spec: EnvironmentSpec{Environment: "e2e", Namespace: namespace}, HelmValues: []byte(`{"maintenance":{"enabled":false},"replicas":2,"rollout":{"partition":0}}`)}, plan: plan}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}
	if _, err = engine.Recover(ctx, old.ReleaseID); err == nil {
		t.Fatal("broken snapshot unexpectedly recovered")
	}
	bundle := []byte(`{"schemaVersion":1,"replacements":{}}`)
	if _, err = engine.Prepare(ctx, "e2e", "repair-new", old.Image, bundle); err == nil {
		t.Fatal("normal prepare accepted failed Helm")
	}
	platform.Helm.Timeout = 60 * time.Second
	if _, err = engine.PrepareRepair(ctx, "e2e", "repair-new", old.Image, bundle, old.ReleaseID); err != nil {
		t.Fatal(err)
	}
	archived, err := store.Archived(ctx, old.ReleaseID)
	if err != nil || archived.Phase != PhaseRecovering || archived.ManifestDigest != old.ManifestDigest || len(archived.Attempts) != 1 {
		t.Fatalf("old facts lost: %v", err)
	}
	state, err := engine.Reconcile(ctx)
	if err != nil || state.Phase != PhaseSucceeded {
		t.Fatalf("repair failed: phase=%s error=%v", state.Phase, err)
	}
	assertWorkloadReplicas(t, kubectl, namespace, "statefulset/comma", 2)
}
