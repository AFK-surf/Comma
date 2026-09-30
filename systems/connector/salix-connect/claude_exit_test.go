package main

import (
	"os/exec"
	"testing"
)

func TestClaudeKilledProcessExitAfterSettlement(t *testing.T) {
	for _, state := range []string{"settled", "starting", "running"} {
		t.Run(state, func(t *testing.T) {
			c := newEventTestConnector(t, t.TempDir())
			defer c.externalRuntimeState.close()
			generation := &claudeAuthGeneration{}
			generation.wait.Add(1)
			session := &claudeRuntimeSession{
				connector: c, cmd: exec.Command("sleep", "60"), done: make(chan struct{}),
				authGeneration: generation, diagnostics: &claudeDiagnosticBuffer{},
				token: "token-1", sessionID: "session-1", dispatchID: "dispatch-1",
				executionID: "execution-1", workState: state,
			}
			configureProcessGroup(session.cmd)
			if err := session.cmd.Start(); err != nil {
				t.Fatal(err)
			}
			session.stop()
			session.wait()
			events := runtimeEventPayloads(t, c)
			if len(events) != 1 {
				t.Fatalf("events=%#v", events)
			}
			event := events[0]
			if state == "settled" {
				if event["type"] != "status" || event["name"] != "runtime_stopped" || event["issue"] != nil || event["work_state"] != nil {
					t.Fatalf("completed work reported failed: %#v", event)
				}
			} else if event["type"] != "error" || event["work_state"] != "failed" {
				t.Fatalf("unfinished work failure suppressed: %#v", event)
			}
		})
	}
}
