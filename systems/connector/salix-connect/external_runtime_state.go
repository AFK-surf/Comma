package main

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/oklog/ulid/v2"
	bolt "go.etcd.io/bbolt"
)

const externalRuntimeEventBatchMaxItems = 64
const externalRuntimeEventBatchMaxBytes = 8 * 1024 * 1024
const externalRuntimeEventMaxBytes = 64 * 1024
const externalRuntimeEventContentMaxBytes = 16 * 1024
const externalRuntimeEventDetailMaxBytes = 4 * 1024
const migratedExternalRuntimeEventLegacyKey = "_connector_migrated_legacy"
const externalRuntimeInputConcurrency = 8
const externalRuntimeSessionsPerRuntime = 64
const externalRuntimeSessionsPerMetadata = 256
const externalRuntimeEventRetryInterval = 5 * time.Second
const externalRuntimeSettlementRetryInterval = 5 * time.Second
const externalRuntimeEventSessionRetryInterval = 30 * time.Second
const externalRuntimeEventScanMaxItems = 1024
const legacyAsyncCompletionResultMaxChars = 16_000
const legacyAsyncCompletionErrorMessageMaxChars = 4_000
const legacyAsyncCompletionErrorClassMaxChars = 256

const legacyAsyncCompletionRecoveryMessage = "This completion notification was stored before bounded result previews. Its oversized duplicate result was omitted during connector recovery. Use tool_call.get_result with offset 0 to read the durable result."

var canonicalExternalRuntimeSessionID = regexp.MustCompile(`^ses1_[0-9]{19}$`)

var runtimeOperationMetadataFields = []string{"action", "bytes", "command", "count", "cwd", "depth", "duration_ms", "encoding", "end", "end_line", "exit_code", "file", "file_path", "filename", "files", "id", "json_bytes", "limit", "line", "lines", "location", "mode", "name", "next_offset", "offset", "omitted", "operation", "options", "path", "paths", "pattern", "query", "range", "recursive", "shell", "size", "size_bytes", "start", "start_line", "state", "status", "success", "timeout", "timeout_ms", "tool_call_id", "truncated", "uri", "url", "workdir", "working_directory"}

var (
	// Identity and active execution are separate facts under one bbolt owner.
	// Connector recovery tests own this implementation boundary; the retained
	// ExternalRuntime model covers only Server input ACK and native evidence.
	externalRuntimeSessionsBucket         = []byte("active-sessions-v1")
	externalRuntimeIdentitiesBucket       = []byte("session-identities-v2")
	externalRuntimeActiveExecutionsBucket = []byte("active-executions-v2")
	externalRuntimeInputBatchesBucket     = []byte("input-batches-v1")
	externalRuntimeSessionEventsBucket    = []byte("session-events-v1")
	externalRuntimeFaultEpisodesBucket    = []byte("runtime-fault-episodes-v1")
	legacyExternalRuntimeRemindersBucket  = []byte("runtime-reminders-v1")
)

type externalRuntimeInputBatch struct {
	Version  int                           `json:"version"`
	Session  externalRuntimeRecoveryRecord `json:"session"`
	Messages []map[string]any              `json:"messages"`
}

type legacyAsyncCompletion struct {
	Type       string          `json:"type"`
	ToolCallID string          `json:"tool_call_id"`
	ToolName   string          `json:"tool_name,omitempty"`
	Status     string          `json:"status"`
	Error      *bool           `json:"error"`
	Summary    string          `json:"summary,omitempty"`
	SourceRefs map[string]any  `json:"source_refs"`
	Result     json.RawMessage `json:"result,omitempty"`
	ResultPage json.RawMessage `json:"result_page,omitempty"`
	Message    string          `json:"message"`
}

type runtimeSessionProjection struct {
	count int
	ids   []string
}

type externalRuntimeState struct {
	connector               *connector
	db                      *bolt.DB
	mu                      sync.Mutex
	identities              map[string]externalRuntimeSessionIdentity
	activeExecutions        map[string]externalRuntimeActiveExecution
	activeTargets           map[string]int
	runtimeSessions         map[string]map[string]struct{}
	runtimeSessionSnapshots map[string]runtimeSessionProjection
	hostOrphans             map[string]externalRuntimeHostOrphan
	sessionsObservedAt      int64
	nextID                  func() ulid.ULID
	lastID                  string
	eventWakeup             chan struct{}
	inputWakeup             chan struct{}
	metadataWakeup          chan struct{}
	settlementWakeup        chan struct{}
	settlementCursor        string
	settlementRetryAfter    map[string]time.Time
	settlementInFlight      bool
	inputCalls              sync.Map
	inputSlots              chan struct{}
	ctx                     context.Context
	cancel                  context.CancelFunc
	worker                  sync.WaitGroup
}

// This in-memory index belongs to the existing execution owner and is rebuilt
// from its validated rows at startup. A target auth save consults one count,
// never all historical identities or a fan-out of native sessions. It is not a
// persisted aggregate or a second execution authority.
func (s *externalRuntimeState) putActiveExecutionLocked(execution externalRuntimeActiveExecution) {
	key := execution.key()
	previous := s.activeExecutions[key]
	retryAfter := s.settlementRetryAfter[key]
	s.deleteActiveExecutionLocked(key)
	if previous.Session.ExecutionID == execution.Session.ExecutionID && !retryAfter.IsZero() {
		s.settlementRetryAfter[key] = retryAfter
	}
	s.activeExecutions[key] = execution
	target := runtimeSessionTargetKey(execution.Session.Provider, execution.Session.Command)
	s.activeTargets[target]++
}

func (s *externalRuntimeState) deleteActiveExecutionLocked(key string) {
	if previous, present := s.activeExecutions[key]; present {
		target := runtimeSessionTargetKey(previous.Session.Provider, previous.Session.Command)
		s.activeTargets[target]--
		if s.activeTargets[target] == 0 {
			delete(s.activeTargets, target)
		}
		delete(s.activeExecutions, key)
		delete(s.settlementRetryAfter, key)
	}
}

func (s *externalRuntimeState) targetHasActiveExecution(target runtimeProbeTarget) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.activeTargets[target.key()] > 0
}

func (s *externalRuntimeState) healthCounts() (resumable, recoverable, inputBatches, runtimeEvents int) {
	if s.db == nil {
		return 0, 0, 0, 0
	}
	s.mu.Lock()
	resumable = len(s.identities)
	recoverable = len(s.activeExecutions)
	s.mu.Unlock()
	_ = s.db.View(func(tx *bolt.Tx) error {
		inputBatches = tx.Bucket(externalRuntimeInputBatchesBucket).Stats().KeyN
		runtimeEvents = tx.Bucket(externalRuntimeSessionEventsBucket).Stats().KeyN
		return nil
	})
	return resumable, recoverable, inputBatches, runtimeEvents
}

func (s *externalRuntimeState) executionBudgetHealth(now time.Time) (settlementActionRequired int, oldestSettlementSeconds int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, execution := range s.activeExecutions {
		if execution.Phase != externalRuntimeExecutionSettling || execution.SettlingStartedAt <= 0 {
			continue
		}
		age := now.Unix() - execution.SettlingStartedAt
		if age > oldestSettlementSeconds {
			oldestSettlementSeconds = age
		}
		if execution.SettlementIssue == "execution_settlement_unknown" ||
			age >= int64(externalRuntimeSettlementBudget/time.Second) {
			settlementActionRequired++
		}
	}
	return settlementActionRequired, oldestSettlementSeconds
}

func (s *externalRuntimeState) hostOrphanBudgetHealth() (observed, actionRequired int) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, orphan := range s.hostOrphans {
		observed++
		if orphan.ActionRequired {
			actionRequired++
		}
	}
	return observed, actionRequired
}

func (s *externalRuntimeState) recoveryStartedAt(record externalRuntimeRecoveryRecord) (int, int64) {
	s.mu.Lock()
	defer s.mu.Unlock()
	execution, ok := s.activeExecutions[record.key()]
	if !ok || execution.Session.ExecutionID != record.ExecutionID {
		return 0, 0
	}
	return execution.Version, execution.RecoveryStartedAt
}

// newDisabledExternalRuntimeState backs a scope-limited connector that must
// never share, open, or recover the host-wide external runtime database. It
// holds no bolt handle (`db == nil` is the disabled sentinel every
// persistence path checks) and starts no worker goroutines, so any number of
// scoped connectors can share one --root concurrently.
func newDisabledExternalRuntimeState(connector *connector) *externalRuntimeState {
	ctx, cancel := context.WithCancel(context.Background())
	return &externalRuntimeState{
		connector:               connector,
		identities:              map[string]externalRuntimeSessionIdentity{},
		activeExecutions:        map[string]externalRuntimeActiveExecution{},
		activeTargets:           map[string]int{},
		runtimeSessions:         map[string]map[string]struct{}{},
		runtimeSessionSnapshots: map[string]runtimeSessionProjection{},
		hostOrphans:             map[string]externalRuntimeHostOrphan{},
		nextID:                  ulid.Make,
		eventWakeup:             make(chan struct{}, 1),
		inputWakeup:             make(chan struct{}, 1),
		metadataWakeup:          make(chan struct{}, 1),
		settlementWakeup:        make(chan struct{}, 1),
		settlementRetryAfter:    map[string]time.Time{},
		inputSlots:              make(chan struct{}, externalRuntimeInputConcurrency),
		ctx:                     ctx,
		cancel:                  cancel,
	}
}

var errExternalRuntimeStateDisabled = errors.New(
	"external runtime state is disabled for this connector scope",
)

func newExternalRuntimeState(connector *connector) (*externalRuntimeState, error) {
	path := filepath.Join(connector.runtimeStateRoot(), externalRuntimeStateRelativePath)
	dir := filepath.Dir(path)
	info, err := os.Lstat(dir)
	switch {
	case os.IsNotExist(err):
		if err := os.Mkdir(dir, 0o700); err != nil {
			return nil, err
		}
	case err != nil:
		return nil, err
	case !info.IsDir():
		return nil, fmt.Errorf("external runtime state directory %s must not be a symlink", dir)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return nil, err
	}
	if err := syncDirectory(connector.runtimeStateRoot()); err != nil {
		return nil, err
	}
	info, err = os.Lstat(path)
	switch {
	case os.IsNotExist(err):
		file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
		if err != nil {
			return nil, err
		}
		if err := file.Close(); err != nil {
			return nil, err
		}
	case err != nil:
		return nil, err
	case !info.Mode().IsRegular():
		return nil, fmt.Errorf("external runtime state database %s must be a regular file", path)
	}
	db, err := bolt.Open(path, 0o600, &bolt.Options{Timeout: time.Second})
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(path, 0o600); err != nil {
		db.Close()
		return nil, err
	}
	var lastID string
	if err := db.Update(func(tx *bolt.Tx) error {
		for _, name := range [][]byte{
			externalRuntimeIdentitiesBucket,
			externalRuntimeActiveExecutionsBucket,
			externalRuntimeInputBatchesBucket,
			externalRuntimeSessionEventsBucket,
			externalRuntimeFaultEpisodesBucket,
		} {
			if _, err := tx.CreateBucketIfNotExists(name); err != nil {
				return err
			}
		}
		if err := tx.DeleteBucket(legacyExternalRuntimeRemindersBucket); err != nil &&
			!errors.Is(err, bolt.ErrBucketNotFound) {
			return err
		}
		if err := migratePersistedRuntimeEvents(tx.Bucket(externalRuntimeSessionEventsBucket)); err != nil {
			return err
		}
		key, _ := tx.Bucket(externalRuntimeSessionEventsBucket).Cursor().Last()
		lastID = string(key)
		return nil
	}); err != nil {
		db.Close()
		return nil, err
	}
	if err := syncDirectory(filepath.Dir(path)); err != nil {
		db.Close()
		return nil, err
	}
	ctx, cancel := context.WithCancel(context.Background())
	s := &externalRuntimeState{
		connector:               connector,
		db:                      db,
		identities:              map[string]externalRuntimeSessionIdentity{},
		activeExecutions:        map[string]externalRuntimeActiveExecution{},
		activeTargets:           map[string]int{},
		runtimeSessions:         map[string]map[string]struct{}{},
		runtimeSessionSnapshots: map[string]runtimeSessionProjection{},
		hostOrphans:             map[string]externalRuntimeHostOrphan{},
		nextID:                  ulid.Make,
		lastID:                  lastID,
		eventWakeup:             make(chan struct{}, 1),
		inputWakeup:             make(chan struct{}, 1),
		metadataWakeup:          make(chan struct{}, 1),
		settlementWakeup:        make(chan struct{}, 1),
		settlementRetryAfter:    map[string]time.Time{},
		inputSlots:              make(chan struct{}, externalRuntimeInputConcurrency),
		ctx:                     ctx,
		cancel:                  cancel,
	}
	s.worker.Go(s.runInputBatches)
	s.worker.Go(s.run)
	s.worker.Go(s.runMetadataPublishes)
	s.worker.Go(s.runSettlements)
	return s, nil
}

func (s *externalRuntimeState) load() error {
	if s.db == nil {
		return nil
	}
	if err := s.migrateLegacyRecoveryFiles(); err != nil {
		return err
	}
	if err := s.migrateLegacyRuntimeSessions(); err != nil {
		return err
	}
	released, err := s.normalizeActiveExecutions()
	if err != nil {
		return err
	}
	if released > 0 {
		logf("released unaccepted external runtime input claims count=%d", released)
	}
	identities := []externalRuntimeSessionIdentity{}
	executions := []externalRuntimeActiveExecution{}
	if err := s.db.View(func(tx *bolt.Tx) error {
		identityBucket := tx.Bucket(externalRuntimeIdentitiesBucket)
		activeBucket := tx.Bucket(externalRuntimeActiveExecutionsBucket)
		if err := identityBucket.ForEach(func(key, raw []byte) error {
			var state externalRuntimeSessionIdentityFile
			if json.Unmarshal(raw, &state) != nil || state.Version != 2 || state.Identity.validate() != nil {
				return errors.New("invalid external runtime session identity")
			}
			if string(key) != state.Identity.key() {
				return errors.New("external runtime session identity key mismatch")
			}
			if s.connector.runtimeImplementations[state.Identity.Provider] == nil {
				return fmt.Errorf("unsupported persisted external runtime provider %q", state.Identity.Provider)
			}
			identities = append(identities, state.Identity)
			return nil
		}); err != nil {
			return err
		}
		return activeBucket.ForEach(func(key, raw []byte) error {
			var state externalRuntimeActiveExecution
			if json.Unmarshal(raw, &state) != nil || state.validate() != nil {
				return errors.New("invalid external runtime active execution")
			}
			if string(key) != state.key() || identityBucket.Get(key) == nil {
				return errors.New("external runtime active execution has no matching identity")
			}
			executions = append(executions, state)
			return nil
		})
	}); err != nil {
		return err
	}
	if err := s.validateInputBatches(); err != nil {
		return err
	}
	compacted, err := s.compactPersistedLegacyAsyncCompletions()
	if err != nil {
		return err
	}
	if compacted > 0 {
		logf("compacted persisted legacy oversized async completion messages count=%d", compacted)
	}
	s.mu.Lock()
	for _, identity := range identities {
		s.identities[identity.key()] = identity
		s.addRuntimeSessionLocked(identity)
	}
	for _, execution := range executions {
		s.putActiveExecutionLocked(execution)
	}
	s.rebuildRuntimeSessionSnapshotsLocked()
	s.markSessionsObservedLocked()
	s.mu.Unlock()
	for _, execution := range executions {
		record := execution.Session
		if unstartedRuntimeInput(execution) {
			continue
		}
		if err := s.connector.runtimeImplementations[record.Provider].Restore(record.input()); err != nil {
			return err
		}
	}
	s.wake()
	return nil
}

