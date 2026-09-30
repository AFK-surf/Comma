package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	meetingRuntimeID            = "meetnative"
	meetingRuntimeProvider      = "meetnative"
	meetingRuntimeKind          = "meeting"
	meetingArtifactProbeTimeout = 5 * time.Second
	meetingArtifactTransport    = "opaque-v1"
	meetingArtifactTTL          = 2 * time.Hour
	maxMeetingArtifacts         = 128
	maxArtifactsPerEvent        = 2
	maxMeetingArtifactSize      = 30 * 1024 * 1024
	maxMeetingArtifactEventSize = 32 * 1024 * 1024
	meetingArtifactFrameBytes   = 64 * 1024
	meetingArtifactFrameBudget  = 250 * time.Millisecond
	meetingArtifactSetupBudget  = 30 * time.Second
	meetingEventFinalizeBudget  = 30 * time.Second
	meetingEventServerSlop      = 30 * time.Second
	meetingEventServerFloor     = 120 * time.Second
	meetingOuterSlop            = 30 * time.Second
)

type meetingArtifact struct {
	meetingID  string
	path       string
	size       int64
	modTime    time.Time
	hash       [sha256.Size]byte
	registered time.Time
}

var errMeetingArtifactTerminal = errors.New("terminal meeting artifact source error")

func meetingRuntimeConfigured(cfg config) bool {
	return strings.TrimSpace(cfg.meetURL) != ""
}

func (c *connector) detectMeetingRuntime() []map[string]any {
	if !meetingRuntimeConfigured(c.cfg) {
		return nil
	}
	return []map[string]any{
		{
			"id":         meetingRuntimeID,
			"kind":       meetingRuntimeKind,
			"provider":   meetingRuntimeProvider,
			"status":     "ready",
			"ready":      true,
			"transports": []string{"http"},
		},
	}
}

func (c *connector) methodMeetingJoin(ctx context.Context, params map[string]any) (map[string]any, error) {
	meetingID := stringParam(params, "meeting_id")
	if meetingID == "" {
		return nil, errors.New("meeting_id is required")
	}
	if stringParam(params, "meet_url") == "" {
		return nil, errors.New("meet_url is required")
	}
	if strings.TrimSpace(c.cfg.meetURL) == "" {
		return nil, errors.New("meeting runtime not configured")
	}

	// Runtime-side join idempotency (RFC contract one, defense in depth at
	// the closest point to truth): if the runtime already holds a live
	// session for this meeting, adopt it instead of raising a second bot.
	// Only a definite "live" answer short-circuits; "none" and "unavailable"
	// proceed exactly as before — the Salix-side claim gate has already
	// required a definite answer for any retry re-dispatch.
	if status, err := c.methodMeetingSessionStatus(ctx, map[string]any{"meeting_id": meetingID}); err == nil {
		if stringFromAny(status["status"]) == "live" {
			c.trackMeeting(meetingID, stringParam(params, "runtime_token"))
			if sessionID := stringFromAny(status["session"]); sessionID != "" {
				c.trackMeetingSession(meetingID, sessionID)
			}
			out := map[string]any{"accepted": true, "already": true}
			if sessionID := stringFromAny(status["session"]); sessionID != "" {
				out["session"] = sessionID
			}
			return out, nil
		}
	}

	c.trackMeeting(meetingID, stringParam(params, "runtime_token"))

	callbackURL, err := c.ensureMeetingCallback()
	if err != nil {
		return nil, err
	}

	body := map[string]any{}
	for k, v := range params {
		body[k] = v
	}
	body["callback_url"] = callbackURL
	if stringParam(params, "llm_capability_token") != "" {
		body["llm_url"] = c.meetBaseURL + "/llm/chat"
	}
	raw, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}

	url := strings.TrimRight(c.cfg.meetURL, "/") + "/v1/meetings/join"
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("content-type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("meetnative join failed: HTTP %d %s", resp.StatusCode, strings.TrimSpace(string(rb)))
	}
	out := map[string]any{}
	_ = json.Unmarshal(rb, &out)
	if sessionID := stringFromAny(out["session"]); sessionID != "" {
		c.trackMeetingSession(meetingID, sessionID)
	}
	out["accepted"] = true
	return out, nil
}

