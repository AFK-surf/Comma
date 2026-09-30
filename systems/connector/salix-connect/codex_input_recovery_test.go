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
	"strings"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

func TestHostCodexUnboundExecutionRetainsAcquisitionFence(t *testing.T) {
	for _, acquired := range []bool{false, true} {
		t.Run(fmt.Sprintf("host_acquired=%t", acquired), func(t *testing.T) {
			root := t.TempDir()
			logPath := filepath.Join(t.TempDir(), "codex.log")
			command := fakeCodexCommand(t, logPath, nil)
			first := newEventTestConnector(t, root)
			defer first.externalRuntimeState.close()
			target, err := externalRuntimeExecutionTargetFromMap(first.currentComputeRuntimeExecutionTarget())
			if err != nil {
				t.Fatal(err)
			}
			batch := testRuntimeInputBatch("codex", "host-unbound", "dispatch-host", "original-message")
			batch.Session.Command, batch.Session.Workspace = command, t.TempDir()
			persistRuntimeInputBatch(t, first.externalRuntimeState, batch)
			input, err := first.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, first.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch}))
			if err != nil {
				t.Fatal(err)
			}
			if acquired {
				attachRuntimeExecutionTestTransport(t, first)
				if err := first.externalRuntimeState.ensureHostExecutionAcquired(input); err != nil {
					t.Fatal(err)
				}
			}
			// Another Session already has a native binding; loading the unstarted
			// claim must not delete or replace this independent recovery obligation.
			bound := testRuntimeInputBatch("codex", "host-bound", "dispatch-bound", "bound-message")
			bound.Session.Command, bound.Session.Workspace = command, t.TempDir()
			persistRuntimeInputBatch(t, first.externalRuntimeState, bound)
			boundInput, err := first.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{bound}, first.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{bound}))
			if err != nil {
				t.Fatal(err)
			}
			boundInput.payload = map[string]any{"thread_id": "thread-bound"}
			if err := first.watchExternalRuntime("codex", boundInput); err != nil {
				t.Fatal(err)
			}
			first.externalRuntimeState.close()

			c, err := newConnector(config{root: root})
			if err != nil {
				t.Fatalf("unstarted Host claim prevents Connector restart: %v", err)
			}
			defer func() {
				c.closeExternalRuntimes()
				if c.bridgeServer != nil {
					_ = c.bridgeServer.Shutdown(context.Background())
				}
			}()
			assertClaim := func() {
				t.Helper()
				c.externalRuntimeState.mu.Lock()
				execution := c.externalRuntimeState.activeExecutions[batch.Session.key()]
				other := c.externalRuntimeState.activeExecutions[bound.Session.key()]
				c.externalRuntimeState.mu.Unlock()
				if execution.Version != 3 || execution.Session.ExecutionID != input.executionID || execution.Target != target || execution.HostAcquired != acquired || !slices.Equal(execution.InputBatchIDs, []string{batch.Session.DispatchID}) {
					t.Fatalf("Host acquisition fence changed: %#v", execution)
				}
				if other.Session.ExecutionID != boundInput.executionID || stringParam(other.Session.Payload, "thread_id") != "thread-bound" {
					t.Fatalf("independent native binding changed: %#v", other)
				}
				if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
					key := []byte(batch.key())
					saved, err := decodeExternalRuntimeInputBatch(key, tx.Bucket(externalRuntimeInputBatchesBucket).Get(key))
					if err != nil {
						return err
					}
					if saved.Session.Token != batch.Session.Token || saved.Messages[0]["content"] != "original-message" {
						t.Fatalf("durable input changed: %#v", saved)
					}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
				log, _ := os.ReadFile(logPath)
				if strings.Contains(string(log), "original-message") {
					t.Fatalf("unverified claim reached native runtime: %s", log)
				}
			}
			check := func() {
				c.externalRuntimeRecoveryFailures = map[string]externalRuntimeRecoveryStreak{}
				c.checkExternalRuntimes(context.Background())
			}
			// No transport cannot establish execution authority.
			check()
			assertClaim()
			transport := attachRuntimeExecutionTestTransport(t, c)
			hostSend := transport.send
			send := func(ctx context.Context, request message) error {
				if request.Method == "runtime_subscription_access" {
					c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{"bound": false}})
					return nil
				}
				return hostSend(ctx, request)
			}
			// An observation from another container is not proof of the saved right.
			transport.send = func(ctx context.Context, request message) error {
				request.Params = maps.Clone(request.Params)
				observedTarget := maps.Clone(mapParam(request.Params, "target"))
				observedTarget["container_instance_id"] = "other-instance"
				request.Params["target"] = observedTarget
				return send(ctx, request)
			}
			c.setComputeRuntimeExecutionTarget(target.mapValue())
			check()
			assertClaim()
			transport.send = send
			// If the old right is absent, a new container must not acquire it against
			// a different target. An already acquired but absent right also stays fenced.
			replacement := target
			replacement.ContainerInstanceID = "replacement-instance"
			c.setComputeRuntimeExecutionTarget(replacement.mapValue())
			check()
			assertClaim()
			c.setComputeRuntimeExecutionTarget(target.mapValue())
			if acquired {
				// Recreate the fixture Host's retained right, not a production migration.
				if _, err := c.runtimeExecution(context.Background(), "acquire", input.executionID, target.mapValue()); err != nil {
					t.Fatal(err)
				}
			}
			check()
			log, err := os.ReadFile(logPath)
			if err != nil {
				t.Fatal(err)
			}
			deliveries := 0
			for _, line := range strings.Split(string(log), "\n") {
				if strings.HasPrefix(line, "turn/start ") && strings.Contains(line, "original-message") {
					deliveries++
				}
			}
			if deliveries != 1 {
				t.Fatalf("original batch deliveries = %d: %s", deliveries, log)
			}
			c.externalRuntimeState.mu.Lock()
			execution := c.externalRuntimeState.activeExecutions[batch.Session.key()]
			c.externalRuntimeState.mu.Unlock()
			threadID := stringParam(execution.Session.Payload, "thread_id")
			if execution.Session.ExecutionID != input.executionID || execution.Target != target || !execution.HostAcquired || len(execution.InputBatchIDs) != 0 || threadID == "" || execution.Phase == externalRuntimeExecutionInterrupted {
				t.Fatalf("retry failed to retain authority and bind its native thread: %#v", execution)
			}
			if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
				if tx.Bucket(externalRuntimeInputBatchesBucket).Get([]byte(batch.key())) != nil {
					t.Fatal("accepted batch remains pending")
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			c.closeExternalRuntimes()
			if c.bridgeServer != nil {
				_ = c.bridgeServer.Shutdown(context.Background())
			}
			c, err = newConnector(config{root: root})
			if err != nil {
				t.Fatalf("bound native Session cannot restart: %v", err)
			}
			implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
			implementation.mu.Lock()
			restored, other := implementation.sessions[batch.Session.SessionID], implementation.sessions[bound.Session.SessionID]
			implementation.mu.Unlock()
			if restored == nil || other == nil {
				t.Fatal("restart lost a native Session")
			}
			restored.mu.Lock()
			restoredThread, restoredID := restored.threadID, restored.executionID
			restored.mu.Unlock()
			other.mu.Lock()
			otherThread := other.threadID
			other.mu.Unlock()
			if restoredThread != threadID || restoredID != input.executionID || otherThread != "thread-bound" {
				t.Fatal("restart changed native Session bindings")
			}
		})
	}
}

