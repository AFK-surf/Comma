package release

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

type repairStatefulSet struct {
	Metadata struct {
		UID        string
		Generation int64
	}
	Spec struct {
		Replicas int
		Template struct {
			Spec struct {
				Containers []struct{ Name, Image string }
			}
		}
		UpdateStrategy struct{ RollingUpdate struct{ Partition int } }
	}
	Status struct {
		ObservedGeneration int64
		UpdateRevision     string
	}
}

type repairPod struct {
	Metadata struct {
		UID, ResourceVersion string
		DeletionTimestamp    *string
		Labels               map[string]string
		OwnerReferences      []struct {
			UID, Kind  string
			Controller bool
		}
	}
	Status struct {
		Conditions []struct{ Type, Status string }
	}
}

// OrderedReady can retain an unready old Pod after its template is repaired.
// Delete only that observed Pod, gracefully, without deleting its successor.
func (p KubectlPlatform) repairUnreadyPods(ctx context.Context, state State) error {
	var target repairStatefulSet
	readSet := func() (repairStatefulSet, error) {
		var set repairStatefulSet
		body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "statefulset/comma", "-o", "json")
		if err == nil {
			err = json.Unmarshal(body, &set)
		}
		return set, err
	}
	for {
		set, err := readSet()
		if err != nil {
			return err
		}
		imageMatches := false
		for _, container := range set.Spec.Template.Spec.Containers {
			if container.Name == "comma" && container.Image == state.Image {
				imageMatches = true
			}
		}
		if !imageMatches || set.Spec.UpdateStrategy.RollingUpdate.Partition != 0 {
			return errors.New("repair StatefulSet template differs from candidate")
		}
		if set.Status.ObservedGeneration >= set.Metadata.Generation && set.Status.UpdateRevision != "" {
			target = set
			break
		}
		if err = repairPause(ctx); err != nil {
			return err
		}
	}
	for ordinal := 0; ordinal < target.Spec.Replicas; ordinal++ {
		name := fmt.Sprintf("comma-%d", ordinal)
		for {
			if err := ctx.Err(); err != nil {
				return fmt.Errorf("repair waiting for %s: %w", name, err)
			}
			set, err := readSet()
			if err != nil {
				return err
			}
			if set.Metadata.UID != target.Metadata.UID || set.Metadata.Generation != target.Metadata.Generation || set.Status.UpdateRevision != target.Status.UpdateRevision {
				return errors.New("repair StatefulSet changed during replacement")
			}
			body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "pod/"+name, "-o", "json")
			if err != nil {
				if !containsNotFound(err.Error()) {
					return err
				}
				if err = repairPause(ctx); err != nil {
					return err
				}
				continue
			}
			var pod repairPod
			if err = json.Unmarshal(body, &pod); err != nil {
				return err
			}
			owned := false
			for _, owner := range pod.Metadata.OwnerReferences {
				if owner.Controller && owner.Kind == "StatefulSet" && owner.UID == target.Metadata.UID {
					owned = true
				}
			}
			if !owned {
				return errors.New("repair Pod does not belong to the StatefulSet")
			}
			ready := false
			for _, condition := range pod.Status.Conditions {
				if condition.Type == "Ready" && condition.Status == "True" {
					ready = true
				}
			}
			if ready {
				break
			}
			if pod.Metadata.DeletionTimestamp == nil && pod.Metadata.Labels["controller-revision-hash"] != target.Status.UpdateRevision {
				active, err := (KubectlStore{Runner: p.Kubectl, Namespace: p.Spec.Namespace}).Load(ctx)
				if err != nil {
					return err
				}
				if active.State.ReleaseID != state.ReleaseID || active.State.Phase != PhaseApplying || active.State.Image != state.Image || active.State.RepairFrom != state.RepairFrom {
					return errors.New("repair release no longer owns Pod replacement")
				}
				options, _ := json.Marshal(map[string]any{"apiVersion": "v1", "kind": "DeleteOptions", "preconditions": map[string]string{"uid": pod.Metadata.UID, "resourceVersion": pod.Metadata.ResourceVersion}})
				_, err = p.Kubectl.Run(ctx, options, "delete", "--raw", "/api/v1/namespaces/"+p.Spec.Namespace+"/pods/"+name, "-f", "-")
				if err != nil && !containsConflict(err.Error()) && !containsNotFound(err.Error()) {
					return err
				}
			}
			if err = repairPause(ctx); err != nil {
				return err
			}
		}
	}
	return nil
}

func repairPause(ctx context.Context) error {
	timer := time.NewTimer(500 * time.Millisecond)
	defer timer.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-timer.C:
		return nil
	}
}
