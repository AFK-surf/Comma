package accountproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"regexp"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
)

var resetRequestID = regexp.MustCompile(`^[A-Za-z0-9_-]{16,128}$`)

type resetResult struct {
	Code         string `json:"code"`
	WindowsReset int64  `json:"windows_reset"`
}

// The pinned SDK supplies authenticated HTTP, but no reset-credit operation.
// Salix persists one redeem_request_id and reuses it after an uncertain response.
func consumeReset(ctx context.Context, e auth.ProviderExecutor, a *auth.Auth, requestID string) (resetResult, error) {
	body, _ := json.Marshal(map[string]string{"redeem_request_id": requestID})
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits/consume", bytes.NewReader(body))
	if err != nil {
		return resetResult{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Accept", "application/json")
	if id, ok := a.Metadata["account_id"].(string); ok {
		req.Header.Set("Chatgpt-Account-Id", id)
	}
	resp, err := e.HttpRequest(ctx, a, req)
	if err != nil {
		return resetResult{}, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return resetResult{}, fmt.Errorf("reset HTTP %d", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, 64*1024+1))
	if err != nil || len(data) > 64*1024 {
		return resetResult{}, fmt.Errorf("invalid reset response")
	}
	var result resetResult
	if json.Unmarshal(data, &result) != nil || result.WindowsReset < 0 {
		return resetResult{}, fmt.Errorf("invalid reset response")
	}
	switch result.Code {
	case "reset", "nothing_to_reset", "no_credit", "already_redeemed":
		return result, nil
	default:
		return resetResult{}, fmt.Errorf("unknown reset outcome")
	}
}
