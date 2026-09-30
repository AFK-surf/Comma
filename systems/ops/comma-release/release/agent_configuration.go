package release

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"time"
)

// FinishAgentConfiguration runs after durable core success. The runtime's
// markers admit Agent mutations and Group Compute authority. Failure never rolls back
// the already successful core. AgentConfigurationAuthority.tla maps this call
// to Admit, followed by bounded Freeze/Claim/Acknowledge pages.
func (p KubectlPlatform) FinishAgentConfiguration(ctx context.Context, state State) error {
	if state.Phase != PhaseSucceeded {
		return errors.New("Agent configuration handoff requires successful core rollout")
	}
	budget := 10 * time.Minute
	if p.Spec.Environment == "production" || p.Spec.Environment == "prod" {
		budget = 5 * time.Minute
	}
	ctx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	cursor := "nil"
	for {
		output, err := p.agentConfigurationPage(ctx, cursor)
		if err != nil {
			return fmt.Errorf("Agent handoff paused; core remains online; retry finish-agent-configuration: %w", err)
		}
		var result struct {
			NextCursor *string `json:"next_cursor"`
		}
		found := false
		for _, line := range strings.Split(string(output), "\n") {
			if body, ok := strings.CutPrefix(line, "COMMA_AGENT_TRANSFER_RESULT:"); ok {
				if err := json.Unmarshal([]byte(body), &result); err != nil {
					return fmt.Errorf("Agent handoff response: %w", err)
				}
				found = true
			}
		}
		if !found {
			return errors.New("Agent handoff returned no page result; retry finish-agent-configuration")
		}
		if result.NextCursor == nil {
			return nil
		}
		// Native release cursors are base64 JSON, never arbitrary Elixir source.
		cursor = fmt.Sprintf("%q", *result.NextCursor)
	}
}

// agentConfigurationPage retries the same idempotent page after a transient
// failure. It never advances the cursor without a successful page response.
func (p KubectlPlatform) agentConfigurationPage(ctx context.Context, cursor string) ([]byte, error) {
	const attempts = 12
	delay := p.Poll
	if delay <= 0 {
		delay = 10 * time.Second
	}
	for attempt := 1; ; attempt++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		output, err := p.Kubectl.Run(ctx, nil,
			"-n", p.Spec.Namespace, "exec", "pod/comma-0", "-c", "comma", "--",
			"bin/comma", "rpc", "Comma.Release.transfer_agent_configuration_page("+cursor+")")
		if err == nil || attempt == attempts || !retryableAgentHandoff(err) {
			return output, err
		}
		fmt.Fprintf(os.Stderr, "Agent handoff temporarily unavailable. Retry the same page (%d/%d).\n", attempt+1, attempts)
		timer := time.NewTimer(delay)
		select {
		case <-ctx.Done():
			timer.Stop()
			return nil, fmt.Errorf("%w (last handoff error: %v)", ctx.Err(), err)
		case <-timer.C:
		}
	}
}

func retryableAgentHandoff(err error) bool {
	// The release-owned atom distinguishes an unreadable marker from an
	// incomplete handoff. Do not retry domain obligations or invalid state.
	message := err.Error()
	for _, transient := range []string{
		":agent_configuration_state_unavailable",
		":group_compute_state_unavailable",
		`Error from server (NotFound): pods "comma-0" not found`,
		"connection refused",
		"connection reset by peer",
		"unexpected EOF",
		`unable to upgrade connection: container not found ("comma")`,
		":nodedown",
	} {
		if strings.Contains(message, transient) {
			return true
		}
	}
	return false
}