// methodMeetingSendChat commands the joined bot to post a chat message into the live meeting. It is the
// downlink counterpart of the meetnative → connector → salix chat uplink: salix issues "meeting_send_chat"
// over the connector, and this routes it to the meetnative session that owns the meeting.
func (c *connector) methodMeetingSendChat(ctx context.Context, params map[string]any) (map[string]any, error) {
	meetingID := stringParam(params, "meeting_id")
	messageID := stringParam(params, "message_id")
	text := stringParam(params, "text")
	if meetingID == "" {
		return nil, errors.New("meeting_id is required")
	}
	if messageID == "" {
		return nil, errors.New("message_id is required")
	}
	if text == "" {
		return nil, errors.New("text is required")
	}
	if strings.TrimSpace(c.cfg.meetURL) == "" {
		return nil, errors.New("meeting runtime not configured")
	}

	sessionID := c.meetingSession(meetingID)
	if sessionID == "" {
		return nil, fmt.Errorf("no active meetnative session for meeting %s", meetingID)
	}

	raw, err := json.Marshal(map[string]any{"message_id": messageID, "text": text})
	if err != nil {
		return nil, err
	}

	url := strings.TrimRight(c.cfg.meetURL, "/") + "/v1/meetings/" + sessionID + "/chat"
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, url, bytes.NewReader(raw))
	if err != nil {
		return nil, err
	}
	req.Header.Set("content-type", "application/json")

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	rb, _ := io.ReadAll(resp.Body)
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("meetnative chat failed: HTTP %d %s", resp.StatusCode, strings.TrimSpace(string(rb)))
	}
	return map[string]any{"sent": true}, nil
}

// methodMeetingSessionStatus answers the three-valued live-session read: does
// the runtime that actually owns the bot report a live session for this
// meeting_id? The connector's in-memory session table is never consulted —
// it is a cache, not the authority. Only an exact, well-formed meetnative
// answer produces a definite result; every other outcome (runtime not
// configured, unreachable, unknown route, malformed or mismatched body) maps
// to "unavailable", which callers must treat as fail-closed and never fold
// into either definite answer.
//
// Contract with meetnative (documented in
// docs/meetings-calendar.md): GET /v1/meetings/status with a
// meeting_id query parameter returns 200 and a JSON body carrying a boolean
// "active" (optionally "meeting_id" echoing the query and "session"). Until
// meetnative implements that endpoint every probe reports "unavailable".
func (c *connector) methodMeetingSessionStatus(ctx context.Context, params map[string]any) (map[string]any, error) {
	meetingID := stringParam(params, "meeting_id")
	if meetingID == "" {
		return nil, errors.New("meeting_id is required")
	}
	if strings.TrimSpace(c.cfg.meetURL) == "" {
		return map[string]any{"status": "unavailable", "reason": "not_configured"}, nil
	}
	// With a meeting runtime configured, the connector attests the pinned
	// meet-native contract: join is idempotent by meeting_id. Salix's retry
	// gate accepts this attestation as the runtime-authority face of RFC
	// contract one when the liveness probe itself is unavailable (the pinned
	// meet-native predates the /status endpoint).
	attested := func(out map[string]any) (map[string]any, error) {
		out["join_idempotent"] = true
		return out, nil
	}

	endpoint := strings.TrimRight(c.cfg.meetURL, "/") + "/v1/meetings/status?" +
		url.Values{"meeting_id": []string{meetingID}}.Encode()
	requestCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(requestCtx, http.MethodGet, endpoint, nil)
	if err != nil {
		return attested(map[string]any{"status": "unavailable", "reason": "request_build_failed"})
	}

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return attested(map[string]any{"status": "unavailable", "reason": "runtime_unreachable"})
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64*1024))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return attested(map[string]any{"status": "unavailable", "reason": fmt.Sprintf("http_%d", resp.StatusCode)})
	}

	var parsed struct {
		MeetingID string `json:"meeting_id"`
		Active    *bool  `json:"active"`
		Session   string `json:"session"`
	}
	if err := json.Unmarshal(body, &parsed); err != nil || parsed.Active == nil {
		return attested(map[string]any{"status": "unavailable", "reason": "malformed_runtime_answer"})
	}
	if parsed.MeetingID != "" && parsed.MeetingID != meetingID {
		return attested(map[string]any{"status": "unavailable", "reason": "meeting_id_mismatch"})
	}
	if !*parsed.Active {
		return attested(map[string]any{"status": "none"})
	}
	out := map[string]any{"status": "live"}
	if parsed.Session != "" {
		out["session"] = parsed.Session
	}
	return attested(out)
}

