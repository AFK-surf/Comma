package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/oklog/ulid/v2"
	bolt "go.etcd.io/bbolt"
)

// Direct Connectors have no Compute target. Missing Compute targets must not
// turn a configured Host-backed runtime into a direct execution.
func TestExternalRuntimeInputClaimExecutionBoundary(t *testing.T) {
	for _, compute := range []bool{false, true} {
		t.Run(fmt.Sprintf("compute=%t", compute), func(t *testing.T) {
			c := newEventTestConnector(t, t.TempDir())
			defer c.externalRuntimeState.close()
			c.setComputeRuntimeExecutionTarget(nil)
			if compute {
				c.cfg.computeRuntimeURL = "wss://compute.invalid/runtime"
			}
			batch := testRuntimeInputBatch("pi", "session-boundary", "dispatch-1", "message-1")
			persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
			batches := []externalRuntimeInputBatch{batch}
			input, err := c.externalRuntimeState.claimInputBatches(batches, c.externalRuntimeState.inputForBatches(batches))
			if compute {
				if err == nil {
					t.Fatal("Compute input was claimed without its Host target")
				}
				assertRuntimeInputState(t, c, 1, false, nil)
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			// No transport exists: direct acquisition must remain local.
			if err := c.externalRuntimeState.ensureHostExecutionAcquired(input); err != nil {
				t.Fatal(err)
			}
			assertRuntimeInputState(t, c, 1, true, []string{"dispatch-1"})
			c.cfg.computeRuntimeURL = "wss://compute.invalid/runtime"
			if err := c.externalRuntimeState.ensureHostExecutionAcquired(input); err == nil {
				t.Fatal("direct execution was adopted by a Compute runtime")
			}
		})
	}
}

func TestExternalRuntimeInputClaimSettlesAllMergedBatches(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	provider := "pi"
	batches := []externalRuntimeInputBatch{
		testRuntimeInputBatch(provider, "session-claim", "dispatch-1", "message-1"),
		testRuntimeInputBatch(provider, "session-claim", "dispatch-2", "message-2"),
	}
	for _, batch := range batches {
		persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
	}
	input := c.externalRuntimeState.inputForBatches(batches)
	input, err := c.externalRuntimeState.claimInputBatches(batches, input)
	if err != nil {
		t.Fatal(err)
	}
	assertRuntimeInputState(t, c, 2, true, []string{"dispatch-1", "dispatch-2"})

	bound := input
	bound.executionID = "execution-1"
	bound.payload = map[string]any{"session_id": "native-1"}
	if err := c.watchExternalRuntime(provider, bound); err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.acceptInputClaim(provider, input); err != nil {
		t.Fatal(err)
	}
	assertRuntimeInputState(t, c, 0, true, nil)
}

func TestExternalRuntimeInputSelectionSkipsRotatedCapabilityBehindActiveExecution(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()

	active := externalRuntimeInput{
		sessionID: "session-a", dispatchID: "dispatch-active", executionID: "execution-active",
		token: "capability-old", command: "/usr/local/bin/pi", workspace: t.TempDir(),
		payload: map[string]any{},
	}
	if err := c.watchExternalRuntime("pi", active); err != nil {
		t.Fatal(err)
	}
	promoteTestHostExecution(t, c, "pi", active.sessionID)

	blocked := testRuntimeInputBatch("pi", "session-a", "dispatch-blocked", "message-blocked")
	blocked.Session.Token = "capability-new"
	eligible := testRuntimeInputBatch("pi", "session-b", "dispatch-eligible", "message-eligible")
	for _, batch := range []externalRuntimeInputBatch{blocked, eligible} {
		persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
	}

	batches, ok, err := c.externalRuntimeState.nextInputBatches()
	if err != nil {
		t.Fatal(err)
	}
	if !ok || len(batches) != 1 || batches[0].Session.SessionID != "session-b" {
		t.Fatalf("selected batches=%#v, want only eligible session-b", batches)
	}
	c.externalRuntimeState.inputCalls.Delete(eligible.Session.key())
}

func TestSettlingSessionDoesNotBlockAnotherSessionsInput(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	blocked := testRuntimeInputBatch("pi", "session-a", "dispatch-later", "message-later")
	input := c.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{blocked})
	input.executionID = "execution-old"
	input.batchIDs = nil
	if err := c.watchExternalRuntime("pi", input); err != nil {
		t.Fatal(err)
	}
	promoteTestHostExecution(t, c, "pi", input.sessionID)
	state := c.externalRuntimeState
	state.mu.Lock()
	execution := state.activeExecutions[blocked.Session.key()]
	execution.Phase = externalRuntimeExecutionSettling
	execution.TerminalEventID = "terminal-acked"
	execution.SettlingStartedAt = time.Now().Unix()
	_, err := state.storeActiveExecutionLocked(externalRuntimeIdentityFromRecovery(execution.Session), execution)
	state.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	eligible := testRuntimeInputBatch("pi", "session-b", "dispatch-ready", "message-ready")
	persistRuntimeInputBatch(t, state, blocked)
	persistRuntimeInputBatch(t, state, eligible)
	batches, ok, err := state.nextInputBatches()
	if err != nil {
		t.Fatal(err)
	}
	if !ok || len(batches) != 1 || batches[0].Session.SessionID != eligible.Session.SessionID {
		t.Fatalf("selected blocked input instead of eligible session: %#v", batches)
	}
	state.inputCalls.Delete(eligible.Session.key())
}

func TestExternalRuntimeInputSelectionKeepsSameCapabilitySteeringEligible(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()

	active := externalRuntimeInput{
		sessionID: "session-a", dispatchID: "dispatch-active", executionID: "execution-active",
		token: "capability-current", command: "/usr/local/bin/pi", workspace: t.TempDir(),
		payload: map[string]any{},
	}
	if err := c.watchExternalRuntime("pi", active); err != nil {
		t.Fatal(err)
	}
	promoteTestHostExecution(t, c, "pi", active.sessionID)

	steer := testRuntimeInputBatch("pi", "session-a", "dispatch-steer", "message-steer")
	steer.Session.Token = active.token
	persistRuntimeInputBatch(t, c.externalRuntimeState, steer)

	batches, ok, err := c.externalRuntimeState.nextInputBatches()
	if err != nil {
		t.Fatal(err)
	}
	if !ok || len(batches) != 1 || batches[0].Session.DispatchID != "dispatch-steer" {
		t.Fatalf("selected batches=%#v, want same-capability steering", batches)
	}
	c.externalRuntimeState.inputCalls.Delete(steer.Session.key())
}

func TestExternalRuntimeInputSelectionDoesNotMergeRotatedCapability(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()

	active := externalRuntimeInput{
		sessionID: "session-a", dispatchID: "dispatch-active", executionID: "execution-active",
		token: "capability-old", command: "/usr/local/bin/pi", workspace: t.TempDir(),
		payload: map[string]any{},
	}
	if err := c.watchExternalRuntime("pi", active); err != nil {
		t.Fatal(err)
	}
	promoteTestHostExecution(t, c, "pi", active.sessionID)

	steer := testRuntimeInputBatch("pi", "session-a", "dispatch-1-steer", "message-steer")
	steer.Session.Token = active.token
	blocked := testRuntimeInputBatch("pi", "session-a", "dispatch-2-blocked", "message-blocked")
	blocked.Session.Token = "capability-new"
	eligible := testRuntimeInputBatch("pi", "session-b", "dispatch-eligible", "message-eligible")
	for _, batch := range []externalRuntimeInputBatch{steer, blocked, eligible} {
		persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
	}

	batches, ok, err := c.externalRuntimeState.nextInputBatches()
	if err != nil {
		t.Fatal(err)
	}
	if !ok || len(batches) != 1 || batches[0].Session.DispatchID != steer.Session.DispatchID {
		t.Fatalf("selected batches=%#v, want only same-capability steering", batches)
	}
	input := c.externalRuntimeState.inputForBatches(batches)
	input, err = c.externalRuntimeState.claimInputBatches(batches, input)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.acceptInputClaim("pi", input); err != nil {
		t.Fatal(err)
	}
	assertRuntimeInputState(t, c, 2, true, nil)
	if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
		if tx.Bucket(externalRuntimeInputBatchesBucket).Get([]byte(blocked.key())) == nil {
			return errors.New("rotated-capability batch was not preserved")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	c.externalRuntimeState.inputCalls.Delete(steer.Session.key())

	batches, ok, err = c.externalRuntimeState.nextInputBatches()
	if err != nil {
		t.Fatal(err)
	}
	if !ok || len(batches) != 1 || batches[0].Session.SessionID != "session-b" {
		t.Fatalf("selected batches=%#v, want only eligible session-b", batches)
	}
	c.externalRuntimeState.inputCalls.Delete(eligible.Session.key())
}

func TestExternalRuntimeMissingProviderDefersClaimedInput(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	batch := testRuntimeInputBatch("missing", "session-missing", "dispatch-missing", "message-missing")
	batch.Session.Workspace = t.TempDir()
	persistRuntimeInputBatch(t, c.externalRuntimeState, batch)

	if completed := c.externalRuntimeState.deliverInputBatches([]externalRuntimeInputBatch{batch}); completed {
		t.Fatal("input completed without a runtime provider implementation")
	}
	assertRuntimeInputState(t, c, 1, true, []string{"dispatch-missing"})
}

func TestExternalRuntimeLifecycleSettlesBoundClaimAtomically(t *testing.T) {
	for _, test := range []struct {
		transition string
		wantActive bool
		direct     bool
	}{
		{transition: externalRuntimeExecutionRunning, wantActive: true},
		{transition: externalRuntimeExecutionSettled, wantActive: true},
		{transition: externalRuntimeExecutionRunning, wantActive: true, direct: true},
		{transition: externalRuntimeExecutionSettled, wantActive: false, direct: true},
	} {
		t.Run(fmt.Sprintf("%s/direct=%t", test.transition, test.direct), func(t *testing.T) {
			c := newEventTestConnector(t, t.TempDir())
			defer c.externalRuntimeState.close()
			if test.direct {
				c.setComputeRuntimeExecutionTarget(nil)
			}
			provider := "pi"
			batch := testRuntimeInputBatch(provider, "session-lifecycle", "dispatch-lifecycle", "message-lifecycle")
			persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
			input := c.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
			input, err := c.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, input)
			if err != nil {
				t.Fatal(err)
			}
			bound := input
			bound.payload = map[string]any{"session_id": "native-lifecycle"}
			if err := c.watchExternalRuntime(provider, bound); err != nil {
				t.Fatal(err)
			}
			if !test.direct {
				promoteTestHostExecution(t, c, provider, bound.sessionID)
			}
			event := attachRuntimeIdentity(map[string]any{
				"type": "status", "provider": provider, "state": test.transition, "created_at": int64(1),
			}, bound.dispatchID, bound.executionID, test.transition)
			if err := c.externalRuntimeState.enqueueExecutionEvent(
				provider, bound.sessionID, bound.token, event, test.transition,
			); err != nil {
				t.Fatal(err)
			}
			assertRuntimeInputState(t, c, 0, test.wantActive, nil)
		})
	}
}

