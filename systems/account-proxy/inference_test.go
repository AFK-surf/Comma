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
	"reflect"
	"strings"
	"sync"
	"testing"
)

type fixtureCall func(string, string) testResult

func TestCodexSelectedModelAndEffortReachUpstream(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprintf("stream=%v", stream), func(t *testing.T) {
			call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var request struct {
					Model     string `json:"model"`
					Reasoning struct {
						Effort string `json:"effort"`
					} `json:"reasoning"`
				}
				if json.NewDecoder(r.Body).Decode(&request) != nil || request.Model != "gpt-5.5" || request.Reasoning.Effort != "ultra" {
					t.Errorf("selection changed: %+v", request)
				}
				w.Header().Set("Content-Type", "text/event-stream")
				fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"gpt-5.5\",\"output\":[]}}\n\n")
			}))
			result := call("/v1/responses", fmt.Sprintf(`{"model":"gpt-5.5","reasoning":{"effort":"ultra"},"input":"hi","stream":%t}`, stream))
			if result.Code != 200 {
				t.Fatalf("request failed: %d %s", result.Code, result.ErrorCode)
			}
		})
	}
}

func TestCodexEmptyToolArgumentsReachUpstreamAsJSON(t *testing.T) {
	for _, stream := range []bool{false, true} {
		t.Run(fmt.Sprintf("stream=%v", stream), func(t *testing.T) {
			call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var request struct {
					Input []struct {
						Type      string `json:"type"`
						Arguments string `json:"arguments"`
					} `json:"input"`
				}
				if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
					t.Fatal(err)
				}
				if len(request.Input) != 2 || request.Input[0].Type != "function_call" || request.Input[0].Arguments != "{}" {
					t.Errorf("empty tool arguments were not normalized: %+v", request.Input)
				}
				w.Header().Set("Content-Type", "text/event-stream")
				fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n")
			}))
			result := call("/v1/responses", fmt.Sprintf(`{"model":"gpt-5.5","input":[{"type":"function_call","call_id":"call","name":"lookup","arguments":""},{"type":"function_call_output","call_id":"call","output":"done"}],"stream":%t}`, stream))
			if result.Code != 200 {
				t.Fatalf("tool continuation failed: %d %s", result.Code, result.ErrorCode)
			}
		})
	}
}

