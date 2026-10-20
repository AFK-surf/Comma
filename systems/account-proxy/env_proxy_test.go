package accountproxy

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"sync"
	"testing"

	"github.com/router-for-me/CLIProxyAPI/v8/sdk/proxyutil"
)

// connectRecorder is an HTTP proxy that records CONNECT targets and refuses them.
type connectRecorder struct {
	mu      sync.Mutex
	targets []string
}

func (p *connectRecorder) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	p.mu.Lock()
	p.targets = append(p.targets, r.Method+" "+r.Host)
	p.mu.Unlock()
	http.Error(w, "refused by test proxy", http.StatusForbidden)
}

func (p *connectRecorder) seen() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string(nil), p.targets...)
}

func useEnvironmentProxy(t *testing.T) *connectRecorder {
	t.Helper()
	recorder := &connectRecorder{}
	proxy := httptest.NewServer(recorder)
	t.Cleanup(proxy.Close)
	for _, k := range []string{"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"} {
		t.Setenv(k, "")
	}
	t.Setenv("HTTPS_PROXY", proxy.URL)
	return recorder
}

// Subscription inference runs on CLIProxyAPI's fingerprint transports, which
// ignored HTTPS_PROXY: behind an outbound proxy every call dialed the provider
// directly and hung until the first-event timeout.
func TestSubscriptionInferenceUsesEnvironmentProxy(t *testing.T) {
	for _, tc := range []struct{ provider, op, payload, want string }{
		{"codex", "/v1/responses", `{"model":"gpt-5.5","input":"hi","stream":true}`, "CONNECT chatgpt.com:443"},
		{"claude", "/v1/messages", `{"model":"claude-sonnet-4-6","max_tokens":16,"messages":[{"role":"user","content":"hi"}]}`, "CONNECT api.anthropic.com:443"},
	} {
		t.Run(tc.provider, func(t *testing.T) {
			recorder := useEnvironmentProxy(t)
			cred := Credential{Provider: tc.provider, Credentials: providerCredentials(tc.provider)}
			_ = inference(t.Context(), cred, tc.op, json.RawMessage(tc.payload), func([]byte) error { return nil })
			if !slices.Contains(recorder.seen(), tc.want) {
				t.Fatalf("inference bypassed the environment proxy; proxy saw %v, want %q", recorder.seen(), tc.want)
			}
		})
	}
}

// The fingerprint transports apply NO_PROXY per request, as Go's default
// transport does, and fall back to ALL_PROXY when HTTPS_PROXY is unset.
func TestEnvironmentProxyRules(t *testing.T) {
	chatgpt, _ := url.Parse("https://chatgpt.com/backend-api/codex/responses")
	anthropic, _ := url.Parse("https://api.anthropic.com/v1/messages")
	for _, tc := range []struct {
		name               string
		env                map[string]string
		chatgpt, anthropic string
	}{
		{"none", nil, "", ""},
		{"https proxy", map[string]string{"HTTPS_PROXY": "http://proxy.test:3128"}, "http://proxy.test:3128", "http://proxy.test:3128"},
		{"no proxy", map[string]string{"HTTPS_PROXY": "http://proxy.test:3128", "NO_PROXY": "chatgpt.com"}, "", "http://proxy.test:3128"},
		{"all proxy", map[string]string{"ALL_PROXY": "socks5://proxy.test:1080", "no_proxy": ".anthropic.com"}, "socks5://proxy.test:1080", ""},
	} {
		t.Run(tc.name, func(t *testing.T) {
			for _, k := range []string{"HTTPS_PROXY", "https_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"} {
				t.Setenv(k, tc.env[k])
			}
			proxyFor := proxyutil.EnvironmentProxy()
			if proxyFor == nil {
				if tc.chatgpt != "" || tc.anthropic != "" {
					t.Fatal("no environment proxy resolved")
				}
				return
			}
			for _, check := range []struct {
				target *url.URL
				want   string
			}{{chatgpt, tc.chatgpt}, {anthropic, tc.anthropic}} {
				got, err := proxyFor(check.target)
				if err != nil {
					t.Fatal(err)
				}
				gotURL := ""
				if got != nil {
					gotURL = got.String()
				}
				if gotURL != check.want {
					t.Fatalf("%s: proxy %q, want %q (empty means direct)", check.target.Host, gotURL, check.want)
				}
			}
		})
	}
}

// An injected transport still wins over the environment proxy: model discovery
// relies on it to refuse redirects, and the fixtures rely on it to stay local.
func TestInjectedTransportWinsOverEnvironmentProxy(t *testing.T) {
	recorder := useEnvironmentProxy(t)
	call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"gpt-5.5\",\"output\":[]}}\n\n")
	}))
	if result := call("/v1/responses", `{"model":"gpt-5.5","input":"hi","stream":true}`); result.Code != 200 {
		t.Fatalf("request failed: %d %s", result.Code, result.ErrorCode)
	}
	if seen := recorder.seen(); len(seen) != 0 {
		t.Fatalf("injected transport was bypassed; proxy saw %v", seen)
	}
}