func TestExternalRuntimeLaterInputSurvivesPriorExecutionTerminal(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	provider := "pi"
	old := externalRuntimeInput{
		sessionID: "session-race", dispatchID: "dispatch-old", executionID: "execution-old",
		token: "capability-claim", command: "/usr/local/bin/pi", workspace: "/tmp/workspace",
		payload: map[string]any{"session_id": "native-old"},
	}
	if err := c.watchExternalRuntime(provider, old); err != nil {
		t.Fatal(err)
	}
	promoteTestHostExecution(t, c, provider, old.sessionID)
	oldRunning := attachRuntimeIdentity(map[string]any{
		"type": "status", "provider": provider, "state": "running", "created_at": int64(1),
	}, old.dispatchID, old.executionID, externalRuntimeExecutionRunning)
	if err := c.externalRuntimeState.enqueueExecutionEvent(
		provider, old.sessionID, old.token, oldRunning, externalRuntimeExecutionRunning,
	); err != nil {
		t.Fatal(err)
	}

	batch := testRuntimeInputBatch(provider, old.sessionID, "dispatch-new", "message-new")
	persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
	c.externalRuntimeState.inputCalls.Store(batch.Session.key(), struct{}{})
	defer c.externalRuntimeState.inputCalls.Delete(batch.Session.key())
	input := c.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
	input, err := c.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, input)
	if err != nil {
		t.Fatal(err)
	}
	oldTerminal := attachRuntimeIdentity(map[string]any{
		"type": "status", "provider": provider, "state": "settled", "created_at": int64(2),
	}, old.dispatchID, old.executionID, externalRuntimeExecutionSettled)
	if err := c.externalRuntimeState.enqueueExecutionEvent(
		provider, old.sessionID, old.token, oldTerminal, externalRuntimeExecutionSettled,
	); err != nil {
		t.Fatal(err)
	}
	assertRuntimeInputState(t, c, 1, true, []string{"dispatch-new"})
	if err := c.watchExternalRuntime(provider, input); err == nil {
		t.Fatal("new native execution replaced an execution that was still settling")
	}
	settleTestHostExecution(t, c, provider, old.sessionID)
	input = c.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
	input, err = c.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, input)
	if err != nil {
		t.Fatal(err)
	}

	bound := input
	bound.payload = map[string]any{"session_id": "native-new"}
	if err := c.watchExternalRuntime(provider, bound); err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.acceptInputClaim(provider, input); err != nil {
		t.Fatal(err)
	}
	assertRuntimeInputState(t, c, 0, true, nil)
}

func TestExternalRuntimeUnboundClaimReturnsToInboxAfterRestart(t *testing.T) {
	root := t.TempDir()
	first := newEventTestConnector(t, root)
	provider := "pi"
	batch := testRuntimeInputBatch(provider, "session-unbound", "dispatch-unbound", "message-unbound")
	persistRuntimeInputBatch(t, first.externalRuntimeState, batch)
	input := first.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
	_, err := first.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, input)
	if err != nil {
		t.Fatal(err)
	}
	first.externalRuntimeState.close()

	second := newEventTestConnector(t, root)
	defer second.externalRuntimeState.close()
	second.runtimeImplementations = map[string]externalRuntimeImplementation{
		provider: testRuntimeImplementation{},
	}
	second.externalRuntimeState.inputCalls.Store(batch.Session.key(), struct{}{})
	if err := second.externalRuntimeState.load(); err != nil {
		t.Fatal(err)
	}
	assertRuntimeInputState(t, second, 1, true, []string{"dispatch-unbound"})
}

func TestRuntimeExecutionAcquireIntentRecoversSameIDAfterRestart(t *testing.T) {
	root := t.TempDir()
	first := newEventTestConnector(t, root)
	batch := testRuntimeInputBatch("pi", "session-acquire-recovery", "dispatch-1", "message-1")
	persistRuntimeInputBatch(t, first.externalRuntimeState, batch)
	input := first.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
	input, err := first.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, input)
	if err != nil {
		t.Fatal(err)
	}
	preparedID := input.executionID
	first.externalRuntimeState.close()

	restarted := newEventTestConnector(t, root)
	defer restarted.externalRuntimeState.close()
	restarted.runtimeImplementations = map[string]externalRuntimeImplementation{
		"pi": testRuntimeImplementation{},
	}
	attachRuntimeExecutionTestTransport(t, restarted)
	if err := restarted.externalRuntimeState.load(); err != nil {
		t.Fatal(err)
	}
	records := restarted.externalRuntimeState.activeRecords()
	if len(records) != 1 || records[0].ExecutionID != preparedID {
		t.Fatalf("restarted records=%#v, want prepared execution %q", records, preparedID)
	}
	if err := restarted.externalRuntimeState.reconcileHostExecution(context.Background(), records[0]); err != nil {
		t.Fatal(err)
	}
	restarted.externalRuntimeState.mu.Lock()
	recovered := restarted.externalRuntimeState.activeExecutions[records[0].key()]
	restarted.externalRuntimeState.mu.Unlock()
	if !recovered.HostAcquired || recovered.Session.ExecutionID != preparedID {
		t.Fatalf("recovered execution=%#v", recovered)
	}
}

func TestRuntimeExecutionLostAcquireReplyRecoversAfterAllocationGenerationChange(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	requests := make(chan message, 4)
	attachRuntimeExecutionRecordingTransport(t, c, requests)
	batch := testRuntimeInputBatch("pi", "session-generation-change", "dispatch-1", "message-1")
	persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
	input := c.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
	input, err := c.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, input)
	if err != nil {
		t.Fatal(err)
	}
	c.externalRuntimeState.mu.Lock()
	saved := c.externalRuntimeState.activeExecutions[batch.Session.key()]
	c.externalRuntimeState.mu.Unlock()
	if _, err := c.runtimeExecution(context.Background(), "acquire", input.executionID, saved.Target.mapValue()); err != nil {
		t.Fatal(err)
	}
	if request := <-requests; stringParam(request.Params, "action") != "acquire" {
		t.Fatalf("Host setup action=%#v, want acquire", request.Params)
	}
	replacement := saved.Target
	replacement.AllocationGeneration++
	c.setComputeRuntimeExecutionTarget(replacement.mapValue())

	if err := c.externalRuntimeState.reconcileHostExecution(context.Background(), saved.Session); err != nil {
		t.Fatal(err)
	}
	if request := <-requests; stringParam(request.Params, "action") != "list" {
		t.Fatalf("recovery action=%#v, want list", request.Params)
	}
	select {
	case unexpected := <-requests:
		t.Fatalf("allocation generation change retried acquire instead of confirming its lost reply: %#v", unexpected)
	default:
	}
	c.externalRuntimeState.mu.Lock()
	recovered := c.externalRuntimeState.activeExecutions[batch.Session.key()]
	c.externalRuntimeState.mu.Unlock()
	if !recovered.HostAcquired || recovered.Target != saved.Target {
		t.Fatalf("recovered execution changed its saved target: %#v", recovered)
	}
}

