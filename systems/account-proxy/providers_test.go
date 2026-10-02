package accountproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"
)

const copilotToken = "tid=1;exp=9999999999;proxy-ep=proxy.individual.githubcopilot.com;sku=x"

func providerCredentials(provider string) map[string]any {
	expiry := time.Now().Add(time.Hour).UTC().Format(time.RFC3339)
	switch provider {
	case "gemini":
		return map[string]any{"access_token": "synthetic-selected", "expired": expiry, "project_id": "project-1"}
	case "kimi-code":
		return map[string]any{"access_token": "synthetic-selected", "expired": expiry, "device_id": "device-1"}
	case "github-copilot":
		return map[string]any{"access_token": copilotToken, "expired": expiry}
	}
	return map[string]any{"access_token": "synthetic-selected", "expired": expiry}
}

func providerFixture(t *testing.T, provider string, h http.Handler) (fixtureCall, *rewriteTransport) {
	t.Helper()
	up := httptest.NewServer(h)
	t.Cleanup(up.Close)
	u, _ := url.Parse(up.URL)
	rt := &rewriteTransport{url: u, handler: http.DefaultTransport}
	c := Credential{Provider: provider, Credentials: providerCredentials(provider)}
	return func(path, body string) testResult {
		result := testResult{Code: 200, Body: new(bytes.Buffer)}
		err := execute(context.WithValue(context.Background(), "cliproxy.roundtripper", rt), path, json.RawMessage(body), c, func(data []byte) error { _, err := result.Body.Write(data); return err })
		if err != nil {
			result.Code = 503
			var oe *operationError
			if errors.As(err, &oe) {
				result.Code, result.ErrorCode = oe.status, oe.code
			}
		}
		return result
	}, rt
}

func sse(w http.ResponseWriter, events ...string) {
	w.Header().Set("Content-Type", "text/event-stream")
	for _, e := range events {
		fmt.Fprintf(w, "data: %s\n\n", e)
	}
}

// Each new provider serves one Salix wire protocol through its native executor
// and sends only the selected credential to that provider's endpoint.
func TestSubscriptionProvidersExecuteSelectedCredential(t *testing.T) {
	claudeStream := []string{
		`{"type":"message_start","message":{"id":"m","type":"message","role":"assistant","model":"kimi-for-coding","content":[],"usage":{"input_tokens":3,"output_tokens":0}}}`,
		`{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
		`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}`,
		`{"type":"content_block_stop","index":0}`,
		`{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":1}}`,
		`{"type":"message_stop"}`,
	}
	cases := []struct {
		provider, path, request, upstreamPath, auth string
		respond                                     func(http.ResponseWriter, bool)
	}{
		{"grok", "/v1/responses", `{"model":"grok-build","input":"hi"}`, "/v1/responses", "Bearer synthetic-selected", func(w http.ResponseWriter, _ bool) {
			sse(w, `{"type":"response.output_text.delta","delta":"Hello"}`, `{"type":"response.completed","response":{"id":"r","object":"response","status":"completed","model":"grok-build","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}],"usage":{"input_tokens":3,"output_tokens":1}}}`)
		}},
		{"kimi-code", "/v1/messages", `{"model":"kimi-for-coding","max_tokens":64,"messages":[{"role":"user","content":"hi"}]}`, "/coding/v1/messages", "Bearer synthetic-selected", func(w http.ResponseWriter, stream bool) {
			if stream {
				sse(w, claudeStream...)
				return
			}
			fmt.Fprint(w, `{"id":"m","type":"message","role":"assistant","model":"kimi-for-coding","content":[{"type":"text","text":"Hello"}],"stop_reason":"end_turn","usage":{"input_tokens":3,"output_tokens":1}}`)
		}},
		{"gemini", "/v1/chat/completions", `{"model":"gemini-3-flash","messages":[{"role":"user","content":"hi"}]}`, "", "Bearer synthetic-selected", func(w http.ResponseWriter, _ bool) {
			sse(w, `{"response":{"candidates":[{"content":{"role":"model","parts":[{"text":"Hello"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":1,"totalTokenCount":4},"modelVersion":"gemini-3-flash"}}`)
		}},
		{"github-copilot", "/v1/chat/completions", `{"model":"gpt-4.1","messages":[{"role":"user","content":"hi"}]}`, "/chat/completions", "Bearer " + copilotToken, func(w http.ResponseWriter, stream bool) {
			if stream {
				sse(w, `{"id":"c","object":"chat.completion.chunk","model":"gpt-4.1","choices":[{"index":0,"delta":{"role":"assistant","content":"Hello"}}]}`, `{"id":"c","object":"chat.completion.chunk","model":"gpt-4.1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}`, `[DONE]`)
				return
			}
			fmt.Fprint(w, `{"id":"c","object":"chat.completion","model":"gpt-4.1","choices":[{"index":0,"message":{"role":"assistant","content":"Hello"},"finish_reason":"stop"}],"usage":{"prompt_tokens":3,"completion_tokens":1,"total_tokens":4}}`)
		}},
	}
	for _, tc := range cases {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%v", tc.provider, stream), func(t *testing.T) {
				call, rt := providerFixture(t, tc.provider, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					if tc.upstreamPath != "" && r.URL.Path != tc.upstreamPath {
						t.Errorf("upstream path %s, want %s", r.URL.Path, tc.upstreamPath)
					}
					if r.Header.Get("Authorization") != tc.auth {
						t.Errorf("credential not selected: %q", r.Header.Get("Authorization"))
					}
					if tc.provider == "github-copilot" && (r.Header.Get("Copilot-Integration-Id") != "vscode-chat" || r.Header.Get("X-Initiator") != "user") {
						t.Errorf("missing Copilot client headers: %v", r.Header)
					}
					if tc.provider == "gemini" {
						body, _ := io.ReadAll(r.Body)
						if !strings.Contains(string(body), `"project":"project-1"`) {
							t.Errorf("project missing from Antigravity request: %s", body)
						}
					}
					tc.respond(w, stream)
				}))
				request := tc.request
				if stream {
					request = strings.TrimSuffix(request, "}") + `,"stream":true}`
				}
				result := call(tc.path, request)
				if result.Code != 200 || !strings.Contains(result.Body.String(), "Hello") {
					t.Fatalf("result %d %s: %s", result.Code, result.ErrorCode, result.Body.String())
				}
				if tc.path == "/v1/chat/completions" && stream && !strings.HasSuffix(result.Body.String(), "data: [DONE]\n\n") {
					t.Fatalf("chat stream is not framed for SSE: %q", result.Body.String())
				}
				if tc.path == "/v1/responses" && stream && strings.Count(result.Body.String(), "\n\n") != 2 {
					t.Fatalf("Responses stream events are not delimited: %q", result.Body.String())
				}
				if len(rt.calls) != 1 {
					t.Fatalf("upstream calls: %v", rt.calls)
				}
			})
		}
	}
}

