package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"syscall"
	"time"
)

type externalRuntimeImplementation interface {
	Send(context.Context, externalRuntimeInput) (map[string]any, string, error)
	Restore(externalRuntimeInput) error
	Check(context.Context, string) error
	// AbandonRecovery is the explicit stop invoked by the health loop when one
	// execution exhausts the recovery failure budget.
	// The durable removal is gated on record's dispatch/execution fence, so a
	// replacement execution that started after the budget tripped is never
	// the one abandoned; obligation and identity are removed together, the
	// terminal observations (the recovery_exhausted failed execution event —
	// also for work whose interruption was already announced — then
	// runtime_stopped) are forwarded even
	// when no native process is alive, and pending inbox rows survive for
	// redelivery into a fresh native session. Returns false when the session
	// is busy right now; the caller retries on a later tick.
	AbandonRecovery(record externalRuntimeRecoveryRecord, reason string) bool
	ReplayObservations()
	Close()
}

const (
	// Bound simultaneous probes and native-process restarts without limiting
	// which active sessions a health pass covers.
	externalRuntimeCheckConcurrency = 8
	externalRuntimeCheckTimeout     = 20 * time.Second
	externalRuntimeProbeTimeout     = 2 * time.Second
	// A recovery obligation whose checks keep failing is abandoned after this
	// many consecutive failed attempts. Without a budget one permanently
	// failing recovery retries forever on the health-loop cadence, keeps
	// re-running expensive app-server restarts, and blocks the session's new
	// input (claimInputBatches rejects input while an interrupted obligation
	// exists). Attempts back off between failures (recoveryBackoffDelayTicks:
	// 1, 2, 4, then externalRuntimeRecoveryBackoffCapTicks health passes), so
	// 12 attempts is ~9 minutes at the 10s cadence when checks fail fast,
	// longer when each attempt burns its 20s timeout — transient
	// interruptions recover far earlier, so only genuinely stuck sessions hit
	// the bound.
	externalRuntimeRecoveryFailureBudget = 12
	// Cap on the number of health passes between two attempts for the same
	// stuck execution: ≈60s at the 10s cadence. The cap bounds how hard a
	// session that keeps failing (or keeps oscillating) can hammer expensive
	// restart work, while an honest recovery after a transient outage is
	// retried within a minute.
	externalRuntimeRecoveryBackoffCapTicks = 6
	externalRuntimeSettlementBudget        = 120 * time.Second
	externalRuntimeRecoveryBudget          = 900 * time.Second
	// After marking a session abandoned and killing its native process, wait
	// this long for the production exit path to finish: an echo it enqueued
	// before observing the abandoned mark then lands before the
	// recovery_exhausted announcement and loses the watermark race.
	externalRuntimeAbandonStopWait       = 3 * time.Second
	externalRuntimeRecoveryAbandonReason = "external runtime recovery attempts exhausted"
	// A resume identity with no active execution, no pending input, and no
	// recorded activity for this long is forgotten. The identity ledger's only
	// other exit is a clean terminal stop, which a conversation that simply
	// went cold never reaches, so without a TTL the ledger grows forever
	// (staging accumulated 759 entries by 2026-08). Losing an identity is the
	// existing degraded path: the next input starts a fresh native thread with
	// the recreated-session notice, server-side conversation history intact.
	// The workspace archiver already treats sessions idle for a fraction of
	// this window (72h default) as cold.
	externalRuntimeIdentityIdleTTL = 30 * 24 * time.Hour
	// How often the health loop looks for expired identities.
	externalRuntimeIdentityPruneInterval = time.Hour
	// Ledger mutations (stamps + expirations) one maintenance pass performs,
	// all in a single transaction: bounds the transaction size and therefore
	// the durable-commit cost. The candidate scan itself still walks the whole
	// in-memory identity map (no I/O), so the mutex hold is one full map scan
	// plus one bounded commit. A backlog larger than this drains across
	// consecutive hourly passes.
	externalRuntimeIdentityPrunePassLimit = 256
	externalRuntimeRecoveryMessage        = "The previous execution was interrupted outside the runtime; the runtime did not choose to stop. " +
		"The same native session has now been restored. Review the existing conversation and workspace, inspect any relevant tool or external-operation state, " +
		"and determine from actual state whether the current work is already complete, should continue, needs repair or a safe retry, or should stop. " +
		"Continue the work and report through the existing task path when appropriate. Do not blindly replay prior commands or assume they failed; verify side effects before retrying."
	externalRuntimeRecreatedMessage = "The previous execution was interrupted outside the runtime; the runtime did not choose to stop. " +
		"The previous native thread could not be found, so a new native thread has been created for the same external session. " +
		"Review the existing conversation and workspace, inspect any relevant tool or external-operation state, and determine from actual state whether the current work is already complete, " +
		"should continue, needs repair or a safe retry, or should stop. Continue the work and report through the existing task path when appropriate. " +
		"Do not blindly replay prior commands or assume they failed; verify side effects before retrying."
	externalRuntimeWorkspaceRestoredMessage = "This session's workspace was automatically archived after a period of inactivity and has just been restored from that archive. " +
		"Regenerable cache and dependency directories (for example node_modules, language build outputs, and tool caches) were excluded from the archive, " +
		"so files in those locations may be missing even though the conversation references them. Verify what is actually present before continuing, " +
		"and regenerate missing dependencies or build artifacts (for example by re-running the package install or build step) as needed. " +
		"Source files, configuration, and everything else that was archived are back in place."
)