func TestRuntimeExecutionRecoveryDoesNotBorrowReplacementAllocationGeneration(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	requests := make(chan message, 4)
	attachRuntimeExecutionRecordingTransport(t, c, requests)
	batch := testRuntimeInputBatch("pi", "session-no-authority-borrow", "dispatch-1", "message-1")
	persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
	input := c.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
	if _, err := c.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, input); err != nil {
		t.Fatal(err)
	}
	c.externalRuntimeState.mu.Lock()
	saved := c.externalRuntimeState.activeExecutions[batch.Session.key()]
	c.externalRuntimeState.mu.Unlock()
	replacement := saved.Target
	replacement.AllocationGeneration++
	c.setComputeRuntimeExecutionTarget(replacement.mapValue())

	if err := c.externalRuntimeState.reconcileHostExecution(context.Background(), saved.Session); err == nil {
		t.Fatal("recovery acquired absent work through a replacement allocation generation")
	}
	if request := <-requests; stringParam(request.Params, "action") != "list" {
		t.Fatalf("recovery action=%#v, want list", request.Params)
	}
	select {
	case unexpected := <-requests:
		t.Fatalf("recovery borrowed replacement authority: %#v", unexpected)
	default:
	}
	if !c.externalRuntimeState.watched(batch.Session.Provider, batch.Session.SessionID) {
		t.Fatal("failed recovery deleted the unresolved obligation")
	}
}

func TestRuntimeExecutionRecoveryPreservesUnownedHostEntries(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	requests := make(chan message, 2)
	attachRuntimeExecutionRecordingTransport(t, c, requests)
	record := testRecoveryObligationRecord("pi", "session-host-list", "dispatch-1", "execution-owned")
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	promoteTestHostExecution(t, c, record.Provider, record.SessionID)
	target, _ := externalRuntimeExecutionTargetFromMap(c.currentComputeRuntimeExecutionTarget())
	if _, err := c.runtimeExecution(context.Background(), "acquire", record.ExecutionID, target.mapValue()); err != nil {
		t.Fatal(err)
	}
	if request := <-requests; stringParam(request.Params, "action") != "acquire" {
		t.Fatalf("Host setup action=%#v, want acquire", request.Params)
	}

	if err := c.externalRuntimeState.reconcileHostExecution(context.Background(), record); err != nil {
		t.Fatal(err)
	}
	request := <-requests
	if stringParam(request.Params, "action") != "list" {
		t.Fatalf("Host reconciliation action=%#v, want list", request.Params)
	}
	select {
	case unexpected := <-requests:
		t.Fatalf("Host reconciliation mutated an extra entry: %#v", unexpected)
	default:
	}
	if !c.externalRuntimeState.watched(record.Provider, record.SessionID) {
		t.Fatal("Host reconciliation dropped the owned execution")
	}
}

func TestTerminalEventAckPrecedesExactHostRelease(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	requests := make(chan message, 4)
	attachRuntimeExecutionRecordingTransport(t, c, requests)
	batch := testRuntimeInputBatch("pi", "session-settlement", "dispatch-1", "message-1")
	persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
	input := c.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch})
	input, err := c.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, input)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.ensureHostExecutionAcquired(input); err != nil {
		t.Fatal(err)
	}
	acquire := <-requests
	if stringParam(acquire.Params, "action") != "acquire" {
		t.Fatalf("first Host action=%#v", acquire)
	}
	input.payload = map[string]any{"session_id": "native-1"}
	if err := c.watchExternalRuntime("pi", input); err != nil {
		t.Fatal(err)
	}
	event := attachRuntimeIdentity(map[string]any{
		"type": "status", "provider": "pi", "state": "settled", "created_at": int64(1),
	}, input.dispatchID, input.executionID, externalRuntimeExecutionSettled)
	if err := c.externalRuntimeState.enqueueExecutionEvent(
		"pi", input.sessionID, input.token, event, externalRuntimeExecutionSettled,
	); err != nil {
		t.Fatal(err)
	}
	c.externalRuntimeState.settleRuntimeExecution()
	select {
	case request := <-requests:
		t.Fatalf("released before terminal event ACK: %#v", request)
	default:
	}

	key := "pi\x00" + input.sessionID
	c.externalRuntimeState.mu.Lock()
	terminalID := c.externalRuntimeState.activeExecutions[key].TerminalEventID
	c.externalRuntimeState.mu.Unlock()
	if err := c.externalRuntimeState.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeSessionEventsBucket).Delete([]byte(terminalID))
	}); err != nil {
		t.Fatal(err)
	}
	c.externalRuntimeState.settleRuntimeExecution()
	release := <-requests
	if stringParam(release.Params, "action") != "release" ||
		stringParam(release.Params, "execution_id") != input.executionID ||
		stringParam(mapParam(release.Params, "target"), "container_instance_id") != "instance-test" {
		t.Fatalf("release=%#v", release)
	}
	if c.externalRuntimeState.watched("pi", input.sessionID) {
		t.Fatal("settled execution survived exact release acknowledgement")
	}
}

func TestSettlementBudgetReportsActionRequiredWithoutDeletingObligation(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	input := externalRuntimeInput{
		provider: "pi", sessionID: "session-old-settlement", dispatchID: "dispatch-1",
		executionID: "execution-1", token: "token", command: "/usr/local/bin/pi",
		workspace: "/tmp/workspace", payload: map[string]any{"session_id": "native-settlement"},
	}
	if err := c.watchExternalRuntime("pi", input); err != nil {
		t.Fatal(err)
	}
	promoteTestHostExecution(t, c, "pi", input.sessionID)
	c.externalRuntimeState.mu.Lock()
	execution := c.externalRuntimeState.activeExecutions["pi\x00"+input.sessionID]
	execution.Phase = externalRuntimeExecutionSettling
	execution.TerminalEventID = "terminal-1"
	execution.SettlingStartedAt = time.Now().Add(-externalRuntimeSettlementBudget - time.Second).Unix()
	_, err := c.externalRuntimeState.storeActiveExecutionLocked(externalRuntimeIdentityFromRecovery(execution.Session), execution)
	c.externalRuntimeState.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	actionRequired, oldest := c.externalRuntimeState.executionBudgetHealth(time.Now())
	if actionRequired != 1 || oldest < int64(externalRuntimeSettlementBudget/time.Second) {
		t.Fatalf("settlement health action_required=%d oldest=%d", actionRequired, oldest)
	}
	if !c.externalRuntimeState.watched("pi", input.sessionID) {
		t.Fatal("budget reporting deleted an unresolved settlement")
	}
}