func (c *connector) methodMeetingLeave(ctx context.Context, params map[string]any) error {
	meetingID := stringParam(params, "meeting_id")
	if meetingID == "" {
		return errors.New("meeting_id is required")
	}
	if strings.TrimSpace(c.cfg.meetURL) == "" {
		return errors.New("meeting runtime not configured")
	}

	sessionID := c.meetingSession(meetingID)
	if sessionID == "" {
		return fmt.Errorf("no active meetnative session for meeting %s", meetingID)
	}

	requestCtx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(
		requestCtx,
		http.MethodPost,
		strings.TrimRight(c.cfg.meetURL, "/")+"/v1/meetings/"+sessionID+"/leave",
		bytes.NewReader([]byte("{}")),
	)
	if err != nil {
		return err
	}
	req.Header.Set("content-type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("meetnative leave failed: HTTP %d", resp.StatusCode)
	}
	c.forgetMeeting(meetingID)
	return nil
}

func (c *connector) trackMeeting(meetingID, runtimeToken string) {
	c.meetMu.Lock()
	if c.meetTokens == nil {
		c.meetTokens = map[string]string{}
	}
	c.meetTokens[meetingID] = runtimeToken
	c.meetMu.Unlock()
}

// trackMeetingSession remembers the meetnative session id returned by join, so a later "meeting_send_chat"
// can address the meeting's chat endpoint (which is keyed by session id, not meeting id).
func (c *connector) trackMeetingSession(meetingID, sessionID string) {
	c.meetMu.Lock()
	if c.meetSessions == nil {
		c.meetSessions = map[string]string{}
	}
	c.meetSessions[meetingID] = sessionID
	c.meetMu.Unlock()
}

func (c *connector) meetingSession(meetingID string) string {
	c.meetMu.Lock()
	defer c.meetMu.Unlock()
	return c.meetSessions[meetingID]
}

func (c *connector) forgetMeeting(meetingID string) {
	c.meetMu.Lock()
	defer c.meetMu.Unlock()
	delete(c.meetTokens, meetingID)
	delete(c.meetSessions, meetingID)
}

