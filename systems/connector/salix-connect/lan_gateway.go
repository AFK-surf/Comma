package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"net"
	"net/http"
	"time"
)

// A LAN gateway sends HTTP requests and UDP datagrams (device.lan_request)
// and relays TCP connections (ssh.open with device_id) from this computer's
// network. The
// gateway does not restrict destinations: it reaches what this computer
// reaches.
const (
	lanGatewayMaxBytes = 64 * 1024
	// A response_mode "chunks" body: up to 4 MiB, sent as response_chunk
	// frames before the final response.
	lanGatewayChunkedMaxBytes   = 4 * 1024 * 1024
	lanGatewayChunkBytes        = 32 * 1024
	lanGatewayMaxTimeoutSeconds = 30
	lanGatewayDefaultTimeout    = 10 * time.Second
)

func lanGatewayCapability() map[string]any {
	return map[string]any{
		"methods":             []string{"lan_http_request", "lan_tcp_dial", "udp_request"},
		"max_bytes":           lanGatewayMaxBytes,
		"max_timeout_seconds": lanGatewayMaxTimeoutSeconds,
		"response_chunks": map[string]any{
			"max_total_bytes": lanGatewayChunkedMaxBytes,
			"chunk_bytes":     lanGatewayChunkBytes,
		},
	}
}

func (c *connector) methodLANHTTPRequest(ctx context.Context, params map[string]any) (map[string]any, error) {
	limits := lanHTTPLimits(lanGatewayMaxBytes)
	defer limits.client.CloseIdleConnections()
	return performHTTPRequest(ctx, params, limits)
}

// methodLANHTTPRequestChunks returns the body as response_chunk frames
// {"id","type":"response_chunk","seq","data_b64"} sent before the final
// response, which carries body_encoding "chunks", the frame count, the byte
// count and the body's sha256. The body may be binary.
func (c *connector) methodLANHTTPRequestChunks(ctx context.Context, session *connectionSession, id string, params map[string]any) (map[string]any, error) {
	if session == nil {
		return nil, errors.New("response_mode chunks requires a connector socket")
	}
	limit := intParam(params, "max_bytes", lanGatewayChunkedMaxBytes)
	if limit <= 0 || limit > lanGatewayChunkedMaxBytes {
		limit = lanGatewayChunkedMaxBytes
	}
	request := make(map[string]any, len(params))
	for key, value := range params {
		request[key] = value
	}
	request["max_bytes"] = limit
	limits := lanHTTPLimits(int64(limit))
	defer limits.client.CloseIdleConnections()
	result, raw, err := performHTTPRequestBytes(ctx, request, limits)
	if err != nil {
		return nil, err
	}
	frames := 0
	for start := 0; start < len(raw); start += lanGatewayChunkBytes {
		end := min(start+lanGatewayChunkBytes, len(raw))
		seq := frames
		chunk := message{ID: id, Type: "response_chunk", Seq: &seq, DataB64: base64.StdEncoding.EncodeToString(raw[start:end])}
		if err := session.send(chunk); err != nil {
			return nil, err
		}
		frames++
	}
	sum := sha256.Sum256(raw)
	result["body_encoding"] = "chunks"
	result["chunks"] = frames
	result["sha256"] = hex.EncodeToString(sum[:])
	return result, nil
}

func lanHTTPLimits(maxBytes int64) httpRequestLimits {
	transport := &http.Transport{
		DialContext:         (&net.Dialer{Timeout: lanGatewayMaxTimeoutSeconds * time.Second}).DialContext,
		Proxy:               nil,
		TLSHandshakeTimeout: 10 * time.Second,
	}
	return httpRequestLimits{
		defaultTimeout: lanGatewayDefaultTimeout,
		maxTimeout:     lanGatewayMaxTimeoutSeconds * time.Second,
		maxBytes:       maxBytes,
		client: &http.Client{
			Transport: transport,
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				return http.ErrUseLastResponse
			},
		},
	}
}
