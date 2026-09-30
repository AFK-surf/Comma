package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestClaudeInputRetriesAfterPreNativeFailure(t *testing.T) {
	for _, scenario := range []struct {
		name              string
		host, restart     bool
		initializeFailure bool
	}{
		{"direct", false, false, false}, {"direct-restart", false, true, false},
		{"host", true, false, false}, {"host-restart", true, true, false},
		{"initialize", true, false, true},
	} {
		t.Run(scenario.name, func(t *testing.T) {
			logPath := filepath.Join(t.TempDir(), "claude.log")
			t.Setenv("SALIX_TEST_FAKE_CLAUDE_LOG", logPath)
			t.Setenv("SALIX_TEST_FAKE_CLAUDE_HOLD_FIRST", "1")
			command := filepath.Join(t.TempDir(), "claude")
			if scenario.initializeFailure {
				t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "startup_failure")
				if err := os.Symlink(fakeClaudeRuntimeCommand(t), command); err != nil {
					t.Fatal(err)
				}
			}
			root := t.TempDir()
			c, err := newConnector(config{root: root})
			if err != nil {
				t.Fatal(err)
			}
			target := externalRuntimeExecutionTarget{
				RuntimeInstanceID: "runtime-test", RuntimeGeneration: 1, RuntimeConnectionEpoch: "epoch-test",
				WorkloadID: "workload-test", WorkloadGeneration: 1, AllocationID: "allocation-test", AllocationGeneration: 1,
				ContainerID: "container-test", ContainerInstanceID: "instance-test",
			}
			if scenario.host {
				c.setComputeRuntimeExecutionTarget(target.mapValue())
				attachRuntimeExecutionTestTransport(t, c)
			}
			defer func() {
				c.closeExternalRuntimes()
				if c.bridgeServer != nil {
					_ = c.bridgeServer.Shutdown(context.Background())
				}
			}()
			batch := testRuntimeInputBatch("claude", "session-startup", "dispatch-startup", "original-message")
			batch.Session.Command, batch.Session.Workspace = command, t.TempDir()
			persistRuntimeInputBatch(t, c.externalRuntimeState, batch)
			if c.externalRuntimeState.deliverInputBatches([]externalRuntimeInputBatch{batch}) {
				t.Fatal("missing executable accepted input")
			}
			records := c.externalRuntimeState.activeRecords()
			if len(records) != 1 {
				t.Fatalf("missing recovery obligation: %v", records)
			}
			executionID := records[0].ExecutionID
			c.checkExternalRuntimes(context.Background())
			if c.externalRuntimeRecoveryFailures[records[0].key()].count != 1 {
				t.Fatal("startup failure was reported healthy")
			}
			if scenario.restart {
				c.closeExternalRuntimes()
				if c.bridgeServer != nil {
					_ = c.bridgeServer.Shutdown(context.Background())
				}
				c, err = newConnector(config{root: root})
				if err != nil {
					t.Fatalf("unstarted claim prevents restart: %v", err)
				}
				if scenario.host {
					c.setComputeRuntimeExecutionTarget(target.mapValue())
					attachRuntimeExecutionTestTransport(t, c)
					// Recreate the remote fixture's retained right after the local
					// Connector restart. Production must reconcile this exact right.
					if _, err := c.runtimeExecution(context.Background(), "acquire", executionID, target.mapValue()); err != nil {
						t.Fatal(err)
					}
				}
			}
			if scenario.initializeFailure {
				t.Setenv("SALIX_TEST_FAKE_CLAUDE_AUTH", "")
			} else {
				if err := os.Symlink(fakeClaudeRuntimeCommand(t), command); err != nil {
					t.Fatal(err)
				}
			}
			for n := 0; n < 5; n++ {
				c.checkExternalRuntimes(context.Background())
			}
			deadline := time.Now().Add(3 * time.Second)
			var log []byte
			for time.Now().Before(deadline) {
				log, _ = os.ReadFile(logPath)
				if strings.Contains(string(log), "original-message") {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			deliveries := 0
			for _, line := range strings.Split(string(log), "\n") {
				var message map[string]any
				if json.Unmarshal([]byte(line), &message) == nil && message["type"] == "user" && strings.Contains(line, "original-message") {
					deliveries++
				}
			}
			if deliveries != 1 {
				t.Fatalf("original input was not delivered once: %s", log)
			}
			assertRuntimeInputState(t, c, 0, true, nil)
			for _, record := range c.externalRuntimeState.activeRecords() {
				if record.ExecutionID != executionID {
					t.Fatal("recovery replaced execution authority")
				}
			}
			c.externalRuntimeState.mu.Lock()
			execution := c.externalRuntimeState.activeExecutions[records[0].key()]
			c.externalRuntimeState.mu.Unlock()
			if execution.Phase == externalRuntimeExecutionInterrupted {
				t.Fatal("accepted retry remained interrupted")
			}
			if scenario.host && (!execution.HostAcquired || execution.Target != target) {
				t.Fatal("recovery changed the Host execution target")
			}
		})
	}
}