func TestExpiredSettlementRetriesExactReleaseAfterRestart(t *testing.T) {
	for _, issue := range []string{"", "execution_settlement_unknown"} {
		t.Run("issue="+issue, func(t *testing.T) {
			c := newEventTestConnector(t, t.TempDir())
			input := externalRuntimeInput{
				provider: "pi", sessionID: "ses1_1000000000000000001", dispatchID: "dispatch-1",
				executionID: "execution-1", token: "token", command: "/usr/local/bin/pi",
				workspace: "/tmp/workspace", payload: map[string]any{"session_id": "native-settlement"},
			}
			if err := c.watchExternalRuntime("pi", input); err != nil {
				t.Fatal(err)
			}
			promoteTestHostExecution(t, c, "pi", input.sessionID)
			state := c.externalRuntimeState
			state.mu.Lock()
			execution := state.activeExecutions["pi\x00"+input.sessionID]
			execution.Phase = externalRuntimeExecutionSettling
			execution.TerminalEventID = "terminal-acked"
			execution.SettlingStartedAt = time.Now().Add(-externalRuntimeSettlementBudget - time.Second).Unix()
			execution.SettlementIssue = issue
			_, err := state.storeActiveExecutionLocked(externalRuntimeIdentityFromRecovery(execution.Session), execution)
			state.mu.Unlock()
			if err != nil {
				t.Fatal(err)
			}
			later := testRuntimeInputBatch("pi", input.sessionID, "dispatch-later", "message-later")
			persistRuntimeInputBatch(t, state, later)
			state.close()

			restarted, err := newConnector(config{name: "settlement-restart", root: c.root})
			if err != nil {
				t.Fatal(err)
			}
			defer restarted.externalRuntimeState.close()
			// Hold automatic dispatch so this test can claim the next input without a native CLI.
			restarted.externalRuntimeState.inputCalls.Store(later.Session.key(), struct{}{})
			requests := make(chan message, 4)
			attachRuntimeExecutionRecordingTransport(t, restarted, requests)
			restarted.externalRuntimeState.settleRuntimeExecution()
			request := receiveEventRequest(t, requests)
			if stringParam(request.Params, "action") != "release" ||
				stringParam(request.Params, "execution_id") != input.executionID ||
				stringParam(mapParam(request.Params, "target"), "container_instance_id") != "instance-test" {
				t.Fatalf("unexpected settlement request: %#v", request)
			}
			oldExecutionPresent := func() bool {
				restarted.externalRuntimeState.mu.Lock()
				defer restarted.externalRuntimeState.mu.Unlock()
				current, exists := restarted.externalRuntimeState.activeExecutions[later.Session.key()]
				return exists && current.Session.ExecutionID == input.executionID
			}
			deadline := time.Now().Add(time.Second)
			for oldExecutionPresent() && time.Now().Before(deadline) {
				time.Sleep(time.Millisecond)
			}
			if oldExecutionPresent() {
				t.Fatal("confirmed release retained the old execution")
			}
			batches := []externalRuntimeInputBatch{later}
			nextInput := restarted.externalRuntimeState.inputForBatches(batches)
			nextInput, err = restarted.externalRuntimeState.claimInputBatches(batches, nextInput)
			if err != nil {
				t.Fatalf("later input could not continue after release: %v", err)
			}
			if nextInput.executionID == "" || nextInput.executionID == input.executionID || oldExecutionPresent() {
				t.Fatal("later input did not acquire a distinct execution")
			}
			if err := restarted.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
				if tx.Bucket(externalRuntimeInputBatchesBucket).Get([]byte(later.key())) == nil {
					t.Error("release deleted later input")
				}
				if tx.Bucket(externalRuntimeIdentitiesBucket).Get([]byte("pi\x00"+input.sessionID)) == nil {
					t.Error("release deleted native identity")
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestSlowFailedSettlementDoesNotBlockEventsOrOtherSettlements(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	state := c.externalRuntimeState
	for _, session := range []string{"session-a", "session-b"} {
		input := externalRuntimeInput{
			provider: "pi", sessionID: session, dispatchID: "dispatch-" + session,
			executionID: "execution-" + session, token: "token-" + session,
			command: "/usr/local/bin/pi", workspace: t.TempDir(), payload: map[string]any{"session_id": "native-" + session},
		}
		if err := c.watchExternalRuntime("pi", input); err != nil {
			t.Fatal(err)
		}
		promoteTestHostExecution(t, c, "pi", session)
		state.mu.Lock()
		execution := state.activeExecutions["pi\x00"+session]
		execution.Phase = externalRuntimeExecutionSettling
		execution.TerminalEventID = "acked-" + session
		execution.SettlingStartedAt = time.Now().Unix()
		_, err := state.storeActiveExecutionLocked(externalRuntimeIdentityFromRecovery(execution.Session), execution)
		state.mu.Unlock()
		if err != nil {
			t.Fatal(err)
		}
	}
	releases := make(chan message, 4)
	events := make(chan message, 4)
	unblock := make(chan struct{})
	var attempts atomic.Int32
	transport := &runtimeTransport{done: make(chan struct{})}
	transport.send = func(ctx context.Context, request message) error {
		if request.Method == "external_runtime_events" {
			events <- request
			return nil
		}
		if request.Method != "runtime_execution" || stringParam(request.Params, "action") != "release" {
			return fmt.Errorf("unexpected request: %s", request.Method)
		}
		releases <- request
		if stringParam(request.Params, "execution_id") == "execution-session-a" && attempts.Add(1) == 1 {
			select {
			case <-unblock:
			case <-ctx.Done():
				return ctx.Err()
			}
			return errors.New("Host release temporarily unavailable")
		}
		go c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{"released": true}})
		return nil
	}
	c.sendMu.Lock()
	c.activeTransport = transport
	c.sendMu.Unlock()
	defer transport.close()
	// Start the release before adding the unrelated event.
	state.wake()
	first := receiveEventRequest(t, releases)
	if stringParam(first.Params, "execution_id") != "execution-session-a" {
		t.Fatalf("first release: %#v", first)
	}
	c.forwardRuntimeEvent("unrelated-capability", map[string]any{
		"type": "status", "provider": "codex", "state": "running",
	})
	event := receiveEventRequest(t, events)
	acknowledgeEventRequest(t, c, event)
	waitForDurableEventCount(t, c, 0)
	close(unblock)
	second := receiveEventRequest(t, releases)
	if stringParam(second.Params, "execution_id") != "execution-session-b" {
		t.Fatalf("failed release starved next Session: %#v", second)
	}
	deadline := time.Now().Add(time.Second)
	for state.watched("pi", "session-b") && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if state.watched("pi", "session-b") {
		t.Fatal("successful release did not retire execution")
	}
	if !state.watched("pi", "session-a") {
		t.Fatal("failed release discarded its obligation")
	}
	select {
	case extra := <-releases:
		t.Fatalf("release retried without delay: %#v", extra)
	case <-time.After(100 * time.Millisecond):
	}
	select {
	case retry := <-releases:
		if stringParam(retry.Params, "execution_id") != "execution-session-a" {
			t.Fatalf("unexpected retry: %#v", retry)
		}
	case <-time.After(12 * time.Second):
		t.Fatal("failed settlement did not retry after Host recovery")
	}
	deadline = time.Now().Add(time.Second)
	for state.watched("pi", "session-a") && time.Now().Before(deadline) {
		time.Sleep(time.Millisecond)
	}
	if state.watched("pi", "session-a") {
		t.Fatal("recovered release retained execution")
	}
}

func TestHostOrphanIsObservedWithoutReleaseAndUsesHostAcquiredBudget(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	target, err := externalRuntimeExecutionTargetFromMap(c.currentComputeRuntimeExecutionTarget())
	if err != nil {
		t.Fatal(err)
	}
	requests := make(chan message, 2)
	transport := &runtimeTransport{done: make(chan struct{})}
	transport.send = func(_ context.Context, request message) error {
		requests <- request
		go c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{
			"status": "EXECUTION_LIST_STATUS_PRESENT", "allocation_authority": target.AllocationID,
			"container_instance_id": target.ContainerInstanceID,
			"executions": []any{map[string]any{
				"execution_id": "orphan-main", "owner": fmt.Sprintf("%s:%d", target.RuntimeInstanceID, target.RuntimeGeneration),
				"kind":               "EXECUTION_KIND_MAIN_EXECUTION",
				"acquired_unix_nano": time.Now().Add(-externalRuntimeRecoveryBudget - time.Second).UnixNano(),
			}},
		}})
		return nil
	}
	c.sendMu.Lock()
	c.activeTransport = transport
	c.sendMu.Unlock()
	if err := c.externalRuntimeState.reconcileHostOrphans(context.Background()); err != nil {
		t.Fatal(err)
	}
	request := <-requests
	if stringParam(request.Params, "action") != "list" {
		t.Fatalf("Host orphan inspection action=%#v", request.Params)
	}
	observed, actionRequired := c.externalRuntimeState.hostOrphanBudgetHealth()
	if observed != 1 || actionRequired != 1 {
		t.Fatalf("Host orphan health observed=%d action_required=%d", observed, actionRequired)
	}
	select {
	case request := <-requests:
		t.Fatalf("Host orphan was mutated: %#v", request)
	default:
	}
}

func testRuntimeInputBatch(provider, sessionID, dispatchID, messageID string) externalRuntimeInputBatch {
	return externalRuntimeInputBatch{
		Version: 1,
		Session: externalRuntimeRecoveryRecord{
			Provider: provider, SessionID: sessionID, DispatchID: dispatchID,
			Token: "capability-claim", Command: "/usr/local/bin/pi",
			Workspace: "/tmp/workspace", Payload: map[string]any{},
		},
		Messages: []map[string]any{{"id": messageID, "role": "user", "content": messageID}},
	}
}

func persistRuntimeInputBatch(t *testing.T, state *externalRuntimeState, batch externalRuntimeInputBatch) {
	t.Helper()
	raw, err := json.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	if err := state.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeInputBatchesBucket).Put([]byte(batch.key()), raw)
	}); err != nil {
		t.Fatal(err)
	}
}

type testRuntimeImplementation struct{}

func (testRuntimeImplementation) Send(context.Context, externalRuntimeInput) (map[string]any, string, error) {
	return nil, "", nil
}
func (testRuntimeImplementation) Restore(externalRuntimeInput) error  { return nil }
func (testRuntimeImplementation) Check(context.Context, string) error { return nil }
func (testRuntimeImplementation) AbandonRecovery(externalRuntimeRecoveryRecord, string) bool {
	return true
}
func (testRuntimeImplementation) ReplayObservations() {}
func (testRuntimeImplementation) Close()              {}