type externalRuntimeRecoveryRecord struct {
	Provider        string         `json:"provider"`
	SessionID       string         `json:"session_id"`
	DispatchID      string         `json:"dispatch_id,omitempty"`
	ExecutionID     string         `json:"execution_id,omitempty"`
	Token           string         `json:"runtime_capability_token"`
	Command         string         `json:"command"`
	Workspace       string         `json:"workspace"`
	Model           string         `json:"model,omitempty"`
	ModelProvider   string         `json:"model_provider,omitempty"`
	ReasoningEffort string         `json:"reasoning_effort,omitempty"`
	SystemPrompt    string         `json:"system_prompt,omitempty"`
	Payload         map[string]any `json:"runtime_payload"`
}

type externalRuntimeRecoveryFile struct {
	Version int                           `json:"version"`
	Session externalRuntimeRecoveryRecord `json:"session"`
}

type externalRuntimeSessionIdentity struct {
	Provider  string         `json:"provider"`
	SessionID string         `json:"session_id"`
	Command   string         `json:"command"`
	Workspace string         `json:"workspace"`
	Payload   map[string]any `json:"runtime_payload"`
	// LastActivityAt is the unix time of the most recent input batch or
	// runtime event for this session. Zero means the record predates
	// activity tracking; idleness then falls back to workspace mtimes.
	LastActivityAt int64 `json:"last_activity_at,omitempty"`
}

type externalRuntimeSessionIdentityFile struct {
	Version  int                            `json:"version"`
	Identity externalRuntimeSessionIdentity `json:"identity"`
}

type externalRuntimeActiveExecution struct {
	Version           int                            `json:"version"`
	Phase             string                         `json:"phase"`
	Session           externalRuntimeRecoveryRecord  `json:"session"`
	InputBatchIDs     []string                       `json:"input_batch_ids,omitempty"`
	Target            externalRuntimeExecutionTarget `json:"target,omitempty"`
	HostAcquired      bool                           `json:"host_acquired,omitempty"`
	RecoveryStartedAt int64                          `json:"recovery_started_at,omitempty"`
	TerminalEventID   string                         `json:"terminal_event_id,omitempty"`
	SettlingStartedAt int64                          `json:"settling_started_at,omitempty"`
	SettlementIssue   string                         `json:"settlement_issue,omitempty"`
}

type externalRuntimeHostOrphan struct {
	ExecutionID    string
	AcquiredAt     int64
	ActionRequired bool
}

type externalRuntimeExecutionTarget struct {
	RuntimeInstanceID      string `json:"runtime_instance_id"`
	RuntimeGeneration      int    `json:"runtime_generation"`
	RuntimeConnectionEpoch string `json:"runtime_connection_epoch"`
	WorkloadID             string `json:"workload_id"`
	WorkloadGeneration     int    `json:"workload_generation"`
	AllocationID           string `json:"allocation_id"`
	AllocationGeneration   int    `json:"allocation_generation"`
	ContainerID            string `json:"container_id"`
	ContainerInstanceID    string `json:"container_instance_id"`
}

const (
	externalRuntimeExecutionStarting    = "starting"
	externalRuntimeExecutionRunning     = "running"
	externalRuntimeExecutionInterrupted = "interrupted"
	externalRuntimeExecutionSettling    = "settling"
	externalRuntimeExecutionSettled     = "settled"
)

// setWorkspaceRuntimeNotice stages a one-shot runtime-role notice for the
// next delivery of this session's input. Delivery consumes it only after the
// native Send succeeds.
func (c *connector) setWorkspaceRuntimeNotice(sessionID, notice string) {
	c.workspaceNoticeMu.Lock()
	defer c.workspaceNoticeMu.Unlock()
	c.workspaceRuntimeNotices[sessionID] = notice
}

func (c *connector) peekWorkspaceRuntimeNotice(sessionID string) string {
	c.workspaceNoticeMu.Lock()
	defer c.workspaceNoticeMu.Unlock()
	return c.workspaceRuntimeNotices[sessionID]
}

func (c *connector) clearWorkspaceRuntimeNotice(sessionID string) {
	c.workspaceNoticeMu.Lock()
	defer c.workspaceNoticeMu.Unlock()
	delete(c.workspaceRuntimeNotices, sessionID)
}

// externalRuntimeWorkspaceRestoreFailedMessage tells the agent that the
// automatic workspace restore did not complete, where the intact archive
// lives, and how to recover specific pieces itself if the work needs them.
func externalRuntimeWorkspaceRestoreFailedMessage(sessionID, archivePath, workspacePath string, restoreErr error, restoreTimeout time.Duration) string {
	base := "This session's workspace was automatically archived after a period of inactivity, and "
	tail := "The connector is proceeding with a fresh, empty workspace for this session, so files the conversation references may be absent. " +
		"Treat prior workspace state as unavailable: check the workspace before recreating anything, and surface the data-loss risk to the user instead of silently re-creating critical files."
	switch {
	case restoreErr != nil && errors.Is(restoreErr, errWorkspaceArchiveCorrupt):
		return base + "the archive was found to be corrupt, so it was discarded and its contents are unrecoverable. " + tail
	case restoreErr != nil && (errors.Is(restoreErr, context.DeadlineExceeded) || strings.Contains(restoreErr.Error(), "context deadline exceeded")):
		return base + fmt.Sprintf("the automatic restore timed out after %s and was aborted. ", restoreTimeout) + tail + " " +
			"The archive itself is intact and was kept at " + archivePath + " (tar+zst; entries are prefixed with the session id " + sessionID + "/). " +
			"If specific archived files are needed for the current work, extract them yourself, for example: " +
			"tar --zstd -xf " + archivePath + " -C " + workspacePath + " --strip-components=1 " + sessionID + "/<relative/path>, " +
			"then verify the extracted contents before relying on them."
	default:
		return base + "the automatic restore attempt just failed. " + tail + " " +
			"The archive itself was kept at " + archivePath + " (tar+zst; entries are prefixed with the session id " + sessionID + "/). " +
			"If specific archived files are needed for the current work, extract them yourself, for example: " +
			"tar --zstd -xf " + archivePath + " -C " + workspacePath + " --strip-components=1 " + sessionID + "/<relative/path>, " +
			"then verify the extracted contents before relying on them."
	}
}

