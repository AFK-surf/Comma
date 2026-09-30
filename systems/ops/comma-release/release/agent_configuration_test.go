package release

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Exercise the real command runner: stderr becomes the classified error,
// while a lost response must not cause the release runner to skip a page.
func TestAgentHandoffRetriesPageAcrossProcessFailure(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HANDOFF_TEST_DIR", dir)
	script := filepath.Join(dir, "kubectl")
	err := os.WriteFile(script, []byte(`#!/bin/sh
set -eu
echo "$*" >> "$HANDOFF_TEST_DIR/calls"
if [ ! -f "$HANDOFF_TEST_DIR/first" ]; then
  touch "$HANDOFF_TEST_DIR/first"
  echo 'COMMA_AGENT_TRANSFER_RESULT:{"processed":20,"next_cursor":"cGFnZTI="}'
elif [ ! -f "$HANDOFF_TEST_DIR/retried" ]; then
  touch "$HANDOFF_TEST_DIR/retried"
  echo '** (RuntimeError) Agent configuration handoff paused; core remains online. Retry this page: :agent_configuration_state_unavailable' >&2
  exit 1
else
  echo 'COMMA_AGENT_TRANSFER_RESULT:{"processed":1,"next_cursor":null}'
fi
`), 0700)
	if err != nil {
		t.Fatal(err)
	}
	p := KubectlPlatform{Kubectl: ExecRunner{Name: script}, Poll: time.Nanosecond}
	if err := p.FinishAgentConfiguration(context.Background(), State{Phase: PhaseSucceeded}); err != nil {
		t.Fatal(err)
	}
	body, err := os.ReadFile(filepath.Join(dir, "calls"))
	if err != nil {
		t.Fatal(err)
	}
	calls := strings.Split(strings.TrimSpace(string(body)), "\n")
	if len(calls) != 3 || calls[1] != calls[2] || !strings.Contains(calls[1], `("cGFnZTI=")`) {
		t.Fatalf("failed page was not replayed exactly: %q", calls)
	}
}

func TestAgentHandoffRetryClassificationAndBound(t *testing.T) {
	for _, tc := range []struct {
		message string
		want    int
	}{
		{":agent_configuration_state_unavailable", 12},
		{`Error from server (NotFound): pods "comma-0" not found`, 12},
		{"connection refused", 12},
		{"connection reset by peer", 12},
		{"unexpected EOF", 12},
		{`unable to upgrade connection: container not found ("comma")`, 12},
		{":nodedown", 12},
		{":agent_configuration_rollout_pending", 1},
		{":invalid_agent_configuration_state", 1},
		{":drain_agent_configuration_outbox", 1},
		{"Error from server (Forbidden)", 1},
		{"invalid cursor", 1},
	} {
		t.Run(tc.message, func(t *testing.T) {
			calls := 0
			p := KubectlPlatform{Poll: time.Nanosecond}
			p.Kubectl = runnerFunc(func(context.Context, []byte, ...string) ([]byte, error) {
				calls++
				return nil, errors.New(tc.message)
			})
			err := p.FinishAgentConfiguration(context.Background(), State{Phase: PhaseSucceeded})
			if err == nil || calls != tc.want || !strings.Contains(err.Error(), tc.message) {
				t.Fatalf("calls=%d want=%d error=%v", calls, tc.want, err)
			}
		})
	}
}

func TestAgentHandoffCancellationStopsRetryWait(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	calls := 0
	p := KubectlPlatform{Poll: time.Hour}
	p.Kubectl = runnerFunc(func(context.Context, []byte, ...string) ([]byte, error) {
		calls++
		cancel()
		return nil, errors.New("connection refused")
	})
	err := p.FinishAgentConfiguration(ctx, State{Phase: PhaseSucceeded})
	if !errors.Is(err, context.Canceled) || calls != 1 {
		t.Fatalf("cancellation did not stop retry: calls=%d error=%v", calls, err)
	}
}

func TestAgentHandoffDoesNotRetryInvalidResponse(t *testing.T) {
	for _, response := range []string{"no result", "COMMA_AGENT_TRANSFER_RESULT:{"} {
		calls := 0
		p := KubectlPlatform{Poll: time.Nanosecond}
		p.Kubectl = runnerFunc(func(context.Context, []byte, ...string) ([]byte, error) {
			calls++
			return []byte(response), nil
		})
		if err := p.FinishAgentConfiguration(context.Background(), State{Phase: PhaseSucceeded}); err == nil || calls != 1 {
			t.Fatalf("invalid response accepted or retried: calls=%d error=%v", calls, err)
		}
	}
}
