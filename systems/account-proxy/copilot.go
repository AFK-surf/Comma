package accountproxy

// CLIProxyAPI has no GitHub Copilot provider. This adapter ports the device
// login and token exchange from pi's GitHub Copilot OAuth implementation and
// executes requests through CLIProxyAPI's OpenAI-compatible executor.
// Only github.com accounts are supported; GitHub Enterprise domains are not.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	"github.com/tidwall/gjson"
)

var copilotClientID = func() string {
	id, _ := base64.StdEncoding.DecodeString("SXYxLmI1MDdhMDhjODdlY2ZlOTg=")
	return string(id)
}()

const copilotDefaultBaseURL = "https://api.individual.githubcopilot.com"

var copilotHeaders = map[string]string{
	"User-Agent":             "GitHubCopilotChat/0.35.0",
	"Editor-Version":         "vscode/1.107.0",
	"Editor-Plugin-Version":  "copilot-chat/0.35.0",
	"Copilot-Integration-Id": "vscode-chat",
}

func copilotHTTP(ctx context.Context, method, endpoint string, form url.Values, header map[string]string) (int, []byte, error) {
	var body io.Reader
	if form != nil {
		body = strings.NewReader(form.Encode())
	}
	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return 0, nil, err
	}
	req.Header.Set("Accept", "application/json")
	if form != nil {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	for k, v := range header {
		req.Header.Set(k, v)
	}
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 1024*1024+1))
	if err != nil || len(data) > 1024*1024 {
		return 0, nil, errors.New("invalid copilot response")
	}
	return resp.StatusCode, data, nil
}

func copilotBeginDevice(ctx context.Context) (map[string]any, error) {
	status, data, err := copilotHTTP(ctx, http.MethodPost, "https://github.com/login/device/code", url.Values{"client_id": {copilotClientID}, "scope": {"read:user"}}, map[string]string{"User-Agent": copilotHeaders["User-Agent"]})
	if err != nil || status != http.StatusOK {
		return nil, errors.New("device authorization failed")
	}
	var r struct {
		DeviceCode      string `json:"device_code"`
		UserCode        string `json:"user_code"`
		VerificationURI string `json:"verification_uri"`
		Interval        int    `json:"interval"`
	}
	if json.Unmarshal(data, &r) != nil || r.DeviceCode == "" || r.UserCode == "" {
		return nil, errors.New("device authorization failed")
	}
	return map[string]any{"device_auth_id": r.DeviceCode, "user_code": r.UserCode, "interval": r.Interval, "url": r.VerificationURI}, nil
}

// copilotPollDevice checks once. A nil result with a nil error is pending.
func copilotPollDevice(ctx context.Context, deviceCode string) (map[string]any, bool, error) {
	status, data, err := copilotHTTP(ctx, http.MethodPost, "https://github.com/login/oauth/access_token", url.Values{"client_id": {copilotClientID}, "device_code": {deviceCode}, "grant_type": {"urn:ietf:params:oauth:grant-type:device_code"}}, map[string]string{"User-Agent": copilotHeaders["User-Agent"]})
	if err != nil || status != http.StatusOK {
		return nil, false, errors.New("device authorization failed")
	}
	var r struct {
		AccessToken string `json:"access_token"`
		Error       string `json:"error"`
	}
	if json.Unmarshal(data, &r) != nil {
		return nil, false, errors.New("device authorization failed")
	}
	switch {
	case r.AccessToken != "":
	case r.Error == "authorization_pending":
		return nil, false, nil
	case r.Error == "slow_down":
		return nil, true, nil
	default:
		return nil, false, errors.New("device authorization failed")
	}
	metadata, err := copilotExchange(ctx, map[string]any{"refresh_token": r.AccessToken})
	if err != nil {
		return nil, false, err
	}
	identity, err := copilotIdentity(ctx, r.AccessToken)
	if err != nil {
		return nil, false, err
	}
	metadata["email"] = identity
	return metadata, false, nil
}

// copilotIdentity is the account identity Salix matches reconnects by: the
// numeric GitHub id only. An email or a login can change, and a change would
// make a second account on the next sign-in. Sign-in and imports both use it.
func copilotIdentity(ctx context.Context, githubToken string) (string, error) {
	status, data, err := copilotHTTP(ctx, http.MethodGet, "https://api.github.com/user", nil, map[string]string{"Authorization": "Bearer " + githubToken, "User-Agent": copilotHeaders["User-Agent"]})
	if err != nil || status != http.StatusOK {
		return "", errors.New("profile unavailable")
	}
	id := gjson.GetBytes(data, "id")
	if id.Type != gjson.Number || id.Int() <= 0 {
		return "", errors.New("GitHub profile has no account id")
	}
	return fmt.Sprintf("id:github:%d", id.Int()), nil
}

// copilotExchange turns the long-lived GitHub OAuth token, stored as the
// refresh token, into a short-lived Copilot API token.
func copilotExchange(ctx context.Context, metadata map[string]any) (map[string]any, error) {
	github, _ := metadata["refresh_token"].(string)
	if strings.TrimSpace(github) == "" {
		return nil, errors.New("missing GitHub token")
	}
	header := map[string]string{"Authorization": "Bearer " + github}
	for k, v := range copilotHeaders {
		header[k] = v
	}
	status, data, err := copilotHTTP(ctx, http.MethodGet, "https://api.github.com/copilot_internal/v2/token", nil, header)
	if err != nil || status != http.StatusOK {
		return nil, fmt.Errorf("copilot token HTTP %d", status)
	}
	var r struct {
		Token     string `json:"token"`
		ExpiresAt int64  `json:"expires_at"`
	}
	if json.Unmarshal(data, &r) != nil || r.Token == "" || r.ExpiresAt <= 0 {
		return nil, errors.New("invalid copilot token")
	}
	if _, err := copilotBaseURL(r.Token); err != nil {
		return nil, err
	}
	out := map[string]any{}
	for k, v := range metadata {
		out[k] = v
	}
	out["type"] = "github-copilot"
	out["access_token"] = r.Token
	// Match pi: renew five minutes before the provider expiry.
	out["expired"] = time.Unix(r.ExpiresAt, 0).Add(-5 * time.Minute).UTC().Format(time.RFC3339)
	out["last_refresh"] = time.Now().UTC().Format(time.RFC3339)
	return out, nil
}