func TestCodexMissingInputBatchDoesNotBlockOtherSessions(t *testing.T) {
	for _, scenario := range []struct {
		name           string
		host, settling bool
	}{
		{name: "legacy"},
		{name: "host", host: true}, {name: "settling", host: true, settling: true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			root := t.TempDir()
			logPath := filepath.Join(t.TempDir(), "native.log")
			command := fakeCodexCommand(t, logPath, map[string]string{"SALIX_TEST_FAKE_CODEX_MISSING_THREAD_ON_RESUME": "1"})
			first := newEventTestConnector(t, root)
			defer first.externalRuntimeState.close()
			pending := testRuntimeInputBatch("codex", "missing-input", "next-dispatch", "must-retain")
			pending.Session.Command, pending.Session.Workspace = command, t.TempDir()
			persistRuntimeInputBatch(t, first.externalRuntimeState, pending)
			input := pending.Session.input()
			input.dispatchID, input.executionID = "missing-input-dispatch", "missing-input-execution"
			if err := first.watchExternalRuntime("codex", input); err != nil {
				t.Fatal(err)
			}
			if scenario.host {
				promoteTestHostExecution(t, first, "codex", input.sessionID)
				first.externalRuntimeState.mu.Lock()
				execution := first.externalRuntimeState.activeExecutions[pending.Session.key()]
				execution.RecoveryStartedAt = time.Now().Add(-externalRuntimeRecoveryBudget - time.Second).Unix()
				_, err := first.externalRuntimeState.storeActiveExecutionLocked(externalRuntimeIdentityFromRecovery(execution.Session), execution)
				first.externalRuntimeState.mu.Unlock()
				if err != nil {
					t.Fatal(err)
				}
			}
			if scenario.settling {
				event := attachRuntimeIdentity(map[string]any{"type": "status", "provider": "codex", "state": "settled", "created_at": int64(1)}, input.dispatchID, input.executionID, externalRuntimeExecutionSettled)
				if err := first.externalRuntimeState.enqueueExecutionEvent("codex", input.sessionID, input.token, event, externalRuntimeExecutionSettled); err != nil {
					t.Fatal(err)
				}
			}
			first.externalRuntimeState.mu.Lock()
			expected := first.externalRuntimeState.activeExecutions[pending.Session.key()]
			first.externalRuntimeState.mu.Unlock()
			healthy := pending.Session.input()
			healthy.sessionID, healthy.dispatchID, healthy.executionID = "healthy", "healthy-dispatch", "healthy-execution"
			healthy.payload = map[string]any{"thread_id": "old-native-thread"}
			if err := first.watchExternalRuntime("codex", healthy); err != nil {
				t.Fatal(err)
			}
			first.externalRuntimeState.close()
			c, err := newConnector(config{root: root})
			if err != nil {
				t.Fatalf("one missing native binding prevents Connector startup: %v", err)
			}
			defer func() {
				c.closeExternalRuntimes()
				if c.bridgeServer != nil {
					_ = c.bridgeServer.Shutdown(context.Background())
				}
			}()
			implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
			implementation.mu.Lock()
			emptyRoute := implementation.threads[""]
			implementation.mu.Unlock()
			if emptyRoute != "" {
				t.Fatal("missing binding registered an empty native route")
			}
			if err := implementation.Check(context.Background(), input.sessionID); err == nil || !strings.Contains(err.Error(), "input batch") {
				t.Fatalf("missing binding was silently healthy: %v", err)
			}
			transport := &runtimeTransport{done: make(chan struct{})}
			transport.send = func(_ context.Context, request message) error {
				if request.Method == "runtime_subscription_access" {
					c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{"bound": false}})
					return nil
				}
				// Unavailable authority and unacknowledged events must not make recovery
				// exhaustion discard input or manufacture a terminal acknowledgment.
				return errors.New("test Host unavailable")
			}
			c.sendMu.Lock()
			c.activeTransport = transport
			c.sendMu.Unlock()
			defer transport.close()
			for n := 0; n < (externalRuntimeRecoveryFailureBudget+2)*externalRuntimeRecoveryBackoffCapTicks; n++ {
				c.checkExternalRuntimes(context.Background())
			}
			if !scenario.settling && c.externalRuntimeRecoveryFailures[pending.Session.key()].count < externalRuntimeRecoveryFailureBudget {
				t.Fatal("test did not exhaust the recovery failure budget")
			}
			assertRetained := func() {
				t.Helper()
				c.externalRuntimeState.mu.Lock()
				saved, exists := c.externalRuntimeState.activeExecutions[pending.Session.key()]
				c.externalRuntimeState.mu.Unlock()
				if !exists || saved.Version != expected.Version || saved.Session.ExecutionID != input.executionID || saved.Session.DispatchID != input.dispatchID || saved.Target != expected.Target || saved.HostAcquired != expected.HostAcquired || !slices.Equal(saved.InputBatchIDs, expected.InputBatchIDs) || saved.TerminalEventID != expected.TerminalEventID {
					t.Fatalf("missing-input execution facts changed: %#v", saved)
				}
				if scenario.settling && saved.Phase != externalRuntimeExecutionSettling {
					t.Fatalf("terminal settlement changed: %#v", saved)
				}
				if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
					if tx.Bucket(externalRuntimeInputBatchesBucket).Get([]byte(pending.key())) == nil {
						t.Fatal("pending input was discarded")
					}
					if scenario.settling && tx.Bucket(externalRuntimeSessionEventsBucket).Get([]byte(expected.TerminalEventID)) == nil {
						t.Fatal("terminal evidence was acknowledged without authority")
					}
					return nil
				}); err != nil {
					t.Fatal(err)
				}
			}
			assertRetained()
			nativeLog, err := os.ReadFile(logPath)
			if err != nil {
				t.Fatal(err)
			}
			if strings.Contains(string(nativeLog), "must-retain") {
				t.Fatalf("missing-input input was replayed: %s", nativeLog)
			}
			// The other Session has a persisted thread ID but no native history.
			// Its existing recreate-and-continue path must remain usable.
			if !strings.Contains(string(nativeLog), "thread/resume ") || !strings.Contains(string(nativeLog), "thread/start ") || !strings.Contains(string(nativeLog), "turn/start ") || !strings.Contains(string(nativeLog), externalRuntimeRecreatedMessage) {
				t.Fatalf("healthy Session did not recreate missing native history: %s", nativeLog)
			}
			if strings.Count(string(nativeLog), "thread/start ") != 1 {
				t.Fatalf("missing binding created extra native threads: %s", nativeLog)
			}
			c.closeExternalRuntimes()
			if c.bridgeServer != nil {
				_ = c.bridgeServer.Shutdown(context.Background())
			}
			transport.close()
			c, err = newConnector(config{root: root})
			if err != nil {
				t.Fatalf("retained missing-input Session prevents subsequent restart: %v", err)
			}
			assertRetained()
		})
	}
}

