package release

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"slices"
	"strings"
	"testing"
	"time"
)

type runnerFunc func(context.Context, []byte, ...string) ([]byte, error)

func (f runnerFunc) Run(ctx context.Context, body []byte, args ...string) ([]byte, error) {
	return f(ctx, body, args...)
}

func TestCurrentHelmRevisionRequiresDeployedExistingRelease(t *testing.T) {
	tests := []struct {
		name     string
		body     string
		runErr   error
		want     int
		wantErr  string
		noRunner bool
	}{
		{name: "deployed", body: `{"version":7,"info":{"status":"deployed"}}`, want: 7},
		{name: "pending", body: `{"version":7,"info":{"status":"pending-upgrade"}}`, wantErr: `not deployed: status "pending-upgrade"`},
		{name: "missing release", runErr: errors.New("Error: release: not found"), wantErr: "must be bootstrapped"},
		{name: "invalid revision", body: `{"version":0,"info":{"status":"deployed"}}`, wantErr: "invalid helm status output"},
		{name: "runner required", noRunner: true, wantErr: "status is required"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			platform := KubectlPlatform{}
			if !tc.noRunner {
				platform.Helm = HelmAdapter{
					Release:   "comma",
					Namespace: "comma",
					Runner: runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
						if !slices.Equal(args, []string{"status", "comma", "--namespace", "comma", "--output", "json"}) {
							t.Fatalf("helm status args = %#v", args)
						}
						return []byte(tc.body), tc.runErr
					}),
				}
			}
			got, err := platform.CurrentHelmRevision(context.Background())
			if tc.wantErr == "" {
				if err != nil || got != tc.want {
					t.Fatalf("CurrentHelmRevision() = %d, %v; want %d", got, err, tc.want)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("CurrentHelmRevision() error = %v; want %q", err, tc.wantErr)
			}
		})
	}
}

func TestEnsureBundleRejectsMutableContentAddressedConfigMap(t *testing.T) {
	bundle, _ := json.Marshal(CandidateBundle{SchemaVersion: 1, Replacements: map[string]string{"COMMA_IMAGE": "image"}})
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, _ ...string) ([]byte, error) {
		return []byte(`{"kind":"ConfigMap","immutable":false,"data":{"bundle.json":"{\"COMMA_IMAGE\":\"image\"}"}}`), nil
	})
	if _, err := p.EnsureBundle(context.Background(), BundleName(bundle), bundle); err == nil {
		t.Fatal("mutable top-level candidate bundle was accepted")
	}
}

func TestValidateCandidateResourceRecomputesSecretContent(t *testing.T) {
	expected := CandidateResource{Name: "candidate", Type: "Opaque", Data: map[string]string{"TOKEN": "correct"}}
	digest := CandidateResourceDigest(expected)
	object := map[string]any{
		"kind": "Secret", "type": "Opaque", "immutable": true,
		"data": map[string]string{"TOKEN": base64.StdEncoding.EncodeToString([]byte("wrong"))},
	}
	body, _ := json.Marshal(object)
	if validateCandidateResource(body, expected, digest) == nil {
		t.Fatal("candidate resource accepted conflicting secret data")
	}
}

func TestCandidateResourceDigestKeepsEstablishedSecretIdentity(t *testing.T) {
	resource := CandidateResource{Type: "Opaque", Data: map[string]string{"TOKEN": "correct"}}
	if got, want := CandidateResourceDigest(resource), "3cb8af9d78e38a0adb9bd759794be22399586d168e6e947d1fb9151dad9356f7"; got != want {
		t.Fatalf("candidate Secret digest = %s, want %s", got, want)
	}
}

func TestCandidateCreateResponseLossRecoversByContent(t *testing.T) {
	resource := CandidateResource{Type: "Opaque", Data: map[string]string{"TOKEN": "correct"}}
	resource.Name = "candidate-" + CandidateResourceDigest(resource)[:12]
	actual, _ := json.Marshal(map[string]any{
		"kind": "Secret", "type": "Opaque", "immutable": true,
		"data": map[string]string{"TOKEN": base64.StdEncoding.EncodeToString([]byte("correct"))},
	})
	reads := 0
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		if slicesContain(args, "create") {
			return nil, errors.New("connection lost")
		}
		reads++
		if reads == 1 {
			return nil, errors.New("NotFound")
		}
		return actual, nil
	})
	if err := p.ensureCandidateResource(context.Background(), resource); err != nil {
		t.Fatal(err)
	}
}

func TestLifecycleEpochJobUsesCandidateImageAndKeepsTokenOutOfJobIdentity(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	token := strings.Repeat("secret-fence-", 4)
	epoch := LifecycleEpochSpec{
		Action: LifecycleEpochAssert, ReleaseID: "lifecycle-v1",
		Image: "candidate@sha256:digest", BundleName: "bundle",
		Token: token, Generation: 3, Attempt: 4, LeaseSeconds: 300,
	}
	spec := JobSpec{
		Name: "epoch", Stage: "session-lifecycle-epoch-assert",
		Image: epoch.Image, BundleName: epoch.BundleName, Attempt: epoch.Attempt,
		Fence: "lifecycle-v1:assert:4", LifecycleEpoch: &epoch,
	}
	manifest := p.jobManifest(spec, map[string]string{})
	body, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	text := string(body)
	for _, required := range []string{
		"Comma.SessionLifecycleWriterEpoch.release_command!",
		"COMMA_SESSION_LIFECYCLE_EPOCH_TOKEN",
		"COMMA_SESSION_LIFECYCLE_EPOCH_GENERATION",
		`"image":"candidate@sha256:digest"`,
	} {
		if !strings.Contains(text, required) {
			t.Fatalf("lifecycle epoch Job omits %q: %s", required, text)
		}
	}
	metadata := manifest["metadata"].(map[string]any)
	annotations, _ := json.Marshal(metadata["annotations"])
	labels, _ := json.Marshal(metadata["labels"])
	if bytes.Contains(annotations, []byte(token)) || bytes.Contains(labels, []byte(token)) {
		t.Fatalf("lifecycle fencing token leaked into durable Job identity")
	}
}

func TestCutoverJobRequestsAutopilotEvictionProtection(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}

	cutover := p.jobManifest(JobSpec{Name: "cutover", Stage: "cutover", Image: "image"}, map[string]string{})
	template := cutover["spec"].(map[string]any)["template"].(map[string]any)
	annotations := template["metadata"].(map[string]any)["annotations"].(map[string]string)
	if got := annotations["cluster-autoscaler.kubernetes.io/safe-to-evict"]; got != "false" {
		t.Fatalf("cutover Job safe-to-evict = %q, want false", got)
	}

	plan := p.jobManifest(JobSpec{Name: "plan", Stage: "plan", Image: "image"}, map[string]string{})
	planTemplate := plan["spec"].(map[string]any)["template"].(map[string]any)
	planAnnotations := planTemplate["metadata"].(map[string]any)["annotations"].(map[string]string)
	if _, ok := planAnnotations["cluster-autoscaler.kubernetes.io/safe-to-evict"]; ok {
		t.Fatal("non-cutover Job unexpectedly requested extended eviction protection")
	}
}

func TestCutoverJobCanRunConversationProjectionTasks(t *testing.T) {
	elixir, err := exec.LookPath("elixir")
	if err != nil {
		t.Skip("Elixir is not installed")
	}

	manifest := (KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}).jobManifest(
		JobSpec{Name: "cutover", Stage: "cutover", Image: "candidate@sha256:digest"},
		map[string]string{},
	)
	template := manifest["spec"].(map[string]any)["template"].(map[string]any)
	container := template["spec"].(map[string]any)["containers"].([]any)[0].(map[string]any)
	var boot string
	for _, item := range container["env"].([]any) {
		entry := item.(map[string]any)
		if entry["name"] == "COMMA_RELEASE_BOOT_EXPRESSION" {
			boot = entry["value"].(string)
			break
		}
	}
	if boot == "" {
		t.Fatal("cutover Job has no boot expression")
	}

	script := `
:ok = :application.load({:application, :salix_store, [vsn: ~c"0.0.1", modules: [], applications: [:kernel, :stdlib]]})
Code.eval_string(System.fetch_env!("COMMA_RELEASE_BOOT_EXPRESSION"))
`
	expression := `
parent = self()
{:ok, _} = Task.Supervisor.start_child(SalixIM.ConversationProjectionTasks, fn -> send(parent, :projection_ran) end)
receive do
  :projection_ran -> IO.puts("projection_ran")
after
  1_000 -> raise "projection task did not run"
end
`
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, elixir, "-e", script)
	command.Env = append(os.Environ(), "COMMA_RELEASE_BOOT_EXPRESSION="+boot, "COMMA_RELEASE_EXPRESSION="+expression)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("cutover Job cannot run Conversation projection tasks: %v\n%s", err, output)
	}
	if !bytes.Contains(output, []byte("projection_ran")) {
		t.Fatalf("cutover Job did not run projection task: %s", output)
	}
}

