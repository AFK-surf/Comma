package release

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"testing"
)

func TestRuntimePublicationUsesSuccessfulImageAndDoesNotExecuteBeforeSuccess(t *testing.T) {
	state := State{ReleaseID: "release-one", Phase: PhaseApplying,
		Image:      "ghcr.io/afk-surf/comma@sha256:" + strings.Repeat("a", 64),
		BundleName: "bundle-one", Helm: HelmFacts{ServingRevision: 42}}
	var submitted []map[string]any
	p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "comma"}}
	p.Kubectl = runnerFunc(func(_ context.Context, input []byte, args ...string) ([]byte, error) {
		switch {
		case slices.Contains(args, "configmap/bundle-one"):
			return []byte(`{"COMMA_SECRETS_NAME":"secrets","SALIX_CONFIG_SECRET_NAME":"config"}`), nil
		case slices.Contains(args, "get"):
			return nil, errors.New("NotFound")
		case slices.Contains(args, "create"):
			var job map[string]any
			if err := json.Unmarshal(input, &job); err != nil {
				t.Fatal(err)
			}
			submitted = append(submitted, job)
			return []byte(`{}`), nil
		case slices.Contains(args, "wait"), slices.Contains(args, "logs"):
			return []byte("ok"), nil
		default:
			t.Fatalf("unexpected command: %v", args)
			return nil, nil
		}
	})
	if err := p.PublishRuntimeRelease(context.Background(), state); err == nil || len(submitted) != 0 {
		t.Fatalf("publication before core success: jobs=%d err=%v", len(submitted), err)
	}
	state.Phase = PhaseSucceeded
	for range 2 {
		if err := p.PublishRuntimeRelease(context.Background(), state); err != nil {
			t.Fatal(err)
		}
	}
	for _, job := range submitted {
		spec := job["spec"].(map[string]any)["template"].(map[string]any)["spec"].(map[string]any)
		container := spec["containers"].([]any)[0].(map[string]any)
		if container["image"] != state.Image {
			t.Fatalf("wrong image: %v", container["image"])
		}
		values := map[string]any{}
		for _, raw := range container["env"].([]any) {
			env := raw.(map[string]any)
			values[env["name"].(string)] = env["value"]
		}
		if values["COMMA_RUNTIME_RELEASE_ID"] != state.ReleaseID || values["COMMA_RUNTIME_HELM_REVISION"] != "42" {
			t.Fatal("publication omitted the successful release scope")
		}
	}
	if submitted[0]["metadata"].(map[string]any)["name"] == submitted[1]["metadata"].(map[string]any)["name"] {
		t.Fatal("retry reused a possibly failed executor")
	}
}

func TestRuntimeReleaseJobNameFitsKubernetesGeneratedPodFields(t *testing.T) {
	name := runtimeReleaseJobName("gha-36392678649-1", 1790581623051824874)
	if len(name) > 63 {
		t.Fatalf("runtime release Job name has %d characters; generated Pod labels and container names allow 63: %s", len(name), name)
	}
}