// Both the legacy inbox association and a current direct claim retain their
// execution ID. Startup must recover the original batch, not allocate a new one.
func TestDirectCodexUnboundExecutionDoesNotPreventConnectorStartup(t *testing.T) {
	for _, version := range []int{2, 4} {
		t.Run(fmt.Sprintf("version=%d", version), func(t *testing.T) {
			root, logPath := t.TempDir(), filepath.Join(t.TempDir(), "native.log")
			first := newEventTestConnector(t, root)
			first.setComputeRuntimeExecutionTarget(nil)
			batch := testRuntimeInputBatch("codex", "direct-unbound", "original-dispatch", "original-direct-input")
			batch.Session.Command, batch.Session.Workspace = fakeCodexCommand(t, logPath, nil), t.TempDir()
			persistRuntimeInputBatch(t, first.externalRuntimeState, batch)
			input, err := first.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, first.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch}))
			if err != nil {
				t.Fatal(err)
			}
			// A legacy row and a failed older restart can both lack InputBatchIDs.
			// Normalize must recover that association from the matching durable inbox.
			if err := first.externalRuntimeState.db.Update(func(tx *bolt.Tx) error {
				bucket, key := tx.Bucket(externalRuntimeActiveExecutionsBucket), []byte(batch.Session.key())
				var execution externalRuntimeActiveExecution
				if err := json.Unmarshal(bucket.Get(key), &execution); err != nil {
					return err
				}
				execution.Version, execution.InputBatchIDs = version, nil
				execution.Phase = externalRuntimeExecutionInterrupted
				raw, err := json.Marshal(execution)
				if err != nil {
					return err
				}
				return bucket.Put(key, raw)
			}); err != nil {
				t.Fatal(err)
			}
			first.externalRuntimeState.close()
			c, err := newConnector(config{root: root})
			if err != nil {
				t.Fatalf("unstarted input prevents restart: %v", err)
			}
			defer c.closeExternalRuntimes()
			c.externalRuntimeState.mu.Lock()
			restored := c.externalRuntimeState.activeExecutions[batch.Session.key()]
			c.externalRuntimeState.mu.Unlock()
			if restored.Session.ExecutionID != input.executionID || !slices.Equal(restored.InputBatchIDs, []string{batch.Session.DispatchID}) {
				t.Fatalf("restart replaced the original execution or claim: %#v", restored)
			}
			attachUnboundCodexTestTransport(t, c)
			if version == 2 {
				// Legacy rows have no saved Host authority. Do not interpret an
				// observed target as permission to submit new input on a Host.
				c.setComputeRuntimeExecutionTarget(map[string]any{"runtime_instance_id": "host"})
				c.checkExternalRuntimes(context.Background())
				if log, _ := os.ReadFile(logPath); strings.Contains(string(log), "turn/start") {
					t.Fatalf("legacy input bypassed Host authority: %s", log)
				}
				c.setComputeRuntimeExecutionTarget(nil)
				c.externalRuntimeRecoveryFailures = map[string]externalRuntimeRecoveryStreak{}
			}
			c.checkExternalRuntimes(context.Background())
			assertCodexOriginalInputDelivered(t, logPath, "original-direct-input", 1)
			c.externalRuntimeState.mu.Lock()
			execution := c.externalRuntimeState.activeExecutions[batch.Session.key()]
			c.externalRuntimeState.mu.Unlock()
			if execution.Session.ExecutionID != input.executionID || stringParam(execution.Session.Payload, "thread_id") == "" || len(execution.InputBatchIDs) != 0 {
				t.Fatalf("original execution not recovered: %#v", execution)
			}
			// A later health pass must not submit the accepted original batch again.
			c.checkExternalRuntimes(context.Background())
			assertCodexOriginalInputDelivered(t, logPath, "original-direct-input", 1)
		})
	}
}