type lifecycleV1VerifyFixture struct {
	oldProduct             bool
	routeObservedGen       int
	routeHost              string
	omitGatewayRoute       string
	unexpectedGatewayRoute bool
	endpointUID            string
	probeStatus            map[string]int
	probeSetCookie         string
	kubectlCalls           []string
	publicProbeCalls       []string
}

func (f *lifecycleV1VerifyFixture) kubectl(
	_ context.Context,
	_ []byte,
	args ...string,
) ([]byte, error) {
	command := strings.Join(args, " ")
	f.kubectlCalls = append(f.kubectlCalls, command)
	switch {
	case strings.Contains(command, "configmap/bundle"):
		return []byte(`{"COMMA_REVISION_LABEL":"rev-v1","SALIX_HOST":"salix.example.test","COMMA_WEB_COOKIE_ORIGIN":"https://app.example.test","COMMA_ADMIN_COOKIE_ORIGIN":"https://admin.example.test"}`), nil
	case strings.Contains(command, "get statefulset/comma "):
		terminalSpec := `{"containers":[{"name":"comma"},{"name":"cloud-sql-proxy","args":["--private-ip","project:region:instance"]}]}`
		return []byte(`{"spec":{"replicas":1,"template":{"spec":` + terminalSpec + `}}}`), nil
	case strings.Contains(command, "get pods -l app.kubernetes.io/name=comma"):
		image := "candidate@sha256:digest"
		revision := "rev-v1"
		if f.oldProduct {
			image = "old@sha256:digest"
			revision = "rev-old"
		}
		return []byte(fmt.Sprintf(
			`{"items":[{"metadata":{"name":"comma-0","uid":"comma-uid","labels":{"comma.surf/revision":%q}},"spec":{"containers":[{"name":"comma","image":%q},{"name":"cloud-sql-proxy","args":["--private-ip","project:region:instance"]}]},"status":{"phase":"Running","podIP":"10.0.0.1","conditions":[{"type":"Ready","status":"True"}]}}]}`,
			revision,
			image,
		)), nil
	case strings.Contains(command, "app.kubernetes.io/name=comma"):
		image := "candidate@sha256:digest"
		revision := "rev-v1"
		if f.oldProduct {
			image = "old@sha256:digest"
			revision = "rev-old"
		}
		return []byte(fmt.Sprintf(
			`{"items":[{"metadata":{"name":"comma-0","uid":"comma-uid","labels":{"comma.surf/revision":%q}},"spec":{"containers":[{"name":"comma","image":%q}]},"status":{"phase":"Running","podIP":"10.0.0.1","conditions":[{"type":"Ready","status":"True"}]}}]}`,
			revision,
			image,
		)), nil
	case strings.Contains(command, "get httproutes"):
		observedGeneration := f.routeObservedGen
		if observedGeneration == 0 {
			observedGeneration = 7
		}
		host := f.routeHost
		if host == "" {
			host = "salix.example.test"
		}
		items := make([]string, 0, 4)
		if f.omitGatewayRoute != "comma-salix" {
			items = append(items, fmt.Sprintf(
				`{"metadata":{"name":"comma-salix","generation":7},"spec":{"parentRefs":[{"name":"comma"}],"hostnames":[%q]},"status":{"parents":[{"parentRef":{"name":"comma"},"conditions":[{"type":"Accepted","status":"True","observedGeneration":%d},{"type":"ResolvedRefs","status":"True","observedGeneration":%d}]}]}}`,
				host,
				observedGeneration,
				observedGeneration,
			))
		}
		for _, name := range []string{"comma-salix-sites", "comma-teams"} {
			if f.omitGatewayRoute != name {
				items = append(items, fmt.Sprintf(
					`{"metadata":{"name":%q},"spec":{"parentRefs":[{"name":"comma"}]}}`,
					name,
				))
			}
		}
		if f.unexpectedGatewayRoute {
			items = append(items,
				`{"metadata":{"name":"rogue-admin-route"},"spec":{"parentRefs":[{"name":"comma"}]}}`,
			)
		}
		return []byte(`{"items":[` + strings.Join(items, ",") + `]}`), nil
	case strings.Contains(command, "kubernetes.io/service-name=comma-product"):
		uid := f.endpointUID
		if uid == "" {
			uid = "comma-uid"
		}
		return []byte(fmt.Sprintf(
			`{"items":[{"endpoints":[{"addresses":["10.0.0.1"],"conditions":{"ready":true,"serving":true,"terminating":false},"targetRef":{"kind":"Pod","name":"comma-0","uid":%q}}]}]}`,
			uid,
		)), nil
	default:
		return nil, fmt.Errorf("unexpected kubectl command %s", command)
	}
}

func (f *lifecycleV1VerifyFixture) curl(
	_ context.Context,
	_ []byte,
	args ...string,
) ([]byte, error) {
	command := strings.Join(args, " ")
	f.publicProbeCalls = append(f.publicProbeCalls, command)
	probe := ""
	status := 0
	body := ""
	switch {
	case strings.Contains(command, "probe=missing-version"):
		probe = "missing-version"
		status = 428
		body = `{"contract_version":1,"error":"session_lifecycle_version_required"}`
	case strings.Contains(command, "probe=unsupported-version"):
		probe = "unsupported-version"
		status = 400
		body = `{"contract_version":1,"error":"unsupported_session_lifecycle_version"}`
	case strings.Contains(command, "probe=explicit-bearer"):
		probe = "explicit-bearer"
		status = 401
		body = `{"error":"unauthorized"}`
	default:
		return nil, fmt.Errorf("unexpected public probe %s", command)
	}
	if override := f.probeStatus[probe]; override != 0 {
		status = override
		body = `{"error":"unexpected"}`
	}
	headers := "cache-control: no-store\r\n"
	headers += "content-type: application/json; charset=utf-8\r\n"
	if f.probeSetCookie == probe {
		headers += "set-cookie: comma_session=unexpected; HttpOnly\r\n"
	}
	return []byte(fmt.Sprintf(
		"HTTP/2 %d\r\n%s\r\n%s%s%d",
		status,
		headers,
		body,
		lifecycleV1ProbeStatusMarker,
		status,
	)), nil
}

func lifecycleV1VerifyState() State {
	now := time.Now().UTC()
	return State{
		ReleaseID: "lifecycle-v1", Image: "candidate@sha256:digest", BundleName: "bundle",
		LifecycleWriterEpoch: &LifecycleWriterEpochFacts{
			Required: true, Status: "active", Generation: 1,
			FencingToken: strings.Repeat("a", 64), LeaseExpiresAt: now.Add(time.Minute),
			DrainedAt: now,
		},
	}
}

func lifecycleV1VerifyPlatform(fixture *lifecycleV1VerifyFixture) KubectlPlatform {
	return KubectlPlatform{
		Kubectl: runnerFunc(fixture.kubectl),
		Curl:    runnerFunc(fixture.curl),
		Spec: EnvironmentSpec{
			Namespace:   "comma",
			PublicHosts: []string{"salix.example.test", "teams.example.test"},
		},
	}
}

func TestVerifyLifecycleV1RequiresCandidateRevisionThroughPublicIngress(t *testing.T) {
	fixture := &lifecycleV1VerifyFixture{probeStatus: map[string]int{}}
	platform := lifecycleV1VerifyPlatform(fixture)
	state := lifecycleV1VerifyState()
	if err := platform.VerifyLifecycleV1(context.Background(), state); err != nil {
		t.Fatal(err)
	}
	calls := strings.Join(fixture.publicProbeCalls, "\n")
	for _, required := range []string{
		"probe=missing-version",
		"probe=unsupported-version",
		"probe=explicit-bearer",
		"x-comma-session-transport: bearer",
		"authorization: Bearer " + lifecycleV1InvalidBearer,
	} {
		if !strings.Contains(calls, required) {
			t.Fatalf("public lifecycle-v1 probes omit %q: %s", required, calls)
		}
	}
	if strings.Contains(calls, "comma_sess_") {
		t.Fatalf("release probe used a database-resolvable Session credential: %s", calls)
	}
	for _, call := range fixture.publicProbeCalls {
		switch {
		case strings.Contains(call, "probe=missing-version"):
			if strings.Contains(call, "x-comma-session-lifecycle-version") {
				t.Fatalf("missing-version probe accidentally sent a version: %s", call)
			}
		case strings.Contains(call, "probe=unsupported-version"):
			if !strings.Contains(call, "x-comma-session-lifecycle-version: 0") {
				t.Fatalf("unsupported-version probe omitted its invalid version: %s", call)
			}
		case strings.Contains(call, "probe=explicit-bearer"):
			if strings.Contains(call, "origin:") ||
				strings.Contains(call, "x-comma-expected-auth-session-id") {
				t.Fatalf("native bearer probe borrowed Web Cookie authority headers: %s", call)
			}
		}
	}

	fixture.oldProduct = true
	if err := platform.VerifyLifecycleV1(context.Background(), state); err == nil ||
		!strings.Contains(err.Error(), "not lifecycle-v1") {
		t.Fatalf("serving old replica was accepted: %v", err)
	}
}