// The Copilot token names its API proxy. Accept only GitHub Copilot hosts, so
// an imported token cannot direct requests to another network location.
func copilotBaseURL(token string) (string, error) {
	for _, field := range strings.Split(token, ";") {
		if host, ok := strings.CutPrefix(field, "proxy-ep="); ok {
			host = "api." + strings.TrimPrefix(strings.TrimSpace(host), "proxy.")
			u, err := url.Parse("https://" + host)
			if err != nil || u.Host != host || u.Port() != "" || !strings.HasSuffix(u.Hostname(), ".githubcopilot.com") {
				return "", errors.New("unsupported copilot endpoint")
			}
			return "https://" + host, nil
		}
	}
	return copilotDefaultBaseURL, nil
}

// copilotExecutor supplies the Copilot token, endpoint, and client headers to
// CLIProxyAPI's OpenAI-compatible executor, and owns token renewal.
type copilotExecutor struct{ auth.ProviderExecutor }

func (e copilotExecutor) withAttributes(a *auth.Auth, payload []byte) (*auth.Auth, error) {
	token, _ := a.Metadata["access_token"].(string)
	base, err := copilotBaseURL(token)
	if err != nil {
		return nil, err
	}
	clone := a.Clone()
	clone.Attributes = map[string]string{"base_url": base, "api_key": token}
	for k, v := range copilotHeaders {
		clone.Attributes["header:"+k] = v
	}
	clone.Attributes["header:Openai-Intent"] = "conversation-edits"
	// Copilot bills a user-initiated request differently from an agent follow-up.
	initiator := "user"
	if messages := gjson.GetBytes(payload, "messages").Array(); len(messages) > 0 && messages[len(messages)-1].Get("role").String() != "user" {
		initiator = "agent"
	}
	clone.Attributes["header:X-Initiator"] = initiator
	if strings.Contains(string(payload), `"image_url"`) {
		clone.Attributes["header:Copilot-Vision-Request"] = "true"
	}
	return clone, nil
}

func (e copilotExecutor) Execute(ctx context.Context, a *auth.Auth, req executor.Request, opts executor.Options) (executor.Response, error) {
	prepared, err := e.withAttributes(a, req.Payload)
	if err != nil {
		return executor.Response{}, err
	}
	return e.ProviderExecutor.Execute(ctx, prepared, req, opts)
}

func (e copilotExecutor) ExecuteStream(ctx context.Context, a *auth.Auth, req executor.Request, opts executor.Options) (*executor.StreamResult, error) {
	prepared, err := e.withAttributes(a, req.Payload)
	if err != nil {
		return nil, err
	}
	return e.ProviderExecutor.ExecuteStream(ctx, prepared, req, opts)
}

func (e copilotExecutor) Refresh(ctx context.Context, a *auth.Auth) (*auth.Auth, error) {
	metadata, err := copilotExchange(ctx, a.Metadata)
	if err != nil {
		return nil, err
	}
	clone := a.Clone()
	clone.Metadata = metadata
	return clone, nil
}

// Copilot reports plan quota through the GitHub API with the GitHub token.
// Premium requests do not gate included models, so that window carries a
// "premium" scope and never excludes the account from selection.
func copilotQuota(ctx context.Context, a *auth.Auth, now time.Time) (Snapshot, error) {
	github, _ := a.Metadata["refresh_token"].(string)
	if github == "" {
		return Snapshot{}, errors.New("missing GitHub token")
	}
	header := map[string]string{"Authorization": "Bearer " + github}
	for k, v := range copilotHeaders {
		header[k] = v
	}
	status, data, err := copilotHTTP(ctx, http.MethodGet, "https://api.github.com/copilot_internal/user", nil, header)
	if err != nil || status != http.StatusOK {
		return Snapshot{}, fmt.Errorf("quota HTTP %d", status)
	}
	return decodeCopilotQuota(data, now)
}

func decodeCopilotQuota(data []byte, now time.Time) (Snapshot, error) {
	root := gjson.ParseBytes(data)
	s := Snapshot{ObservedAt: now, PlanType: strings.TrimSpace(root.Get("copilot_plan").String())}
	raw := root.Get("quota_reset_date_utc").String()
	reset, err := time.Parse(time.RFC3339, raw)
	if err != nil {
		reset, err = time.Parse("2006-01-02", root.Get("quota_reset_date").String())
	}
	if err != nil {
		return Snapshot{}, errors.New("missing quota reset")
	}
	for _, scope := range []struct{ key, model string }{{"chat", ""}, {"premium_interactions", "premium"}} {
		q := root.Get("quota_snapshots." + scope.key)
		remaining := q.Get("percent_remaining")
		if !q.Exists() || q.Get("unlimited").Bool() || remaining.Type != gjson.Number {
			continue
		}
		s.addWindow(remaining.Float(), reset, "month", scope.model)
	}
	if len(s.Windows) == 0 {
		return Snapshot{}, errors.New("no supported quota windows")
	}
	return s, nil
}