func (s *externalRuntimeState) enqueueInputBatch(provider string, input externalRuntimeInput) error {
	if s.db == nil {
		return errExternalRuntimeStateDisabled
	}
	batch := externalRuntimeInputBatch{
		Version:  1,
		Session:  externalRuntimeRecoveryRecordFromInput(provider, input),
		Messages: input.messages,
	}
	batch, _ = compactLegacyAsyncCompletionBatch(batch)
	if err := batch.validate(); err != nil {
		return err
	}
	key := []byte(batch.key())
	s.mu.Lock()
	err := s.db.Update(func(tx *bolt.Tx) error {
		if err := allowRuntimeMigrationInput(tx, batch.Session.key()); err != nil {
			return err
		}
		batches := tx.Bucket(externalRuntimeInputBatchesBucket)
		if existing := batches.Get(key); existing != nil {
			var current externalRuntimeInputBatch
			if json.Unmarshal(existing, &current) != nil {
				return errors.New("invalid persisted external runtime input batch")
			}
			canonical, _ := json.Marshal(batch)
			if !bytes.Equal(existing, canonical) {
				return errors.New("conflicting external runtime input batch")
			}
			return nil
		}
		raw, err := json.Marshal(batch)
		if err != nil {
			return err
		}
		return batches.Put(key, raw)
	})
	s.mu.Unlock()
	if err == nil {
		s.touchSessionActivity(provider, input.sessionID)
		s.wake()
	}
	return err
}

func (batch externalRuntimeInputBatch) key() string {
	return batch.Session.key() + "\x00" + batch.Session.DispatchID
}

func (batch externalRuntimeInputBatch) validate() error {
	if batch.Version != 1 || batch.Session.DispatchID == "" || len(batch.Messages) == 0 {
		return errors.New("invalid external runtime input batch")
	}
	if err := batch.Session.validate(); err != nil {
		return err
	}
	return nil
}

func decodeExternalRuntimeInputBatch(key, raw []byte) (externalRuntimeInputBatch, error) {
	var batch externalRuntimeInputBatch
	if json.Unmarshal(raw, &batch) != nil || batch.validate() != nil {
		return batch, errors.New("invalid external runtime input batch")
	}
	if string(key) != batch.key() {
		return batch, errors.New("external runtime input batch key mismatch")
	}
	return batch, nil
}

func (s *externalRuntimeState) compactPersistedLegacyAsyncCompletions() (int, error) {
	compacted := 0
	err := s.db.Update(func(tx *bolt.Tx) error {
		bucket := tx.Bucket(externalRuntimeInputBatchesBucket)
		rewrites := map[string][]byte{}
		if err := bucket.ForEach(func(key, raw []byte) error {
			batch, err := decodeExternalRuntimeInputBatch(key, raw)
			if err != nil {
				return err
			}
			canonical, changed := compactLegacyAsyncCompletionBatch(batch)
			if changed == 0 {
				return nil
			}
			encoded, err := json.Marshal(canonical)
			if err != nil {
				return err
			}
			rewrites[string(key)] = encoded
			compacted += changed
			return nil
		}); err != nil {
			return err
		}
		for key, raw := range rewrites {
			if err := bucket.Put([]byte(key), raw); err != nil {
				return err
			}
		}
		return nil
	})
	return compacted, err
}

func compactLegacyAsyncCompletionBatch(batch externalRuntimeInputBatch) (externalRuntimeInputBatch, int) {
	messages := make([]map[string]any, len(batch.Messages))
	changed := 0
	for index, message := range batch.Messages {
		canonical, compacted := compactLegacyAsyncCompletionMessage(message)
		messages[index] = canonical
		if compacted {
			changed++
		}
	}
	if changed > 0 {
		batch.Messages = messages
	}
	return batch, changed
}

func compactLegacyAsyncCompletionMessage(message map[string]any) (map[string]any, bool) {
	if exactString(message, "role") != "runtime" ||
		exactString(message, "kind") != "runtime_message" {
		return message, false
	}
	notificationType := exactString(message, "type")
	status := ""
	errorValue := false
	switch notificationType {
	case "tool_call_completed":
		status = "completed"
	case "tool_call_failed":
		status = "failed"
		errorValue = true
	default:
		return message, false
	}
	toolCallID := exactString(message, "source_tool_call_id")
	notificationID := "tool-call-result:" + toolCallID
	if toolCallID == "" ||
		exactString(message, "runtime_message_id") != notificationID ||
		exactString(message, "source_message_id") != notificationID {
		return message, false
	}

	var content legacyAsyncCompletion
	statusMatches := func(inner string) bool {
		return inner == status ||
			(notificationType == "tool_call_failed" && inner == "completed")
	}
	if json.Unmarshal([]byte(exactString(message, "content")), &content) != nil ||
		content.Type != notificationType ||
		content.ToolCallID != toolCallID ||
		!statusMatches(content.Status) ||
		content.Error == nil ||
		*content.Error != errorValue ||
		content.Result == nil ||
		content.ResultPage != nil ||
		utf8.RuneCount(content.Result) <= legacyAsyncCompletionResultMaxChars {
		return message, false
	}

	sourceRefs := compactLegacyAsyncCompletionSourceRefs(
		content.SourceRefs,
		toolCallID,
		content.ToolName,
		status,
	)
	content.Result = nil
	content.Status = status
	content.SourceRefs = sourceRefs
	if summary := exactString(message, "summary"); summary != "" {
		content.Summary = summary
	}
	content.Message = legacyAsyncCompletionRecoveryMessage
	encoded, err := json.Marshal(content)
	if err != nil {
		return message, false
	}
	canonical := make(map[string]any, len(message))
	for key, value := range message {
		canonical[key] = value
	}
	canonical["content"] = string(encoded)
	canonical["source_refs"] = sourceRefs
	return canonical, true
}

func compactLegacyAsyncCompletionSourceRefs(
	source map[string]any,
	toolCallID string,
	toolName string,
	status string,
) map[string]any {
	result := map[string]any{
		"tool_call_id": toolCallID,
		"status":       status,
	}
	if toolName != "" {
		result["tool_name"] = toolName
	}
	for _, field := range []struct {
		name  string
		limit int
	}{
		{name: "error_class", limit: legacyAsyncCompletionErrorClassMaxChars},
		{name: "error_message", limit: legacyAsyncCompletionErrorMessageMaxChars},
	} {
		value, ok := source[field.name].(string)
		if !ok || value == "" {
			continue
		}
		bounded, truncated := truncateRunes(value, field.limit)
		result[field.name] = bounded
		if truncated || source[field.name+"_truncated"] == true {
			result[field.name+"_truncated"] = true
		}
	}
	return result
}

func exactString(values map[string]any, key string) string {
	value, _ := values[key].(string)
	return value
}

func truncateRunes(value string, limit int) (string, bool) {
	if utf8.RuneCountInString(value) <= limit {
		return value, false
	}
	runes := []rune(value)
	return string(runes[:limit]), true
}

func (s *externalRuntimeState) validateInputBatches() error {
	return s.db.View(func(tx *bolt.Tx) error {
		bucket := tx.Bucket(externalRuntimeInputBatchesBucket)
		return bucket.ForEach(func(key, raw []byte) error {
			batch, err := decodeExternalRuntimeInputBatch(key, raw)
			if err != nil {
				return err
			}
			if s.connector.runtimeImplementations[batch.Session.Provider] == nil {
				return fmt.Errorf("unsupported persisted external runtime provider %q", batch.Session.Provider)
			}
			return nil
		})
	})
}

func (s *externalRuntimeState) nextInputBatches() ([]externalRuntimeInputBatch, bool, error) {
	var claimed []externalRuntimeInputBatch
	claimedSession := ""
	claimedToken := ""
	skippedSession := ""
	s.mu.Lock()
	defer s.mu.Unlock()
	err := s.db.View(func(tx *bolt.Tx) error {
		bucket := tx.Bucket(externalRuntimeInputBatchesBucket)
		cursor := bucket.Cursor()
		for key, raw := cursor.First(); raw != nil; key, raw = cursor.Next() {
			batch, err := decodeExternalRuntimeInputBatch(key, raw)
			if err != nil {
				return err
			}
			sessionKey := batch.Session.key()
			if claimedSession == "" {
				if sessionKey == skippedSession {
					continue
				}
				// Recovery, settlement, and capability changes must not block another Session.
				if active, exists := s.activeExecutions[sessionKey]; exists &&
					(active.Phase == externalRuntimeExecutionInterrupted || active.Phase == externalRuntimeExecutionSettling || len(active.InputBatchIDs) > 0 ||
						active.Session.Token != batch.Session.Token) {
					skippedSession = sessionKey
					continue
				}
				if _, inFlight := s.inputCalls.LoadOrStore(sessionKey, struct{}{}); inFlight {
					skippedSession = sessionKey
					continue
				}
				claimedSession = sessionKey
				claimedToken = batch.Session.Token
			}
			if sessionKey != claimedSession || batch.Session.Token != claimedToken {
				break
			}
			claimed = append(claimed, batch)
		}
		return nil
	})
	if err != nil {
		if claimedSession != "" {
			s.inputCalls.Delete(claimedSession)
		}
		return nil, false, err
	}
	return claimed, len(claimed) > 0, nil
}

func (s *externalRuntimeState) drainInputBatches() {
	for len(s.inputSlots) < cap(s.inputSlots) {
		batches, ok, err := s.nextInputBatches()
		if err != nil {
			logf("claim external runtime input batches failed: %v", err)
			return
		}
		if !ok {
			return
		}
		sessionKey := batches[0].Session.key()
		s.inputSlots <- struct{}{}
		s.worker.Go(func() {
			completed := s.deliverInputBatches(batches)
			s.inputCalls.Delete(sessionKey)
			<-s.inputSlots
			if completed {
				s.wake()
			}
		})
	}
}

func (s *externalRuntimeState) runInputBatches() {
	for {
		select {
		case <-s.inputWakeup:
			s.drainInputBatches()
		case <-s.ctx.Done():
			return
		}
	}
}

func (s *externalRuntimeState) deliverInputBatches(batches []externalRuntimeInputBatch) bool {
	nativeCtx, leaveAccess, admitted := s.connector.deviceRuntimeAdmission(s.ctx)
	if !admitted {
		return false
	}
	defer leaveAccess()
	latest := batches[len(batches)-1]
	input := s.inputForBatches(batches)
	leaveNative, err := s.connector.enterRuntimeAuthNativeCallAdmitted(s.ctx, latest.Session.Provider, input.command)
	if err != nil {
		return false
	}
	defer leaveNative()
	err = prepareExternalRuntimeWorkspace(input.workspace)
	messages := []map[string]any(nil)
	if err == nil {
		// Workspace archival notices ride along as a runtime-role message so
		// the persisted batch itself stays byte-stable across duplicates.
		if notice := s.connector.peekWorkspaceRuntimeNotice(latest.Session.SessionID); notice != "" {
			input.messages = append(input.messages, map[string]any{"role": "runtime", "content": notice})
		}
		messages, err = input.agentBatchMessages(time.Now())
	}
	if err == nil {
		input.messages = messages
		input, err = s.claimInputBatches(batches, input)
	}
	if err == nil {
		err = s.ensureHostExecutionAcquired(input)
	}
	if err == nil {
		implementation := s.connector.runtimeImplementations[latest.Session.Provider]
		if implementation == nil {
			err = fmt.Errorf("external runtime provider %q is unavailable", latest.Session.Provider)
		} else {
			ctx, cancel := context.WithTimeout(nativeCtx, 60*time.Second)
			_, _, err = implementation.Send(ctx, input)
			cancel()
		}
		if err == nil {
			s.connector.clearWorkspaceRuntimeNotice(latest.Session.SessionID)
		}
	}
	if err != nil {
		logf("external runtime input batches deferred provider=%s session=%s batches=%d latest=%s: %v", latest.Session.Provider, latest.Session.SessionID, len(batches), latest.Session.DispatchID, err)
		return false
	}
	if err := s.acceptInputClaim(latest.Session.Provider, input); err != nil {
		logf("external runtime input batch acknowledgement failed provider=%s session=%s batches=%d latest=%s: %v", latest.Session.Provider, latest.Session.SessionID, len(batches), latest.Session.DispatchID, err)
		return false
	}
	return true
}

func (s *externalRuntimeState) inputForBatches(batches []externalRuntimeInputBatch) externalRuntimeInput {
	latest := batches[len(batches)-1]
	input := latest.Session.input()
	input.batchIDs = make([]string, 0, len(batches))
	for _, batch := range batches {
		input.batchIDs = append(input.batchIDs, batch.Session.DispatchID)
		for index, message := range batch.Messages {
			copy := make(map[string]any, len(message)+1)
			for key, value := range message {
				copy[key] = value
			}
			if stringParam(copy, "id") == "" && stringParam(copy, "source_message_id") == "" {
				copy["id"] = fmt.Sprintf("%s:%d", batch.Session.DispatchID, index+1)
			}
			input.messages = append(input.messages, copy)
		}
	}
	s.mu.Lock()
	if identity, ok := s.identities[latest.Session.key()]; ok {
		input.command = identity.Command
		input.payload = maps.Clone(identity.Payload)
		input.workspace = identity.Workspace
	}
	s.mu.Unlock()
	return input
}