func TestVerifyLifecycleV1RequiresWriterDrainEvidence(t *testing.T) {
	fixture := &lifecycleV1VerifyFixture{probeStatus: map[string]int{}}
	state := lifecycleV1VerifyState()
	state.LifecycleWriterEpoch.DrainedAt = time.Time{}

	err := lifecycleV1VerifyPlatform(fixture).VerifyLifecycleV1(
		context.Background(),
		state,
	)
	if err == nil || !strings.Contains(err.Error(), "active epoch and writer-drain evidence") {
		t.Fatalf("VerifyLifecycleV1() error = %v; want missing writer-drain evidence", err)
	}
	if len(fixture.publicProbeCalls) != 0 {
		t.Fatalf("public ingress was probed before writer-drain evidence: %#v", fixture.publicProbeCalls)
	}
}

func TestVerifyLifecycleV1IngressEvidenceFailsClosed(t *testing.T) {
	tests := []struct {
		name    string
		mutate  func(*lifecycleV1VerifyFixture)
		wantErr string
	}{
		{
			name: "public API route has the wrong host",
			mutate: func(fixture *lifecycleV1VerifyFixture) {
				fixture.routeHost = "wrong.example.test"
			},
			wantErr: "public API HTTPRoute has the wrong host",
		},
		{
			name: "public Gateway has an unexpected route",
			mutate: func(fixture *lifecycleV1VerifyFixture) {
				fixture.unexpectedGatewayRoute = true
			},
			wantErr: "public Gateway HTTPRoute set drifted",
		},
		{
			name: "public Gateway omits an expected route",
			mutate: func(fixture *lifecycleV1VerifyFixture) {
				fixture.omitGatewayRoute = "comma-teams"
			},
			wantErr: "public Gateway HTTPRoute set drifted",
		},
		{
			name: "route controller has not observed the current generation",
			mutate: func(fixture *lifecycleV1VerifyFixture) {
				fixture.routeObservedGen = 6
			},
			wantErr: "not accepted at its current generation",
		},
		{
			name: "EndpointSlice retains a stale pod identity",
			mutate: func(fixture *lifecycleV1VerifyFixture) {
				fixture.endpointUID = "old-product-uid"
			},
			wantErr: "not an exact lifecycle-v1 candidate pod",
		},
		{
			name: "missing-version response is not 428",
			mutate: func(fixture *lifecycleV1VerifyFixture) {
				fixture.probeStatus["missing-version"] = 200
			},
			wantErr: "status 200, expected 428",
		},
		{
			name: "bearer probe attempts cookie mutation",
			mutate: func(fixture *lifecycleV1VerifyFixture) {
				fixture.probeSetCookie = "explicit-bearer"
			},
			wantErr: "attempted to mutate a cookie",
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fixture := &lifecycleV1VerifyFixture{probeStatus: map[string]int{}}
			tc.mutate(fixture)
			err := lifecycleV1VerifyPlatform(fixture).VerifyLifecycleV1(
				context.Background(),
				lifecycleV1VerifyState(),
			)
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("VerifyLifecycleV1() error = %v; want %q", err, tc.wantErr)
			}
		})
	}
}

func TestValidateExistingJobChecksCompleteAuthoredSpec(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma-staging"}}
	spec := JobSpec{Name: "job", Stage: "online", Image: "image", ManifestDigest: "digest", BundleName: "bundle-a", Attempt: 2, AllowedStepIDs: []string{"billing-1"}, Fence: "release:digest"}
	expected := p.jobManifest(spec, map[string]string{"COMMA_SECRETS_NAME": "comma-secrets-a", "INSTANCE_CONNECTION_NAME": "project:region:instance", "SALIX_CONFIG_SECRET_NAME": "salix-a"})
	body, _ := json.Marshal(expected)
	if err := validateExistingJob(body, expected); err != nil {
		t.Fatal(err)
	}

	var stale map[string]any
	_ = json.Unmarshal(body, &stale)
	stale["metadata"].(map[string]any)["annotations"].(map[string]any)["comma.surf/allowed-step-ids"] = `["bridge-2"]`
	staleBody, _ := json.Marshal(stale)
	if validateExistingJob(staleBody, expected) == nil {
		t.Fatal("job with stale allowed ids was accepted")
	}
}