func assertRuntimeInputState(
	t *testing.T,
	c *connector,
	wantInputs int,
	wantActive bool,
	wantClaim []string,
) {
	t.Helper()
	c.externalRuntimeState.mu.Lock()
	defer c.externalRuntimeState.mu.Unlock()
	active := c.externalRuntimeState.activeExecutions
	if (len(active) > 0) != wantActive {
		t.Fatalf("active execution presence=%t, want %t: %#v", len(active) > 0, wantActive, active)
	}
	if wantActive {
		for _, execution := range active {
			got := execution.InputBatchIDs
			if !slices.Equal(got, wantClaim) {
				raw, _ := json.Marshal(execution)
				t.Fatalf("active input claim=%v, want %v: %s", got, wantClaim, raw)
			}
		}
	}
	if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
		if got := tx.Bucket(externalRuntimeInputBatchesBucket).Stats().KeyN; got != wantInputs {
			t.Fatalf("input batch count=%d, want %d", got, wantInputs)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestExternalRuntimeStateRootPreservesEventsAcrossWorkspaceRootChange(t *testing.T) {
	stateRoot := t.TempDir()
	open := func(root string) *connector {
		c := &connector{cfg: config{externalStateRoot: stateRoot}, root: root, runtimePending: map[string]runtimePendingRequest{}}
		state, err := newExternalRuntimeState(c)
		if err != nil {
			t.Fatal(err)
		}
		c.externalRuntimeState = state
		return c
	}
	first := open(t.TempDir())
	first.forwardRuntimeEvent("capability", map[string]any{"type": "status", "provider": "codex", "state": "running"})
	event := readOnlyDurableEvent(t, first)
	first.externalRuntimeState.close()
	second := open(t.TempDir())
	defer second.externalRuntimeState.close()
	if got := readOnlyDurableEvent(t, second); got.ID != event.ID {
		t.Fatalf("separate state root lost accepted event: got %s want %s", got.ID, event.ID)
	}
	assertEventDatabaseSecurity(t, stateRoot)
}

func TestExternalRuntimeEventsSurviveRestart(t *testing.T) {
	root := t.TempDir()
	first := newEventTestConnector(t, root)
	startedAt := time.Now().Unix()
	first.forwardRuntimeEvent("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "running",
	})
	item := readOnlyDurableEvent(t, first)
	if _, err := ulid.ParseStrict(item.ID); err != nil {
		t.Fatalf("event id is not a ULID: %q", item.ID)
	}
	event := mapParam(item.Params, "event")
	createdAt, ok := event["created_at"].(float64)
	if !ok || int64(createdAt) < startedAt || int64(createdAt) > time.Now().Unix() {
		t.Fatalf("event execution time was not persisted: %#v", event)
	}
	first.externalRuntimeState.close()
	assertEventDatabaseSecurity(t, root)

	second := newEventTestConnector(t, root)
	defer second.externalRuntimeState.close()
	sent := make(chan message, 1)
	deactivate := activateRuntimeTransportForTest(second, func(message message) error {
		sent <- message
		return nil
	})
	defer deactivate()
	request := receiveEventRequest(t, sent)
	delivered := eventRequestItems(t, request)
	if len(delivered) != 1 || delivered[0].ID != item.ID || delivered[0].Params["event_id"] != item.ID {
		t.Fatalf("restart changed durable event id: %#v", request)
	}
	acknowledgeEventRequest(t, second, request)
	waitForDurableEventCount(t, second, 0)
}

func TestExternalRuntimeStateDropsLegacyToolFailureReminders(t *testing.T) {
	root := t.TempDir()
	first := newEventTestConnector(t, root)
	first.externalRuntimeState.close()

	path := filepath.Join(root, externalRuntimeStateRelativePath)
	db, err := bolt.Open(path, 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Update(func(tx *bolt.Tx) error {
		bucket, err := tx.CreateBucketIfNotExists(legacyExternalRuntimeRemindersBucket)
		if err != nil {
			return err
		}
		return bucket.Put([]byte("legacy-session"), []byte(`{"state":"pending"}`))
	}); err != nil {
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}

	second := newEventTestConnector(t, root)
	defer second.externalRuntimeState.close()
	if err := second.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
		if tx.Bucket(legacyExternalRuntimeRemindersBucket) != nil {
			t.Fatal("legacy tool failure reminder bucket was retained")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestExternalRuntimeEventsRetryOnNextTransport(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	c.forwardRuntimeEvent("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "running",
	})

	firstSent := make(chan message, 1)
	deactivateFirst := activateRuntimeTransportForTest(c, func(message message) error {
		firstSent <- message
		return nil
	})
	first := receiveEventRequest(t, firstSent)
	deactivateFirst()

	secondSent := make(chan message, 1)
	deactivateSecond := activateRuntimeTransportForTest(c, func(message message) error {
		secondSent <- message
		return nil
	})
	defer deactivateSecond()
	second := receiveEventRequest(t, secondSent)
	firstEventID := eventRequestItems(t, first)[0].ID
	secondEventID := eventRequestItems(t, second)[0].ID
	if secondEventID != firstEventID {
		t.Fatalf("reconnect changed event id: first=%s second=%s", firstEventID, secondEventID)
	}
	if second.ID == first.ID {
		t.Fatalf("retry reused transport request id %q", first.ID)
	}
	acknowledgeEventRequest(t, c, second)
	waitForDurableEventCount(t, c, 0)
}

func TestExternalRuntimeEventsDeliverInBoundedBatch(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	for index := range 4 {
		c.forwardRuntimeEvent("capability", map[string]any{
			"type": "status", "provider": "codex", "state": "running", "index": index,
		})
	}

	sent := make(chan message, 1)
	deactivate := activateRuntimeTransportForTest(c, func(message message) error {
		sent <- message
		return nil
	})
	defer deactivate()
	request := receiveEventRequest(t, sent)
	if items := eventRequestItems(t, request); len(items) != 4 {
		t.Fatalf("runtime event batch count=%d, want 4", len(items))
	}
	acknowledgeEventRequest(t, c, request)
	waitForDurableEventCount(t, c, 0)
}

func TestExternalRuntimeEventsRetryRejectedEventWithoutBlockingLaterEvents(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	c.forwardRuntimeEvent("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "first",
	})
	sent := make(chan message, 2)
	deactivate := activateRuntimeTransportForTest(c, func(message message) error {
		sent <- message
		return nil
	})
	defer deactivate()
	first := receiveEventRequest(t, sent)
	acknowledgeEventIDs(c, first, nil)
	c.forwardRuntimeEvent("independent-capability", map[string]any{
		"type": "status", "provider": "codex", "state": "second",
	})
	second := receiveEventRequest(t, sent)
	if eventRequestItems(t, second)[0].ID == eventRequestItems(t, first)[0].ID {
		t.Fatal("rejected event blocked a later event")
	}
	acknowledgeEventRequest(t, c, second)
	waitForDurableEventCount(t, c, 1)

	select {
	case retried := <-sent:
		retriedID := eventRequestItems(t, retried)[0].ID
		firstID := eventRequestItems(t, first)[0].ID
		if retriedID != firstID {
			t.Fatalf("retried event id=%s, want %s", retriedID, firstID)
		}
		acknowledgeEventRequest(t, c, retried)
	case <-time.After(externalRuntimeEventSessionRetryInterval + externalRuntimeEventRetryInterval):
		t.Fatal("rejected event was not retried on the same transport")
	}
	waitForDurableEventCount(t, c, 0)
}

func TestExternalRuntimeEventsReconnectAfterPartialAckKeepsOnlyUnacknowledgedIDs(t *testing.T) {
	for _, restart := range []bool{false, true} {
		t.Run(fmt.Sprintf("restart=%t", restart), func(t *testing.T) {
			root := t.TempDir()
			c := newEventTestConnector(t, root)
			defer func() { c.externalRuntimeState.close() }()
			for _, state := range []string{"running", "settled"} {
				c.forwardRuntimeEvent("capability", map[string]any{
					"type": "status", "provider": "codex", "state": state,
				})
			}

			firstSent := make(chan message, 1)
			deactivateFirst := activateRuntimeTransportForTest(c, func(message message) error {
				firstSent <- message
				return nil
			})
			first := receiveEventRequest(t, firstSent)
			items := eventRequestItems(t, first)
			if len(items) != 2 {
				t.Fatalf("batch count=%d, want 2", len(items))
			}
			acknowledgeEventIDs(c, first, []string{items[0].ID})
			waitForDurableEventCount(t, c, 1)
			deactivateFirst()
			if restart {
				c.externalRuntimeState.close()
				c = newEventTestConnector(t, root)
				if err := c.externalRuntimeState.load(); err != nil {
					t.Fatal(err)
				}
			}

			secondSent := make(chan message, 1)
			deactivateSecond := activateRuntimeTransportForTest(c, func(message message) error {
				secondSent <- message
				return nil
			})
			defer deactivateSecond()
			retry := receiveEventRequest(t, secondSent)
			retried := eventRequestItems(t, retry)
			if len(retried) != 1 || retried[0].ID != items[1].ID {
				t.Fatalf("partial ACK retry=%#v, want only %s", retried, items[1].ID)
			}
			acknowledgeEventRequest(t, c, retry)
			waitForDurableEventCount(t, c, 0)
		})
	}
}

func TestExternalRuntimeUnknownOutcomeReconnectPreservesStableEventIDWithoutSideEffectReplay(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	c.forwardRuntimeEvent("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "running",
		"dispatch_id": "side-effect-dispatch", "execution_id": "side-effect-execution",
	})

	firstSent := make(chan message, 1)
	deactivateFirst := activateRuntimeTransportForTest(c, func(message message) error {
		firstSent <- message
		return nil
	})
	first := receiveEventRequest(t, firstSent)
	firstItem := eventRequestItems(t, first)[0]
	deactivateFirst()

	secondSent := make(chan message, 1)
	deactivateSecond := activateRuntimeTransportForTest(c, func(message message) error {
		secondSent <- message
		return nil
	})
	defer deactivateSecond()
	retry := receiveEventRequest(t, secondSent)
	retryItem := eventRequestItems(t, retry)[0]
	if retryItem.ID != firstItem.ID || retryItem.Params["event_id"] != firstItem.ID {
		t.Fatalf("unknown-outcome retry changed durable identity: first=%#v retry=%#v", firstItem, retryItem)
	}
	acknowledgeEventRequest(t, c, retry)
	waitForDurableEventCount(t, c, 0)
}

func TestExternalRuntimeEventsDoNotSkipConcurrentEarlierCommit(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	firstStarted := make(chan struct{})
	releaseFirst := make(chan struct{})
	var calls atomic.Int32
	c.externalRuntimeState.nextID = func() ulid.ULID {
		if calls.Add(1) == 1 {
			close(firstStarted)
			<-releaseFirst
			return ulid.MustParse("01ARZ3NDEKTSV4RRFFQ69G5FAV")
		}
		return ulid.MustParse("01ARZ3NDEKTSV4RRFFQ69G5FAW")
	}
	sent := make(chan message, 2)
	deactivate := activateRuntimeTransportForTest(c, func(message message) error {
		sent <- message
		return nil
	})
	defer deactivate()
	results := make(chan error, 2)
	go func() {
		results <- c.externalRuntimeState.enqueue("capability", map[string]any{
			"type": "status", "provider": "codex", "state": "first", "created_at": int64(1),
		})
	}()
	<-firstStarted
	go func() {
		results <- c.externalRuntimeState.enqueue("capability", map[string]any{
			"type": "status", "provider": "codex", "state": "second", "created_at": int64(2),
		})
	}()

	delivered := make([]message, 0, 2)
	select {
	case request := <-sent:
		delivered = append(delivered, eventRequestItems(t, request)...)
		acknowledgeEventRequest(t, c, request)
	case <-time.After(20 * time.Millisecond):
	}
	close(releaseFirst)
	for len(delivered) < 2 {
		request := receiveEventRequest(t, sent)
		delivered = append(delivered, eventRequestItems(t, request)...)
		acknowledgeEventRequest(t, c, request)
	}
	for range 2 {
		if err := <-results; err != nil {
			t.Fatal(err)
		}
	}
	if delivered[0].ID >= delivered[1].ID {
		t.Fatalf("delivery order=%q then %q", delivered[0].ID, delivered[1].ID)
	}
	waitForDurableEventCount(t, c, 0)
}

func TestExternalRuntimeEventsDoNotSkipClockRollback(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	ids := []ulid.ULID{
		ulid.MustParse("01ARZ3NDEKTSV4RRFFQ69G5FAW"),
		ulid.MustParse("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
	}
	next := 0
	c.externalRuntimeState.nextID = func() ulid.ULID {
		id := ids[next]
		next++
		return id
	}
	sent := make(chan message, 2)
	deactivate := activateRuntimeTransportForTest(c, func(message message) error {
		sent <- message
		return nil
	})
	defer deactivate()

	if err := c.externalRuntimeState.enqueue("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "first", "created_at": int64(1),
	}); err != nil {
		t.Fatal(err)
	}
	first := receiveEventRequest(t, sent)
	acknowledgeEventRequest(t, c, first)
	waitForDurableEventCount(t, c, 0)

	if err := c.externalRuntimeState.enqueue("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "second", "created_at": int64(2),
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case second := <-sent:
		acknowledgeEventRequest(t, c, second)
		waitForDurableEventCount(t, c, 0)
	case <-time.After(200 * time.Millisecond):
		t.Fatal("event created after a clock rollback was skipped by the transport high-water mark")
	}
}

func TestExternalRuntimeEventCloseDoesNotWaitForBlockedTransportWrite(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	if err := c.externalRuntimeState.enqueue("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "running", "created_at": int64(1),
	}); err != nil {
		t.Fatal(err)
	}
	writeStarted := make(chan struct{})
	releaseWrite := make(chan struct{})
	writeReturned := make(chan struct{})
	deactivate := activateRuntimeTransportForTest(c, func(message message) error {
		close(writeStarted)
		<-releaseWrite
		close(writeReturned)
		return nil
	})
	<-writeStarted
	deactivate()

	closed := make(chan struct{})
	go func() {
		c.externalRuntimeState.close()
		close(closed)
	}()
	select {
	case <-closed:
		close(releaseWrite)
		<-writeReturned
	case <-time.After(200 * time.Millisecond):
		close(releaseWrite)
		<-writeReturned
		<-closed
		t.Fatal("outbox close waited for a transport write after the transport disconnected")
	}
}

