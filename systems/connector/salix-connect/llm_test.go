package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestLLMChatForwardsBearerToken(t *testing.T) {
	c := &connector{
		runtimePending:    map[string]runtimePendingRequest{},
		runtimeProxySlots: make(chan struct{}, maxConcurrentRequests),
	}

	captured := make(chan map[string]any, 1)
	deactivate := activateRuntimeTransportForTest(c, func(m message) error {
		captured <- m.Params
		c.completeRuntimeProxy(message{
			ID:   m.ID,
			Type: "response",
			Result: map[string]any{
				"status":      float64(200),
				"headers":     map[string]any{"content-type": "application/json"},
				"body_base64": base64.StdEncoding.EncodeToString([]byte(`{"choices":[{"message":{"content":"HELLO"}}]}`)),
			},
		})
		return nil
	})
	defer deactivate()

	srv := httptest.NewServer(http.HandlerFunc(c.handleLLMChat))
	defer srv.Close()

	post := func(bearer string) *http.Response {
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/llm/chat",
			bytes.NewReader([]byte(`{"messages":[{"role":"user","content":"hi"}]}`)))
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		return resp
	}

	if resp := post(""); resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("missing token: want 401 got %d", resp.StatusCode)
	}

	resp := post("cap-abc")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("valid token: want 200 got %d", resp.StatusCode)
	}
	rb, _ := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	var decoded map[string]any
	if err := json.Unmarshal(rb, &decoded); err != nil {
		t.Fatalf("decode response: %v (%s)", err, rb)
	}
	if choices, _ := decoded["choices"].([]any); len(choices) == 0 {
		t.Fatalf("completion did not flow back: %v", decoded)
	}

	params := <-captured
	if params["capability_token"] != "cap-abc" {
		t.Fatalf("capability_token = %v, want cap-abc (the forwarded bearer)", params["capability_token"])
	}
	if params["route_path"] != "/llm/chat" {
		t.Fatalf("route_path = %v, want /llm/chat", params["route_path"])
	}
	fwd, _ := base64.StdEncoding.DecodeString(stringFromAny(params["body_base64"]))
	if !bytes.Contains(fwd, []byte(`"messages"`)) {
		t.Fatalf("forwarded body missing messages: %s", fwd)
	}
}

func TestMeetingJoinInjectsLLMURLAndPassesToken(t *testing.T) {
	var joinBody map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_ = json.NewDecoder(r.Body).Decode(&joinBody)
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"accepted":true}`))
	}))
	defer srv.Close()

	c := &connector{cfg: config{meetURL: srv.URL}}
	_, err := c.methodMeetingJoin(context.Background(), map[string]any{
		"meeting_id":           "m1",
		"meet_url":             "https://meet.google.com/abc-defg-hij",
		"runtime_token":        "tok",
		"llm_capability_token": "cap-secret",
	})
	if err != nil {
		t.Fatalf("join: %v", err)
	}

	url := stringFromAny(joinBody["llm_url"])
	if url == "" || !bytes.HasSuffix([]byte(url), []byte("/llm/chat")) {
		t.Fatalf("llm_url not injected correctly: %q", url)
	}
	if got := stringFromAny(joinBody["llm_capability_token"]); got != "cap-secret" {
		t.Fatalf("llm_capability_token = %q, want the passed-through token", got)
	}
}
