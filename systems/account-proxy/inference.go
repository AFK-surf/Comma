package accountproxy

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/auth"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/cliproxy/executor"
	"github.com/router-for-me/CLIProxyAPI/v8/sdk/translator"
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
	provider, format := "codex", "openai-response"
	if op == "/v1/messages" {
		provider, format = "claude", "claude"
	}
	if c.Provider != provider {
		return &operationError{400, "provider_mismatch"}
	}
	e, err := cliproxy.NewSubscriptionExecutor(provider)
	if err != nil {
		return &operationError{400, "invalid_provider"}
	}
	a := &auth.Auth{Provider: provider, Metadata: c.Credentials}
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
					return nil
				}
				if chunk.Err != nil {
					return chunk.Err
				}
				wrote = true
				payload := chunk.Payload
				// Native Codex translation returns complete SSE data lines without
				// HTTP event delimiters. The host, as in the upstream handler,
				// must frame each event before forwarding it to an SSE client.
				if provider == "codex" && len(bytes.TrimSpace(payload)) > 0 {
					payload = append(bytes.TrimRight(payload, "\r\n"), '\n', '\n')
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