func TestCodexPreservesTrailingDeveloperReminderOrder(t *testing.T) {
	history := []map[string]any{{"role": "user", "content": "Stable question"}}
	for round := 0; round < 3; round++ {
		input := append(append([]map[string]any{}, history...), map[string]any{"role": "developer", "content": "turn: decide=on"})
		call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			var body struct {
				Instructions string           `json:"instructions"`
				Input        []map[string]any `json:"input"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				t.Error(err)
				return
			}
			if body.Instructions != "Stable instructions" || !reflect.DeepEqual(body.Input, input) {
				t.Errorf("round %d: instructions or ordered history/reminder changed: %+v", round, body)
			}
			w.Header().Set("Content-Type", "text/event-stream")
			fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n")
		}))
		payload, err := json.Marshal(map[string]any{"model": "gpt-5.5", "instructions": "Stable instructions", "input": input, "stream": true})
		if err != nil {
			t.Fatal(err)
		}
		if result := call("/v1/responses", string(payload)); result.Code != 200 {
			t.Fatalf("round %d: %d %s", round, result.Code, result.ErrorCode)
		}
		id := fmt.Sprintf("read-%d", round)
		history = append(history,
			map[string]any{"type": "function_call", "call_id": id, "name": "read", "arguments": "{}"},
			map[string]any{"type": "function_call_output", "call_id": id, "output": "Stable result"})
	}
}

type testResult struct {
	Code      int
	ErrorCode string
	Body      *bytes.Buffer
}

func fixture(t *testing.T, provider string, h http.Handler) (fixtureCall, *rewriteTransport) {
	t.Helper()
	up := httptest.NewServer(h)
	t.Cleanup(up.Close)
	u, _ := url.Parse(up.URL)
	rt := &rewriteTransport{url: u, handler: http.DefaultTransport}
	c := Credential{Provider: provider, Credentials: map[string]any{"access_token": "synthetic-selected", "account_id": "upstream", "account_uuid": "11111111-1111-4111-8111-111111111111", "claude_device_ids": []string{strings.Repeat("a", 64)}}}
	return func(path, body string) testResult {
		result := testResult{Code: 200, Body: new(bytes.Buffer)}
		err := execute(context.WithValue(context.Background(), "cliproxy.roundtripper", rt), path, json.RawMessage(body), c, func(data []byte) error { _, err := result.Body.Write(data); return err })
		if err != nil {
			result.Code = 503
			var oe *operationError
			if errors.As(err, &oe) {
				result.Code = oe.status
				result.ErrorCode = oe.code
			}
		}
		return result
	}, rt
}

type rewriteTransport struct {
	url     *url.URL
	mu      sync.Mutex
	calls   []string
	handler http.RoundTripper
}

func (rt *rewriteTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	if r.URL.Host != "chatgpt.com" && r.URL.Host != "api.anthropic.com" && r.URL.Host != "auth.openai.com" {
		return nil, fmt.Errorf("unexpected upstream %s", r.URL.Host)
	}
	clone := r.Clone(r.Context())
	u := *r.URL
	u.Scheme, u.Host = rt.url.Scheme, rt.url.Host
	clone.URL = &u
	rt.mu.Lock()
	rt.calls = append(rt.calls, r.Header.Get("Authorization"))
	rt.mu.Unlock()
	return rt.handler.RoundTrip(clone)
}

func TestNativeExecutorsUseOnlySuppliedCredential(t *testing.T) {
	for _, provider := range []string{"codex", "claude"} {
		for _, stream := range []bool{false, true} {
			t.Run(fmt.Sprintf("%s/stream=%v", provider, stream), func(t *testing.T) {
				s, rt := fixture(t, provider, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					body, _ := io.ReadAll(r.Body)
					if provider == "claude" {
						var request struct {
							System []struct {
								Text string `json:"text"`
							} `json:"system"`
						}
						if err := json.Unmarshal(body, &request); err != nil {
							t.Fatal(err)
						}
						if len(request.System) != 1 || request.System[0].Text != "SALIX_SYSTEM_SENTINEL" {
							t.Errorf("Salix system instructions changed: %+v", request.System)
						}
					}
					if !strings.Contains(string(body), "lookup") {
						t.Error("missing tool")
					}
					if !strings.Contains(r.Header.Get("Authorization"), "synthetic") {
						t.Error("missing OAuth token")
					}
					if provider == "codex" {
						w.Header().Set("Content-Type", "text/event-stream")
						fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"object\":\"response\",\"status\":\"completed\",\"model\":\"gpt-5.5\",\"output\":[{\"type\":\"function_call\",\"id\":\"fc\",\"call_id\":\"call\",\"name\":\"lookup\",\"arguments\":\"{}\"}],\"usage\":{\"input_tokens\":10,\"output_tokens\":3}}}\n\n")
					} else if !stream {
						fmt.Fprint(w, `{"id":"msg","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"tool_use","id":"call","name":"lookup","input":{}}],"stop_reason":"tool_use","usage":{"input_tokens":10,"output_tokens":3}}`)
					} else {
						fmt.Fprint(w, "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"msg\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude-sonnet-4-6\",\"content\":[],\"usage\":{\"input_tokens\":10,\"output_tokens\":0}}}\n\nevent: content_block_start\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call\",\"name\":\"lookup\",\"input\":{}}}\n\nevent: content_block_stop\ndata: {\"type\":\"content_block_stop\",\"index\":0}\n\nevent: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3}}\n\nevent: message_stop\ndata: {\"type\":\"message_stop\"}\n\n")
					}
				}))
				path, payload := "/v1/responses", `{"model":"gpt-5.5","input":"hi","tools":[{"type":"function","name":"lookup","parameters":{"type":"object"}}]}`
				if provider == "claude" {
					path, payload = "/v1/messages", `{"model":"claude-sonnet-4-6","max_tokens":128,"system":"SALIX_SYSTEM_SENTINEL","messages":[{"role":"user","content":"hi"}],"tools":[{"name":"lookup","input_schema":{"type":"object"}}]}`
				}
				if stream {
					payload = strings.TrimSuffix(payload, "}") + `,"stream":true}`
				}
				w := s(path, payload)
				if w.Code != 200 || !strings.Contains(w.Body.String(), "lookup") {
					t.Fatalf("native result %d: %s", w.Code, w.Body.String())
				}
				if len(rt.calls) != 1 {
					t.Fatal("unexpected attempts", rt.calls)
				}
			})
		}
	}
}
func TestNativeCodexCompactionWithSelectedCredential(t *testing.T) {
	s, rt := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !strings.HasSuffix(r.URL.Path, "/responses/compact") {
			t.Errorf("wrong compaction path: %s", r.URL.Path)
		}
		body, _ := io.ReadAll(r.Body)
		if !strings.Contains(string(body), "summarize me") {
			t.Error("compaction input lost")
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"id":"cmp_1","object":"response.compaction","output":[{"type":"compaction","encrypted_content":"compact-result"}],"usage":{"input_tokens":20,"output_tokens":4}}`)
	}))
	payload := `{"model":"gpt-5.5","input":[{"role":"user","content":"summarize me"}]}`
	result := s("/v1/responses/compact", payload)
	if result.Code != 200 || !strings.Contains(result.Body.String(), "compact-result") || !strings.Contains(result.Body.String(), "usage") {
		t.Fatalf("compaction result %d: %s", result.Code, result.Body.String())
	}
	if result := s("/v1/responses/compact", `{"model":"gpt-5.5","stream":true}`); result.Code != 400 {
		t.Fatalf("stream accepted: %d", result.Code)
	}
	rt.mu.Lock()
	defer rt.mu.Unlock()
	if len(rt.calls) != 1 {
		t.Fatalf("unexpected upstream calls: %d", len(rt.calls))
	}
}

func TestCodexStreamFramesAreIndividuallyDecodable(t *testing.T) {
	events := []string{
		`{"type":"response.created","response":{"id":"r","status":"in_progress"}}`,
		`{"type":"response.output_text.delta","delta":"Hello"}`,
		`{"type":"response.completed","response":{"id":"r","status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}],"usage":{"input_tokens":1,"output_tokens":1}}}`,
	}
	s, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		for _, event := range events {
			fmt.Fprintf(w, "data: %s\n\n", event)
		}
	}))
	w := s("/v1/responses", `{"model":"gpt-5.5","input":"hello","stream":true}`)
	if w.Code != 200 {
		t.Fatalf("status %d", w.Code)
	}
	frames := strings.Split(strings.TrimSpace(w.Body.String()), "\n\n")
	if len(frames) != len(events) {
		t.Fatalf("want %d frames, got %d", len(events), len(frames))
	}
	for _, frame := range frames {
		if !strings.HasPrefix(frame, "data: ") || !json.Valid([]byte(strings.TrimPrefix(frame, "data: "))) {
			t.Fatalf("invalid SSE event: %s", frame)
		}
	}
}

