package accountproxy

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	logrus "github.com/sirupsen/logrus"
)

type observationHook struct {
	events chan *logrus.Entry
	fail   bool
}

func (h *observationHook) Levels() []logrus.Level { return logrus.AllLevels }
func (h *observationHook) Fire(e *logrus.Entry) error {
	if h.fail {
		panic("PRIVATE_LOG_FAILURE")
	}
	if strings.HasPrefix(e.Message, "subscription_") {
		copy := e.Dup()
		copy.Message = e.Message
		h.events <- copy
	}
	return nil
}
func captureObservations(t *testing.T, fail bool) *observationHook {
	t.Helper()
	h := &observationHook{events: make(chan *logrus.Entry, 32), fail: fail}
	logger := logrus.StandardLogger()
	old := logger.ReplaceHooks(logrus.LevelHooks{})
	level := logger.GetLevel()
	logger.SetLevel(logrus.InfoLevel)
	logger.AddHook(h)
	t.Cleanup(func() { logger.ReplaceHooks(old); logger.SetLevel(level) })
	return h
}
func nextObservation(t *testing.T, h *observationHook) *logrus.Entry {
	t.Helper()
	select {
	case e := <-h.events:
		return e
	case <-time.After(3 * time.Second):
		t.Fatal("missing subscription observation")
		return nil
	}
}
func TestNativeBlockingCallReportsUpstreamBeforeHostData(t *testing.T) {
	h := captureObservations(t, false)
	release := make(chan struct{})
	defer close(release)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fmt.Fprint(w, ": upstream-started\n\n")
		fmt.Fprint(w, `data: {"type":"response.reasoning_summary_text.delta","delta":"PRIVATE_REASONING"}`+"\n\n")
		fmt.Fprint(w, "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"r\",\"object\":\"response\",\"status\":\"completed\",\"output\":[]}}\n\n")
		w.(http.Flusher).Flush()
		select {
		case <-release:
		case <-r.Context().Done():
			return
		}

	}))
	defer server.Close()
	u, _ := url.Parse(server.URL)
	parent, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ctx, finish := observeCall(context.WithValue(parent, "cliproxy.roundtripper", &rewriteTransport{url: u, handler: http.DefaultTransport}), command{ID: "call-42", Op: "/v1/responses", Body: json.RawMessage(`{"input":"PRIVATE_PROMPT"}`)})
	data := make(chan []byte, 1)
	done := make(chan error, 1)
	go func() {
		err := execute(ctx, "/v1/responses", json.RawMessage(`{"model":"gpt-5.5","input":"PRIVATE_PROMPT"}`), Credential{Provider: "codex", Credentials: map[string]any{"access_token": "PRIVATE_TOKEN", "account_id": "PRIVATE_ACCOUNT"}}, func(b []byte) error { data <- b; return nil })
		finish(event{Type: "done"})
		done <- err
	}()
	for _, name := range []string{"subscription_sdk_call_start", "subscription_upstream_request_written", "subscription_upstream_first_byte", "subscription_upstream_headers", "subscription_upstream_first_body", "subscription_upstream_first_event", "subscription_upstream_first_reasoning", "subscription_upstream_terminal", "subscription_upstream_response_metadata"} {
		e := nextObservation(t, h)
		if e.Message != name || e.Data["worker_request_id"] != "call-42" {
			t.Fatalf("unexpected event: %v", e)
		}
		encoded, _ := json.Marshal(e.Data)
		if strings.Contains(string(encoded), "PRIVATE_") {
			t.Fatal("payload leaked")
		}
	}
	select {
	case <-data:
		t.Fatal("blocking executor emitted before completion")
	default:
	}
	release <- struct{}{}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if len(<-data) == 0 {
		t.Fatal("empty result")
	}
	e := nextObservation(t, h)
	if e.Message != "subscription_upstream_body_end" || e.Data["reason"] != "eof" || e.Data["terminal_seen"] != true {
		t.Fatal(e)
	}
	e = nextObservation(t, h)
	if e.Message != "subscription_sdk_call_finish" || e.Data["outcome"] != "ok" {
		t.Fatal(e)
	}
}
func TestObservationFailurePreservesWorkerResult(t *testing.T) {
	captureObservations(t, true)
	c := wire(t, func(context.Context, string, json.RawMessage, Credential, emitter) error { return nil })
	c.send(t, "call-43", "call", "/normalize")
	if result := c.next(t); result.Type != "done" {
		t.Fatal(result)
	}
}
func TestObservationRejectsUntrustedOperationAndErrorText(t *testing.T) {
	h := captureObservations(t, false)
	_, finish := observeCall(context.Background(), command{ID: "PRIVATE_TOKEN?", Op: "PRIVATE_URL", Body: json.RawMessage(`{"secret":"PRIVATE_BODY"}`)})
	finish(event{Type: "error", Status: 429, Code: "PRIVATE_ERROR", Data: []byte("PRIVATE_RESPONSE")})
	for i := 0; i < 2; i++ {
		e := nextObservation(t, h)
		b, _ := json.Marshal(e.Data)
		if strings.Contains(string(b), "PRIVATE_") {
			t.Fatal("private data leaked")
		}
		if e.Data["worker_request_id"] != "invalid" || e.Data["operation"] != "unknown" {
			t.Fatal(e)
		}
	}
}

