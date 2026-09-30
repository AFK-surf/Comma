package accountproxy

import (
	"encoding/base64"
	"testing"
)

func TestAccountEmail(t *testing.T) {
	jwt := func(claims string) string {
		return "header." + base64.RawURLEncoding.EncodeToString([]byte(claims)) + ".signature"
	}
	for _, tc := range []struct {
		name     string
		metadata map[string]any
		want     string
	}{
		{"provider profile", map[string]any{"email": "member@example.com"}, "member@example.com"},
		{"codex identity token", map[string]any{"id_token": jwt(`{"email":"codex@example.com"}`)}, "codex@example.com"},
		{"codex profile claim", map[string]any{"access_token": jwt(`{"https://api.openai.com/profile":{"email":"profile@example.com"}}`)}, "profile@example.com"},
		{"opaque credential", map[string]any{"access_token": "secret"}, ""},
		{"malformed claim", map[string]any{"id_token": "a.invalid.b"}, ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if got := accountEmail(tc.metadata); got != tc.want {
				t.Fatalf("email = %q, want %q", got, tc.want)
			}
		})
	}
}
