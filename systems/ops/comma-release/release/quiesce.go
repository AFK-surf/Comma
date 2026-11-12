package release

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
)

// Maintenance sets replicas to zero before existing writers drain.
// Keep each Pod's grace period and wait for writer absence before migration.
func (p KubectlPlatform) stopMaintenancePods(ctx context.Context, state State) error {
	body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "pods", "-l", "app.kubernetes.io/name=comma", "-o", "json")
	if err != nil {
		return err
	}
	var pods struct {
		Items []struct{ Metadata struct{ Name string } }
	}
	if err := json.Unmarshal(body, &pods); err != nil {
		return err
	}
	for _, item := range pods.Items {
		name := item.Metadata.Name
		active, err := (KubectlStore{Runner: p.Kubectl, Namespace: p.Spec.Namespace}).Load(ctx)
		if err != nil {
			return err
		}
		if active.State.ReleaseID != state.ReleaseID || active.State.Image != state.Image ||
			active.State.Phase != PhaseQuiescing || !active.State.RequiresExclusiveDeployment() {
			return errors.New("release no longer owns the maintenance drain")
		}
		body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "statefulset/comma", "-o", "json")
		if err != nil {
			return err
		}
		var set struct {
			Metadata struct{ UID string }
			Spec     struct{ Replicas *int }
		}
		if err = json.Unmarshal(body, &set); err != nil {
			return err
		}
		if set.Metadata.UID == "" || set.Spec.Replicas == nil || *set.Spec.Replicas != 0 {
			return errors.New("maintenance drain requires zero desired replicas")
		}
		body, err = p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "pod/"+name, "-o", "json")
		if err != nil {
			if containsNotFound(err.Error()) {
				continue
			}
			return err
		}
		var pod repairPod
		if err = json.Unmarshal(body, &pod); err != nil {
			return err
		}
		owned := false
		for _, owner := range pod.Metadata.OwnerReferences {
			if owner.Controller && owner.Kind == "StatefulSet" && owner.UID == set.Metadata.UID {
				owned = true
			}
		}
		if !owned {
			continue
		}
		if pod.Metadata.UID == "" {
			return fmt.Errorf("maintenance Pod %s has no UID", name)
		}
		if pod.Metadata.DeletionTimestamp != nil {
			continue
		}
		options, _ := json.Marshal(map[string]any{"apiVersion": "v1", "kind": "DeleteOptions",
			"preconditions": map[string]string{"uid": pod.Metadata.UID}})
		_, err = p.Kubectl.Run(ctx, options, "delete", "--raw", "/api/v1/namespaces/"+p.Spec.Namespace+"/pods/"+name, "-f", "-")
		if err != nil && !containsNotFound(err.Error()) {
			return err
		}
	}
	return nil
}
