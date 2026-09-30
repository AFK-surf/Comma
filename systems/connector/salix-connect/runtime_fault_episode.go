package main

import (
	"encoding/json"

	bolt "go.etcd.io/bbolt"
)

type runtimeFaultEpisode struct {
	ID        string `json:"id"`
	StartedAt int64  `json:"started_at"`
	Priority  string `json:"priority"`
	Recovered bool   `json:"recovered"`
}

// stampRuntimeFault runs inside the existing lifecycle/outbox transaction.
// Each receipt describes its exact fault, even if storage delivery is reordered
// or an older log segment is backfilled later. There is no external alert call.
// Models: RuntimeEpisode.Produce and RuntimeRecoveryReceipt.Recover.
func stampRuntimeFault(tx *bolt.Tx, event map[string]any, id string) error {
	dispatch, execution := stringParam(event, "dispatch_id"), stringParam(event, "execution_id")
	failed := stringParam(event, "work_state") == "failed" &&
		(stringParam(event, "issue") == "runtime_failed" || stringParam(event, "issue") == "recovery_exhausted")
	recovered := stringParam(event, "name") == "runtime_recovered" && stringParam(event, "state") == "recovered"
	// Do not accept caller-provided fault ownership.
	delete(event, "fault_episode_id")
	delete(event, "fault_started_at")
	delete(event, "fault_priority")
	if dispatch == "" || execution == "" || (!failed && !recovered) {
		return nil
	}
	bucket := tx.Bucket(externalRuntimeFaultEpisodesBucket)
	key := []byte(stringParam(event, "provider") + "\x00" + dispatch + "\x00" + execution)
	var episode runtimeFaultEpisode
	if raw := bucket.Get(key); raw != nil {
		if err := json.Unmarshal(raw, &episode); err != nil {
			return err
		}
	}
	if failed {
		if episode.ID == "" || episode.Recovered {
			episode = runtimeFaultEpisode{ID: id, StartedAt: int64Param(event, "created_at", 0), Priority: "P1"}
		}
		if stringParam(event, "issue") == "recovery_exhausted" {
			episode.Priority = "P0"
		}
	} else {
		// An old Connector may have no correlated failure. Never guess one.
		if episode.ID == "" {
			return nil
		}
		episode.Recovered = true
	}
	event["fault_episode_id"], event["fault_started_at"], event["fault_priority"] = episode.ID, episode.StartedAt, episode.Priority
	raw, err := json.Marshal(episode)
	if err != nil {
		return err
	}
	return bucket.Put(key, raw)
}
