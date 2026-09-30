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

type preflightTrackingRunner struct {
	base  Runner
	calls []string
}

func (r *preflightTrackingRunner) Run(ctx context.Context, body []byte, args ...string) ([]byte, error) {
	r.calls = append(r.calls, strings.Join(args, " "))
	return r.base.Run(ctx, body, args...)
}

func TestHelmPreflightE2ERejectsInvalidValuesBeforeReleaseMutation(t *testing.T) {
	if os.Getenv("COMMA_HELM_PREFLIGHT_E2E") != "1" {
		t.Skip("set COMMA_HELM_PREFLIGHT_E2E=1 on a disposable local Kubernetes cluster")
	}
	root := os.Getenv("COMMA_REPO_ROOT")
	helmBinary := os.Getenv("COMMA_HELM_BIN")
	if root == "" || helmBinary == "" {
		t.Fatal("COMMA_REPO_ROOT and COMMA_HELM_BIN are required")
	}
	ctx := context.Background()
	namespace := "comma-helm-preflight-" + strings.ToLower(strings.ReplaceAll(time.Now().UTC().Format("150405.000000"), ".", ""))
	kubectl := ExecRunner{Name: "kubectl"}
	if _, err := kubectl.Run(ctx, nil, "create", "namespace", namespace); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = kubectl.Run(context.Background(), nil, "delete", "namespace", namespace, "--wait=false")
	})

	helmRunner := &preflightTrackingRunner{base: ExecRunner{Name: helmBinary}}
	if _, err := helmRunner.Run(
		ctx,
		nil,
		"install", "comma", filepath.Join(root, "k8s/comma/chart"),
		"--namespace", namespace,
		"--set", "maintenance.enabled=true",
	); err != nil {
		t.Fatalf("seed deployed Helm release: %v", err)
	}
	platform := KubectlPlatform{
		Kubectl: kubectl,
		Helm: HelmAdapter{
			Runner: helmRunner, Release: "comma", Namespace: namespace,
			Chart: filepath.Join(root, "k8s/comma/chart"), Timeout: 2 * time.Minute,
		},
		Spec: EnvironmentSpec{Environment: "local", Namespace: namespace, Project: "local-project", Cluster: "example-cluster", RuntimeServiceAccount: "runtime-local@local-project.iam.gserviceaccount.com"},
	}

	valid := preflightBundle(t, "1.0")
	if _, err := platform.Preflight(ctx, valid); err != nil {
		t.Fatalf("valid Helm preflight failed: %v", err)
	}
	if !slicesContainSubstring(helmRunner.calls, "--dry-run=server") {
		t.Fatalf("normal preflight omitted server dry-run: %#v", helmRunner.calls)
	}
	status, err := platform.Helm.Status(ctx)
	if err != nil {
		t.Fatalf("read release after server dry-run: %v", err)
	}
	if status.Revision != 1 {
		t.Fatalf("server dry-run mutated Helm history: %#v", status)
	}

	store := &memoryStore{}
	engine := Engine{Store: store, Platform: platform, Now: time.Now}
	invalid := preflightBundle(t, "not-a-ratio")
	if _, err := engine.Prepare(ctx, "local", "invalid-values", "ghcr.io/afk-surf/comma@sha256:"+strings.Repeat("a", 64), invalid); err == nil {
		t.Fatal("invalid Helm values were accepted")
	}
	if store.exists {
		t.Fatal("invalid Helm values persisted release state before migration")
	}
	body, err := kubectl.Run(ctx, nil, "-n", namespace, "get", "jobs", "-o", "json")
	if err != nil {
		t.Fatal(err)
	}
	var jobs struct {
		Items []json.RawMessage `json:"items"`
	}
	if json.Unmarshal(body, &jobs) != nil || len(jobs.Items) != 0 {
		t.Fatalf("invalid Helm values created a migration Job: %s", body)
	}
}

func preflightBundle(t *testing.T, traceRatio string) []byte {
	t.Helper()
	replacements := map[string]string{
		"COMMA_IMAGE":    "ghcr.io/afk-surf/comma@sha256:" + strings.Repeat("a", 64),
		"COMMA_REVISION": "sha-" + strings.Repeat("a", 40), "COMMA_REVISION_LABEL": "rev-" + strings.Repeat("a", 12),
		"COMMA_TRACE_SAMPLE_RATIO": traceRatio, "COMMA_LEGACY_MESSAGE_EVENT_CLAIM_WRITER_FENCE_EPOCH": "e2e",
		"SALIX_CONFIG_SHA256": strings.Repeat("c", 64),
		"COMMA_SECRETS_NAME":  "comma-secrets", "INSTANCE_CONNECTION_NAME": "local-project:local-region:local-instance", "SALIX_CONFIG_SECRET_NAME": "salix-config",
		"SALIX_TLS_SECRET_NAME": "salix-tls", "SALIX_SITES_TLS_SECRET_NAME": "sites-tls",
		"TEAMS_TLS_SECRET_NAME": "teams-tls", "COMMA_STATIC_IP": "comma-static-ip", "SALIX_HOST": "salix.local",
		"SALIX_SITES_DOMAIN": "sites.local", "BRIDGE_HOST": "teams.local",
	}
	body, err := json.Marshal(CandidateBundle{SchemaVersion: 1, Replacements: replacements})
	if err != nil {
		t.Fatal(err)
	}
	return body
}

func slicesContainSubstring(values []string, needle string) bool {
	for _, value := range values {
		if strings.Contains(value, needle) {
			return true
		}
	}
	return false
}