func (c *connector) watchExternalRuntime(provider string, input externalRuntimeInput) error {
	record := externalRuntimeRecoveryRecordFromInput(provider, input)
	if err := record.validate(); err != nil {
		return err
	}
	return c.externalRuntimeState.watch(record, input.batchIDs...)
}

func (c *connector) forgetExternalRuntime(provider, sessionID string) {
	c.externalRuntimeState.forget(provider, sessionID)
}

func (c *connector) checkExternalRuntimes(ctx context.Context) {
	ctx, leaveAccess, admitted := c.deviceRuntimeAdmission(ctx)
	if !admitted {
		return
	}
	defer leaveAccess()
	records := c.externalRuntimeState.activeRecords()
	checked := make([]int, 0, len(records))
	for index, record := range records {
		if c.recoveryAttemptDue(record) {
			checked = append(checked, index)
		}
	}
	errs := make([]error, len(checked))
	jobs := make(chan int)
	var workers sync.WaitGroup
	for range min(externalRuntimeCheckConcurrency, len(checked)) {
		workers.Add(1)
		go func() {
			defer workers.Done()
			for position := range jobs {
				record := records[checked[position]]
				checkCtx, cancel := context.WithTimeout(ctx, externalRuntimeCheckTimeout)
				err := c.externalRuntimeState.reconcileHostExecution(checkCtx, record)
				leaveNative := func() {}
				if err == nil {
					leaveNative, err = c.enterRuntimeAuthNativeCallAdmitted(checkCtx, record.Provider, record.Command)
				}
				if err == nil {
					var retried bool
					retried, err = c.externalRuntimeState.retryUnstartedRuntimeInput(checkCtx, record)
					if !retried {
						err = c.runtimeImplementations[record.Provider].Check(checkCtx, record.SessionID)
					}
					leaveNative()
				}
				cancel()
				errs[position] = err
				if err != nil && ctx.Err() == nil {
					logf("external runtime recovery failed provider=%s session=%s: %v", record.Provider, record.SessionID, err)
				}
			}
		}()
	}
	for position := range checked {
		select {
		case jobs <- position:
		case <-ctx.Done():
			close(jobs)
			workers.Wait()
			return
		}
	}
	close(jobs)
	workers.Wait()
	if ctx.Err() != nil {
		return
	}
	c.applyRecoveryFailureBudget(records, checked, errs)
	if err := c.externalRuntimeState.reconcileHostOrphans(ctx); err != nil && ctx.Err() == nil {
		logf("external runtime Host orphan inspection failed: %v", err)
	}
}

// recoveryAttemptDue reports whether this record's next recovery attempt is
// due on this health pass. A record with no streak, or whose streak belongs
// to an older dispatch/execution fence, is fresh work and always due. Reads
// only: the pass that completes decrements the remaining wait in
// applyRecoveryFailureBudget, so a cancelled pass never consumes backoff.
func (c *connector) recoveryAttemptDue(record externalRuntimeRecoveryRecord) bool {
	streak, exists := c.externalRuntimeRecoveryFailures[record.key()]
	if !exists || streak.dispatchID != record.DispatchID || streak.executionID != record.ExecutionID {
		return true
	}
	return streak.skip == 0
}

// recoveryBackoffDelayTicks is the number of health passes between failed
// attempt n and the next attempt for the same execution: 1, 2, 4, then the
// cap. The doubling keeps the first retries prompt for transient blips while
// geometric growth stops a stuck session from re-running expensive
// app-server restarts on every pass.
func recoveryBackoffDelayTicks(failures int) int {
	if shift := failures - 1; shift < 3 {
		return 1 << shift
	}
	return externalRuntimeRecoveryBackoffCapTicks
}

// pruneIdleExternalRuntimeIdentities runs the identity TTL at most once per
// externalRuntimeIdentityPruneInterval; the health loop drives it. The gate
// state is owned by the health-loop goroutine, like the recovery streaks.
func (c *connector) pruneIdleExternalRuntimeIdentities(now time.Time) {
	if !c.externalRuntimeIdentityPruneAt.IsZero() &&
		now.Sub(c.externalRuntimeIdentityPruneAt) < externalRuntimeIdentityPruneInterval {
		return
	}
	c.externalRuntimeIdentityPruneAt = now
	started := time.Now()
	stamped, pruned := c.externalRuntimeState.pruneIdleIdentities(now.Unix())
	if stamped > 0 || pruned > 0 {
		logf("external runtime identity prune stamped=%d pruned=%d duration_ms=%d",
			stamped, pruned, time.Since(started).Milliseconds())
	}
}