func (c *connector) ensureMeetingCallback() (string, error) {
	c.meetMu.Lock()
	defer c.meetMu.Unlock()
	if c.meetCallbackURL != "" {
		return c.meetCallbackURL, nil
	}
	if c.runtimeProxySlots == nil {
		c.runtimeProxySlots = make(chan struct{}, maxConcurrentRequests)
	}

	host := strings.TrimSpace(c.cfg.meetCallbackHost)
	listenHost := "127.0.0.1"
	if host != "" {
		listenHost = "0.0.0.0"
	}
	// A pinned per-instance port keeps callback URLs held by meetnative valid
	// across a connector restart; port 0 preserves the ephemeral default.
	listenAddr := net.JoinHostPort(listenHost, strconv.Itoa(c.cfg.meetCallbackPort))
	ln, err := net.Listen("tcp", listenAddr)
	if err != nil {
		return "", err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/meeting-events", c.handleMeetingCallback)
	mux.HandleFunc("/llm/chat", c.handleLLMChat)
	srv := &http.Server{Handler: mux}
	go func() { _ = srv.Serve(ln) }()
	c.meetServer = srv
	if host == "" {
		host = "127.0.0.1"
	}
	_, port, _ := net.SplitHostPort(ln.Addr().String())
	c.meetBaseURL = "http://" + net.JoinHostPort(host, port)
	c.meetCallbackURL = c.meetBaseURL + "/meeting-events"
	return c.meetCallbackURL, nil
}

func (c *connector) handleMeetingCallback(w http.ResponseWriter, r *http.Request) {
	var env struct {
		Event map[string]any `json:"event"`
	}
	if err := json.NewDecoder(r.Body).Decode(&env); err != nil || env.Event == nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	meetingID := stringFromAny(env.Event["meeting_id"])
	if strings.TrimSpace(meetingID) == "" {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	c.meetMu.Lock()
	token := c.meetTokens[meetingID]
	c.meetMu.Unlock()

	// The in-memory token table is a precheck cache in front of the Server's
	// authoritative runtime_token verification, never the authority itself. A
	// cache hit still rejects a mismatched credential locally; a cache miss
	// (typically a connector restart during a live meeting) forwards the
	// presented token so the Server can verify it against the meeting
	// document, instead of dropping a terminal event with a 401 that
	// meetnative does not retry.
	presented := bearerToken(r.Header.Get("Authorization"))
	if presented == "" {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if token != "" && subtle.ConstantTimeCompare([]byte(presented), []byte(token)) != 1 {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if !c.tryAcquireMeetingEventSlot() {
		logf("meeting artifact admission rejected (%s): callback capacity exhausted", meetingID)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"accepted":false,"reason":"capacity exhausted"}`))
		return
	}
	defer func() { <-c.runtimeProxySlots }()

	if err := ensureMeetingEventID(meetingID, env.Event); err != nil {
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"accepted":false,"reason":"event identity unavailable"}`))
		return
	}
	transport := c.getActiveTransport()
	if eventHasLocalMeetingArtifacts(env.Event) {
		probeCtx, probeCancel := context.WithTimeout(r.Context(), meetingArtifactProbeTimeout)
		err := c.requireMeetingArtifactTransport(probeCtx, transport)
		probeCancel()
		if err != nil {
			logf("meeting artifact transport unavailable (%s): %v — asking meetnative to retry", meetingID, err)
			w.WriteHeader(http.StatusServiceUnavailable)
			_, _ = w.Write([]byte(`{"accepted":false,"reason":"artifact transport unavailable"}`))
			return
		}
	}
	refs, err := c.authorizeMeetingArtifacts(meetingID, env.Event)
	if err != nil {
		logf("meeting artifact authorization failed (%s): %v — asking meetnative to retry", meetingID, err)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"accepted":false,"reason":"artifact authorization failed"}`))
		return
	}
	defer c.releaseMeetingArtifacts(refs)
	ctx, cancel := context.WithTimeout(r.Context(), meetingEventTimeout(env.Event))
	defer cancel()

	if err := c.forwardMeetingEvent(ctx, transport, meetingID, presented, env.Event); err != nil {
		logf("meeting event forward failed (%s): %v — asking meetnative to retry", meetingID, err)
		w.WriteHeader(http.StatusServiceUnavailable)
		_, _ = w.Write([]byte(`{"accepted":false}`))
		return
	}
	w.Header().Set("content-type", "application/json")
	w.WriteHeader(http.StatusAccepted)
	_, _ = w.Write([]byte(`{"accepted":true}`))
}

func meetingEventTimeout(event map[string]any) time.Duration {
	sizes, ok := boundedMeetingArtifactSizes(event)
	if !ok {
		sizes = nil
	}
	serverBudget := meetingEventFinalizeBudget + meetingEventServerSlop
	for _, size := range sizes {
		// The connector-side request may remain alive for one outer-slop
		// window after the Server has received the FrameStream handle. Parent
		// budgets therefore cover the full request lifetime, not just setup.
		serverBudget += meetingArtifactChildBudget(size) + meetingOuterSlop
	}
	if serverBudget < meetingEventServerFloor {
		serverBudget = meetingEventServerFloor
	}
	return serverBudget + meetingOuterSlop
}

func boundedMeetingArtifactSizes(event map[string]any) ([]int64, bool) {
	values, ok := event["artifacts"].([]any)
	if !ok {
		return nil, true
	}
	sizes := make([]int64, 0, maxArtifactsPerEvent)
	var aggregate int64
	for _, value := range values {
		artifact, ok := value.(map[string]any)
		if !ok {
			return nil, false
		}
		if strings.TrimSpace(stringFromAny(artifact["source_ref"])) == "" {
			continue
		}
		if len(sizes) >= maxArtifactsPerEvent {
			return nil, false
		}
		size := int64Param(artifact, "source_size", -1)
		if size < 0 || size > maxMeetingArtifactSize || aggregate > maxMeetingArtifactEventSize-size {
			return nil, false
		}
		aggregate += size
		sizes = append(sizes, size)
	}
	return sizes, true
}

func meetingArtifactChildBudget(size int64) time.Duration {
	frames := (size + meetingArtifactFrameBytes - 1) / meetingArtifactFrameBytes
	budget := meetingArtifactSetupBudget + time.Duration(frames)*meetingArtifactFrameBudget
	if budget < 90*time.Second {
		budget = 90 * time.Second
	}
	return budget
}

func meetingArtifactRequestTimeout(params map[string]any) time.Duration {
	size := int64Param(params, "expected_size", -1)
	if size < 0 || size > maxMeetingArtifactSize {
		return requestExecutionTimeout
	}
	return meetingArtifactChildBudget(size) + meetingOuterSlop
}

// Meetnative event_id is optional. Stamp a deterministic connector-owned
// fallback before src_path is replaced by a fresh callback-scoped source_ref,
// so a producer retry retains one durable Salix source identity.
func ensureMeetingEventID(meetingID string, event map[string]any) error {
	if strings.TrimSpace(stringFromAny(event["event_id"])) != "" {
		return nil
	}
	raw, err := json.Marshal(map[string]any{"meeting_id": meetingID, "event": event})
	if err != nil {
		return err
	}
	digest := sha256.Sum256(raw)
	event["event_id"] = fmt.Sprintf("connector-%x", digest[:])
	return nil
}

// authorizeMeetingArtifacts replaces runtime-owned local paths with opaque,
// short-lived capabilities. This is the path that grants the Server access to
// an exact artifact emitted by the authenticated meeting runtime.
func eventHasLocalMeetingArtifacts(event map[string]any) bool {
	values, _ := event["artifacts"].([]any)
	for _, value := range values {
		artifact, _ := value.(map[string]any)
		kind := strings.TrimSpace(stringFromAny(artifact["kind"]))
		if strings.TrimSpace(stringFromAny(artifact["src_path"])) != "" && (kind == "audio" || kind == "transcript") {
			return true
		}
	}
	return false
}

func (c *connector) requireMeetingArtifactTransport(ctx context.Context, transport *runtimeTransport) error {
	if transport == nil {
		return errors.New("connector transport unavailable")
	}
	reply, err := c.sendRuntimeRequest(ctx, transport, nil, message{
		ID: "meetcap_" + randomHex(16), Type: "request", Method: "meeting_runtime_capabilities",
		Params: map[string]any{"artifact_transport": meetingArtifactTransport},
	})
	if err != nil {
		return err
	}
	if reply.Type == "error" || strings.TrimSpace(reply.Error) != "" {
		return fmt.Errorf("server rejected meeting artifact transport: %s", reply.Error)
	}
	result, _ := reply.Result.(map[string]any)
	versions, _ := result["artifact_transport_versions"].([]any)
	for _, version := range versions {
		if stringFromAny(version) == meetingArtifactTransport {
			return nil
		}
	}
	return errors.New("server does not advertise opaque meeting artifact transport")
}

func (c *connector) authorizeMeetingArtifacts(meetingID string, event map[string]any) ([]string, error) {
	values, ok := event["artifacts"].([]any)
	if !ok {
		return nil, nil
	}

	authorized := 0
	var aggregate int64
	refs := make([]string, 0, maxArtifactsPerEvent)
	for _, value := range values {
		artifact, ok := value.(map[string]any)
		if !ok {
			continue
		}
		path := strings.TrimSpace(stringFromAny(artifact["src_path"]))
		kind := strings.TrimSpace(stringFromAny(artifact["kind"]))
		if path == "" || (kind != "audio" && kind != "transcript") {
			continue
		}
		delete(artifact, "src_path")
		if authorized >= maxArtifactsPerEvent {
			artifact["source_error"] = "artifact_count_limit"
			continue
		}
		authorized++
		ref, size, err := c.registerMeetingArtifact(meetingID, path)
		if err != nil {
			if errors.Is(err, errMeetingArtifactTerminal) {
				artifact["source_error"] = "unavailable"
				continue
			}
			c.releaseMeetingArtifacts(refs)
			return nil, err
		}
		if aggregate+size > maxMeetingArtifactEventSize {
			c.releaseMeetingArtifacts([]string{ref})
			artifact["source_error"] = "artifact_event_size_limit"
			continue
		}
		aggregate += size
		refs = append(refs, ref)
		artifact["source_ref"] = ref
		artifact["source_size"] = size
	}
	return refs, nil
}

func (c *connector) registerMeetingArtifact(meetingID, path string) (string, int64, error) {
	if strings.TrimSpace(meetingID) == "" {
		return "", 0, errors.New("meeting_id is required")
	}
	full, err := filepath.Abs(filepath.Clean(path))
	if err != nil {
		return "", 0, err
	}
	f, err := os.Open(full)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return "", 0, err
	}
	if !st.Mode().IsRegular() {
		return "", 0, fmt.Errorf("%w: source is not a regular file", errMeetingArtifactTerminal)
	}
	if st.Size() < 0 || st.Size() > maxMeetingArtifactSize {
		return "", 0, fmt.Errorf("%w: source exceeds the bounded upload size", errMeetingArtifactTerminal)
	}
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", 0, err
	}
	var digest [sha256.Size]byte
	copy(digest[:], h.Sum(nil))

	now := time.Now()
	ref := "mart_" + randomHex(24)
	c.meetMu.Lock()
	defer c.meetMu.Unlock()
	c.pruneMeetingArtifactsLocked(now)
	if c.meetingArtifacts == nil {
		c.meetingArtifacts = map[string]meetingArtifact{}
	}
	if len(c.meetingArtifacts) >= maxMeetingArtifacts {
		return "", 0, errors.New("meeting artifact reference capacity exhausted")
	}
	c.meetingArtifacts[ref] = meetingArtifact{
		meetingID:  meetingID,
		path:       full,
		size:       st.Size(),
		modTime:    st.ModTime(),
		hash:       digest,
		registered: now,
	}
	return ref, st.Size(), nil
}

func (c *connector) releaseMeetingArtifacts(refs []string) {
	if len(refs) == 0 {
		return
	}
	c.meetMu.Lock()
	defer c.meetMu.Unlock()
	for _, ref := range refs {
		delete(c.meetingArtifacts, ref)
	}
}

func (c *connector) pruneMeetingArtifactsLocked(now time.Time) {
	for ref, artifact := range c.meetingArtifacts {
		if now.Sub(artifact.registered) > meetingArtifactTTL {
			delete(c.meetingArtifacts, ref)
		}
	}
}

func (c *connector) meetingArtifactForRead(meetingID, ref string) (meetingArtifact, error) {
	c.meetMu.Lock()
	defer c.meetMu.Unlock()
	c.pruneMeetingArtifactsLocked(time.Now())
	artifact, ok := c.meetingArtifacts[ref]
	if !ok || ref == "" {
		return meetingArtifact{}, errors.New("unknown or expired meeting artifact reference")
	}
	if artifact.meetingID != meetingID {
		return meetingArtifact{}, errors.New("meeting artifact reference does not belong to this meeting")
	}
	return artifact, nil
}

func (c *connector) methodMeetingArtifactReadStreamFrames(
	ctx context.Context,
	session *connectionSession,
	id string,
	params map[string]any,
) (map[string]any, error) {
	meetingID := stringParam(params, "meeting_id")
	ref := stringParam(params, "source_ref")
	if meetingID == "" || ref == "" {
		return nil, errors.New("meeting_id and source_ref are required")
	}
	artifact, err := c.meetingArtifactForRead(meetingID, ref)
	if err != nil {
		return nil, err
	}
	expectedSize := int64Param(params, "expected_size", -1)
	maxBytes := int64Param(params, "max_bytes", -1)
	if expectedSize < 0 || expectedSize != artifact.size {
		return nil, errors.New("meeting artifact declared size mismatch")
	}
	if maxBytes < 0 || artifact.size > maxBytes || maxBytes > maxMeetingArtifactSize {
		return nil, errors.New("meeting artifact exceeds server byte budget")
	}
	f, err := os.Open(artifact.path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return nil, err
	}
	if !st.Mode().IsRegular() || st.Size() != artifact.size || !st.ModTime().Equal(artifact.modTime) {
		return nil, errors.New("meeting artifact changed after authorization")
	}
	h := sha256.New()
	buf := make([]byte, 64*1024)
	seq := 0
	var sent int64
	reader := &io.LimitedReader{R: f, N: artifact.size}
	for reader.N > 0 {
		n, readErr := reader.Read(buf)
		if n > 0 {
			seq++
			sent += int64(n)
			_, _ = h.Write(buf[:n])
			frame := message{ID: id, Type: "stream", Stream: &streamData{
				Channel: "data", Data: encodeBase64(buf[:n]), EOF: false, Seq: seq,
			}}
			if err := session.sendReadStreamFrame(ctx, id, seq, frame); err != nil {
				return nil, err
			}
		}
		if readErr == io.EOF && reader.N > 0 {
			return nil, errors.New("meeting artifact changed while streaming")
		}
		if readErr != nil {
			return nil, readErr
		}
	}
	var extra [1]byte
	n, extraErr := f.Read(extra[:])
	finalStat, statErr := f.Stat()
	if statErr != nil {
		return nil, statErr
	}
	if sent != artifact.size || n != 0 || (extraErr != nil && extraErr != io.EOF) ||
		finalStat.Size() != artifact.size || !finalStat.ModTime().Equal(artifact.modTime) ||
		subtle.ConstantTimeCompare(h.Sum(nil), artifact.hash[:]) != 1 {
		return nil, errors.New("meeting artifact changed while streaming")
	}
	seq++
	if err := session.send(message{ID: id, Type: "stream", Stream: &streamData{
		Channel: "data", Data: "", EOF: true, Seq: seq,
	}}); err != nil {
		return nil, err
	}
	return map[string]any{"size": artifact.size}, nil
}

func encodeBase64(data []byte) string {
	return base64.StdEncoding.EncodeToString(data)
}

func (c *connector) tryAcquireMeetingEventSlot() bool {
	select {
	case c.runtimeProxySlots <- struct{}{}:
		return true
	default:
		return false
	}
}

func bearerToken(header string) string {
	const prefix = "Bearer "
	if strings.HasPrefix(header, prefix) {
		return strings.TrimSpace(header[len(prefix):])
	}
	return ""
}

func (c *connector) forwardMeetingEvent(ctx context.Context, transport *runtimeTransport, meetingID, runtimeToken string, ev map[string]any) error {
	if transport == nil {
		return errors.New("no active connector connection")
	}
	event := map[string]any{"meeting_id": meetingID}
	for k, v := range ev {
		event[k] = v
	}
	if runtimeToken != "" {
		event["runtime_token"] = runtimeToken
	}
	if stringFromAny(event["type"]) == "" {
		event["type"] = "joiner_event"
	}
	id := "meeting_event_" + randomHex(12)
	reply, err := c.sendRuntimeRequest(ctx, transport, nil, message{
		ID:     id,
		Type:   "request",
		Method: "meeting_runtime_event",
		Params: map[string]any{"event": event},
	})
	if err != nil {
		return err
	}
	if reply.Type == "error" || reply.Error != "" {
		return errors.New(defaultString(reply.Error, "meeting runtime event rejected"))
	}
	return nil
}
