package accountproxy

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"slices"
	"strings"
	"testing"
	"time"
)

func TestCodexCatalogPreservesModelReasoningChoices(t *testing.T) {
	call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"models":[{"slug":"gpt-live","display_name":"Live model","default_reasoning_level":"ultra","supported_reasoning_levels":[{"effort":"low"},{"effort":"ultra"},{"effort":"future"},{"effort":"low"}]},{"slug":"plain"},{"slug":"hidden","visibility":"hide","supported_reasoning_levels":[{"effort":"high"}]}]}`)
	}))
	result := call("/models", `{"provider":"codex","credentials":{"access_token":"synthetic"}}`)
	var listing modelListing
	if result.Code != 200 || json.Unmarshal(result.Body.Bytes(), &listing) != nil || len(listing.Data) != 2 {
		t.Fatalf("catalog: status=%d body=%s", result.Code, result.Body)
	}
	if !slices.Equal(listing.Data[0].ReasoningEfforts, []string{"low", "ultra", "future"}) || listing.Data[0].DefaultReasoningEffort != "ultra" {
		t.Fatalf("lost provider reasoning choices: %+v", listing.Data[0])
	}
	if len(listing.Data[1].ReasoningEfforts) != 0 || listing.Data[1].DefaultReasoningEffort != "" {
		t.Fatalf("invented reasoning capability: %+v", listing.Data[1])
	}
}

func TestModelsAdapterUsesSDKAndBodyCredential(t *testing.T) {
	for _, provider := range []string{"codex", "claude"} {
		t.Run(provider, func(t *testing.T) {
			calls := 0
			call, _ := fixture(t, provider, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				calls++
				if r.Method != "GET" || r.Header.Get("Authorization") != "Bearer synthetic-body" || r.Header.Get("Accept") != "application/json" {
					t.Errorf("wrong SDK request method or authentication")
				}
				if provider == "codex" {
					if r.URL.Path != "/backend-api/codex/models" || r.URL.Query().Get("client_version") != "0.153.3" || r.Header.Get("Originator") != "codex_cli_rs" || !strings.Contains(r.UserAgent(), "0.153.3") || r.Header.Get("Chatgpt-Account-Id") != "body-account" {
						t.Error("missing Codex discovery contract")
					}
					fmt.Fprint(w, `{"models":[{"slug":"live-codex","display_name":"Live Codex","input_modalities":["text","image"]}]}`)
				} else {
					if r.URL.Path != "/v1/models" || r.Header.Get("anthropic-beta") != "oauth-2025-04-20" || r.Header.Get("anthropic-version") != "2023-06-01" || r.URL.Query().Get("limit") != "1000" {
						t.Error("missing Claude discovery contract")
					}
					fmt.Fprint(w, `{"data":[{"id":"live-claude","display_name":"Live Claude","capabilities":{"image_input":{"supported":true}}}],"has_more":false}`)
				}
			}))
			body, _ := json.Marshal(Credential{Provider: provider, Credentials: map[string]any{"tokens": map[string]any{"access_token": "synthetic-body", "refresh_token": "must-not-refresh", "expired": "2000-01-01T00:00:00Z", "account_id": "body-account", "base_url": "https://untrusted.invalid", "headers": map[string]string{"Authorization": "wrong"}}}})
			got := call("/models", string(body))
			var listing modelListing
			if got.Code != 200 || json.Unmarshal(got.Body.Bytes(), &listing) != nil || len(listing.Data) != 1 || listing.Data[0].ID != "live-"+provider || !listing.Data[0].SupportsImages || listing.Truncated || calls != 1 {
				t.Fatalf("result=%+v body=%s calls=%d", got, got.Body, calls)
			}
			if !strings.Contains(got.Body.String(), `"supports_images":true`) {
				t.Fatal("missing explicit capability")
			}
		})
	}
}

func TestModelsDoNotInferImageSupportFromModelNames(t *testing.T) {
	for _, tc := range []struct{ provider, body string }{
		{"codex", `{"models":[{"slug":"vision-model","input_modalities":["text"]},{"slug":"legacy-model"}]}`},
		{"claude", `{"data":[{"id":"vision-model","capabilities":{"image_input":{"supported":false}}},{"id":"legacy-model"}]}`},
	} {
		t.Run(tc.provider, func(t *testing.T) {
			result, err := queryModelsWithRequester(context.Background(), &auth.Auth{Provider: tc.provider},
				func(context.Context, *auth.Auth, *http.Request) (*http.Response, error) {
					return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(tc.body))}, nil
				})
			if err != nil || len(result.Data) != 2 {
				t.Fatalf("result=%+v err=%v", result, err)
			}
			for _, model := range result.Data {
				if model.SupportsImages {
					t.Fatalf("undeclared image support: %+v", model)
				}
			}
		})
	}
}

type modelsExecutor struct {
	auth.ProviderExecutor // Unexpected Refresh/Execute calls fail the test.
	request               modelRequester
}

func (e modelsExecutor) HttpRequest(ctx context.Context, a *auth.Auth, r *http.Request) (*http.Response, error) {
	return e.request(ctx, a, r)
}

func TestModelsPaginationAndLimits(t *testing.T) {
	for _, tc := range []struct {
		name, provider  string
		pages           []string
		want            int
		truncated, fail bool
	}{
		{name: "complete Claude", provider: "claude", pages: []string{`{"data":[{"id":"a","display_name":"A"}],"has_more":true,"last_id":"cursor /?&"}`, `{"data":[{"id":"b"}],"has_more":false}`}, want: 2},
		{name: "empty", provider: "codex", pages: []string{`{"models":[]}`}},
		{name: "malformed", provider: "codex", pages: []string{`{"models":`}, fail: true},
		{name: "missing array", provider: "claude", pages: []string{`{}`}, fail: true},
		{name: "null array", provider: "codex", pages: []string{`{"models":null}`}, fail: true},
		{name: "empty ID", provider: "claude", pages: []string{`{"data":[{"id":" "}]}`}, fail: true},
		{name: "no cursor", provider: "claude", pages: []string{`{"data":[{"id":"a"}],"has_more":true}`}, fail: true},
		{name: "repeated cursor", provider: "claude", pages: []string{`{"data":[{"id":"a"}],"has_more":true,"last_id":"a"}`, `{"data":[{"id":"b"}],"has_more":true,"last_id":"a"}`}, fail: true},
		{name: "partial then malformed", provider: "claude", pages: []string{`{"data":[{"id":"a"}],"has_more":true,"last_id":"a"}`, `{}`}, fail: true},
		{name: "five pages", provider: "claude", pages: []string{
			`{"data":[{"id":"a"}],"has_more":true,"last_id":"a"}`,
			`{"data":[{"id":"b"}],"has_more":true,"last_id":"b"}`,
			`{"data":[{"id":"c"}],"has_more":true,"last_id":"c"}`,
			`{"data":[{"id":"d"}],"has_more":true,"last_id":"d"}`,
			`{"data":[{"id":"e"}],"has_more":true,"last_id":"e"}`}, want: 5, truncated: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			calls := 0
			a := &auth.Auth{Provider: tc.provider, Metadata: map[string]any{"access_token": "synthetic"}}
			e := modelsExecutor{request: func(ctx context.Context, got *auth.Auth, req *http.Request) (*http.Response, error) {
				if got != a {
					t.Fatal("credential replaced")
				}
				deadline, ok := ctx.Deadline()
				if !ok || time.Until(deadline) > 15*time.Second || req.Context() != ctx {
					t.Fatal("missing shared bounded context")
				}
				if calls >= len(tc.pages) {
					t.Fatal("unbounded pagination")
				}
				if tc.name == "complete Claude" && calls == 1 && req.URL.Query().Get("after_id") != "cursor /?&" {
					t.Fatal("cursor not encoded")
				}
				body := tc.pages[calls]
				calls++
				return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
			}}
			got, err := queryModels(context.Background(), e, a)
			if (err != nil) != tc.fail || (!tc.fail && (len(got.Data) != tc.want || got.Truncated != tc.truncated || got.Data == nil)) {
				t.Fatalf("got=%+v err=%v", got, err)
			}
			if tc.fail && len(got.Data) != 0 {
				t.Fatal("partial success on failed listing")
			}
			if calls != len(tc.pages) {
				t.Fatalf("calls=%d", calls)
			}
			if tc.name == "complete Claude" && got.Data[1].Name != "b" {
				t.Fatal("missing name fallback")
			}
		})
	}
	for _, n := range []int{1000, 1001} {
		for _, provider := range []string{"codex", "claude"} {
			t.Run(fmt.Sprintf("%s/%d", provider, n), func(t *testing.T) {
				entries := make([]map[string]string, n)
				for i := range entries {
					entries[i] = map[string]string{"id": fmt.Sprint(i), "slug": fmt.Sprint(i)}
				}
				key := "models"
				if provider == "claude" {
					key = "data"
				}
				raw, _ := json.Marshal(map[string]any{key: entries})
				got, err := queryModelsWithRequester(context.Background(), &auth.Auth{Provider: provider}, func(context.Context, *auth.Auth, *http.Request) (*http.Response, error) {
					return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(raw)))}, nil
				})
				if err != nil || len(got.Data) != 1000 || got.Truncated != (n > 1000) {
					t.Fatalf("count=%d truncated=%v err=%v", len(got.Data), got.Truncated, err)
				}
			})
		}
	}
}

func TestModelsAdapterScrubsFailuresAndRejectsRedirects(t *testing.T) {
	for _, provider := range []string{"codex", "claude"} {
		for _, status := range []int{302, 307, 401, 429, 500} {
			t.Run(fmt.Sprintf("%s/%d", provider, status), func(t *testing.T) {
				calls := 0
				call, _ := fixture(t, provider, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					calls++
					w.Header().Set("Location", "https://untrusted.invalid/secret")
					w.WriteHeader(status)
					fmt.Fprint(w, "secret-token-provider-error")
				}))
				got := call("/models", fmt.Sprintf(`{"provider":%q,"credentials":{"access_token":"synthetic"}}`, provider))
				if got.Code != 502 || got.ErrorCode != "models_unavailable" || got.Body.Len() != 0 || calls != 1 {
					t.Fatalf("got=%+v calls=%d", got, calls)
				}
			})
		}
	}
	for _, body := range []string{`{`, `{"provider":"other","credentials":{"access_token":"synthetic"}}`, `{"provider":"codex","credentials":{}}`} {
		err := execute(context.Background(), "/models", json.RawMessage(body), Credential{}, func([]byte) error { t.Fatal("unexpected success"); return nil })
		var oe *operationError
		if !errors.As(err, &oe) || oe.status != 400 {
			t.Fatalf("invalid input: %v", err)
		}
	}
}

func TestModelsResponseBudgetAndCancellation(t *testing.T) {
	for _, size := range []int{maxModelResponseBytes, maxModelResponseBytes + 1} {
		prefix := `{"models":[],"padding":"`
		body := prefix + strings.Repeat("x", size-len(prefix)-2) + `"}`
		got, err := queryModelsWithRequester(context.Background(), &auth.Auth{Provider: "codex"}, func(context.Context, *auth.Auth, *http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
		})
		if (err != nil) != (size > maxModelResponseBytes) || (err == nil && got.Data == nil) {
			t.Fatalf("size=%d err=%v", size, err)
		}
	}
	calls := 0
	_, err := queryModelsWithRequester(context.Background(), &auth.Auth{Provider: "claude"}, func(context.Context, *auth.Auth, *http.Request) (*http.Response, error) {
		calls++
		body := fmt.Sprintf(`{"data":[{"id":%q}],"has_more":true,"last_id":%q,"padding":"%s"}`, fmt.Sprint(calls), fmt.Sprint(calls), strings.Repeat("x", maxModelResponseBytes/2))
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(body))}, nil
	})
	if err == nil || calls != 2 {
		t.Fatalf("aggregate budget: calls=%d err=%v", calls, err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, err = queryModelsWithRequester(ctx, &auth.Auth{Provider: "codex"}, func(ctx context.Context, _ *auth.Auth, _ *http.Request) (*http.Response, error) {
		<-ctx.Done()
		return nil, errors.New("secret-token")
	})
	if err == nil || err.Error() != "models_unavailable" || time.Since(start) > time.Second {
		t.Fatalf("cancellation: %v", err)
	}
}

func TestModelsRedirectCannotDispatchCredentialToAnotherURL(t *testing.T) {
	for _, provider := range []string{"codex", "claude"} {
		for _, location := range []string{"https://untrusted.invalid/leak", "https://chatgpt.com/backend-api/codex/models?leak", "http://api.anthropic.com/v1/models"} {
			t.Run(provider+"/"+location, func(t *testing.T) {
				calls := 0
				ctx := context.WithValue(context.Background(), "cliproxy.roundtripper", refreshTransport(func(r *http.Request) (*http.Response, error) {
					calls++
					if calls > 1 {
						return nil, errors.New("redirect dispatched")
					}
					return &http.Response{StatusCode: 302, Header: http.Header{"Location": {location}}, Body: io.NopCloser(strings.NewReader("secret"))}, nil
				}))
				body := json.RawMessage(fmt.Sprintf(`{"provider":%q,"credentials":{"access_token":"synthetic"}}`, provider))
				err := execute(ctx, "/models", body, Credential{}, func([]byte) error { t.Fatal("redirect succeeded"); return nil })
				var oe *operationError
				if !errors.As(err, &oe) || oe.code != "models_unavailable" || calls != 1 {
					t.Fatalf("calls=%d err=%v", calls, err)
				}
			})
		}
	}
}

func TestModelsDeadlineDuringResponseBody(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"models":[`)
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	}))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	ctx := context.WithValue(context.Background(), "cliproxy.roundtripper", &rewriteTransport{url: u, handler: http.DefaultTransport})
	ctx, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel()
	e, err := cliproxy.NewSubscriptionExecutor("codex")
	if err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	_, err = queryModels(ctx, e, &auth.Auth{Provider: "codex", Metadata: map[string]any{"access_token": "synthetic"}})
	if err == nil || err.Error() != "models_unavailable" || time.Since(start) > time.Second {
		t.Fatalf("body deadline: %v", err)
	}
}

func TestModelsCodexFiltersAvailabilityAndPreservesDeclaredCapabilities(t *testing.T) {
	call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprint(w, `{"models":[
   {"slug":"hidden","visibility":"hide"},
   {"slug":"unavailable","available":false},
   {"slug":"subscription-only","display_name":"Subscription only","visibility":"list","supported_in_api":false,"input_modalities":["text","image"]},
   {"slug":"no-availability-field"}
  ]}`)
	}))
	got := call("/models", `{"provider":"codex","credentials":{"access_token":"synthetic"}}`)
	var listing modelListing
	if got.Code != 200 || json.Unmarshal(got.Body.Bytes(), &listing) != nil || len(listing.Data) != 2 || listing.Data[0].ID != "subscription-only" || listing.Data[0].Name != "Subscription only" || !listing.Data[0].SupportsImages || listing.Data[1].SupportsImages || listing.Truncated {
		t.Fatalf("result=%+v body=%s", got, got.Body)
	}
}

func TestModelsDeduplicateAcrossPagesBeforeUniqueLimit(t *testing.T) {
	calls := 0
	got, err := queryModelsWithRequester(context.Background(), &auth.Auth{Provider: "claude"}, func(ctx context.Context, a *auth.Auth, r *http.Request) (*http.Response, error) {
		calls++
		entries := []map[string]string{}
		if calls == 1 {
			for i := 0; i < 999; i++ {
				entries = append(entries, map[string]string{"id": fmt.Sprint(i), "display_name": "First"})
			}
		} else if calls == 2 {
			for i := 0; i < 999; i++ {
				entries = append(entries, map[string]string{"id": fmt.Sprint(i), "display_name": "Duplicate"})
			}
			entries = append(entries, map[string]string{"id": "last", "display_name": "Last"})
		} else {
			t.Fatal("unbounded duplicate pagination")
		}
		raw, _ := json.Marshal(map[string]any{"data": entries, "has_more": calls == 1, "last_id": "998"})
		return &http.Response{StatusCode: 200, Body: io.NopCloser(strings.NewReader(string(raw)))}, nil
	})
	if err != nil || calls != 2 || len(got.Data) != 1000 || got.Truncated || got.Data[0].Name != "First" || got.Data[999].ID != "last" {
		t.Fatalf("count=%d truncated=%v calls=%d err=%v", len(got.Data), got.Truncated, calls, err)
	}
}
