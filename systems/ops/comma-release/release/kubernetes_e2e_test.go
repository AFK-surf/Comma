package release

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"slices"
	"strings"
	"testing"
	"time"
)

type namespaceFaultRunner struct {
	base             Runner
	failScale        bool
	scaleCalls       int
	lostJobCreate    bool
	lostCreateLanded bool
}

func externalSessionActivityCutoverPlan(t *testing.T) Plan {
	t.Helper()
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("could not resolve Kubernetes E2E source path")
	}
	manifestPath := filepath.Join(filepath.Dir(currentFile), "../../../apps/comma/priv/release/migration-manifest-v2.json")
	body, err := os.ReadFile(manifestPath)
	if err != nil {
		t.Fatal(err)
	}
	var manifest struct {
		SchemaVersion int              `json:"schemaVersion"`
		StepDefaults  map[string]any   `json:"stepDefaults"`
		Steps         []map[string]any `json:"steps"`
	}
	if err = json.Unmarshal(body, &manifest); err != nil {
		t.Fatal(err)
	}
	const id = "salix-20260807000101"
	index := slices.IndexFunc(manifest.Steps, func(step map[string]any) bool { return step["id"] == id })
	if index < 0 {
		t.Fatalf("checked-in migration manifest omits %s", id)
	}
	expanded := mergeJSONObjects(manifest.StepDefaults, manifest.Steps[index])
	expandedBody, err := json.Marshal(expanded)
	if err != nil {
		t.Fatal(err)
	}
	var step MigrationStepV2
	if err = json.Unmarshal(expandedBody, &step); err != nil {
		t.Fatal(err)
	}
	if step.Phase != "exclusive" || step.Compatibility["oldRuntimeRead"] || step.Compatibility["oldRuntimeWrite"] || step.Safety.RollbackStrategy != "none" {
		t.Fatalf("external Session Activity cutover contract drifted: %#v", step)
	}
	sum := sha256.Sum256(body)
	plan := Plan{
		SchemaVersion:  manifest.SchemaVersion,
		ManifestDigest: fmt.Sprintf("sha256:%x", sum),
		RequiredMode:   ModeExclusive,
		PendingIDs:     []string{id},
		PendingSteps:   []MigrationStepV2{step},
	}
	if err = plan.Validate(); err != nil {
		t.Fatal(err)
	}
	return plan
}

func mergeJSONObjects(defaults, overrides map[string]any) map[string]any {
	merged := make(map[string]any, len(defaults)+len(overrides))
	for key, value := range defaults {
		merged[key] = value
	}
	for key, value := range overrides {
		defaultObject, defaultIsObject := merged[key].(map[string]any)
		overrideObject, overrideIsObject := value.(map[string]any)
		if defaultIsObject && overrideIsObject {
			merged[key] = mergeJSONObjects(defaultObject, overrideObject)
			continue
		}
		merged[key] = value
	}
	return merged
}

func (r *namespaceFaultRunner) Run(ctx context.Context, body []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "get gateway/comma") {
		return nil, errors.New("NotFound: disposable cluster has no Gateway API CRD")
	}
	if strings.Contains(joined, " scale ") {
		r.scaleCalls++
		if r.failScale && r.scaleCalls == 1 {
			r.failScale = false
			return nil, errors.New("injected quiesce failure")
		}
	}
	if strings.Contains(joined, "create -f -") && strings.Contains(string(body), `"kind":"Job"`) && r.lostJobCreate && !r.lostCreateLanded {
		out, err := r.base.Run(ctx, body, args...)
		if err != nil {
			return out, err
		}
		r.lostCreateLanded = true
		return nil, errors.New("injected create response loss")
	}
	if strings.Contains(joined, "wait --for=condition=complete job/") {
		return nil, nil
	}
	if strings.Contains(joined, " logs job/") {
		return []byte("complete"), nil
	}
	return r.base.Run(ctx, body, args...)
}

type namespacePlatform struct {
	KubectlPlatform
	plan      Plan
	plans     []Plan
	failStage string
}

type providerJobPlatform struct {
	*namespacePlatform
	failAttempts map[int]bool
	delay        time.Duration
}

func (p *providerJobPlatform) StartJob(ctx context.Context, spec JobSpec) error {
	delay := p.delay
	if delay <= 0 {
		delay = time.Second
	}
	exitCode := 0
	if p.failAttempts[spec.Attempt] {
		exitCode = 1
	}
	annotations := map[string]string{
		"comma.surf/release-stage":   spec.Stage,
		"comma.surf/release-attempt": fmt.Sprint(spec.Attempt),
		"comma.surf/manifest-digest": spec.ManifestDigest,
		"comma.surf/fence":           spec.Fence,
	}
	manifest := map[string]any{
		"apiVersion": "batch/v1", "kind": "Job",
		"metadata": map[string]any{
			"name": spec.Name, "namespace": p.Spec.Namespace,
			"labels":      map[string]string{"app.kubernetes.io/name": "comma-release", "comma.surf/release-id": sanitize(spec.Fence)},
			"annotations": annotations,
		},
		"spec": map[string]any{
			"backoffLimit": 0,
			"template": map[string]any{
				"metadata": map[string]any{"labels": map[string]string{"app.kubernetes.io/name": "comma-release"}, "annotations": annotations},
				"spec": map[string]any{
					"restartPolicy": "Never",
					"containers": []any{map[string]any{
						"name": "release", "image": "busybox:1.36", "imagePullPolicy": "IfNotPresent",
						"command": []string{"/bin/sh", "-c"},
						"args":    []string{fmt.Sprintf("sleep %d; exit %d", max(1, int(delay.Seconds())), exitCode)},
					}},
				},
			},
		},
	}
	body, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	if _, err = p.Kubectl.Run(ctx, body, "create", "-f", "-"); err == nil {
		return nil
	}
	existing, readErr := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "job/"+spec.Name, "-o", "json")
	if readErr != nil {
		return err
	}
	return validateExistingJob(existing, manifest)
}

type failTerminalUpdateStore struct {
	StateStore
	failed bool
}

func (s *failTerminalUpdateStore) Update(ctx context.Context, record Record) (Record, error) {
	if record.State.Phase == PhaseSucceeded && !s.failed {
		s.failed = true
		return Record{}, errors.New("injected terminal state update failure")
	}
	return s.StateStore.Update(ctx, record)
}

type terminalCleanupPlatform struct {
	*namespacePlatform
}

func (p terminalCleanupPlatform) Verify(context.Context, State) (ApplyEvidence, error) {
	return ApplyEvidence{HelmRevision: 4}, nil
}

func (p *namespacePlatform) Preflight(context.Context, []byte) (string, error) {
	return "sha256:e2e-values", nil
}

// The namespace matrix exercises real durable state and fenced Kubernetes Job
// identities. Stable resource revision transitions are exercised separately by
// chart/test-local-kubernetes.sh; these fixture methods model only their
// externally visible revision/replica outcome and never enter production code.
func (p *namespacePlatform) CurrentHelmRevision(context.Context) (int, error) {
	return 1, nil
}

func (p *namespacePlatform) Quiesce(ctx context.Context, _ State) (int, error) {
	for _, resource := range []string{"statefulset/comma"} {
		if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "scale", resource, "--replicas=0"); err != nil {
			return 0, err
		}
	}
	return 2, nil
}

func (p *namespacePlatform) Restore(ctx context.Context, state State) error {
	for _, resource := range []string{"statefulset/comma"} {
		replicas := 1
		if state.CutoverMayHaveStarted {
			replicas = 0
		}
		if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "scale", resource, "--replicas="+fmt.Sprint(replicas)); err != nil {
			return err
		}
		if replicas > 0 {
			if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "rollout", "status", resource, "--timeout=2m"); err != nil {
				return err
			}
		}
	}
	return nil
}

type e2eBackendRunner struct {
	health    []byte
	namespace string
}

type unschedulableJobRunner struct {
	base   Runner
	target string
}

type lifecycleAcquireResumeRunner struct {
	base        Runner
	acquireJob  string
	releaseJob  string
	releaseID   string
	resumeExact bool
}

type lifecycleAcquireTerminalRepairRunner struct {
	base                     Runner
	acquireJob               string
	releaseJob               string
	releaseID                string
	repair                   bool
	initialAcquireSeen       bool
	initialAcquireTokenHash  [sha256.Size]byte
	initialAcquireGeneration string
}

func (r *unschedulableJobRunner) Run(ctx context.Context, body []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "get gateway/comma") {
		return nil, errors.New("NotFound: disposable cluster has no Gateway API CRD")
	}
	if strings.Contains(joined, "create -f -") && strings.Contains(string(body), `"kind":"Job"`) && strings.Contains(string(body), `"name":"`+r.target+`"`) {
		var manifest map[string]any
		if err := json.Unmarshal(body, &manifest); err != nil {
			return nil, err
		}
		spec := manifest["spec"].(map[string]any)
		template := spec["template"].(map[string]any)
		pod := template["spec"].(map[string]any)
		pod["nodeSelector"] = map[string]string{"comma.surf/never-schedule": "true"}
		body, _ = json.Marshal(manifest)
	}
	return r.base.Run(ctx, body, args...)
}

func (r *lifecycleAcquireResumeRunner) Run(ctx context.Context, body []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "get gateway/comma") {
		return nil, errors.New("NotFound: disposable cluster has no Gateway API CRD")
	}
	if strings.Contains(joined, "create -f -") &&
		strings.Contains(string(body), `"kind":"Job"`) &&
		strings.Contains(string(body), `"name":"`+r.acquireJob+`"`) {
		var manifest map[string]any
		if err := json.Unmarshal(body, &manifest); err != nil {
			return nil, err
		}
		spec := manifest["spec"].(map[string]any)
		template := spec["template"].(map[string]any)
		pod := template["spec"].(map[string]any)
		pod["nodeSelector"] = map[string]string{"comma.surf/never-schedule": "true"}
		body, _ = json.Marshal(manifest)
	}
	if strings.Contains(joined, "wait --for=condition=complete job/") {
		if strings.Contains(joined, "job/"+r.acquireJob) && !r.resumeExact {
			return nil, errors.New("injected lifecycle acquire runner loss")
		}
		return nil, nil
	}
	if strings.Contains(joined, "logs job/") {
		switch {
		case strings.Contains(joined, "job/"+r.acquireJob):
			if !r.resumeExact {
				return nil, errors.New("lifecycle acquire has no logs yet")
			}
			return lifecycleEpochE2ELog(r.releaseID, LifecycleEpochAcquire, 1), nil
		case strings.Contains(joined, "job/"+r.releaseJob):
			return lifecycleEpochE2ELog(r.releaseID, LifecycleEpochRelease, 1), nil
		default:
			return []byte("complete"), nil
		}
	}
	return r.base.Run(ctx, body, args...)
}