// claimInputBatches lets the active owner durably claim exact inbox membership
// before provider Send can begin.
func (s *externalRuntimeState) claimInputBatches(
	batches []externalRuntimeInputBatch,
	input externalRuntimeInput,
) (externalRuntimeInput, error) {
	if len(batches) == 0 || len(input.batchIDs) != len(batches) {
		return input, errors.New("invalid external runtime input claim membership")
	}
	record := externalRuntimeRecoveryRecordFromInput(batches[len(batches)-1].Session.Provider, input)
	for index, batch := range batches {
		if batch.Session.key() != record.key() ||
			batch.Session.Token != input.token ||
			batch.Session.DispatchID != input.batchIDs[index] {
			return input, errors.New("external runtime input claim crosses a session or capability")
		}
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	execution, exists := s.activeExecutions[record.key()]
	if exists && (len(execution.InputBatchIDs) > 0 ||
		execution.Phase == externalRuntimeExecutionInterrupted ||
		execution.Phase == externalRuntimeExecutionSettling) {
		return input, errors.New("external runtime recovery must settle before accepting new input")
	}
	if exists && execution.Session.Token != input.token {
		return input, errors.New("external runtime capability changed")
	}
	if !exists {
		executionID, err := newRuntimeContext()
		if err != nil {
			return input, err
		}
		version := 4 // Direct Connector: native execution is owned locally.
		var target externalRuntimeExecutionTarget
		if s.connector.requiresHostRuntimeExecution() {
			version = 3
			target, err = externalRuntimeExecutionTargetFromMap(s.connector.currentComputeRuntimeExecutionTarget())
			if err != nil {
				return input, err
			}
		}
		input.executionID = executionID
		record.ExecutionID = executionID
		execution = externalRuntimeActiveExecution{
			Version: version, Phase: externalRuntimeExecutionStarting, Session: record, Target: target,
			RecoveryStartedAt: time.Now().Unix(),
		}
	} else {
		// Direct sessions restored from the legacy native identity can still
		// accept input after recovery. Never upgrade them onto a Compute Host.
		if execution.Version == 2 && !s.connector.requiresHostRuntimeExecution() {
			execution.Version = 4
			execution.RecoveryStartedAt = time.Now().Unix()
			if execution.Session.ExecutionID == "" {
				executionID, err := newRuntimeContext()
				if err != nil {
					return input, err
				}
				execution.Session.ExecutionID = executionID
			}
		}
		if !slices.Contains([]int{3, 4}, execution.Version) || execution.Session.ExecutionID == "" {
			return input, errors.New("legacy external runtime execution requires recovery")
		}
		input.executionID = execution.Session.ExecutionID
	}
	execution.InputBatchIDs = slices.Clone(input.batchIDs)
	changed, err := s.storeActiveExecutionLocked(externalRuntimeIdentityFromRecovery(record), execution)
	if changed {
		s.wakeMetadataPublish()
	}
	return input, err
}

func (s *externalRuntimeState) ensureHostExecutionAcquired(input externalRuntimeInput) error {
	key := input.provider + "\x00" + input.sessionID
	s.mu.Lock()
	execution, exists := s.activeExecutions[key]
	if !exists || execution.Session.ExecutionID != input.executionID || !slices.Contains([]int{3, 4}, execution.Version) {
		s.mu.Unlock()
		return errors.New("runtime execution acquisition intent is unavailable")
	}
	if execution.Version == 4 {
		s.mu.Unlock()
		if s.connector.requiresHostRuntimeExecution() {
			return errors.New("direct runtime execution cannot acquire a Compute Host")
		}
		return nil
	}
	if execution.HostAcquired {
		s.mu.Unlock()
		return nil
	}
	target := execution.Target
	s.mu.Unlock()
	result, err := s.connector.runtimeExecution(s.ctx, "acquire", input.executionID, target.mapValue())
	if err != nil {
		return err
	}
	if stringParam(result, "execution_id") != input.executionID ||
		stringParam(result, "container_instance_id") != target.ContainerInstanceID {
		return errors.New("runtime execution acquire acknowledgement changed target")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	current, ok := s.activeExecutions[key]
	if !ok || current.Session.ExecutionID != input.executionID || current.Target != target {
		return errors.New("runtime execution acquisition fence changed")
	}
	current.HostAcquired = true
	_, err = s.storeActiveExecutionLocked(externalRuntimeIdentityFromRecovery(current.Session), current)
	return err
}

func (s *externalRuntimeState) acceptInputClaim(provider string, input externalRuntimeInput) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	key := provider + "\x00" + input.sessionID
	execution, exists := s.activeExecutions[key]
	if !exists {
		return s.assertInputClaimRowsAbsentLocked(provider, input)
	}
	if len(execution.InputBatchIDs) == 0 {
		if execution.Session.Token != input.token {
			return errors.New("external runtime input acknowledgement capability changed")
		}
		return s.assertInputClaimRowsAbsentLocked(provider, input)
	}
	if !inputClaimMatches(execution, input) {
		return errors.New("external runtime input acknowledgement does not match its active claim")
	}
	return s.clearInputClaimLocked(key, execution, true, false)
}

func (s *externalRuntimeState) assertInputClaimRowsAbsentLocked(
	provider string,
	input externalRuntimeInput,
) error {
	return s.db.View(func(tx *bolt.Tx) error {
		bucket := tx.Bucket(externalRuntimeInputBatchesBucket)
		for _, batchID := range input.batchIDs {
			key := []byte(provider + "\x00" + input.sessionID + "\x00" + batchID)
			if bucket.Get(key) != nil {
				return errors.New("external runtime input lost its active claim before acknowledgement")
			}
		}
		return nil
	})
}

func (s *externalRuntimeState) releaseInputClaim(
	provider string,
	input externalRuntimeInput,
) error {
	key := provider + "\x00" + input.sessionID
	s.mu.Lock()
	defer s.mu.Unlock()
	execution, exists := s.activeExecutions[key]
	if !exists || !inputClaimMatches(execution, input) {
		return nil
	}
	removeActive := inputClaimIsBound(execution) || execution.Session.ExecutionID == ""
	return s.clearInputClaimLocked(key, execution, false, removeActive)
}

func inputClaimMatches(execution externalRuntimeActiveExecution, input externalRuntimeInput) bool {
	return len(input.batchIDs) > 0 && slices.Equal(execution.InputBatchIDs, input.batchIDs) &&
		execution.Session.Token == input.token
}

func inputClaimIsBound(execution externalRuntimeActiveExecution) bool {
	return len(execution.InputBatchIDs) > 0 && execution.Session.ExecutionID != "" &&
		execution.Session.DispatchID == execution.InputBatchIDs[len(execution.InputBatchIDs)-1]
}

func (s *externalRuntimeState) clearInputClaimLocked(
	key string,
	execution externalRuntimeActiveExecution,
	deleteRows, removeActive bool,
) error {
	batchIDs := execution.InputBatchIDs
	execution.InputBatchIDs = nil
	if err := s.db.Update(func(tx *bolt.Tx) error {
		if deleteRows {
			if err := deleteRuntimeInputBatchRows(tx, key, execution.Session.Token, batchIDs); err != nil {
				return err
			}
		}
		bucket := tx.Bucket(externalRuntimeActiveExecutionsBucket)
		if removeActive {
			return bucket.Delete([]byte(key))
		}
		encoded, err := json.Marshal(execution)
		if err != nil {
			return err
		}
		return bucket.Put([]byte(key), encoded)
	}); err != nil {
		return err
	}
	if removeActive {
		s.deleteActiveExecutionLocked(key)
	} else {
		s.putActiveExecutionLocked(execution)
	}
	return nil
}

func deleteRuntimeInputBatchRows(tx *bolt.Tx, sessionKey, token string, batchIDs []string) error {
	bucket := tx.Bucket(externalRuntimeInputBatchesBucket)
	for _, batchID := range batchIDs {
		key := []byte(sessionKey + "\x00" + batchID)
		raw := bucket.Get(key)
		if raw == nil {
			continue
		}
		batch, err := decodeExternalRuntimeInputBatch(key, raw)
		if err != nil {
			return err
		}
		if batch.Session.key() != sessionKey ||
			batch.Session.Token != token ||
			batch.Session.DispatchID != batchID {
			return errors.New("external runtime input claim no longer matches its inbox row")
		}
		if err := bucket.Delete(key); err != nil {
			return err
		}
	}
	return nil
}

func (s *externalRuntimeState) storeActiveExecutionLocked(
	identity externalRuntimeSessionIdentity,
	execution externalRuntimeActiveExecution,
) (bool, error) {
	if err := identity.validate(); err != nil {
		return false, err
	}
	if err := execution.validate(); err != nil {
		return false, err
	}
	identityRaw, err := json.Marshal(externalRuntimeSessionIdentityFile{Version: 2, Identity: identity})
	if err != nil {
		return false, err
	}
	executionRaw, err := json.Marshal(execution)
	if err != nil {
		return false, err
	}
	if err := s.db.Update(func(tx *bolt.Tx) error {
		key := []byte(execution.key())
		if err := allowRuntimeMigrationInput(tx, execution.key()); err != nil {
			return err
		}
		if err := tx.Bucket(externalRuntimeIdentitiesBucket).Put(key, identityRaw); err != nil {
			return err
		}
		return tx.Bucket(externalRuntimeActiveExecutionsBucket).Put(key, executionRaw)
	}); err != nil {
		return false, err
	}
	previous, existed := s.identities[identity.key()]
	s.identities[identity.key()] = identity
	s.putActiveExecutionLocked(execution)
	changed := !existed || previous.Command != identity.Command
	if changed {
		if existed {
			s.removeRuntimeSessionLocked(previous)
			s.refreshRuntimeSessionSnapshotLocked(runtimeSessionTargetKey(previous.Provider, previous.Command))
		}
		s.addRuntimeSessionLocked(identity)
		s.refreshRuntimeSessionSnapshotLocked(runtimeSessionTargetKey(identity.Provider, identity.Command))
		s.markSessionsObservedLocked()
	}
	return changed, nil
}

func (s *externalRuntimeState) watch(record externalRuntimeRecoveryRecord, batchIDs ...string) error {
	if s.db == nil {
		return errExternalRuntimeStateDisabled
	}
	identity := externalRuntimeIdentityFromRecovery(record)
	s.mu.Lock()
	defer s.mu.Unlock()
	select {
	case <-s.ctx.Done():
		return errors.New("external runtime state is closed")
	default:
	}
	execution, exists := s.activeExecutions[record.key()]
	if !exists {
		execution = externalRuntimeActiveExecution{
			Version:       2,
			Phase:         externalRuntimeExecutionStarting,
			Session:       record,
			InputBatchIDs: slices.Clone(batchIDs),
		}
	} else {
		if execution.Phase == externalRuntimeExecutionSettling {
			return errors.New("external runtime execution is settling")
		}
		previousExecutionID := execution.Session.ExecutionID
		previousDispatchID := execution.Session.DispatchID
		if len(execution.InputBatchIDs) > 0 {
			if !slices.Equal(execution.InputBatchIDs, batchIDs) ||
				record.DispatchID != batchIDs[len(batchIDs)-1] || execution.Session.Token != record.Token {
				return errors.New("external runtime input claim changed before native binding")
			}
		} else if len(batchIDs) > 0 &&
			(execution.Session.DispatchID != record.DispatchID ||
				execution.Session.ExecutionID != record.ExecutionID ||
				execution.Session.Token != record.Token) {
			return errors.New("external runtime input has no matching durable claim")
		}
		execution.Session = record
		// Rebinding metadata is not recovery acceptance. Preserve interruption
		// for the exact dispatch until the native receipt/phase transaction.
		// RuntimeRecoveryReceipt: this metadata refresh stutters the phase.
		preserveInterrupted := execution.Phase == externalRuntimeExecutionInterrupted &&
			previousExecutionID == record.ExecutionID && previousDispatchID == record.DispatchID
		if !preserveInterrupted && (execution.Phase != externalRuntimeExecutionRunning || previousExecutionID != record.ExecutionID) {
			execution.Phase = externalRuntimeExecutionStarting
		}
	}
	changed, err := s.storeActiveExecutionLocked(identity, execution)
	if err != nil {
		return err
	}
	if changed {
		s.wakeMetadataPublish()
	}
	return nil
}

func (s *externalRuntimeState) forget(provider, sessionID string) {
	if s.db == nil {
		return
	}
	s.mu.Lock()
	existed, err := s.forgetKeyLocked(provider + "\x00" + sessionID)
	s.mu.Unlock()
	if err == nil && existed {
		s.wakeMetadataPublish()
	}
	if err != nil {
		logf("external runtime recovery state cleanup failed provider=%s session=%s: %v", provider, sessionID, err)
	}
}

// forgetExecution is forget gated on the durable execution fence: the
// obligation and identity are removed only while the currently watched
// execution still matches the sampled record's dispatch/execution generation.
// It reports the removed execution's phase so the caller can decide whether
// the abandoned work still owes a failed announcement. A fence mismatch means
// the obligation was replaced after the caller sampled it; nothing is removed.
func (s *externalRuntimeState) forgetExecution(record externalRuntimeRecoveryRecord) (string, bool, error) {
	if s.db == nil {
		return "", false, errExternalRuntimeStateDisabled
	}
	key := record.key()
	s.mu.Lock()
	execution, exists := s.activeExecutions[key]
	if !exists || execution.Session.DispatchID != record.DispatchID ||
		execution.Session.ExecutionID != record.ExecutionID {
		s.mu.Unlock()
		return "", false, nil
	}
	existed, err := s.forgetKeyLocked(key)
	s.mu.Unlock()
	if err == nil && existed {
		s.wakeMetadataPublish()
	}
	if err != nil {
		logf("external runtime recovery state cleanup failed provider=%s session=%s: %v", record.Provider, record.SessionID, err)
		return "", false, err
	}
	return execution.Phase, true, nil
}

// forgetKeyLocked deletes one obligation/identity pair from both durable
// buckets and the in-memory maps. It reports whether an identity existed so
// the caller can publish a metadata update outside the lock.
func (s *externalRuntimeState) forgetKeyLocked(key string) (bool, error) {
	identity, existed := s.identities[key]
	err := s.db.Update(func(tx *bolt.Tx) error {
		if err := tx.Bucket(externalRuntimeActiveExecutionsBucket).Delete([]byte(key)); err != nil {
			return err
		}
		return tx.Bucket(externalRuntimeIdentitiesBucket).Delete([]byte(key))
	})
	if err == nil {
		s.deleteActiveExecutionLocked(key)
		delete(s.identities, key)
		if existed {
			s.removeRuntimeSessionLocked(identity)
			s.refreshRuntimeSessionSnapshotLocked(runtimeSessionTargetKey(identity.Provider, identity.Command))
			s.markSessionsObservedLocked()
		}
	}
	return existed, err
}

// discardSession deletes only rows that carry the exact provider/Session key
// or the exact Salix capability. The Worker is permanently archived before
// this internal operation is reachable, so pending local copies are no longer
// delivery obligations and are deliberately removed.
func (s *externalRuntimeState) discardSession(provider, sessionID, operationID, token string) error {
	if s.db == nil || token == "" {
		return errExternalRuntimeStateDisabled
	}
	key := provider + "\x00" + sessionID
	s.mu.Lock()
	defer s.mu.Unlock()
	identity, existed := s.identities[key]
	err := s.db.Update(func(tx *bolt.Tx) error {
		seal, err := runtimeMigrationSeal(tx, key)
		if err != nil {
			return err
		}
		if seal == nil || seal.OperationID != operationID ||
			(seal.Phase != "discarding" && seal.Phase != "discarded") {
			return errors.New("archive discard admission fence is missing")
		}
		prefix := []byte(key + "\x00")
		batches := tx.Bucket(externalRuntimeInputBatchesBucket)
		batchKeys := [][]byte{}
		faultKeys := [][]byte{}
		cursor := batches.Cursor()
		for k, raw := cursor.Seek(prefix); k != nil && bytes.HasPrefix(k, prefix); k, raw = cursor.Next() {
			if len(batchKeys) >= migrationFileLimit {
				return errors.New("archive discard input inspection exceeds 100000 rows")
			}
			batch, err := decodeExternalRuntimeInputBatch(k, raw)
			if err != nil {
				return err
			}
			batchKeys = append(batchKeys, bytes.Clone(k))
			if batch.Session.DispatchID != "" && batch.Session.ExecutionID != "" {
				faultKeys = append(faultKeys, []byte(provider+"\x00"+batch.Session.DispatchID+"\x00"+batch.Session.ExecutionID))
			}
		}
		events := tx.Bucket(externalRuntimeSessionEventsBucket)
		if events.Stats().KeyN > migrationFileLimit {
			return errors.New("archive discard event inspection exceeds 100000 rows")
		}
		eventKeys := [][]byte{}
		if err := events.ForEach(func(k, raw []byte) error {
			var event message
			if err := json.Unmarshal(raw, &event); err != nil {
				return err
			}
			if stringParam(event.Params, "capability_token") == token {
				eventKeys = append(eventKeys, bytes.Clone(k))
				payload := mapParam(event.Params, "event")
				dispatch, execution := stringParam(payload, "dispatch_id"), stringParam(payload, "execution_id")
				if dispatch != "" && execution != "" {
					faultKeys = append(faultKeys, []byte(provider+"\x00"+dispatch+"\x00"+execution))
				}
			}
			return nil
		}); err != nil {
			return err
		}
		for _, row := range batchKeys {
			if err := batches.Delete(row); err != nil {
				return err
			}
		}
		for _, row := range eventKeys {
			if err := events.Delete(row); err != nil {
				return err
			}
		}
		for _, row := range faultKeys {
			if err := tx.Bucket(externalRuntimeFaultEpisodesBucket).Delete(row); err != nil {
				return err
			}
		}
		if err := tx.Bucket(externalRuntimeActiveExecutionsBucket).Delete([]byte(key)); err != nil {
			return err
		}
		if err := tx.Bucket(externalRuntimeIdentitiesBucket).Delete([]byte(key)); err != nil {
			return err
		}
		seal.Phase = "discarded"
		raw, err := json.Marshal(seal)
		if err != nil {
			return err
		}
		return tx.Bucket(externalRuntimeMigrationBucket).Put([]byte(key), raw)
	})
	if err != nil {
		return err
	}
	s.deleteActiveExecutionLocked(key)
	delete(s.identities, key)
	if existed {
		s.removeRuntimeSessionLocked(identity)
		s.refreshRuntimeSessionSnapshotLocked(runtimeSessionTargetKey(identity.Provider, identity.Command))
		s.markSessionsObservedLocked()
	}
	s.wakeMetadataPublish()
	return nil
}

// prepareDiscard closes local admission before the native process is quieted.
// Unlike migration prepare, permanent archive deliberately abandons pending
// local copies, so this fence does not require them to drain first.
func (s *externalRuntimeState) prepareDiscard(seal externalRuntimeMigrationSeal, token string) error {
	if s.db == nil || token == "" || seal.OperationID == "" || seal.Source == "" || seal.Target == "" ||
		!canonicalExternalRuntimeSessionID.MatchString(seal.SessionID) ||
		(seal.Provider != "codex" && seal.Provider != "claude" && seal.Provider != "pi") {
		return errors.New("invalid archive discard scope")
	}
	key := seal.Provider + "\x00" + seal.SessionID
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.db.Update(func(tx *bolt.Tx) error {
		// Permanent archive is also the cleanup path for a Session that never
		// reached a settled provider identity. The authenticated server request
		// supplies the exact Session capability; the discard owner still limits
		// database rows to provider+Session or that capability.
		if tx.Bucket(externalRuntimeIdentitiesBucket).Get([]byte(key)) == nil {
			previous, err := runtimeMigrationSeal(tx, key)
			if err != nil {
				return err
			}
			if previous != nil && previous.OperationID == seal.OperationID &&
				(previous.Phase == "discarding" || previous.Phase == "discarded") {
				return nil
			}
		}
		seal.Phase = "discarding"
		raw, err := json.Marshal(seal)
		if err != nil {
			return err
		}
		bucket, err := tx.CreateBucketIfNotExists(externalRuntimeMigrationBucket)
		if err != nil {
			return err
		}
		return bucket.Put([]byte(key), raw)
	})
}

func (s *externalRuntimeState) addRuntimeSessionLocked(identity externalRuntimeSessionIdentity) {
	if !canonicalExternalRuntimeSessionID.MatchString(identity.SessionID) {
		return
	}
	key := runtimeSessionTargetKey(identity.Provider, identity.Command)
	if s.runtimeSessions[key] == nil {
		s.runtimeSessions[key] = map[string]struct{}{}
	}
	s.runtimeSessions[key][identity.SessionID] = struct{}{}
}

func (s *externalRuntimeState) removeRuntimeSessionLocked(identity externalRuntimeSessionIdentity) {
	key := runtimeSessionTargetKey(identity.Provider, identity.Command)
	sessions := s.runtimeSessions[key]
	delete(sessions, identity.SessionID)
	if len(sessions) == 0 {
		delete(s.runtimeSessions, key)
	}
}

func (s *externalRuntimeState) rebuildRuntimeSessionSnapshotsLocked() {
	clear(s.runtimeSessionSnapshots)
	for key := range s.runtimeSessions {
		s.refreshRuntimeSessionSnapshotLocked(key)
	}
}

func (s *externalRuntimeState) refreshRuntimeSessionSnapshotLocked(key string) {
	set := s.runtimeSessions[key]
	if len(set) == 0 {
		delete(s.runtimeSessionSnapshots, key)
		return
	}
	ids := make([]string, 0, len(set))
	for sessionID := range set {
		ids = append(ids, sessionID)
	}
	sort.Strings(ids)
	ids = ids[:min(len(ids), externalRuntimeSessionsPerRuntime)]
	s.runtimeSessionSnapshots[key] = runtimeSessionProjection{count: len(set), ids: ids}
}

func runtimeSessionTargetKey(provider, identityMaterial string) string {
	return provider + "\x00" + identityMaterial
}

func (s *externalRuntimeState) markSessionsObservedLocked() {
	now := time.Now().UnixMilli()
	if now <= s.sessionsObservedAt {
		now = s.sessionsObservedAt + 1
	}
	s.sessionsObservedAt = now
}

func (s *externalRuntimeState) attachRuntimeSessionSnapshots(runtimes []map[string]any) {
	projections := make([]runtimeSessionProjection, len(runtimes))
	s.mu.Lock()
	observedAt := s.sessionsObservedAt
	for index, runtime := range runtimes {
		projection := s.runtimeSessionSnapshots[runtimeSessionTargetKey(stringParam(runtime, "provider"), stringParam(runtime, "identity_material"))]
		projections[index] = runtimeSessionProjection{
			count: projection.count,
			ids:   slices.Clone(projection.ids),
		}
	}
	s.mu.Unlock()

	remaining := externalRuntimeSessionsPerMetadata
	for index, runtime := range runtimes {
		provider := stringParam(runtime, "provider")
		if provider != "codex" && provider != "pi" && provider != "kimi" && provider != "claude" {
			continue
		}
		owned := projections[index]
		visible := min(len(owned.ids), remaining)
		ids := make([]string, visible)
		copy(ids, owned.ids[:visible])
		remaining -= visible
		runtime["session_snapshot"] = map[string]any{
			"schema_version": 1,
			"observed_at":    observedAt,
			"session_count":  owned.count,
			"session_ids":    ids,
			"truncated":      visible < owned.count,
		}
	}
}

func (s *externalRuntimeState) wakeMetadataPublish() {
	select {
	case s.metadataWakeup <- struct{}{}:
	default:
	}
}

func (s *externalRuntimeState) runMetadataPublishes() {
	for {
		select {
		case <-s.metadataWakeup:
			// Collapse ownership bursts before reading the latest complete snapshot.
			timer := time.NewTimer(10 * time.Millisecond)
			select {
			case <-timer.C:
			case <-s.ctx.Done():
				timer.Stop()
				return
			}
			draining := true
			for draining {
				select {
				case <-s.metadataWakeup:
				default:
					draining = false
				}
			}
			s.connector.publishCachedMetadata()
		case <-s.ctx.Done():
			return
		}
	}
}

func (s *externalRuntimeState) activeRecords() []externalRuntimeRecoveryRecord {
	s.mu.Lock()
	defer s.mu.Unlock()
	records := make([]externalRuntimeRecoveryRecord, 0, len(s.activeExecutions))
	for _, execution := range s.activeExecutions {
		if execution.Phase != externalRuntimeExecutionSettling {
			records = append(records, execution.Session)
		}
	}
	return records
}

func (s *externalRuntimeState) reconcileHostExecution(ctx context.Context, record externalRuntimeRecoveryRecord) error {
	key := record.key()
	s.mu.Lock()
	execution, ok := s.activeExecutions[key]
	s.mu.Unlock()
	if !ok || execution.Session.ExecutionID != record.ExecutionID {
		return errors.New("runtime execution recovery fence changed")
	}
	if execution.Version == 4 && s.connector.requiresHostRuntimeExecution() {
		return errors.New("direct runtime execution cannot recover on a Compute Host")
	}
	if execution.Version != 3 {
		// Direct Connector records have no Host right. Version 2 predates Host execution rights. Its durable native identity
		// still has to be reconciled in place; it cannot be acquired against a
		// newly observed target or treated as absent merely because no right was
		// recorded by the old binary.
		return nil
	}
	result, err := s.connector.runtimeExecution(ctx, "list", "", execution.Target.mapValue())
	if err != nil {
		return err
	}
	present, err := exactHostExecutionPresent(result, execution, record.ExecutionID)
	if err != nil {
		return err
	}
	if present {
		if execution.HostAcquired {
			return nil
		}
		return s.markHostExecutionAcquired(key, record.ExecutionID, execution.Target)
	}
	if execution.HostAcquired {
		return errors.New("runtime execution is absent from the exact Host target")
	}
	currentTarget, err := externalRuntimeExecutionTargetFromMap(s.connector.currentComputeRuntimeExecutionTarget())
	if err != nil || currentTarget != execution.Target {
		return errors.New("runtime execution acquire authority changed before recovery")
	}
	result, err = s.connector.runtimeExecution(ctx, "acquire", record.ExecutionID, execution.Target.mapValue())
	if err != nil {
		return err
	}
	if stringParam(result, "execution_id") != record.ExecutionID ||
		stringParam(result, "container_instance_id") != execution.Target.ContainerInstanceID {
		return errors.New("runtime execution acquire recovery changed target")
	}
	return s.markHostExecutionAcquired(key, record.ExecutionID, execution.Target)
}

func exactHostExecutionPresent(result map[string]any, execution externalRuntimeActiveExecution, executionID string) (bool, error) {
	if stringParam(result, "allocation_authority") != execution.Target.AllocationID ||
		stringParam(result, "container_instance_id") != execution.Target.ContainerInstanceID {
		return false, errors.New("runtime execution Host observation is not current")
	}
	status := stringParam(result, "status")
	if status == "EXECUTION_LIST_STATUS_EMPTY" {
		return false, nil
	}
	if status != "EXECUTION_LIST_STATUS_PRESENT" {
		return false, errors.New("runtime execution Host observation is not current")
	}
	expectedOwner := fmt.Sprintf("%s:%d", execution.Target.RuntimeInstanceID, execution.Target.RuntimeGeneration)
	for _, item := range sliceMapParam(result, "executions") {
		if stringParam(item, "execution_id") == executionID &&
			stringParam(item, "owner") == expectedOwner &&
			stringParam(item, "kind") == "EXECUTION_KIND_MAIN_EXECUTION" {
			return true, nil
		}
	}
	return false, nil
}

// reconcileHostOrphans observes Host-owned main executions that have no local
// active record. They are never released or adopted: without the durable
// capability/native record the Connector cannot prove ownership. Host's stable
// acquired timestamp supplies the recovery budget, so reconnects cannot reset
// the action-required deadline.
func (s *externalRuntimeState) reconcileHostOrphans(ctx context.Context) error {
	if !s.connector.requiresHostRuntimeExecution() || s.connector.getActiveTransport() == nil {
		return nil
	}
	target, err := externalRuntimeExecutionTargetFromMap(s.connector.currentComputeRuntimeExecutionTarget())
	if err != nil {
		return err
	}
	result, err := s.connector.runtimeExecution(ctx, "list", "", target.mapValue())
	if err != nil {
		return err
	}
	if stringParam(result, "allocation_authority") != target.AllocationID ||
		stringParam(result, "container_instance_id") != target.ContainerInstanceID {
		return errors.New("runtime execution Host orphan observation is not current")
	}
	status := stringParam(result, "status")
	if status != "EXECUTION_LIST_STATUS_EMPTY" && status != "EXECUTION_LIST_STATUS_PRESENT" {
		return errors.New("runtime execution Host orphan observation is not available")
	}

	now := time.Now().Unix()
	expectedOwner := fmt.Sprintf("%s:%d", target.RuntimeInstanceID, target.RuntimeGeneration)
	operationRights := s.connector.runtimeOperations.snapshot()
	s.mu.Lock()
	defer s.mu.Unlock()
	local := make(map[string]struct{}, len(s.activeExecutions))
	for _, execution := range s.activeExecutions {
		if execution.Version == 3 && execution.Target == target {
			local[execution.Session.ExecutionID] = struct{}{}
		}
	}
	for _, right := range operationRights {
		observed, parseErr := externalRuntimeExecutionTargetFromMap(right.Target)
		if parseErr == nil && observed == target {
			local[right.ActivityID] = struct{}{}
		}
	}
	next := make(map[string]externalRuntimeHostOrphan)
	for _, item := range sliceMapParam(result, "executions") {
		id := stringParam(item, "execution_id")
		if id == "" || stringParam(item, "owner") != expectedOwner {
			continue
		}
		if _, exists := local[id]; exists {
			continue
		}
		acquiredAt := int64Param(item, "acquired_unix_nano", 0) / int64(time.Second)
		actionRequired := acquiredAt <= 0 || now-acquiredAt >= int64(externalRuntimeRecoveryBudget/time.Second)
		orphan := externalRuntimeHostOrphan{ExecutionID: id, AcquiredAt: acquiredAt, ActionRequired: actionRequired}
		next[id] = orphan
		if actionRequired && !s.hostOrphans[id].ActionRequired {
			logf("external runtime Host orphan requires action execution=%s age_seconds=%d issue=runtime_recovery_expired", id, max(int64(0), now-acquiredAt))
		}
	}
	s.hostOrphans = next
	return nil
}

func (s *externalRuntimeState) markHostExecutionAcquired(key, executionID string, target externalRuntimeExecutionTarget) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	current, exists := s.activeExecutions[key]
	if !exists || current.Session.ExecutionID != executionID || current.Target != target {
		return errors.New("runtime execution acquire recovery fence changed")
	}
	current.HostAcquired = true
	_, err := s.storeActiveExecutionLocked(externalRuntimeIdentityFromRecovery(current.Session), current)
	return err
}