func TestBodyObservationBoundsAndPreservesPrivateBytes(t *testing.T) {
	h := captureObservations(t, false)
	payload := "data: " + strings.Repeat("PRIVATE_BODY", 10000) + "\n\ndata: {\"type\":\"PRIVATE_EVENT\"}\n\n"
	b := &observedBody{ReadCloser: io.NopCloser(strings.NewReader(payload)), fields: logrus.Fields{"worker_request_id": "bounded"}, started: time.Now(), lastProgress: time.Now(), sse: true}
	got, err := io.ReadAll(b)
	if err != nil || string(got) != payload {
		t.Fatal("observation changed body")
	}
	if b.oversized != 1 || cap(b.line) > 100000 {
		t.Fatalf("unbounded observer: %d", cap(b.line))
	}
	for len(h.events) > 0 {
		e := nextObservation(t, h)
		data, _ := json.Marshal(e.Data)
		if strings.Contains(string(data), "PRIVATE_") {
			t.Fatal("private content logged")
		}
	}
}

func TestBodyObservationLoggingFailurePreservesBytes(t *testing.T) {
	captureObservations(t, true)
	payload := "data: {\"type\":\"response.completed\"}\n\n"
	b := &observedBody{ReadCloser: io.NopCloser(strings.NewReader(payload)), fields: logrus.Fields{}, started: time.Now(), lastProgress: time.Now(), sse: true}
	got, err := io.ReadAll(b)
	if err != nil || string(got) != payload {
		t.Fatal("logging failure changed result")
	}
}

func TestLargeCompletionIsVisibleBeforeEOF(t *testing.T) {
	h := captureObservations(t, false)
	payload := "data: {\"type\":\"response.completed\",\"response\":{\"text\":\"" + strings.Repeat("PRIVATE_OUTPUT", 10000) + "\"}}\n\n"
	b := &observedBody{ReadCloser: io.NopCloser(strings.NewReader(payload)), fields: logrus.Fields{}, started: time.Now(), lastProgress: time.Now(), sse: true}
	got := make([]byte, len(payload))
	n, err := io.ReadFull(b, got)
	if err != nil || n != len(payload) || string(got) != payload || !b.terminal || b.ended {
		t.Fatal("large terminal not observed before EOF")
	}
	for len(h.events) > 0 {
		e := nextObservation(t, h)
		data, _ := json.Marshal(e.Data)
		if strings.Contains(string(data), "PRIVATE_") {
			t.Fatal("content leaked")
		}
		if e.Message == "subscription_upstream_response_metadata" && e.Data["response_metadata_complete"] != false {
			t.Fatal("oversized metadata was treated as complete")
		}
	}
}