// externalRuntimeRecoveryStreak binds a consecutive-failure count to the
// execution generation it was observed on: a different dispatch/execution
// fence is new work and must earn its own full budget, so a replacement
// execution can never inherit its predecessor's failures or its backoff.
// skip is how many completed health passes this execution still sits out
// before its next attempt.
type externalRuntimeRecoveryStreak struct {
	dispatchID  string
	executionID string
	count       int
	skip        int
}

// applyRecoveryFailureBudget bounds recovery retries per watched execution
// and schedules the backoff between them. checked holds the indexes of the
// records attempted on this pass with errs parallel to it; every other
// watched record sat the pass out and consumes one tick of its remaining
// backoff. Streaks are counted only over completed health passes (a
// cancelled pass returns before this runs), reset on any successful check or
// fence change, and dropped when the obligation leaves activeRecords through
// its normal settle or forget paths. The state is in-memory on purpose: it
// is retry-storm damping, not durable lifecycle state, and a Connector
// restart already re-validates every obligation from state.db, so the streak
// restarting with the process is acceptable.
func (c *connector) applyRecoveryFailureBudget(records []externalRuntimeRecoveryRecord, checked []int, errs []error) {
	if c.externalRuntimeRecoveryFailures == nil {
		c.externalRuntimeRecoveryFailures = map[string]externalRuntimeRecoveryStreak{}
	}
	attempted := make(map[int]int, len(checked))
	for position, index := range checked {
		attempted[index] = position
	}
	seen := make(map[string]bool, len(records))
	for index, record := range records {
		key := record.key()
		seen[key] = true
		position, wasAttempted := attempted[index]
		if !wasAttempted {
			streak, exists := c.externalRuntimeRecoveryFailures[key]
			if exists && streak.dispatchID == record.DispatchID &&
				streak.executionID == record.ExecutionID && streak.skip > 0 {
				streak.skip--
				c.externalRuntimeRecoveryFailures[key] = streak
			}
			continue
		}
		if errs[position] == nil {
			delete(c.externalRuntimeRecoveryFailures, key)
			continue
		}
		streak := c.externalRuntimeRecoveryFailures[key]
		if streak.dispatchID != record.DispatchID || streak.executionID != record.ExecutionID {
			streak = externalRuntimeRecoveryStreak{dispatchID: record.DispatchID, executionID: record.ExecutionID}
		}
		streak.count++
		streak.skip = recoveryBackoffDelayTicks(streak.count) - 1
		c.externalRuntimeRecoveryFailures[key] = streak
		if streak.count < externalRuntimeRecoveryFailureBudget {
			continue
		}
		version, startedAt := c.externalRuntimeState.recoveryStartedAt(record)
		if version == 3 &&
			(startedAt <= 0 || time.Now().Unix()-startedAt < int64(externalRuntimeRecoveryBudget/time.Second)) {
			continue
		}
		implementation := c.runtimeImplementations[record.Provider]
		if implementation == nil ||
			!implementation.AbandonRecovery(record, externalRuntimeRecoveryAbandonReason) {
			continue
		}
		delete(c.externalRuntimeRecoveryFailures, key)
		logf("external runtime recovery abandoned provider=%s session=%s after %d consecutive failed attempts",
			record.Provider, record.SessionID, streak.count)
	}
	for key := range c.externalRuntimeRecoveryFailures {
		if !seen[key] {
			delete(c.externalRuntimeRecoveryFailures, key)
		}
	}
}

// announceAbandonedRecovery forwards the terminal observations for an
// abandoned obligation: the failed execution event carrying the distinct
// recovery_exhausted conclusion, then runtime_stopped — including when no
// native process is alive. The failed event is deliberately sent for
// interrupted obligations too: connector restarts and abnormal exits leave
// real recovery work in the interrupted phase with its earlier exit event
// normalized as generic runtime_failed, and abandonment is the later, more
// specific terminal fact — the status read model applies the newer watermark
// and supersedes that projection. Only obligations without an execution
// fence (pre-native inbox work) have no execution event to fail. The
// capability token and execution fence come from the durable record that
// forgetExecution just verified.
func (c *connector) announceAbandonedRecovery(record externalRuntimeRecoveryRecord, reason string) {
	if record.DispatchID != "" && record.ExecutionID != "" {
		// The explicit issue keeps abandonment distinguishable from the
		// runtime failing on its own: attachRuntimeIdentity regenerates the
		// canonical recovery_exhausted message for it.
		c.forwardRuntimeExecutionEvent(record.Provider, record.SessionID, record.Token, attachRuntimeIdentity(map[string]any{
			"type":     "error",
			"provider": record.Provider,
			"issue":    "recovery_exhausted",
			"message":  reason,
		}, record.DispatchID, record.ExecutionID, "failed"), "")
	}
	event := standardRuntimeEvent(record.Provider, "status", "runtime_stopped")
	event["state"] = "stopped"
	c.forwardRuntimeEvent(record.Token, event)
}

// abandonRuntimeObligation is the no-native-state abandonment path shared by
// the provider implementations: fence-checked removal, then the terminal
// announcements. A fence mismatch means the obligation was replaced after the
// caller sampled it — nothing is removed and nothing is owed.
func (c *connector) abandonRuntimeObligation(record externalRuntimeRecoveryRecord, reason string) bool {
	_, removed, err := c.externalRuntimeState.forgetExecution(record)
	if err != nil {
		return false
	}
	if removed {
		c.announceAbandonedRecovery(record, reason)
	}
	return true
}

