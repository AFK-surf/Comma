package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"strings"
	"testing"
)

func screenStreamTestFrame(kind byte, payload []byte) []byte {
	frame := make([]byte, 5, 5+len(payload))
	frame[0] = kind
	binary.BigEndian.PutUint32(frame[1:], uint32(len(payload)))
	return append(frame, payload...)
}

func TestReadScreenStreamFrame(t *testing.T) {
	stream := append(screenStreamTestFrame(screenStreamFrameJSON, []byte(`{"type":"ready"}`)), screenStreamTestFrame(screenStreamFrameVideo, []byte{1, 2, 3})...)
	reader := bytes.NewReader(stream)

	kind, payload, err := readScreenStreamFrame(reader)
	if err != nil || kind != screenStreamFrameJSON || string(payload) != `{"type":"ready"}` {
		t.Fatalf("first frame = %d %q %v", kind, payload, err)
	}
	kind, payload, err = readScreenStreamFrame(reader)
	if err != nil || kind != screenStreamFrameVideo || !bytes.Equal(payload, []byte{1, 2, 3}) {
		t.Fatalf("second frame = %d %v %v", kind, payload, err)
	}
	if _, _, err := readScreenStreamFrame(reader); err == nil {
		t.Fatal("reading past the last frame succeeded")
	}
}

func TestReadScreenStreamFrameRejectsOversizedPayload(t *testing.T) {
	header := []byte{screenStreamFrameVideo, 0, 0, 0, 0}
	binary.BigEndian.PutUint32(header[1:], screenStreamMaxFrameBytes+1)
	if _, _, err := readScreenStreamFrame(bytes.NewReader(header)); err == nil || !strings.Contains(err.Error(), "too large") {
		t.Fatalf("err = %v", err)
	}
}

func TestScreenStreamICEServers(t *testing.T) {
	if servers := screenStreamICEServers(nil); len(servers) != 1 || servers[0].URLs[0] != screenStreamDefaultSTUN {
		t.Fatalf("default servers = %#v", servers)
	}
	servers := screenStreamICEServers([]any{
		map[string]any{"urls": "turn:turn.example:3478", "username": "u", "credential": "c"},
		map[string]any{"urls": []any{"stun:a.example", "stun:b.example"}},
		map[string]any{"username": "no urls"},
	})
	if len(servers) != 2 || servers[0].Username != "u" || servers[0].Credential != "c" || len(servers[1].URLs) != 2 {
		t.Fatalf("servers = %#v", servers)
	}
}

func TestScreenStreamRejectsInvalidRequests(t *testing.T) {
	c := &connector{}
	for name, params := range map[string]map[string]any{
		"unknown op":  {"op": "pause"},
		"missing sdp": {"op": "start"},
	} {
		result := c.methodScreenStream(context.Background(), params)
		if result["ok"] != false || result["error"] == "" {
			t.Fatalf("%s: result = %#v", name, result)
		}
	}
	if result := c.methodScreenStream(context.Background(), map[string]any{"op": "stop", "stream_id": "absent"}); result["ok"] != true {
		t.Fatalf("stopping an absent stream = %#v", result)
	}
}

func TestScreenStreamRegistryBoundsSessions(t *testing.T) {
	var registry screenStreamRegistry
	streams := make([]*screenStream, 0, screenStreamMaxSessions)
	for index := range screenStreamMaxSessions {
		stream := &screenStream{id: string(rune('a' + index))}
		if err := registry.add(stream); err != nil {
			t.Fatalf("add %d: %v", index, err)
		}
		streams = append(streams, stream)
	}
	if err := registry.add(&screenStream{id: "over"}); err == nil {
		t.Fatal("registry accepted a stream over its bound")
	}
	registry.stop(streams[0].id)
	if err := registry.add(&screenStream{id: "next"}); err != nil {
		t.Fatalf("add after stop: %v", err)
	}
	registry.stopAll()
	if len(registry.streams) != 0 {
		t.Fatalf("streams left after stopAll: %d", len(registry.streams))
	}
}