func TestReleaseJobUsesEphemeralCombinedConfigWhenPresent(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	manifest := p.jobManifest(JobSpec{Name: "plan", Stage: "plan", Image: "image"}, map[string]string{
		"COMMA_SECRETS_NAME":               "comma-secrets",
		"SALIX_CONFIG_SECRET_NAME":         "salix-config",
		"COMMA_RELEASE_CONFIG_SECRET_NAME": "comma-release-config",
	})
	pod := manifest["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
	volume := pod["volumes"].([]any)[0].(map[string]any)
	if got := volume["secret"].(map[string]any)["secretName"]; got != "comma-release-config" {
		t.Fatalf("release Job config Secret = %q, want comma-release-config", got)
	}

	legacy := p.jobManifest(JobSpec{Name: "legacy", Stage: "plan", Image: "image"}, map[string]string{
		"COMMA_SECRETS_NAME":       "comma-secrets",
		"SALIX_CONFIG_SECRET_NAME": "salix-config",
	})
	legacyPod := legacy["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
	legacyVolume := legacyPod["volumes"].([]any)[0].(map[string]any)
	if got := legacyVolume["secret"].(map[string]any)["secretName"]; got != "salix-config" {
		t.Fatalf("legacy release Job config Secret = %q, want salix-config", got)
	}
}

func TestReleaseJobDisablesDomainWorkers(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	manifest := p.jobManifest(JobSpec{Name: "plan", Stage: "plan", Image: "image"}, map[string]string{})
	pod := manifest["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
	container := pod["containers"].([]any)[0].(map[string]any)
	env := container["env"].([]any)

	if !slices.ContainsFunc(env, func(value any) bool {
		entry, ok := value.(map[string]any)
		return ok && entry["name"] == "COMMA_RELEASE_JOB" && entry["value"] == "1"
	}) {
		t.Fatal("release job did not fence domain workers")
	}
	if !slices.ContainsFunc(env, func(value any) bool {
		entry, ok := value.(map[string]any)
		return ok && entry["name"] == "SALIX_SNOWFLAKE_WORKER_ID" && entry["value"] == "1023"
	}) {
		t.Fatal("release job did not use its reserved worker ID outside serving ordinals 0..1021")
	}
}

func TestBuildHelmValuesPreservesRuntimeWorkloadIdentity(t *testing.T) {
	replacements := testCandidateReplacements()

	for _, test := range []struct {
		environment       string
		project           string
		want              string
		gatewayEnabled    bool
		computeRuntimeURL string
	}{
		{"staging", "example-staging-project", "runtime-staging@example-staging-project.iam.gserviceaccount.com", true, "https://salix-staging.comma.surf"},
		{"production", "example-prod-project", "runtime-prod@example-prod-project.iam.gserviceaccount.com", false, ""},
	} {
		platform := KubectlPlatform{Spec: EnvironmentSpec{Environment: test.environment, Project: test.project, RuntimeServiceAccount: test.want, ReleaseObserverServiceAccount: "observer@" + test.project + ".iam.gserviceaccount.com", AgentVmmGatewayEnabled: test.gatewayEnabled, ComputeRuntimeBaseURL: test.computeRuntimeURL, SSHEnabled: test.gatewayEnabled}}
		body, err := platform.buildHelmValues(replacements)
		if err != nil {
			t.Fatal(err)
		}
		var values struct {
			Runtime struct {
				CloudSQLInstanceConnectionName string `json:"cloudSqlInstanceConnectionName"`
				AgentVmmGatewayEnabled         bool   `json:"agentVmmGatewayEnabled"`
				ComputeRuntimeBaseURL          string `json:"computeRuntimeBaseURL"`
			} `json:"runtime"`
			References     map[string]string `json:"references"`
			ServiceAccount struct {
				GCPServiceAccount string `json:"gcpServiceAccount"`
				ReleaseObserver   string `json:"releaseObserver"`
			} `json:"serviceAccount"`
			Workloads   map[string]any `json:"workloads"`
			AlertRouter struct {
				Enabled  bool `json:"enabled"`
				Replicas int  `json:"replicas"`
			} `json:"alertRouter"`
		}
		if err = json.Unmarshal(body, &values); err != nil {
			t.Fatal(err)
		}
		var raw map[string]any
		if err = json.Unmarshal(body, &raw); err != nil {
			t.Fatal(err)
		}
		if _, ok := raw["adoption"]; ok {
			t.Fatalf("%s Helm values retained retired adoption mode", test.environment)
		}
		if values.ServiceAccount.GCPServiceAccount != test.want {
			t.Fatalf("%s Workload Identity = %q, want %q", test.environment, values.ServiceAccount.GCPServiceAccount, test.want)
		}
		if values.ServiceAccount.ReleaseObserver != platform.Spec.ReleaseObserverServiceAccount {
			t.Fatalf("observer identity did not reach Helm: %q", values.ServiceAccount.ReleaseObserver)
		}
		if raw["ssh"].(map[string]any)["enabled"] != test.gatewayEnabled {
			t.Fatal("SSH environment setting did not reach Helm")
		}
		if values.Runtime.CloudSQLInstanceConnectionName != "value" {
			t.Fatalf("%s Cloud SQL connection name = %q, want candidate replacement", test.environment, values.Runtime.CloudSQLInstanceConnectionName)
		}
		if values.Runtime.AgentVmmGatewayEnabled != test.gatewayEnabled || values.Runtime.ComputeRuntimeBaseURL != test.computeRuntimeURL {
			t.Fatalf("%s Agent VMM runtime values = %#v", test.environment, values.Runtime)
		}
		if values.References["agentVmmGatewayRuntimeSecret"] != "salix-vmm-gateway-runtime" || values.References["agentVmmGatewayClientTlsSecret"] != "salix-vmm-gateway-client-tls" || values.References["computeWorkloadCredentialSecret"] != "salix-compute-runtime" {
			t.Fatalf("%s Agent VMM Secret references = %#v", test.environment, values.References)
		}
		if _, ok := values.References["bridgeDatabaseSecret"]; ok {
			t.Fatalf("%s normal Helm values retained bridgeDatabaseSecret reference", test.environment)
		}
		if _, ok := values.References["systemFilesConfigMap"]; ok {
			t.Fatalf("%s normal Helm values retained candidate system-files ConfigMap reference", test.environment)
		}
		if _, ok := values.Workloads["productReplicas"]; ok {
			t.Fatalf("%s Helm values retained legacy product replicas", test.environment)
		}
		if _, ok := values.Workloads["productServingOwner"]; ok {
			t.Fatalf("%s Helm values retained product serving owner", test.environment)
		}
		if values.AlertRouter.Enabled || values.AlertRouter.Replicas != 2 {
			t.Fatalf("%s default Alert Router values = %#v", test.environment, values.AlertRouter)
		}
	}
}

func TestBuildHelmValuesEnablesAlertRouterOnlyWithMatchingReleaseSubsystem(t *testing.T) {
	replacements := testCandidateReplacements()
	replacements["COMMA_ALERT_ROUTER_ENABLED"] = "true"
	replacements["COMMA_RELEASE_SUBSYSTEMS"] = "salix,bridge_for_teams,comma_product,alert_router"
	replacements["ALERT_ROUTER_CONFIG_SECRET_NAME"] = "alert-router-config"
	replacements["ALERT_ROUTER_CONFIG_SHA256"] = "alert-router-checksum"
	platform := KubectlPlatform{Spec: EnvironmentSpec{Environment: "staging", Project: "example-staging-project", RuntimeServiceAccount: "runtime-staging@example-staging-project.iam.gserviceaccount.com"}}
	body, err := platform.buildHelmValues(replacements)
	if err != nil {
		t.Fatal(err)
	}
	var values struct {
		AlertRouter struct {
			Enabled  bool `json:"enabled"`
			Replicas int  `json:"replicas"`
		} `json:"alertRouter"`
	}
	if err = json.Unmarshal(body, &values); err != nil {
		t.Fatal(err)
	}
	if !values.AlertRouter.Enabled || values.AlertRouter.Replicas != 2 {
		t.Fatalf("enabled Alert Router values = %#v", values.AlertRouter)
	}
	replacements["COMMA_RELEASE_SUBSYSTEMS"] = "salix,bridge_for_teams,comma_product"
	if _, err = platform.buildHelmValues(replacements); err == nil || !strings.Contains(err.Error(), "disagree") {
		t.Fatalf("mismatched Alert Router release selection was accepted: %v", err)
	}
}

func TestBuildHelmValuesTreatsLegacyCandidateBundleAsAlertRouterDisabled(t *testing.T) {
	replacements := testCandidateReplacements()
	delete(replacements, "COMMA_ALERT_ROUTER_ENABLED")
	delete(replacements, "COMMA_RELEASE_SUBSYSTEMS")
	platform := KubectlPlatform{Spec: EnvironmentSpec{Environment: "staging", Project: "example-staging-project", RuntimeServiceAccount: "runtime-staging@example-staging-project.iam.gserviceaccount.com"}}
	body, err := platform.buildHelmValues(replacements)
	if err != nil {
		t.Fatal(err)
	}
	var values struct {
		AlertRouter struct {
			Enabled bool `json:"enabled"`
		} `json:"alertRouter"`
	}
	if err = json.Unmarshal(body, &values); err != nil {
		t.Fatal(err)
	}
	if values.AlertRouter.Enabled {
		t.Fatal("legacy candidate bundle unexpectedly enabled Alert Router")
	}
}

func TestReleaseJobUsesCandidateSelectedSubsystems(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	replacements := testCandidateReplacements()
	replacements["COMMA_ALERT_ROUTER_ENABLED"] = "true"
	replacements["COMMA_RELEASE_SUBSYSTEMS"] = "salix,bridge_for_teams,comma_product,alert_router"
	manifest := p.jobManifest(JobSpec{Name: "plan", Stage: "plan", Image: "image"}, replacements)
	pod := manifest["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
	container := pod["containers"].([]any)[0].(map[string]any)
	env := container["env"].([]any)
	selected := ""
	for _, raw := range env {
		entry := raw.(map[string]any)
		if entry["name"] == "COMMA_SUBSYSTEMS" {
			selected, _ = entry["value"].(string)
		}
	}
	if selected != replacements["COMMA_RELEASE_SUBSYSTEMS"] {
		t.Fatalf("release Job subsystems = %q", selected)
	}
}

func TestReleaseJobKeepsLegacyCandidateBundleOnCoreSubsystems(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	replacements := testCandidateReplacements()
	delete(replacements, "COMMA_ALERT_ROUTER_ENABLED")
	delete(replacements, "COMMA_RELEASE_SUBSYSTEMS")
	manifest := p.jobManifest(JobSpec{Name: "plan", Stage: "plan", Image: "image"}, replacements)
	pod := manifest["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
	container := pod["containers"].([]any)[0].(map[string]any)
	for _, raw := range container["env"].([]any) {
		entry := raw.(map[string]any)
		if entry["name"] == "COMMA_SUBSYSTEMS" && entry["value"] != coreReleaseSubsystems {
			t.Fatalf("legacy release Job subsystems = %q", entry["value"])
		}
	}
}

func testCandidateBundle(t *testing.T) []byte {
	t.Helper()
	body, err := json.Marshal(CandidateBundle{SchemaVersion: 1, Replacements: testCandidateReplacements()})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func testCandidateReplacements() map[string]string {
	replacements := map[string]string{}
	for _, key := range []string{
		"COMMA_IMAGE", "COMMA_REVISION", "COMMA_REVISION_LABEL", "COMMA_TRACE_SAMPLE_RATIO",
		"COMMA_LEGACY_MESSAGE_EVENT_CLAIM_WRITER_FENCE_EPOCH", "SALIX_CONFIG_SHA256",
		"COMMA_SECRETS_NAME", "INSTANCE_CONNECTION_NAME", "SALIX_CONFIG_SECRET_NAME",
		"SALIX_TLS_SECRET_NAME", "SALIX_SITES_TLS_SECRET_NAME", "TEAMS_TLS_SECRET_NAME", "COMMA_STATIC_IP",
		"SALIX_HOST", "SALIX_SITES_DOMAIN", "BRIDGE_HOST",
	} {
		replacements[key] = "value"
	}
	replacements["COMMA_ALERT_ROUTER_ENABLED"] = "false"
	replacements["COMMA_RELEASE_SUBSYSTEMS"] = "salix,bridge_for_teams,comma_product"
	return replacements
}

func TestWaitForJobReturnsFailedTerminalCondition(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		joined := strings.Join(args, " ")
		if strings.Contains(joined, " wait --for=condition=complete ") {
			return nil, errors.New("timed out")
		}
		if strings.Contains(joined, " get job/failed -o json") {
			return []byte(`{"status":{"conditions":[{"type":"Failed","status":"True"}]}}`), nil
		}
		return nil, errors.New("unexpected kubectl call: " + joined)
	})
	if err := p.waitForJob(context.Background(), "failed"); err == nil || !strings.Contains(err.Error(), "release job failed failed") {
		t.Fatalf("failed terminal condition was not returned: %v", err)
	}
}

func TestEnsureJobReturnsFailedContainerLogsBeforeRecoveryDeletesJob(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	jobReads := 0
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		joined := strings.Join(args, " ")
		switch {
		case strings.Contains(joined, "get configmap/bundle -o jsonpath="):
			return []byte(`{"COMMA_SECRETS_NAME":"secrets","INSTANCE_CONNECTION_NAME":"instance","SALIX_CONFIG_SECRET_NAME":"salix-config"}`), nil
		case strings.Contains(joined, "get job/failed -o json"):
			jobReads++
			if jobReads == 1 {
				return nil, errors.New("NotFound")
			}
			return []byte(`{"status":{"conditions":[{"type":"Failed","status":"True"}]}}`), nil
		case slicesContain(args, "create"):
			return nil, nil
		case strings.Contains(joined, "wait --for=condition=complete job/failed"):
			return nil, errors.New("timed out")
		case strings.Contains(joined, "logs job/failed --all-containers=true --tail=1000 --limit-bytes=65536"):
			return []byte(
				"** (Postgrex.Error) password=hunter2 REDIS_URL=redis://:redis-secret@redis/0 database authentication failed\n" +
					strings.Repeat("migration info\n", 220) +
					strings.Repeat("proxy shutdown noise\n", 700),
			), nil
		default:
			return nil, errors.New("unexpected kubectl call: " + joined)
		}
	})

	_, err := p.ensureJob(context.Background(), JobSpec{Name: "failed", Stage: "plan", Image: "image", BundleName: "bundle"})
	if err == nil || !strings.Contains(err.Error(), "release job failed failed") ||
		!strings.Contains(err.Error(), "password=[redacted]") ||
		!strings.Contains(err.Error(), "REDIS_URL=redis://[redacted]@redis/0") ||
		!strings.Contains(err.Error(), "database authentication failed") ||
		strings.Contains(err.Error(), "hunter2") || strings.Contains(err.Error(), "redis-secret") {
		t.Fatalf("failed Job did not preserve its container logs: %v", err)
	}
}

func TestReleaseJobLogDiagnosticIsLocallyByteBounded(t *testing.T) {
	logs := []byte(
		"password=early-secret " +
			strings.Repeat("x", 60*1024) +
			"\n** (Postgrex.Error) password=late-secret application root cause\n" +
			strings.Repeat("migration info\n", 220) +
			strings.Repeat("proxy shutdown noise\n", 220),
	)
	got := releaseJobLogDiagnostic(logs)
	if len(got) > 4200 || !strings.Contains(got, "[truncated") ||
		!strings.Contains(got, "[failure context]") ||
		!strings.Contains(got, "Postgrex.Error") ||
		!strings.Contains(got, "password=[redacted] application root cause") ||
		!strings.Contains(got, "[final log tail]") ||
		!strings.Contains(got, "proxy shutdown noise") {
		t.Fatalf("release Job diagnostic was not bounded and redacted: length=%d value=%q", len(got), got)
	}
	for _, secret := range []string{"early-secret", "late-secret"} {
		if strings.Contains(got, secret) {
			t.Fatalf("release Job diagnostic leaked %q", secret)
		}
	}
}

func TestWaitForJobReportsAndBoundsPendingPod(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}, JobPendingTimeout: time.Millisecond}
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		joined := strings.Join(args, " ")
		switch {
		case strings.Contains(joined, " wait --for=condition=complete "):
			return nil, errors.New("timed out")
		case strings.Contains(joined, " get job/pending -o json"):
			return []byte(`{"status":{}}`), nil
		case strings.Contains(joined, " get pods -l job-name=pending -o json"):
			return []byte(`{"items":[{"metadata":{"name":"pending-x"},"status":{"phase":"Pending","conditions":[{"type":"PodScheduled","status":"False","reason":"Unschedulable","message":"insufficient cpu"}],"containerStatuses":[]}}]}`), nil
		default:
			return nil, errors.New("unexpected kubectl call: " + joined)
		}
	})
	err := p.waitForJob(context.Background(), "pending")
	if err == nil || !strings.Contains(err.Error(), "remained pending") || !strings.Contains(err.Error(), "Unschedulable") || !strings.Contains(err.Error(), "insufficient cpu") {
		t.Fatalf("pending Job did not return its actionable reason: %v", err)
	}
}

