package accountproxy

import (
	"context"
	"net/url"

	sdkauth "github.com/router-for-me/CLIProxyAPI/v8/sdk/auth"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/config"
)

// Providers whose sign-in returns to a provider callback URL that the user pastes.
var callbackProviders = []string{"codex", "claude", "gemini"}

// deviceAttempt is the private attempt the host stores between polls.
// DeviceAuthID holds the provider's private device code.
type deviceAttempt struct {
	Provider     string         `json:"provider"`
	DeviceAuthID string         `json:"device_auth_id"`
	UserCode     string         `json:"user_code"`
	Context      map[string]any `json:"context,omitempty"`
}

func deviceFailed() error { return &operationError{502, "device_authorization_failed"} }

// beginDevice returns the private attempt plus the public user code and URL.
// An empty provider is Codex, which predates multi-provider device sign-in.
func beginDevice(ctx context.Context, provider string) (map[string]any, error) {
	if provider == "" {
		provider = "codex"
	}
	out := map[string]any{"provider": provider, "mode": "device"}
	interval := 0
	switch provider {
	case "codex":
		id, code, seconds, err := sdkauth.BeginCodexDeviceAuthorization(ctx, &config.Config{})
		if err != nil {
			return nil, deviceFailed()
		}
		out["device_auth_id"], out["user_code"], out["url"], interval = id, code, "https://auth.openai.com/codex/device", seconds
	case "grok", "kimi-code":
		begin := sdkauth.BeginXAIDeviceAuthorization
		if provider == "kimi-code" {
			begin = sdkauth.BeginKimiDeviceAuthorization
		}
		d, err := begin(ctx, &config.Config{})
		if err != nil {
			return nil, deviceFailed()
		}
		out["device_auth_id"], out["user_code"], out["url"], interval = d.DeviceCode, d.UserCode, d.VerificationURL, d.Interval
		context := map[string]any{}
		if d.TokenEndpoint != "" {
			context["token_endpoint"] = d.TokenEndpoint
		}
		if d.DeviceID != "" {
			context["device_id"] = d.DeviceID
		}
		out["context"] = context
	case "github-copilot":
		d, err := copilotBeginDevice(ctx)
		if err != nil {
			return nil, deviceFailed()
		}
		for k, v := range d {
			out[k] = v
		}
		interval, _ = d["interval"].(int)
	default:
		return nil, &operationError{400, "invalid_provider"}
	}
	// The host displays this URL to the user. Accept only a web URL.
	if u, err := url.Parse(out["url"].(string)); err != nil || u.Scheme != "https" || u.Host == "" || u.User != nil {
		return nil, deviceFailed()
	}
	if interval > 900 {
		return nil, deviceFailed()
	}
	out["interval"] = max(interval, 5)
	return out, nil
}

// pollDevice checks once and returns pending status or normal credentials.
func pollDevice(ctx context.Context, in deviceAttempt) (map[string]any, error) {
	var metadata map[string]any
	switch in.Provider {
	case "", "codex":
		m, pending, err := sdkauth.PollCodexDeviceAuthorization(ctx, &config.Config{}, in.DeviceAuthID, in.UserCode)
		if err != nil {
			return nil, deviceFailed()
		}
		if pending {
			return map[string]any{"status": "pending"}, nil
		}
		metadata = m
	case "grok", "kimi-code":
		d := sdkauth.DeviceAuthorization{DeviceCode: in.DeviceAuthID, UserCode: in.UserCode}
		d.TokenEndpoint, _ = in.Context["token_endpoint"].(string)
		d.DeviceID, _ = in.Context["device_id"].(string)
		poll := sdkauth.PollXAIDeviceAuthorization
		if in.Provider == "kimi-code" {
			poll = sdkauth.PollKimiDeviceAuthorization
		}
		m, status, err := poll(ctx, &config.Config{}, d)
		if err != nil {
			return nil, deviceFailed()
		}
		if status != sdkauth.DeviceComplete {
			return pending(status == sdkauth.DeviceSlowDown), nil
		}
		metadata = m
	case "github-copilot":
		m, slowDown, err := copilotPollDevice(ctx, in.DeviceAuthID)
		if err != nil {
			return nil, deviceFailed()
		}
		if m == nil {
			return pending(slowDown), nil
		}
		metadata = m
	default:
		return nil, &operationError{400, "invalid_provider"}
	}
	return map[string]any{"credentials": metadata, "email": accountEmail(metadata)}, nil
}

// slow_down asks the host to add five seconds to its polling interval (RFC 8628).
func pending(slowDown bool) map[string]any {
	out := map[string]any{"status": "pending"}
	if slowDown {
		out["slow_down"] = true
	}
	return out
}