func TestExternalRuntimeEventLateOldWriteDoesNotDeleteNewPending(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	if err := c.externalRuntimeState.enqueue("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "running", "created_at": int64(1),
	}); err != nil {
		t.Fatal(err)
	}
	oldWriteStarted := make(chan struct{})
	releaseOldWrite := make(chan struct{})
	oldWriteFinished := make(chan struct{})
	oldWriteError := &observedError{observed: oldWriteFinished}
	deactivateOld := activateRuntimeTransportForTest(c, func(message message) error {
		close(oldWriteStarted)
		<-releaseOldWrite
		return oldWriteError
	})
	<-oldWriteStarted
	deactivateOld()

	newSent := make(chan message, 1)
	deactivateNew := activateRuntimeTransportForTest(c, func(message message) error {
		newSent <- message
		return nil
	})
	defer deactivateNew()
	request := receiveEventRequest(t, newSent)
	close(releaseOldWrite)
	<-oldWriteFinished
	acknowledgeEventRequest(t, c, request)
	waitForDurableEventCount(t, c, 0)
}

func TestExternalRuntimeEventCloseWaitsForAcceptedEnqueue(t *testing.T) {
	root := t.TempDir()
	c := newEventTestConnector(t, root)
	started := make(chan struct{})
	release := make(chan struct{})
	c.externalRuntimeState.nextID = func() ulid.ULID {
		close(started)
		<-release
		return ulid.Make()
	}
	enqueued := make(chan error, 1)
	go func() {
		enqueued <- c.externalRuntimeState.enqueue("capability", map[string]any{
			"type": "status", "provider": "codex", "state": "running", "created_at": int64(1),
		})
	}()
	<-started
	closed := make(chan struct{})
	go func() {
		c.externalRuntimeState.close()
		close(closed)
	}()
	select {
	case <-closed:
		t.Fatal("outbox closed during an accepted enqueue")
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	if err := <-enqueued; err != nil {
		t.Fatal(err)
	}
	<-closed

	reopened := newEventTestConnector(t, root)
	defer reopened.externalRuntimeState.close()
	waitForDurableEventCount(t, reopened, 1)
}

func newEventTestConnector(t *testing.T, root string) *connector {
	t.Helper()
	c := &connector{root: root, runtimePending: map[string]runtimePendingRequest{}}
	c.setComputeRuntimeExecutionTarget(externalRuntimeExecutionTarget{
		RuntimeInstanceID: "runtime-test", RuntimeGeneration: 1,
		RuntimeConnectionEpoch: "connection-test", WorkloadID: "workload-test",
		WorkloadGeneration: 1, AllocationID: "allocation-test", AllocationGeneration: 1,
		ContainerID: "container-test", ContainerInstanceID: "instance-test",
	}.mapValue())
	events, err := newExternalRuntimeState(c)
	if err != nil {
		t.Fatal(err)
	}
	c.externalRuntimeState = events
	return c
}

func attachRuntimeExecutionTestTransport(t *testing.T, c *connector) *runtimeTransport {
	t.Helper()
	return attachRuntimeExecutionRecordingTransport(t, c, nil)
}

func attachRuntimeExecutionRecordingTransport(t *testing.T, c *connector, requests chan<- message) *runtimeTransport {
	t.Helper()
	transport := &runtimeTransport{done: make(chan struct{})}
	var hostMu sync.Mutex
	hostExecutions := map[string]map[string]any{}
	transport.send = func(_ context.Context, request message) error {
		if request.Method != "runtime_execution" {
			return fmt.Errorf("unexpected runtime method %q", request.Method)
		}
		target := mapParam(request.Params, "target")
		result := map[string]any{
			"execution_id":          stringParam(request.Params, "execution_id"),
			"container_instance_id": stringParam(target, "container_instance_id"),
		}
		switch stringParam(request.Params, "action") {
		case "acquire":
			hostMu.Lock()
			hostExecutions[stringParam(request.Params, "execution_id")] = map[string]any{
				"execution_id": stringParam(request.Params, "execution_id"),
				"owner":        fmt.Sprintf("%s:%d", stringParam(target, "runtime_instance_id"), intParam(target, "runtime_generation", 0)),
				"kind":         "EXECUTION_KIND_MAIN_EXECUTION",
			}
			hostMu.Unlock()
			result["acquired"] = true
		case "release":
			hostMu.Lock()
			delete(hostExecutions, stringParam(request.Params, "execution_id"))
			hostMu.Unlock()
			result["released"] = true
		case "list":
			result["allocation_authority"] = stringParam(target, "allocation_id")
			items := []any{map[string]any{
				"execution_id": "unowned-host-orphan",
				"owner":        "another-runtime:1",
				"kind":         "EXECUTION_KIND_MAIN_EXECUTION",
			}}
			hostMu.Lock()
			for _, item := range hostExecutions {
				items = append(items, maps.Clone(item))
			}
			hostMu.Unlock()
			result["status"] = "EXECUTION_LIST_STATUS_PRESENT"
			result["executions"] = items
		default:
			return errors.New("unexpected runtime execution action")
		}
		if requests != nil {
			requests <- request
		}
		go c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: result})
		return nil
	}
	c.sendMu.Lock()
	c.activeTransport = transport
	c.sendMu.Unlock()
	t.Cleanup(func() { transport.close() })
	return transport
}