func TestJobPendingObservationIncludesImagePullReason(t *testing.T) {
	body := []byte(`{"items":[{"metadata":{"name":"plan-x"},"status":{"phase":"Pending","containerStatuses":[{"name":"release","state":{"waiting":{"reason":"ImagePullBackOff","message":"image not found"}}}]}}]}`)
	observation, pending, err := jobPendingObservation(body)
	if err != nil || !pending || !strings.Contains(observation, "ImagePullBackOff") || !strings.Contains(observation, "image not found") {
		t.Fatalf("unexpected pending observation: %q %v %v", observation, pending, err)
	}

	running := []byte(`{"items":[{"metadata":{"name":"plan-x"},"status":{"phase":"Running","containerStatuses":[{"name":"release","state":{"running":{}}}]}}]}`)
	_, pending, err = jobPendingObservation(running)
	if err != nil || pending {
		t.Fatalf("running pod was classified as pending: %v %v", pending, err)
	}
}

func TestAbortAttemptsDeletesOnlyDurablyFencedPendingJobs(t *testing.T) {
	state := State{ReleaseID: "release-1", ManifestDigest: "sha256:digest", Attempts: []JobAttempt{
		{Stage: "plan", Attempt: 1, Name: "comma-release-release-1-plan-1", Status: "pending"},
		{Stage: "online", Attempt: 1, Name: "comma-release-release-1-online-1", Status: "complete"},
	}}
	var calls []string
	exists := true
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		joined := strings.Join(args, " ")
		calls = append(calls, joined)
		if strings.Contains(joined, " get job/comma-release-release-1-plan-1 -o json") {
			if !exists {
				return nil, errors.New("NotFound")
			}
			return []byte(`{"metadata":{"name":"comma-release-release-1-plan-1","uid":"uid-1","resourceVersion":"7","labels":{"comma.surf/release-id":"release-1"},"annotations":{"comma.surf/fence":"release-1"}}}`), nil
		}
		if strings.Contains(joined, " label job/comma-release-release-1-plan-1 comma.surf/abort-token=uid-1 --resource-version=7 --overwrite") {
			return nil, nil
		}
		if strings.Contains(joined, " delete job -l comma.surf/abort-token=uid-1 ") {
			exists = false
			return nil, nil
		}
		return nil, errors.New("unexpected kubectl call: " + joined)
	})
	if err := p.AbortAttempts(context.Background(), state); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(calls, "\n")
	if !strings.Contains(joined, "delete job -l comma.surf/abort-token=uid-1 --cascade=foreground --wait=true --timeout=2m") || strings.Contains(joined, "job/comma-release-release-1-online-1") {
		t.Fatalf("unexpected abort calls: %s", joined)
	}
}

func TestAbortAttemptsRejectsFenceMismatch(t *testing.T) {
	state := State{ReleaseID: "release-1", Attempts: []JobAttempt{{Stage: "plan", Attempt: 1, Name: "comma-release-release-1-plan-1", Status: "pending"}}}
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		joined := strings.Join(args, " ")
		if strings.Contains(joined, " get job/") {
			return []byte(`{"metadata":{"name":"comma-release-release-1-plan-1","uid":"uid-1","resourceVersion":"7","labels":{"comma.surf/release-id":"another-release"},"annotations":{"comma.surf/fence":"another-release"}}}`), nil
		}
		return nil, errors.New("must not delete a mismatched job")
	})
	if err := p.AbortAttempts(context.Background(), state); err == nil || !strings.Contains(err.Error(), "fence mismatch") {
		t.Fatalf("mismatched release job was accepted: %v", err)
	}
}

func TestDeleteTerminalJobsRemovesCompleteAndFailedButKeepsActive(t *testing.T) {
	var calls []string
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		joined := strings.Join(args, " ")
		calls = append(calls, joined)
		if strings.Contains(joined, " get job ") {
			return []byte(`{"items":[
				{"metadata":{"name":"complete"},"status":{"conditions":[{"type":"Complete","status":"True"}]}},
				{"metadata":{"name":"failed"},"status":{"conditions":[{"type":"Failed","status":"True"}]}},
				{"metadata":{"name":"active"},"status":{"conditions":[]}}
			]}`), nil
		}
		return nil, nil
	})
	if err := p.deleteTerminalJobs(context.Background()); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(calls, "\n")
	if !strings.Contains(joined, "delete job/complete") || !strings.Contains(joined, "delete job/failed") {
		t.Fatalf("terminal Jobs were not deleted: %s", joined)
	}
	if strings.Contains(joined, "delete job/active") {
		t.Fatalf("active Job was deleted: %s", joined)
	}
}