func stopExternalRuntime(ctx context.Context, stop func(), done <-chan struct{}) error {
	stop()
	select {
	case <-done:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (c *connector) externalRuntimeHealthLoop(ctx context.Context, interval time.Duration) {
	if interval <= 0 {
		return
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	c.checkExternalRuntimes(ctx)
	c.pruneIdleExternalRuntimeIdentities(time.Now())
	c.externalRuntimeState.wake()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			c.checkExternalRuntimes(ctx)
			c.pruneIdleExternalRuntimeIdentities(time.Now())
			c.externalRuntimeState.wake()
		}
	}
}

func externalRuntimeRecoveryRecordFromInput(provider string, input externalRuntimeInput) externalRuntimeRecoveryRecord {
	return externalRuntimeRecoveryRecord{
		Provider: provider, SessionID: input.sessionID, DispatchID: input.dispatchID,
		ExecutionID: input.executionID, Token: input.token, Command: input.command,
		Workspace: input.workspace, Model: input.model, ModelProvider: input.modelProvider,
		ReasoningEffort: input.reasoningEffort, SystemPrompt: input.systemPrompt, Payload: input.payload,
	}
}

func externalRuntimeIdentityFromRecovery(record externalRuntimeRecoveryRecord) externalRuntimeSessionIdentity {
	return externalRuntimeSessionIdentity{
		Provider: record.Provider, SessionID: record.SessionID, Command: record.Command,
		Workspace: record.Workspace, Payload: maps.Clone(record.Payload),
	}
}

func (record externalRuntimeRecoveryRecord) key() string {
	return record.Provider + "\x00" + record.SessionID
}

func (record externalRuntimeRecoveryRecord) input() externalRuntimeInput {
	return externalRuntimeInput{
		provider:  record.Provider,
		sessionID: record.SessionID, dispatchID: record.DispatchID, executionID: record.ExecutionID,
		token: record.Token, command: record.Command,
		workspace: record.Workspace, model: record.Model, modelProvider: record.ModelProvider,
		reasoningEffort: record.ReasoningEffort, systemPrompt: record.SystemPrompt, payload: record.Payload,
	}
}

func (record externalRuntimeRecoveryRecord) validate() error {
	if record.Provider == "" || record.SessionID == "" || record.Token == "" ||
		record.Command == "" || record.Workspace == "" || !filepath.IsAbs(record.Workspace) || record.Payload == nil {
		return errors.New("invalid external runtime recovery record")
	}
	if record.DispatchID == "" && record.ExecutionID != "" {
		return errors.New("invalid external runtime recovery fence")
	}
	return nil
}

func (execution externalRuntimeActiveExecution) key() string {
	return execution.Session.key()
}

func (execution externalRuntimeActiveExecution) validate() error {
	if !slices.Contains([]int{2, 3, 4}, execution.Version) || !slices.Contains([]string{
		externalRuntimeExecutionStarting,
		externalRuntimeExecutionRunning,
		externalRuntimeExecutionInterrupted,
		externalRuntimeExecutionSettling,
	}, execution.Phase) || execution.Session.validate() != nil {
		return errors.New("invalid external runtime active execution")
	}
	if execution.Version == 3 && execution.Target.validate() != nil {
		return errors.New("invalid external runtime execution target")
	}
	// Version 4 records belong to direct Connectors, not Compute Hosts.
	if execution.Version == 4 && (execution.Target != (externalRuntimeExecutionTarget{}) ||
		execution.HostAcquired || execution.Phase == externalRuntimeExecutionSettling) {
		return errors.New("invalid direct runtime execution")
	}
	if execution.Version >= 3 && execution.RecoveryStartedAt <= 0 {
		return errors.New("invalid external runtime recovery budget")
	}
	if execution.Phase == externalRuntimeExecutionSettling &&
		(execution.TerminalEventID == "" || execution.SettlingStartedAt <= 0 || !execution.HostAcquired) {
		return errors.New("invalid external runtime settling execution")
	}
	if len(execution.InputBatchIDs) == 0 {
		return nil
	}
	seen := make(map[string]struct{}, len(execution.InputBatchIDs))
	for _, batchID := range execution.InputBatchIDs {
		if batchID == "" {
			return errors.New("invalid external runtime input claim")
		}
		if _, exists := seen[batchID]; exists {
			return errors.New("duplicate external runtime input claim")
		}
		seen[batchID] = struct{}{}
	}
	return nil
}

func (target externalRuntimeExecutionTarget) validate() error {
	if target.RuntimeInstanceID == "" || target.RuntimeGeneration <= 0 ||
		target.RuntimeConnectionEpoch == "" || target.WorkloadID == "" ||
		target.WorkloadGeneration <= 0 || target.AllocationID == "" ||
		target.AllocationGeneration <= 0 || target.ContainerID == "" || target.ContainerInstanceID == "" {
		return errors.New("invalid runtime execution target")
	}
	return nil
}

func externalRuntimeExecutionTargetFromMap(value map[string]any) (externalRuntimeExecutionTarget, error) {
	raw, err := json.Marshal(value)
	if err != nil {
		return externalRuntimeExecutionTarget{}, err
	}
	var target externalRuntimeExecutionTarget
	if err := json.Unmarshal(raw, &target); err != nil {
		return externalRuntimeExecutionTarget{}, err
	}
	return target, target.validate()
}

func (target externalRuntimeExecutionTarget) mapValue() map[string]any {
	raw, _ := json.Marshal(target)
	var value map[string]any
	_ = json.Unmarshal(raw, &value)
	return value
}

func (identity externalRuntimeSessionIdentity) key() string {
	return identity.Provider + "\x00" + identity.SessionID
}

func (identity externalRuntimeSessionIdentity) validate() error {
	if identity.Provider == "" || identity.SessionID == "" || identity.Command == "" ||
		identity.Workspace == "" || !filepath.IsAbs(identity.Workspace) || identity.Payload == nil {
		return errors.New("invalid external runtime session identity")
	}
	return nil
}

type externalRuntimeInput struct {
	provider        string
	sessionID       string
	dispatchID      string
	batchIDs        []string
	executionID     string
	token           string
	command         string
	workspace       string
	model           string
	modelProvider   string
	reasoningEffort string
	systemPrompt    string
	payload         map[string]any
	messages        []map[string]any
}

func parseExternalRuntimeInput(params map[string]any) (string, externalRuntimeInput, error) {
	if stringParam(params, "kind") != "external" {
		return "", externalRuntimeInput{}, errors.New("agent_runtime_input requires kind=external")
	}
	provider := stringParam(params, "provider")
	config := mapParam(params, "runtime_config")
	input := externalRuntimeInput{
		provider:        provider,
		sessionID:       stringParam(params, "session_id"),
		dispatchID:      stringParam(params, "dispatch_id"),
		token:           stringParam(params, "runtime_capability_token"),
		command:         stringParam(config, "command"),
		model:           stringParam(config, "model"),
		modelProvider:   stringParam(config, "model_provider"),
		reasoningEffort: stringParam(config, "reasoning_effort"),
		systemPrompt:    stringParam(params, "system_prompt"),
		payload:         map[string]any{},
		messages:        sliceMapParam(params, "input_messages"),
	}
	if input.sessionID == "" || input.dispatchID == "" || input.token == "" {
		return "", externalRuntimeInput{}, errors.New("session_id, dispatch_id, and runtime_capability_token are required")
	}
	if len(input.messages) == 0 {
		return "", externalRuntimeInput{}, errors.New("agent_runtime_input requires at least one input item")
	}
	for _, message := range input.messages {
		role := stringParam(message, "role")
		if role != "summary" && role != "user" && role != "runtime" {
			return "", externalRuntimeInput{}, fmt.Errorf("unsupported external runtime input role %q", role)
		}
	}
	if input.text() == "" {
		return "", externalRuntimeInput{}, errors.New("agent_runtime_input contains no text")
	}
	return provider, input, nil
}

func (input externalRuntimeInput) text() string {
	parts := make([]string, 0, len(input.messages))
	for _, message := range input.messages {
		if content := strings.TrimSpace(stringParam(message, "content")); content != "" {
			if messageTime, ok := message["input_time"].(map[string]any); ok {
				if encoded, err := json.Marshal(messageTime); err == nil {
					content = "Message time context (source metadata, not user text): " + string(encoded) + "\n\n" + content
				}
			}
			parts = append(parts, content)
		}
	}
	return strings.Join(parts, "\n\n")
}

func (input externalRuntimeInput) agentBatchMessages(deliveredAt time.Time) ([]map[string]any, error) {
	batchIDs := input.batchIDs
	if len(batchIDs) == 0 {
		batchIDs = []string{input.dispatchID}
	}
	messages := make([]map[string]any, 0, len(input.messages))
	for index, source := range input.messages {
		messageID := defaultString(stringParam(source, "id"), stringParam(source, "source_message_id"))
		if messageID == "" {
			messageID = fmt.Sprintf("%s:%d", input.dispatchID, index+1)
		}
		message := map[string]any{
			"message_id": messageID,
			"role":       stringParam(source, "role"),
			"sent_at":    readableMessageTime(source["created_at"]),
			"content": []map[string]any{{
				"type": "text",
				"text": stringParam(source, "content"),
			}},
		}
		if messageTime, ok := source["input_time"].(map[string]any); ok {
			message["input_time"] = messageTime
			message["sent_at"] = defaultString(stringParam(messageTime, "source_sent_at"), "Unknown (use received_at as an explicit fallback)")
		}
		messages = append(messages, message)
	}
	envelope := map[string]any{
		"schema":           "external_session_message_batch_v1",
		"batch_id":         input.dispatchID,
		"source_batch_ids": batchIDs,
		"delivery": map[string]any{
			"delivered_at":     readableTime(deliveredAt),
			"may_be_duplicate": true,
			"notice":           "This complete batch is delivered at least once. Some messages may already have been seen after an interrupted or uncertain delivery. Use stable message IDs, original times, conversation context, workspace, and actual external side effects before continuing or retrying anything.",
		},
		"messages": messages,
	}
	raw, err := json.MarshalIndent(envelope, "", "  ")
	if err != nil {
		return nil, err
	}
	return []map[string]any{{"role": "user", "content": string(raw)}}, nil
}

func readableMessageTime(value any) string {
	seconds := int64(intFromAny(value, 0))
	if seconds <= 0 {
		return "Unknown (the sender did not provide an original time)"
	}
	if seconds > 10_000_000_000 {
		seconds /= 1000
	}
	sentAt := time.Unix(seconds, 0).UTC()
	return readableTime(sentAt)
}

func readableTime(value time.Time) string {
	return value.UTC().Format("Monday, 02 January 2006 at 15:04:05 UTC")
}

func externalRuntimeRecoveryInput(input externalRuntimeInput, nativeKey, nativeID string) externalRuntimeInput {
	input.messages = nil
	strictResume := boolParam(input.payload, "require_native_resume")
	sessionFile := stringParam(input.payload, "session_file")
	input.payload = map[string]any{nativeKey: nativeID}
	if strictResume {
		input.payload["require_native_resume"] = true
	}
	if sessionFile != "" {
		input.payload["session_file"] = sessionFile
	}
	return input
}

func standardRuntimeEvent(provider, eventType, name string) map[string]any {
	return map[string]any{
		"type":     eventType,
		"provider": provider,
		"name":     name,
	}
}

func attachRuntimeIdentity(event map[string]any, dispatchID, executionID, workState string) map[string]any {
	if event == nil || dispatchID == "" || executionID == "" {
		return event
	}
	event["dispatch_id"] = dispatchID
	event["execution_id"] = executionID
	if workState != "" {
		event["work_state"] = workState
	}
	if workState == "failed" {
		issue, message := stringParam(event, "issue"), stringParam(event, "message")
		if validRuntimeFailureIssue(issue) {
			message = runtimeFailureMessage(stringParam(event, "provider"), issue)
		} else {
			issue, message = normalizeRuntimeFailure(
				stringParam(event, "provider"),
				stringParam(event, "code"),
				message,
			)
		}
		message = runtimeFailureResetMessage(event, issue, message)
		event["issue"] = issue
		event["message"] = message
	}
	return event
}

func validRuntimeFailureIssue(issue string) bool {
	return slices.Contains([]string{
		"quota_exhausted", "rate_limited", "authentication_required", "model_unavailable",
		"recovery_exhausted", "runtime_failed",
	}, issue)
}

func normalizeRuntimeFailure(provider, code, detail string) (string, string) {
	provider = strings.ToLower(strings.TrimSpace(provider))
	code = strings.ToLower(strings.TrimSpace(code))
	detail = strings.ToLower(strings.TrimSpace(detail))
	issue := "runtime_failed"
	switch {
	case slices.Contains([]string{"usage_limit_reached", "insufficient_quota", "quota_exceeded"}, code),
		strings.Contains(detail, "no credits left"),
		strings.Contains(detail, "hit your usage limit"),
		strings.Contains(detail, "hit your session limit"):
		issue = "quota_exhausted"
	case slices.Contains([]string{"rate_limit_exceeded", "rate_limited", "too_many_requests"}, code):
		issue = "rate_limited"
	case slices.Contains([]string{"authentication_required", "unauthorized", "not_logged_in"}, code):
		issue = "authentication_required"
	case slices.Contains([]string{"model_not_found", "model_unavailable", "unsupported_model"}, code):
		issue = "model_unavailable"
	case detail == externalRuntimeRecoveryAbandonReason:
		// Connector-owned abandonment reason (fixed text, not provider
		// output): recovery gave up after the failure budget, which is a
		// distinct diagnosis from the runtime failing on its own.
		issue = "recovery_exhausted"
	}
	return issue, runtimeFailureMessage(provider, issue)
}

func runtimeFailureMessage(provider, issue string) string {
	name := map[string]string{"codex": "Codex", "pi": "Pi", "kimi": "Kimi", "claude": "Claude"}[strings.ToLower(provider)]
	if name == "" {
		name = "External"
	}
	messages := map[string]string{
		"quota_exhausted":         name + " account usage quota is exhausted.",
		"rate_limited":            name + " is temporarily rate limited.",
		"authentication_required": name + " reports no authenticated account.",
		"model_unavailable":       "The configured " + name + " model is unavailable.",
		"recovery_exhausted":      name + " session recovery attempts were exhausted.",
		"runtime_failed":          name + " runtime execution failed.",
	}
	return messages[issue]
}

func textList(value any) string {
	items, ok := value.([]any)
	if !ok {
		return strings.TrimSpace(stringFromAny(value))
	}
	parts := make([]string, 0, len(items))
	for _, item := range items {
		if text := strings.TrimSpace(stringFromAny(item)); text != "" {
			parts = append(parts, text)
		}
	}
	return strings.Join(parts, "\n")
}

func contentBlockText(value any, blockType, field string) string {
	if text, ok := value.(string); ok && blockType == "text" {
		return strings.TrimSpace(text)
	}
	items, _ := value.([]any)
	parts := make([]string, 0, len(items))
	for _, item := range items {
		block, _ := item.(map[string]any)
		if stringParam(block, "type") == blockType {
			if text := strings.TrimSpace(stringParam(block, field)); text != "" {
				parts = append(parts, text)
			}
		}
	}
	return strings.Join(parts, "\n")
}

func newRuntimeContext() (string, error) {
	raw := make([]byte, 24)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	return hex.EncodeToString(raw), nil
}

func (c *connector) forwardRuntimeEvent(token string, event map[string]any) {
	c.forwardRuntimeExecutionEvent("", "", token, event, "")
}

func (c *connector) forwardRuntimeExecutionEvent(
	provider, sessionID, token string,
	event map[string]any,
	transition string,
) {
	if token == "" {
		return
	}
	event["created_at"] = time.Now().Unix()
	if err := c.externalRuntimeState.enqueueExecutionEvent(provider, sessionID, token, event, transition); err != nil {
		logf("persist external runtime event failed: %v", err)
	}
}

func (c *connector) methodAgentRuntimeInput(ctx context.Context, params map[string]any) (map[string]any, error) {
	c.cloudRuntimeMu.Lock()
	defer c.cloudRuntimeMu.Unlock()
	c.expireCloudRuntimeQuiesce()
	if c.cloudRuntimeQuiesced {
		return nil, errors.New("cloud runtime is idle; reconnect before sending input")
	}

	provider, input, err := parseExternalRuntimeInput(params)
	if err != nil {
		return nil, err
	}
	input.workspace, err = c.externalRuntimeWorkspace(provider, input.sessionID)
	if err != nil {
		return nil, err
	}
	if c.workspaceArchiver != nil {
		// Notices are staged for the delivery path instead of being appended
		// here: the persisted input batch must stay byte-identical across
		// duplicate dispatches of the same input.
		restored, restoreErr := c.workspaceArchiver.RestoreIfArchived(ctx, input.sessionID)
		if restored && restoreErr == nil {
			c.setWorkspaceRuntimeNotice(input.sessionID, externalRuntimeWorkspaceRestoredMessage)
		} else if restoreErr != nil {
			logf("workspace restore failed session=%s: %v", input.sessionID, restoreErr)
			c.setWorkspaceRuntimeNotice(input.sessionID, externalRuntimeWorkspaceRestoreFailedMessage(
				input.sessionID,
				c.workspaceArchiver.archivePath(input.sessionID),
				input.workspace,
				restoreErr,
				c.workspaceArchiver.restoreTimeout,
			))
			c.forwardRuntimeEvent(input.token, standardRuntimeEvent(provider, "status", "workspace_restore_failed"))
		}
	}
	implementation := c.runtimeImplementations[provider]
	if implementation == nil {
		return nil, fmt.Errorf("unsupported external runtime provider %q", provider)
	}
	if input.command == "" {
		return nil, errors.New("agent_runtime_input requires a discovered runtime command")
	}
	if err := c.externalRuntimeState.enqueueInputBatch(provider, input); err != nil {
		return nil, err
	}
	return map[string]any{
		"accepted":    true,
		"dispatch_id": input.dispatchID,
	}, nil
}

func (c *connector) replayRuntimeObservations() {
	for _, implementation := range c.runtimeImplementations {
		implementation.ReplayObservations()
	}
}

func resolveExternalRuntimeWorkspaceRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve external runtime workspace home: %w", err)
	}
	if !filepath.IsAbs(home) {
		return "", errors.New("resolve external runtime workspace home: HOME must be absolute")
	}
	return filepath.Join(home, ".comma", "workspaces"), nil
}