func promoteTestHostExecution(t *testing.T, c *connector, provider, sessionID string) {
	t.Helper()
	key := provider + "\x00" + sessionID
	c.externalRuntimeState.mu.Lock()
	defer c.externalRuntimeState.mu.Unlock()
	execution, ok := c.externalRuntimeState.activeExecutions[key]
	if !ok {
		t.Fatalf("missing test execution %q", key)
	}
	execution.Version = 3
	execution.Target, _ = externalRuntimeExecutionTargetFromMap(c.currentComputeRuntimeExecutionTarget())
	execution.HostAcquired = true
	execution.RecoveryStartedAt = time.Now().Unix()
	if _, err := c.externalRuntimeState.storeActiveExecutionLocked(
		externalRuntimeIdentityFromRecovery(execution.Session), execution,
	); err != nil {
		t.Fatal(err)
	}
}

func settleTestHostExecution(t *testing.T, c *connector, provider, sessionID string) {
	t.Helper()
	key := provider + "\x00" + sessionID
	c.externalRuntimeState.mu.Lock()
	defer c.externalRuntimeState.mu.Unlock()
	if err := c.externalRuntimeState.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeActiveExecutionsBucket).Delete([]byte(key))
	}); err != nil {
		t.Fatal(err)
	}
	c.externalRuntimeState.deleteActiveExecutionLocked(key)
}

func readOnlyDurableEvent(t *testing.T, c *connector) message {
	t.Helper()
	end, err := c.externalRuntimeState.eventScanEnd()
	if err != nil {
		t.Fatal(err)
	}
	items, _, err := c.externalRuntimeState.nextBatch("", end, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 1 {
		t.Fatalf("durable event count=%d, want 1", len(items))
	}
	return items[0]
}

func receiveEventRequest(t *testing.T, sent <-chan message) message {
	t.Helper()
	select {
	case request := <-sent:
		return request
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for external runtime event")
		return message{}
	}
}

func eventRequestItems(t *testing.T, request message) []message {
	t.Helper()
	if request.Method == "external_runtime_event" {
		item := request
		item.ID, _ = request.Params["event_id"].(string)
		return []message{item}
	}
	if request.Method != "external_runtime_events" {
		t.Fatalf("unexpected external runtime event method %q", request.Method)
	}
	raw, ok := request.Params["events"].([]map[string]any)
	if !ok || len(raw) == 0 {
		t.Fatalf("invalid external runtime event batch: %#v", request)
	}
	items := make([]message, len(raw))
	for index, params := range raw {
		id, _ := params["event_id"].(string)
		items[index] = message{ID: id, Type: "request", Method: "external_runtime_event", Params: params}
	}
	return items
}

func acknowledgeEventRequest(t *testing.T, c *connector, request message) {
	t.Helper()
	items := eventRequestItems(t, request)
	ids := make([]string, len(items))
	for index, item := range items {
		ids[index] = item.ID
	}
	acknowledgeEventIDs(c, request, ids)
}

func acknowledgeEventIDs(c *connector, request message, ids []string) {
	accepted := make([]any, len(ids))
	for index, id := range ids {
		accepted[index] = id
	}
	c.completeRuntimeProxy(message{
		ID: request.ID, Type: "response", Result: map[string]any{"accepted_event_ids": accepted},
	})
}

func waitForDurableEventCount(t *testing.T, c *connector, count int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		current := -1
		err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
			current = tx.Bucket(externalRuntimeSessionEventsBucket).Stats().KeyN
			return nil
		})
		if err == nil && current == count {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("durable event count did not reach %d", count)
}

func assertEventDatabaseSecurity(t *testing.T, root string) {
	t.Helper()
	dir := filepath.Join(root, "external-runtime")
	for path, want := range map[string]os.FileMode{dir: 0o700, filepath.Join(dir, "state.db"): 0o600} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != want {
			t.Fatalf("%s mode=%o, want %o", path, info.Mode().Perm(), want)
		}
	}
}

type observedError struct {
	once     sync.Once
	observed chan struct{}
}

func (e *observedError) Error() string {
	e.once.Do(func() { close(e.observed) })
	return "old transport write failed"
}

func persistRuntimeIdentity(t *testing.T, state *externalRuntimeState, identity externalRuntimeSessionIdentity) {
	t.Helper()
	raw, err := json.Marshal(externalRuntimeSessionIdentityFile{Version: 2, Identity: identity})
	if err != nil {
		t.Fatal(err)
	}
	if err := state.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeIdentitiesBucket).Put([]byte(identity.key()), raw)
	}); err != nil {
		t.Fatal(err)
	}
	state.mu.Lock()
	state.identities[identity.key()] = identity
	state.addRuntimeSessionLocked(identity)
	state.mu.Unlock()
}

func settleWatchedExecution(t *testing.T, c *connector, record externalRuntimeRecoveryRecord) {
	t.Helper()
	event := attachRuntimeIdentity(map[string]any{
		"type": "status", "provider": record.Provider, "state": "settled", "created_at": int64(1),
	}, record.DispatchID, record.ExecutionID, externalRuntimeExecutionSettled)
	if err := c.externalRuntimeState.enqueueExecutionEvent(
		record.Provider, record.SessionID, record.Token, event, externalRuntimeExecutionSettled,
	); err != nil {
		t.Fatal(err)
	}
}

func TestRuntimeAuthBusyIndexTracksExecutionOwner(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	state := c.externalRuntimeState
	first := testRecoveryObligationRecord("pi", "busy-first", "dispatch-first", "execution-first")
	second := testRecoveryObligationRecord("pi", "busy-second", "dispatch-second", "execution-second")
	target := runtimeProbeTarget{provider: first.Provider, identityMaterial: first.Command}
	for _, record := range []externalRuntimeRecoveryRecord{first, second, first} {
		if err := state.watch(record); err != nil {
			t.Fatal(err)
		}
	}
	settleWatchedExecution(t, c, first)
	settleWatchedExecution(t, c, first) // duplicate completion cannot release second
	if !state.targetHasActiveExecution(target) {
		t.Fatal("one terminal session concealed another active execution")
	}
	settleWatchedExecution(t, c, second)
	if state.targetHasActiveExecution(target) {
		t.Fatal("settled identities remained busy")
	}
	state.mu.Lock()
	defer state.mu.Unlock()
	if len(state.activeTargets) != 0 {
		t.Fatal("completed targets retained busy index entries")
	}
}