func (r *lifecycleAcquireTerminalRepairRunner) Run(ctx context.Context, body []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "get gateway/comma") {
		return nil, errors.New("NotFound: disposable cluster has no Gateway API CRD")
	}
	if strings.Contains(joined, "create -f -") &&
		strings.Contains(string(body), `"kind":"Job"`) {
		switch {
		case strings.Contains(string(body), `"name":"`+r.acquireJob+`"`):
			identity, err := lifecycleEpochE2EJobIdentity(body)
			if err != nil {
				return nil, err
			}
			tokenHash := sha256.Sum256([]byte(identity.Token))
			if !r.repair {
				if r.initialAcquireSeen ||
					identity.Action != "acquire" ||
					identity.ReleaseID != r.releaseID ||
					identity.Generation != "0" ||
					identity.Stage != "session-lifecycle-epoch-acquire" ||
					identity.Attempt != "1" ||
					identity.Fence != r.releaseID+":acquire:1" {
					return nil, errors.New("initial lifecycle acquire carrier identity mismatch")
				}
				r.initialAcquireSeen = true
				r.initialAcquireTokenHash = tokenHash
				r.initialAcquireGeneration = identity.Generation
			} else if !r.initialAcquireSeen ||
				tokenHash != r.initialAcquireTokenHash ||
				identity.Generation != r.initialAcquireGeneration ||
				identity.Action != "acquire" ||
				identity.ReleaseID != r.releaseID ||
				identity.Stage != "session-lifecycle-epoch-acquire" ||
				identity.Attempt != "1" ||
				identity.Fence != r.releaseID+":acquire:1" {
				return nil, errors.New("replacement lifecycle acquire did not preserve the durable identity")
			}
			script := "echo 'terminal acquire carrier omitted lifecycle evidence' >&2; exit 1"
			if r.repair {
				script = "printf '%s\\n' '" + string(lifecycleEpochE2ELog(r.releaseID, LifecycleEpochAcquire, 1)) + "'"
			}
			if body, err = rewriteLifecycleE2EJob(body, script); err != nil {
				return nil, err
			}
		case strings.Contains(string(body), `"name":"`+r.releaseJob+`"`):
			identity, err := lifecycleEpochE2EJobIdentity(body)
			if err != nil {
				return nil, err
			}
			if !r.initialAcquireSeen ||
				sha256.Sum256([]byte(identity.Token)) != r.initialAcquireTokenHash ||
				identity.Generation != "1" ||
				identity.Action != "release" ||
				identity.ReleaseID != r.releaseID ||
				identity.Stage != "session-lifecycle-epoch-release" ||
				identity.Attempt != "2" ||
				identity.Fence != r.releaseID+":release:2" {
				return nil, errors.New("lifecycle release did not settle the repaired acquire identity")
			}
			script := "printf '%s\\n' '" + string(lifecycleEpochE2ELog(r.releaseID, LifecycleEpochRelease, 1)) + "'"
			if body, err = rewriteLifecycleE2EJob(body, script); err != nil {
				return nil, err
			}
		}
	}
	if strings.Contains(joined, "wait --for=condition=complete job/") &&
		!strings.Contains(joined, "job/"+r.acquireJob) &&
		!strings.Contains(joined, "job/"+r.releaseJob) {
		return nil, nil
	}
	if strings.Contains(joined, " logs job/") &&
		!strings.Contains(joined, "job/"+r.acquireJob) &&
		!strings.Contains(joined, "job/"+r.releaseJob) {
		return []byte("complete"), nil
	}
	return r.base.Run(ctx, body, args...)
}

type lifecycleEpochE2EJobIdentityValue struct {
	Action     string
	ReleaseID  string
	Token      string
	Generation string
	Stage      string
	Attempt    string
	Fence      string
}

func lifecycleEpochE2EJobIdentity(body []byte) (lifecycleEpochE2EJobIdentityValue, error) {
	var manifest struct {
		Metadata struct {
			Annotations map[string]string `json:"annotations"`
		} `json:"metadata"`
		Spec struct {
			Template struct {
				Spec struct {
					Containers []struct {
						Env []struct {
							Name  string `json:"name"`
							Value string `json:"value"`
						} `json:"env"`
					} `json:"containers"`
				} `json:"spec"`
			} `json:"template"`
		} `json:"spec"`
	}
	if err := json.Unmarshal(body, &manifest); err != nil {
		return lifecycleEpochE2EJobIdentityValue{}, err
	}
	env := map[string]string{}
	for _, container := range manifest.Spec.Template.Spec.Containers {
		for _, value := range container.Env {
			env[value.Name] = value.Value
		}
	}
	identity := lifecycleEpochE2EJobIdentityValue{
		Action:     env["COMMA_SESSION_LIFECYCLE_EPOCH_ACTION"],
		ReleaseID:  env["COMMA_SESSION_LIFECYCLE_EPOCH_RELEASE_ID"],
		Token:      env["COMMA_SESSION_LIFECYCLE_EPOCH_TOKEN"],
		Generation: env["COMMA_SESSION_LIFECYCLE_EPOCH_GENERATION"],
		Stage:      manifest.Metadata.Annotations["comma.surf/release-stage"],
		Attempt:    manifest.Metadata.Annotations["comma.surf/release-attempt"],
		Fence:      manifest.Metadata.Annotations["comma.surf/fence"],
	}
	if identity.Action == "" || identity.ReleaseID == "" || identity.Token == "" ||
		identity.Generation == "" || identity.Stage == "" ||
		identity.Attempt == "" || identity.Fence == "" {
		return lifecycleEpochE2EJobIdentityValue{}, errors.New("lifecycle Job omitted its durable identity")
	}
	return identity, nil
}

func rewriteLifecycleE2EJob(body []byte, script string) ([]byte, error) {
	var manifest map[string]any
	if err := json.Unmarshal(body, &manifest); err != nil {
		return nil, err
	}
	spec := manifest["spec"].(map[string]any)
	template := spec["template"].(map[string]any)
	pod := template["spec"].(map[string]any)
	containers := pod["containers"].([]any)
	container := containers[0].(map[string]any)
	container["image"] = "busybox:1.36"
	container["imagePullPolicy"] = "IfNotPresent"
	container["command"] = []string{"/bin/sh", "-c"}
	container["args"] = []string{script}
	return json.Marshal(manifest)
}

func lifecycleEpochE2ELog(releaseID string, action LifecycleEpochAction, generation int64) []byte {
	now := time.Now().UTC()
	evidence := LifecycleEpochEvidence{
		SchemaVersion:  1,
		Action:         action,
		Status:         "active",
		ReleaseID:      releaseID,
		Generation:     generation,
		LeaseExpiresAt: now.Add(5 * time.Minute),
		DrainedAt:      now,
	}
	if action == LifecycleEpochRelease {
		evidence.Status = "released"
		evidence.ReleasedAt = now
	}
	body, _ := json.Marshal(evidence)
	return []byte(lifecycleEpochEvidenceMarkerPrefix + string(body))
}

type replaceBeforeAbortRunner struct {
	base        Runner
	target      string
	replacement []byte
	replaced    bool
}

type replaceAfterClaimRunner struct {
	base          Runner
	namespace     string
	target        string
	replacement   []byte
	replaced      bool
	sawRecovering bool
}

func (r *replaceAfterClaimRunner) Run(ctx context.Context, body []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	if strings.Contains(joined, " label job/"+r.target+" ") {
		out, err := r.base.Run(ctx, body, args...)
		if err != nil {
			return out, err
		}
		record, loadErr := (KubectlStore{Runner: r.base, Namespace: r.namespace}).Load(ctx)
		if loadErr == nil && record.State.Phase == PhaseRecovering {
			r.sawRecovering = true
		}
		return out, nil
	}
	if !r.replaced && strings.Contains(joined, " delete job -l comma.surf/abort-token=") {
		r.replaced = true
		if _, err := r.base.Run(ctx, nil, "-n", r.namespace, "delete", "job/"+r.target, "--wait=true"); err != nil {
			return nil, err
		}
		if _, err := r.base.Run(ctx, r.replacement, "create", "-f", "-"); err != nil {
			return nil, err
		}
	}
	return r.base.Run(ctx, body, args...)
}

func (r *replaceBeforeAbortRunner) Run(ctx context.Context, body []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	if !r.replaced && strings.Contains(joined, " label job/"+r.target+" ") {
		r.replaced = true
		if _, err := r.base.Run(ctx, nil, "-n", namespaceFromArgs(args), "delete", "job/"+r.target, "--wait=true"); err != nil {
			return nil, err
		}
		if _, err := r.base.Run(ctx, r.replacement, "create", "-f", "-"); err != nil {
			return nil, err
		}
	}
	return r.base.Run(ctx, body, args...)
}

func namespaceFromArgs(args []string) string {
	for i := range len(args) - 1 {
		if args[i] == "-n" {
			return args[i+1]
		}
	}
	return ""
}

func refreshKubeconfigEndpoint(t *testing.T, ctx context.Context, container string) {
	t.Helper()
	path := os.Getenv("COMMA_RELEASE_E2E_KUBECONFIG")
	if path == "" {
		return
	}
	out, err := (ExecRunner{Name: "docker"}).Run(ctx, nil, "port", container, "6443/tcp")
	if err != nil {
		t.Fatalf("could not read restarted Kubernetes endpoint: %v", err)
	}
	endpoint := strings.TrimSpace(string(out))
	if idx := strings.LastIndex(endpoint, "\n"); idx >= 0 {
		endpoint = strings.TrimSpace(endpoint[idx+1:])
	}
	if endpoint == "" {
		t.Fatal("restarted Kubernetes endpoint is empty")
	}
	body, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("could not read kubeconfig after restart: %v", err)
	}
	updated := regexp.MustCompile(`https://127\.0\.0\.1:[0-9]+`).ReplaceAll(body, []byte("https://"+endpoint))
	if err = os.WriteFile(path, updated, 0o600); err != nil {
		t.Fatalf("could not update kubeconfig after restart: %v", err)
	}
}

func (r e2eBackendRunner) Run(_ context.Context, _ []byte, args ...string) ([]byte, error) {
	if strings.Contains(strings.Join(args, " "), "backend-services list") {
		return []byte("lb-" + r.namespace + "-comma-salix-80-a\nlb-" + r.namespace + "-comma-teams-80-b\n"), nil
	}
	return r.health, nil
}

func (p *namespacePlatform) RunPlan(context.Context, State) (Plan, error) {
	if len(p.plans) > 0 {
		plan := p.plans[0]
		p.plans = p.plans[1:]
		return plan, nil
	}
	return p.plan, nil
}
func (p *namespacePlatform) RunJob(ctx context.Context, spec JobSpec) error {
	if p.failStage == spec.Stage {
		return errors.New("injected " + spec.Stage + " failure")
	}
	_, err := p.ensureJob(ctx, spec)
	if err == nil {
		p.plan.PendingIDs = without(p.plan.PendingIDs, spec.AllowedStepIDs)
		p.plan.PendingSteps = slices.DeleteFunc(p.plan.PendingSteps, func(step MigrationStepV2) bool { return slices.Contains(spec.AllowedStepIDs, step.ID) })
	}
	return err
}

func (p *namespacePlatform) StartJob(ctx context.Context, spec JobSpec) error {
	return p.KubectlPlatform.StartJob(ctx, spec)
}