func TestKubernetesJobReuseRejectsOldBundleAndAllowedIDs(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	spec := JobSpec{Name: "job", Stage: "online", Image: "image", ManifestDigest: "digest", BundleName: "bundle-new", Attempt: 2, AllowedStepIDs: []string{"billing-1"}, Fence: "release:digest"}
	replacements := map[string]string{"COMMA_SECRETS_NAME": "comma-secrets-new", "INSTANCE_CONNECTION_NAME": "project:region:instance", "SALIX_CONFIG_SECRET_NAME": "salix-new"}
	stale := p.jobManifest(spec, replacements)
	annotations := stale["metadata"].(map[string]any)["annotations"].(map[string]string)
	annotations["comma.surf/bundle-name"] = "bundle-old"
	annotations["comma.surf/allowed-step-ids"] = `["bridge-2"]`
	staleBody, _ := json.Marshal(stale)
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		for _, arg := range args {
			if arg == "jsonpath={.data.bundle\\.json}" {
				return json.Marshal(replacements)
			}
		}
		return staleBody, nil
	})
	if _, err := p.ensureJob(context.Background(), spec); err == nil {
		t.Fatal("Kubernetes job adapter accepted stale bundle and allowed ids")
	}
}

func TestJobCreateResponseLossRecoversSameDeterministicSpec(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	spec := JobSpec{Name: "job", Stage: "online", Image: "image", ManifestDigest: "digest", BundleName: "bundle", Attempt: 1, AllowedStepIDs: []string{"billing-1"}, Fence: "release:digest"}
	replacements := map[string]string{"COMMA_SECRETS_NAME": "comma-secrets", "INSTANCE_CONNECTION_NAME": "project:region:instance", "SALIX_CONFIG_SECRET_NAME": "salix"}
	expected, _ := json.Marshal(p.jobManifest(spec, replacements))
	jobReads := 0
	p.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		joined := strings.Join(args, " ")
		switch {
		case strings.Contains(joined, "jsonpath={.data.bundle\\.json}"):
			return json.Marshal(replacements)
		case strings.Contains(joined, " get job/job ") || strings.HasSuffix(joined, " get job/job -o json"):
			jobReads++
			if jobReads == 1 {
				return nil, errors.New("NotFound")
			}
			return expected, nil
		case strings.Contains(joined, "create -f -"):
			return nil, errors.New("connection lost")
		case strings.Contains(joined, "wait --for=condition=complete"):
			return nil, nil
		case strings.Contains(joined, "logs job/job"):
			return []byte("complete"), nil
		default:
			return nil, errors.New("unexpected kubectl call: " + joined)
		}
	})
	if _, err := p.ensureJob(context.Background(), spec); err != nil {
		t.Fatal(err)
	}
}

