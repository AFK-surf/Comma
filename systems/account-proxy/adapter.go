package accountproxy

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"

	sdkauth "github.com/router-for-me/CLIProxyAPI/v8/sdk/auth"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy"
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
	case "/v1/responses", "/v1/responses/compact", "/v1/messages", "/v1/images/generations", "/v1/images/edits":
		return inference(ctx, credential, op, body, emit)
	case "/oauth/device/begin":
		id, code, interval, err := sdkauth.BeginCodexDeviceAuthorization(ctx, &config.Config{})
		if err != nil {
			return &operationError{502, "device_authorization_failed"}
		}
		if interval > 900 {
			return &operationError{502, "device_authorization_failed"}
		}
		if interval < 5 {
			interval = 5
		}
		return emitJSON(emit, map[string]any{"provider": "codex", "mode": "device", "device_auth_id": id, "user_code": code, "interval": interval, "url": "https://auth.openai.com/codex/device"})
	case "/oauth/device/poll":
		var in struct {
			DeviceAuthID string `json:"device_auth_id"`
			UserCode     string `json:"user_code"`
		}
		if json.Unmarshal(body, &in) != nil || in.DeviceAuthID == "" || in.UserCode == "" {
			return &operationError{400, "invalid_request"}
		}
		metadata, pending, err := sdkauth.PollCodexDeviceAuthorization(ctx, &config.Config{}, in.DeviceAuthID, in.UserCode)
		if err != nil {
			return &operationError{502, "device_authorization_failed"}
		}
		if pending {
			return emitJSON(emit, map[string]any{"status": "pending"})
		}
		return emitJSON(emit, map[string]any{"credentials": metadata, "email": accountEmail(metadata)})
	case "/oauth/begin":
		var in struct {
			Provider string `json:"provider"`
			State    string `json:"state"`
		}
		if json.Unmarshal(body, &in) != nil {
			return &operationError{400, "invalid_request"}
		}
		a, err := oauth.Begin(&config.Config{}, in.Provider, in.State)
		if err != nil {
			return &operationError{400, "invalid_provider"}
		}
		return emitJSON(emit, a)
	case "/oauth/exchange":
		var in struct {
			Attempt oauth.Attempt `json:"attempt"`
			Code    string        `json:"code"`
		}
		if json.Unmarshal(body, &in) != nil {
			return &operationError{400, "invalid_request"}
		}
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
		a := &auth.Auth{Provider: c.Provider, Metadata: metadata}
		e, err := cliproxy.NewSubscriptionExecutor(c.Provider)
		if err != nil {
			return &operationError{400, "invalid_provider"}
		}
		switch op {
		case "/prepare":
			if c.ForceRefresh || needsRefresh(a) {
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
			q, err := queryQuota(ctx, e, a)
			if err != nil {
				return &operationError{502, "quota_unavailable"}
			}
			return emitJSON(emit, q)
		}
		return emitJSON(emit, map[string]any{"credentials": a.Metadata, "email": accountEmail(a.Metadata)})
	default:
		return &operationError{404, "not_found"}
	}
}
func needsRefresh(a *auth.Auth) bool {
	token, _ := a.Metadata["refresh_token"].(string)
	raw, _ := a.Metadata["expired"].(string)
	expiry, err := time.Parse(time.RFC3339, raw)
	return token != "" && (err != nil || time.Until(expiry) < 30*time.Second)
}
func queryQuota(ctx context.Context, e auth.ProviderExecutor, a *auth.Auth) (Snapshot, error) {
	endpoint := "https://chatgpt.com/backend-api/wham/usage"
	if a.Provider == "claude" {
		endpoint = "https://api.anthropic.com/api/oauth/usage"
	}
	req, err := http.NewRequestWithContext(ctx, "GET", endpoint, nil)
	if err != nil {
		return Snapshot{}, err
	}
	if a.Provider == "claude" {
		req.Header.Set("anthropic-beta", "oauth-2025-04-20")
	}
	if id, ok := a.Metadata["account_id"].(string); ok && a.Provider == "codex" {
		req.Header.Set("Chatgpt-Account-Id", id)
	}
	resp, err := e.HttpRequest(ctx, a, req)
	if err != nil {
		return Snapshot{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return Snapshot{}, fmt.Errorf("quota HTTP %d", resp.StatusCode)
	}
	return decodeQuota(a.Provider, resp.Body, time.Now())
}
