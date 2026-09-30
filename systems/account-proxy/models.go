package accountproxy

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"slices"
	"strings"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

const (
	modelDiscoveryTimeout = 15 * time.Second
	maxModelResponseBytes = 2 * 1024 * 1024
	maxDiscoveredModels   = 1000
	maxModelPages         = 5
)

type discoveredModel struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Provider-declared capability. Missing metadata does not enable image input.
	SupportsImages         bool     `json:"supports_images"`
	ReasoningEfforts       []string `json:"reasoning_efforts,omitempty"`
	DefaultReasoningEffort string   `json:"default_reasoning_effort,omitempty"`
}

type modelListing struct {
	Data      []discoveredModel `json:"data"`
	Truncated bool              `json:"truncated"`
}

type modelRequester func(context.Context, *auth.Auth, *http.Request) (*http.Response, error)

// The pinned CLIProxyAPI SDK exports HttpRequest but no subscription model
// discovery API. Keep the provider response adapter here and use the executor
// for authentication and HTTP dispatch. The parent owns refresh via /prepare.
func queryModels(ctx context.Context, e auth.ProviderExecutor, a *auth.Auth) (modelListing, error) {
	return queryModelsWithRequester(ctx, a, e.HttpRequest)
}

func queryModelsWithRequester(ctx context.Context, a *auth.Auth, request modelRequester) (modelListing, error) {
	unavailable := errors.New("models_unavailable")
	if a == nil || (a.Provider != "codex" && a.Provider != "claude") {
		return modelListing{}, unavailable
	}
	ctx, cancel := context.WithTimeout(ctx, modelDiscoveryTimeout)
	defer cancel()
	// The SDK client has no exported redirect policy. Its transport hook lets us
	// reject redirects before credentials can reach another URL. Discovery uses
	// standard Go TLS here instead of the SDK's private fingerprint transports.
	transport, _ := ctx.Value("cliproxy.roundtripper").(http.RoundTripper)
	if transport == nil {
		transport = http.DefaultTransport
	}
	ctx = context.WithValue(ctx, "cliproxy.roundtripper", modelTransport{transport})
	result := modelListing{Data: []discoveredModel{}}
	remaining := int64(maxModelResponseBytes)
	cursor := ""
	cursors := map[string]bool{}
	seen := map[string]bool{}
	for page := 0; page < maxModelPages; page++ {
		endpoint := "https://chatgpt.com/backend-api/codex/models?client_version=0.153.3"
		if a.Provider == "claude" {
			params := url.Values{"limit": {"1000"}}
			if cursor != "" {
				params.Set("after_id", cursor)
			}
			endpoint = "https://api.anthropic.com/v1/models?" + params.Encode()
		}
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
		if err != nil || ctx.Err() != nil {
			return modelListing{}, unavailable
		}
		req.Header.Set("Accept", "application/json")
		if a.Provider == "claude" {
			req.Header.Set("anthropic-beta", "oauth-2025-04-20")
			req.Header.Set("anthropic-version", "2023-06-01")
		} else {
			req.Header.Set("Originator", "codex_cli_rs")
			req.Header.Set("User-Agent", "codex_cli_rs/0.153.3 (Mac OS 26.3.1; arm64) iTerm.app/3.6.9")
			if id, ok := a.Metadata["account_id"].(string); ok {
				req.Header.Set("Chatgpt-Account-Id", id)
			}
		}
		resp, err := request(ctx, a, req)
		if err != nil || resp == nil || resp.Body == nil {
			if resp != nil && resp.Body != nil {
				resp.Body.Close()
			}
			return modelListing{}, unavailable
		}
		if resp.StatusCode != http.StatusOK {
			resp.Body.Close()
			return modelListing{}, unavailable
		}
		raw, err := io.ReadAll(io.LimitReader(resp.Body, remaining+1))
		resp.Body.Close()
		if err != nil || int64(len(raw)) > remaining || ctx.Err() != nil {
			return modelListing{}, unavailable
		}
		remaining -= int64(len(raw))
		var payload struct {
			Models []struct {
				Slug                     string   `json:"slug"`
				Name                     string   `json:"display_name"`
				Visibility               string   `json:"visibility"`
				Available                *bool    `json:"available"`
				InputModalities          []string `json:"input_modalities"`
				DefaultReasoningLevel    string   `json:"default_reasoning_level"`
				SupportedReasoningLevels []struct {
					Effort string `json:"effort"`
				} `json:"supported_reasoning_levels"`
			} `json:"models"`
			Data []struct {
				ID           string `json:"id"`
				Name         string `json:"display_name"`
				Capabilities struct {
					ImageInput struct {
						Supported bool `json:"supported"`
					} `json:"image_input"`
				} `json:"capabilities"`
			} `json:"data"`
			HasMore bool   `json:"has_more"`
			LastID  string `json:"last_id"`
		}
		if json.Unmarshal(raw, &payload) != nil {
			return modelListing{}, unavailable
		}
		models := []discoveredModel{}
		if a.Provider == "codex" {
			if payload.Models == nil {
				return modelListing{}, unavailable
			}
			for _, m := range payload.Models {
				// The pinned catalog marks hidden entries with visibility=hide.
				// supported_in_api=false does not exclude subscription models.
				if m.Visibility == "hide" || m.Visibility == "hidden" || m.Visibility == "unavailable" || (m.Available != nil && !*m.Available) {
					continue
				}
				efforts := []string{}
				for _, level := range m.SupportedReasoningLevels {
					if level.Effort != "" && len(level.Effort) <= 64 && !slices.Contains(efforts, level.Effort) {
						efforts = append(efforts, level.Effort)
						if len(efforts) > 32 {
							return modelListing{}, unavailable
						}
					}
				}
				defaultEffort := m.DefaultReasoningLevel
				if !slices.Contains(efforts, defaultEffort) {
					defaultEffort = ""
				}
				models = append(models, discoveredModel{ID: m.Slug, Name: m.Name, SupportsImages: slices.Contains(m.InputModalities, "image"), ReasoningEfforts: efforts, DefaultReasoningEffort: defaultEffort})
			}
		} else {
			if payload.Data == nil {
				return modelListing{}, unavailable
			}
			for _, m := range payload.Data {
				models = append(models, discoveredModel{ID: m.ID, Name: m.Name, SupportsImages: m.Capabilities.ImageInput.Supported})
			}
		}
		for _, m := range models {
			if strings.TrimSpace(m.ID) == "" {
				return modelListing{}, unavailable
			}
			if seen[m.ID] {
				continue
			}
			if len(result.Data) == maxDiscoveredModels {
				result.Truncated = true
				return result, nil
			}
			if strings.TrimSpace(m.Name) == "" {
				m.Name = m.ID
			}
			seen[m.ID] = true
			result.Data = append(result.Data, m)
		}
		if a.Provider == "codex" || !payload.HasMore {
			return result, nil
		}
		if len(result.Data) == maxDiscoveredModels || page+1 == maxModelPages || remaining == 0 {
			result.Truncated = true
			return result, nil
		}
		if payload.LastID == "" || cursors[payload.LastID] || len(models) == 0 {
			return modelListing{}, unavailable
		}
		cursor = payload.LastID
		cursors[cursor] = true
	}
	return result, nil
}

type modelTransport struct{ base http.RoundTripper }

func (t modelTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	// Only these fixed discovery endpoints may receive the prepared credential.
	if req.URL.Scheme != "https" || req.URL.User != nil ||
		!((req.URL.Host == "chatgpt.com" && req.URL.Path == "/backend-api/codex/models") ||
			(req.URL.Host == "api.anthropic.com" && req.URL.Path == "/v1/models")) {
		return nil, errors.New("models_unavailable")
	}
	resp, err := t.base.RoundTrip(req)
	if err == nil && resp != nil && resp.StatusCode >= 300 && resp.StatusCode < 400 {
		if resp.Body != nil {
			resp.Body.Close()
		}
		return nil, errors.New("models_unavailable")
	}
	return resp, err
}
