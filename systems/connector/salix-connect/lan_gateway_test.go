package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestLANHTTPRequestReachesAnyDestination(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(`{"on":true}`))
	}))
	defer server.Close()

	// httptest listens on loopback; the gateway no longer refuses any address.
	result, err := (&connector{}).methodLANHTTPRequest(context.Background(), map[string]any{"method": "GET", "url": server.URL})
	if err != nil {
		t.Fatal(err)
	}
	if result["status"] != 200 || result["body"] != `{"on":true}` {
		t.Fatalf("result = %v", result)
	}
}

func TestLANHTTPRequestCapsResponseBytes(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte(strings.Repeat("x", lanGatewayMaxBytes+10)))
	}))
	defer server.Close()

	result, err := (&connector{}).methodLANHTTPRequest(context.Background(), map[string]any{"method": "GET", "url": server.URL, "max_bytes": 10 * lanGatewayMaxBytes})
	if err != nil {
		t.Fatal(err)
	}
	if result["truncated"] != true || len(result["body"].(string)) != lanGatewayMaxBytes {
		t.Fatalf("result = truncated %v, %d bytes", result["truncated"], len(result["body"].(string)))
	}
}

func TestLANGatewayCapabilityAdvertisesLimits(t *testing.T) {
	capability := lanGatewayCapability()
	if methods := capability["methods"].([]string); len(methods) != 3 || methods[0] != "lan_http_request" || methods[1] != "lan_tcp_dial" || methods[2] != "udp_request" {
		t.Fatalf("methods = %v", methods)
	}
	if capability["max_bytes"] != 65536 || capability["max_timeout_seconds"] != 30 {
		t.Fatalf("limits = %v", capability)
	}
	chunks := capability["response_chunks"].(map[string]any)
	if chunks["max_total_bytes"] != 4*1024*1024 || chunks["chunk_bytes"] != 32*1024 {
		t.Fatalf("response_chunks = %v", chunks)
	}
}

func TestLANHTTPRequestChunksSendsBinaryBodyBeforeTheResult(t *testing.T) {
	body := make([]byte, 3*lanGatewayChunkBytes+17)
	if _, err := rand.Read(body); err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		w.Write(body)
	}))
	defer server.Close()

	var frames []message
	c := &connector{}
	session := newConnectionSession(c, context.Background(), func(_ context.Context, m message) error {
		frames = append(frames, m)
		return nil
	}, nil)
	defer session.close(context.Canceled)

	result, err := c.methodLANHTTPRequestChunks(context.Background(), session, "r1", map[string]any{"method": "GET", "url": server.URL, "response_mode": "chunks"})
	if err != nil {
		t.Fatal(err)
	}
	var got []byte
	for i, frame := range frames {
		if frame.ID != "r1" || frame.Type != "response_chunk" || frame.Seq == nil || *frame.Seq != i {
			t.Fatalf("frame %d = %+v", i, frame)
		}
		part, err := base64.StdEncoding.DecodeString(frame.DataB64)
		if err != nil {
			t.Fatal(err)
		}
		got = append(got, part...)
	}
	sum := sha256.Sum256(body)
	if !bytes.Equal(got, body) || len(frames) != 4 || result["chunks"] != 4 || result["body_bytes"] != len(body) ||
		result["body_encoding"] != "chunks" || result["sha256"] != hex.EncodeToString(sum[:]) || result["truncated"] != false {
		t.Fatalf("frames %d, result %v", len(frames), result)
	}
	if _, ok := result["body"]; ok {
		t.Fatalf("result carries the body: %v", result)
	}
}
