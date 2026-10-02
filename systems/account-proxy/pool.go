package accountproxy

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Salix uses email to match imports within one tenant and provider.
// Email is metadata, never proof of authorization.
// OAuth exchange already obtains email from the provider. Imported Codex files
// can carry the same identity in their ID token without a separate profile call.
func accountEmail(metadata map[string]any) string {
	if email, ok := metadata["email"].(string); ok && email != "" {
		return email
	}
	for _, key := range []string{"id_token", "access_token"} {
		token, _ := metadata[key].(string)
		claims := tokenClaims(token)
		if email, ok := claims["email"].(string); ok && email != "" {
			return email
		}
		if profile, ok := claims["https://api.openai.com/profile"].(map[string]any); ok {
			if email, ok := profile["email"].(string); ok && email != "" {
				return email
			}
		}
	}
	// Plans whose sign-in names no email (Kimi Code) still need a stable
	// identity, or each sign-in would add another account instead of
	// reconnecting this one.
	for _, key := range []string{"id_token", "access_token"} {
		token, _ := metadata[key].(string)
		claims := tokenClaims(token)
		for _, claim := range []string{"sub", "user_id"} {
			if id, ok := claims[claim].(string); ok && id != "" && len(id) <= 200 {
				return "id:" + id
			}
		}
	}
	return ""
}

// Claims supply identity and expiry hints only. Upstream still authenticates the token.
func tokenClaims(token string) map[string]any {
	parts := strings.Split(token, ".")
	if len(parts) != 3 || len(parts[1]) > 65536 {
		return nil
	}
	body, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil
	}
	var claims map[string]any
	if json.Unmarshal(body, &claims) != nil {
		return nil
	}
	return claims
}

func cleanCredentials(provider string, raw map[string]any) (map[string]any, error) {
	extra, ok := credentialKeys[provider]
	if !ok {
		return nil, errors.New("unsupported provider")
	}
	if tokens, ok := raw["tokens"].(map[string]any); ok {
		raw = tokens
	}
	if tokens, ok := raw["claudeAiOauth"].(map[string]any); ok {
		raw = map[string]any{"access_token": tokens["accessToken"], "refresh_token": tokens["refreshToken"]}
		if ms, ok := tokens["expiresAt"].(float64); ok {
			raw["expired"] = time.UnixMilli(int64(ms)).UTC().Format(time.RFC3339)
		}
	}
	out := map[string]any{"type": executorIDs[provider]}
	for _, k := range append([]string{"access_token", "refresh_token", "id_token", "email", "expired", "last_refresh"}, extra...) {
		if v, ok := raw[k]; ok {
			out[k] = v
		}
	}
	token, _ := out["access_token"].(string)
	if strings.TrimSpace(token) == "" {
		return nil, errors.New("access_token is required")
	}
	if expiry, _ := out["expired"].(string); expiry == "" {
		if exp, ok := tokenClaims(token)["exp"].(float64); ok && exp > 0 {
			out["expired"] = time.Unix(int64(exp), 0).UTC().Format(time.RFC3339)
		}
	}
	return out, nil
}
