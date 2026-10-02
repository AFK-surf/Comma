package main

import (
	"context"
	"errors"
	"fmt"
	"time"

	bolt "go.etcd.io/bbolt"
)

// Stop addresses current execution only. Agent admission is owned by Salix.
// The stop and quiet regressions cover the current implementation boundary.
var errRuntimeStopBusy = errors.New("external session stop is pending")
var errRuntimeNotQuiet = errors.New("external runtime still owns work")

const externalRuntimeQuietPageSize = 32

func appendRuntimeSessionID(order *[]string, index *map[string]int, id string) {
	if *index == nil {
		*index = make(map[string]int, len(*order)+1)
		for position, existing := range *order {
			(*index)[existing] = position
		}
	}
	(*index)[id] = len(*order)
	*order = append(*order, id)
}

func removeRuntimeSessionID(order *[]string, index *map[string]int, id string) {
	if *index == nil {
		*index = make(map[string]int, len(*order))
		for position, existing := range *order {
			(*index)[existing] = position
		}
	}
	position, ok := (*index)[id]
	if !ok {
		return
	}
	last := len(*order) - 1
	lastID := (*order)[last]
	(*order)[position] = lastID
	(*index)[lastID] = position
	*order = (*order)[:last]
	delete(*index, id)
}

func quietSessionPage[T any](sessions map[string]T, order []string, selected string, offset int) ([]string, int) {
	if selected != "" {
		if offset != 0 {
			return nil, 0
		}
		if _, ok := sessions[selected]; ok {
			return []string{selected}, 1
		}
		return nil, 0
	}
	if offset >= len(order) {
		return nil, len(order)
	}
	end := min(offset+externalRuntimeQuietPageSize, len(order))
	return append([]string(nil), order[offset:end]...), len(order)
}

type externalRuntimeStopper interface {
	Stop(context.Context, string) error
}

type externalRuntimeQuietChecker interface {
	Quiet(context.Context) error
}

func (c *connector) methodAgentRuntimeQuiet(ctx context.Context, params map[string]any) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	provider := stringParam(params, "provider")
	implementation, ok := c.runtimeImplementations[provider].(externalRuntimeQuietChecker)
	if !ok {
		return nil, errors.New("unsupported external runtime quiet target")
	}
	operationRights := len(c.runtimeOperations.snapshot())
	_, active, inputs, events := c.externalRuntimeState.healthCounts()
	if operationRights != 0 || active != 0 || inputs != 0 || events != 0 {
		return nil, errRuntimeNotQuiet
	}
	if err := implementation.Quiet(ctx); err != nil {
		return nil, err
	}
	return map[string]any{"quiet": true}, nil
}

func (c *connector) methodAgentRuntimeStop(ctx context.Context, params map[string]any) (map[string]any, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	provider, sessionID := stringParam(params, "provider"), stringParam(params, "session_id")
	implementation, ok := c.runtimeImplementations[provider].(externalRuntimeStopper)
	if !ok || !canonicalExternalRuntimeSessionID.MatchString(sessionID) {
		return nil, errors.New("unsupported external session stop target")
	}
	if err := implementation.Stop(ctx, sessionID); err != nil {
		return nil, err
	}
	return map[string]any{"stopped": true}, nil
}

