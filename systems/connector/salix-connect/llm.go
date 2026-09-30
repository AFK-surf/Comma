package main

import (
	"encoding/base64"
	"io"
	"net/http"
)

func (c *connector) handleLLMChat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	token := bearerToken(r.Header.Get("Authorization"))
	if token == "" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxFile+1))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	if len(body) > maxFile {
		http.Error(w, "request body exceeds 10MB cap", http.StatusRequestEntityTooLarge)
		return
	}

	result, err := c.sendRuntimeProxy(r.Context(), map[string]any{
		"capability_token": token,
		"method":           http.MethodPost,
		"route_path":       "/llm/chat",
		"body_base64":      base64.StdEncoding.EncodeToString(body),
	})
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	writeRuntimeBridgeResult(w, result)
}
