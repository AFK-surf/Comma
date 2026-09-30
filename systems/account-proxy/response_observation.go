package accountproxy

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"

	logrus "github.com/sirupsen/logrus"
	"github.com/tidwall/gjson"
)

// Observe reads at the HTTP boundary, including bytes buffered by the SDK.
// Never retain more than one bounded line or emit provider-controlled strings.
type observedTransport struct {
	base    http.RoundTripper
	fields  logrus.Fields
	started time.Time
}

func (t *observedTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	resp, err := t.base.RoundTrip(req)
	if err != nil {
		return resp, err
	}
	f := withElapsed(t.fields, "elapsed_ms", t.started)
	f["http_status"] = resp.StatusCode
	f["response_content_type"] = responseContentType(resp.Header.Get("Content-Type"))
	logObservation("subscription_upstream_headers", f)
	resp.Body = &observedBody{ctx: req.Context(), ReadCloser: resp.Body, fields: t.fields, started: t.started, lastProgress: time.Now(), sse: strings.HasPrefix(strings.ToLower(resp.Header.Get("Content-Type")), "text/event-stream")}
	return resp, nil
}

type observedBody struct {
	io.ReadCloser
	mu                                         sync.Mutex
	ctx                                        context.Context
	fields                                     logrus.Fields
	started, lastProgress                      time.Time
	sse, dropping, firstEvent, terminal, ended bool
	line                                       []byte
	bytes, events, oversized                   int64
	lastEvent                                  string
	firstReasoning, firstText, firstTool       bool
}

func (b *observedBody) report(name, reason string) {
	f := withElapsed(b.fields, "elapsed_ms", b.started)
	f["upstream_body_bytes"] = b.bytes
	f["sse_events"] = b.events
	f["oversized_lines"] = b.oversized
	f["last_event_type"] = b.lastEvent
	f["terminal_seen"] = b.terminal
	f["reason"] = reason
	logObservation(name, f)
}
func (b *observedBody) Read(p []byte) (int, error) {
	n, err := b.ReadCloser.Read(p)
	b.mu.Lock()
	defer b.mu.Unlock()
	firstBody := b.bytes == 0 && n > 0
	b.bytes += int64(n)
	if firstBody {
		b.report("subscription_upstream_first_body", "read")
	}
	if b.sse {
		for _, c := range p[:n] {
			if c == '\n' {
				if !b.dropping {
					b.observeLine()
				}
				b.line = b.line[:0]
				b.dropping = false
			} else if !b.dropping {
				if len(b.line) < 64*1024 {
					b.line = append(b.line, c)
				} else {
					b.dropping = true
					b.oversized++
					b.observeLine()
				}
			}
		}
	}
	if n > 0 && time.Since(b.lastProgress) >= 15*time.Second {
		b.report("subscription_upstream_progress", "read")
		b.lastProgress = time.Now()
	}
	if err != nil && !b.ended {
		b.ended = true
		reason := "read_error"
		if err == io.EOF {
			reason = "eof"
		} else if b.ctx != nil && b.ctx.Err() == context.Canceled {
			reason = "cancelled"
		} else if b.ctx != nil && b.ctx.Err() == context.DeadlineExceeded {
			reason = "deadline"
		}
		b.report("subscription_upstream_body_end", reason)
	}
	return n, err
}
func (b *observedBody) Close() error {
	err := b.ReadCloser.Close()
	b.mu.Lock()
	defer b.mu.Unlock()
	if !b.ended {
		b.ended = true
		b.report("subscription_upstream_body_end", "closed")
	}
	b.line = nil
	return err
}
func (b *observedBody) observeLine() {
	line := bytes.TrimSpace(b.line)
	if !bytes.HasPrefix(line, []byte("data:")) {
		return
	}
	data := bytes.TrimSpace(line[5:])
	// GJSON can read the top-level type from a bounded prefix before a large payload.
	eventType := gjson.GetBytes(data, "type").String()
	kind := "other"
	switch eventType {
	case "response.created", "response.in_progress", "response.output_text.delta", "response.reasoning_summary_text.delta", "response.reasoning_text.delta", "response.function_call_arguments.delta", "response.output_item.done", "response.completed", "response.incomplete", "response.failed", "error", "message_start", "content_block_delta", "message_stop":
		kind = eventType
	}
	if bytes.Equal(data, []byte("[DONE]")) {
		kind = "done"
	}
	b.events++
	b.lastEvent = kind
	if !b.firstEvent {
		b.firstEvent = true
		b.report("subscription_upstream_first_event", "event")
	}
	var first *bool
	var name string
	switch kind {
	case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
		first, name = &b.firstReasoning, "subscription_upstream_first_reasoning"
	case "response.output_text.delta":
		first, name = &b.firstText, "subscription_upstream_first_text"
	case "response.function_call_arguments.delta":
		first, name = &b.firstTool, "subscription_upstream_first_tool_arguments"
	}
	if first != nil && !*first && gjson.GetBytes(data, "delta").String() != "" {
		*first = true
		b.report(name, "event")
	}
	switch kind {
	case "response.completed", "response.incomplete", "response.failed", "error", "message_stop", "done":
		if !b.terminal {
			b.terminal = true
			b.report("subscription_upstream_terminal", "event")
			if kind == "response.completed" || kind == "response.incomplete" {
				b.reportResponse(data)
			}
		}
	}
}

// Incomplete bounded prefixes cannot establish missing usage or encrypted output.
func (b *observedBody) reportResponse(data []byte) {
	f := withElapsed(b.fields, "elapsed_ms", b.started)
	complete := !b.dropping && gjson.ValidBytes(data)
	f["response_metadata_complete"] = complete
	if complete {
		response := gjson.GetBytes(data, "response")
		usage := response.Get("usage")
		f["usage_reported"] = usage.IsObject()
		for _, field := range []struct{ name, path string }{
			{"input_tokens", "input_tokens"},
			{"output_tokens", "output_tokens"},
			{"cached_tokens", "input_tokens_details.cached_tokens"},
			{"reasoning_tokens", "output_tokens_details.reasoning_tokens"},
		} {
			value := usage.Get(field.path)
			reported := value.Type == gjson.Number && value.Int() >= 0
			f[field.name+"_reported"] = reported
			if reported {
				f[field.name] = value.Int()
			}
		}
		count, size := 0, 0
		response.Get("output").ForEach(func(_, item gjson.Result) bool {
			if item.Get("type").String() == "reasoning" {
				value := item.Get("encrypted_content")
				if value.Type == gjson.String && value.String() != "" {
					count++
					size += len(value.String())
				}
			}
			return true
		})
		f["encrypted_reasoning_items"] = count
		f["encrypted_reasoning_bytes"] = size
	}
	logObservation("subscription_upstream_response_metadata", f)
}

func responseContentType(value string) string {
	mediaType := strings.ToLower(strings.TrimSpace(strings.SplitN(value, ";", 2)[0]))
	switch mediaType {
	case "text/event-stream", "application/json", "text/html", "text/plain", "application/octet-stream":
		return mediaType
	case "":
		return "missing"
	default:
		return "other"
	}
}