// Retire only the execution sampled under the provider's input lock. A newer
// durable input may already own this Session; its recovery must survive a late
// stop. This uses the existing execution/batch records and preserves identity
// and native history. There is no permanent stop marker.
func (s *externalRuntimeState) retireStoppedExecution(record externalRuntimeRecoveryRecord) error {
	if s.db == nil {
		return errExternalRuntimeStateDisabled
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := record.key()
	current, exists := s.activeExecutions[key]
	if !exists || current.Session.DispatchID != record.DispatchID || current.Session.ExecutionID != record.ExecutionID {
		return nil
	}
	if err := s.db.Update(func(tx *bolt.Tx) error {
		if inputClaimIsBound(current) {
			if err := deleteRuntimeInputBatchRows(tx, key, current.Session.Token, current.InputBatchIDs); err != nil {
				return err
			}
		}
		return tx.Bucket(externalRuntimeActiveExecutionsBucket).Delete([]byte(key))
	}); err != nil {
		return err
	}
	s.deleteActiveExecutionLocked(key)
	s.wakeMetadataPublish()
	return nil
}

func (i *piRuntimeImplementation) Stop(ctx context.Context, sessionID string) error {
	i.activityMu.Lock()
	i.activityRevision.Add(1)
	defer i.activityMu.Unlock()
	i.mu.Lock()
	slot := i.sessions[sessionID]
	i.mu.Unlock()
	if slot == nil {
		if i.connector.externalRuntimeState.watched("pi", sessionID) {
			return errors.New("native stop cannot be confirmed after recovery")
		}
		return nil
	}
	if !slot.mu.TryLock() {
		return errRuntimeStopBusy
	}
	defer slot.mu.Unlock()
	if slot.session == nil {
		if i.connector.externalRuntimeState.watched("pi", sessionID) {
			return errors.New("native stop cannot be confirmed after recovery")
		}
		return nil
	}
	record := externalRuntimeRecoveryRecordFromInput("pi", slot.recoveryInput)
	slot.session.markAbandoned()
	if err := stopExternalRuntime(ctx, slot.session.stop, slot.session.done); err != nil {
		return err
	}
	if err := i.connector.externalRuntimeState.retireStoppedExecution(record); err != nil {
		return err
	}
	slot.session = nil
	slot.recoveryInput = externalRuntimeInput{}
	i.mu.Lock()
	if i.sessions[sessionID] == slot {
		delete(i.sessions, sessionID)
		removeRuntimeSessionID(&i.sessionOrder, &i.sessionIndex, sessionID)
	}
	i.mu.Unlock()
	return nil
}

func (i *piRuntimeImplementation) Quiet(ctx context.Context) error {
	return i.quietSessions(ctx, "")
}

func (i *piRuntimeImplementation) quietSessions(ctx context.Context, selected string) error {
	activityRevision := i.activityRevision.Load()
	for offset := 0; ; {
		i.mu.Lock()
		ids, total := quietSessionPage(i.sessions, i.sessionOrder, selected, offset)
		i.mu.Unlock()
		if len(ids) == 0 {
			break
		}
		locked := make([]*piRuntimeSlot, 0, len(ids))
		for _, id := range ids {
			i.mu.Lock()
			slot := i.sessions[id]
			i.mu.Unlock()
			if slot == nil || !slot.mu.TryLock() {
				for _, held := range locked {
					held.mu.Unlock()
				}
				return errRuntimeNotQuiet
			}
			locked = append(locked, slot)
		}
		for _, slot := range locked {
			session := slot.session
			if session != nil {
				session.mu.Lock()
				busy := session.workState == "starting" || session.workState == "running"
				session.mu.Unlock()
				if busy {
					for _, held := range locked {
						held.mu.Unlock()
					}
					return errRuntimeNotQuiet
				}
			}
		}
		for _, held := range locked {
			held.mu.Unlock()
		}
		offset += len(ids)
		if offset >= total {
			break
		}
	}
	if err := lockRuntimeContext(ctx, &i.activityMu); err != nil {
		return err
	}
	defer i.activityMu.Unlock()
	if i.activityRevision.Load() != activityRevision {
		return errRuntimeNotQuiet
	}
	for {
		i.mu.Lock()
		ids, _ := quietSessionPage(i.sessions, i.sessionOrder, selected, 0)
		i.mu.Unlock()
		if len(ids) == 0 {
			break
		}
		for _, id := range ids {
			i.mu.Lock()
			slot := i.sessions[id]
			i.mu.Unlock()
			if slot == nil {
				return errRuntimeNotQuiet
			}
			if err := lockRuntimeContext(ctx, &slot.mu); err != nil {
				return err
			}
			session := slot.session
			if session != nil {
				session.markAbandoned()
				if err := stopExternalRuntime(ctx, session.stop, session.done); err != nil {
					slot.mu.Unlock()
					return err
				}
				slot.session = nil
				slot.recoveryInput = externalRuntimeInput{}
			}
			slot.mu.Unlock()
			i.mu.Lock()
			if i.sessions[id] == slot {
				delete(i.sessions, id)
				removeRuntimeSessionID(&i.sessionOrder, &i.sessionIndex, id)
			}
			i.mu.Unlock()
		}
		if selected != "" {
			break
		}
	}
	return nil
}

func (i *claudeRuntimeImplementation) Stop(ctx context.Context, sessionID string) error {
	i.activityMu.Lock()
	i.activityRevision.Add(1)
	defer i.activityMu.Unlock()
	i.mu.Lock()
	slot := i.sessions[sessionID]
	i.mu.Unlock()
	if slot == nil {
		if i.connector.externalRuntimeState.watched("claude", sessionID) {
			return errors.New("native stop cannot be confirmed after recovery")
		}
		return nil
	}
	if !slot.mu.TryLock() {
		return errRuntimeStopBusy
	}
	defer slot.mu.Unlock()
	if slot.session == nil {
		if i.connector.externalRuntimeState.watched("claude", sessionID) {
			return errors.New("native stop cannot be confirmed after recovery")
		}
		return nil
	}
	record := externalRuntimeRecoveryRecordFromInput("claude", slot.recoveryInput)
	slot.session.markAbandoned()
	if err := stopExternalRuntime(ctx, slot.session.stop, slot.session.done); err != nil {
		return err
	}
	if err := i.connector.externalRuntimeState.retireStoppedExecution(record); err != nil {
		return err
	}
	slot.session = nil
	slot.recoveryInput = externalRuntimeInput{}
	i.mu.Lock()
	if i.sessions[sessionID] == slot {
		delete(i.sessions, sessionID)
		removeRuntimeSessionID(&i.sessionOrder, &i.sessionIndex, sessionID)
	}
	i.mu.Unlock()
	return nil
}

func (i *claudeRuntimeImplementation) Quiet(ctx context.Context) error {
	return i.quietSessions(ctx, "")
}

func (i *claudeRuntimeImplementation) quietSessions(ctx context.Context, selected string) error {
	activityRevision := i.activityRevision.Load()
	for offset := 0; ; {
		i.mu.Lock()
		ids, total := quietSessionPage(i.sessions, i.sessionOrder, selected, offset)
		i.mu.Unlock()
		if len(ids) == 0 {
			break
		}
		locked := make([]*claudeRuntimeSlot, 0, len(ids))
		for _, id := range ids {
			i.mu.Lock()
			slot := i.sessions[id]
			i.mu.Unlock()
			if slot == nil || !slot.mu.TryLock() {
				for _, held := range locked {
					held.mu.Unlock()
				}
				return errRuntimeNotQuiet
			}
			locked = append(locked, slot)
		}
		for _, slot := range locked {
			session := slot.session
			if session != nil {
				session.mu.Lock()
				busy := session.workState == "starting" || session.workState == "running" || session.steering || session.backgroundWork
				session.mu.Unlock()
				if busy {
					for _, held := range locked {
						held.mu.Unlock()
					}
					return errRuntimeNotQuiet
				}
			}
		}
		for _, held := range locked {
			held.mu.Unlock()
		}
		offset += len(ids)
		if offset >= total {
			break
		}
	}
	if err := lockRuntimeContext(ctx, &i.activityMu); err != nil {
		return err
	}
	defer i.activityMu.Unlock()
	if i.activityRevision.Load() != activityRevision {
		return errRuntimeNotQuiet
	}
	for {
		i.mu.Lock()
		ids, _ := quietSessionPage(i.sessions, i.sessionOrder, selected, 0)
		i.mu.Unlock()
		if len(ids) == 0 {
			break
		}
		locked := make([]*claudeRuntimeSlot, 0, len(ids))
		for _, id := range ids {
			i.mu.Lock()
			slot := i.sessions[id]
			i.mu.Unlock()
			if slot == nil || !slot.mu.TryLock() {
				for _, held := range locked {
					held.mu.Unlock()
				}
				return errRuntimeNotQuiet
			}
			locked = append(locked, slot)
		}
		err := checkNativeQuietPage(ctx, locked, func(ctx context.Context, slot *claudeRuntimeSlot) error {
			session := slot.session
			if session != nil {
				session.markAbandoned()
				if err := session.drain(ctx); err != nil {
					return err
				}
			}
			return nil
		})
		if err != nil {
			for _, held := range locked {
				held.mu.Unlock()
			}
			return err
		}
		for index, id := range ids {
			slot := locked[index]
			slot.session = nil
			slot.recoveryInput = externalRuntimeInput{}
			slot.mu.Unlock()
			i.mu.Lock()
			if i.sessions[id] == slot {
				delete(i.sessions, id)
				removeRuntimeSessionID(&i.sessionOrder, &i.sessionIndex, id)
			}
			i.mu.Unlock()
		}
		if selected != "" {
			break
		}
	}
	return nil
}

func (i *kimiRuntimeImplementation) Stop(ctx context.Context, sessionID string) error {
	i.activityMu.Lock()
	defer i.activityMu.Unlock()
	i.mu.Lock()
	slot := i.sessions[sessionID]
	i.mu.Unlock()
	if slot == nil {
		if i.connector.externalRuntimeState.watched("kimi", sessionID) {
			return errors.New("native stop cannot be confirmed after recovery")
		}
		return nil
	}
	if !slot.mu.TryLock() {
		return errRuntimeStopBusy
	}
	defer slot.mu.Unlock()
	if slot.session == nil {
		if i.connector.externalRuntimeState.watched("kimi", sessionID) {
			return errors.New("native stop cannot be confirmed after recovery")
		}
		return nil
	}
	record := externalRuntimeRecoveryRecordFromInput("kimi", slot.recoveryInput)
	slot.session.markAbandoned()
	if err := stopExternalRuntime(ctx, slot.session.stop, slot.session.done); err != nil {
		return err
	}
	if err := i.connector.externalRuntimeState.retireStoppedExecution(record); err != nil {
		return err
	}
	slot.session = nil
	slot.recoveryInput = externalRuntimeInput{}
	i.mu.Lock()
	if i.sessions[sessionID] == slot {
		delete(i.sessions, sessionID)
	}
	i.mu.Unlock()
	return nil
}

func (i *codexRuntimeImplementation) Stop(ctx context.Context, sessionID string) error {
	i.activityMu.Lock()
	i.activityRevision.Add(1)
	defer i.activityMu.Unlock()
	i.mu.Lock()
	session := i.sessions[sessionID]
	i.mu.Unlock()
	if session == nil {
		if i.connector.externalRuntimeState.watched("codex", sessionID) {
			return errors.New("native Codex stop cannot be confirmed after recovery")
		}
		return nil
	}
	if !session.inputMu.TryLock() {
		return errRuntimeStopBusy
	}
	defer session.inputMu.Unlock()
	session.mu.Lock()
	runtime, threadID, turnID := session.runtime, session.threadID, session.activeTurnID
	record := externalRuntimeRecoveryRecordFromInput("codex", session.recoveryInput)
	active := session.workState == "starting" || session.workState == "running" || session.recoveryPending
	if runtime == nil || threadID == "" || (active && turnID == "") {
		session.mu.Unlock()
		return errors.New("native Codex stop cannot be confirmed")
	}
	if active {
		done := make(chan struct{})
		session.stopDone = done
		session.mu.Unlock()
		// The app-server is shared. Interrupt only this turn and await its
		// terminal event before cleaning this thread's background terminals.
		_, err := runtime.rpc(ctx, "turn/interrupt", map[string]any{"threadId": threadID, "turnId": turnID}, 5*time.Second)
		if err != nil {
			select {
			case <-runtime.exited:
			default:
				return err
			}
		}
		select {
		case <-done:
		case <-runtime.exited:
		case <-ctx.Done():
			return ctx.Err()
		}
	} else {
		session.mu.Unlock()
	}
	// A completed/interrupted turn can still own running command terminals.
	// Native thread cleanup is required even for an already settled turn and
	// must succeed before retiring recovery or acknowledging stop.
	if _, err := runtime.rpc(ctx, "thread/backgroundTerminals/clean", map[string]any{"threadId": threadID}, 5*time.Second); err != nil {
		return fmt.Errorf("native Codex background terminals were not confirmed stopped; retry with a Codex version supporting thread/backgroundTerminals/clean: %w", err)
	}
	if err := i.retireStoppedSession(session, record); err != nil {
		return err
	}
	i.mu.Lock()
	if i.sessions[sessionID] == session {
		delete(i.sessions, sessionID)
		removeRuntimeSessionID(&i.sessionOrder, &i.sessionIndex, sessionID)
		if i.threads[threadID] == sessionID {
			delete(i.threads, threadID)
		}
	}
	i.mu.Unlock()
	return nil
}

func (i *codexRuntimeImplementation) Quiet(ctx context.Context) error {
	return i.quietSessions(ctx, "")
}

func (i *codexRuntimeImplementation) quietSessions(ctx context.Context, selected string) error {
	activityRevision := i.activityRevision.Load()
	for offset := 0; ; {
		i.mu.Lock()
		ids, total := quietSessionPage(i.sessions, i.sessionOrder, selected, offset)
		i.mu.Unlock()
		if len(ids) == 0 {
			break
		}
		locked := make([]*codexRuntimeSession, 0, len(ids))
		for _, id := range ids {
			i.mu.Lock()
			session := i.sessions[id]
			i.mu.Unlock()
			if session == nil || !session.inputMu.TryLock() {
				for _, held := range locked {
					held.inputMu.Unlock()
				}
				return errRuntimeNotQuiet
			}
			locked = append(locked, session)
		}
		err := checkNativeQuietPage(ctx, locked, func(ctx context.Context, session *codexRuntimeSession) error {
			session.mu.Lock()
			runtime, threadID := session.runtime, session.threadID
			busy := session.workState == "starting" || session.workState == "running" || session.recoveryPending || session.persistencePending
			session.mu.Unlock()
			if busy {
				return errRuntimeNotQuiet
			}
			if runtime != nil && threadID != "" {
				result, err := runtime.rpc(ctx, "thread/backgroundTerminals/list", map[string]any{"threadId": threadID, "limit": 1}, 5*time.Second)
				if err != nil {
					return fmt.Errorf("native Codex background terminals could not be inspected: %w", err)
				}
				terminals, ok := result["data"].([]any)
				if !ok || len(terminals) != 0 {
					if !ok {
						return errors.New("native Codex background terminal response is invalid")
					}
					return errRuntimeNotQuiet
				}
			}
			return nil
		})
		for _, held := range locked {
			held.inputMu.Unlock()
		}
		if err != nil {
			return err
		}
		offset += len(ids)
		if offset >= total {
			break
		}
	}
	if err := lockRuntimeContext(ctx, &i.activityMu); err != nil {
		return err
	}
	defer i.activityMu.Unlock()
	if i.activityRevision.Load() != activityRevision {
		return errRuntimeNotQuiet
	}
	for {
		i.mu.Lock()
		ids, _ := quietSessionPage(i.sessions, i.sessionOrder, selected, 0)
		i.mu.Unlock()
		if len(ids) == 0 {
			break
		}
		for _, id := range ids {
			i.mu.Lock()
			session := i.sessions[id]
			i.mu.Unlock()
			if session == nil {
				return errRuntimeNotQuiet
			}
			if err := lockRuntimeContext(ctx, &session.inputMu); err != nil {
				return err
			}
			session.mu.Lock()
			record := externalRuntimeRecoveryRecordFromInput("codex", session.recoveryInput)
			session.mu.Unlock()
			if err := i.retireStoppedSession(session, record); err != nil {
				session.inputMu.Unlock()
				return err
			}
			session.mu.Lock()
			threadID := session.threadID
			session.mu.Unlock()
			session.inputMu.Unlock()
			i.mu.Lock()
			if i.sessions[id] == session {
				delete(i.sessions, id)
				removeRuntimeSessionID(&i.sessionOrder, &i.sessionIndex, id)
				if i.threads[threadID] == id {
					delete(i.threads, threadID)
				}
			}
			i.mu.Unlock()
		}
		if selected != "" {
			break
		}
	}
	return nil
}

// The caller holds inputMu, so no later Send can rewrite this native Session.
func (i *codexRuntimeImplementation) retireStoppedSession(session *codexRuntimeSession, record externalRuntimeRecoveryRecord) error {
	if err := i.connector.externalRuntimeState.retireStoppedExecution(record); err != nil {
		return err
	}
	session.mu.Lock()
	session.recoveryPending = false
	session.persistencePending = false
	session.recoveryInput = externalRuntimeInput{}
	session.mu.Unlock()
	return nil
}
