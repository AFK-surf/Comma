package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestMeetingJoinHTTPForwardsCallbacks(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		_ = json.NewDecoder(r.Body).Decode(&body)
		cb := stringFromAny(body["callback_url"])
		mid := stringFromAny(body["meeting_id"])
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"accepted":true,"session":"` + mid + `"}`))
		go func() {
			post := func(ev map[string]any) {
				b, _ := json.Marshal(map[string]any{"event": ev})
				req, _ := http.NewRequest(http.MethodPost, cb, bytes.NewReader(b))
				req.Header.Set("Authorization", "Bearer tok")
				resp, err := http.DefaultClient.Do(req)
				if err == nil {
					_ = resp.Body.Close()
				}
			}
			post(map[string]any{"meeting_id": mid, "type": "caption", "text": "hi"})
			post(map[string]any{"meeting_id": mid, "type": "meeting_ended"})
		}()
	}))
	defer srv.Close()

	c := &connector{cfg: config{meetURL: srv.URL}}
	events := collectMeetingEvents()
	deactivate := activateRuntimeTransportForTest(c, acknowledgeMeetingEvents(c, events.send))
	defer deactivate()
	out, err := c.methodMeetingJoin(context.Background(), joinParams())
	if err != nil {
		t.Fatalf("join: %v", err)
	}
	if out["accepted"] != true {
		t.Fatalf("expected accepted, got %v", out)
	}
	events.expect(t, []string{"caption", "meeting_ended"})
}

func TestMeetingRuntimeNotConfigured(t *testing.T) {
	c := &connector{cfg: config{}}
	if c.detectMeetingRuntime() != nil {
		t.Fatal("expected no meeting runtime without a transport")
	}
	if meetingRuntimeConfigured(c.cfg) {
		t.Fatal("expected meeting runtime disabled")
	}
}

func TestMeetingSendChatForwardsStableMessageID(t *testing.T) {
	received := make(chan map[string]any, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Errorf("decode request: %v", err)
		}
		received <- body
		w.Header().Set("content-type", "application/json")
		_, _ = w.Write([]byte(`{"sent":true}`))
	}))
	defer srv.Close()

	c := &connector{cfg: config{meetURL: srv.URL}}
	c.trackMeetingSession("m1", "session-1")

	if _, err := c.methodMeetingSendChat(context.Background(), map[string]any{
		"meeting_id": "m1",
		"message_id": "chat-message-1",
		"text":       "hello",
	}); err != nil {
		t.Fatalf("methodMeetingSendChat: %v", err)
	}

	select {
	case body := <-received:
		if body["message_id"] != "chat-message-1" || body["text"] != "hello" {
			t.Fatalf("forwarded body = %#v", body)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for meetnative request")
	}
}

func TestMeetingLeaveRequiresAndClearsActiveSession(t *testing.T) {
	requests := make(chan string, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests <- r.URL.Path
		w.WriteHeader(http.StatusNoContent)
	}))
	defer srv.Close()

	c := &connector{cfg: config{meetURL: srv.URL}}
	c.trackMeeting("m1", "tok")
	c.trackMeetingSession("m1", "session-1")

	if err := c.methodMeetingLeave(context.Background(), map[string]any{"meeting_id": "m1"}); err != nil {
		t.Fatalf("methodMeetingLeave: %v", err)
	}

	select {
	case path := <-requests:
		if path != "/v1/meetings/session-1/leave" {
			t.Fatalf("leave path=%q", path)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for leave request")
	}

	if got := c.meetingSession("m1"); got != "" {
		t.Fatalf("session mapping survived leave: %q", got)
	}
	if err := c.methodMeetingLeave(context.Background(), map[string]any{"meeting_id": "m1"}); err == nil {
		t.Fatal("leave without an active session unexpectedly succeeded")
	}
}

func TestMeetingEventTimeoutCoversNestedStopAndWaitArtifactFrames(t *testing.T) {
	tests := []struct {
		name  string
		event map[string]any
		want  time.Duration
	}{
		{name: "no artifacts", event: map[string]any{}, want: 150 * time.Second},
		{name: "small artifact", event: map[string]any{"artifacts": []any{
			map[string]any{"source_ref": "mart_small", "source_size": int64(64 * 1024)},
		}}, want: 210 * time.Second},
		{name: "maximum single artifact", event: map[string]any{"artifacts": []any{
			map[string]any{"source_ref": "mart_audio", "source_size": int64(30 * 1024 * 1024)},
		}}, want: 270 * time.Second},
		{name: "maximum aggregate", event: map[string]any{"artifacts": []any{
			map[string]any{"source_ref": "mart_audio", "source_size": int64(30 * 1024 * 1024)},
			map[string]any{"source_ref": "mart_transcript", "source_size": int64(2 * 1024 * 1024)},
		}}, want: 390 * time.Second},
		{name: "non-stream artifact does not collapse two-stream budget", event: map[string]any{"artifacts": []any{
			map[string]any{"source_ref": "mart_audio", "source_size": int64(30 * 1024 * 1024)},
			map[string]any{"source_ref": "mart_transcript", "source_size": int64(2 * 1024 * 1024)},
			map[string]any{"kind": "audio", "source_error": "artifact_count_limit"},
		}}, want: 390 * time.Second},
		{name: "malformed size fails to bounded floor", event: map[string]any{"artifacts": []any{
			map[string]any{"source_ref": "mart_bad", "source_size": "huge"},
		}}, want: 150 * time.Second},
		{name: "oversize fails to bounded floor", event: map[string]any{"artifacts": []any{
			map[string]any{"source_ref": "mart_bad", "source_size": int64(1 << 62)},
		}}, want: 150 * time.Second},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := meetingEventTimeout(tt.event); got != tt.want {
				t.Fatalf("meetingEventTimeout()=%s, want %s", got, tt.want)
			}
		})
	}

	t.Run("two-artifact deadlines are strictly nested", func(t *testing.T) {
		event := map[string]any{"artifacts": []any{
			map[string]any{"source_ref": "mart_audio", "source_size": int64(30 * 1024 * 1024)},
			map[string]any{"source_ref": "mart_transcript", "source_size": int64(2 * 1024 * 1024)},
		}}
		serverChildren := meetingArtifactRequestTimeout(map[string]any{"expected_size": int64(30 * 1024 * 1024)}) +
			meetingArtifactRequestTimeout(map[string]any{"expected_size": int64(2 * 1024 * 1024)})
		serverParent := meetingEventTimeout(event) - meetingOuterSlop
		if serverChildren+meetingEventFinalizeBudget >= serverParent {
			t.Fatalf("child budgets %s must fit below server parent %s", serverChildren, serverParent)
		}
		if serverParent >= meetingEventTimeout(event) {
			t.Fatalf("server parent %s must fit below callback %s", serverParent, meetingEventTimeout(event))
		}
	})
}

func TestMeetingCallbackAuth(t *testing.T) {
	c := &connector{cfg: config{meetURL: "http://unused"}}
	deactivate := activateRuntimeTransportForTest(c, acknowledgeMeetingEvents(c, func(message) error { return nil }))
	defer deactivate()
	c.trackMeeting("m1", "tok")
	cbURL, err := c.ensureMeetingCallback()
	if err != nil {
		t.Fatal(err)
	}

	post := func(bearer string) int {
		b, _ := json.Marshal(map[string]any{"event": map[string]any{"meeting_id": "m1", "type": "caption"}})
		req, _ := http.NewRequest(http.MethodPost, cbURL, bytes.NewReader(b))
		if bearer != "" {
			req.Header.Set("Authorization", "Bearer "+bearer)
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		return resp.StatusCode
	}

	if got := post(""); got != http.StatusUnauthorized {
		t.Fatalf("missing token: want 401 got %d", got)
	}
	if got := post("wrong"); got != http.StatusUnauthorized {
		t.Fatalf("wrong token: want 401 got %d", got)
	}
	if got := post("tok"); got != http.StatusAccepted {
		t.Fatalf("valid token: want 202 got %d", got)
	}
}

func TestMeetingCallbackStreamsOnlyAuthorizedImmutableArtifact(t *testing.T) {
	path := t.TempDir() + "/audio.ogg"
	want := []byte("OggS\x00bounded meeting audio")
	if err := os.WriteFile(path, want, 0o600); err != nil {
		t.Fatal(err)
	}

	c := &connector{cfg: config{meetURL: "http://unused"}}
	c.trackMeeting("m1", "tok")
	events := collectMeetingEvents()
	deactivate := activateRuntimeTransportForTest(c, acknowledgeMeetingEvents(c, events.send))
	defer deactivate()
	cbURL, err := c.ensureMeetingCallback()
	if err != nil {
		t.Fatal(err)
	}

	body, _ := json.Marshal(map[string]any{"event": map[string]any{
		"meeting_id": "m1",
		"type":       "meeting_ended",
		"artifacts": []any{
			map[string]any{"kind": "audio", "filename": "audio.ogg", "src_path": path},
		},
	}})
	req, _ := http.NewRequest(http.MethodPost, cbURL, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("callback status=%d, want 202", resp.StatusCode)
	}

	var event map[string]any
	select {
	case event = <-events.ch:
	case <-time.After(3 * time.Second):
		t.Fatal("timed out waiting for forwarded meeting event")
	}
	artifacts, ok := event["artifacts"].([]any)
	if !ok || len(artifacts) != 1 {
		t.Fatalf("artifacts=%#v", event["artifacts"])
	}
	artifact, ok := artifacts[0].(map[string]any)
	if !ok {
		t.Fatalf("artifact=%#v", artifacts[0])
	}
	if _, exposed := artifact["src_path"]; exposed {
		t.Fatalf("runtime path escaped authenticated callback: %#v", artifact)
	}
	ref := stringFromAny(artifact["source_ref"])
	if !strings.HasPrefix(ref, "mart_") {
		t.Fatalf("source_ref=%q", ref)
	}
	if _, err := c.meetingArtifactForRead("m1", ref); err == nil {
		t.Fatal("callback-scoped artifact capability survived the acknowledged forward")
	}

	directRef, _, err := c.registerMeetingArtifact("m1", path)
	if err != nil {
		t.Fatal(err)
	}
	defer c.releaseMeetingArtifacts([]string{directRef})

	var frames []message
	var session *connectionSession
	session = newConnectionSession(c, context.Background(), func(_ context.Context, frame message) error {
		frames = append(frames, frame)
		if frame.Stream != nil && !frame.Stream.EOF {
			go session.completePendingAck(frame.ID, frame.Stream.Seq, "")
		}
		return nil
	}, nil)
	defer session.close(context.Canceled)

	result, err := c.dispatchSession(context.Background(), session, "artifact", "meeting_artifact_read", map[string]any{
		"meeting_id":    "m1",
		"source_ref":    directRef,
		"expected_size": int64(len(want)),
		"max_bytes":     maxMeetingArtifactSize,
	})
	if err != nil {
		t.Fatalf("meeting_artifact_read: %v", err)
	}
	resultMap, ok := result.(map[string]any)
	if !ok || resultMap["size"] != int64(len(want)) {
		t.Fatalf("result=%#v", result)
	}
	var got []byte
	for _, frame := range frames {
		if frame.Stream == nil || frame.Stream.Data == "" {
			continue
		}
		chunk, decodeErr := base64.StdEncoding.DecodeString(frame.Stream.Data)
		if decodeErr != nil {
			t.Fatal(decodeErr)
		}
		got = append(got, chunk...)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("streamed=%q, want %q", got, want)
	}

	if _, err := c.meetingArtifactForRead("another-meeting", directRef); err == nil {
		t.Fatal("artifact capability was not bound to its meeting")
	}
	if err := os.WriteFile(path, bytes.Repeat([]byte("x"), len(want)), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := c.methodMeetingArtifactReadStreamFrames(context.Background(), session, "changed", map[string]any{
		"meeting_id":    "m1",
		"source_ref":    directRef,
		"expected_size": int64(len(want)),
		"max_bytes":     maxMeetingArtifactSize,
	}); err == nil || !strings.Contains(err.Error(), "meeting artifact changed") {
		t.Fatalf("changed artifact err=%v", err)
	}
}

func joinParams() map[string]any {
	return map[string]any{
		"meeting_id":    "m1",
		"meet_url":      "https://meet.google.com/abc-defg-hij",
		"runtime_token": "tok",
	}
}

type meetingEventSink struct{ ch chan map[string]any }

func collectMeetingEvents() *meetingEventSink {
	return &meetingEventSink{ch: make(chan map[string]any, 16)}
}

func (s *meetingEventSink) send(m message) error {
	if m.Method == "meeting_runtime_event" {
		ev, _ := m.Params["event"].(map[string]any)
		s.ch <- ev
	}
	return nil
}

func acknowledgeMeetingEvents(c *connector, send func(message) error) func(message) error {
	return func(m message) error {
		if m.Method == "meeting_runtime_capabilities" {
			c.completeRuntimeProxy(message{ID: m.ID, Type: "response", Result: map[string]any{
				"artifact_transport_versions": []any{meetingArtifactTransport},
			}})
			return nil
		}
		if err := send(m); err != nil {
			return err
		}
		c.completeRuntimeProxy(message{ID: m.ID, Type: "response", Result: map[string]any{"ok": true}})
		return nil
	}
}

func (s *meetingEventSink) expect(t *testing.T, want []string) {
	t.Helper()
	timeout := time.After(3 * time.Second)
	for i, w := range want {
		select {
		case ev := <-s.ch:
			if stringFromAny(ev["type"]) != w {
				t.Fatalf("event %d: want %s got %v", i, w, ev["type"])
			}
			if stringFromAny(ev["meeting_id"]) != "m1" {
				t.Fatalf("meeting_id not stamped: %v", ev)
			}
			if stringFromAny(ev["runtime_token"]) != "tok" {
				t.Fatalf("runtime_token not stamped: %v", ev)
			}
		case <-timeout:
			t.Fatalf("timed out waiting for event %d (%s)", i, w)
		}
	}
}

// The meeting callback must forward over the CURRENT connection: 503 while the
// tunnel is down (so meetnative retries), and after a reconnect the events go to
// the new send, never the stale one — the bug that stranded meetings on reconnect.
func TestMeetingCallbackFollowsLiveSend(t *testing.T) {
	c := &connector{cfg: config{meetURL: "http://unused"}}
	c.trackMeeting("m1", "tok")
	cbURL, err := c.ensureMeetingCallback()
	if err != nil {
		t.Fatal(err)
	}

	post := func() int {
		b, _ := json.Marshal(map[string]any{"event": map[string]any{"meeting_id": "m1", "type": "caption"}})
		req, _ := http.NewRequest(http.MethodPost, cbURL, bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer tok")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		return resp.StatusCode
	}

	// No live connection → 503 so meetnative retries instead of dropping the event.
	if got := post(); got != http.StatusServiceUnavailable {
		t.Fatalf("disconnected: want 503 got %d", got)
	}

	s1 := collectMeetingEvents()
	deactivate1 := activateRuntimeTransportForTest(c, acknowledgeMeetingEvents(c, s1.send))
	defer deactivate1()
	if got := post(); got != http.StatusAccepted {
		t.Fatalf("connected: want 202 got %d", got)
	}
	s1.expect(t, []string{"caption"})

	// Reconnect replaces the send. Events must follow the live connection.
	s2 := collectMeetingEvents()
	deactivate2 := activateRuntimeTransportForTest(c, acknowledgeMeetingEvents(c, s2.send))
	defer deactivate2()
	if got := post(); got != http.StatusAccepted {
		t.Fatalf("reconnected: want 202 got %d", got)
	}
	s2.expect(t, []string{"caption"})

	select {
	case ev := <-s1.ch:
		t.Fatalf("stale connection received event after reconnect: %v", ev)
	default:
	}
}

func TestMeetingCallbacksShareBoundedRuntimeAdmissionAndRecover(t *testing.T) {
	c := &connector{cfg: config{meetURL: "http://unused"}}
	c.trackMeeting("m1", "tok")
	cbURL, err := c.ensureMeetingCallback()
	if err != nil {
		t.Fatal(err)
	}

	requests := make(chan message, maxConcurrentRequests+1)
	deactivate := activateRuntimeTransportForTest(c, func(m message) error {
		requests <- m
		return nil
	})
	defer deactivate()

	post := func(eventID string) int {
		body, _ := json.Marshal(map[string]any{
			"event": map[string]any{
				"meeting_id": "m1",
				"event_id":   eventID,
				"type":       "caption",
				"text":       eventID,
			},
		})
		req, _ := http.NewRequest(http.MethodPost, cbURL, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer tok")
		resp, requestErr := http.DefaultClient.Do(req)
		if requestErr != nil {
			t.Errorf("post %s: %v", eventID, requestErr)
			return 0
		}
		_ = resp.Body.Close()
		return resp.StatusCode
	}

	statuses := make(chan int, maxConcurrentRequests)
	var starters sync.WaitGroup
	starters.Add(maxConcurrentRequests)
	for i := 0; i < maxConcurrentRequests; i++ {
		go func(index int) {
			starters.Done()
			statuses <- post(fmt.Sprintf("held-%d", index))
		}(i)
	}
	starters.Wait()

	held := make([]message, 0, maxConcurrentRequests)
	for len(held) < maxConcurrentRequests {
		select {
		case request := <-requests:
			held = append(held, request)
		case <-time.After(3 * time.Second):
			t.Fatalf("only %d callbacks reached the runtime", len(held))
		}
	}

	started := time.Now()
	if got := post("saturated"); got != http.StatusServiceUnavailable {
		t.Fatalf("saturated callback: want 503 got %d", got)
	}
	if elapsed := time.Since(started); elapsed > 2*time.Second {
		t.Fatalf("saturated callback waited %s instead of failing immediately", elapsed)
	}

	for _, request := range held {
		c.completeRuntimeProxy(message{
			ID:     request.ID,
			Type:   "response",
			Result: map[string]any{"ok": true},
		})
	}
	for i := 0; i < maxConcurrentRequests; i++ {
		if got := <-statuses; got != http.StatusAccepted {
			t.Fatalf("released callback %d: want 202 got %d", i, got)
		}
	}

	recovered := make(chan int, 1)
	go func() { recovered <- post("recovered") }()

	select {
	case request := <-requests:
		c.completeRuntimeProxy(message{
			ID:     request.ID,
			Type:   "response",
			Result: map[string]any{"ok": true},
		})
	case <-time.After(3 * time.Second):
		t.Fatal("callback admission did not recover after slots were released")
	}

	if got := <-recovered; got != http.StatusAccepted {
		t.Fatalf("recovered callback: want 202 got %d", got)
	}
}

func TestMeetingCallbackWaitsForSalixResultBeforeAcknowledging(t *testing.T) {
	c := &connector{cfg: config{meetURL: "http://unused"}}
	c.trackMeeting("m1", "tok")
	cbURL, err := c.ensureMeetingCallback()
	if err != nil {
		t.Fatal(err)
	}

	attempt := 0
	deactivate := activateRuntimeTransportForTest(c, func(m message) error {
		attempt++
		if attempt == 1 {
			c.completeRuntimeProxy(message{ID: m.ID, Type: "error", Error: "status outbox unavailable"})
		} else {
			c.completeRuntimeProxy(message{ID: m.ID, Type: "response", Result: map[string]any{"ok": true}})
		}
		return nil
	})
	defer deactivate()

	post := func() int {
		b, _ := json.Marshal(map[string]any{"event": map[string]any{"meeting_id": "m1", "type": "joiner_event"}})
		req, _ := http.NewRequest(http.MethodPost, cbURL, bytes.NewReader(b))
		req.Header.Set("Authorization", "Bearer tok")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = resp.Body.Close()
		return resp.StatusCode
	}

	if got := post(); got != http.StatusServiceUnavailable {
		t.Fatalf("Salix rejection: want 503 got %d", got)
	}
	if got := post(); got != http.StatusAccepted {
		t.Fatalf("Salix acceptance: want 202 got %d", got)
	}
	if attempt != 2 {
		t.Fatalf("want two producer attempts, got %d", attempt)
	}
}

func TestMeetingCallbackRetryWithoutProducerEventIDKeepsStableIdentity(t *testing.T) {
	path := t.TempDir() + "/transcript.txt"
	if err := os.WriteFile(path, []byte("stable retry body"), 0o600); err != nil {
		t.Fatal(err)
	}
	c := &connector{cfg: config{meetURL: "http://unused"}}
	c.trackMeeting("m1", "tok")
	cbURL, err := c.ensureMeetingCallback()
	if err != nil {
		t.Fatal(err)
	}

	var eventIDs, refs []string
	deactivate := activateRuntimeTransportForTest(c, func(m message) error {
		if m.Method == "meeting_runtime_capabilities" {
			c.completeRuntimeProxy(message{ID: m.ID, Type: "response", Result: map[string]any{
				"artifact_transport_versions": []any{meetingArtifactTransport},
			}})
			return nil
		}
		event, _ := m.Params["event"].(map[string]any)
		eventIDs = append(eventIDs, stringFromAny(event["event_id"]))
		artifacts, _ := event["artifacts"].([]any)
		artifact, _ := artifacts[0].(map[string]any)
		refs = append(refs, stringFromAny(artifact["source_ref"]))
		if len(eventIDs) == 1 {
			c.completeRuntimeProxy(message{ID: m.ID, Type: "error", Error: "retry me"})
		} else {
			c.completeRuntimeProxy(message{ID: m.ID, Type: "response", Result: map[string]any{"ok": true}})
		}
		return nil
	})
	defer deactivate()

	body, _ := json.Marshal(map[string]any{"event": map[string]any{
		"meeting_id": "m1", "type": "meeting_runtime_update", "status": "done",
		"artifacts": []any{map[string]any{"kind": "transcript", "src_path": path}},
	}})
	post := func() int {
		req, _ := http.NewRequest(http.MethodPost, cbURL, bytes.NewReader(body))
		req.Header.Set("Authorization", "Bearer tok")
		resp, postErr := http.DefaultClient.Do(req)
		if postErr != nil {
			t.Fatal(postErr)
		}
		_ = resp.Body.Close()
		return resp.StatusCode
	}

	if got := post(); got != http.StatusServiceUnavailable {
		t.Fatalf("first attempt status=%d, want 503", got)
	}
	if got := post(); got != http.StatusAccepted {
		t.Fatalf("retry status=%d, want 202", got)
	}
	if len(eventIDs) != 2 || eventIDs[0] == "" || eventIDs[0] != eventIDs[1] {
		t.Fatalf("event ids=%#v, want one stable fallback", eventIDs)
	}
	if len(refs) != 2 || refs[0] == "" || refs[0] == refs[1] {
		t.Fatalf("source refs=%#v, want fresh callback-scoped refs", refs)
	}
	if len(c.meetingArtifacts) != 0 {
		t.Fatalf("callback refs leaked after attempts: %#v", c.meetingArtifacts)
	}
}

func TestMeetingCallbackRejectsArtifactBeforeRegistrationWhenAdmissionIsFull(t *testing.T) {
	path := t.TempDir() + "/audio.ogg"
	if err := os.WriteFile(path, []byte("must not be hashed or registered"), 0o600); err != nil {
		t.Fatal(err)
	}
	c := &connector{cfg: config{meetURL: "http://unused"}}
	c.trackMeeting("m1", "tok")
	cbURL, err := c.ensureMeetingCallback()
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < maxConcurrentRequests; i++ {
		c.runtimeProxySlots <- struct{}{}
	}
	defer func() {
		for i := 0; i < maxConcurrentRequests; i++ {
			<-c.runtimeProxySlots
		}
	}()

	body, _ := json.Marshal(map[string]any{"event": map[string]any{
		"meeting_id": "m1", "type": "meeting_ended",
		"artifacts": []any{map[string]any{"kind": "audio", "src_path": path}},
	}})
	req, _ := http.NewRequest(http.MethodPost, cbURL, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status=%d, want 503", resp.StatusCode)
	}
	if len(c.meetingArtifacts) != 0 {
		t.Fatalf("rejected callback mutated artifact table: %#v", c.meetingArtifacts)
	}
}

func TestMeetingCallbackFailsClosedWhenServerDoesNotNegotiateArtifactTransport(t *testing.T) {
	path := t.TempDir() + "/audio.ogg"
	if err := os.WriteFile(path, []byte("audio"), 0o600); err != nil {
		t.Fatal(err)
	}
	c := &connector{cfg: config{meetURL: "http://unused"}}
	c.trackMeeting("m1", "tok")
	cbURL, err := c.ensureMeetingCallback()
	if err != nil {
		t.Fatal(err)
	}
	deactivate := activateRuntimeTransportForTest(c, func(m message) error {
		c.completeRuntimeProxy(message{ID: m.ID, Type: "error", Error: "unknown method"})
		return nil
	})
	defer deactivate()

	body, _ := json.Marshal(map[string]any{"event": map[string]any{
		"meeting_id": "m1", "type": "meeting_ended",
		"artifacts": []any{map[string]any{"kind": "audio", "src_path": path}},
	}})
	req, _ := http.NewRequest(http.MethodPost, cbURL, bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer tok")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status=%d, want retryable 503", resp.StatusCode)
	}
	if len(c.meetingArtifacts) != 0 {
		t.Fatalf("version mismatch registered capabilities: %#v", c.meetingArtifacts)
	}
}

func TestMeetingArtifactStreamRejectsSameSizeMutationAndGrowthBeforeEOF(t *testing.T) {
	for _, tc := range []struct {
		name   string
		mutate func(string, []byte) error
	}{
		{
			name: "same-size rewrite",
			mutate: func(path string, original []byte) error {
				return os.WriteFile(path, bytes.Repeat([]byte("z"), len(original)), 0o600)
			},
		},
		{
			name: "append",
			mutate: func(path string, _ []byte) error {
				f, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0)
				if err != nil {
					return err
				}
				defer f.Close()
				_, err = f.Write([]byte("growth"))
				return err
			},
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := t.TempDir() + "/audio.ogg"
			original := bytes.Repeat([]byte("a"), 256*1024)
			if err := os.WriteFile(path, original, 0o600); err != nil {
				t.Fatal(err)
			}
			c := &connector{}
			ref, _, err := c.registerMeetingArtifact("m1", path)
			if err != nil {
				t.Fatal(err)
			}
			defer c.releaseMeetingArtifacts([]string{ref})

			mutated := false
			var frames []message
			var session *connectionSession
			session = newConnectionSession(c, context.Background(), func(_ context.Context, frame message) error {
				frames = append(frames, frame)
				if frame.Stream != nil && !frame.Stream.EOF {
					if !mutated {
						mutated = true
						if err := tc.mutate(path, original); err != nil {
							return err
						}
					}
					go session.completePendingAck(frame.ID, frame.Stream.Seq, "")
				}
				return nil
			}, nil)
			defer session.close(context.Canceled)

			_, err = c.methodMeetingArtifactReadStreamFrames(context.Background(), session, "mutating", map[string]any{
				"meeting_id": "m1", "source_ref": ref,
				"expected_size": int64(len(original)), "max_bytes": maxMeetingArtifactSize,
			})
			if err == nil || !strings.Contains(err.Error(), "changed while streaming") {
				t.Fatalf("err=%v, want immutable-stream rejection", err)
			}
			for _, frame := range frames {
				if frame.Stream != nil && frame.Stream.EOF {
					t.Fatalf("immutable-source failure emitted success EOF: %#v", frame)
				}
			}
		})
	}
}

func TestMeetingArtifactEventBoundsAreTerminalAndDoNotEvictAdmittedRefs(t *testing.T) {
	root := t.TempDir()
	paths := []string{root + "/one.txt", root + "/two.ogg", root + "/three.ogg"}
	for _, path := range paths {
		if err := os.WriteFile(path, []byte("bounded"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	event := map[string]any{"artifacts": []any{
		map[string]any{"kind": "transcript", "src_path": paths[0]},
		map[string]any{"kind": "audio", "src_path": paths[1]},
		map[string]any{"kind": "audio", "src_path": paths[2]},
	}}
	c := &connector{}
	refs, err := c.authorizeMeetingArtifacts("m1", event)
	if err != nil {
		t.Fatal(err)
	}
	defer c.releaseMeetingArtifacts(refs)
	if len(refs) != maxArtifactsPerEvent || len(c.meetingArtifacts) != maxArtifactsPerEvent {
		t.Fatalf("refs=%d table=%d", len(refs), len(c.meetingArtifacts))
	}
	artifacts := event["artifacts"].([]any)
	third := artifacts[2].(map[string]any)
	if third["source_error"] != "artifact_count_limit" || third["source_ref"] != nil {
		t.Fatalf("third artifact=%#v", third)
	}
}

func postMeetingCallback(t *testing.T, c *connector, token string, event map[string]any) *httptest.ResponseRecorder {
	t.Helper()
	b, err := json.Marshal(map[string]any{"event": event})
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/meeting-events", bytes.NewReader(b))
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	c.handleMeetingCallback(rec, req)
	return rec
}

func TestMeetingCallbackForwardsPresentedTokenOnCacheMiss(t *testing.T) {
	// A restarted connector has an empty token table while meetnative still
	// holds the join-time token. The callback must forward the presented
	// token for the Server's authoritative verification instead of 401ing.
	c := &connector{cfg: config{meetURL: "http://127.0.0.1:1"}}
	c.runtimeProxySlots = make(chan struct{}, maxConcurrentRequests)
	events := collectMeetingEvents()
	deactivate := activateRuntimeTransportForTest(c, acknowledgeMeetingEvents(c, events.send))
	defer deactivate()

	rec := postMeetingCallback(t, c, "join-time-token", map[string]any{
		"meeting_id": "m1", "type": "caption", "text": "late",
	})
	if rec.Code != http.StatusAccepted {
		t.Fatalf("cache-miss callback status=%d body=%s", rec.Code, rec.Body.String())
	}
	select {
	case ev := <-events.ch:
		if stringFromAny(ev["runtime_token"]) != "join-time-token" {
			t.Fatalf("forwarded token=%v", ev["runtime_token"])
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for forwarded event")
	}
}

func TestMeetingCallbackStillRejectsLocally(t *testing.T) {
	c := &connector{cfg: config{meetURL: "http://127.0.0.1:1"}}
	c.trackMeeting("m1", "tok")

	if rec := postMeetingCallback(t, c, "wrong", map[string]any{"meeting_id": "m1", "type": "caption"}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("cache-hit mismatch status=%d", rec.Code)
	}
	if rec := postMeetingCallback(t, c, "", map[string]any{"meeting_id": "m1", "type": "caption"}); rec.Code != http.StatusUnauthorized {
		t.Fatalf("missing credential status=%d", rec.Code)
	}
	if rec := postMeetingCallback(t, c, "tok", map[string]any{"type": "caption"}); rec.Code != http.StatusBadRequest {
		t.Fatalf("missing meeting_id status=%d", rec.Code)
	}
}

func TestMeetingCallbackPinnedPort(t *testing.T) {
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("probe listen: %v", err)
	}
	port := probe.Addr().(*net.TCPAddr).Port
	_ = probe.Close()

	c := &connector{cfg: config{meetURL: "http://127.0.0.1:1", meetCallbackPort: port}}
	cb, err := c.ensureMeetingCallback()
	if err != nil {
		t.Fatalf("ensureMeetingCallback: %v", err)
	}
	defer func() {
		if c.meetServer != nil {
			_ = c.meetServer.Close()
		}
	}()
	want := fmt.Sprintf("http://127.0.0.1:%d/meeting-events", port)
	if cb != want {
		t.Fatalf("callback url=%q want %q", cb, want)
	}
}

func TestMeetingSessionStatusThreeValued(t *testing.T) {
	var response func(w http.ResponseWriter, r *http.Request)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/meetings/status" || r.URL.Query().Get("meeting_id") != "m1" {
			t.Errorf("unexpected probe %s?%s", r.URL.Path, r.URL.RawQuery)
		}
		response(w, r)
	}))
	defer srv.Close()

	c := &connector{cfg: config{meetURL: srv.URL}}
	ask := func() map[string]any {
		out, err := c.methodMeetingSessionStatus(context.Background(), map[string]any{"meeting_id": "m1"})
		if err != nil {
			t.Fatalf("methodMeetingSessionStatus: %v", err)
		}
		return out
	}

	response = func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"meeting_id":"m1","active":true,"session":"sess-1"}`))
	}
	if out := ask(); out["status"] != "live" || out["session"] != "sess-1" || out["join_idempotent"] != true {
		t.Fatalf("active answer=%v", out)
	}

	response = func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"meeting_id":"m1","active":false}`))
	}
	if out := ask(); out["status"] != "none" || out["join_idempotent"] != true {
		t.Fatalf("inactive answer=%v", out)
	}

	// An unknown route (today's meetnative), a malformed body, and a
	// mismatched echo must all stay "unavailable" — never a definite answer.
	response = func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusNotFound) }
	if out := ask(); out["status"] != "unavailable" {
		t.Fatalf("route-404 answer=%v", out)
	}
	response = func(w http.ResponseWriter, _ *http.Request) { _, _ = w.Write([]byte(`{"session":"x"}`)) }
	if out := ask(); out["status"] != "unavailable" {
		t.Fatalf("missing-active answer=%v", out)
	}
	response = func(w http.ResponseWriter, _ *http.Request) {
		_, _ = w.Write([]byte(`{"meeting_id":"other","active":true}`))
	}
	if out := ask(); out["status"] != "unavailable" {
		t.Fatalf("mismatched-echo answer=%v", out)
	}

	unconfigured := &connector{cfg: config{}}
	out, err := unconfigured.methodMeetingSessionStatus(context.Background(), map[string]any{"meeting_id": "m1"})
	if err != nil || out["status"] != "unavailable" {
		t.Fatalf("unconfigured answer=%v err=%v", out, err)
	}

	unreachable := &connector{cfg: config{meetURL: "http://127.0.0.1:1"}}
	out, err = unreachable.methodMeetingSessionStatus(context.Background(), map[string]any{"meeting_id": "m1"})
	if err != nil || out["status"] != "unavailable" {
		t.Fatalf("unreachable answer=%v err=%v", out, err)
	}
}

func TestPinnedCallbackPortReceivesCacheMissCallbackBeforeAnyJoin(t *testing.T) {
	// The reviewer-reproduced restart hole: with a pinned port, the listener
	// must exist from process start, not from the next meeting_join. This
	// drives the real startup path (newConnector) and the real TCP listener,
	// with an empty token table standing in for the post-restart state.
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("probe listen: %v", err)
	}
	port := probe.Addr().(*net.TCPAddr).Port
	_ = probe.Close()

	c, err := newConnector(config{
		name:             "test",
		root:             t.TempDir(),
		meetURL:          "http://127.0.0.1:1",
		meetCallbackPort: port,
	})
	if err != nil {
		t.Fatalf("newConnector: %v", err)
	}
	defer c.closeExternalRuntimes()
	defer func() {
		if c.meetServer != nil {
			_ = c.meetServer.Close()
		}
	}()

	events := collectMeetingEvents()
	deactivate := activateRuntimeTransportForTest(c, acknowledgeMeetingEvents(c, events.send))
	defer deactivate()

	// No meeting_join has happened in this process lifetime. The terminal
	// callback of a pre-restart meeting must still be accepted over TCP and
	// forwarded with the presented token for server-side verification.
	b, err := json.Marshal(map[string]any{"event": map[string]any{
		"meeting_id": "m1", "type": "meeting_runtime_update", "status": "done",
	}})
	if err != nil {
		t.Fatalf("marshal event: %v", err)
	}
	req, err := http.NewRequest(http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/meeting-events", port), bytes.NewReader(b))
	if err != nil {
		t.Fatalf("build request: %v", err)
	}
	req.Header.Set("Authorization", "Bearer join-time-token")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("callback before any join refused: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("callback status=%d", resp.StatusCode)
	}
	select {
	case ev := <-events.ch:
		if stringFromAny(ev["runtime_token"]) != "join-time-token" || stringFromAny(ev["status"]) != "done" {
			t.Fatalf("forwarded event=%#v", ev)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for forwarded terminal event")
	}
}

func TestPinnedCallbackPortBindFailureIsFatalAtStartup(t *testing.T) {
	holder, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("holder listen: %v", err)
	}
	defer holder.Close()
	port := holder.Addr().(*net.TCPAddr).Port

	_, err = newConnector(config{
		name:             "test",
		root:             t.TempDir(),
		meetURL:          "http://127.0.0.1:1",
		meetCallbackPort: port,
	})
	if err == nil || !strings.Contains(err.Error(), "pinned meeting callback port") {
		t.Fatalf("expected fatal pinned-port bind error, got %v", err)
	}
}

func TestMeetingJoinAdoptsLiveRuntimeSession(t *testing.T) {
	var joinCalls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/meetings/status":
			w.Header().Set("content-type", "application/json")
			_, _ = w.Write([]byte(`{"meeting_id":"m1","active":true,"session":"sess-live"}`))
		case "/v1/meetings/join":
			atomic.AddInt32(&joinCalls, 1)
			w.Header().Set("content-type", "application/json")
			_, _ = w.Write([]byte(`{"accepted":true,"session":"sess-new"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	c := &connector{cfg: config{meetURL: srv.URL}}
	out, err := c.methodMeetingJoin(context.Background(), joinParams())
	if err != nil {
		t.Fatalf("join: %v", err)
	}
	if out["accepted"] != true || out["already"] != true || stringFromAny(out["session"]) != "sess-live" {
		t.Fatalf("expected live-session adoption, got %v", out)
	}
	if atomic.LoadInt32(&joinCalls) != 0 {
		t.Fatal("a join for a live session must not raise a second bot")
	}
	if c.meetingSession("m1") != "sess-live" {
		t.Fatal("adopted session not tracked for chat/leave downlink")
	}
}

