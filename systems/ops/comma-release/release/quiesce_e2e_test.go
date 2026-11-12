package release

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

func TestHelmExclusiveDrainE2E(t *testing.T) {
	if os.Getenv("COMMA_RELEASE_KUBERNETES_E2E") != "1" {
		t.Skip("requires a disposable Kubernetes cluster")
	}
	namespace := os.Getenv("COMMA_RELEASE_E2E_NAMESPACE") + "-drain"
	helmBinary := os.Getenv("COMMA_HELM_BIN")
	if namespace == "-drain" || helmBinary == "" {
		t.Fatal("test namespace and Helm binary are required")
	}
	ctx, cancel := context.WithCancel(t.Context())
	defer cancel()
	kubectl := ExecRunner{Name: "kubectl"}
	if _, err := kubectl.Run(ctx, nil, "create", "namespace", namespace); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_, _ = kubectl.Run(context.Background(), nil, "delete", "namespace", namespace, "--wait=false")
	})
	values := []byte(`{"maintenance":{"enabled":false},"replicas":2,"rollout":{"partition":0}}`)
	helm := HelmAdapter{Runner: ExecRunner{Name: helmBinary}, Release: "comma", Namespace: namespace,
		Chart: filepath.Join("testdata", "recovery-chart"), Timeout: time.Minute}
	if _, err := helm.Runner.Run(ctx, values, "install", "comma", helm.Chart, "--namespace", namespace,
		"--values", "-", "--wait=watcher", "--timeout=60s"); err != nil {
		t.Fatal(err)
	}
	// Hold deletion until both requests arrive. Cluster speed cannot determine overlap.
	for _, name := range []string{"comma-0", "comma-1"} {
		if _, err := kubectl.Run(ctx, nil, "-n", namespace, "patch", "pod/"+name, "--type=merge",
			"-p", `{"metadata":{"finalizers":["release.comma.surf/test-drain"]}}`); err != nil {
			t.Fatal(err)
		}
	}
	releaseFinalizers := func(ctx context.Context) error {
		for _, name := range []string{"comma-0", "comma-1"} {
			if _, err := kubectl.Run(ctx, nil, "-n", namespace, "patch", "pod/"+name, "--type=merge",
				"-p", `{"metadata":{"finalizers":[]}}`); err != nil && !containsNotFound(err.Error()) {
				return err
			}
		}
		return nil
	}
	t.Cleanup(func() { _ = releaseFinalizers(context.Background()) })
	p := KubectlPlatform{Kubectl: kubectl, Helm: helm, HelmValues: values,
		Spec: EnvironmentSpec{Environment: "e2e", Namespace: namespace}}
	state := NewState("e2e", "drain", "registry.k8s.io/pause:3.10", 1, time.Unix(1, 0))
	state.RequiredMode, state.Phase = ModeExclusive, PhaseQuiescing
	if _, err := (KubectlStore{Runner: kubectl, Namespace: namespace}).Create(ctx, state); err != nil {
		t.Fatal(err)
	}
	type podEvent struct {
		Type   string
		Object struct {
			Metadata struct {
				Name              string
				DeletionTimestamp *string
			}
		}
	}
	watch := exec.CommandContext(ctx, "kubectl", "-n", namespace, "get", "pods", "-l", "app.kubernetes.io/name=comma", "--watch", "--output-watch-events", "-o", "json")
	stdout, err := watch.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err = watch.Start(); err != nil {
		t.Fatal(err)
	}
	events := make(chan podEvent)
	watchErrors := make(chan error, 1)
	go func() {
		decoder := json.NewDecoder(stdout)
		for {
			var event podEvent
			if err := decoder.Decode(&event); err != nil {
				watchErrors <- fmt.Errorf("Pod watch ended: %w", err)
				break
			}
			select {
			case events <- event:
			case <-ctx.Done():
				_ = watch.Wait()
				return
			}
		}
		_ = watch.Wait()
	}()
	done := make(chan error, 1)
	terminating := map[string]bool{}
	started, drained, overlapped, deleted := false, false, false, 0
	for !drained || deleted != 2 {
		select {
		case event := <-events:
			if event.Type == "ERROR" {
				t.Fatal("Pod watch returned an API error")
			}
			if event.Type != "ADDED" && event.Type != "MODIFIED" && event.Type != "DELETED" {
				continue
			}
			name := event.Object.Metadata.Name
			if event.Type == "DELETED" {
				if !overlapped {
					t.Fatal("Pod deletion escaped the test finalizer")
				}
				delete(terminating, name)
				deleted++
			} else {
				terminating[name] = event.Object.Metadata.DeletionTimestamp != nil
			}
			if len(terminating) == 2 && !started {
				started = true
				go func() { _, err := p.Quiesce(ctx, state); done <- err }()
			}
			if terminating["comma-0"] && terminating["comma-1"] && !overlapped {
				overlapped = true
				if err := releaseFinalizers(ctx); err != nil {
					t.Fatal(err)
				}
			}
		case err := <-done:
			if err != nil {
				if terminating["comma-1"] && !terminating["comma-0"] {
					t.Fatalf("drain waited for the first Pod before stopping the next: %v", err)
				}
				t.Fatal(err)
			}
			if !overlapped {
				t.Fatal("Quiesce completed while finalizers still held the writers")
			}
			drained = true
		case err := <-watchErrors:
			t.Fatal(err)
		case <-ctx.Done():
			t.Fatal(ctx.Err())
		}
	}
	if !overlapped {
		t.Fatal("old writer grace periods ran sequentially")
	}
	body, err := kubectl.Run(ctx, nil, "-n", namespace, "get", "pods", "-l", "app.kubernetes.io/name=comma", "-o", "json")
	if err != nil {
		t.Fatal(err)
	}
	var remaining struct{ Items []json.RawMessage }
	if err := json.Unmarshal(body, &remaining); err != nil || len(remaining.Items) != 0 {
		t.Fatalf("Quiesce completed with a writer present: %s, %v", body, err)
	}
}