func externalRuntimeWorkspaceReadinessMessage(err error) string {
	if err == nil {
		return ""
	}
	if strings.TrimSpace(os.Getenv("HOME")) == "" {
		return "HOME is not set; the external runtime workspace root cannot be resolved."
	}
	if !filepath.IsAbs(os.Getenv("HOME")) {
		return "HOME is not an absolute path; the external runtime workspace root cannot be resolved."
	}
	if errors.Is(err, os.ErrPermission) {
		return "The external runtime workspace is not writable by the Connector."
	}
	if errors.Is(err, syscall.ENOSPC) {
		return "The external runtime workspace cannot be prepared because the device has no free disk space."
	}
	return "The external runtime workspace could not be prepared."
}

func (c *connector) externalRuntimeWorkspaceReadiness() error {
	if c.externalWorkspaceError != nil {
		return c.externalWorkspaceError
	}
	return prepareExternalRuntimeWorkspace(c.externalWorkspaceRoot)
}

func (c *connector) externalRuntimeWorkspace(provider, sessionID string) (string, error) {
	if sessionID == "" || sessionID == "." || sessionID == ".." || filepath.Base(sessionID) != sessionID {
		return "", errors.New("invalid external runtime session id")
	}
	workspace, ok, err := c.externalRuntimeState.persistedWorkspace(provider, sessionID)
	if err != nil {
		return "", err
	}
	if ok {
		return workspace, nil
	}
	if c.externalWorkspaceRoot == "" {
		if c.externalWorkspaceError != nil {
			return "", c.externalWorkspaceError
		}
		return "", errors.New("external runtime workspace root is unavailable")
	}
	return filepath.Join(c.externalWorkspaceRoot, sessionID), nil
}

func prepareExternalRuntimeWorkspace(workspace string) error {
	if workspace == "" || !filepath.IsAbs(workspace) {
		return errors.New("external runtime workspace must be absolute")
	}
	if err := os.MkdirAll(workspace, 0o700); err != nil {
		return fmt.Errorf("create external runtime workspace: %w", err)
	}
	return nil
}

func (c *connector) closeExternalRuntimes() {
	c.externalRuntimeState.cancel()
	for _, implementation := range c.runtimeImplementations {
		implementation.Close()
	}
	c.externalRuntimeState.close()
}

// Keep reset metadata numeric and bounded; never propagate raw provider error
// strings into the terminal status. Canonicalization repeats this on outbox reopen.
func runtimeFailureResetMessage(event map[string]any, issue, message string) string {
	reset := int64Param(event, "usage_reset_at", 0)
	delete(event, "usage_reset_at")
	if (issue == "quota_exhausted" || issue == "rate_limited") && reset > 0 && reset <= 253402300799 {
		event["usage_reset_at"] = reset
		return message + " Provider reset time: " + time.Unix(reset, 0).UTC().Format(time.RFC3339) + "."
	}
	return message
}