func TestContextOverflowKeepsOnlyNormalizedErrorCode(t *testing.T) {
	for _, provider := range []string{"codex", "claude"} {
		s, _ := fixture(t, provider, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.WriteHeader(400)
			_, _ = io.WriteString(w, `{"error":{"message":"prompt is too long: private-provider-detail"}}`)
		}))
		path := "/v1/responses"
		if provider == "claude" {
			path = "/v1/messages"
		}
		result := s(path, `{"model":"test","stream":true,"messages":[],"input":[]}`)
		if result.Code != 400 || result.ErrorCode != "context_length_exceeded" {
			t.Fatalf("%s: status=%d code=%s", provider, result.Code, result.ErrorCode)
		}
		if strings.Contains(result.ErrorCode, "private-provider-detail") {
			t.Fatal("raw upstream detail escaped")
		}
	}
}

func TestCodexImageGenerationUsesSelectedSubscription(t *testing.T) {
	call, rt := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/backend-api/codex/images/generations" {
			t.Errorf("wrong image endpoint: %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer synthetic-selected" {
			t.Error("selected credential missing")
		}
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if body["model"] != "gpt-image-2" || body["prompt"] != "a blue circle" {
			t.Errorf("image request lost: %v", body)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"data":[{"b64_json":"aW1hZ2U="}],"output_format":"png"}`)
	}))
	result := call("/v1/images/generations", `{"model":"gpt-image-2","prompt":"a blue circle","output_format":"png"}`)
	if result.Code != 200 || !strings.Contains(result.Body.String(), "aW1hZ2U=") {
		t.Fatalf("image generation failed: %d %s", result.Code, result.ErrorCode)
	}
	if len(rt.calls) != 1 {
		t.Fatalf("want one upstream call, got %d", len(rt.calls))
	}
}

func TestCodexImageEditPreservesReferenceImage(t *testing.T) {
	call, _ := fixture(t, "codex", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/backend-api/codex/images/edits" {
			t.Errorf("wrong edit endpoint: %s", r.URL.Path)
		}
		var body struct {
			Images []struct {
				URL string `json:"image_url"`
			} `json:"images"`
		}
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		if len(body.Images) != 1 || body.Images[0].URL != "data:image/png;base64,aW1hZ2U=" {
			t.Errorf("reference image lost: %+v", body)
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"data":[{"b64_json":"ZWRpdGVk"}]}`)
	}))
	result := call("/v1/images/edits", `{"model":"gpt-image-2","prompt":"make it red","images":[{"image_url":"data:image/png;base64,aW1hZ2U="}]}`)
	if result.Code != 200 || !strings.Contains(result.Body.String(), "ZWRpdGVk") {
		t.Fatalf("edit failed: %d %s", result.Code, result.ErrorCode)
	}
	wrong, _ := fixture(t, "claude", http.HandlerFunc(func(http.ResponseWriter, *http.Request) { t.Fatal("wrong provider must not execute") }))
	if result := wrong("/v1/images/generations", `{"model":"gpt-image-2","prompt":"test"}`); result.Code != 400 || result.ErrorCode != "provider_mismatch" {
		t.Fatalf("wrong provider admitted: %+v", result)
	}
}