func TestPruneIdleIdentitiesRespectsTTLObligationsAndPendingInput(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	state := c.externalRuntimeState
	ttl := int64(externalRuntimeIdentityIdleTTL / time.Second)

	// A: settled → identity only, stamped with the current wall clock.
	recordA := testRecoveryObligationRecord("pi", "session-cold", "dispatch-a", "execution-a")
	if err := state.watch(recordA); err != nil {
		t.Fatal(err)
	}
	settleWatchedExecution(t, c, recordA)

	// B: outstanding obligation — never pruned regardless of staleness.
	recordB := testRecoveryObligationRecord("pi", "session-obligation", "dispatch-b", "execution-b")
	if err := state.watch(recordB); err != nil {
		t.Fatal(err)
	}

	// C: legacy identity with no activity record.
	identityC := externalRuntimeSessionIdentity{
		Provider: "pi", SessionID: "session-legacy", Command: "/usr/local/bin/pi",
		Workspace: "/tmp/workspace", Payload: map[string]any{},
	}
	persistRuntimeIdentity(t, state, identityC)

	// D: settled but with pending input — the inbox row keeps it alive.
	recordD := testRecoveryObligationRecord("pi", "session-pending-input", "dispatch-d", "execution-d")
	if err := state.watch(recordD); err != nil {
		t.Fatal(err)
	}
	settleWatchedExecution(t, c, recordD)
	// This test owns pruning, not delivery. Stop the background input consumer
	// before adding inbox rows so it cannot convert the pending row into an
	// active execution while the test checks the ledger.
	state.cancel()
	state.worker.Wait()
	persistRuntimeInputBatch(t, state, testRuntimeInputBatch("pi", "session-pending-input", "dispatch-d2", "message-d2"))

	if resumable, _, _, _ := state.healthCounts(); resumable != 4 {
		t.Fatalf("setup expected 4 identities, got %d", resumable)
	}

	nowStale := time.Now().Unix() + ttl + 3600
	stamped, pruned := state.pruneIdleIdentities(nowStale)
	if stamped != 1 || pruned != 1 {
		t.Fatalf("first pass: stamped=%d pruned=%d, want 1/1", stamped, pruned)
	}
	if resumable, _, _, _ := state.healthCounts(); resumable != 3 {
		t.Fatalf("cold identity not pruned: resumable=%d", resumable)
	}
	if !state.watched("pi", "session-obligation") {
		t.Fatal("obligation-bearing identity lost its execution")
	}

	// Same instant again: the freshly stamped legacy identity is not stale yet
	// and nothing else qualifies.
	if stamped, pruned := state.pruneIdleIdentities(nowStale); stamped != 0 || pruned != 0 {
		t.Fatalf("second pass mutated state: stamped=%d pruned=%d", stamped, pruned)
	}

	// One TTL later the stamped legacy identity expires; the obligation and
	// the pending-input identity still survive.
	nowLater := nowStale + ttl + 3600
	if stamped, pruned := state.pruneIdleIdentities(nowLater); stamped != 0 || pruned != 1 {
		t.Fatalf("third pass: stamped=%d pruned=%d, want 0/1", stamped, pruned)
	}
	if resumable, recoverable, inputBatches, _ := state.healthCounts(); resumable != 2 || recoverable != 1 || inputBatches != 1 {
		t.Fatalf("final ledger wrong: resumable=%d recoverable=%d inputBatches=%d", resumable, recoverable, inputBatches)
	}
	if err := state.db.View(func(tx *bolt.Tx) error {
		if tx.Bucket(externalRuntimeIdentitiesBucket).Get([]byte(identityC.key())) != nil {
			t.Fatal("legacy identity survived its stamped TTL")
		}
		if tx.Bucket(externalRuntimeIdentitiesBucket).Get([]byte("pi\x00session-pending-input")) == nil {
			t.Fatal("pending-input identity was pruned")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestPruneIdleExternalRuntimeIdentitiesIsIntervalGated(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	state := c.externalRuntimeState

	record := testRecoveryObligationRecord("pi", "session-gate", "dispatch-g", "execution-g")
	if err := state.watch(record); err != nil {
		t.Fatal(err)
	}
	settleWatchedExecution(t, c, record)

	base := time.Now().Add(externalRuntimeIdentityIdleTTL + time.Hour)
	c.pruneIdleExternalRuntimeIdentities(base)
	if resumable, _, _, _ := state.healthCounts(); resumable != 0 {
		t.Fatalf("stale identity survived the first gate pass: resumable=%d", resumable)
	}

	// A second identity that is unambiguously expired: if the prune ran, it
	// would be removed. Its survival inside the interval proves the gate
	// blocked the pass, not that the TTL spared it.
	expired := externalRuntimeSessionIdentity{
		Provider: "pi", SessionID: "session-gate-2", Command: "/usr/local/bin/pi",
		Workspace: "/tmp/workspace", Payload: map[string]any{}, LastActivityAt: 1,
	}
	persistRuntimeIdentity(t, state, expired)

	c.pruneIdleExternalRuntimeIdentities(base.Add(externalRuntimeIdentityPruneInterval / 2))
	if resumable, _, _, _ := state.healthCounts(); resumable != 1 {
		t.Fatal("prune ran inside the gate interval")
	}

	c.pruneIdleExternalRuntimeIdentities(base.Add(externalRuntimeIdentityPruneInterval + time.Minute))
	if resumable, _, _, _ := state.healthCounts(); resumable != 0 {
		t.Fatal("gate did not reopen after the interval")
	}
}

// The rollout cohort from the PR: 759 identities that predate activity
// tracking. One maintenance pass must not stall live input staging — the
// reviewed per-row-transaction shape blocked a concurrent enqueueInputBatch
// for the full multi-second pass.
func TestPruneIdleIdentitiesRolloutCohortDoesNotStallLiveInput(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	state := c.externalRuntimeState

	const cohort = 759
	identities := make([]externalRuntimeSessionIdentity, 0, cohort)
	if err := state.db.Update(func(tx *bolt.Tx) error {
		bucket := tx.Bucket(externalRuntimeIdentitiesBucket)
		for index := range cohort {
			identity := externalRuntimeSessionIdentity{
				Provider: "pi", SessionID: fmt.Sprintf("session-cohort-%03d", index),
				Command: "/usr/local/bin/pi", Workspace: "/tmp/workspace", Payload: map[string]any{},
			}
			raw, err := json.Marshal(externalRuntimeSessionIdentityFile{Version: 2, Identity: identity})
			if err != nil {
				return err
			}
			if err := bucket.Put([]byte(identity.key()), raw); err != nil {
				return err
			}
			identities = append(identities, identity)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	state.mu.Lock()
	for _, identity := range identities {
		state.identities[identity.key()] = identity
		state.addRuntimeSessionLocked(identity)
	}
	state.mu.Unlock()

	// Live input staged concurrently with the maintenance passes; its latency
	// is the availability contract under review. The delivery worker is held
	// off the live session (inputCalls guard) so the test measures staging
	// latency, not the fake implementation's delivery.
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": testRuntimeImplementation{}}
	state.inputCalls.Store("pi\x00session-live", struct{}{})
	defer state.inputCalls.Delete("pi\x00session-live")
	const inputLatencyBound = 2 * time.Second
	stop := make(chan struct{})
	inputErr := make(chan error, 1)
	go func() {
		defer close(inputErr)
		sequence := 0
		for {
			select {
			case <-stop:
				return
			default:
			}
			sequence++
			input := externalRuntimeInput{
				sessionID: "session-live", dispatchID: fmt.Sprintf("dispatch-live-%04d", sequence),
				token: "capability-claim", command: "/usr/local/bin/pi", workspace: "/tmp/workspace",
				payload:  map[string]any{},
				messages: []map[string]any{{"id": fmt.Sprintf("m-%04d", sequence), "role": "user", "content": "live"}},
				batchIDs: []string{fmt.Sprintf("dispatch-live-%04d", sequence)},
			}
			started := time.Now()
			err := state.enqueueInputBatch("pi", input)
			if elapsed := time.Since(started); err != nil || elapsed > inputLatencyBound {
				inputErr <- fmt.Errorf("live input stalled: err=%v elapsed=%s", err, elapsed)
				return
			}
		}
	}()

	// The stamp phase drains the cohort across bounded passes.
	nowStamp := time.Now().Unix()
	totalStamped := 0
	for pass := 0; pass < 8 && totalStamped < cohort; pass++ {
		started := time.Now()
		stamped, pruned := state.pruneIdleIdentities(nowStamp)
		if elapsed := time.Since(started); elapsed > inputLatencyBound {
			t.Fatalf("stamp pass %d took %s", pass, elapsed)
		}
		if pruned != 0 {
			t.Fatalf("stamp phase pruned %d identities", pruned)
		}
		if stamped > externalRuntimeIdentityPrunePassLimit {
			t.Fatalf("pass exceeded its mutation bound: %d", stamped)
		}
		totalStamped += stamped
	}
	if totalStamped != cohort {
		t.Fatalf("cohort not fully stamped: %d/%d", totalStamped, cohort)
	}

	// The synchronized 30-day expiration drains the same way.
	ttl := int64(externalRuntimeIdentityIdleTTL / time.Second)
	nowExpire := nowStamp + ttl + 3600
	totalPruned := 0
	for pass := 0; pass < 8 && totalPruned < cohort; pass++ {
		started := time.Now()
		stamped, pruned := state.pruneIdleIdentities(nowExpire)
		if elapsed := time.Since(started); elapsed > inputLatencyBound {
			t.Fatalf("expire pass %d took %s", pass, elapsed)
		}
		if stamped != 0 {
			t.Fatalf("expire phase stamped %d identities", stamped)
		}
		totalPruned += pruned
	}
	if totalPruned != cohort {
		t.Fatalf("cohort not fully expired: %d/%d", totalPruned, cohort)
	}

	close(stop)
	if err := <-inputErr; err != nil {
		t.Fatal(err)
	}
	if resumable, _, _, _ := state.healthCounts(); resumable != 0 {
		t.Fatalf("cohort left residue: resumable=%d", resumable)
	}
}

// Stamping a legacy identity deliberately refreshes the workspace archiver's
// activity view: sessionActivity starts reporting the stamp, so the archiver
// skips its workspace-mtime fallback for the next idle window.
func TestPruneStampRefreshesArchiverActivityView(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	state := c.externalRuntimeState

	legacy := externalRuntimeSessionIdentity{
		Provider: "pi", SessionID: "session-legacy-view", Command: "/usr/local/bin/pi",
		Workspace: "/tmp/workspace", Payload: map[string]any{},
	}
	persistRuntimeIdentity(t, state, legacy)
	if _, tracked := state.sessionActivity()["session-legacy-view"]; tracked {
		t.Fatal("legacy identity reported activity before the stamp")
	}

	now := time.Now().Unix()
	if stamped, pruned := state.pruneIdleIdentities(now); stamped != 1 || pruned != 0 {
		t.Fatalf("stamp pass: stamped=%d pruned=%d", stamped, pruned)
	}
	if at, tracked := state.sessionActivity()["session-legacy-view"]; !tracked || at != now {
		t.Fatalf("stamp not visible to the archiver activity view: at=%d tracked=%v", at, tracked)
	}
}