func TestDisposableNamespaceRecoveryMatrix(t *testing.T) {
	if os.Getenv("COMMA_RELEASE_KUBERNETES_E2E") != "1" {
		t.Skip("set COMMA_RELEASE_KUBERNETES_E2E=1 with a disposable namespace")
	}
	namespace := os.Getenv("COMMA_RELEASE_E2E_NAMESPACE")
	if !strings.HasPrefix(namespace, "comma-release-e2e-") {
		t.Fatal("COMMA_RELEASE_E2E_NAMESPACE must be disposable and start with comma-release-e2e-")
	}
	ctx := context.Background()
	base := ExecRunner{Name: "kubectl"}
	applyNamespaceFixtures(t, ctx, base, namespace)
	bundle, _ := json.Marshal(CandidateBundle{SchemaVersion: 1, Replacements: map[string]string{
		"COMMA_SECRETS_NAME": "comma-e2e", "INSTANCE_CONNECTION_NAME": "project:region:instance", "SALIX_CONFIG_SECRET_NAME": "salix-e2e",
	}})

	reset := func(t *testing.T) {
		t.Helper()
		_, _ = base.Run(ctx, nil, "-n", namespace, "delete", "configmap/comma-release-state", "--ignore-not-found=true")
		_, _ = base.Run(ctx, nil, "-n", namespace, "delete", "job", "-l", "app.kubernetes.io/name=comma-release", "--ignore-not-found=true", "--wait=true")
		for _, resource := range []string{"statefulset/comma"} {
			if _, err := base.Run(ctx, nil, "-n", namespace, "scale", resource, "--replicas=1"); err != nil {
				t.Fatal(err)
			}
		}
	}
	replicas := func(t *testing.T, resource string) string {
		t.Helper()
		body, err := base.Run(ctx, nil, "-n", namespace, "get", resource, "-o", "jsonpath={.spec.replicas}")
		if err != nil {
			t.Fatal(err)
		}
		return string(body)
	}
	newEngine := func(t *testing.T, plan Plan, runner *namespaceFaultRunner) (Engine, *namespacePlatform) {
		t.Helper()
		platform := &namespacePlatform{KubectlPlatform: KubectlPlatform{Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}, plan: plan}
		return Engine{Store: KubectlStore{Runner: runner, Namespace: namespace}, Platform: platform, Now: time.Now}, platform
	}

	t.Run("public ingress ownership rejects a rogue Gateway route", func(t *testing.T) {
		const (
			httpRouteCRD = "httproutes.gateway.networking.k8s.io"
			publicHost   = "salix.e2e.invalid"
		)
		crd := []byte(`{
			"apiVersion":"apiextensions.k8s.io/v1",
			"kind":"CustomResourceDefinition",
			"metadata":{
				"name":"httproutes.gateway.networking.k8s.io",
				"annotations":{"api-approved.kubernetes.io":"https://github.com/kubernetes-sigs/gateway-api/pull/891"}
			},
			"spec":{
				"group":"gateway.networking.k8s.io",
				"names":{"kind":"HTTPRoute","listKind":"HTTPRouteList","plural":"httproutes","singular":"httproute"},
				"scope":"Namespaced",
				"versions":[{
					"name":"v1",
					"served":true,
					"storage":true,
					"schema":{"openAPIV3Schema":{"type":"object","x-kubernetes-preserve-unknown-fields":true}},
					"subresources":{"status":{}}
				}]
			}
		}`)
		if _, err := base.Run(ctx, crd, "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_, _ = base.Run(context.Background(), nil, "delete", "crd/"+httpRouteCRD, "--ignore-not-found=true", "--wait=true")
		})
		if _, err := base.Run(ctx, nil, "wait", "--for=condition=Established", "crd/"+httpRouteCRD, "--timeout=60s"); err != nil {
			t.Fatal(err)
		}

		createRoute := func(name string, hostnames []string, rules []any) {
			t.Helper()
			route := map[string]any{
				"apiVersion": "gateway.networking.k8s.io/v1",
				"kind":       "HTTPRoute",
				"metadata":   map[string]any{"name": name, "namespace": namespace},
				"spec": map[string]any{
					"parentRefs": []any{map[string]any{
						"group": "gateway.networking.k8s.io",
						"kind":  "Gateway",
						"name":  "comma",
					}},
					"hostnames": hostnames,
					"rules":     rules,
				},
			}
			body, err := json.Marshal(route)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = base.Run(ctx, body, "create", "-f", "-"); err != nil {
				t.Fatal(err)
			}
		}
		productRule := map[string]any{
			"matches": []any{
				map[string]any{"path": map[string]any{"type": "PathPrefix", "value": "/v1/comma"}},
				map[string]any{"path": map[string]any{"type": "PathPrefix", "value": "/oauth2"}},
				map[string]any{"path": map[string]any{"type": "PathPrefix", "value": "/.well-known"}},
				map[string]any{"path": map[string]any{"type": "PathPrefix", "value": "/v1/auth"}},
				map[string]any{"path": map[string]any{"type": "Exact", "value": "/v1/integrations/telegram/webhook"}},
				map[string]any{"path": map[string]any{"type": "Exact", "value": "/v1/integrations/telegram/connect/callback"}},
				map[string]any{"path": map[string]any{"type": "PathPrefix", "value": "/v1/me"}},
				map[string]any{"path": map[string]any{"type": "PathPrefix", "value": "/v1/workspaces"}},
				map[string]any{"path": map[string]any{"type": "PathPrefix", "value": "/v1/groups"}},
				map[string]any{"path": map[string]any{"type": "PathPrefix", "value": "/v1/billing"}},
			},
			"backendRefs": []any{map[string]any{"name": "comma-product", "port": 80}},
		}
		salixFallback := map[string]any{
			"backendRefs": []any{map[string]any{"name": "comma-salix", "port": 80}},
		}
		routerMatches := []any{}
		for _, path := range []string{"gcp", "grafana", "github", "runtime-storage"} {
			routerMatches = append(routerMatches, map[string]any{"path": map[string]any{"type": "Exact", "value": "/v1/events/" + path}})
		}
		routerRule := map[string]any{
			"matches":     routerMatches,
			"backendRefs": []any{map[string]any{"name": "comma-alert-router", "port": 80}},
		}
		for _, route := range []struct {
			name      string
			hostnames []string
			rules     []any
		}{
			{name: "comma-salix", hostnames: []string{publicHost}, rules: []any{routerRule, productRule, salixFallback}},
			{name: "comma-salix-sites"},
			{name: "comma-teams"},
		} {
			createRoute(route.name, route.hostnames, route.rules)
		}
		generation, err := base.Run(ctx, nil, "-n", namespace, "get", "httproute/comma-salix", "-o", "jsonpath={.metadata.generation}")
		if err != nil {
			t.Fatal(err)
		}
		status := []byte(fmt.Sprintf(`{
			"status":{"parents":[{
				"parentRef":{"group":"gateway.networking.k8s.io","kind":"Gateway","name":"comma"},
				"conditions":[
					{"type":"Accepted","status":"True","observedGeneration":%s},
					{"type":"ResolvedRefs","status":"True","observedGeneration":%s}
				]
			}]}
		}`, generation, generation))
		if _, err = base.Run(ctx, status, "-n", namespace, "patch", "httproute/comma-salix", "--subresource=status", "--type=merge", "-p", string(status)); err != nil {
			t.Fatal(err)
		}

		platform := KubectlPlatform{Kubectl: base, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}
		endpoint := []byte(fmt.Sprintf(`{"apiVersion":"discovery.k8s.io/v1","kind":"EndpointSlice","metadata":{"name":"router-ready","namespace":%q,"labels":{"kubernetes.io/service-name":"comma-alert-router"}},"addressType":"IPv4","ports":[{"name":"http","protocol":"TCP","port":80}],"endpoints":[{"addresses":["10.0.1.1"],"conditions":{"ready":true}}]}`, namespace))
		if _, err = base.Run(ctx, endpoint, "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		if err = platform.verifyAlertRouterServingPath(ctx, publicHost); err != nil {
			t.Fatalf("valid four-path Alert Router route was rejected: %v", err)
		}
		if err = platform.verifyPublicIngressOwnership(ctx, publicHost); err != nil {
			t.Fatalf("valid Gateway route inventory was rejected before rogue injection: %v", err)
		}
		createRoute("rogue-admin-route", []string{publicHost}, nil)
		if err = platform.verifyPublicIngressOwnership(ctx, publicHost); err == nil ||
			!strings.Contains(err.Error(), "public Gateway HTTPRoute set drifted") {
			t.Fatalf("rogue Gateway route was accepted: %v", err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "delete", "httproute/rogue-admin-route", "--wait=true"); err != nil {
			t.Fatal(err)
		}
		if err = platform.verifyPublicIngressOwnership(ctx, publicHost); err != nil {
			t.Fatalf("expected Gateway route inventory was rejected after cleanup: %v", err)
		}
		// A failed rollout may restore a revision without the optional log source.
		if _, err = base.Run(ctx, nil, "-n", namespace, "patch", "httproute/comma-salix", "--type=json", "-p", `[{"op":"remove","path":"/spec/rules/0/matches/3"}]`); err != nil {
			t.Fatal(err)
		}
		generation, err = base.Run(ctx, nil, "-n", namespace, "get", "httproute/comma-salix", "-o", "jsonpath={.metadata.generation}")
		if err != nil {
			t.Fatal(err)
		}
		status = []byte(fmt.Sprintf(`{"status":{"parents":[{"parentRef":{"name":"comma"},"conditions":[{"type":"Accepted","status":"True","observedGeneration":%s},{"type":"ResolvedRefs","status":"True","observedGeneration":%s}]}]}}`, generation, generation))
		if _, err = base.Run(ctx, nil, "-n", namespace, "patch", "httproute/comma-salix", "--subresource=status", "--type=merge", "-p", string(status)); err != nil {
			t.Fatal(err)
		}
		if err = platform.verifyAlertRouterServingPath(ctx, publicHost); err != nil {
			t.Fatalf("valid restored three-path Alert Router route was rejected: %v", err)
		}
	})

	t.Run("legacy provider durable phase fails closed without mutation", func(t *testing.T) {
		reset(t)
		state := NewState("e2e", "legacy-provider-phase", "busybox:1.36", 1, time.Now())
		state.Phase = Phase("provider")
		stateBody, err := json.Marshal(state)
		if err != nil {
			t.Fatal(err)
		}
		cm := configMap{APIVersion: "v1", Kind: "ConfigMap", Data: map[string]string{"state.json": string(stateBody)}}
		cm.Metadata.Name = stateConfigMap
		cm.Metadata.Namespace = namespace
		cmBody, err := json.Marshal(cm)
		if err != nil {
			t.Fatal(err)
		}
		created, err := base.Run(ctx, cmBody, "create", "-f", "-", "-o", "json")
		if err != nil {
			t.Fatal(err)
		}
		var createdCM configMap
		if err = json.Unmarshal(created, &createdCM); err != nil {
			t.Fatal(err)
		}

		runner := &namespaceFaultRunner{base: base}
		engine, _ := newEngine(t, testPlan(t, ModeOnline), runner)
		for name, call := range map[string]func() error{
			"status":    func() error { _, loadErr := engine.Store.Load(ctx); return loadErr },
			"reconcile": func() error { _, reconcileErr := engine.Reconcile(ctx); return reconcileErr },
			"recover":   func() error { _, recoverErr := engine.Recover(ctx, state.ReleaseID); return recoverErr },
		} {
			t.Run(name, func(t *testing.T) {
				if callErr := call(); callErr == nil || !strings.Contains(callErr.Error(), `unsupported release state phase "provider"`) {
					t.Fatalf("legacy provider phase did not fail closed: %v", callErr)
				}
			})
		}

		current, err := base.Run(ctx, nil, "-n", namespace, "get", "configmap/"+stateConfigMap, "-o", "json")
		if err != nil {
			t.Fatal(err)
		}
		var currentCM configMap
		if err = json.Unmarshal(current, &currentCM); err != nil {
			t.Fatal(err)
		}
		jobs, err := base.Run(ctx, nil, "-n", namespace, "get", "jobs", "-l", "app.kubernetes.io/name=comma-release", "-o", "jsonpath={.items[*].metadata.name}")
		if err != nil {
			t.Fatal(err)
		}
		if currentCM.Metadata.ResourceVersion != createdCM.Metadata.ResourceVersion || strings.TrimSpace(string(jobs)) != "" || replicas(t, "statefulset/comma") != "1" {
			t.Fatalf("legacy phase rejection mutated state or workloads: resourceVersion=%s/%s jobs=%q", createdCM.Metadata.ResourceVersion, currentCM.Metadata.ResourceVersion, jobs)
		}
	})

	t.Run("provider completion owner observes one real asynchronous Job", func(t *testing.T) {
		reset(t)
		state := NewState("e2e", "provider-complete", "busybox:1.36", 1, time.Now())
		state.Phase = PhaseSucceeded
		state.ManifestDigest = "sha256:" + strings.Repeat("a", 64)
		state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
		store := KubectlStore{Runner: base, Namespace: namespace}
		if _, err := store.Create(ctx, state); err != nil {
			t.Fatal(err)
		}
		runner := &namespaceFaultRunner{base: base}
		basePlatform := &namespacePlatform{KubectlPlatform: KubectlPlatform{Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}}
		platform := &providerJobPlatform{namespacePlatform: basePlatform}
		engine := Engine{Store: store, Platform: platform, Now: time.Now, ProviderPoll: 100 * time.Millisecond, ProviderBudget: 30 * time.Second}

		got, err := engine.Reconcile(ctx)
		if err != nil || got.Phase != PhaseSucceeded || got.Provider.Status != "succeeded" || got.Provider.Attempt != 1 {
			t.Fatalf("real provider completion = %#v, %v", got, err)
		}
		jobs, err := base.Run(ctx, nil, "-n", namespace, "get", "jobs", "-l", "comma.surf/release-id="+sanitize(state.ReleaseID+":"+state.ManifestDigest), "-o", "jsonpath={.items[*].metadata.name}")
		jobNames := strings.Fields(string(jobs))
		if err != nil || len(jobNames) != 1 || jobNames[0] != JobName(state.ReleaseID, "provider", 1) {
			t.Fatalf("provider Job cardinality = %q, %v", jobs, err)
		}
	})

	t.Run("provider failure retries with a second fenced Job", func(t *testing.T) {
		reset(t)
		state := NewState("e2e", "provider-retry", "busybox:1.36", 1, time.Now())
		state.Phase = PhaseSucceeded
		state.ManifestDigest = "sha256:" + strings.Repeat("b", 64)
		state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
		store := KubectlStore{Runner: base, Namespace: namespace}
		if _, err := store.Create(ctx, state); err != nil {
			t.Fatal(err)
		}
		runner := &namespaceFaultRunner{base: base}
		basePlatform := &namespacePlatform{KubectlPlatform: KubectlPlatform{Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}}
		platform := &providerJobPlatform{namespacePlatform: basePlatform, failAttempts: map[int]bool{1: true}}
		engine := Engine{Store: store, Platform: platform, Now: time.Now, ProviderPoll: 100 * time.Millisecond, ProviderBudget: 10 * time.Second}

		got, err := engine.Reconcile(ctx)
		if err != nil || got.Provider.Status != "succeeded" || got.Provider.Attempt != 2 || got.Phase != PhaseSucceeded {
			t.Fatalf("real provider retry = %#v, %v", got, err)
		}
		jobs, err := base.Run(ctx, nil, "-n", namespace, "get", "jobs", "-l", "comma.surf/release-id="+sanitize(state.ReleaseID+":"+state.ManifestDigest), "-o", "jsonpath={.items[*].metadata.name}")
		if err != nil || len(strings.Fields(string(jobs))) != 2 {
			t.Fatalf("provider retry cardinality = %q, %v", jobs, err)
		}
	})

	t.Run("provider create response loss reuses the exact landed Job", func(t *testing.T) {
		reset(t)
		state := NewState("e2e", "provider-create-loss", "busybox:1.36", 1, time.Now())
		state.Phase = PhaseSucceeded
		state.ManifestDigest = "sha256:" + strings.Repeat("c", 64)
		state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
		runner := &namespaceFaultRunner{base: base, lostJobCreate: true}
		store := KubectlStore{Runner: runner, Namespace: namespace}
		if _, err := store.Create(ctx, state); err != nil {
			t.Fatal(err)
		}
		basePlatform := &namespacePlatform{KubectlPlatform: KubectlPlatform{Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}}
		platform := &providerJobPlatform{namespacePlatform: basePlatform}
		engine := Engine{Store: store, Platform: platform, Now: time.Now, ProviderPoll: 100 * time.Millisecond, ProviderBudget: 10 * time.Second}

		got, err := engine.Reconcile(ctx)
		if err != nil || got.Provider.Status != "succeeded" || got.Provider.Attempt != 1 || !runner.lostCreateLanded {
			t.Fatalf("provider create-loss recovery = %#v, %v landed=%v", got, err, runner.lostCreateLanded)
		}
	})

	t.Run("provider outage times out degraded without reopening core", func(t *testing.T) {
		reset(t)
		state := NewState("e2e", "provider-timeout", "busybox:1.36", 1, time.Now())
		state.Phase = PhaseSucceeded
		state.ManifestDigest = "sha256:" + strings.Repeat("d", 64)
		state.Provider = ProviderFacts{Status: "pending", AllowedIDs: []string{"billing-provider"}}
		store := KubectlStore{Runner: base, Namespace: namespace}
		if _, err := store.Create(ctx, state); err != nil {
			t.Fatal(err)
		}
		runner := &namespaceFaultRunner{base: base}
		basePlatform := &namespacePlatform{KubectlPlatform: KubectlPlatform{Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}}
		platform := &providerJobPlatform{namespacePlatform: basePlatform, delay: 5 * time.Second}
		engine := Engine{Store: store, Platform: platform, Now: time.Now, ProviderPoll: 50 * time.Millisecond, ProviderBudget: 200 * time.Millisecond}

		got, err := engine.Reconcile(ctx)
		if err != nil || got.Phase != PhaseSucceeded || got.Provider.Status != "degraded" || got.Provider.JobName == "" {
			t.Fatalf("real provider timeout = %#v, %v", got, err)
		}
	})

	t.Run("partial V3 cutover with retired availability fails closed without mutation", func(t *testing.T) {
		reset(t)
		state := NewState("e2e", "partial-v3-cutover", "busybox:1.36", 1, time.Now())
		state.Phase = PhaseSucceeded
		var rawState map[string]any
		stateBody, err := json.Marshal(state)
		if err != nil || json.Unmarshal(stateBody, &rawState) != nil {
			t.Fatalf("encode V3 state: %v", err)
		}
		rawState["availability"] = map[string]any{"resources": map[string]bool{"statefulset/comma": true}, "replicas": map[string]int{"statefulset/comma": 1}}
		stateBody, err = json.Marshal(rawState)
		if err != nil {
			t.Fatal(err)
		}
		cm := configMap{APIVersion: "v1", Kind: "ConfigMap", Data: map[string]string{"state.json": string(stateBody)}}
		cm.Metadata.Name = stateConfigMap
		cm.Metadata.Namespace = namespace
		cmBody, err := json.Marshal(cm)
		if err != nil {
			t.Fatal(err)
		}
		created, err := base.Run(ctx, cmBody, "create", "-f", "-", "-o", "json")
		if err != nil {
			t.Fatal(err)
		}
		var createdCM configMap
		if err = json.Unmarshal(created, &createdCM); err != nil {
			t.Fatal(err)
		}

		runner := &namespaceFaultRunner{base: base}
		engine, _ := newEngine(t, testPlan(t, ModeOnline), runner)
		for name, call := range map[string]func() error{
			"status":    func() error { _, loadErr := engine.Store.Load(ctx); return loadErr },
			"reconcile": func() error { _, reconcileErr := engine.Reconcile(ctx); return reconcileErr },
			"recover":   func() error { _, recoverErr := engine.Recover(ctx, state.ReleaseID); return recoverErr },
		} {
			t.Run(name, func(t *testing.T) {
				if callErr := call(); callErr == nil || !strings.Contains(callErr.Error(), "retired availability field") {
					t.Fatalf("partial V3 cutover did not fail closed: %v", callErr)
				}
			})
		}

		current, err := base.Run(ctx, nil, "-n", namespace, "get", "configmap/"+stateConfigMap, "-o", "json")
		if err != nil {
			t.Fatal(err)
		}
		var currentCM configMap
		if err = json.Unmarshal(current, &currentCM); err != nil {
			t.Fatal(err)
		}
		if currentCM.Metadata.ResourceVersion != createdCM.Metadata.ResourceVersion || replicas(t, "statefulset/comma") != "1" {
			t.Fatalf("partial V3 cutover rejection mutated state or workloads: resourceVersion=%s/%s", createdCM.Metadata.ResourceVersion, currentCM.Metadata.ResourceVersion)
		}
		assertNoReleaseJobs(t, base, namespace)
	})

	t.Run("terminal verification rejects reintroduced Cloud SQL Secret drift", func(t *testing.T) {
		reset(t)
		stalePatch := `[{"op":"add","path":"/spec/template/spec/containers/1/env","value":[{"name":"INSTANCE_CONNECTION_NAME","valueFrom":{"secretKeyRef":{"name":"bridge-e2e","key":"INSTANCE_CONNECTION_NAME"}}}]}]`
		if _, err := base.Run(ctx, nil, "-n", namespace, "patch", "statefulset/comma", "--type=json", "-p="+stalePatch); err != nil {
			t.Fatal(err)
		}
		clean := func() {
			_, _ = base.Run(ctx, nil, "-n", namespace, "patch", "statefulset/comma", "--type=json", "-p="+`[{"op":"remove","path":"/spec/template/spec/containers/1/env"}]`)
		}
		t.Cleanup(clean)
		platform := KubectlPlatform{Kubectl: base, Helm: testHelm(&helmRunner{}), Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}
		if err := platform.verifyTerminalWorkloadShape(ctx); err == nil || !strings.Contains(err.Error(), "retired Cloud SQL INSTANCE_CONNECTION_NAME") {
			t.Fatalf("terminal verification accepted reintroduced Cloud SQL Secret drift: %v", err)
		}
		clean()
		if _, err := base.Run(ctx, nil, "-n", namespace, "rollout", "status", "statefulset/comma", "--timeout=2m"); err != nil {
			t.Fatal(err)
		}
		if err := platform.verifyTerminalWorkloadShape(ctx); err != nil {
			t.Fatalf("terminal verification rejected the repaired direct-argument shape: %v", err)
		}
	})

	t.Run("terminal state failure preserves snapshot candidate for recovery", func(t *testing.T) {
		reset(t)
		const releaseID = "terminal-save-failure"
		const snapshotSecret = "comma-release-e2e-snapshot-secret"
		candidate, _ := json.Marshal(map[string]any{
			"apiVersion": "v1", "kind": "Secret", "immutable": true,
			"metadata": map[string]any{
				"name": snapshotSecret, "namespace": namespace,
				"labels": map[string]string{"app.kubernetes.io/name": "comma-release-candidate"},
			},
			"stringData": map[string]string{"snapshot": "must-survive-terminal-save-failure"},
		})
		if _, err := base.Run(ctx, candidate, "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_, _ = base.Run(ctx, nil, "-n", namespace, "delete", "secret/"+snapshotSecret, "--ignore-not-found=true")
		})

		platform := &namespacePlatform{KubectlPlatform: KubectlPlatform{Kubectl: base, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}}
		bundleName, err := platform.EnsureBundle(ctx, BundleName(bundle), bundle)
		if err != nil {
			t.Fatal(err)
		}
		state := NewState("e2e", releaseID, "busybox:1.36", 1, time.Now())
		state.BundleName = bundleName
		state.Phase = PhaseVerifying
		state.RequiredMode = ModeOnline
		state.Helm.SnapshotRevision = 1
		baseStore := KubectlStore{Runner: base, Namespace: namespace}
		if _, err = baseStore.Create(ctx, state); err != nil {
			t.Fatal(err)
		}
		store := &failTerminalUpdateStore{StateStore: baseStore}
		engine := Engine{Store: store, Platform: terminalCleanupPlatform{namespacePlatform: platform}, Now: time.Now}

		if _, err = engine.Verify(ctx); err == nil || !strings.Contains(err.Error(), "injected terminal state update failure") {
			t.Fatalf("terminal update failure was not injected: %v", err)
		}
		persisted, loadErr := baseStore.Load(ctx)
		if loadErr != nil || persisted.State.Phase != PhaseVerifying {
			t.Fatalf("failed terminal update changed durable state: %#v %v", persisted.State, loadErr)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "secret/"+snapshotSecret); err != nil {
			t.Fatalf("snapshot candidate was collected before terminal state became durable: %v", err)
		}
		recovered, err := engine.Recover(ctx, releaseID)
		if err != nil || recovered.Phase != PhaseRecovered {
			t.Fatalf("snapshot recovery did not converge: %#v %v", recovered, err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "secret/"+snapshotSecret); err != nil {
			t.Fatalf("snapshot candidate disappeared during recovery: %v", err)
		}
	})

	t.Run("failed Kubernetes Job returns without waiting for Complete timeout", func(t *testing.T) {
		reset(t)
		platform := KubectlPlatform{Kubectl: base, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}
		bundleName, err := platform.EnsureBundle(ctx, BundleName(bundle), bundle)
		if err != nil {
			t.Fatal(err)
		}
		started := time.Now()
		_, err = platform.ensureJob(ctx, JobSpec{Name: "comma-release-e2e-failed-job", Stage: "plan", Image: "busybox:1.36", BundleName: bundleName, Fence: "failed-job"})
		if err == nil || !strings.Contains(err.Error(), "release job comma-release-e2e-failed-job failed") ||
			!strings.Contains(err.Error(), "cloud-sql-proxy") {
			t.Fatalf("failed Job did not return its terminal state and container log: %v", err)
		}
		if elapsed := time.Since(started); elapsed > 60*time.Second {
			t.Fatalf("failed Job detection took %s", elapsed)
		}
	})

	t.Run("unschedulable Kubernetes Job returns its scheduling reason", func(t *testing.T) {
		reset(t)
		const name = "comma-release-e2e-unschedulable"
		manifest, _ := json.Marshal(map[string]any{
			"apiVersion": "batch/v1",
			"kind":       "Job",
			"metadata": map[string]any{
				"name": name, "namespace": namespace,
				"labels": map[string]string{"app.kubernetes.io/name": "comma-release"},
			},
			"spec": map[string]any{
				"backoffLimit": 0,
				"template": map[string]any{
					"metadata": map[string]any{"labels": map[string]string{"app.kubernetes.io/name": "comma-release"}},
					"spec": map[string]any{
						"restartPolicy": "Never",
						"nodeSelector":  map[string]string{"comma.surf/never-schedule": "true"},
						"containers":    []any{map[string]any{"name": "release", "image": "busybox:1.36", "command": []string{"sleep", "300"}}},
					},
				},
			},
		})
		if _, err := base.Run(ctx, manifest, "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		platform := KubectlPlatform{Kubectl: base, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}, JobPendingTimeout: 5 * time.Second}
		started := time.Now()
		err := platform.waitForJob(ctx, name)
		if err == nil || !strings.Contains(err.Error(), "remained pending") || !strings.Contains(err.Error(), "Unschedulable") {
			t.Fatalf("unschedulable Job did not return its scheduling reason: %v", err)
		}
		if elapsed := time.Since(started); elapsed > 20*time.Second {
			t.Fatalf("unschedulable Job exceeded bounded diagnostic window: %s", elapsed)
		}
	})

	t.Run("recovered state aborts fenced live Job before idempotent return", func(t *testing.T) {
		reset(t)
		const releaseID = "recovered-live"
		attempt := NextAttempt(State{ReleaseID: releaseID}, "plan")
		manifest, _ := json.Marshal(map[string]any{
			"apiVersion": "batch/v1",
			"kind":       "Job",
			"metadata": map[string]any{
				"name": attempt.Name, "namespace": namespace,
				"labels":      map[string]string{"app.kubernetes.io/name": "comma-release", "comma.surf/release-id": sanitize(releaseID)},
				"annotations": map[string]string{"comma.surf/fence": releaseID},
			},
			"spec": map[string]any{
				"backoffLimit": 0,
				"template": map[string]any{
					"metadata": map[string]any{"labels": map[string]string{"app.kubernetes.io/name": "comma-release"}},
					"spec": map[string]any{
						"restartPolicy": "Never",
						"containers":    []any{map[string]any{"name": "release", "image": "busybox:1.36", "command": []string{"sleep", "300"}}},
					},
				},
			},
		})
		if _, err := base.Run(ctx, manifest, "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		state := NewState("e2e", releaseID, "busybox:1.36", 1, time.Now())
		state.Phase = PhaseRecovered
		state.Attempts = []JobAttempt{attempt}
		store := KubectlStore{Runner: base, Namespace: namespace}
		if _, err := store.Create(ctx, state); err != nil {
			t.Fatal(err)
		}
		platform := KubectlPlatform{Kubectl: base, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}
		got, err := (Engine{Store: store, Platform: platform, Now: time.Now}).Recover(ctx, releaseID)
		if err != nil || got.Attempts[0].Status != "aborted" {
			t.Fatalf("recovered live attempt did not converge: %#v %v", got, err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+attempt.Name); err == nil || !containsNotFound(err.Error()) {
			t.Fatalf("fenced live Job still exists after recovery: %v", err)
		}
		if replicas(t, "statefulset/comma") != "1" {
			t.Fatal("pre-cutover recovery mutated serving replicas")
		}
	})

	t.Run("pending timeout is aborted before recovery becomes terminal", func(t *testing.T) {
		reset(t)
		const releaseID = "pending-timeout"
		target := JobName(releaseID, "online", 1)
		runner := &unschedulableJobRunner{base: base, target: target}
		plan := testPlan(t, ModeOnline)
		platform := &namespacePlatform{
			KubectlPlatform: KubectlPlatform{Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}, JobPendingTimeout: 5 * time.Second},
			plan:            plan,
		}
		store := KubectlStore{Runner: runner, Namespace: namespace}
		engine := Engine{Store: store, Platform: platform, Now: time.Now}
		if _, err := engine.Prepare(ctx, "e2e", releaseID, "busybox:1.36", bundle); err != nil {
			t.Fatal(err)
		}
		if _, err := engine.Migrate(ctx); err == nil || !strings.Contains(err.Error(), "remained pending") {
			t.Fatalf("unschedulable mutation attempt did not time out: %v", err)
		}
		failed, err := store.Load(ctx)
		if err != nil || failed.State.Attempts[len(failed.State.Attempts)-1].Status != "failed" {
			t.Fatalf("client timeout was not durably recorded: %#v %v", failed.State, err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+target); err != nil {
			t.Fatalf("test did not preserve the live Job before recovery: %v", err)
		}
		got, err := engine.Recover(ctx, releaseID)
		if err != nil || got.Phase != PhaseRecovered || got.Attempts[len(got.Attempts)-1].Status != "aborted" {
			t.Fatalf("pending timeout recovery did not abort the attempt: %#v %v", got, err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+target); err == nil || !containsNotFound(err.Error()) {
			t.Fatalf("timed-out mutation Job survived terminal recovery: %v", err)
		}
		if replicas(t, "statefulset/comma") != "1" {
			t.Fatal("pending timeout recovery mutated serving replicas")
		}
	})

	t.Run("lifecycle recovery reattaches the exact pending acquire Job before release", func(t *testing.T) {
		reset(t)
		const releaseID = "epoch-resume"
		acquireJob := JobName(releaseID, "session-lifecycle-epoch-acquire", 1)
		releaseJob := JobName(releaseID, "session-lifecycle-epoch-release", 2)
		runner := &lifecycleAcquireResumeRunner{
			base: base, acquireJob: acquireJob, releaseJob: releaseJob, releaseID: releaseID,
		}
		platform := &namespacePlatform{
			KubectlPlatform: KubectlPlatform{
				Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"},
				JobPendingTimeout: 5 * time.Second,
			},
			plan: testPlan(t, ModeOnline),
		}
		store := KubectlStore{Runner: runner, Namespace: namespace}
		engine := Engine{
			Store: store, Platform: platform, Now: time.Now,
			RequireLifecycleWriterEpoch: true,
		}
		if _, err := engine.Prepare(ctx, "e2e", releaseID, "busybox:1.36", bundle); err != nil {
			t.Fatal(err)
		}
		failed, err := engine.Migrate(ctx)
		if err == nil || !strings.Contains(err.Error(), "remained pending") ||
			failed.LifecycleWriterEpoch == nil ||
			failed.LifecycleWriterEpoch.Status != "acquiring" ||
			failed.LifecycleWriterEpoch.OperationAttempt != 1 {
			t.Fatalf("pending lifecycle acquire did not retain its durable Job: state=%#v err=%v", failed, err)
		}
		before, err := base.Run(ctx, nil, "-n", namespace, "get", "job/"+acquireJob, "-o", "jsonpath={.metadata.uid}")
		if err != nil || strings.TrimSpace(string(before)) == "" {
			t.Fatalf("pending lifecycle acquire Job is missing: uid=%q err=%v", before, err)
		}

		runner.resumeExact = true
		recovered, err := engine.Recover(ctx, releaseID)
		if err != nil || recovered.Phase != PhaseRecovered ||
			recovered.LifecycleWriterEpoch.Status != "released" ||
			recovered.LifecycleWriterEpoch.OperationAttempt != 2 {
			t.Fatalf("exact lifecycle acquire did not settle before release: state=%#v err=%v", recovered, err)
		}
		after, err := base.Run(ctx, nil, "-n", namespace, "get", "job/"+acquireJob, "-o", "jsonpath={.metadata.uid}")
		if err != nil || string(after) != string(before) {
			t.Fatalf("recovery replaced the durable lifecycle acquire Job: before=%q after=%q err=%v", before, after, err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+JobName(releaseID, "session-lifecycle-epoch-acquire", 2)); err == nil || !containsNotFound(err.Error()) {
			t.Fatalf("recovery created a second lifecycle acquire Job: %v", err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+releaseJob); err != nil {
			t.Fatalf("recovery did not create release only after exact acquire evidence: %v", err)
		}
	})

	t.Run("terminal lifecycle acquire is foreground-replaced before exact recovery", func(t *testing.T) {
		reset(t)
		const releaseID = "epoch-term"
		acquireJob := JobName(releaseID, "session-lifecycle-epoch-acquire", 1)
		releaseJob := JobName(releaseID, "session-lifecycle-epoch-release", 2)
		runner := &lifecycleAcquireTerminalRepairRunner{
			base: base, acquireJob: acquireJob, releaseJob: releaseJob, releaseID: releaseID,
		}
		platform := &namespacePlatform{
			KubectlPlatform: KubectlPlatform{
				Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"},
				JobPendingTimeout: 5 * time.Second,
			},
			plan: testPlan(t, ModeOnline),
		}
		store := KubectlStore{Runner: runner, Namespace: namespace}
		engine := Engine{
			Store: store, Platform: platform, Now: time.Now,
			RequireLifecycleWriterEpoch: true,
		}
		if _, err := engine.Prepare(ctx, "e2e", releaseID, "busybox:1.36", bundle); err != nil {
			t.Fatal(err)
		}
		failed, err := engine.Migrate(ctx)
		if err == nil || !strings.Contains(err.Error(), "release job "+acquireJob+" failed") ||
			failed.LifecycleWriterEpoch == nil ||
			failed.LifecycleWriterEpoch.Status != "acquiring" ||
			failed.LifecycleWriterEpoch.OperationAttempt != 1 ||
			failed.CutoverMayHaveStarted {
			t.Fatalf("terminal lifecycle acquire did not retain its pre-cutover intent: state=%#v err=%v", failed, err)
		}

		body, err := base.Run(ctx, nil, "-n", namespace, "get", "job/"+acquireJob, "-o", "json")
		if err != nil {
			t.Fatal(err)
		}
		var job struct {
			Metadata struct {
				UID             string            `json:"uid"`
				ResourceVersion string            `json:"resourceVersion"`
				Annotations     map[string]string `json:"annotations"`
			} `json:"metadata"`
			Status struct {
				Active     int `json:"active"`
				Conditions []struct {
					Type   string `json:"type"`
					Status string `json:"status"`
				} `json:"conditions"`
			} `json:"status"`
		}
		if err = json.Unmarshal(body, &job); err != nil {
			t.Fatal(err)
		}
		terminal, err := jobTerminalCondition(body)
		if err != nil || terminal != "Failed" || job.Status.Active != 0 ||
			job.Metadata.UID == "" || job.Metadata.ResourceVersion == "" ||
			job.Metadata.Annotations["comma.surf/release-stage"] != "session-lifecycle-epoch-acquire" ||
			job.Metadata.Annotations["comma.surf/release-attempt"] != "1" ||
			job.Metadata.Annotations["comma.surf/fence"] != releaseID+":acquire:1" {
			t.Fatalf("terminal acquire did not satisfy repair preconditions: terminal=%q job=%#v err=%v", terminal, job, err)
		}
		oldUID := job.Metadata.UID
		claim := "comma.surf/abort-token=" + oldUID
		if _, err = base.Run(ctx, nil, "-n", namespace, "label", "job/"+acquireJob, claim, "--resource-version="+job.Metadata.ResourceVersion, "--overwrite"); err != nil {
			t.Fatalf("could not claim exact terminal acquire Job: %v", err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "delete", "job", "-l", claim, "--cascade=foreground", "--wait=true", "--timeout=2m"); err != nil {
			t.Fatalf("could not foreground-delete exact terminal acquire Job: %v", err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+acquireJob); err == nil || !containsNotFound(err.Error()) {
			t.Fatalf("terminal acquire Job survived foreground deletion: %v", err)
		}
		pods, err := base.Run(ctx, nil, "-n", namespace, "get", "pods", "-l", "job-name="+acquireJob, "-o", "name")
		if err != nil || strings.TrimSpace(string(pods)) != "" {
			t.Fatalf("terminal acquire Pods survived foreground deletion: pods=%q err=%v", pods, err)
		}

		runner.repair = true
		recovered, err := engine.Recover(ctx, releaseID)
		if err != nil || recovered.Phase != PhaseRecovered ||
			recovered.CutoverMayHaveStarted ||
			recovered.LifecycleWriterEpoch.Status != "released" ||
			recovered.LifecycleWriterEpoch.OperationAttempt != 2 {
			t.Fatalf("terminal acquire repair did not settle and release exact intent: state=%#v err=%v", recovered, err)
		}
		newUID, err := base.Run(ctx, nil, "-n", namespace, "get", "job/"+acquireJob, "-o", "jsonpath={.metadata.uid}")
		if err != nil || strings.TrimSpace(string(newUID)) == "" || strings.TrimSpace(string(newUID)) == oldUID {
			t.Fatalf("recovery did not replace the terminal execution carrier: old=%q new=%q err=%v", oldUID, newUID, err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+JobName(releaseID, "session-lifecycle-epoch-acquire", 2)); err == nil || !containsNotFound(err.Error()) {
			t.Fatalf("repair allocated a second acquire attempt: %v", err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+releaseJob); err != nil {
			t.Fatalf("repair did not release only after exact acquire evidence: %v", err)
		}
	})

	t.Run("abort CAS cannot delete a same-name replacement Job", func(t *testing.T) {
		reset(t)
		const releaseID = "abort-cas"
		attempt := NextAttempt(State{ReleaseID: releaseID}, "plan")
		job := func(fence string) []byte {
			body, _ := json.Marshal(map[string]any{
				"apiVersion": "batch/v1", "kind": "Job",
				"metadata": map[string]any{
					"name": attempt.Name, "namespace": namespace,
					"labels":      map[string]string{"app.kubernetes.io/name": "comma-release", "comma.surf/release-id": sanitize(fence)},
					"annotations": map[string]string{"comma.surf/fence": fence},
				},
				"spec": map[string]any{
					"backoffLimit": 0,
					"template": map[string]any{
						"metadata": map[string]any{"labels": map[string]string{"app.kubernetes.io/name": "comma-release"}},
						"spec":     map[string]any{"restartPolicy": "Never", "containers": []any{map[string]any{"name": "release", "image": "busybox:1.36", "command": []string{"sleep", "300"}}}},
					},
				},
			})
			return body
		}
		if _, err := base.Run(ctx, job(releaseID), "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		runner := &replaceBeforeAbortRunner{base: base, target: attempt.Name, replacement: job("replacement-release")}
		platform := KubectlPlatform{Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}
		state := NewState("e2e", releaseID, "busybox:1.36", 1, time.Now())
		state.Attempts = []JobAttempt{attempt}
		store := KubectlStore{Runner: runner, Namespace: namespace}
		if _, err := store.Create(ctx, state); err != nil {
			t.Fatal(err)
		}
		if _, err := (Engine{Store: store, Platform: platform, Now: time.Now}).Recover(ctx, releaseID); err == nil || !strings.Contains(err.Error(), "fence mismatch") {
			t.Fatalf("same-name replacement race was not rejected: %v", err)
		}
		body, err := base.Run(ctx, nil, "-n", namespace, "get", "job/"+attempt.Name, "-o", "jsonpath={.metadata.annotations.comma\\.surf/fence}")
		if err != nil || string(body) != "replacement-release" {
			t.Fatalf("abort deleted or changed the replacement Job: %q %v", body, err)
		}
		persisted, err := store.Load(ctx)
		if err != nil || persisted.State.Phase != PhaseRecovering || replicas(t, "statefulset/comma") != "1" {
			t.Fatalf("failed abort persisted recovery or mutated serving state: %#v %v", persisted.State, err)
		}
	})

	t.Run("durable recovery ownership converges same-fence replacement after abort claim", func(t *testing.T) {
		reset(t)
		const releaseID = "abort-post-claim"
		attempt := NextAttempt(State{ReleaseID: releaseID}, "plan")
		job := func() []byte {
			body, _ := json.Marshal(map[string]any{
				"apiVersion": "batch/v1", "kind": "Job",
				"metadata": map[string]any{
					"name": attempt.Name, "namespace": namespace,
					"labels":      map[string]string{"app.kubernetes.io/name": "comma-release", "comma.surf/release-id": sanitize(releaseID)},
					"annotations": map[string]string{"comma.surf/fence": releaseID},
				},
				"spec": map[string]any{
					"backoffLimit": 0,
					"template": map[string]any{
						"metadata": map[string]any{"labels": map[string]string{"app.kubernetes.io/name": "comma-release"}},
						"spec":     map[string]any{"restartPolicy": "Never", "containers": []any{map[string]any{"name": "release", "image": "busybox:1.36", "command": []string{"sleep", "300"}}}},
					},
				},
			})
			return body
		}
		if _, err := base.Run(ctx, job(), "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		state := NewState("e2e", releaseID, "busybox:1.36", 1, time.Now())
		state.Attempts = []JobAttempt{attempt}
		if _, err := (KubectlStore{Runner: base, Namespace: namespace}).Create(ctx, state); err != nil {
			t.Fatal(err)
		}
		runner := &replaceAfterClaimRunner{base: base, namespace: namespace, target: attempt.Name, replacement: job()}
		store := KubectlStore{Runner: runner, Namespace: namespace}
		platform := KubectlPlatform{Kubectl: runner, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}
		got, err := (Engine{Store: store, Platform: platform, Now: time.Now}).Recover(ctx, releaseID)
		if err != nil || got.Phase != PhaseRecovered || got.Attempts[0].Status != "aborted" || !runner.replaced || !runner.sawRecovering {
			t.Fatalf("post-claim replacement did not converge under durable recovery ownership: %#v %v runner=%#v", got, err, runner)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+attempt.Name); err == nil || !containsNotFound(err.Error()) {
			t.Fatalf("same-fence replacement survived terminal recovery: %v", err)
		}
		if replicas(t, "statefulset/comma") != "1" {
			t.Fatal("post-claim replacement recovery mutated serving replicas")
		}
	})

	t.Run("release Job kills an unready live proxy before bounded retry", func(t *testing.T) {
		reset(t)
		const toolsName = "comma-release-e2e-unready-tools"
		_, _ = base.Run(ctx, nil, "-n", namespace, "delete", "configmap/"+toolsName, "--ignore-not-found=true")
		tools, _ := json.Marshal(map[string]any{
			"apiVersion": "v1",
			"kind":       "ConfigMap",
			"metadata":   map[string]string{"name": toolsName, "namespace": namespace},
			"data": map[string]string{
				"cloud-sql-proxy": "#!/bin/sh\necho fake-proxy-attempt\nexec sleep 300\n",
				"curl":            "#!/bin/sh\nexit 1\n",
			},
		})
		if _, err := base.Run(ctx, tools, "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			_, _ = base.Run(ctx, nil, "-n", namespace, "delete", "configmap/"+toolsName, "--ignore-not-found=true")
		})

		platform := KubectlPlatform{Kubectl: base, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}
		replacements := map[string]string{"COMMA_SECRETS_NAME": "comma-e2e", "INSTANCE_CONNECTION_NAME": "project:region:instance", "SALIX_CONFIG_SECRET_NAME": "salix-e2e"}
		manifest := platform.jobManifest(JobSpec{Name: "comma-release-e2e-unready-proxy", Stage: "plan", Image: "busybox:1.36", Fence: "unready-proxy"}, replacements)
		pod := manifest["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
		container := pod["containers"].([]any)[0].(map[string]any)
		command := container["args"].([]string)[0]
		command = strings.Replace(command, "proxy=/usr/local/bin/cloud-sql-proxy", "proxy=/release-tools/cloud-sql-proxy", 1)
		command = strings.Replace(command, "curl --fail --silent --show-error", "/release-tools/curl", 1)
		command = strings.Replace(command, `while [ "${attempt}" -le 12 ]`, `while [ "${attempt}" -le 3 ]`, 1)
		command = strings.Replace(command, `while [ "${readiness_attempt}" -le 10 ]`, `while [ "${readiness_attempt}" -le 2 ]`, 1)
		command = strings.ReplaceAll(command, "sleep 1", "sleep 0.1")
		command = strings.ReplaceAll(command, "sleep 5", "sleep 0.1")
		container["args"] = []string{command}
		container["volumeMounts"] = append(container["volumeMounts"].([]any), map[string]any{"name": "release-tools", "mountPath": "/release-tools", "readOnly": true})
		pod["volumes"] = append(pod["volumes"].([]any), map[string]any{"name": "release-tools", "configMap": map[string]any{"name": toolsName, "defaultMode": 0o555}})

		body, _ := json.Marshal(manifest)
		if _, err := base.Run(ctx, body, "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		started := time.Now()
		err := platform.waitForJob(ctx, "comma-release-e2e-unready-proxy")
		if err == nil || !strings.Contains(err.Error(), "release job comma-release-e2e-unready-proxy failed") {
			t.Fatalf("unready proxy Job did not fail at its bounded limit: %v", err)
		}
		if elapsed := time.Since(started); elapsed > 20*time.Second {
			t.Fatalf("unready proxy retries exceeded bounded window: %s", elapsed)
		}
		logs, err := base.Run(ctx, nil, "-n", namespace, "logs", "job/comma-release-e2e-unready-proxy", "--all-containers=true")
		if err != nil {
			t.Fatal(err)
		}
		if attempts := strings.Count(string(logs), "fake-proxy-attempt"); attempts < 2 {
			t.Fatalf("unready live proxy was not killed and retried: attempts=%d logs=%s", attempts, logs)
		}
	})

	t.Run("online only never quiesces", func(t *testing.T) {
		reset(t)
		runner := &namespaceFaultRunner{base: base, lostJobCreate: true}
		engine, _ := newEngine(t, testPlan(t, ModeOnline), runner)
		var err error
		if _, err = engine.Prepare(ctx, "e2e", "online", "busybox:1.36", bundle); err != nil {
			t.Fatal(err)
		}
		if _, err = engine.Migrate(ctx); err != nil || !runner.lostCreateLanded || replicas(t, "statefulset/comma") != "1" {
			t.Fatalf("online/create ambiguity failed: %v", err)
		}
	})

	t.Run("stale recovery cannot touch a newer active release", func(t *testing.T) {
		reset(t)
		runner := &namespaceFaultRunner{base: base}
		engine, _ := newEngine(t, testPlan(t, ModeOnline), runner)
		if _, err := engine.Prepare(ctx, "e2e", "release-b", "busybox:1.36", bundle); err != nil {
			t.Fatal(err)
		}
		store := engine.Store.(KubectlStore)
		record, err := store.Load(ctx)
		if err != nil {
			t.Fatal(err)
		}
		record.State.Phase = PhaseOnline
		if _, err = store.Update(ctx, record); err != nil {
			t.Fatal(err)
		}
		if _, err = engine.Recover(ctx, "release-a"); err == nil {
			t.Fatal("stale recovery fence was accepted")
		}
		after, err := store.Load(ctx)
		if err != nil || after.State.ReleaseID != "release-b" || after.State.Phase != PhaseOnline || replicas(t, "statefulset/comma") != "1" {
			t.Fatalf("stale recovery mutated release B: %#v %v", after.State, err)
		}
	})

	for _, tc := range []struct {
		name    string
		phase   Phase
		attempt JobAttempt
	}{
		{
			name:    "plan",
			phase:   PhasePrepared,
			attempt: JobAttempt{Stage: "plan", Attempt: 1, Name: "comma-release-fresh-plan-plan-1", Status: "pending"},
		},
		{
			name:    "schema",
			phase:   PhaseOnline,
			attempt: JobAttempt{Stage: "online", Attempt: 1, Name: "comma-release-fresh-schema-online-1", Status: "pending"},
		},
	} {
		t.Run("fresh recovery process reads durable "+tc.name+" runner loss", func(t *testing.T) {
			reset(t)
			runner := &namespaceFaultRunner{base: base}
			engine, _ := newEngine(t, testPlan(t, ModeOnline), runner)
			releaseID := "fresh-" + tc.name
			if _, err := engine.Prepare(ctx, "e2e", releaseID, "busybox:1.36", bundle); err != nil {
				t.Fatal(err)
			}
			store := engine.Store.(KubectlStore)
			record, err := store.Load(ctx)
			if err != nil {
				t.Fatal(err)
			}
			record.State.Phase = tc.phase
			record.State.Attempts = []JobAttempt{tc.attempt}
			if _, err = store.Update(ctx, record); err != nil {
				t.Fatal(err)
			}

			wakeupRunner := &namespaceFaultRunner{base: base}
			wakeup, _ := newEngine(t, testPlan(t, ModeOnline), wakeupRunner)
			state, err := wakeup.Recover(ctx, releaseID)
			if err != nil || state.Phase != PhaseRecovered || replicas(t, "statefulset/comma") != "1" {
				t.Fatalf("fresh recovery process did not converge: %#v %v", state, err)
			}
			status, err := (KubectlStore{Runner: base, Namespace: namespace}).Load(ctx)
			if err != nil || status.State.Phase != PhaseRecovered || status.State.ReleaseID != releaseID {
				t.Fatalf("status did not observe durable recovery: %#v %v", status.State, err)
			}

			secondRunner := &namespaceFaultRunner{base: base}
			secondWakeup, _ := newEngine(t, testPlan(t, ModeOnline), secondRunner)
			again, err := secondWakeup.Recover(ctx, releaseID)
			if err != nil || again.Phase != PhaseRecovered {
				t.Fatalf("second fresh recovery was not idempotent: %#v %v", again, err)
			}

			retryReleaseID := releaseID + "-retry"
			retry, err := secondWakeup.Prepare(ctx, "e2e", retryReleaseID, "busybox:1.36", bundle)
			if err != nil || retry.Phase != PhasePlanned || retry.ReleaseID != retryReleaseID {
				t.Fatalf("new release id did not start the immutable retry: %#v %v", retry, err)
			}
			persistedRetry, err := (KubectlStore{Runner: base, Namespace: namespace}).Load(ctx)
			if err != nil || persistedRetry.State.ReleaseID != retryReleaseID || persistedRetry.State.Phase != PhasePlanned {
				t.Fatalf("immutable retry was not durably prepared: %#v %v", persistedRetry.State, err)
			}
		})
	}

	t.Run("quiesce failure restores exact snapshot and repeat is idempotent", func(t *testing.T) {
		reset(t)
		runner := &namespaceFaultRunner{base: base, failScale: true}
		engine, _ := newEngine(t, testPlan(t, ModeExclusive), runner)
		_, _ = engine.Prepare(ctx, "e2e", "partial", "busybox:1.36", bundle)
		if _, err := engine.Migrate(ctx); err == nil {
			t.Fatal("expected quiesce failure")
		}
		first, err := engine.Recover(ctx, "partial")
		if err != nil || first.Phase != PhaseRecovered || replicas(t, "statefulset/comma") != "1" {
			t.Fatalf("snapshot was not restored: %#v %v", first, err)
		}
		second, err := engine.Recover(ctx, "partial")
		if err != nil || second.Phase != PhaseRecovered {
			t.Fatalf("repeated recover failed: %#v %v", second, err)
		}
	})

	t.Run("cutover failure is forward only", func(t *testing.T) {
		reset(t)
		runner := &namespaceFaultRunner{base: base}
		engine, platform := newEngine(t, testPlan(t, ModeExclusive), runner)
		platform.failStage = "cutover"
		_, _ = engine.Prepare(ctx, "e2e", "cutover", "busybox:1.36", bundle)
		if _, err := engine.Migrate(ctx); err == nil {
			t.Fatal("expected cutover failure")
		}
		state, err := engine.Recover(ctx, "cutover")
		if err != nil || state.Phase != PhaseForwardOnly || state.ForwardPhase != PhaseCutover || replicas(t, "statefulset/comma") != "0" {
			t.Fatalf("cutover recovery restarted old writers: %#v %v", state, err)
		}
		if _, err = engine.Prepare(ctx, "e2e", "cutover-rerun", "busybox:1.36", bundle); err == nil {
			t.Fatal("new release attempt replaced forward-only cutover")
		}
		persisted, err := engine.Store.Load(ctx)
		if err != nil || persisted.State.ReleaseID != "cutover" || !persisted.State.CutoverMayHaveStarted || replicas(t, "statefulset/comma") != "0" {
			t.Fatalf("new attempt lost cutover fence: %#v %v", persisted.State, err)
		}
		if _, err = engine.ResumeForward(ctx, "cutover", PhaseCutover, true); err != nil {
			t.Fatal(err)
		}
		platform.failStage = ""
		state, err = engine.Migrate(ctx)
		if err != nil || state.Phase != PhaseApplying || replicas(t, "statefulset/comma") != "0" {
			t.Fatalf("explicit forward resume did not converge cutover: %#v %v", state, err)
		}
	})

	t.Run("external session status v2 manifest quiesces writers and cannot restore v1", func(t *testing.T) {
		reset(t)
		runner := &namespaceFaultRunner{base: base}
		engine, platform := newEngine(t, externalSessionActivityCutoverPlan(t), runner)
		platform.failStage = "cutover"
		_, _ = engine.Prepare(ctx, "e2e", "external-activity-v2", "busybox:1.36", bundle)
		if _, err := engine.Migrate(ctx); err == nil {
			t.Fatal("expected cutover failure")
		}
		if runner.scaleCalls == 0 || replicas(t, "statefulset/comma") != "0" {
			t.Fatal("external activity cutover reached its Job before proving writer absence")
		}
		state, err := engine.Recover(ctx, "external-activity-v2")
		if err != nil || state.Phase != PhaseForwardOnly || state.ForwardPhase != PhaseCutover || replicas(t, "statefulset/comma") != "0" {
			t.Fatalf("external activity cutover recovery restored a v1 writer: %#v %v", state, err)
		}
	})

	t.Run("cutover Job retains eviction protection in Kubernetes", func(t *testing.T) {
		reset(t)
		platform := KubectlPlatform{Kubectl: base, Spec: EnvironmentSpec{Namespace: namespace, Environment: "e2e"}}
		name := "comma-release-e2e-protected-cutover"
		job := platform.jobManifest(JobSpec{
			Name: name, Stage: "cutover", Image: "busybox:1.36", Fence: "protected-cutover",
		}, map[string]string{
			"COMMA_SECRETS_NAME": "comma-e2e", "INSTANCE_CONNECTION_NAME": "project:region:instance", "SALIX_CONFIG_SECRET_NAME": "salix-e2e",
		})
		job["spec"].(map[string]any)["suspend"] = true
		body, err := json.Marshal(job)
		if err != nil {
			t.Fatal(err)
		}
		if _, err = base.Run(ctx, body, "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}

		stored, err := base.Run(ctx, nil, "-n", namespace, "get", "job/"+name, "-o", "json")
		if err != nil {
			t.Fatal(err)
		}
		var actual struct {
			Spec struct {
				Template struct {
					Metadata struct {
						Annotations map[string]string `json:"annotations"`
					} `json:"metadata"`
				} `json:"template"`
			} `json:"spec"`
		}
		if err = json.Unmarshal(stored, &actual); err != nil {
			t.Fatal(err)
		}
		if got := actual.Spec.Template.Metadata.Annotations["cluster-autoscaler.kubernetes.io/safe-to-evict"]; got != "false" {
			t.Fatalf("stored cutover Job safe-to-evict = %q, want false", got)
		}
	})

	t.Run("independent wakeup restores a runner lost during rollout verification", func(t *testing.T) {
		reset(t)
		runner := &namespaceFaultRunner{base: base}
		engine, _ := newEngine(t, testPlan(t, ModeOnline), runner)
		if _, err := engine.Prepare(ctx, "e2e", "verify-loss", "busybox:1.36", bundle); err != nil {
			t.Fatal(err)
		}
		store := engine.Store.(KubectlStore)
		record, err := store.Load(ctx)
		if err != nil {
			t.Fatal(err)
		}
		record.State.Phase = PhaseVerifying
		if _, err = store.Update(ctx, record); err != nil {
			t.Fatal(err)
		}
		for _, resource := range []string{"statefulset/comma"} {
			if _, err = base.Run(ctx, nil, "-n", namespace, "scale", resource, "--replicas=0"); err != nil {
				t.Fatal(err)
			}
		}

		// Construct a fresh engine to model the default-branch watchdog waking
		// without any process-local state from the vanished release runner.
		wakeupRunner := &namespaceFaultRunner{base: base}
		wakeup, _ := newEngine(t, testPlan(t, ModeOnline), wakeupRunner)
		state, err := wakeup.Recover(ctx, "verify-loss")
		if err != nil || state.Phase != PhaseRecovered || replicas(t, "statefulset/comma") != "1" {
			t.Fatalf("rollout recovery did not restore the durable snapshot: %#v %v", state, err)
		}
	})

	t.Run("persistent namespace resumes after local Kubernetes restart", func(t *testing.T) {
		container := os.Getenv("COMMA_RELEASE_E2E_RESTART_CONTAINER")
		if container == "" {
			t.Skip("set COMMA_RELEASE_E2E_RESTART_CONTAINER to exercise restart persistence")
		}
		reset(t)
		persistenceFixture := strings.ReplaceAll(`apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: restart-evidence, namespace: NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  resources: {requests: {storage: 1Mi}}
---
apiVersion: v1
kind: Pod
metadata: {name: restart-pvc-writer, namespace: NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "echo durable-control-plane-restart > /evidence/marker; sync"]
      volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, persistentVolumeClaim: {claimName: restart-evidence}}]
`, "NAMESPACE", namespace)
		_, _ = base.Run(ctx, nil, "-n", namespace, "delete", "pod/restart-pvc-writer", "pod/restart-pvc-reader", "--ignore-not-found=true", "--wait=true")
		_, _ = base.Run(ctx, nil, "-n", namespace, "delete", "pvc/restart-evidence", "--ignore-not-found=true", "--wait=true")
		if _, err := base.Run(ctx, []byte(persistenceFixture), "apply", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		if _, err := base.Run(ctx, nil, "-n", namespace, "wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/restart-pvc-writer", "--timeout=2m"); err != nil {
			t.Fatal(err)
		}
		runner := &namespaceFaultRunner{base: base}
		engine, platform := newEngine(t, testPlan(t, ModeOnline), runner)
		if _, err := engine.Prepare(ctx, "e2e", "restart-resume", "busybox:1.36", bundle); err != nil {
			t.Fatal(err)
		}
		store := engine.Store.(KubectlStore)
		record, err := store.Load(ctx)
		if err != nil {
			t.Fatal(err)
		}
		record.State.Phase = PhaseApplying
		attempt := NextAttempt(record.State, "online")
		record.State.Attempts = append(record.State.Attempts, attempt)
		if _, err = store.Update(ctx, record); err != nil {
			t.Fatal(err)
		}
		job := platform.jobManifest(JobSpec{
			Name: attempt.Name, Stage: attempt.Stage, Image: record.State.Image,
			ManifestDigest: record.State.ManifestDigest, BundleName: record.State.BundleName,
			Attempt: attempt.Attempt, Fence: record.State.ReleaseID + ":" + record.State.ManifestDigest,
		}, map[string]string{"COMMA_SECRETS_NAME": "comma-e2e", "INSTANCE_CONNECTION_NAME": "project:region:instance", "SALIX_CONFIG_SECRET_NAME": "salix-e2e"})
		job["spec"].(map[string]any)["suspend"] = true
		jobBody, _ := json.Marshal(job)
		if _, err = base.Run(ctx, jobBody, "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		jobUID, err := base.Run(ctx, nil, "-n", namespace, "get", "job/"+attempt.Name, "-o", "jsonpath={.metadata.uid}")
		if err != nil || len(jobUID) == 0 {
			t.Fatalf("restart fixture Job has no durable UID: %q %v", jobUID, err)
		}
		for _, resource := range []string{"statefulset/comma"} {
			if _, err = base.Run(ctx, nil, "-n", namespace, "scale", resource, "--replicas=0"); err != nil {
				t.Fatal(err)
			}
		}

		if _, err = (ExecRunner{Name: "docker"}).Run(ctx, nil, "restart", container); err != nil {
			t.Fatalf("local Kubernetes restart failed: %v", err)
		}
		refreshKubeconfigEndpoint(t, ctx, container)
		readyBy := time.Now().Add(180 * time.Second)
		for {
			if _, err = base.Run(ctx, nil, "get", "--raw=/readyz"); err == nil {
				break
			}
			if time.Now().After(readyBy) {
				t.Fatalf("local Kubernetes did not become ready after restart: %v", err)
			}
			time.Sleep(2 * time.Second)
		}
		if _, err = base.Run(ctx, nil, "get", "namespace/"+namespace); err != nil {
			t.Fatalf("restart cleared the test namespace: %v", err)
		}
		persisted, err := (KubectlStore{Runner: base, Namespace: namespace}).Load(ctx)
		if err != nil || persisted.State.ReleaseID != "restart-resume" || persisted.State.Phase != PhaseApplying {
			t.Fatalf("restart lost durable release state: %#v %v", persisted.State, err)
		}
		afterUID, err := base.Run(ctx, nil, "-n", namespace, "get", "job/"+attempt.Name, "-o", "jsonpath={.metadata.uid}")
		if err != nil || string(afterUID) != string(jobUID) {
			t.Fatalf("restart replaced or lost fenced Job: before=%q after=%q err=%v", jobUID, afterUID, err)
		}
		reader := strings.ReplaceAll(`apiVersion: v1
kind: Pod
metadata: {name: restart-pvc-reader, namespace: NAMESPACE}
spec:
  restartPolicy: Never
  containers:
    - name: reader
      image: busybox:1.36
      command: ["sh", "-c", "test \"$(cat /evidence/marker)\" = durable-control-plane-restart"]
      volumeMounts: [{name: evidence, mountPath: /evidence}]
  volumes: [{name: evidence, persistentVolumeClaim: {claimName: restart-evidence}}]
`, "NAMESPACE", namespace)
		if _, err = base.Run(ctx, []byte(reader), "create", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "wait", "--for=jsonpath={.status.phase}=Succeeded", "pod/restart-pvc-reader", "--timeout=2m"); err != nil {
			t.Fatal(err)
		}

		// Model an independent watchdog after the runner and API server both
		// restarted: no process memory is reused, only Kubernetes facts.
		wakeupRunner := &namespaceFaultRunner{base: base}
		wakeup, _ := newEngine(t, testPlan(t, ModeOnline), wakeupRunner)
		state, err := wakeup.Recover(ctx, "restart-resume")
		if err != nil || state.Phase != PhaseRecovered || state.Attempts[len(state.Attempts)-1].Status != "aborted" || replicas(t, "statefulset/comma") != "1" {
			t.Fatalf("restart resume did not recover from durable facts: %#v %v", state, err)
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "get", "job/"+attempt.Name); err == nil || !containsNotFound(err.Error()) {
			t.Fatalf("recovery did not delete the surviving fenced Job: %v", err)
		}
	})

	t.Run("exclusive candidate startup follows ordered-ready zero then one", func(t *testing.T) {
		manifest := strings.ReplaceAll(`apiVersion: v1
kind: Service
metadata: {name: exclusive-order, namespace: NAMESPACE}
spec: {clusterIP: None, selector: {app: exclusive-order}}
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: exclusive-order, namespace: NAMESPACE}
spec:
  serviceName: exclusive-order
  replicas: 0
  updateStrategy: {type: RollingUpdate, rollingUpdate: {partition: 0}}
  selector: {matchLabels: {app: exclusive-order}}
  template:
    metadata: {labels: {app: exclusive-order}}
    spec:
      containers:
        - name: candidate
          image: busybox:1.36
          command: ["sh", "-c", "sleep 5; touch /tmp/ready; sleep 3600"]
          readinessProbe: {exec: {command: ["cat", "/tmp/ready"]}, periodSeconds: 1}
`, "NAMESPACE", namespace)
		if _, err := base.Run(ctx, []byte(manifest), "apply", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		if _, err := base.Run(ctx, nil, "-n", namespace, "scale", "statefulset/exclusive-order", "--replicas=2"); err != nil {
			t.Fatal(err)
		}
		if _, err := base.Run(ctx, nil, "-n", namespace, "wait", "--for=condition=PodScheduled", "pod/exclusive-order-0", "--timeout=90s"); err != nil {
			t.Fatal(err)
		}
		if _, err := base.Run(ctx, nil, "-n", namespace, "get", "pod/exclusive-order-1"); err == nil || !containsNotFound(err.Error()) {
			t.Fatal("OrderedReady started ordinal 1 before candidate ordinal 0 became ready")
		}
		if _, err := base.Run(ctx, nil, "-n", namespace, "rollout", "status", "statefulset/exclusive-order", "--timeout=120s"); err != nil {
			t.Fatal(err)
		}
	})

	t.Run("recovery does not persist recovered before restored workloads are ready", func(t *testing.T) {
		reset(t)
		slowServing := strings.ReplaceAll(`apiVersion: apps/v1
kind: StatefulSet
metadata: {name: comma, namespace: NAMESPACE}
spec:
  serviceName: comma
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: comma}}
  template:
    metadata: {labels: {app.kubernetes.io/name: comma}}
    spec:
      containers:
        - name: pause
          image: busybox:1.36
          command: ["sh", "-c", "sleep 6; touch /tmp/ready; sleep 3600"]
          readinessProbe: {exec: {command: ["cat", "/tmp/ready"]}, periodSeconds: 1}
`, "NAMESPACE", namespace)
		if _, err := base.Run(ctx, []byte(slowServing), "apply", "-f", "-"); err != nil {
			t.Fatal(err)
		}
		if _, err := base.Run(ctx, nil, "-n", namespace, "rollout", "status", "statefulset/comma", "--timeout=2m"); err != nil {
			t.Fatal(err)
		}

		runner := &namespaceFaultRunner{base: base}
		engine, _ := newEngine(t, testPlan(t, ModeOnline), runner)
		if _, err := engine.Prepare(ctx, "e2e", "ready-recovery", "busybox:1.36", bundle); err != nil {
			t.Fatal(err)
		}
		store := engine.Store.(KubectlStore)
		record, err := store.Load(ctx)
		if err != nil {
			t.Fatal(err)
		}
		record.State.Phase = PhaseApplying
		if _, err = store.Update(ctx, record); err != nil {
			t.Fatal(err)
		}
		for _, resource := range []string{"statefulset/comma"} {
			if _, err = base.Run(ctx, nil, "-n", namespace, "scale", resource, "--replicas=0"); err != nil {
				t.Fatal(err)
			}
		}
		if _, err = base.Run(ctx, nil, "-n", namespace, "wait", "--for=delete", "pod", "-l", "app.kubernetes.io/name=comma", "--timeout=2m"); err != nil {
			t.Fatal(err)
		}

		started := time.Now()
		state, err := engine.Recover(ctx, "ready-recovery")
		if err != nil || state.Phase != PhaseRecovered {
			t.Fatalf("recovery failed: %#v %v", state, err)
		}
		ready, readErr := base.Run(ctx, nil, "-n", namespace, "get", "statefulset/comma", "-o", "jsonpath={.status.readyReplicas}")
		if readErr != nil || string(ready) != "1" || time.Since(started) < 4*time.Second {
			t.Fatalf("recovery became terminal before readiness: ready=%q elapsed=%s err=%v", ready, time.Since(started), readErr)
		}
	})
}

func applyNamespaceFixtures(t *testing.T, ctx context.Context, runner Runner, namespace string) {
	t.Helper()
	manifest := strings.ReplaceAll(`apiVersion: v1
kind: Service
metadata: {name: comma, namespace: NAMESPACE}
spec: {clusterIP: None, selector: {app.kubernetes.io/name: comma}}
---
apiVersion: v1
kind: Service
metadata: {name: comma-salix, namespace: NAMESPACE}
spec: {selector: {app.kubernetes.io/name: comma}, ports: [{port: 80, targetPort: 80}]}
---
apiVersion: v1
kind: Service
metadata: {name: comma-teams, namespace: NAMESPACE}
spec: {selector: {app.kubernetes.io/name: comma}, ports: [{port: 80, targetPort: 80}]}
---
apiVersion: v1
kind: ServiceAccount
metadata: {name: comma, namespace: NAMESPACE}
---
apiVersion: v1
kind: Secret
metadata: {name: comma-e2e, namespace: NAMESPACE}
stringData: {value: test}
---
apiVersion: v1
kind: Secret
metadata: {name: bridge-e2e, namespace: NAMESPACE}
stringData: {INSTANCE_CONNECTION_NAME: test}
---
apiVersion: v1
kind: Secret
metadata: {name: salix-e2e, namespace: NAMESPACE}
stringData: {value: test}
---
apiVersion: apps/v1
kind: StatefulSet
metadata: {name: comma, namespace: NAMESPACE}
spec:
  serviceName: comma
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: comma}}
  template:
    metadata: {labels: {app.kubernetes.io/name: comma}}
    spec:
      containers:
        - {name: pause, image: registry.k8s.io/pause:3.9}
        - name: cloud-sql-proxy
          image: busybox:1.36
          command: ["sh", "-c"]
          args: ["sleep 3600", "project:region:instance"]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: comma-otel-collector, namespace: NAMESPACE}
spec:
  replicas: 1
  selector: {matchLabels: {app.kubernetes.io/name: comma-otel-collector}}
  template:
    metadata: {labels: {app.kubernetes.io/name: comma-otel-collector}}
    spec:
      containers:
        - {name: pause, image: registry.k8s.io/pause:3.9}
`, "NAMESPACE", namespace)
	if _, err := runner.Run(ctx, []byte(manifest), "apply", "-f", "-"); err != nil {
		t.Fatal(err)
	}
}