func TestContentProgressAndUsagePreserveBodyAndExcludeContent(t *testing.T) {
	h := captureObservations(t, false)
	payload := `data: {"type":"response.reasoning_summary_text.delta","delta":"PRIVATE_REASONING"}

data: {"type":"response.function_call_arguments.delta","delta":"PRIVATE_TOOL"}

data: {"type":"response.output_text.delta","delta":"PRIVATE_TEXT"}

data: {"type":"response.completed","response":{"usage":{"input_tokens":100,"output_tokens":40,"input_tokens_details":{"cached_tokens":0},"output_tokens_details":{"reasoning_tokens":30}},"output":[{"type":"reasoning","encrypted_content":"PRIVATE_CIPHER"}]}}

`
	b := &observedBody{ReadCloser: io.NopCloser(strings.NewReader(payload)), fields: logrus.Fields{}, started: time.Now(), lastProgress: time.Now(), sse: true}
	got, err := io.ReadAll(b)
	if err != nil || string(got) != payload {
		t.Fatal("changed body")
	}
	seen := map[string]bool{}
	for len(h.events) > 0 {
		e := nextObservation(t, h)
		seen[e.Message] = true
		encoded, _ := json.Marshal(e.Data)
		if strings.Contains(string(encoded), "PRIVATE_") {
			t.Fatal("content leaked")
		}
		if e.Message == "subscription_upstream_response_metadata" {
			if e.Data["reasoning_tokens"] != int64(30) || e.Data["cached_tokens_reported"] != true || e.Data["cached_tokens"] != int64(0) || e.Data["encrypted_reasoning_items"] != 1 {
				t.Fatal(e)
			}
		}
	}
	for _, name := range []string{"subscription_upstream_first_reasoning", "subscription_upstream_first_text", "subscription_upstream_first_tool_arguments", "subscription_upstream_response_metadata"} {
		if !seen[name] {
			t.Fatal("missing", name)
		}
	}
}

func TestProviderFailuresRemainDistinguishableWithoutPrivateBodies(t *testing.T) {
	for _, tc := range []struct {
		name, contentType, body, class string
		status                         int
	}{
		{"terminal_failure", "application/octet-stream", `data: {"type":"response.failed","response":{"error":{"code":"server_error","message":"PRIVATE_RESPONSE"}}}` + "\n\n", "server_error", 502},
		{"unknown_failure", "PRIVATE_HEADER", `data: {"type":"response.failed","response":{"error":{"code":"PRIVATE_ERROR_CODE","type":"PRIVATE_ERROR_TYPE","message":"PRIVATE_RESPONSE"}}}` + "\n\n", "unclassified", 502},
		{"empty_incomplete", "text/event-stream", `data: {"type":"response.incomplete","response":{"status":"incomplete","output":[],"usage":{"input_tokens":0,"output_tokens":0}}}` + "\n\n", "empty_incomplete_response", 502},
		{"missing_terminal", "text/html; PRIVATE_HEADER", "PRIVATE_RESPONSE", "stream_missing_terminal", 408},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := captureObservations(t, false)
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", tc.contentType)
				fmt.Fprint(w, tc.body)
			}))
			defer server.Close()
			u, _ := url.Parse(server.URL)
			ctx, _ := observeCall(context.WithValue(context.Background(), "cliproxy.roundtripper", &rewriteTransport{url: u, handler: http.DefaultTransport}), command{ID: "diagnostic", Op: "/v1/responses"})
			err := execute(ctx, "/v1/responses", json.RawMessage(`{"model":"gpt-5.5","input":"PRIVATE_PROMPT"}`), Credential{Provider: "codex", Credentials: map[string]any{"access_token": "PRIVATE_TOKEN"}}, func([]byte) error { t.Fatal("failed request emitted output"); return nil })
			oe, ok := err.(*operationError)
			if !ok || oe.status != tc.status || oe.code != "subscription_request_failed" {
				t.Fatalf("unexpected public result: %v", err)
			}
			found := false
			for len(h.events) > 0 {
				e := <-h.events
				encoded, _ := json.Marshal(e.Data)
				if strings.Contains(string(encoded), "PRIVATE_") {
					t.Fatal("private data escaped")
				}
				if e.Message == "subscription_sdk_failure" {
					found = true
					if e.Data["failure_class"] != tc.class {
						t.Fatalf("wrong failure class: %v", e.Data)
					}
				}
				if e.Message == "subscription_upstream_headers" && e.Data["response_content_type"] == nil {
					t.Fatal("missing normalized content type")
				}
			}
			if !found {
				t.Fatal("missing SDK failure classification")
			}
		})
	}
}