func slicesContain(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

func TestHealthFactsMustBelongToTheSameEndpoint(t *testing.T) {
	endpointBody := []byte(`{"items":[{"endpoints":[{"addresses":["10.0.0.1"],"conditions":{"ready":true,"terminating":false},"targetRef":{"name":"comma-1"}},{"addresses":["10.0.0.2"],"conditions":{"ready":true},"targetRef":{"name":"comma-0"}}]}]}`)
	if endpointReady(endpointBody, "comma-1", "10.0.0.2") {
		t.Fatal("EndpointSlice facts from different endpoints were combined")
	}
	if !endpointReady(endpointBody, "comma-1", "10.0.0.1") {
		t.Fatal("matching ready endpoint was rejected")
	}

	healthBody := []byte(`[{"ipAddress":"10.0.0.1","healthState":"UNHEALTHY"},{"ipAddress":"10.0.0.2","healthState":"HEALTHY"}]`)
	if backendHealthy(healthBody, "10.0.0.1") {
		t.Fatal("health facts from different backend entries were combined")
	}
}

func TestOrdinalPublicHealthChecksUseReadinessForEverySurface(t *testing.T) {
	runner := &verifyRunner{}
	p := KubectlPlatform{
		Kubectl: runner,
		Curl:    runner,
		Gcloud:  verifyGcloudRunner{},
		Spec: EnvironmentSpec{
			Namespace:   "comma",
			Project:     "project",
			Location:    "region",
			PublicHosts: []string{"salix.example.test", "teams.example.test"},
		},
	}

	if err := p.verifyOrdinalOnce(context.Background(), "comma-0", []string{"comma-salix", "comma-teams", "comma-product"}); err != nil {
		t.Fatal(err)
	}
	calls := strings.Join(runner.calls, "\n")
	for _, host := range p.Spec.PublicHosts {
		if !strings.Contains(calls, "https://"+host+"/ready") {
			t.Fatalf("readiness URL missing for %s: %s", host, calls)
		}
	}
	if strings.Contains(calls, "/health") || strings.Contains(calls, "/login") {
		t.Fatalf("retired public health path remained: %s", calls)
	}
}

type verifyRunner struct {
	calls                 []string
	alertRouterEnabled    bool
	routerPaths           []string
	omitRouterEndpoint    bool
	wrongRouterRoute      bool
	extraRouterRoute      bool
	unattachedRouterRoute bool
}

func (r *verifyRunner) Run(_ context.Context, _ []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	r.calls = append(r.calls, joined)
	switch {
	case len(args) > 0 && args[0] == "status":
		return []byte(`{"version":7,"info":{"status":"deployed"}}`), nil
	case len(args) > 0 && args[0] == "upgrade":
		return []byte("ok"), nil
	case len(args) > 1 && args[0] == "get" && args[1] == "values":
		return []byte(`{"network":{"salixHost":"salix.example.test"}}`), nil
	case strings.Contains(joined, "get pod/comma-1"):
		return []byte("10.0.0.2"), nil
	case strings.Contains(joined, "get pod/comma-0"):
		return []byte("10.0.0.1"), nil
	case strings.Contains(joined, "kubernetes.io/service-name=comma-alert-router"):
		if r.omitRouterEndpoint {
			return []byte(`{"items":[]}`), nil
		}
		return []byte(`{"items":[{"endpoints":[{"addresses":["10.0.1.1"],"conditions":{"ready":true}}]}]}`), nil
	case strings.Contains(joined, "get endpointslice"):
		return []byte(`{"items":[{"endpoints":[{"addresses":["10.0.0.1"],"conditions":{"ready":true},"targetRef":{"name":"comma-0"}},{"addresses":["10.0.0.2"],"conditions":{"ready":true},"targetRef":{"name":"comma-1"}}]}]}`), nil
	case strings.Contains(joined, "get deployment/comma-alert-router -o json"):
		return []byte(`{"spec":{"template":{"spec":{"containers":[{"name":"comma"},{"name":"cloud-sql-proxy","args":["--private-ip","project:region:instance"]}]}}}}`), nil
	case strings.Contains(joined, "get configmap/bundle"):
		subsystems := coreReleaseSubsystems
		if r.alertRouterEnabled {
			subsystems += ",alert_router"
		}
		return []byte(fmt.Sprintf(`{"SALIX_HOST":"salix.example.test","COMMA_WEB_COOKIE_ORIGIN":"https://app.example.test","COMMA_ADMIN_COOKIE_ORIGIN":"https://admin.example.test","COMMA_ALERT_ROUTER_ENABLED":"%t","COMMA_RELEASE_SUBSYSTEMS":"%s"}`, r.alertRouterEnabled, subsystems)), nil
	case strings.Contains(joined, "get httproute/comma-salix"):
		pathType := "Exact"
		if r.wrongRouterRoute {
			pathType = "PathPrefix"
		}
		extraRule := ""
		if r.extraRouterRoute {
			extraRule = `,{"matches":[{"path":{"type":"PathPrefix","value":"/v1/events"}}],"backendRefs":[{"name":"comma-alert-router","port":80}]}`
		}
		parentAndStatus := `"parentRefs":[{"name":"comma"}],"hostnames":["salix.example.test"],`
		status := `,"status":{"parents":[{"parentRef":{"name":"comma"},"conditions":[{"type":"Accepted","status":"True","observedGeneration":7},{"type":"ResolvedRefs","status":"True","observedGeneration":7}]}]}`
		if r.unattachedRouterRoute {
			parentAndStatus = `"hostnames":["salix.example.test"],`
			status = ""
		}
		paths := r.routerPaths
		if paths == nil {
			paths = []string{"gcp", "grafana", "github"}
		}
		matches := make([]string, 0, len(paths))
		for _, path := range paths {
			pathValue := "/v1/events/" + path
			if path == "interactions/slack" {
				pathValue = "/v1/interactions/slack"
			}
			matches = append(matches, fmt.Sprintf(`{"path":{"type":%q,"value":%q}}`, pathType, pathValue))
		}
		return []byte(fmt.Sprintf(`{"metadata":{"name":"comma-salix","generation":7},"spec":{%s"rules":[{"matches":[%s],"backendRefs":[{"name":"comma-alert-router","port":80}]}%s]}%s}`, parentAndStatus, strings.Join(matches, ","), extraRule, status)), nil
	default:
		return nil, nil
	}
}

func TestValidateTerminalPodShapeRejectsRetiredFields(t *testing.T) {
	clean := `{"containers":[{"name":"comma"},{"name":"cloud-sql-proxy","args":["--private-ip","project:region:instance"]}]}`
	for _, test := range []struct {
		name string
		body string
		want string
	}{
		{"clean", clean, ""},
		{"native sidecar", `{"initContainers":[{"name":"cloud-sql-proxy","restartPolicy":"Always","args":["--private-ip","project:region:instance"]}],"containers":[{"name":"comma"}]}`, ""},
		{"init container", `{"initContainers":[{"name":"comma-system-files"}],"containers":[{"name":"cloud-sql-proxy","args":["project:region:instance"]}]}`, "init container"},
		{"mount", `{"containers":[{"name":"comma","volumeMounts":[{"name":"other","mountPath":"/etc/salix-system"}]},{"name":"cloud-sql-proxy","args":["project:region:instance"]}]}`, "system-files mount"},
		{"volume", `{"volumes":[{"name":"comma-system-files-archive"}],"containers":[{"name":"cloud-sql-proxy","args":["project:region:instance"]}]}`, "volume"},
		{"secret env", `{"containers":[{"name":"cloud-sql-proxy","args":["project:region:instance"],"env":[{"name":"INSTANCE_CONNECTION_NAME"}]}]}`, "environment source"},
		{"missing proxy", `{"containers":[{"name":"comma"}]}`, "omits the Cloud SQL proxy"},
		{"missing direct arg", `{"containers":[{"name":"cloud-sql-proxy","args":["--private-ip"]}]}`, "terminal direct instance argument"},
	} {
		t.Run(test.name, func(t *testing.T) {
			var spec terminalPodShape
			if err := json.Unmarshal([]byte(test.body), &spec); err != nil {
				t.Fatal(err)
			}
			err := validateTerminalPodShape("fixture", spec)
			if test.want == "" && err != nil {
				t.Fatal(err)
			}
			if test.want != "" && (err == nil || !strings.Contains(err.Error(), test.want)) {
				t.Fatalf("validation error = %v, want %q", err, test.want)
			}
		})
	}
}

type verifyGcloudRunner struct{}

func (verifyGcloudRunner) Run(_ context.Context, _ []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	if strings.Contains(joined, "backend-services list") {
		return []byte("lb-comma-comma-salix-80-a\nlb-comma-comma-teams-80-b\nlb-comma-comma-product-80-c\n"), nil
	}
	return []byte(`[{"ipAddress":"10.0.0.1","healthState":"HEALTHY"},{"ipAddress":"10.0.0.2","healthState":"HEALTHY"}]`), nil
}

func TestVerifyPreservesCollectorOrdinalOneOrdinalZeroOrder(t *testing.T) {
	runner := &verifyRunner{}
	p := KubectlPlatform{
		Kubectl:    runner,
		Curl:       runner,
		Gcloud:     verifyGcloudRunner{},
		Helm:       testHelm(runner),
		HelmValues: []byte(`{"rollout":{}}`),
		Spec: EnvironmentSpec{
			Namespace: "comma", Project: "project", Location: "region",
			PublicHosts: []string{"salix.example.test"},
		},
		Poll: time.Nanosecond,
	}
	state := State{
		ReleaseID: "ordinary-release", BundleName: "bundle",
		RequiredMode: ModeOnline,
	}
	if _, err := p.Verify(context.Background(), state); err != nil {
		t.Fatal(err)
	}

	index := func(fragment string) int {
		for i, call := range runner.calls {
			if strings.Contains(call, fragment) {
				return i
			}
		}
		return -1
	}
	collector := index("rollout status deployment/comma-otel-collector")
	ordinalOne := index("get pod/comma-1")
	partitionZero := index("upgrade comma")
	ordinalZero := index("get pod/comma-0")
	if collector < 0 || !(collector < ordinalOne && ordinalOne < partitionZero && partitionZero < ordinalZero) {
		t.Fatalf("unexpected verify order: %#v", runner.calls)
	}
	if strings.Contains(strings.Join(runner.calls, "\n"), "patch statefulset/comma") {
		t.Fatalf("online rollout used forbidden kubectl patch: %#v", runner.calls)
	}
	if strings.Contains(strings.Join(runner.calls, "\n"), "--install") {
		t.Fatalf("online rollout retained forbidden Helm fresh-install capability: %#v", runner.calls)
	}
	for _, service := range []string{"comma-salix", "comma-teams", "comma-product"} {
		if index("kubernetes.io/service-name="+service) < 0 {
			t.Fatalf("verify omitted ready endpoints for %s: %#v", service, runner.calls)
		}
	}
}

func TestVerifyWaitsForAndAuditsEnabledAlertRouter(t *testing.T) {
	runner := &verifyRunner{
		alertRouterEnabled: true,
		routerPaths:        []string{"gcp", "runtime-storage", "grafana", "github", "posthog", "slack", "interactions/slack"},
	}
	p := KubectlPlatform{
		Kubectl: runner, Curl: runner, Gcloud: verifyGcloudRunner{},
		Helm: testHelm(runner), HelmValues: []byte(`{"rollout":{}}`),
		Spec: EnvironmentSpec{Namespace: "comma", Project: "project", Location: "region", PublicHosts: []string{"salix.example.test"}},
		Poll: time.Nanosecond,
	}
	if _, err := p.Verify(context.Background(), State{ReleaseID: "router-release", BundleName: "bundle", RequiredMode: ModeOnline}); err != nil {
		t.Fatal(err)
	}
	calls := strings.Join(runner.calls, "\n")
	for _, expected := range []string{"rollout status deployment/comma-alert-router", "get httproute/comma-salix", "kubernetes.io/service-name=comma-alert-router"} {
		if !strings.Contains(calls, expected) {
			t.Fatalf("enabled Alert Router verification omitted %q: %s", expected, calls)
		}
	}
}

func TestAlertRouterServingPathAcceptsOptionalSources(t *testing.T) {
	for _, paths := range [][]string{
		{"gcp", "grafana", "github"},
		{"gcp", "grafana", "github", "runtime-storage"},
		{"gcp", "grafana", "github", "posthog"},
		{"gcp", "grafana", "github", "runtime-storage", "posthog"},
	} {
		t.Run(strings.Join(paths, "+"), func(t *testing.T) {
			runner := &verifyRunner{routerPaths: paths}
			p := KubectlPlatform{Kubectl: runner, Spec: EnvironmentSpec{Namespace: "comma"}}
			if err := p.verifyAlertRouterServingPath(context.Background(), "salix.example.test"); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestVerifyFailsClosedWithoutAlertRouterServingPath(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*verifyRunner)
		want   string
	}{
		{name: "missing ready endpoint", mutate: func(r *verifyRunner) { r.omitRouterEndpoint = true }, want: "no ready EndpointSlice"},
		{name: "wrong route match", mutate: func(r *verifyRunner) { r.wrongRouterRoute = true }, want: "exact event paths"},
		{name: "unknown optional path", mutate: func(r *verifyRunner) { r.routerPaths = []string{"gcp", "grafana", "github", "unknown"} }, want: "exact event paths"},
		{name: "optional path replaces required path", mutate: func(r *verifyRunner) { r.routerPaths = []string{"gcp", "grafana", "runtime-storage"} }, want: "exact event paths"},
		{name: "posthog replaces required path", mutate: func(r *verifyRunner) { r.routerPaths = []string{"gcp", "grafana", "posthog"} }, want: "exact event paths"},
		{name: "duplicate posthog path", mutate: func(r *verifyRunner) { r.routerPaths = []string{"gcp", "grafana", "github", "posthog", "posthog"} }, want: "exact event paths"},
		{name: "posthog suffix", mutate: func(r *verifyRunner) { r.routerPaths = []string{"gcp", "grafana", "github", "posthog/extra"} }, want: "exact event paths"},
		{name: "duplicate required path", mutate: func(r *verifyRunner) { r.routerPaths = []string{"gcp", "grafana", "github", "github"} }, want: "exact event paths"},
		{name: "additional broad Router route", mutate: func(r *verifyRunner) { r.extraRouterRoute = true }, want: "exactly one Router rule"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			runner := &verifyRunner{alertRouterEnabled: true}
			tc.mutate(runner)
			p := KubectlPlatform{
				Kubectl: runner, Curl: runner, Gcloud: verifyGcloudRunner{},
				Helm: testHelm(runner), HelmValues: []byte(`{"rollout":{}}`),
				Spec: EnvironmentSpec{Namespace: "comma", Project: "project", Location: "region", PublicHosts: []string{"salix.example.test"}},
				Poll: time.Nanosecond,
			}
			_, err := p.Verify(context.Background(), State{ReleaseID: "router-release", BundleName: "bundle", RequiredMode: ModeOnline})
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("Verify() error = %v, want %q", err, tc.want)
			}
		})
	}
}

func TestRestoreFailsClosedWhenRestoredAlertRouterServingPathDrifts(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(*verifyRunner)
	}{
		{name: "wrong Router path", mutate: func(r *verifyRunner) { r.wrongRouterRoute = true }},
		{name: "route detached from public Gateway", mutate: func(r *verifyRunner) { r.unattachedRouterRoute = true }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			runner := &verifyRunner{alertRouterEnabled: true}
			tc.mutate(runner)
			p := KubectlPlatform{
				Kubectl: runner,
				Helm:    testHelm(runner),
				Spec:    EnvironmentSpec{Namespace: "comma"},
			}
			err := p.Restore(context.Background(), State{
				ReleaseID: "router-release",
				Helm:      HelmFacts{SnapshotRevision: 7},
			})
			if err == nil || !strings.Contains(err.Error(), "restored Alert Router serving path") {
				t.Fatalf("Restore() error = %v, want restored serving-path failure", err)
			}
			for _, expected := range []string{"get deployment/comma-alert-router -o name", "rollout status deployment/comma-alert-router", "get values comma", "get httproute/comma-salix"} {
				if !strings.Contains(strings.Join(runner.calls, "\n"), expected) {
					t.Fatalf("Restore() omitted %q: %#v", expected, runner.calls)
				}
			}
		})
	}
}

