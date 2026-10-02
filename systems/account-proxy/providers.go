package accountproxy

import (
	"errors"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

// Salix names subscription products. CLIProxyAPI names its executors.
// The worker accepts only these Salix provider IDs.
var executorIDs = map[string]string{
	"codex":          "codex",
	"claude":         "claude",
	"gemini":         "antigravity",
	"grok":           "xai",
	"kimi-code":      "kimi",
	"github-copilot": "github-copilot",
}

// Each inference operation keeps one client wire protocol. The credential's
// provider selects the native executor that serves that protocol. Grok has no
// compaction: upstream sends OAuth compaction to api.x.ai, not the Grok Build
// proxy, and no subscription token was checked there.
var inferenceProviders = map[string][]string{
	"/v1/responses":          {"codex", "grok"},
	"/v1/responses/compact":  {"codex"},
	"/v1/messages":           {"claude", "kimi-code"},
	"/v1/chat/completions":   {"gemini", "github-copilot"},
	"/v1/images/generations": {"codex"},
	"/v1/images/edits":       {"codex"},
}

// Refresh this long before the stored expiry. Antigravity refreshes on its own
// inside a five-minute window, but inference credentials carry no refresh token.
func refreshLead(provider string) time.Duration {
	if provider == "gemini" {
		return 6 * time.Minute
	}
	return 30 * time.Second
}

func newAuth(provider string, metadata map[string]any) *auth.Auth {
	a := &auth.Auth{Provider: executorIDs[provider], Metadata: metadata}
	if provider == "grok" {
		// Subscription tokens use the Grok Build chat proxy, not the paid API key route.
		a.Attributes = map[string]string{"auth_kind": "oauth"}
	}
	return a
}

func newExecutor(provider string) (auth.ProviderExecutor, error) {
	id, ok := executorIDs[provider]
	if !ok {
		return nil, errors.New("unsupported provider")
	}
	e, err := cliproxy.NewSubscriptionExecutor(id)
	if err != nil {
		return nil, err
	}
	if provider == "github-copilot" {
		return copilotExecutor{e}, nil
	}
	return e, nil
}

// Imported credentials keep only identity and token fields. Endpoint fields
// such as base_url or token_endpoint are dropped: a tenant-supplied URL must
// not choose where the worker sends a bearer token. Executors use their
// built-in provider endpoints instead.
var legacyCredentialKeys = []string{"account_id", "account_uuid", "organization_uuid", "organization_name", "claude_device_ids"}
var credentialKeys = map[string][]string{
	"codex":          legacyCredentialKeys,
	"claude":         legacyCredentialKeys,
	"gemini":         {"project_id"},
	"grok":           {"sub"},
	"kimi-code":      {"device_id"},
	"github-copilot": {},
}
