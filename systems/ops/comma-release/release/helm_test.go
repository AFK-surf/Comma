package release

import (
	"context"
	"strings"
	"testing"
)

type helmRunner struct {
	calls [][]string
}

func (r *helmRunner) Run(_ context.Context, _ []byte, args ...string) ([]byte, error) {
	r.calls = append(r.calls, append([]string(nil), args...))
	switch args[0] {
	case "status":
		return []byte(`{"version":7,"info":{"status":"deployed"}}`), nil
	case "history":
		return []byte(`[{"revision":"6","status":"superseded"},{"revision":7,"status":"deployed"}]`), nil
	case "package":
		return []byte("Successfully packaged chart and saved it to: /tmp/comma-0.1.0.tgz\n"), nil
	case "push":
		return []byte("Pushed: localhost:5000/comma:0.1.0\nDigest: sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n"), nil
	default:
		return []byte("ok"), nil
	}
}

func testHelm(r Runner) HelmAdapter {
	return HelmAdapter{Runner: r, Release: "comma", Namespace: "comma", Chart: "chart@sha256:abc", ValuesPath: "values.json", HistoryMax: 10}
}

func TestHelmUpgradeUsesCompleteResetValuesAndBoundedHistory(t *testing.T) {
	runner := &helmRunner{}
	revision, err := testHelm(runner).Upgrade(context.Background(), HelmUpgradeOptions{})
	if err != nil || revision.Revision != 7 {
		t.Fatalf("upgrade failed: %#v %v", revision, err)
	}
	command := strings.Join(runner.calls[0], " ")
	for _, required := range []string{"--values values.json", "--reset-values", "--history-max 10", "--server-side=true", "--force-conflicts", "--wait=watcher"} {
		if !strings.Contains(command, required) {
			t.Fatalf("upgrade omitted %q: %s", required, command)
		}
	}
	for _, forbidden := range []string{"--reuse-values", "--atomic", "--rollback-on-failure"} {
		if strings.Contains(command, forbidden) {
			t.Fatalf("upgrade used forbidden %q: %s", forbidden, command)
		}
	}
}

func TestHelmOrdinaryUpgradeUsesServerSideApplyWithForceConflicts(t *testing.T) {
	runner := &helmRunner{}
	if _, err := testHelm(runner).Upgrade(context.Background(), HelmUpgradeOptions{}); err != nil {
		t.Fatal(err)
	}
	command := strings.Join(runner.calls[0], " ")
	if !strings.Contains(command, "--server-side=true") || !strings.Contains(command, "--force-conflicts") {
		t.Fatalf("ordinary Helm upgrade did not assert stable-field authority: %s", command)
	}
}

func TestHelmRollbackRequiresMatchingFence(t *testing.T) {
	runner := &helmRunner{}
	adapter := testHelm(runner)
	if _, err := adapter.Rollback(context.Background(), 4, RollbackAuthorization{Allowed: true, ReleaseID: "old", ExpectedRelease: "new"}); err == nil {
		t.Fatal("rollback accepted stale release authorization")
	}
	if len(runner.calls) != 0 {
		t.Fatal("unauthorized rollback reached helm")
	}
	if _, err := adapter.Rollback(context.Background(), 4, RollbackAuthorization{Allowed: true, ReleaseID: "release-1", ExpectedRelease: "release-1"}); err != nil {
		t.Fatal(err)
	}
}

func TestHelmHistoryAcceptsStringAndNumericRevisions(t *testing.T) {
	history, err := testHelm(&helmRunner{}).History(context.Background())
	if err != nil || len(history) != 2 || history[0].Revision != 6 || history[1].Revision != 7 {
		t.Fatalf("unexpected history: %#v %v", history, err)
	}
}

func TestHelmRunRejectsForbiddenArguments(t *testing.T) {
	adapter := testHelm(&helmRunner{})
	for _, argument := range []string{"--install", "--reuse-values", "--reset-then-reuse-values", "--atomic", "--rollback-on-failure"} {
		if _, err := adapter.run(context.Background(), "upgrade", argument); err == nil {
			t.Fatalf("accepted %s", argument)
		}
	}
}

func TestHelmUpgradeRejectsFloatingOCIChart(t *testing.T) {
	adapter := testHelm(&helmRunner{})
	adapter.Chart = "oci://registry.example/comma:latest"
	if _, err := adapter.Upgrade(context.Background(), HelmUpgradeOptions{}); err == nil {
		t.Fatal("accepted floating OCI chart")
	}
}

func TestHelmUpgradeUsesTheExactImmutableOCIReference(t *testing.T) {
	runner := &helmRunner{}
	adapter := testHelm(runner)
	adapter.Chart = "oci://ghcr.io/afk-surf/charts/comma@sha256:" + strings.Repeat("a", 64)
	digest, err := OCIChartDigest(adapter.Chart)
	if err != nil || digest != "sha256:"+strings.Repeat("a", 64) {
		t.Fatalf("immutable chart identity rejected: %q %v", digest, err)
	}
	if _, err = adapter.Upgrade(context.Background(), HelmUpgradeOptions{}); err != nil {
		t.Fatal(err)
	}
	command := strings.Join(runner.calls[0], " ")
	if !strings.Contains(command, "upgrade comma "+adapter.Chart+" ") {
		t.Fatalf("Helm did not deploy the recorded OCI identity: %s", command)
	}
	if strings.Contains(command, "--install") {
		t.Fatalf("Helm upgrade retained forbidden fresh-install capability: %s", command)
	}
	for _, invalid := range []string{
		"oci://ghcr.io/afk-surf/charts/comma:latest",
		"oci://ghcr.io/afk-surf/charts/comma:1.0.0@sha256:" + strings.Repeat("a", 64),
	} {
		if _, err = OCIChartDigest(invalid); err == nil {
			t.Fatalf("accepted non-canonical chart identity %q", invalid)
		}
	}
}

func TestHelmOCIPackagePushAndDigestPull(t *testing.T) {
	runner := &helmRunner{}
	adapter := testHelm(runner)
	adapter.Chart = "k8s/comma/chart"

	archive, err := adapter.PackageOCI(context.Background(), "/tmp/out")
	if err != nil || archive != "/tmp/comma-0.1.0.tgz" {
		t.Fatalf("package failed: %q %v", archive, err)
	}
	artifact, err := adapter.PushOCI(context.Background(), archive, "oci://localhost:5000", true)
	if err != nil {
		t.Fatal(err)
	}
	want := "localhost:5000/comma@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	if artifact.Reference != want {
		t.Fatalf("unexpected immutable OCI identity: %q", artifact.Reference)
	}
	if err := adapter.PullOCIByDigest(context.Background(), "oci://"+artifact.Reference, "/tmp/pull", true); err != nil {
		t.Fatal(err)
	}
	command := strings.Join(runner.calls[len(runner.calls)-1], " ")
	if !strings.Contains(command, "@sha256:") || !strings.Contains(command, "--plain-http") {
		t.Fatalf("pull was not digest pinned: %s", command)
	}
}

func TestHelmOCIPullRejectsFloatingIdentity(t *testing.T) {
	runner := &helmRunner{}
	adapter := testHelm(runner)
	if err := adapter.PullOCIByDigest(context.Background(), "oci://registry.example/comma:latest", "/tmp/pull", false); err == nil {
		t.Fatal("accepted floating OCI pull")
	}
	if len(runner.calls) != 0 {
		t.Fatal("floating OCI pull reached Helm")
	}
}