func TestExclusiveVerifyUsesCandidateOnlyOrderedReadyZeroThenOne(t *testing.T) {
	runner := &verifyRunner{}
	p := KubectlPlatform{
		Kubectl: runner,
		Curl:    runner,
		Gcloud:  verifyGcloudRunner{},
		Helm:    testHelm(runner),
		Spec: EnvironmentSpec{
			Namespace: "comma", Project: "project", Location: "region",
			PublicHosts: []string{"salix.example.test"},
		},
		Poll: time.Nanosecond,
	}
	state := State{
		ReleaseID: "exclusive-release", BundleName: "bundle",
		RequiredMode: ModeExclusive,
	}
	if _, err := p.Verify(context.Background(), state); err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(runner.calls, "\n")
	zero := strings.Index(joined, "get pod/comma-0")
	one := strings.Index(joined, "get pod/comma-1")
	if zero < 0 || one < 0 || zero >= one || strings.Contains(joined, "patch statefulset/comma") {
		t.Fatalf("exclusive verify did not follow candidate-only 0->1 order: %s", joined)
	}
}

func TestApplyUsesHelmRevisionAndManifestEvidence(t *testing.T) {
	runner := &helmRunner{}
	p := KubectlPlatform{Helm: testHelm(runner), HelmValues: []byte(`{"rollout":{}}`)}
	state := State{BundleName: "bundle", RequiredMode: ModeOnline}
	evidence, err := p.Apply(context.Background(), state)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(evidence.ManifestDigest, "sha256:") || evidence.HelmRevision != 7 {
		t.Fatalf("missing apply evidence: %#v", evidence)
	}
	for _, call := range runner.calls {
		if strings.Contains(strings.Join(call, " "), "kubectl") {
			t.Fatalf("apply escaped Helm adapter: %#v", runner.calls)
		}
	}
}

func TestAgentHandoffRequiresCoreSuccessAndFailureDoesNotRollback(t *testing.T) {
	ctx := context.Background()
	calls := 0
	platform := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	platform.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		calls++
		if args[len(args)-1] != "Comma.Release.transfer_agent_configuration_page(nil)" {
			t.Fatalf("unexpected RPC: %v", args)
		}
		return nil, errors.New("an old Agent obligation needs retry")
	})
	if err := platform.FinishAgentConfiguration(ctx, State{Phase: PhaseVerifying}); err == nil || calls != 0 {
		t.Fatalf("handoff ran before core success: calls=%d error=%v", calls, err)
	}
	state := State{Phase: PhaseSucceeded, ReleaseID: "online-agent"}
	if err := platform.FinishAgentConfiguration(ctx, state); err == nil || calls != 1 {
		t.Fatalf("handoff failure missing: calls=%d error=%v", calls, err)
	}
	store := &memoryStore{exists: true, record: Record{State: state, Version: "1"}}
	core := &fakePlatform{}
	engine := Engine{Store: store, Platform: core}
	got, err := engine.Recover(ctx, state.ReleaseID)
	if err != nil || got.Phase != PhaseSucceeded || core.restoreCalls != 0 || core.quiesced {
		t.Fatalf("handoff failure rolled back serving core: state=%+v error=%v platform=%+v", got, err, core)
	}
}

func TestAgentHandoffConsumesBoundedReleasePages(t *testing.T) {
	cursor := base64.StdEncoding.EncodeToString([]byte(`{"stage":"projects"}`))
	calls := 0
	platform := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	platform.Kubectl = runnerFunc(func(_ context.Context, _ []byte, args ...string) ([]byte, error) {
		calls++
		if calls == 1 {
			return []byte("COMMA_AGENT_TRANSFER_RESULT:{\"processed\":20,\"next_cursor\":\"" + cursor + "\"}\n:ok\n"), nil
		}
		if calls != 2 || args[len(args)-1] != fmt.Sprintf("Comma.Release.transfer_agent_configuration_page(%q)", cursor) {
			t.Fatalf("wrong page continuation: %v", args)
		}
		return []byte("COMMA_AGENT_TRANSFER_RESULT:{\"processed\":1,\"next_cursor\":null}\n:ok\n"), nil
	})
	if err := platform.FinishAgentConfiguration(context.Background(), State{Phase: PhaseSucceeded}); err != nil || calls != 2 {
		t.Fatalf("handoff did not complete: calls=%d error=%v", calls, err)
	}
}

func TestLoadEnvironmentSpecRequiresLiveResourceNames(t *testing.T) {
	values := map[string]string{
		"COMMA_GCP_PROJECT":                      "example-project",
		"COMMA_RELEASE_OBSERVER_SERVICE_ACCOUNT": "observer@example-project.iam.gserviceaccount.com",
		"COMMA_GKE_CLUSTER":                      "example-cluster",
		"COMMA_RUNTIME_SERVICE_ACCOUNT":          "runtime@example-project.iam.gserviceaccount.com",
		"COMMA_REDIS_SECRET_NAME":                "example-redis",
	}
	getenv := func(name string) string { return values[name] }

	var spec EnvironmentSpec
	if err := LoadEnvironmentSpec(&spec, getenv); err != nil {
		t.Fatalf("IdP secret must be optional while the IdP is disabled: %v", err)
	}
	if spec.Project != "example-project" || spec.Cluster != "example-cluster" || spec.RedisSecret != "example-redis" || spec.ReleaseObserverServiceAccount != values["COMMA_RELEASE_OBSERVER_SERVICE_ACCOUNT"] {
		t.Fatalf("live names were not applied: %#v", spec)
	}

	enabled := EnvironmentSpec{OauthIdp: "enabled"}
	if err := LoadEnvironmentSpec(&enabled, getenv); err == nil {
		t.Fatal("an enabled IdP without a secret name was accepted")
	}
	values["COMMA_OAUTH_IDP_SECRET_NAME"] = "example-idp"
	if err := LoadEnvironmentSpec(&enabled, getenv); err != nil || enabled.OAuthIdpSecret != "example-idp" {
		t.Fatalf("enabled IdP secret name was not applied: %v %#v", err, enabled)
	}

	delete(values, "COMMA_GKE_CLUSTER")
	if err := LoadEnvironmentSpec(&EnvironmentSpec{}, getenv); err == nil {
		t.Fatal("a missing cluster name was accepted")
	}
}

func TestReleaseJobsRunInTheirEnvironment(t *testing.T) {
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma", Environment: "staging"}}
	body, err := json.Marshal(p.jobManifest(JobSpec{Name: "plan", Stage: "plan", Image: "image"}, map[string]string{}))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(body), `{"name":"COMMA_ENVIRONMENT","value":"staging"}`) {
		t.Fatalf("release Job does not carry its environment: %s", body)
	}
}