func TestInferenceRejectsProviderOutsideItsProtocol(t *testing.T) {
	call, rt := providerFixture(t, "gemini", http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	if result := call("/v1/messages", `{"model":"gemini-3-flash","max_tokens":1,"messages":[]}`); result.ErrorCode != "provider_mismatch" {
		t.Fatalf("result %+v", result)
	}
	if len(rt.calls) != 0 {
		t.Fatal("mismatched request reached a provider")
	}
	// Grok has no native compaction through the Grok Build proxy.
	grok, grokRT := providerFixture(t, "grok", http.HandlerFunc(func(http.ResponseWriter, *http.Request) {}))
	if result := grok("/v1/responses/compact", `{"model":"grok-4.3","input":"hi"}`); result.ErrorCode != "provider_mismatch" {
		t.Fatalf("grok compaction %+v", result)
	}
	if len(grokRT.calls) != 0 {
		t.Fatal("grok compaction reached a provider")
	}
}

// Imported endpoint fields cannot redirect a bearer token. A Copilot token may
// name only a GitHub Copilot API host.
func TestImportedCredentialsCannotChooseEndpoints(t *testing.T) {
	var out struct {
		Credentials map[string]any `json:"credentials"`
	}
	body, _ := json.Marshal(Credential{Provider: "grok", Credentials: map[string]any{"access_token": "a", "base_url": "http://169.254.169.254", "token_endpoint": "http://169.254.169.254/token"}})
	if err := execute(context.Background(), "/normalize", body, Credential{}, func(data []byte) error { return json.Unmarshal(data, &out) }); err != nil {
		t.Fatal(err)
	}
	if _, ok := out.Credentials["base_url"]; ok {
		t.Fatal("imported base_url retained")
	}
	if _, ok := out.Credentials["token_endpoint"]; ok {
		t.Fatal("imported token_endpoint retained")
	}
	for _, token := range []string{"tid=1;proxy-ep=proxy.attacker.example", "tid=1;proxy-ep=proxy.githubcopilot.com.attacker.example", "tid=1;proxy-ep=127.0.0.1:80"} {
		c := Credential{Provider: "github-copilot", Credentials: map[string]any{"access_token": token}}
		ctx := context.WithValue(context.Background(), "cliproxy.roundtripper", refreshTransport(func(r *http.Request) (*http.Response, error) {
			t.Errorf("token %q reached %s", token, r.URL.Host)
			return nil, errors.New("blocked")
		}))
		err := execute(ctx, "/v1/chat/completions", json.RawMessage(`{"model":"gpt-4.1","messages":[{"role":"user","content":"hi"}]}`), c, func([]byte) error { return nil })
		if err == nil {
			t.Fatalf("token %q was executed", token)
		}
	}
}