func (s *externalRuntimeState) watched(provider, sessionID string) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	_, exists := s.activeExecutions[provider+"\x00"+sessionID]
	return exists
}

// touchSessionActivity records fresh activity for a session identity.
func (s *externalRuntimeState) touchSessionActivity(provider, sessionID string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.touchSessionActivityLocked(provider, sessionID)
}

// touchSessionActivityLocked records fresh activity for a session identity.
// Input batches and runtime events both count: a session that receives either
// is not idle.
func (s *externalRuntimeState) touchSessionActivityLocked(provider, sessionID string) {
	key := provider + "\x00" + sessionID
	identity, ok := s.identities[key]
	if !ok {
		return
	}
	identity.LastActivityAt = time.Now().Unix()
	_ = s.persistIdentityLocked(key, identity)
}

func (s *externalRuntimeState) persistIdentityLocked(key string, identity externalRuntimeSessionIdentity) error {
	raw, err := json.Marshal(externalRuntimeSessionIdentityFile{Version: 2, Identity: identity})
	if err != nil {
		return err
	}
	if err := s.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeIdentitiesBucket).Put([]byte(key), raw)
	}); err != nil {
		return err
	}
	s.identities[key] = identity
	return nil
}

// pruneIdleIdentities is the TTL exit for the long-lived identity ledger. An
// identity is forgotten only when all three hold: it has no active execution,
// its recorded activity is older than externalRuntimeIdentityIdleTTL, and no
// pending input batch exists for its session — the input check runs inside
// the same transaction as the delete, and enqueueInputBatch persists its rows
// under the same mutex, so input staged concurrently always wins. Identities
// predating activity tracking (zero LastActivityAt) get stamped with now on
// first observation and start a fresh idle clock instead of being
// mass-forgotten at unknown age. Stamping deliberately also refreshes the
// workspace archiver's view of the session (sessionActivity starts reporting
// the stamp, so the archiver's workspace-mtime fallback no longer applies): a
// legacy identity's still-unarchived workspace gets up to one more archive
// idle window before it is archived, the price of not trusting unknown ages.
// Executions are never touched here: their bound is the recovery failure
// budget.
//
// One pass performs at most externalRuntimeIdentityPrunePassLimit ledger
// mutations, all inside a single bbolt transaction; the candidate scan walks
// the full in-memory map (no I/O), so the mutex hold is one map scan plus
// one bounded commit. A per-row transaction here blocks live
// input and event staging for seconds at real ledger sizes (multi-second
// stalls measured at the 759-entry rollout cohort). A transaction failure
// aborts the whole pass — bolt rolls back, the in-memory maps are untouched,
// and the next hourly pass retries.
func (s *externalRuntimeState) pruneIdleIdentities(now int64) (stamped, pruned int) {
	if s.db == nil {
		return 0, 0
	}
	ttl := int64(externalRuntimeIdentityIdleTTL / time.Second)
	s.mu.Lock()
	stampKeys := make([]string, 0)
	expireKeys := make([]string, 0)
	for key, identity := range s.identities {
		if boolParam(identity.Payload, "require_native_resume") {
			continue
		}
		if len(stampKeys)+len(expireKeys) >= externalRuntimeIdentityPrunePassLimit {
			break
		}
		if _, active := s.activeExecutions[key]; active {
			continue
		}
		if identity.LastActivityAt == 0 {
			stampKeys = append(stampKeys, key)
			continue
		}
		if now-identity.LastActivityAt > ttl {
			expireKeys = append(expireKeys, key)
		}
	}
	if len(stampKeys) == 0 && len(expireKeys) == 0 {
		s.mu.Unlock()
		return 0, 0
	}
	stampedIdentities := make(map[string]externalRuntimeSessionIdentity, len(stampKeys))
	removedKeys := make([]string, 0, len(expireKeys))
	err := s.db.Update(func(tx *bolt.Tx) error {
		identities := tx.Bucket(externalRuntimeIdentitiesBucket)
		for _, key := range stampKeys {
			identity := s.identities[key]
			identity.LastActivityAt = now
			raw, err := json.Marshal(externalRuntimeSessionIdentityFile{Version: 2, Identity: identity})
			if err != nil {
				return err
			}
			if err := identities.Put([]byte(key), raw); err != nil {
				return err
			}
			stampedIdentities[key] = identity
		}
		cursor := tx.Bucket(externalRuntimeInputBatchesBucket).Cursor()
		for _, key := range expireKeys {
			seal, err := runtimeMigrationSeal(tx, key)
			if err != nil {
				return err
			}
			if seal != nil {
				continue
			}
			prefix := []byte(key + "\x00")
			if k, _ := cursor.Seek(prefix); k != nil && bytes.HasPrefix(k, prefix) {
				continue
			}
			if err := identities.Delete([]byte(key)); err != nil {
				return err
			}
			removedKeys = append(removedKeys, key)
		}
		return nil
	})
	if err != nil {
		s.mu.Unlock()
		logf("external runtime identity prune failed: %v", err)
		return 0, 0
	}
	for key, identity := range stampedIdentities {
		s.identities[key] = identity
	}
	for _, key := range removedKeys {
		identity := s.identities[key]
		delete(s.identities, key)
		s.removeRuntimeSessionLocked(identity)
		s.refreshRuntimeSessionSnapshotLocked(runtimeSessionTargetKey(identity.Provider, identity.Command))
	}
	if len(removedKeys) > 0 {
		s.markSessionsObservedLocked()
	}
	s.mu.Unlock()
	if len(removedKeys) > 0 {
		s.wakeMetadataPublish()
	}
	return len(stampedIdentities), len(removedKeys)
}

