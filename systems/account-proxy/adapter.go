package accountproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/config"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/oauth"
)

type Credential struct {
	ForceRefresh bool           `json:"force_refresh,omitempty"`
	Provider     string         `json:"provider"`
	Credentials  map[string]any `json:"credentials"`
}
type operationError struct {
	status int
	code   string
}

func (e *operationError) Error() string { return e.code }

type emitter func([]byte) error

func emitJSON(emit emitter, value any) error {
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return emit(data)
}
func execute(ctx context.Context, op string, body json.RawMessage, credential Credential, emit emitter) error {
	switch op {
	case "/subscription/seal":
		return sealSubscription(body, emit)
	case "/v1/responses", "/v1/responses/compact", "/v1/messages", "/v1/chat/completions", "/v1/images/generations", "/v1/images/edits":
		return inference(ctx, credential, op, body, emit)
	case "/oauth/device/begin":
		var in struct {
			Provider string `json:"provider"`
		}
		if len(body) > 0 && json.Unmarshal(body, &in) != nil {
			return &operationError{400, "invalid_request"}
		}
		attempt, err := beginDevice(ctx, in.Provider)
		if err != nil {
			return err
		}
		return emitJSON(emit, attempt)
	case "/oauth/device/poll":
		var in deviceAttempt
		if json.Unmarshal(body, &in) != nil || in.DeviceAuthID == "" || in.UserCode == "" {
			return &operationError{400, "invalid_request"}
		}
		result, err := pollDevice(ctx, in)
		if err != nil {
			return err
		}
		return emitJSON(emit, result)
	case "/oauth/begin":
		var in struct {
			Provider string `json:"provider"`
			State    string `json:"state"`
		}
		if json.Unmarshal(body, &in) != nil {
			return &operationError{400, "invalid_request"}
		}
		if !slices.Contains(callbackProviders, in.Provider) {
			return &operationError{400, "invalid_provider"}
		}
		a, err := oauth.Begin(&config.Config{}, executorIDs[in.Provider], in.State)
		if err != nil {
			return &operationError{400, "invalid_provider"}
		}
		// The host stores this attempt and later saves its credentials under the Salix provider ID.
		a.Provider = in.Provider
		return emitJSON(emit, a)
	case "/oauth/exchange":
		var in struct {
			Attempt oauth.Attempt `json:"attempt"`
			Code    string        `json:"code"`
		}
		if json.Unmarshal(body, &in) != nil || !slices.Contains(callbackProviders, in.Attempt.Provider) {
			return &operationError{400, "invalid_request"}
		}
		in.Attempt.Provider = executorIDs[in.Attempt.Provider]
		metadata, err := oauth.Exchange(ctx, &config.Config{}, in.Attempt, in.Code)
		if err != nil {
			return &operationError{502, "exchange_failed"}
		}
		return emitJSON(emit, map[string]any{"credentials": metadata, "email": accountEmail(metadata)})
	case "/normalize", "/prepare", "/quota", "/models", "/quota/reset":
		var c Credential
		if json.Unmarshal(body, &c) != nil {
			return &operationError{400, "invalid_request"}
		}
		metadata, err := cleanCredentials(c.Provider, c.Credentials)
		if err != nil {
			return &operationError{400, "invalid_credential"}
		}
		a := newAuth(c.Provider, metadata)
		e, err := newExecutor(c.Provider)
		if err != nil {
			return &operationError{400, "invalid_provider"}
		}
		switch op {
		case "/prepare":
			if c.ForceRefresh || needsRefresh(a, refreshLead(c.Provider)) {
				a, err = e.Refresh(ctx, a)
			}
			if err == nil && a != nil {
				if p, ok := e.(auth.RequestAuthPreparer); ok && p.ShouldPrepareRequestAuth(a) {
					a, err = p.PrepareRequestAuth(ctx, a)
				}
			}
			if err != nil || a == nil {
				return &operationError{502, "prepare_failed"}
			}
		case "/models":
			models, err := queryModels(ctx, e, a)
			if err != nil {
				return &operationError{502, "models_unavailable"}
			}
			return emitJSON(emit, models)
		case "/quota/reset":
			if c.Provider != "codex" {
				return &operationError{400, "invalid_provider"}
			}
			var input struct {
				RequestID string `json:"redeem_request_id"`
			}
			if json.Unmarshal(body, &input) != nil || !resetRequestID.MatchString(input.RequestID) {
				return &operationError{400, "invalid_request"}
			}
			result, err := consumeReset(ctx, e, a, input.RequestID)
			if err != nil {
				return &operationError{502, "reset_unavailable"}
			}
			return emitJSON(emit, result)
		case "/quota":
			q, err := queryQuota(ctx, c.Provider, e, a)
			if err != nil {
				return &operationError{502, "quota_unavailable"}
			}
			return emitJSON(emit, q)
		}
		if op == "/normalize" && c.Provider == "github-copilot" {
			// An imported Copilot credential gets the same identity as a
			// sign-in, so a later sign-in or import finds the same account.
			github, _ := a.Metadata["refresh_token"].(string)
			identity, err := copilotIdentity(ctx, github)
			if err != nil {
				return &operationError{400, "invalid_credential"}
			}
			a.Metadata["email"] = identity
		}
		return emitJSON(emit, map[string]any{"credentials": a.Metadata, "email": accountEmail(a.Metadata)})
	default:
		return &operationError{404, "not_found"}
	}
}
func needsRefresh(a *auth.Auth, lead time.Duration) bool {
	token, _ := a.Metadata["refresh_token"].(string)
	raw, _ := a.Metadata["expired"].(string)
	expiry, err := time.Parse(time.RFC3339, raw)
	return token != "" && (err != nil || time.Until(expiry) < lead)
}
func queryQuota(ctx context.Context, provider string, e auth.ProviderExecutor, a *auth.Auth) (Snapshot, error) {
	if provider == "github-copilot" {
		return copilotQuota(ctx, a, time.Now())
	}
	method, endpoint, decode := "GET", "", func(r io.Reader, now time.Time) (Snapshot, error) { return decodeQuota(provider, r, now) }
	var body io.Reader
	switch provider {
	case "codex":
		endpoint = "https://chatgpt.com/backend-api/wham/usage"
	case "claude":
		endpoint = "https://api.anthropic.com/api/oauth/usage"
	case "gemini":
		project, _ := a.Metadata["project_id"].(string)
		data, _ := json.Marshal(map[string]string{"project": project})
		method, endpoint, decode, body = "POST", "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels", decodeGeminiQuota, bytes.NewReader(data)
	case "grok":
		endpoint, decode = "https://cli-chat-proxy.grok.com/v1/billing?format=credits", decodeGrokQuota
	case "kimi-code":
		endpoint, decode = "https://api.kimi.com/coding/v1/usages", decodeKimiQuota
	default:
		return Snapshot{}, fmt.Errorf("quota unsupported")
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return Snapshot{}, err
	}
	switch provider {
	case "claude":
		req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	case "codex":
		if id, ok := a.Metadata["account_id"].(string); ok {
			req.Header.Set("Chatgpt-Account-Id", id)
		}
	case "gemini":
		req.Header.Set("Content-Type", "application/json")
	case "grok":
		// Grok Build CLI headers for its billing endpoint.
		req.Header.Set("X-XAI-Token-Auth", "xai-grok-cli")
		req.Header.Set("x-grok-client-version", "0.2.120")
		if sub, ok := a.Metadata["sub"].(string); ok && sub != "" {
			req.Header.Set("x-userid", sub)
		}
	}
	resp, err := e.HttpRequest(ctx, a, req)
	if err != nil {
		return Snapshot{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return Snapshot{}, fmt.Errorf("quota HTTP %d", resp.StatusCode)
	}
	return decode(resp.Body, time.Now())
}