func TestMeetingJoinProceedsOnDefinitelyNoneAnswer(t *testing.T) {
	var joinCalls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/meetings/status":
			w.Header().Set("content-type", "application/json")
			_, _ = w.Write([]byte(`{"meeting_id":"m1","active":false}`))
		case "/v1/meetings/join":
			atomic.AddInt32(&joinCalls, 1)
			w.Header().Set("content-type", "application/json")
			_, _ = w.Write([]byte(`{"accepted":true,"session":"sess-new"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	c := &connector{cfg: config{meetURL: srv.URL}}
	defer func() {
		if c.meetServer != nil {
			_ = c.meetServer.Close()
		}
	}()
	out, err := c.methodMeetingJoin(context.Background(), joinParams())
	if err != nil {
		t.Fatalf("join: %v", err)
	}
	if out["accepted"] != true || out["already"] == true {
		t.Fatalf("expected a fresh dispatch, got %v", out)
	}
	if atomic.LoadInt32(&joinCalls) != 1 {
		t.Fatalf("expected exactly one forwarded join, got %d", joinCalls)
	}
}

func TestMeetingSessionStatusAttestsIdempotentJoinOnlyWithRuntime(t *testing.T) {
	// Unconfigured: no runtime, no attestation — plain fail-closed unavailable.
	c := &connector{cfg: config{}}
	out, err := c.methodMeetingSessionStatus(context.Background(), map[string]any{"meeting_id": "m1"})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if out["status"] != "unavailable" || out["join_idempotent"] != nil {
		t.Fatalf("unconfigured answer=%v", out)
	}

	// Configured but unreachable (the pinned pre-/status meetnative shape):
	// unavailable, with the pinned-contract idempotency attested.
	c = &connector{cfg: config{meetURL: "http://127.0.0.1:1"}}
	out, err = c.methodMeetingSessionStatus(context.Background(), map[string]any{"meeting_id": "m1"})
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if out["status"] != "unavailable" || out["join_idempotent"] != true {
		t.Fatalf("unreachable answer=%v", out)
	}
}
