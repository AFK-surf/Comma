package client

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/AFK-surf/comma/systems/cli/bft/internal/output"
)

type Client struct {
	BaseURL    string
	Token      string
	HTTPClient *http.Client
}

func New(baseURL, token string) Client {
	return Client{
		BaseURL: strings.TrimRight(baseURL, "/"),
		Token:   token,
		HTTPClient: &http.Client{
			Timeout: 15 * time.Second,
		},
	}
}

func (c Client) Get(ctx context.Context, path string, query map[string]string) (map[string]any, output.Error) {
	return c.request(ctx, http.MethodGet, path, query, nil, c.Token)
}

func (c Client) Post(ctx context.Context, path string, body map[string]any) (map[string]any, output.Error) {
	return c.request(ctx, http.MethodPost, path, nil, body, c.Token)
}

func (c Client) Patch(ctx context.Context, path string, body map[string]any) (map[string]any, output.Error) {
	return c.request(ctx, http.MethodPatch, path, nil, body, c.Token)
}

func (c Client) Delete(ctx context.Context, path string, query map[string]string) (map[string]any, output.Error) {
	return c.request(ctx, http.MethodDelete, path, query, nil, c.Token)
}

func (c Client) AuthDeviceStart(ctx context.Context, clientName string) (map[string]any, output.Error) {
	body := map[string]any{}
	if strings.TrimSpace(clientName) != "" {
		body["client_name"] = strings.TrimSpace(clientName)
	}
	return c.request(ctx, http.MethodPost, "/v1/cli/auth/device", nil, body, "")
}

func (c Client) AuthDevicePoll(ctx context.Context, deviceCode string) (map[string]any, output.Error) {
	return c.request(ctx, http.MethodPost, "/v1/cli/auth/device/poll", nil, map[string]any{"device_code": deviceCode}, "")
}

func (c Client) AuthOrgGrantStart(ctx context.Context, clientName string) (map[string]any, output.Error) {
	body := map[string]any{}
	if strings.TrimSpace(clientName) != "" {
		body["client_name"] = strings.TrimSpace(clientName)
	}
	return c.request(ctx, http.MethodPost, "/v1/cli/auth/orgs/device", nil, body, c.Token)
}

func (c Client) AuthOrgGrantPoll(ctx context.Context, deviceCode string) (map[string]any, output.Error) {
	return c.request(ctx, http.MethodPost, "/v1/cli/auth/orgs/device/poll", nil, map[string]any{"device_code": deviceCode}, c.Token)
}

func (c Client) AuthOrgRevoke(ctx context.Context, org string) (map[string]any, output.Error) {
	return c.request(ctx, http.MethodPost, "/v1/cli/auth/orgs/revoke", nil, map[string]any{"org": org}, c.Token)
}

func (c Client) AuthLogout(ctx context.Context) (map[string]any, output.Error) {
	return c.request(ctx, http.MethodPost, "/v1/cli/auth/logout", nil, nil, c.Token)
}

func (c Client) request(ctx context.Context, method, path string, query map[string]string, body map[string]any, token string) (map[string]any, output.Error) {
	if strings.TrimSpace(c.BaseURL) == "" {
		return nil, output.Usage("missing_api_base_url", "Set BFT_URL, pass --url, or choose an environment with --env prod|staging|local.", nil)
	}
	if !isPublicAuthPath(path) && strings.TrimSpace(token) == "" {
		return nil, output.Usage("missing_api_token", "Run bft auth login first.", nil)
	}

	endpoint, err := url.Parse(c.BaseURL + path)
	if err != nil {
		return nil, output.Error{ExitCode: output.ExitUsage, Code: "invalid_api_base_url", Message: "BFT API URL is invalid.", Details: map[string]any{"reason": err.Error()}}
	}
	values := endpoint.Query()
	for key, value := range query {
		if strings.TrimSpace(value) != "" {
			values.Set(key, value)
		}
	}
	endpoint.RawQuery = values.Encode()

	var reader io.Reader
	if body != nil {
		encoded, err := json.Marshal(body)
		if err != nil {
			return nil, output.Error{ExitCode: output.ExitSoftware, Code: "json_encode_failed", Message: "Could not encode API request.", Details: map[string]any{"reason": err.Error()}}
		}
		reader = bytes.NewReader(encoded)
	}

	req, err := http.NewRequestWithContext(ctx, method, endpoint.String(), reader)
	if err != nil {
		return nil, output.Error{ExitCode: output.ExitSoftware, Code: "api_request_failed", Message: "Could not build BFT API request.", Details: map[string]any{"reason": err.Error()}}
	}
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}

	httpClient := c.HTTPClient
	if httpClient == nil {
		httpClient = http.DefaultClient
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return nil, output.Error{ExitCode: output.ExitUnavailable, Code: "api_unavailable", Message: "Could not reach the BFT API.", Details: map[string]any{"reason": err.Error()}, Retryable: true}
	}
	defer resp.Body.Close()

	var envelope map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&envelope); err != nil {
		return nil, output.Error{ExitCode: output.ExitUnavailable, Code: "unexpected_api_response", Message: "BFT API returned non-JSON output.", Details: map[string]any{"http_status": resp.StatusCode, "reason": err.Error()}, Retryable: resp.StatusCode >= 500}
	}

	if ok, _ := envelope["ok"].(bool); ok {
		data, _ := envelope["data"].(map[string]any)
		if data == nil {
			data = map[string]any{}
		}
		return data, output.Error{}
	}

	apiErr, _ := envelope["error"].(map[string]any)
	code, _ := apiErr["code"].(string)
	message, _ := apiErr["message"].(string)
	details, _ := apiErr["details"].(map[string]any)
	if redacted, ok := output.Redact(details).(map[string]any); ok {
		details = redacted
	}
	if message == "" {
		message = fmt.Sprintf("BFT API request failed with HTTP %d.", resp.StatusCode)
	}
	if code == "" {
		code = "api_error"
	}
	return nil, output.Error{
		ExitCode:   exitForStatus(resp.StatusCode, code),
		Code:       code,
		Message:    message,
		Details:    details,
		NextAction: message,
		Retryable:  resp.StatusCode >= 500,
	}
}

func isPublicAuthPath(path string) bool {
	switch path {
	case "/v1/cli/auth/device", "/v1/cli/auth/device/poll":
		return true
	default:
		return false
	}
}

func exitForStatus(status int, code string) int {
	if status == http.StatusNotFound {
		return output.ExitNotFound
	}
	if status >= 500 {
		return output.ExitUnavailable
	}
	if status >= 400 {
		return output.ExitUsage
	}
	return output.ExitUnavailable
}
