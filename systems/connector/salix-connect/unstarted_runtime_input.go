package main

import (
	"context"
	"errors"
	"time"

	bolt "go.etcd.io/bbolt"
)

// Codex and Claude persist their native binding before submitting user input.
// Keep an unstarted claim's execution authority and retry its exact durable
// batch only after Host recovery; there is no native delivery to Restore yet.
func unstartedRuntimeInput(execution externalRuntimeActiveExecution) bool {
	return missingNativeInputBinding(execution.Session) &&
		inputClaimIsBound(execution) && execution.Phase != externalRuntimeExecutionSettling
}

func missingNativeInputBinding(record externalRuntimeRecoveryRecord) bool {
	switch record.Provider {
	case "codex":
		return stringParam(record.Payload, "thread_id") == ""
	case "claude":
		return stringParam(record.Payload, "session_id") == ""
	default:
		return false
	}
}

func (s *externalRuntimeState) retryUnstartedRuntimeInput(ctx context.Context, record externalRuntimeRecoveryRecord) (bool, error) {
	if !missingNativeInputBinding(record) {
		return false, nil
	}
	key := record.key()
	// Share the delivery fence with the inbox worker. A sampled health record
	// must not submit again while the original Send is still in progress.
	if _, busy := s.inputCalls.LoadOrStore(key, struct{}{}); busy {
		return true, nil
	}
	defer s.inputCalls.Delete(key)
	s.mu.Lock()
	execution, exists := s.activeExecutions[key]
	if !exists || execution.Session.ExecutionID != record.ExecutionID {
		s.mu.Unlock()
		return true, nil
	}
	if !unstartedRuntimeInput(execution) {
		s.mu.Unlock()
		// Keep Claude's existing no-op behavior. Codex Check reports a
		// missing original batch without blocking unrelated Sessions.
		return record.Provider != "codex", nil
	}
	// Legacy records can recover their original input on a direct Connector,
	// but carry no saved Host target against which new input can be authorized.
	if record.Provider == "codex" && s.connector.requiresHostRuntimeExecution() && execution.Version != 3 {
		s.mu.Unlock()
		return true, errors.New("unstarted runtime input has no saved Host execution authority")
	}
	var batches []externalRuntimeInputBatch
	err := s.db.View(func(tx *bolt.Tx) error {
		for _, id := range execution.InputBatchIDs {
			rowKey := []byte(key + "\x00" + id)
			raw := tx.Bucket(externalRuntimeInputBatchesBucket).Get(rowKey)
			if raw == nil {
				return errors.New("unstarted runtime input is missing its durable batch")
			}
			batch, err := decodeExternalRuntimeInputBatch(rowKey, raw)
			if err != nil {
				return err
			}
			if batch.Session.Token != record.Token {
				return errors.New("unstarted runtime input capability changed")
			}
			batches = append(batches, batch)
		}
		return nil
	})
	s.mu.Unlock()
	if err != nil {
		return true, err
	}
	input := s.inputForBatches(batches)
	input.executionID = record.ExecutionID
	if err := prepareExternalRuntimeWorkspace(input.workspace); err != nil {
		return true, err
	}
	if notice := s.connector.peekWorkspaceRuntimeNotice(record.SessionID); notice != "" {
		input.messages = append(input.messages, map[string]any{"role": "runtime", "content": notice})
	}
	input.messages, err = input.agentBatchMessages(time.Now())
	if err != nil {
		return true, err
	}
	_, _, err = s.connector.runtimeImplementations[record.Provider].Send(ctx, input)
	if err != nil {
		return true, err
	}
	s.connector.clearWorkspaceRuntimeNotice(record.SessionID)
	if err := s.markExecutionRecovered(record.Provider, record.SessionID, record.Token); err != nil {
		return true, err
	}
	if err := s.acceptInputClaim(record.Provider, input); err != nil {
		return true, err
	}
	s.wake()
	return true, nil
}