// sessionActivity returns the latest known activity time per session id.
// Sessions absent from the map have no activity record (legacy) and fall
// back to workspace-mtime idleness.
func (s *externalRuntimeState) sessionActivity() map[string]int64 {
	s.mu.Lock()
	defer s.mu.Unlock()
	activity := make(map[string]int64, len(s.identities))
	for _, identity := range s.identities {
		if identity.LastActivityAt == 0 {
			// Zero predates activity tracking: report absence so idleness
			// falls back to workspace mtimes instead of treating the
			// session as idle since the epoch.
			continue
		}
		if previous, ok := activity[identity.SessionID]; !ok || identity.LastActivityAt > previous {
			activity[identity.SessionID] = identity.LastActivityAt
		}
	}
	return activity
}

// workspaceSessionIDs returns the session ids that currently have in-flight
// executions for any provider. Workspace archival treats these as active and
// never packs them.
func (s *externalRuntimeState) workspaceSessionIDs() map[string]bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	sessions := make(map[string]bool, len(s.activeExecutions))
	for _, execution := range s.activeExecutions {
		sessions[execution.Session.SessionID] = true
	}
	return sessions
}

// markExecutionRecovered reopens local input dispatch only after the native
// recovery turn is accepted.
func (s *externalRuntimeState) markExecutionRecovered(provider, sessionID, token string) error {
	key := provider + "\x00" + sessionID
	s.mu.Lock()
	execution, exists := s.activeExecutions[key]
	if !exists || execution.Phase != externalRuntimeExecutionInterrupted {
		s.mu.Unlock()
		return nil
	}
	if execution.Session.Token != token {
		s.mu.Unlock()
		return errors.New("external runtime recovery capability changed")
	}
	execution.Phase = externalRuntimeExecutionStarting
	raw, err := json.Marshal(execution)
	// The recovery receipt shares the existing local lifecycle transaction.
	// No Alert Router, Slack, or additional storage call enters runtime progress.
	// A crash after this commit must not erase the positive recovery evidence.
	// Model: tla/alert_router/RuntimeRecoveryReceipt.tla::Recover.
	id := s.nextID()
	if id.String() <= s.lastID {
		id = ulid.MustNew(ulid.MustParse(s.lastID).Time()+1, ulid.DefaultEntropy())
	}
	event := map[string]any{
		"provider": provider, "type": "status", "name": "runtime_recovered",
		"state": "recovered", "created_at": time.Now().Unix(),
		"dispatch_id":  execution.Session.DispatchID,
		"execution_id": execution.Session.ExecutionID,
	}
	if err == nil {
		err = s.db.Update(func(tx *bolt.Tx) error {
			if err := stampRuntimeFault(tx, event, id.String()); err != nil {
				return err
			}
			receipt, err := json.Marshal(message{ID: id.String(), Type: "request", Method: "external_runtime_event",
				Params: map[string]any{"event_id": id.String(), "capability_token": token, "event": event}})
			if err != nil {
				return err
			}
			if err := tx.Bucket(externalRuntimeActiveExecutionsBucket).Put([]byte(key), raw); err != nil {
				return err
			}
			return tx.Bucket(externalRuntimeSessionEventsBucket).Put([]byte(id.String()), receipt)
		})
	}
	if err == nil {
		s.lastID = id.String()
		s.putActiveExecutionLocked(execution)
	}
	s.mu.Unlock()
	if err == nil {
		s.wake()
	}
	return err
}

func (s *externalRuntimeState) persistedWorkspace(provider, sessionID string) (string, bool, error) {
	s.mu.Lock()
	identity, exists := s.identities[provider+"\x00"+sessionID]
	s.mu.Unlock()
	if exists {
		return identity.Workspace, true, nil
	}
	if s.db == nil {
		return "", false, nil
	}
	prefix := []byte(provider + "\x00" + sessionID + "\x00")
	workspace := ""
	err := s.db.View(func(tx *bolt.Tx) error {
		key, raw := tx.Bucket(externalRuntimeInputBatchesBucket).Cursor().Seek(prefix)
		if raw == nil || !bytes.HasPrefix(key, prefix) {
			return nil
		}
		var batch externalRuntimeInputBatch
		if json.Unmarshal(raw, &batch) != nil || batch.validate() != nil {
			return errors.New("invalid persisted external runtime input batch")
		}
		if batch.Session.key() != provider+"\x00"+sessionID {
			return nil
		}
		workspace = batch.Session.Workspace
		return nil
	})
	return workspace, workspace != "", err
}

