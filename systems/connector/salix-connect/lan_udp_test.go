package main

import (
	"context"
	"encoding/base64"
	"net"
	"strconv"
	"testing"
)

// udpEcho answers every datagram with each of replies, prefixed by the
// request bytes.
func udpEcho(t *testing.T, replies ...string) int {
	t.Helper()
	conn, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.Close() })
	go func() {
		buf := make([]byte, 2048)
		for {
			n, from, err := conn.ReadFromUDP(buf)
			if err != nil {
				return
			}
			for _, reply := range replies {
				conn.WriteToUDP(append(append([]byte{}, buf[:n]...), reply...), from)
			}
		}
	}()
	return conn.LocalAddr().(*net.UDPAddr).Port
}

func udpParams(port int, extra map[string]any) map[string]any {
	params := map[string]any{
		"host":        "127.0.0.1",
		"port":        float64(port),
		"payload_b64": base64.StdEncoding.EncodeToString([]byte("hello")),
		"timeout_ms":  float64(500),
	}
	for key, value := range extra {
		params[key] = value
	}
	return params
}

func TestUDPRequestStopsAtMaxResponses(t *testing.T) {
	port := udpEcho(t, "-a", "-b", "-c")
	result, err := (&connector{}).methodUDPRequest(context.Background(), udpParams(port, map[string]any{"max_responses": float64(2)}))
	if err != nil {
		t.Fatal(err)
	}
	responses := result["responses"].([]map[string]any)
	if result["timed_out"] != false || len(responses) != 2 {
		t.Fatalf("result = %v", result)
	}
	payload, _ := base64.StdEncoding.DecodeString(responses[0]["payload_b64"].(string))
	if string(payload) != "hello-a" || responses[0]["from"] != net.JoinHostPort("127.0.0.1", strconv.Itoa(port)) {
		t.Fatalf("first response = %v (%q)", responses[0], payload)
	}
}

func TestUDPRequestCollectsUntilTimeout(t *testing.T) {
	port := udpEcho(t, "-a")
	result, err := (&connector{}).methodUDPRequest(context.Background(), udpParams(port, map[string]any{"timeout_ms": float64(200)}))
	if err != nil {
		t.Fatal(err)
	}
	if result["timed_out"] != true || len(result["responses"].([]map[string]any)) != 1 {
		t.Fatalf("result = %v", result)
	}
}

func TestUDPRequestRejectsBadParams(t *testing.T) {
	for _, params := range []map[string]any{
		udpParams(0, nil),
		udpParams(54321, map[string]any{"host": ""}),
		udpParams(54321, map[string]any{"payload_b64": "not base64!"}),
		udpParams(54321, map[string]any{"payload_b64": base64.StdEncoding.EncodeToString(make([]byte, lanUDPMaxPayloadBytes+1))}),
	} {
		if _, err := (&connector{}).methodUDPRequest(context.Background(), params); err == nil {
			t.Fatalf("params %v were accepted", params)
		}
	}
}
