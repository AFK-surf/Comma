package release

import (
	"context"
	"encoding/json"
	"errors"
	"strings"
	"testing"
	"time"
)

func TestMaintenanceDrainProtectsServingAndReplacementPods(t *testing.T) {
	for _, scenario := range []string{"graceful", "already deleting", "not found", "release replaced", "serving resumed", "missing replicas", "foreign owner", "missing pod UID", "pod replaced"} {
		t.Run(scenario, func(t *testing.T) {
			state := NewState("test", "drain", "image", 1, time.Unix(1, 0))
			state.RequiredMode, state.Phase = ModeExclusive, PhaseQuiescing
			reads, deletes := 0, 0
			p := KubectlPlatform{Spec: EnvironmentSpec{Namespace: "test"}}
			p.Kubectl = runnerFunc(func(_ context.Context, input []byte, args ...string) ([]byte, error) {
				command := strings.Join(args, " ")
				switch {
				case strings.Contains(command, "get pods -l app.kubernetes.io/name=comma"):
					return []byte(`{"items":[{"metadata":{"name":"comma-0"}},{"metadata":{"name":"comma-1"}},{"metadata":{"name":"comma-2"}}]}`), nil
				case strings.Contains(command, "get configmap comma-release-state"):
					reads++
					active := state
					if scenario == "release replaced" && reads == 2 {
						active.ReleaseID = "successor"
					}
					body, _ := json.Marshal(active)
					return json.Marshal(configMap{Data: map[string]string{"state.json": string(body)}})
				case strings.Contains(command, "get statefulset/comma"):
					if scenario == "missing replicas" {
						return []byte(`{"metadata":{"uid":"controller"},"spec":{}}`), nil
					}
					replicas := 0
					if scenario == "serving resumed" && reads == 2 {
						replicas = 2
					}
					return json.Marshal(map[string]any{"metadata": map[string]string{"uid": "controller"}, "spec": map[string]int{"replicas": replicas}})
				case strings.Contains(command, "get pod/comma-"):
					if scenario == "not found" {
						return nil, errors.New("NotFound")
					}
					owner := "controller"
					if scenario == "foreign owner" {
						owner = "other-controller"
					}
					metadata := map[string]any{"uid": "old-pod", "ownerReferences": []any{map[string]any{"uid": owner, "kind": "StatefulSet", "controller": true}}}
					if scenario == "missing pod UID" {
						delete(metadata, "uid")
					}
					if scenario == "already deleting" {
						metadata["deletionTimestamp"] = "2026-10-30T00:00:00Z"
					}
					return json.Marshal(map[string]any{"metadata": metadata})
				case strings.HasPrefix(command, "delete --raw /api/v1/namespaces/test/pods/comma-"):
					deletes++
					var options struct {
						GracePeriodSeconds *int              `json:"gracePeriodSeconds"`
						Preconditions      map[string]string `json:"preconditions"`
					}
					if err := json.Unmarshal(input, &options); err != nil || options.GracePeriodSeconds != nil || options.Preconditions["uid"] != "old-pod" {
						t.Fatalf("delete lost normal grace or the observed Pod identity: %s, %v", input, err)
					}
					if scenario == "pod replaced" {
						return nil, errors.New("Conflict: UID precondition failed")
					}
					return nil, nil
				default:
					t.Fatalf("unexpected command: %s", command)
					return nil, nil
				}
			})
			err := p.stopMaintenancePods(context.Background(), state)
			wantDeletes, wantError := 0, true
			switch scenario {
			case "graceful":
				wantDeletes, wantError = 3, false
			case "already deleting", "not found", "foreign owner":
				wantError = false
			case "release replaced", "serving resumed", "pod replaced":
				wantDeletes = 1
			}
			if (err != nil) != wantError || deletes != wantDeletes {
				t.Fatalf("drain error = %v, delete requests = %d; want error %v, requests %d", err, deletes, wantError, wantDeletes)
			}
		})
	}
}
