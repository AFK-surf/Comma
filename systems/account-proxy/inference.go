package accountproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/translator"
	"slices"
	"strings"
)

func inference(ctx context.Context, c Credential, op string, payload json.RawMessage, emit emitter) error {
	var in struct {
		Model  string `json:"model"`
		Stream bool   `json:"stream"`
	}
	if json.Unmarshal(payload, &in) != nil || in.Model == "" {
		return &operationError{400, "model_required"}
	}
	provider := c.Provider
	if !slices.Contains(inferenceProviders[op], provider) {
		return &operationError{400, "provider_mismatch"}
	}
	format := map[string]string{"/v1/messages": "claude", "/v1/chat/completions": "openai"}[op]
	if format == "" {
		format = "openai-response"
	}
	e, err := newExecutor(provider)
	if err != nil {
		return &operationError{400, "invalid_provider"}
	}
	a := newAuth(provider, c.Credentials)
	req := executor.Request{Model: in.Model, Payload: payload}
	if provider == "codex" {
		req = auth.SubscriptionModelRequest(req)
	}
	opts := executor.Options{SourceFormat: translator.FromString(format), Stream: in.Stream, OriginalRequest: payload}
	if op == "/v1/images/generations" || op == "/v1/images/edits" {
		opts.SourceFormat = translator.FromString("openai-image")
		opts.Metadata = map[string]any{executor.RequestPathMetadataKey: op}
	}
	if op == "/v1/responses/compact" {
		if in.Stream {
			return &operationError{400, "compact_stream_unsupported"}
		}
		opts.Alt = "responses/compact"
	}
	wrote := false
	err = func() error {
		if !in.Stream {
			resp, err := e.Execute(ctx, a, req, opts)
			if err != nil {
				return err
			}
			wrote = true
			err = emit(resp.Payload)
			return err
		}
		resp, err := e.ExecuteStream(ctx, a, req, opts)
		if err != nil {
			return err
		}
		for {
			select {
			case <-ctx.Done():
				return ctx.Err()
			case chunk, ok := <-resp.Chunks:
				if !ok {
					if format == "openai" {
						wrote = true
						return emit([]byte("data: [DONE]\n\n"))
					}
					return nil
				}
				if chunk.Err != nil {
					return chunk.Err
				}
				wrote = true
				payload := chunk.Payload
				// Native Responses translation (Codex and xAI) returns complete SSE
				// data lines without HTTP event delimiters. The host, as in the
				// upstream handler, must frame each event before forwarding it.
				if format == "openai-response" && len(bytes.TrimSpace(payload)) > 0 {
					payload = append(bytes.TrimRight(payload, "\r\n"), '\n', '\n')
				}
				// Chat Completions chunks are bare JSON objects. The upstream
				// handler adds the SSE data prefix and the final [DONE] event.
				if format == "openai" {
					if payload = chatEvent(payload); payload == nil {
						continue
					}
				}
				if err = emit(payload); err != nil {
					return err
				}
			}
		}
	}()
	if err != nil && errors.Is(ctx.Err(), context.DeadlineExceeded) && !wrote {
		return &operationError{504, "account_proxy_timeout"}
	}
	if err != nil && ctx.Err() == nil {
		if !wrote {
			status := 503
			var upstream interface{ StatusCode() int }
			if errors.As(err, &upstream) && upstream.StatusCode() >= 400 && upstream.StatusCode() <= 599 {
				status = upstream.StatusCode()
			}
			observeSDKFailure(ctx, err, status)
			code := "subscription_request_failed"
			detail := strings.ToLower(err.Error())
			for _, marker := range []string{"context_length_exceeded", "context_window_exceeded", "prompt is too long", "maximum context length"} {
				if strings.Contains(detail, marker) {
					code = "context_length_exceeded"
					break
				}
			}
			return &operationError{status, code}
		} else if in.Stream {
			return &operationError{503, "upstream_stream_failed"}
		}
	}
	return err
}

// chatEvent frames one translated chunk as an SSE event. It drops empty
// chunks and a translated [DONE], which the stream end emits once.
func chatEvent(chunk []byte) []byte {
	data := bytes.TrimSpace(chunk)
	if rest, ok := bytes.CutPrefix(data, []byte("data:")); ok {
		data = bytes.TrimSpace(rest)
	}
	if len(data) == 0 || bytes.Equal(data, []byte("[DONE]")) {
		return nil
	}
	return append(append([]byte("data: "), data...), '\n', '\n')
}