func (s *externalRuntimeState) migrateLegacyRecoveryFiles() error {
	dir := filepath.Join(s.connector.runtimeStateRoot(), "external-runtime", "active")
	info, err := os.Lstat(dir)
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("external runtime recovery directory %s must be private", dir)
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		return err
	}
	type legacyRecord struct {
		path    string
		session externalRuntimeRecoveryRecord
	}
	legacy := []legacyRecord{}
	for _, entry := range entries {
		if filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		info, err := os.Lstat(path)
		if err != nil {
			return err
		}
		if !info.Mode().IsRegular() || info.Mode().Perm()&0o077 != 0 {
			return fmt.Errorf("external runtime recovery file %s must be a private regular file", path)
		}
		raw, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		var state externalRuntimeRecoveryFile
		if err := json.Unmarshal(raw, &state); err != nil || state.Version != 1 {
			return errors.New("invalid external runtime recovery file")
		}
		if err := state.Session.validate(); err != nil {
			return err
		}
		if s.connector.runtimeImplementations[state.Session.Provider] == nil {
			return fmt.Errorf("unsupported persisted external runtime provider %q", state.Session.Provider)
		}
		legacy = append(legacy, legacyRecord{path: path, session: state.Session})
	}
	if len(legacy) == 0 {
		return nil
	}
	if err := s.db.Update(func(tx *bolt.Tx) error {
		for _, record := range legacy {
			if err := putMigratedRuntimeIdentity(tx, record.session); err != nil {
				return err
			}
			if err := putMigratedActiveExecution(tx, record.session, nil); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		return err
	}
	for _, record := range legacy {
		if err := os.Remove(record.path); err != nil && !os.IsNotExist(err) {
			return err
		}
	}
	return syncDirectory(dir)
}

func putMigratedRuntimeIdentity(tx *bolt.Tx, record externalRuntimeRecoveryRecord) error {
	identity := externalRuntimeIdentityFromRecovery(record)
	state := externalRuntimeSessionIdentityFile{Version: 2, Identity: identity}
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	bucket := tx.Bucket(externalRuntimeIdentitiesBucket)
	key := []byte(identity.key())
	if existing := bucket.Get(key); existing != nil {
		var current externalRuntimeSessionIdentityFile
		if json.Unmarshal(existing, &current) != nil || current.Version != 2 {
			return fmt.Errorf("conflicting external runtime session identity for %q", identity.key())
		}
		canonical, _ := json.Marshal(current)
		if !bytes.Equal(canonical, raw) {
			return fmt.Errorf("conflicting external runtime session identity for %q", identity.key())
		}
		return nil
	}
	return bucket.Put(key, raw)
}

func putMigratedActiveExecution(
	tx *bolt.Tx,
	record externalRuntimeRecoveryRecord,
	inputBatchIDs []string,
) error {
	state := externalRuntimeActiveExecution{
		Version:       2,
		Phase:         externalRuntimeExecutionInterrupted,
		Session:       record,
		InputBatchIDs: inputBatchIDs,
	}
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	bucket := tx.Bucket(externalRuntimeActiveExecutionsBucket)
	key := []byte(record.key())
	if existing := bucket.Get(key); existing != nil {
		var current externalRuntimeActiveExecution
		if json.Unmarshal(existing, &current) != nil || current.Version != 2 {
			return fmt.Errorf("conflicting external runtime active execution for %q", record.key())
		}
		current.Phase = externalRuntimeExecutionInterrupted
		if len(current.InputBatchIDs) == 0 {
			current.InputBatchIDs = inputBatchIDs
		}
		canonical, _ := json.Marshal(current)
		if !bytes.Equal(canonical, raw) {
			return fmt.Errorf("conflicting external runtime active execution for %q", record.key())
		}
		return nil
	}
	return bucket.Put(key, raw)
}

func (s *externalRuntimeState) migrateLegacyRuntimeSessions() error {
	identities, active := 0, 0
	err := s.db.Update(func(tx *bolt.Tx) error {
		legacy := tx.Bucket(externalRuntimeSessionsBucket)
		if legacy == nil {
			return nil
		}
		// Classify the legacy cross-product in O(events + sessions). Re-scanning
		// the event outbox for every session would hold this startup transaction
		// for O(events * sessions) work on a large recovered database.
		evidence := legacyRuntimeExecutionEvidenceIndex(tx.Bucket(externalRuntimeSessionEventsBucket))
		if err := legacy.ForEach(func(key, raw []byte) error {
			var state externalRuntimeRecoveryFile
			if json.Unmarshal(raw, &state) != nil || state.Version != 1 || state.Session.validate() != nil {
				return errors.New("invalid external runtime recovery state")
			}
			if string(key) != state.Session.key() {
				return errors.New("external runtime recovery state key mismatch")
			}
			if err := putMigratedRuntimeIdentity(tx, state.Session); err != nil {
				return err
			}
			identities++
			needsRecovery, err := migrateLegacyRuntimeExecution(tx, state.Session, evidence)
			if err != nil {
				return err
			}
			if tx.Bucket(externalRuntimeActiveExecutionsBucket).Get(key) == nil && needsRecovery {
				inputBatchIDs, err := legacyRuntimeInputBatchIDs(tx, state.Session)
				if err != nil {
					return err
				}
				if err := putMigratedActiveExecution(tx, state.Session, inputBatchIDs); err != nil {
					return err
				}
				active++
			}
			return nil
		}); err != nil {
			return err
		}
		return tx.DeleteBucket(externalRuntimeSessionsBucket)
	})
	if err == nil && identities > 0 {
		logf("migrated legacy external runtime sessions identities=%d active_executions=%d", identities, active)
	}
	return err
}

type legacyRuntimeExecutionEvidence struct {
	terminal bool
}

func legacyRuntimeExecutionEvidenceIndex(bucket *bolt.Bucket) map[string]legacyRuntimeExecutionEvidence {
	evidence := map[string]legacyRuntimeExecutionEvidence{}
	_ = bucket.ForEach(func(_, raw []byte) error {
		var request message
		if json.Unmarshal(raw, &request) != nil {
			return nil
		}
		event := mapParam(request.Params, "event")
		key := legacyRuntimeExecutionEvidenceKey(
			stringParam(request.Params, "capability_token"),
			stringParam(event, "dispatch_id"),
			stringParam(event, "execution_id"),
		)
		if key == "" {
			return nil
		}
		current := evidence[key]
		switch stringParam(event, "work_state") {
		case externalRuntimeExecutionSettled:
			current.terminal = true
		case "failed":
			if slices.Contains([]string{"turn/completed", "turn.ended", "agent_settled"}, stringParam(event, "name")) {
				current.terminal = true
			}
		}
		evidence[key] = current
		return nil
	})
	return evidence
}

func legacyRuntimeExecutionEvidenceKey(token, dispatchID, executionID string) string {
	if token == "" || dispatchID == "" || executionID == "" {
		return ""
	}
	return token + "\x00" + dispatchID + "\x00" + executionID
}

func migrateLegacyRuntimeExecution(
	tx *bolt.Tx,
	record externalRuntimeRecoveryRecord,
	evidence map[string]legacyRuntimeExecutionEvidence,
) (bool, error) {
	current := evidence[legacyRuntimeExecutionEvidenceKey(record.Token, record.DispatchID, record.ExecutionID)]
	if current.terminal {
		return false, deleteLegacyTerminalInputBatch(tx, record)
	}
	// active-sessions-v1 was itself the old recovery obligation. An ACKed
	// running event has already left the outbox, so missing local event evidence
	// is ambiguous rather than proof of settlement. Conservatively preserve the
	// obligation once during migration; v2 terminal settlement deletes the
	// active fact atomically and does not need this inference again.
	return true, nil
}

func deleteLegacyTerminalInputBatch(tx *bolt.Tx, record externalRuntimeRecoveryRecord) error {
	inputBatchIDs, err := legacyRuntimeInputBatchIDs(tx, record)
	if err != nil || len(inputBatchIDs) == 0 {
		return err
	}
	return deleteRuntimeInputBatchRows(tx, record.key(), record.Token, inputBatchIDs)
}

func legacyRuntimeInputBatchIDs(
	tx *bolt.Tx,
	record externalRuntimeRecoveryRecord,
) ([]string, error) {
	key := []byte(record.key() + "\x00" + record.DispatchID)
	raw := tx.Bucket(externalRuntimeInputBatchesBucket).Get(key)
	if raw == nil {
		return nil, nil
	}
	batch, err := decodeExternalRuntimeInputBatch(key, raw)
	if err != nil {
		return nil, err
	}
	// input-batches-v1 is persisted before native Send allocates an execution
	// id. Correlate the pre-native side through the stable session, dispatch,
	// provider, and capability; execution id belongs only to the post-native
	// active/event side of the legacy join.
	if batch.Session.key() != record.key() ||
		batch.Session.DispatchID != record.DispatchID ||
		batch.Session.Token != record.Token {
		return nil, nil
	}
	return []string{batch.Session.DispatchID}, nil
}

// normalizeActiveExecutions upgrades pre-claim v2 rows at Connector restart.
// A row with no native execution identity safely
// returns to its durable inbox. Once an execution identity exists, the
// provider must recover its native binding, or retry its original durable input
// when binding-before-delivery proves that no native input was submitted. Host
// acquisition fences survive either path.
func (s *externalRuntimeState) normalizeActiveExecutions() (int, error) {
	released := 0
	err := s.db.Update(func(tx *bolt.Tx) error {
		bucket := tx.Bucket(externalRuntimeActiveExecutionsBucket)
		deletes := [][]byte{}
		rewrites := map[string][]byte{}
		if err := bucket.ForEach(func(key, raw []byte) error {
			var execution externalRuntimeActiveExecution
			if json.Unmarshal(raw, &execution) != nil || execution.validate() != nil ||
				string(key) != execution.key() {
				return errors.New("invalid external runtime active execution")
			}
			if len(execution.InputBatchIDs) == 0 && execution.Session.DispatchID != "" {
				inputBatchIDs, err := legacyRuntimeInputBatchIDs(tx, execution.Session)
				if err != nil {
					return err
				}
				execution.InputBatchIDs = inputBatchIDs
			}
			if execution.Version == 4 {
				// A recovered native turn is not an ACK for the interrupted
				// input delivery. Retain its inbox rows for at-least-once replay
				// after native recovery, but release the dead process's claim.
				if !unstartedRuntimeInput(execution) {
					execution.InputBatchIDs = nil
				}
			}
			if execution.Version == 3 {
				if execution.RecoveryStartedAt <= 0 {
					execution.RecoveryStartedAt = time.Now().Unix()
				}
				if execution.Phase != externalRuntimeExecutionSettling {
					execution.Phase = externalRuntimeExecutionInterrupted
				}
				encoded, err := json.Marshal(execution)
				if err != nil {
					return err
				}
				rewrites[string(key)] = encoded
				return nil
			}
			if len(execution.InputBatchIDs) > 0 {
				if execution.Session.ExecutionID == "" {
					deletes = append(deletes, bytes.Clone(key))
					released++
					return nil
				}
			}
			execution.Phase = externalRuntimeExecutionInterrupted
			encoded, err := json.Marshal(execution)
			if err != nil {
				return err
			}
			rewrites[string(key)] = encoded
			return nil
		}); err != nil {
			return err
		}
		for _, key := range deletes {
			if err := bucket.Delete(key); err != nil {
				return err
			}
		}
		for key, raw := range rewrites {
			if err := bucket.Put([]byte(key), raw); err != nil {
				return err
			}
		}
		return nil
	})
	return released, err
}

func syncDirectory(dir string) error {
	directory, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}

func canonicalExternalRuntimeEvent(event map[string]any) (map[string]any, error) {
	provider := strings.ToLower(strings.TrimSpace(stringParam(event, "provider")))
	eventType := strings.ToLower(strings.TrimSpace(stringParam(event, "type")))
	createdAt := int64Param(event, "created_at", 0)
	if !slices.Contains([]string{"codex", "pi", "kimi", "claude"}, provider) || createdAt <= 0 {
		return nil, errors.New("invalid external runtime event identity")
	}
	canonical := map[string]any{"provider": provider, "type": eventType, "created_at": createdAt}
	dispatchID := strings.TrimSpace(stringParam(event, "dispatch_id"))
	executionID := strings.TrimSpace(stringParam(event, "execution_id"))
	if (dispatchID == "") != (executionID == "") {
		return nil, errors.New("invalid external runtime event correlation identity")
	}
	if dispatchID != "" {
		canonical["dispatch_id"], canonical["execution_id"] = dispatchID, executionID
	}
	// Preserve the local owner's self-contained receipt across outbox reopen.
	// Native adapters never supply these fields; stampRuntimeFault owns them.
	if episode := stringParam(event, "fault_episode_id"); episode != "" {
		if _, err := ulid.ParseStrict(episode); err != nil {
			return nil, errors.New("invalid fault episode")
		}
		started := int64Param(event, "fault_started_at", 0)
		priority := stringParam(event, "fault_priority")
		if started <= 0 || (priority != "P0" && priority != "P1") {
			return nil, errors.New("invalid fault snapshot")
		}
		canonical["fault_episode_id"], canonical["fault_started_at"], canonical["fault_priority"] = episode, started, priority
	}
	workState := strings.TrimSpace(stringParam(event, "work_state"))
	if workState != "" {
		if !slices.Contains([]string{"running", "settled", "failed"}, workState) ||
			dispatchID == "" {
			return nil, errors.New("invalid external runtime event lifecycle identity")
		}
		canonical["work_state"] = workState
	}
	_, hasContent := event["content"]
	_, hasUsage := event["usage"].(map[string]any)
	valid := (eventType == "message" && stringParam(event, "role") == "assistant" && hasContent) ||
		(eventType == "thinking" && hasContent) ||
		(eventType == "operation" && strings.TrimSpace(stringParam(event, "name")) != "") ||
		(eventType == "status" && strings.TrimSpace(stringParam(event, "state")) != "") ||
		(eventType == "error" && strings.TrimSpace(stringParam(event, "message")) != "") ||
		(eventType == "usage" && hasUsage)
	if !valid {
		return nil, errors.New("invalid external runtime event shape")
	}
	name := strings.TrimSpace(stringParam(event, "name"))
	if name != "" {
		canonical["name"] = boundedRuntimeEventText(name, 1024)
	}
	switch eventType {
	case "message":
		canonical["role"] = "assistant"
		canonical["content"] = boundedRuntimeEventText(stringParam(event, "content"), externalRuntimeEventContentMaxBytes)
	case "thinking":
		canonical["content"] = boundedRuntimeEventText(stringParam(event, "content"), externalRuntimeEventContentMaxBytes)
	case "error":
		if code := strings.TrimSpace(stringParam(event, "code")); code != "" {
			canonical["code"] = boundedRuntimeEventText(code, 1024)
		}
		canonical["message"] = boundedRuntimeEventText(stringParam(event, "message"), externalRuntimeEventDetailMaxBytes)
	case "operation":
		for _, key := range []string{"operation_id", "status"} {
			if value := strings.TrimSpace(stringParam(event, key)); value != "" {
				canonical[key] = boundedRuntimeEventText(value, 1024)
			}
		}
		if input := compactRuntimeMetadata(event["input"]); input != nil {
			canonical["input"] = input
		}
		if event["output"] != nil {
			canonical["output"] = summarizeRuntimeOutput(event["output"])
		}
	case "status":
		canonical["state"] = boundedRuntimeEventText(stringParam(event, "state"), 1024)
		if reason := strings.TrimSpace(stringParam(event, "reason")); reason != "" {
			canonical["reason"] = boundedRuntimeEventText(reason, 1024)
		}
	}
	if usage, ok := event["usage"].(map[string]any); ok {
		canonical["usage"] = usage
	}
	if workState == "failed" {
		issue := strings.TrimSpace(stringParam(event, "issue"))
		if validRuntimeFailureIssue(issue) {
			canonical["issue"] = issue
			canonical["message"] = runtimeFailureMessage(provider, issue)
		} else {
			issue, message := normalizeRuntimeFailure(
				provider, stringParam(event, "code"), stringParam(event, "message"),
			)
			canonical["issue"], canonical["message"] = issue, message
		}
		canonical["usage_reset_at"] = event["usage_reset_at"]
		canonical["message"] = runtimeFailureResetMessage(canonical,
			stringParam(canonical, "issue"), stringParam(canonical, "message"))
	}
	raw, err := json.Marshal(canonical)
	if err == nil && len(raw) > externalRuntimeEventMaxBytes && eventType != "usage" {
		delete(canonical, "input")
		delete(canonical, "usage")
		raw, err = json.Marshal(canonical)
	}
	if err != nil || len(raw) > externalRuntimeEventMaxBytes {
		return nil, errors.New("external runtime event exceeds the durable metadata bound")
	}
	return canonical, nil
}

func boundedRuntimeEventText(value string, limit int) string {
	value = strings.ToValidUTF8(value, "�")
	for len(value) > limit && !utf8.ValidString(value[:limit]) {
		limit--
	}
	return value[:min(len(value), limit)]
}

func compactRuntimeMetadata(value any) map[string]any {
	source, _ := value.(map[string]any)
	metadata := map[string]any{}
	for _, key := range runtimeOperationMetadataFields {
		switch value := source[key].(type) {
		case string:
			metadata[key] = boundedRuntimeEventText(value, 1024)
		case bool, float64, float32, int, int32, int64, uint, uint32, uint64, json.Number:
			metadata[key] = value
		case []any:
			items := make([]any, 0, min(len(value), 16))
			for _, item := range value[:min(len(value), 16)] {
				switch item := item.(type) {
				case string:
					items = append(items, boundedRuntimeEventText(item, 1024))
				case bool, float64, float32, int, int32, int64, uint, uint32, uint64, json.Number:
					items = append(items, item)
				}
			}
			if len(items) > 0 {
				metadata[key] = items
			}
		}
	}
	if len(metadata) == 0 {
		return nil
	}
	return metadata
}

func summarizeRuntimeOutput(value any) map[string]any {
	metadata := compactRuntimeMetadata(value)
	if metadata["omitted"] == true && intFromAny(metadata["json_bytes"], -1) >= 0 {
		return metadata
	}
	raw, _ := json.Marshal(value)
	summary := map[string]any{"omitted": true, "json_bytes": len(raw)}
	maps.Copy(summary, metadata)
	return summary
}

func migratePersistedRuntimeEvents(bucket *bolt.Bucket) error {
	keys := [][]byte{}
	if err := bucket.ForEach(func(key, _ []byte) error {
		keys = append(keys, bytes.Clone(key))
		return nil
	}); err != nil {
		return err
	}
	for _, key := range keys {
		raw := bytes.Clone(bucket.Get(key))
		var request message
		decodeErr := json.Unmarshal(raw, &request)
		canonical, eventErr := canonicalExternalRuntimeEvent(mapParam(request.Params, "event"))
		if decodeErr != nil || request.Method != "external_runtime_event" ||
			request.ID != string(key) || stringParam(request.Params, "event_id") != string(key) ||
			strings.TrimSpace(stringParam(request.Params, "capability_token")) == "" || eventErr != nil {
			if err := bucket.Delete(key); err != nil {
				return err
			}
			continue
		}
		request.Params["event"] = canonical
		canonicalRaw, _ := json.Marshal(request)
		if bytes.Equal(raw, canonicalRaw) {
			continue
		}
		request.Params[migratedExternalRuntimeEventLegacyKey] = true
		canonicalRaw, _ = json.Marshal(request)
		if err := bucket.Put(key, canonicalRaw); err != nil {
			return err
		}
	}
	return nil
}

func (s *externalRuntimeState) enqueue(token string, event map[string]any) error {
	return s.enqueueExecutionEvent("", "", token, event, "")
}

// enqueueExecutionEvent owns the local native-work settlement boundary:
// lifecycle evidence, inbox acceptance, and active retirement share one tx.
func (s *externalRuntimeState) enqueueExecutionEvent(
	provider, sessionID, token string,
	event map[string]any,
	transition string,
) error {
	if s.db == nil {
		return errExternalRuntimeStateDisabled
	}
	event, err := canonicalExternalRuntimeEvent(event)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.touchSessionActivityLocked(provider, sessionID)
	id := s.nextID()
	if id.String() <= s.lastID {
		id = ulid.MustNew(ulid.MustParse(s.lastID).Time()+1, ulid.DefaultEntropy())
	}
	s.lastID = id.String()
	request := message{ID: s.lastID, Type: "request", Method: "external_runtime_event", Params: map[string]any{
		"event_id": s.lastID, "capability_token": token, "event": event,
	}}
	key := provider + "\x00" + sessionID
	current, hasCurrent := s.activeExecutions[key]
	matchesCurrent := hasCurrent && runtimeExecutionEventMatches(current.Session, event)
	updated := current
	settleActive := false
	deleteLegacyActive := false
	acceptInput := false
	if matchesCurrent && transition != "" && transition != externalRuntimeExecutionSettled {
		updated.Phase = transition
		if transition == externalRuntimeExecutionRunning && inputClaimIsBound(current) {
			updated.InputBatchIDs = nil
			acceptInput = true
		}
	} else if matchesCurrent && transition == externalRuntimeExecutionSettled {
		if current.Version == 3 && current.HostAcquired {
			settleActive = true
			updated.Phase = externalRuntimeExecutionSettling
			updated.TerminalEventID = s.lastID
			updated.SettlingStartedAt = time.Now().Unix()
			if inputClaimIsBound(current) {
				updated.InputBatchIDs = nil
			}
		} else if current.Version == 2 || current.Version == 4 {
			// Direct Connector and legacy version 2 records have no Host rights or
			// exact target to release, so their native terminal event remains
			// the settlement boundary without a Host release.
			deleteLegacyActive = true
		} else {
			return errors.New("terminal runtime execution has no acquired Host target")
		}
	}
	// A native running callback may race ahead of Check's successful return.
	// It is itself recovery acceptance for the interrupted exact execution;
	// persist the receipt here before advancing Phase so Check cannot lose it.
	receiptID := ""
	var recoveryEvent map[string]any
	if matchesCurrent && current.Phase == externalRuntimeExecutionInterrupted && transition == externalRuntimeExecutionRunning {
		receiptULID := s.nextID()
		if receiptULID.String() <= s.lastID {
			receiptULID = ulid.MustNew(ulid.MustParse(s.lastID).Time()+1, ulid.DefaultEntropy())
		}
		receiptID = receiptULID.String()
		recoveryEvent = map[string]any{
			"provider": current.Session.Provider, "type": "status", "name": "runtime_recovered",
			"state": "recovered", "created_at": event["created_at"],
			"dispatch_id": current.Session.DispatchID, "execution_id": current.Session.ExecutionID,
		}
	}
	if err := s.db.Update(func(tx *bolt.Tx) error {
		if err := stampRuntimeFault(tx, event, id.String()); err != nil {
			return err
		}
		raw, err := json.Marshal(request)
		if err != nil {
			return err
		}
		if err := tx.Bucket(externalRuntimeSessionEventsBucket).Put([]byte(s.lastID), raw); err != nil {
			return err
		}
		if receiptID != "" {
			if err := stampRuntimeFault(tx, recoveryEvent, receiptID); err != nil {
				return err
			}
			receipt, err := json.Marshal(message{ID: receiptID, Type: "request", Method: "external_runtime_event",
				Params: map[string]any{"event_id": receiptID, "capability_token": token, "event": recoveryEvent}})
			if err != nil {
				return err
			}
			if err := tx.Bucket(externalRuntimeSessionEventsBucket).Put([]byte(receiptID), receipt); err != nil {
				return err
			}
		}
		if !matchesCurrent || transition == "" {
			return nil
		}
		if settleActive || deleteLegacyActive {
			if inputClaimIsBound(current) {
				if err := deleteRuntimeInputBatchRows(
					tx, key, current.Session.Token, current.InputBatchIDs,
				); err != nil {
					return err
				}
			}
			if deleteLegacyActive {
				return tx.Bucket(externalRuntimeActiveExecutionsBucket).Delete([]byte(key))
			}
			encoded, err := json.Marshal(updated)
			if err != nil {
				return err
			}
			return tx.Bucket(externalRuntimeActiveExecutionsBucket).Put([]byte(key), encoded)
		}
		if acceptInput {
			if err := deleteRuntimeInputBatchRows(
				tx, key, current.Session.Token, current.InputBatchIDs,
			); err != nil {
				return err
			}
		}
		encoded, err := json.Marshal(updated)
		if err != nil {
			return err
		}
		return tx.Bucket(externalRuntimeActiveExecutionsBucket).Put([]byte(key), encoded)
	}); err != nil {
		return err
	}
	if matchesCurrent {
		if deleteLegacyActive {
			s.deleteActiveExecutionLocked(key)
		} else if transition != "" {
			s.putActiveExecutionLocked(updated)
		}
	}
	if receiptID != "" {
		s.lastID = receiptID
	}
	s.wake()
	return nil
}

func runtimeExecutionEventMatches(record externalRuntimeRecoveryRecord, event map[string]any) bool {
	dispatchID := stringParam(event, "dispatch_id")
	executionID := stringParam(event, "execution_id")
	if record.DispatchID == "" && record.ExecutionID == "" {
		return dispatchID == "" && executionID == ""
	}
	return record.DispatchID == dispatchID && record.ExecutionID == executionID
}

func (s *externalRuntimeState) wakeSettlement() {
	select {
	case s.settlementWakeup <- struct{}{}:
	default:
	}
}

func (s *externalRuntimeState) wake() {
	s.wakeSettlement()
	select {
	case s.eventWakeup <- struct{}{}:
	default:
	}
	select {
	case s.inputWakeup <- struct{}{}:
	default:
	}
}

func (s *externalRuntimeState) close() {
	s.cancel()
	s.worker.Wait()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.db != nil {
		_ = s.db.Close()
	}
}

// The durable batch/partial-ACK protocol and retry scheduler below are modeled
// in tla/salix/ExternalRuntimeEventBatch.tla and
// tla/salix/ExternalRuntimeEventRetryFairness.tla.
func (s *externalRuntimeState) run() {
	var current *runtimeTransport
	after := ""
	scanEnd := ""
	retryAfter := map[string]time.Time{}
	rescanDue := false
	retry := time.NewTicker(externalRuntimeEventRetryInterval)
	defer retry.Stop()
	for {
		select {
		case <-s.eventWakeup:
		case <-retry.C:
			rescanDue = runtimeEventSessionsDue(retryAfter, time.Now()) || rescanDue
		case <-s.ctx.Done():
			return
		}
		for {
			select {
			case <-retry.C:
				rescanDue = runtimeEventSessionsDue(retryAfter, time.Now()) || rescanDue
			default:
			}
			transport := s.connector.getActiveTransport()
			if transport == nil {
				break
			}
			if transport != current {
				current, after, scanEnd = transport, "", ""
				clear(retryAfter)
				rescanDue = false
			}
			if rescanDue && scanEnd == "" {
				releaseDueRuntimeEventSessions(retryAfter, time.Now())
				after, rescanDue = "", false
			}
			if scanEnd == "" {
				var err error
				scanEnd, err = s.eventScanEnd()
				if err != nil {
					logf("read external runtime event outbox tail failed: %v", err)
					break
				}
				if scanEnd == "" {
					break
				}
			}
			previousAfter := after
			batch, scannedThrough, err := s.nextBatch(after, scanEnd, retryAfter)
			if err != nil {
				logf("read external runtime event outbox failed: %v", err)
				break
			}
			if scannedThrough > after {
				after = scannedThrough
			}
			if len(batch) == 0 {
				if after != previousAfter {
					continue
				}
				if rescanDue {
					releaseDueRuntimeEventSessions(retryAfter, time.Now())
					after, scanEnd, rescanDue = "", "", false
					continue
				}
				scanEnd = ""
				break
			}
			retries := s.deliverBatch(transport, batch)
			for _, item := range batch {
				delete(retryAfter, externalRuntimeEventSession(item))
			}
			now := time.Now()
			for session, delay := range retries {
				retryAfter[session] = now.Add(delay)
				if delay <= 0 {
					rescanDue = true
				}
			}
		}
	}
}

// One worker owns Host release. A slow release does not delay terminal delivery.
func (s *externalRuntimeState) runSettlements() {
	retry := time.NewTicker(externalRuntimeSettlementRetryInterval)
	defer retry.Stop()
	for {
		select {
		case <-s.settlementWakeup:
		case <-retry.C:
		case <-s.ctx.Done():
			return
		}
		s.settleRuntimeExecution()
	}
}

func (s *externalRuntimeState) settleRuntimeExecution() {
	if s.connector.getActiveTransport() == nil {
		return
	}
	s.mu.Lock()
	if s.settlementInFlight {
		s.mu.Unlock()
		return
	}
	keys := make([]string, 0, len(s.activeExecutions))
	for key, execution := range s.activeExecutions {
		if execution.Version == 3 && execution.Phase == externalRuntimeExecutionSettling {
			keys = append(keys, key)
		}
	}
	sort.Strings(keys)
	start := sort.Search(len(keys), func(i int) bool { return keys[i] > s.settlementCursor })
	now := time.Now()
	var key string
	var execution externalRuntimeActiveExecution
	for offset := range len(keys) {
		candidate := keys[(start+offset)%len(keys)]
		value := s.activeExecutions[candidate]
		if s.settlementRetryAfter[candidate].After(now) ||
			(value.SettlementIssue != "" && value.SettlementIssue != "execution_settlement_unknown") {
			continue
		}
		if value.SettlementIssue == "" && (value.SettlingStartedAt <= 0 ||
			now.Unix()-value.SettlingStartedAt >= int64(externalRuntimeSettlementBudget/time.Second)) {
			value.SettlementIssue = "execution_settlement_unknown"
			if _, err := s.storeActiveExecutionLocked(externalRuntimeIdentityFromRecovery(value.Session), value); err != nil {
				logf("runtime execution settlement failure persistence failed provider=%s session=%s execution=%s: %v", value.Session.Provider, value.Session.SessionID, value.Session.ExecutionID, err)
			} else {
				logf("runtime execution settlement requires action provider=%s session=%s execution=%s issue=%s", value.Session.Provider, value.Session.SessionID, value.Session.ExecutionID, value.SettlementIssue)
			}
		}
		acked := false
		_ = s.db.View(func(tx *bolt.Tx) error {
			acked = tx.Bucket(externalRuntimeSessionEventsBucket).Get([]byte(value.TerminalEventID)) == nil
			return nil
		})
		if acked {
			key, execution = candidate, value
			s.settlementCursor = candidate
			s.settlementInFlight = true
			break
		}
	}
	s.mu.Unlock()
	if key == "" {
		return
	}
	defer func() {
		s.mu.Lock()
		s.settlementInFlight = false
		if current, ok := s.activeExecutions[key]; ok && current.Session.ExecutionID == execution.Session.ExecutionID {
			s.settlementRetryAfter[key] = time.Now().Add(externalRuntimeSettlementRetryInterval)
		}
		s.mu.Unlock()
		s.wakeSettlement()
	}()
	ctx, cancel := context.WithTimeout(s.ctx, 20*time.Second)
	result, err := s.connector.runtimeExecution(
		ctx, "release", execution.Session.ExecutionID, execution.Target.mapValue(),
	)
	cancel()
	if err != nil || !boolParam(result, "released") {
		if err != nil {
			logf("runtime execution release deferred provider=%s session=%s execution=%s: %v", execution.Session.Provider, execution.Session.SessionID, execution.Session.ExecutionID, err)
		}
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	current, ok := s.activeExecutions[key]
	if !ok || current.Phase != externalRuntimeExecutionSettling ||
		current.Session.ExecutionID != execution.Session.ExecutionID ||
		current.TerminalEventID != execution.TerminalEventID {
		return
	}
	if err := s.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeActiveExecutionsBucket).Delete([]byte(key))
	}); err != nil {
		logf("runtime execution release acknowledgement persistence failed provider=%s session=%s execution=%s: %v", execution.Session.Provider, execution.Session.SessionID, execution.Session.ExecutionID, err)
		return
	}
	s.deleteActiveExecutionLocked(key)
	s.wake()
}