func attachUnboundCodexTestTransport(t *testing.T, c *connector) {
	t.Helper()
	transport := &runtimeTransport{done: make(chan struct{})}
	transport.send = func(_ context.Context, request message) error {
		if request.Method == "runtime_subscription_access" {
			c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{"bound": false}})
			return nil
		}
		return errors.New("test request not acknowledged")
	}
	c.sendMu.Lock()
	c.activeTransport = transport
	c.sendMu.Unlock()
	t.Cleanup(transport.close)
}

func assertCodexOriginalInputDelivered(t *testing.T, path, input string, want int) {
	t.Helper()
	log, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	count := 0
	for _, line := range strings.Split(string(log), "\n") {
		if strings.HasPrefix(line, "turn/start ") && strings.Contains(line, input) {
			count++
		}
	}
	if count != want {
		t.Fatalf("original input deliveries = %d, want %d: %s", count, want, log)
	}
}

func TestCodexUnstartedInputWaitsForDurableBinding(t *testing.T) {
	root, logPath := t.TempDir(), filepath.Join(t.TempDir(), "native.log")
	first := newEventTestConnector(t, root)
	first.setComputeRuntimeExecutionTarget(nil)
	batch := testRuntimeInputBatch("codex", "binding-failure", "binding-dispatch", "input-after-persistence")
	batch.Session.Command, batch.Session.Workspace = fakeCodexCommand(t, logPath, nil), t.TempDir()
	persistRuntimeInputBatch(t, first.externalRuntimeState, batch)
	input, err := first.externalRuntimeState.claimInputBatches([]externalRuntimeInputBatch{batch}, first.externalRuntimeState.inputForBatches([]externalRuntimeInputBatch{batch}))
	if err != nil {
		t.Fatal(err)
	}
	first.externalRuntimeState.close()
	c, err := newConnector(config{root: root})
	if err != nil {
		t.Fatal(err)
	}
	attachUnboundCodexTestTransport(t, c)
	// Closing the durable owner rejects binding writes, while the provider can
	// still create a thread. A failed write must prevent native task submission.
	c.externalRuntimeState.cancel()
	c.externalRuntimeState.worker.Wait()
	retried, err := c.externalRuntimeState.retryUnstartedRuntimeInput(context.Background(), externalRuntimeRecoveryRecordFromInput("codex", input))
	if !retried || err == nil || !strings.Contains(err.Error(), "state is closed") {
		t.Fatalf("binding failure = %t, %v", retried, err)
	}
	assertCodexOriginalInputDelivered(t, logPath, "input-after-persistence", 0)
	if log, err := os.ReadFile(logPath); err != nil || !strings.Contains(string(log), "thread/start ") {
		t.Fatalf("test did not reach native binding: %s, %v", log, err)
	}
	if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
		if tx.Bucket(externalRuntimeInputBatchesBucket).Get([]byte(batch.key())) == nil {
			t.Fatal("binding failure lost input")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	c.closeExternalRuntimes()
	c, err = newConnector(config{root: root})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeExternalRuntimes()
	attachUnboundCodexTestTransport(t, c)
	c.checkExternalRuntimes(context.Background())
	assertCodexOriginalInputDelivered(t, logPath, "input-after-persistence", 1)
	c.externalRuntimeState.mu.Lock()
	restored := c.externalRuntimeState.activeExecutions[batch.Session.key()]
	c.externalRuntimeState.mu.Unlock()
	if restored.Session.ExecutionID != input.executionID {
		t.Fatalf("binding retry changed execution: %#v", restored)
	}
}
