package main

import (
	"testing"
	"time"
)

func TestRuntimeRecoveryReceiptSharesLifecycleCommit(t *testing.T) {
	dir := t.TempDir()
	c := newEventTestConnector(t, dir)
	input := externalRuntimeInput{
		sessionID: "receipt-session", dispatchID: "dispatch-1", executionID: "execution-1",
		token: "receipt-capability", command: "/usr/local/bin/pi", workspace: "/tmp/workspace",
		payload: map[string]any{"session_id": "native-1"},
	}
	if err := c.watchExternalRuntime("pi", input); err != nil {
		t.Fatal(err)
	}
	event := attachRuntimeIdentity(map[string]any{
		"type": "error", "provider": "pi", "message": "runtime failed", "issue": "runtime_failed", "created_at": int64(1),
	}, input.dispatchID, input.executionID, "failed")
	if err := c.externalRuntimeState.enqueueExecutionEvent("pi", input.sessionID, input.token, event, externalRuntimeExecutionInterrupted); err != nil {
		t.Fatal(err)
	}
	// Rebinding the same native session during recovery must not erase the
	// interrupted phase before recovery acceptance commits its receipt.
	if err := c.watchExternalRuntime("pi", input); err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.markExecutionRecovered("pi", input.sessionID, "wrong-capability"); err == nil {
		t.Fatal("wrong capability accepted")
	}
	if err := c.externalRuntimeState.markExecutionRecovered("pi", input.sessionID, input.token); err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.markExecutionRecovered("pi", input.sessionID, input.token); err != nil {
		t.Fatal(err)
	}
	c.externalRuntimeState.close()

	// No alert service is running. The already committed receipt survives a
	// Connector process restart in the ordinary durable transport outbox.
	restarted := newEventTestConnector(t, dir)
	defer restarted.externalRuntimeState.close()
	count := 0
	faultID := ""
	for _, got := range runtimeEventPayloads(t, restarted) {
		if got["issue"] == "runtime_failed" {
			faultID = stringParam(got, "fault_episode_id")
		}
		if got["name"] == "runtime_recovered" {
			count++
			if got["dispatch_id"] != input.dispatchID || got["execution_id"] != input.executionID || got["state"] != "recovered" {
				t.Fatalf("unscoped recovery receipt: %#v", got)
			}
			if faultID == "" || got["fault_episode_id"] != faultID {
				t.Fatalf("recovery lost its fault: %#v", got)
			}
		}
	}
	if count != 1 {
		t.Fatalf("want one durable receipt, got %d", count)
	}
}

func TestRuntimeFaultSnapshotsSurviveAbandonmentAndSeparateLaterFailure(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	// The terminal exhaustion announcement can arrive after active execution
	// removal. Correlation must not depend on that transient active row.
	emit := func(kind string) {
		event := map[string]any{"provider": "pi", "type": "error", "message": "failure", "issue": kind,
			"created_at": time.Now().Unix(), "dispatch_id": "dispatch", "execution_id": "execution", "work_state": "failed"}
		if kind == "runtime_recovered" {
			event = map[string]any{"provider": "pi", "type": "status", "name": kind, "state": "recovered",
				"created_at": time.Now().Unix(), "dispatch_id": "dispatch", "execution_id": "execution"}
		}
		if err := c.externalRuntimeState.enqueue("capability", event); err != nil {
			t.Fatal(err)
		}
	}
	emit("runtime_failed")
	emit("recovery_exhausted")
	emit("runtime_recovered")
	emit("runtime_failed")
	events := runtimeEventPayloads(t, c)
	if len(events) != 4 {
		t.Fatalf("events: %#v", events)
	}
	first := stringParam(events[0], "fault_episode_id")
	if first == "" || events[1]["fault_episode_id"] != first || events[2]["fault_episode_id"] != first {
		t.Fatalf("one fault did not retain identity: %#v", events)
	}
	if events[2]["fault_priority"] != "P0" || events[2]["fault_started_at"] != events[0]["fault_started_at"] {
		t.Fatalf("recovery is not self-contained: %#v", events[2])
	}
	if events[3]["fault_episode_id"] == first || events[3]["fault_priority"] != "P1" {
		t.Fatalf("new fault reused recovered episode: %#v", events[3])
	}
}