func (s *externalRuntimeState) eventScanEnd() (string, error) {
	var end string
	err := s.db.View(func(tx *bolt.Tx) error {
		key, _ := tx.Bucket(externalRuntimeSessionEventsBucket).Cursor().Last()
		end = string(key)
		return nil
	})
	return end, err
}

func runtimeEventSessionsDue(retryAfter map[string]time.Time, now time.Time) bool {
	for _, deadline := range retryAfter {
		if !deadline.After(now) {
			return true
		}
	}
	return false
}

func releaseDueRuntimeEventSessions(retryAfter map[string]time.Time, now time.Time) {
	for session, deadline := range retryAfter {
		if !deadline.After(now) {
			delete(retryAfter, session)
		}
	}
}

func (s *externalRuntimeState) nextBatch(
	after string,
	scanEnd string,
	retryAfter map[string]time.Time,
) ([]message, string, error) {
	items := make([]message, 0, externalRuntimeEventBatchMaxItems)
	encodedBytes := 0
	scannedThrough := after
	err := s.db.View(func(tx *bolt.Tx) error {
		cursor := tx.Bucket(externalRuntimeSessionEventsBucket).Cursor()
		key, value := cursor.Seek(append([]byte(after), 0))
		for scanned := 0; key != nil && string(key) <= scanEnd && len(items) < externalRuntimeEventBatchMaxItems && scanned < externalRuntimeEventScanMaxItems; scanned++ {
			var item message
			if err := json.Unmarshal(value, &item); err != nil {
				return err
			}
			item.ID = string(key)
			if _, deferred := retryAfter[externalRuntimeEventSession(item)]; deferred {
				scannedThrough = item.ID
				key, value = cursor.Next()
				continue
			}
			migratedLegacy := boolParam(item.Params, migratedExternalRuntimeEventLegacyKey)
			if migratedLegacy && len(items) > 0 {
				break
			}
			if len(items) > 0 && encodedBytes+len(value) > externalRuntimeEventBatchMaxBytes {
				break
			}
			items = append(items, item)
			encodedBytes += len(value)
			scannedThrough = item.ID
			if migratedLegacy {
				break
			}
			key, value = cursor.Next()
		}
		return nil
	})
	return items, scannedThrough, err
}

