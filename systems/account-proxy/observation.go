package accountproxy

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptrace"
	"strings"
	"sync"
	"time"

	logrus "github.com/sirupsen/logrus"
	"github.com/tidwall/gjson"
)

type observationFieldsKey struct{}

// These events describe HTTP progress, not model tokens or host data frames.
func observeCall(ctx context.Context, cmd command) (context.Context, func(event)) {
	started := time.Now()
	operation := "unknown"
	switch cmd.Op {
	case "/subscription/seal", "/normalize", "/prepare", "/quota", "/quota/reset", "/oauth/begin", "/oauth/device/begin", "/oauth/device/poll", "/oauth/exchange", "/v1/responses", "/v1/responses/compact", "/v1/messages", "/v1/images/generations", "/v1/images/edits":
		operation = cmd.Op
	}
	var body struct {
		Stream    bool   `json:"stream"`
		Model     string `json:"model"`
		Reasoning struct {
			Effort string `json:"effort"`
		} `json:"reasoning"`
		MaxOutputTokens int    `json:"max_output_tokens"`
		PromptCacheKey  string `json:"prompt_cache_key"`
	}
	_ = json.Unmarshal(cmd.Body, &body)
	fields := logrus.Fields{"worker_request_id": logRequestID(cmd.ID), "operation": operation, "stream": body.Stream}
	fields["request_body_bytes"] = len(cmd.Body)
	fields["prompt_cache_key_present"] = body.PromptCacheKey != ""
	if strings.HasPrefix(body.Model, "gpt-") || strings.HasPrefix(body.Model, "claude-") {
		if name := logRequestID(strings.ReplaceAll(body.Model, ".", "-")); name != "invalid" {
			fields["model"] = body.Model
		}
	}
	switch body.Reasoning.Effort {
	case "none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra":
		fields["reasoning_effort"] = body.Reasoning.Effort
	default:
		fields["reasoning_effort"] = "unspecified_or_other"
	}
	if body.MaxOutputTokens > 0 {
		fields["max_output_tokens"] = body.MaxOutputTokens
	}
	logObservation("subscription_sdk_call_start", fields)
	ctx = context.WithValue(ctx, observationFieldsKey{}, fields)
	ctx = context.WithValue(ctx, "salix.observe_transport", func(rt http.RoundTripper) http.RoundTripper {
		return &observedTransport{base: rt, fields: fields, started: started}
	})
	var written, first sync.Once
	ctx = httptrace.WithClientTrace(ctx, &httptrace.ClientTrace{
		WroteRequest: func(info httptrace.WroteRequestInfo) {
			if info.Err == nil {
				written.Do(func() {
					logObservation("subscription_upstream_request_written", withElapsed(fields, "upstream_request_ms", started))
				})
			}
		},
		GotFirstResponseByte: func() {
			first.Do(func() {
				logObservation("subscription_upstream_first_byte", withElapsed(fields, "upstream_first_byte_ms", started))
			})
		},
	})
	return ctx, func(result event) {
		end := withElapsed(fields, "sdk_duration_ms", started)
		end["outcome"] = "ok"
		if result.Type == "error" {
			end["outcome"] = "error"
			end["http_status"] = result.Status
		}
		logObservation("subscription_sdk_call_finish", end)
	}
}

func withElapsed(fields logrus.Fields, name string, started time.Time) logrus.Fields {
	copy := make(logrus.Fields, len(fields)+2)
	for key, value := range fields {
		copy[key] = value
	}
	copy[name] = time.Since(started).Milliseconds()
	return copy
}

func logRequestID(id string) string {
	if len(id) > 128 {
		return "invalid"
	}
	for _, ch := range id {
		if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '_' || ch == '-' || ch == ':') {
			return "invalid"
		}
	}
	return id
}

func logObservation(event string, fields logrus.Fields) {
	// A logging hook must not turn a successful provider call into a failure.
	defer func() { _ = recover() }()
	logrus.WithFields(fields).Info(event)
}

// SDK errors can contain entire provider responses. Only these closed classes
// enter logs; the original error and public response contract stay unchanged.
func observeSDKFailure(ctx context.Context, err error, status int) {
	fields, ok := ctx.Value(observationFieldsKey{}).(logrus.Fields)
	if !ok {
		return
	}
	f := make(logrus.Fields, len(fields)+2)
	for key, value := range fields {
		f[key] = value
	}
	f["http_status"] = status
	f["failure_class"] = sdkFailureClass(err)
	logObservation("subscription_sdk_failure", f)
}

func sdkFailureClass(err error) string {
	detail := err.Error()
	switch detail {
	case "stream error: stream disconnected before completion: stream closed before response.completed":
		return "stream_missing_terminal"
	case "stream error: upstream terminated with incomplete empty response (0 tokens)":
		return "empty_incomplete_response"
	}
	// Check only structured fields, never arbitrary message substrings.
	for _, path := range []string{"error.code", "error.type"} {
		switch value := gjson.Get(detail, path).String(); value {
		case "server_error", "rate_limit_exceeded", "rate_limit_error", "usage_limit_reached", "auth_unavailable", "authentication_error", "invalid_request_error", "context_too_large", "context_length_exceeded", "thinking_signature_invalid", "previous_response_not_found", "service_unavailable_error", "server_is_overloaded":
			return value
		}
	}
	return "unclassified"
}