func (s *externalRuntimeState) deliverBatch(transport *runtimeTransport, items []message) map[string]time.Duration {
	completed := make(chan map[string]time.Duration, 1)
	go func() {
		completed <- s.deliverBatchRequest(transport, items)
	}()
	select {
	case retries := <-completed:
		return retries
	case <-transport.done:
		return externalRuntimeEventRetries(items, externalRuntimeEventRetryInterval)
	case <-s.ctx.Done():
		return nil
	}
}

func (s *externalRuntimeState) deliverBatchRequest(transport *runtimeTransport, items []message) map[string]time.Duration {
	request, legacy := externalRuntimeEventRequest(items)
	deliveryTimeout := min(time.Minute, externalRuntimeEventRetryInterval*time.Duration(len(items)))
	started := time.Now()
	ctx, cancel := context.WithTimeout(context.Background(), deliveryTimeout)
	response, err := s.connector.sendRuntimeRequest(ctx, transport, s.ctx.Done(), request)
	cancel()
	if err == nil && (response.Type == "error" || response.Error != "") {
		err = errors.New(defaultString(response.Error, "external runtime event batch rejected"))
	}
	if err != nil {
		logf("external runtime event batch delivery deferred first=%s last=%s count=%d: %v", items[0].ID, items[len(items)-1].ID, len(items), err)
		return externalRuntimeEventRetries(items, max(time.Duration(0), externalRuntimeEventRetryInterval-time.Since(started)))
	}
	settled, err := settledExternalRuntimeEventIDs(response, items, legacy)
	if err != nil {
		logf("external runtime event batch acknowledgement invalid first=%s last=%s count=%d: %v", items[0].ID, items[len(items)-1].ID, len(items), err)
		return externalRuntimeEventRetries(items, externalRuntimeEventRetryInterval)
	}
	settledIDs := map[string]struct{}{}
	for _, id := range append(settled.accepted, settled.permanentlyRejected...) {
		settledIDs[id] = struct{}{}
	}
	retryItems := make([]message, 0, len(items)-len(settledIDs))
	for _, item := range items {
		if _, ok := settledIDs[item.ID]; !ok {
			retryItems = append(retryItems, item)
		}
	}
	settledCount := len(settled.accepted) + len(settled.permanentlyRejected)
	if settledCount != len(items) {
		logf("external runtime event batch partially acknowledged first=%s last=%s accepted=%d permanently_rejected=%d retry=%d", items[0].ID, items[len(items)-1].ID, len(settled.accepted), len(settled.permanentlyRejected), len(items)-settledCount)
	}
	if settledCount == 0 {
		return externalRuntimeEventRetries(retryItems, externalRuntimeEventSessionRetryInterval)
	}
	if err := s.db.Update(func(tx *bolt.Tx) error {
		bucket := tx.Bucket(externalRuntimeSessionEventsBucket)
		for _, id := range append(settled.accepted, settled.permanentlyRejected...) {
			if err := bucket.Delete([]byte(id)); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		logf("external runtime event batch ack persistence failed first=%s last=%s accepted=%d permanently_rejected=%d: %v", items[0].ID, items[len(items)-1].ID, len(settled.accepted), len(settled.permanentlyRejected), err)
		return externalRuntimeEventRetries(items, externalRuntimeEventRetryInterval)
	}
	s.wakeSettlement()
	return externalRuntimeEventRetries(retryItems, externalRuntimeEventSessionRetryInterval)
}

func externalRuntimeEventRetries(items []message, delay time.Duration) map[string]time.Duration {
	retries := map[string]time.Duration{}
	for _, item := range items {
		if session := externalRuntimeEventSession(item); session != "" {
			retries[session] = delay
		}
	}
	return retries
}

func externalRuntimeEventSession(item message) string {
	return strings.TrimSpace(stringParam(item.Params, "capability_token"))
}

func externalRuntimeEventRequest(items []message) (message, bool) {
	if len(items) == 1 && boolParam(items[0].Params, migratedExternalRuntimeEventLegacyKey) {
		request := items[0]
		request.Params = maps.Clone(request.Params)
		delete(request.Params, migratedExternalRuntimeEventLegacyKey)
		return request, true
	}
	requestID := "runtime_events_" + ulid.Make().String()
	params := make([]map[string]any, len(items))
	for index, item := range items {
		params[index] = item.Params
	}
	return message{
		ID:     requestID,
		Type:   "request",
		Method: "external_runtime_events",
		Params: map[string]any{"events": params},
	}, false
}

type externalRuntimeEventSettlement struct {
	accepted            []string
	permanentlyRejected []string
}

func settledExternalRuntimeEventIDs(response message, items []message, legacy bool) (externalRuntimeEventSettlement, error) {
	if legacy {
		return externalRuntimeEventSettlement{accepted: []string{items[0].ID}}, nil
	}
	result, ok := response.Result.(map[string]any)
	if !ok {
		return externalRuntimeEventSettlement{}, errors.New("missing batch result")
	}
	raw, ok := result["accepted_event_ids"].([]any)
	if !ok {
		return externalRuntimeEventSettlement{}, errors.New("missing accepted_event_ids")
	}
	requested := make(map[string]struct{}, len(items))
	for _, item := range items {
		requested[item.ID] = struct{}{}
	}
	accepted := make([]string, 0, len(raw))
	seen := make(map[string]struct{}, len(raw))
	for _, value := range raw {
		id, ok := value.(string)
		if !ok {
			return externalRuntimeEventSettlement{}, errors.New("accepted event id is not a string")
		}
		if _, ok := requested[id]; !ok {
			return externalRuntimeEventSettlement{}, fmt.Errorf("accepted unknown event id %q", id)
		}
		if _, ok := seen[id]; ok {
			return externalRuntimeEventSettlement{}, fmt.Errorf("accepted duplicate event id %q", id)
		}
		seen[id] = struct{}{}
		accepted = append(accepted, id)
	}
	permanentlyRejected := []string{}
	if rejectedRaw, exists := result["permanently_rejected_events"]; exists {
		rejected, ok := rejectedRaw.([]any)
		if !ok {
			return externalRuntimeEventSettlement{}, errors.New("permanently_rejected_events is not a list")
		}
		for _, value := range rejected {
			entry, ok := value.(map[string]any)
			if !ok {
				return externalRuntimeEventSettlement{}, errors.New("permanently rejected event is not an object")
			}
			id, _ := entry["event_id"].(string)
			errorCode, _ := entry["error_code"].(string)
			if id == "" || errorCode == "" {
				return externalRuntimeEventSettlement{}, errors.New("permanently rejected event is missing event_id or error_code")
			}
			if _, ok := requested[id]; !ok {
				return externalRuntimeEventSettlement{}, fmt.Errorf("permanently rejected unknown event id %q", id)
			}
			if _, ok := seen[id]; ok {
				return externalRuntimeEventSettlement{}, fmt.Errorf("batch acknowledgement repeated event id %q", id)
			}
			seen[id] = struct{}{}
			permanentlyRejected = append(permanentlyRejected, id)
		}
	}
	return externalRuntimeEventSettlement{
		accepted:            accepted,
		permanentlyRejected: permanentlyRejected,
	}, nil
}

// Managed resource archives contain an MVCC snapshot, never the open database
// file. Quiet admission guarantees that no accepted inputs or outputs remain.
func (s *externalRuntimeState) writeArchiveSnapshot(out *tar.Writer, remainingBytes int64) error {
	return s.db.View(func(tx *bolt.Tx) error {
		for _, name := range [][]byte{externalRuntimeActiveExecutionsBucket, externalRuntimeInputBatchesBucket, externalRuntimeSessionEventsBucket} {
			if tx.Bucket(name).Stats().KeyN != 0 {
				return errRuntimeNotQuiet
			}
		}
		if tx.Size() > remainingBytes {
			return errors.New("archive expanded size exceeds limit")
		}
		if tx.Size() > maxArchiveFile {
			return errors.New("runtime snapshot exceeds archive file limit")
		}
		if err := out.WriteHeader(&tar.Header{Name: externalRuntimeStateRelativePath, Typeflag: tar.TypeReg, Mode: 0600, Size: tx.Size()}); err != nil {
			return err
		}
		_, err := tx.WriteTo(out)
		return err
	})
}

func (s *externalRuntimeState) emptyArchiveTarget() bool {
	if s == nil || s.db == nil {
		return false
	}
	empty := true
	err := s.db.View(func(tx *bolt.Tx) error {
		return tx.ForEach(func(_ []byte, bucket *bolt.Bucket) error {
			if bucket.Stats().KeyN != 0 {
				empty = false
			}
			return nil
		})
	})
	return err == nil && empty
}

func (s *externalRuntimeState) restoreArchiveSnapshot(path string) error {
	source, err := bolt.Open(path, 0600, &bolt.Options{ReadOnly: true, Timeout: time.Second})
	if err != nil {
		return err
	}
	defer source.Close()
	err = source.View(func(input *bolt.Tx) error {
		for _, name := range [][]byte{externalRuntimeActiveExecutionsBucket, externalRuntimeInputBatchesBucket, externalRuntimeSessionEventsBucket} {
			bucket := input.Bucket(name)
			if bucket == nil || bucket.Stats().KeyN != 0 {
				return errors.New("snapshot contains unresolved runtime work")
			}
		}
		identities := input.Bucket(externalRuntimeIdentitiesBucket)
		if identities == nil {
			return errors.New("snapshot lacks runtime identities")
		}
		if err := identities.ForEach(func(key, raw []byte) error {
			var record externalRuntimeSessionIdentityFile
			if json.Unmarshal(raw, &record) != nil || record.Version != 2 || record.Identity.validate() != nil || string(key) != record.Identity.key() || s.connector.runtimeImplementations[record.Identity.Provider] == nil {
				return errors.New("invalid archived runtime identity")
			}
			return nil
		}); err != nil {
			return err
		}
		return s.db.Update(func(output *bolt.Tx) error {
			if err := output.ForEach(func(_ []byte, bucket *bolt.Bucket) error {
				if bucket.Stats().KeyN != 0 {
					return errors.New("runtime restore target is not empty")
				}
				return nil
			}); err != nil {
				return err
			}
			return input.ForEach(func(name []byte, from *bolt.Bucket) error {
				to, err := output.CreateBucketIfNotExists(name)
				if err != nil {
					return err
				}
				return copyArchiveBucket(to, from)
			})
		})
	})
	if err != nil {
		return err
	}
	return s.load()
}

func copyArchiveBucket(to, from *bolt.Bucket) error {
	if err := to.SetSequence(from.Sequence()); err != nil {
		return err
	}
	return from.ForEach(func(key, value []byte) error {
		if value != nil {
			return to.Put(key, value)
		}
		child, err := to.CreateBucket(key)
		if err != nil {
			return err
		}
		return copyArchiveBucket(child, from.Bucket(key))
	})
}
