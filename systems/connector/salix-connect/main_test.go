package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unicode/utf8"

	"github.com/gorilla/websocket"
	"github.com/oklog/ulid/v2"
	bolt "go.etcd.io/bbolt"
)

func TestCurrentBuildInfoPublishesDiagnosticReleaseWithoutTargetRevision(t *testing.T) {
	originalReleaseID := buildReleaseID
	t.Cleanup(func() { buildReleaseID = originalReleaseID })
	buildReleaseID = "server-bound-test"

	payload, err := json.Marshal(currentBuildInfo())
	if err != nil {
		t.Fatal(err)
	}
	var metadata map[string]any
	if err := json.Unmarshal(payload, &metadata); err != nil {
		t.Fatal(err)
	}
	if metadata["release_id"] != "server-bound-test" {
		t.Fatalf("release_id = %#v", metadata["release_id"])
	}
	if _, exists := metadata["target_revision"]; exists {
		t.Fatalf("binary metadata retains target_revision: %#v", metadata)
	}
}

func TestHelperRuntimeMetadataConnector(t *testing.T) {
	mode := os.Getenv("SALIX_TEST_RUNTIME_METADATA_CONNECTOR")
	if mode != "legacy" && mode != "malformed" {
		t.Skip("helper process only")
	}
	server, token := os.Getenv("SALIX_TEST_RUNTIME_METADATA_SERVER"), os.Getenv("SALIX_TEST_RUNTIME_METADATA_TOKEN")
	alias := os.Getenv("SALIX_TEST_RUNTIME_METADATA_ALIAS")
	u, err := url.Parse(strings.TrimRight(server, "/") + "/v1/connect")
	if err != nil {
		t.Fatal(err)
	}
	if u.Scheme == "http" {
		u.Scheme = "ws"
	} else if u.Scheme == "https" {
		u.Scheme = "wss"
	}
	query := u.Query()
	query.Set("name", "Legacy "+alias)
	query.Set("alias", alias)
	u.RawQuery = query.Encode()
	header := http.Header{}
	header.Set("Authorization", "Bearer "+token)
	header.Set(connectorInstanceHeader, mode+"-runtime-observability-e2e")
	ws, response, err := websocket.DefaultDialer.Dial(u.String(), header)
	if err != nil {
		if response != nil {
			t.Fatalf("metadata connector handshake status=%d: %v", response.StatusCode, err)
		}
		t.Fatal(err)
	}
	defer ws.Close()
	var connected message
	if err := ws.ReadJSON(&connected); err != nil || connected.Type != "connected" {
		t.Fatalf("metadata connector greeting=%#v err=%v", connected, err)
	}
	capabilities := map[string]any{"legacy_runtime_observability_e2e": true}
	if mode == "malformed" {
		ids := strings.Split(os.Getenv("SALIX_TEST_RUNTIME_METADATA_SESSION_IDS"), ",")
		identity := os.Getenv("SALIX_TEST_RUNTIME_METADATA_IDENTITY")
		capabilities = map[string]any{
			"runtime_probe": true, "valid_runtime_metadata_e2e": true,
			"agent_runtimes": []any{map[string]any{
				"kind": "external", "provider": "codex", "command": identity,
				"identity_material": identity,
				"session_snapshot": map[string]any{
					"schema_version": 1, "observed_at": time.Now().UnixMilli(),
					"session_count": len(ids), "session_ids": ids, "truncated": false,
				},
			}},
		}
	}
	var writeMu sync.Mutex
	write := func(payload any) error {
		writeMu.Lock()
		defer writeMu.Unlock()
		return ws.WriteJSON(payload)
	}
	if err := write(map[string]any{"type": "metadata", "skills": []any{}, "capabilities": capabilities}); err != nil {
		t.Fatal(err)
	}
	if ready := os.Getenv("SALIX_TEST_RUNTIME_METADATA_READY"); ready != "" {
		if err := os.WriteFile(ready, []byte("ready\n"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if mode == "malformed" {
		go func() {
			gate := os.Getenv("SALIX_TEST_RUNTIME_METADATA_GATE")
			for {
				if _, err := os.Stat(gate); err == nil {
					break
				}
				time.Sleep(10 * time.Millisecond)
			}
			_ = write(map[string]any{
				"type": "metadata", "skills": []any{},
				"capabilities": map[string]any{
					"invalid_runtime_metadata_e2e": true,
					"agent_runtimes":               []any{42},
				},
			})
			_ = write(message{Type: "heartbeat"})
			_ = os.WriteFile(os.Getenv("SALIX_TEST_RUNTIME_METADATA_SENT"), []byte("sent\n"), 0o600)
		}()
	}
	for {
		var incoming message
		if err := ws.ReadJSON(&incoming); err != nil {
			return
		}
		if incoming.Type == "heartbeat" {
			if err := write(message{Type: "heartbeat"}); err != nil {
				return
			}
		}
	}
}

func TestHelperSeedLegacyRuntimeState(t *testing.T) {
	root := os.Getenv("SALIX_TEST_SEED_LEGACY_RUNTIME_STATE")
	if root == "" {
		return
	}
	type oldRecoveryRecord struct {
		Provider     string         `json:"provider"`
		SessionID    string         `json:"session_id"`
		Token        string         `json:"runtime_capability_token"`
		Command      string         `json:"command"`
		Workspace    string         `json:"workspace"`
		SystemPrompt string         `json:"system_prompt,omitempty"`
		Payload      map[string]any `json:"runtime_payload"`
	}
	type oldRecoveryFile struct {
		Version int               `json:"version"`
		Session oldRecoveryRecord `json:"session"`
	}
	workspace := filepath.Join(root, "workspace")
	if err := os.MkdirAll(workspace, 0o700); err != nil {
		t.Fatal(err)
	}
	command := os.Getenv("SALIX_TEST_SEED_LEGACY_RUNTIME_COMMAND")
	if command == "" {
		command = "/bin/true"
	}
	raw, err := json.Marshal(oldRecoveryFile{Version: 1, Session: oldRecoveryRecord{
		Provider: "pi", SessionID: "session-upgrade", Token: "capability-upgrade",
		Command: command, Workspace: workspace, SystemPrompt: "upgrade e2e",
		Payload: map[string]any{"session_id": "pi-native"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(root, "external-runtime")
	legacyDir := filepath.Join(stateDir, "active")
	if err := os.MkdirAll(legacyDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := bolt.Open(filepath.Join(stateDir, "state.db"), 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Update(func(tx *bolt.Tx) error {
		bucket, err := tx.CreateBucketIfNotExists(externalRuntimeSessionsBucket)
		if err != nil {
			return err
		}
		if err := bucket.Put([]byte("pi\x00session-upgrade"), raw); err != nil {
			return err
		}
		if os.Getenv("SALIX_TEST_SEED_LEGACY_RUNTIME_EVENT") != "1" {
			return nil
		}
		events, err := tx.CreateBucketIfNotExists(externalRuntimeSessionEventsBucket)
		if err != nil {
			return err
		}
		const eventID = "01ARZ3NDEKTSV4RRFFQ69G5FAV"
		request := message{
			ID: eventID, Type: "request", Method: "external_runtime_event",
			Params: map[string]any{
				"event_id": eventID, "capability_token": "capability-upgrade",
				"event": map[string]any{
					"type": "operation", "provider": "pi", "name": "read_file",
					"operation_id": "legacy-read", "status": "end", "created_at": int64(1),
					"input": map[string]any{
						"path": "/workspace/report.txt", "offset": 7, "limit": 4096,
						"content": "legacy-input-body-must-not-survive",
					},
					"output": map[string]any{"text": strings.Repeat("legacy-read-body", 64*1024)},
					"issue":  "runtime_failed",
				},
			},
		}
		rawEvent, err := json.Marshal(request)
		if err != nil {
			return err
		}
		if err := events.Put([]byte(eventID), rawEvent); err != nil {
			return err
		}
		const invalidEventID = "00000000000000000000000000"
		invalidRequest := message{
			ID: invalidEventID, Type: "request", Method: "external_runtime_event",
			Params: map[string]any{
				"event_id": invalidEventID, "capability_token": "capability-upgrade",
				"event": map[string]any{
					"type": "operation", "provider": "pi", "created_at": int64(1),
				},
			},
		}
		rawInvalidEvent, err := json.Marshal(invalidRequest)
		if err != nil {
			return err
		}
		return events.Put([]byte(invalidEventID), rawInvalidEvent)
	}); err != nil {
		_ = db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(legacyDir, "session-upgrade.json"), raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestHelperInspectExternalRuntimeState(t *testing.T) {
	root := os.Getenv("SALIX_TEST_INSPECT_EXTERNAL_RUNTIME_STATE")
	output := os.Getenv("SALIX_TEST_INSPECT_EXTERNAL_RUNTIME_STATE_OUTPUT")
	if root == "" {
		return
	}
	if output == "" {
		t.Fatal("SALIX_TEST_INSPECT_EXTERNAL_RUNTIME_STATE_OUTPUT is required")
	}
	db, err := bolt.Open(filepath.Join(root, "external-runtime", "state.db"), 0o600, &bolt.Options{ReadOnly: true})
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	summary := map[string]any{}
	if err := db.View(func(tx *bolt.Tx) error {
		for _, name := range []string{
			"active-sessions-v1",
			"session-identities-v2",
			"active-executions-v2",
			"input-batches-v1",
			"session-events-v1",
		} {
			bucket := tx.Bucket([]byte(name))
			if bucket == nil {
				summary[name] = 0
				continue
			}
			summary[name] = bucket.Stats().KeyN
		}
		eventNames := map[string]int{}
		if bucket := tx.Bucket([]byte("session-events-v1")); bucket != nil {
			if err := bucket.ForEach(func(_, raw []byte) error {
				var request message
				if err := json.Unmarshal(raw, &request); err != nil {
					return err
				}
				name := stringParam(mapParam(request.Params, "event"), "name")
				if name != "" {
					eventNames[name]++
				}
				return nil
			}); err != nil {
				return err
			}
		}
		summary["event_names"] = eventNames
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(summary)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(output, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestHelperSeedRuntimeEventRetryFairness(t *testing.T) {
	root := os.Getenv("SALIX_TEST_SEED_RUNTIME_EVENT_RETRY_FAIRNESS")
	if root == "" {
		return
	}
	stateDir := filepath.Join(root, "external-runtime")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := bolt.Open(filepath.Join(stateDir, "state.db"), 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.Update(func(tx *bolt.Tx) error {
		outbox, err := tx.CreateBucketIfNotExists(externalRuntimeSessionEventsBucket)
		if err != nil {
			return err
		}
		for index := 0; index < externalRuntimeEventBatchMaxItems+2; index++ {
			id := ulid.MustNew(uint64(index+1), bytes.NewReader(make([]byte, 10))).String()
			token := "capability-retrying-session"
			state := "retrying"
			if index == externalRuntimeEventBatchMaxItems+1 {
				token = "capability-healthy-session"
				state = "healthy"
			}
			event, err := canonicalExternalRuntimeEvent(map[string]any{
				"type": "status", "provider": "pi", "state": state,
				"created_at": int64(index + 1),
			})
			if err != nil {
				return err
			}
			request := message{
				ID: id, Type: "request", Method: "external_runtime_event",
				Params: map[string]any{
					"event_id": id, "capability_token": token, "event": event,
				},
			}
			raw, err := json.Marshal(request)
			if err != nil {
				return err
			}
			if err := outbox.Put([]byte(id), raw); err != nil {
				return err
			}
		}
		for index := 0; index < externalRuntimeEventScanMaxItems+1; index++ {
			id := ulid.MustNew(uint64(externalRuntimeEventBatchMaxItems+3+index), bytes.NewReader(make([]byte, 10))).String()
			event, err := canonicalExternalRuntimeEvent(map[string]any{
				"type": "status", "provider": "pi", "state": "retrying-tail",
				"created_at": int64(externalRuntimeEventBatchMaxItems + 3 + index),
			})
			if err != nil {
				return err
			}
			request := message{
				ID: id, Type: "request", Method: "external_runtime_event",
				Params: map[string]any{
					"event_id": id, "capability_token": "capability-retrying-session",
					"event": event,
				},
			}
			raw, err := json.Marshal(request)
			if err != nil {
				return err
			}
			if err := outbox.Put([]byte(id), raw); err != nil {
				return err
			}
		}
		healthyTailID := ulid.MustNew(
			uint64(externalRuntimeEventBatchMaxItems+externalRuntimeEventScanMaxItems+4),
			bytes.NewReader(make([]byte, 10)),
		).String()
		healthyTail, err := canonicalExternalRuntimeEvent(map[string]any{
			"type": "status", "provider": "pi", "state": "healthy-tail",
			"created_at": int64(externalRuntimeEventBatchMaxItems + externalRuntimeEventScanMaxItems + 4),
		})
		if err != nil {
			return err
		}
		rawHealthyTail, err := json.Marshal(message{
			ID: healthyTailID, Type: "request", Method: "external_runtime_event",
			Params: map[string]any{
				"event_id": healthyTailID, "capability_token": "capability-healthy-session",
				"event": healthyTail,
			},
		})
		if err != nil {
			return err
		}
		if err := outbox.Put([]byte(healthyTailID), rawHealthyTail); err != nil {
			return err
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestHelperSeedLegacyRuntimeLifecycleState(t *testing.T) {
	root := os.Getenv("SALIX_TEST_SEED_LEGACY_RUNTIME_LIFECYCLE_STATE")
	if root == "" {
		return
	}
	completedCommand := os.Getenv("SALIX_TEST_SEED_LEGACY_COMPLETED_COMMAND")
	activeCommand := os.Getenv("SALIX_TEST_SEED_LEGACY_ACTIVE_COMMAND")
	ackedActiveCommand := os.Getenv("SALIX_TEST_SEED_LEGACY_ACKED_ACTIVE_COMMAND")
	if completedCommand == "" || activeCommand == "" || ackedActiveCommand == "" {
		t.Fatal("legacy lifecycle seed commands are required")
	}
	stateDir := filepath.Join(root, "external-runtime")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := bolt.Open(filepath.Join(stateDir, "state.db"), 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	records := []externalRuntimeRecoveryRecord{
		{
			Provider: "pi", SessionID: "session-legacy-completed",
			DispatchID: "dispatch-legacy-completed", ExecutionID: "execution-legacy-completed",
			Token: "capability-legacy-completed", Command: completedCommand,
			Workspace: filepath.Join(root, "workspace-completed"), SystemPrompt: "legacy migration e2e",
			Payload: map[string]any{"session_id": "pi-native-completed"},
		},
		{
			Provider: "pi", SessionID: "session-legacy-active",
			DispatchID: "dispatch-legacy-active", ExecutionID: "execution-legacy-active",
			Token: "capability-legacy-active", Command: activeCommand,
			Workspace: filepath.Join(root, "workspace-active"), SystemPrompt: "legacy migration e2e",
			Payload: map[string]any{"session_id": "pi-native-active"},
		},
		{
			Provider: "pi", SessionID: "session-legacy-acked-active",
			DispatchID: "dispatch-legacy-acked-active", ExecutionID: "execution-legacy-acked-active",
			Token: "capability-legacy-acked-active", Command: ackedActiveCommand,
			Workspace: filepath.Join(root, "workspace-acked-active"), SystemPrompt: "legacy migration e2e",
			Payload: map[string]any{"session_id": "pi-native-acked-active"},
		},
	}
	for _, record := range records {
		if err := os.MkdirAll(record.Workspace, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	events := []struct {
		id        string
		record    externalRuntimeRecoveryRecord
		name      string
		workState string
	}{
		{"01ARZ3NDEKTSV4RRFFQ69G5FAA", records[0], "agent_start", "running"},
		{"01ARZ3NDEKTSV4RRFFQ69G5FAB", records[0], "agent_settled", "settled"},
		{"01ARZ3NDEKTSV4RRFFQ69G5FAC", records[1], "agent_start", "running"},
		// records[2] is also running. Its running event was already durably ACKed by
		// the Server, so the old active-sessions-v1 recovery obligation is the only
		// remaining Connector-local fact and the event is no longer in the outbox.
	}
	if err := db.Update(func(tx *bolt.Tx) error {
		legacy, err := tx.CreateBucketIfNotExists(externalRuntimeSessionsBucket)
		if err != nil {
			return err
		}
		outbox, err := tx.CreateBucketIfNotExists(externalRuntimeSessionEventsBucket)
		if err != nil {
			return err
		}
		inputBatches, err := tx.CreateBucketIfNotExists(externalRuntimeInputBatchesBucket)
		if err != nil {
			return err
		}
		for _, record := range records {
			raw, err := json.Marshal(externalRuntimeRecoveryFile{Version: 1, Session: record})
			if err != nil {
				return err
			}
			if err := legacy.Put([]byte(record.key()), raw); err != nil {
				return err
			}
		}
		for _, item := range events {
			event, err := canonicalExternalRuntimeEvent(map[string]any{
				"type": "status", "provider": "pi", "name": item.name,
				"state": item.workState, "created_at": int64(1),
				"dispatch_id":  item.record.DispatchID,
				"execution_id": item.record.ExecutionID,
				"work_state":   item.workState,
			})
			if err != nil {
				return err
			}
			request := message{ID: item.id, Type: "request", Method: "external_runtime_event", Params: map[string]any{
				"event_id": item.id, "capability_token": item.record.Token, "event": event,
			}}
			raw, err := json.Marshal(request)
			if err != nil {
				return err
			}
			if err := outbox.Put([]byte(item.id), raw); err != nil {
				return err
			}
		}
		// The native runtime accepted and completed this exact dispatch, but the
		// Connector crashed before deleting its at-least-once input batch. Exact
		// terminal lifecycle evidence must dominate that stale pending record.
		stalePending := externalRuntimeInputBatch{
			Version: 1,
			Session: records[0],
			Messages: []map[string]any{{
				"id":      "message-legacy-completed-stale-pending",
				"role":    "user",
				"content": "already completed before the migration crash window",
			}},
		}
		// agent_runtime_input is durably ACKed before the background native Send
		// allocates an execution id, so real input-batches-v1 records have none.
		stalePending.Session.ExecutionID = ""
		raw, err := json.Marshal(stalePending)
		if err != nil {
			return err
		}
		if err := inputBatches.Put([]byte(stalePending.key()), raw); err != nil {
			return err
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestHelperSeedLegacyAsyncInputBatch(t *testing.T) {
	root := os.Getenv("SALIX_TEST_SEED_LEGACY_ASYNC_INPUT")
	if root == "" {
		return
	}
	command := os.Getenv("SALIX_TEST_SEED_LEGACY_ASYNC_COMMAND")
	if command == "" {
		t.Fatal("SALIX_TEST_SEED_LEGACY_ASYNC_COMMAND is required")
	}
	const toolCallID = "call-legacy-oversized"
	const summary = "async tool env.exec completed for call-legacy-oversized"
	content, err := json.Marshal(map[string]any{
		"type":         "tool_call_completed",
		"tool_call_id": toolCallID,
		"tool_name":    "env.exec",
		"status":       "completed",
		"error":        false,
		"summary":      summary,
		"source_refs": map[string]any{
			"tool_call_id": toolCallID,
			"tool_name":    "env.exec",
			"status":       "completed",
		},
		"result": map[string]any{
			"status":  "completed",
			"content": strings.Repeat("x", 1_100_000) + "LEGACY_RESULT_END",
		},
		"message": "tool call completed after returning early; short result is included in this notification",
	})
	if err != nil {
		t.Fatal(err)
	}
	historicalFailedContent, err := json.Marshal(map[string]any{
		"type":         "tool_call_failed",
		"tool_call_id": "call-legacy-oversized-failed",
		"tool_name":    "env.exec",
		// Before bounded result pages, Waits defaulted an omitted result status
		// independently from AsyncToolResults' outer failed status.
		"status":  "completed",
		"error":   true,
		"summary": "async tool env.exec completed for call-legacy-oversized-failed",
		"source_refs": map[string]any{
			"tool_call_id": "call-legacy-oversized-failed",
			"tool_name":    "env.exec",
			"status":       "completed",
		},
		"result": map[string]any{
			"error":   true,
			"content": strings.Repeat("y", 1_100_000) + "LEGACY_FAILED_RESULT_END",
		},
		"message": "tool call failed after returning early; short error details are included in this notification",
	})
	if err != nil {
		t.Fatal(err)
	}
	currentPage, err := json.Marshal(map[string]any{
		"type":         "tool_call_completed",
		"tool_call_id": "call-current-page",
		"tool_name":    "env.exec",
		"status":       "completed",
		"error":        false,
		"result_page": map[string]any{
			"encoding":      "json",
			"offset":        0,
			"content":       "CURRENT_PAGE_PREVIEW",
			"content_chars": 20,
			"total_chars":   40,
			"truncated":     true,
			"next_offset":   20,
		},
		"message": "current bounded result preview",
	})
	if err != nil {
		t.Fatal(err)
	}
	workspace := filepath.Join(root, "workspace")
	if err := os.MkdirAll(workspace, 0o700); err != nil {
		t.Fatal(err)
	}
	batch := externalRuntimeInputBatch{
		Version: 1,
		Session: externalRuntimeRecoveryRecord{
			Provider:     "codex",
			SessionID:    "session-legacy-oversized-async",
			DispatchID:   "batch-legacy-oversized-async",
			Token:        "capability-session-legacy-oversized-async",
			Command:      command,
			Workspace:    workspace,
			SystemPrompt: "legacy oversized async completion recovery e2e",
			Payload:      map[string]any{},
		},
		Messages: []map[string]any{
			{
				"id":                  "message-legacy-oversized-async",
				"role":                "runtime",
				"kind":                "runtime_message",
				"runtime_message_id":  "tool-call-result:" + toolCallID,
				"type":                "tool_call_completed",
				"summary":             summary,
				"source_tool_call_id": toolCallID,
				"source_message_id":   "tool-call-result:" + toolCallID,
				"source_refs": map[string]any{
					"tool_call_id": toolCallID,
					"tool_name":    "env.exec",
					"status":       "completed",
				},
				"content":    string(content),
				"created_at": 1_721_056_896,
			},
			{
				"id":                  "message-legacy-oversized-failed",
				"role":                "runtime",
				"kind":                "runtime_message",
				"runtime_message_id":  "tool-call-result:call-legacy-oversized-failed",
				"type":                "tool_call_failed",
				"summary":             "async tool env.exec failed for call-legacy-oversized-failed",
				"source_tool_call_id": "call-legacy-oversized-failed",
				"source_message_id":   "tool-call-result:call-legacy-oversized-failed",
				"source_refs": map[string]any{
					"tool_call_id": "call-legacy-oversized-failed",
					"tool_name":    "env.exec",
					"status":       "failed",
				},
				"content":    string(historicalFailedContent),
				"created_at": 1_721_056_897,
			},
			{
				"id":         "message-ordinary-user",
				"role":       "user",
				"content":    "ORDINARY_USER_INPUT_UNCHANGED",
				"created_at": 1_721_056_898,
			},
			{
				"id":                  "message-current-page",
				"role":                "runtime",
				"kind":                "runtime_message",
				"runtime_message_id":  "tool-call-result:call-current-page",
				"type":                "tool_call_completed",
				"source_tool_call_id": "call-current-page",
				"source_message_id":   "tool-call-result:call-current-page",
				"content":             string(currentPage),
				"created_at":          1_721_056_899,
			},
		},
	}
	raw, err := json.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	stateDir := filepath.Join(root, "external-runtime")
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		t.Fatal(err)
	}
	db, err := bolt.Open(filepath.Join(stateDir, "state.db"), 0o600, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := db.Update(func(tx *bolt.Tx) error {
		bucket, err := tx.CreateBucketIfNotExists(externalRuntimeInputBatchesBucket)
		if err != nil {
			return err
		}
		return bucket.Put([]byte(batch.key()), raw)
	}); err != nil {
		_ = db.Close()
		t.Fatal(err)
	}
	if err := db.Close(); err != nil {
		t.Fatal(err)
	}
}

type blockingCloser struct {
	started chan struct{}
	release chan struct{}
	once    sync.Once
}

type blockingCloseWriteCloser struct {
	*blockingCloser
}

func (closer *blockingCloseWriteCloser) Write(data []byte) (int, error) {
	return len(data), nil
}

func dialVMWebSocket(t *testing.T, wsURL string) *websocket.Conn {
	t.Helper()
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	var metadata message
	if err := ws.ReadJSON(&metadata); err != nil || metadata.Type != "metadata" {
		_ = ws.Close()
		t.Fatalf("metadata=%#v err=%v", metadata, err)
	}
	return ws
}

func waitForCondition(t *testing.T, description string, condition func() bool) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if condition() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", description)
}

func dispatchForTest(
	c *connector,
	ctx context.Context,
	id, method string,
	params map[string]any,
	send func(message) error,
) (any, error) {
	session := newConnectionSession(c, ctx, func(_ context.Context, m message) error { return send(m) }, nil)
	defer session.close(context.Canceled)
	return c.dispatchSession(ctx, session, id, method, params)
}

func activateRuntimeTransportForTest(c *connector, send func(message) error) func() {
	return c.activateRuntimeTransport(func(_ context.Context, m message) error {
		return send(m)
	})
}

func (closer *blockingCloser) Close() error {
	closer.once.Do(func() { close(closer.started) })
	<-closer.release
	return nil
}

func TestRunRemoteOnceRepliesToHeartbeat(t *testing.T) {
	isolateHostRuntimeCommands(t)

	messages := make(chan message, 2)
	upgrader := websocket.Upgrader{}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/connect" {
			http.NotFound(w, r)
			return
		}
		if got := r.Header.Get("Authorization"); got != "Bearer test-token" {
			http.Error(w, "bad authorization", http.StatusUnauthorized)
			return
		}

		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade websocket: %v", err)
			return
		}
		defer ws.Close()

		var meta message
		if err := ws.ReadJSON(&meta); err != nil {
			t.Errorf("read metadata: %v", err)
			return
		}
		messages <- meta

		if err := ws.WriteJSON(message{Type: "heartbeat"}); err != nil {
			t.Errorf("write heartbeat: %v", err)
			return
		}

		var rawReply map[string]json.RawMessage
		if err := ws.ReadJSON(&rawReply); err != nil {
			t.Errorf("read heartbeat reply: %v", err)
			return
		}
		if _, polluted := rawReply["skills"]; polluted {
			t.Errorf("heartbeat carried metadata-only skills: %s", rawReply["skills"])
			return
		}
		var reply message
		encodedReply, _ := json.Marshal(rawReply)
		if err := json.Unmarshal(encodedReply, &reply); err != nil {
			t.Errorf("decode heartbeat reply: %v", err)
			return
		}
		messages <- reply

		_ = ws.WriteMessage(
			websocket.CloseMessage,
			websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""),
		)
	}))
	defer server.Close()

	connector, err := newConnector(config{
		server: server.URL,
		token:  "test-token",
		name:   "laptop",
		root:   t.TempDir(),
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	errs := make(chan error, 1)
	go func() {
		errs <- connector.runRemoteOnce(context.Background())
	}()

	meta := receiveMessage(t, messages)
	if meta.Type != "metadata" {
		t.Fatalf("first connector frame type = %q, want metadata", meta.Type)
	}

	reply := receiveMessage(t, messages)
	if reply.Type != "heartbeat" {
		t.Fatalf("heartbeat reply type = %q, want heartbeat", reply.Type)
	}

	select {
	case <-errs:
	case <-time.After(2 * time.Second):
		t.Fatal("connector did not exit after server close")
	}
}

func TestRemoteWebSocketBlockedDataSendFailsWithinWriteDeadline(t *testing.T) {
	isolateHostRuntimeCommands(t)

	previousTimeout := webSocketWriteTimeout
	webSocketWriteTimeout = 50 * time.Millisecond
	defer func() { webSocketWriteTimeout = previousTimeout }()

	root := t.TempDir()
	payload := make([]byte, maxFile)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "large.bin"), payload, 0o600); err != nil {
		t.Fatal(err)
	}

	upgrader := websocket.Upgrader{}
	requestSent := make(chan struct{})
	releaseServer := make(chan struct{})
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		var metadata message
		if ws.ReadJSON(&metadata) != nil {
			return
		}
		if tcp, ok := ws.UnderlyingConn().(*net.TCPConn); ok {
			_ = tcp.SetReadBuffer(4 * 1024)
		}
		if ws.WriteJSON(message{
			ID: "blocked-send", Type: "request", Method: "read",
			Params: map[string]any{"path": "large.bin"},
		}) != nil {
			return
		}
		close(requestSent)
		<-releaseServer
	}))
	defer server.Close()
	defer close(releaseServer)

	connector, err := newConnector(config{
		root: root, name: "blocked-data-send", server: server.URL,
		token: "token", systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	result := make(chan error, 1)
	go func() { result <- connector.runRemoteOnce(context.Background()) }()
	select {
	case <-requestSent:
	case <-time.After(10 * time.Second):
		t.Fatal("server did not send the large read request")
	}
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("blocked websocket send returned no error")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("blocked websocket send outlived its write deadline")
	}
}

func TestRuntimeAgentCarrierContract(t *testing.T) {
	for _, carrier := range []string{"connected_device", "cloudflare", "agent_vmm"} {
		t.Run(carrier, func(t *testing.T) {
			isolateHostRuntimeCommands(t)
			agent, err := newConnector(config{
				runtimeAgent:       true,
				root:               t.TempDir(),
				name:               "compute-runtime-agent-" + carrier,
				systemInfoInterval: 0,
			})
			if err != nil {
				t.Fatalf("new runtime agent: %v", err)
			}

			server := httptest.NewServer(agent.vmHTTPHandler(context.Background()))
			defer server.Close()
			ready := httpGetJSON(t, server.URL+"/readyz")
			if ready["ready"] != true || ready["workspace_marked"] != true {
				t.Fatalf("runtime agent ready payload = %#v", ready)
			}

			wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
			ws := dialVMWebSocket(t, wsURL)
			defer ws.Close()
			if err := ws.WriteJSON(message{
				ID: "carrier-contract", Type: "request", Method: "exec",
				Params: map[string]any{"command": "printf " + carrier, "timeout": 5},
			}); err != nil {
				t.Fatal(err)
			}
			var reply message
			if err := ws.ReadJSON(&reply); err != nil {
				t.Fatal(err)
			}
			result, ok := reply.Result.(map[string]any)
			if reply.ID != "carrier-contract" || reply.Type != "response" || !ok || result["stdout"] != carrier {
				t.Fatalf("runtime agent %s reply = %#v", carrier, reply)
			}
		})
	}
}

func newVMWebSocketTestConnector(t *testing.T, cfg config) (*connector, error) {
	t.Helper()
	connector, err := newConnector(cfg)
	if err == nil {
		t.Cleanup(connector.closeExternalRuntimes)
	}
	return connector, err
}

func isolateHostRuntimeCommands(t *testing.T) {
	t.Helper()
	t.Setenv("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
	previousBundlePaths := codexAppBundleCommandPaths
	codexAppBundleCommandPaths = func() []string { return nil }
	t.Cleanup(func() { codexAppBundleCommandPaths = previousBundlePaths })
}

func TestVMServerHealthReadyAndConnect(t *testing.T) {
	isolateHostRuntimeCommands(t)

	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer:           true,
		root:               t.TempDir(),
		name:               "cloud-vm",
		systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()

	health := httpGetJSON(t, server.URL+"/healthz")
	if health["ok"] != true {
		t.Fatalf("health ok = %v", health["ok"])
	}
	ready := httpGetJSON(t, server.URL+"/readyz")
	if ready["ready"] != true || ready["workspace_marked"] != true ||
		ready["connector_build_revision"] != connectorBuildRevision {
		t.Fatalf("ready payload = %#v", ready)
	}

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial vm connect: %v", err)
	}
	defer ws.Close()

	var meta message
	if err := ws.ReadJSON(&meta); err != nil {
		t.Fatalf("read metadata: %v", err)
	}
	if meta.Type != "metadata" {
		t.Fatalf("first frame = %q, want metadata", meta.Type)
	}

	if err := ws.WriteJSON(message{Type: "connected", ConnectorRunID: "run-vm"}); err != nil {
		t.Fatalf("write connected: %v", err)
	}
	acknowledgeExternalInputCatchup(t, ws)
	if err := ws.WriteJSON(message{
		ID:     "req-1",
		Type:   "request",
		Method: "exec",
		Params: map[string]any{"command": "printf ok", "timeout": 5},
	}); err != nil {
		t.Fatalf("write exec request: %v", err)
	}

	var reply message
	if err := ws.ReadJSON(&reply); err != nil {
		t.Fatalf("read exec reply: %v", err)
	}
	if reply.ID != "req-1" || reply.Type != "response" {
		t.Fatalf("reply = %#v", reply)
	}
	result, ok := reply.Result.(map[string]any)
	if !ok || result["stdout"] != "ok" {
		t.Fatalf("exec result = %#v", reply.Result)
	}
}

func TestVMWebSocketMetadataAlwaysCarriesEmptySkills(t *testing.T) {
	isolateHostRuntimeCommands(t)

	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: t.TempDir(), name: "metadata-skills", systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	var raw map[string]json.RawMessage
	if err := ws.ReadJSON(&raw); err != nil {
		t.Fatal(err)
	}
	skills, present := raw["skills"]
	if !present {
		t.Fatal("metadata omitted skills, so reconnect cannot clear stale server skills")
	}
	var decoded []any
	if err := json.Unmarshal(skills, &decoded); err != nil || len(decoded) != 0 {
		t.Fatalf("skills=%s decoded=%#v err=%v", skills, decoded, err)
	}
}

func TestVMWebSocketGenerationsDoNotLeakParentContextWatchers(t *testing.T) {
	// Keep host-installed agent binaries out of the connector inventory probe;
	// this test exercises WebSocket generation cleanup, not runtime readiness.
	isolateHostRuntimeCommands(t)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: t.TempDir(), name: "generation-watchers", systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(ctx))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	baseline := connectionWatcherCount(t)

	for index := 0; index < 20; index++ {
		ws := dialVMWebSocket(t, wsURL)
		if err := ws.Close(); err != nil {
			t.Fatal(err)
		}
		waitForCondition(t, "closed WebSocket generation", func() bool {
			connector.connectionMu.Lock()
			defer connector.connectionMu.Unlock()
			return connector.activeConnection == nil
		})
	}

	waitForCondition(t, "connection parent-context watchers to drain", func() bool {
		return connectionWatcherCount(t) <= baseline
	})
}

func connectionWatcherCount(t *testing.T) int {
	t.Helper()
	var stacks bytes.Buffer
	if err := pprof.Lookup("goroutine").WriteTo(&stacks, 2); err != nil {
		t.Fatal(err)
	}
	return bytes.Count(stacks.Bytes(), []byte("newConnectionSession.func1"))
}

func TestVMWebSocketReplacementClosesOldGenerationAndServesNewRPC(t *testing.T) {
	isolateHostRuntimeCommands(t)

	lateMarker := filepath.Join(t.TempDir(), "late-old-request")
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer:           true,
		root:               t.TempDir(),
		name:               "replacement-vm",
		systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"

	oldWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer oldWS.Close()
	var metadata message
	if err := oldWS.ReadJSON(&metadata); err != nil || metadata.Type != "metadata" {
		t.Fatalf("old metadata: %#v err=%v", metadata, err)
	}
	if err := oldWS.WriteJSON(message{Type: "connected", ConnectorRunID: "old-run"}); err != nil {
		t.Fatal(err)
	}
	acknowledgeExternalInputCatchup(t, oldWS)
	if err := oldWS.WriteJSON(message{
		ID:     "old-exec",
		Type:   "request",
		Method: "exec",
		Params: map[string]any{"command": "sleep 30", "timeout": 30},
	}); err != nil {
		t.Fatal(err)
	}

	newWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer newWS.Close()
	metadata = message{}
	if err := newWS.ReadJSON(&metadata); err != nil || metadata.Type != "metadata" {
		t.Fatalf("new metadata: %#v err=%v", metadata, err)
	}
	_ = oldWS.WriteJSON(message{
		ID: "late-old-exec", Type: "request", Method: "exec",
		Params: map[string]any{"command": "printf late > " + shellQuote(lateMarker)},
	})
	if err := newWS.WriteJSON(message{Type: "connected", ConnectorRunID: "new-run"}); err != nil {
		t.Fatal(err)
	}
	acknowledgeExternalInputCatchup(t, newWS)
	if err := newWS.WriteJSON(message{
		ID:     "new-list",
		Type:   "request",
		Method: "process_list",
	}); err != nil {
		t.Fatal(err)
	}
	var reply message
	if err := newWS.ReadJSON(&reply); err != nil {
		t.Fatal(err)
	}
	if reply.ID != "new-list" || reply.Type != "response" {
		t.Fatalf("replacement reply = %#v", reply)
	}

	_ = oldWS.SetReadDeadline(time.Now().Add(time.Second))
	if err := oldWS.ReadJSON(&reply); err == nil {
		t.Fatalf("old generation remained readable after replacement: %#v", reply)
	}
	if runID, _, _ := connector.connectionIdentity(); runID != "new-run" {
		t.Fatalf("stale generation replaced active identity: %q", runID)
	}
	time.Sleep(50 * time.Millisecond)
	if fileExists(lateMarker) {
		t.Fatal("old generation admitted a request after replacement metadata was visible")
	}
}

func acknowledgeExternalInputCatchup(t *testing.T, ws *websocket.Conn) {
	t.Helper()
	var request message
	if err := ws.ReadJSON(&request); err != nil {
		t.Fatalf("read reconnect catch-up request: %v", err)
	}
	if request.Type != "request" || request.Method != "agent_runtime_catchup" || request.ID == "" {
		t.Fatalf("reconnect catch-up request = %#v", request)
	}
	if err := ws.WriteJSON(message{
		ID: request.ID, Type: "response", Result: map[string]any{"accepted": true},
	}); err != nil {
		t.Fatalf("ack reconnect catch-up request: %v", err)
	}
}

func TestVMWebSocketReplacementRejectsOldRequestAlreadyPastReadLoopActiveCheck(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	marker := filepath.Join(root, "old-window-marker")
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: root, name: "replacement-admission-window", systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	admissionEntered := make(chan struct{})
	releaseAdmission := make(chan struct{})
	replacementPublished := make(chan struct{})
	releaseReplacement := make(chan struct{})
	connector.beforeRequestAdmission = func(_ *connectionSession, msg message) {
		if msg.ID == "old-window-write" {
			close(admissionEntered)
			<-releaseAdmission
		}
	}
	connector.afterConnectionPublished = func(_ *connectionSession) {
		close(replacementPublished)
		<-releaseReplacement
	}

	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	oldWS := dialVMWebSocket(t, wsURL)
	defer oldWS.Close()
	if err := oldWS.WriteJSON(message{
		ID: "old-window-write", Type: "request", Method: "write",
		Params: map[string]any{"path": "old-window-marker", "content": "stale"},
	}); err != nil {
		t.Fatal(err)
	}
	select {
	case <-admissionEntered:
	case <-time.After(time.Second):
		t.Fatal("old request did not reach the admission boundary")
	}

	newWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer newWS.Close()
	select {
	case <-replacementPublished:
	case <-time.After(time.Second):
		t.Fatal("replacement was not published")
	}
	close(releaseAdmission)
	time.Sleep(50 * time.Millisecond)
	if fileExists(marker) {
		t.Fatal("old generation produced a side effect after replacement was published")
	}
	close(releaseReplacement)
	var frame message
	if err := newWS.ReadJSON(&frame); err != nil || frame.Type != "metadata" {
		t.Fatalf("replacement metadata=%#v err=%v", frame, err)
	}
	if err := newWS.WriteJSON(message{ID: "new-after-window", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	if err := newWS.ReadJSON(&frame); err != nil || frame.ID != "new-after-window" || frame.Type != "response" {
		t.Fatalf("replacement reply=%#v err=%v", frame, err)
	}
}

func TestVMWebSocketReplacementClosesOldReplySinkBeforePublishingNewGeneration(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	fifo := filepath.Join(root, "blocked-read.fifo")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: root, name: "replacement-reply-sink", systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	replacementPublished := make(chan struct{})
	releaseReplacement := make(chan struct{})
	connector.afterConnectionPublished = func(_ *connectionSession) {
		close(replacementPublished)
		<-releaseReplacement
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	oldWS := dialVMWebSocket(t, wsURL)
	defer oldWS.Close()
	if err := oldWS.WriteJSON(message{
		ID: "old-blocked-read", Type: "request", Method: "read",
		Params: map[string]any{"path": "blocked-read.fifo"},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "old request admission", func() bool { return len(connector.requestSlots) == 1 })

	newWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer newWS.Close()
	select {
	case <-replacementPublished:
	case <-time.After(time.Second):
		t.Fatal("replacement was not published")
	}

	writer, err := os.OpenFile(fifo, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write([]byte("finished")); err != nil {
		t.Fatal(err)
	}
	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "actor-owned old request completion", func() bool { return len(connector.requestSlots) == 0 })

	_ = oldWS.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	var frame message
	if err := oldWS.ReadJSON(&frame); err == nil {
		t.Fatalf("old reply sink remained writable after replacement publication: %#v", frame)
	}
	close(releaseReplacement)
	if err := newWS.ReadJSON(&frame); err != nil || frame.Type != "metadata" {
		t.Fatalf("replacement metadata=%#v err=%v", frame, err)
	}
	if err := newWS.WriteJSON(message{ID: "new-after-old-complete", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	if err := newWS.ReadJSON(&frame); err != nil || frame.ID != "new-after-old-complete" || frame.Type != "response" {
		t.Fatalf("replacement reply=%#v err=%v", frame, err)
	}
}

func TestVMWebSocketReconnectDoesNotCancelActorOwnedExec(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	started := filepath.Join(root, "exec-started")
	marker := filepath.Join(root, "exec-finished")
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	command := "printf started > " + shellQuote(started) + "; sleep 0.4; printf finished > " + shellQuote(marker)
	if err := ws.WriteJSON(message{
		ID: "actor-owned-exec", Type: "request", Method: "exec",
		Params: map[string]any{"command": command, "timeout": 30},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "actor-owned exec start", func() bool { return fileExists(started) })
	if err := ws.Close(); err != nil {
		t.Fatal(err)
	}
	replacement := dialVMWebSocket(t, wsURL)
	defer replacement.Close()
	if err := replacement.WriteJSON(message{ID: "after-reconnect", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	var frame message
	if err := replacement.ReadJSON(&frame); err != nil || frame.ID != "after-reconnect" || frame.Type != "response" {
		t.Fatalf("replacement reply=%#v err=%v", frame, err)
	}
	waitForCondition(t, "actor-owned exec completion", func() bool { return fileExists(marker) })
	waitForCondition(t, "actor-owned exec cleanup", func() bool { return len(connector.requestSlots) == 0 })
}

func TestVMReplacementDuringComputerUseLaunchDoesNotPoisonConnector(t *testing.T) {
	isolateHostRuntimeCommands(t)

	if runtime.GOOS != "darwin" {
		t.Skip("computer_use is macOS-only")
	}
	root := t.TempDir()
	helperApp := filepath.Join(root, "Comma Computer Use.app")
	if err := os.MkdirAll(helperApp, 0o755); err != nil {
		t.Fatal(err)
	}
	started := filepath.Join(root, "open-started")
	binDir := filepath.Join(root, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	openScript := filepath.Join(binDir, "open")
	if err := os.WriteFile(openScript, []byte("#!/bin/sh\nprintf started > \"$SALIX_OPEN_STARTED\"\n/bin/sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", binDir)
	t.Setenv("SALIX_OPEN_STARTED", started)
	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: root, systemInfoInterval: 0,
		computerUseHelperApp:  helperApp,
		computerUseSocketPath: filepath.Join(root, "computer-use.sock"),
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	oldWS := dialVMWebSocket(t, wsURL)
	defer oldWS.Close()
	if err := oldWS.WriteJSON(message{
		ID: "blocked-computer-use", Type: "request", Method: "computer_use",
		Params: map[string]any{"action": "status"},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "computer_use helper launch", func() bool { return fileExists(started) })
	replacement := dialVMWebSocket(t, wsURL)
	defer replacement.Close()
	time.Sleep(connectionDrainTimeout + 250*time.Millisecond)
	if fatal := connector.connectorFatal(); fatal != nil {
		t.Fatalf("canceled computer_use launch poisoned connector: %v", fatal)
	}
	if err := replacement.WriteJSON(message{ID: "after-computer-use-replacement", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	var frame message
	if err := replacement.ReadJSON(&frame); err != nil || frame.ID != "after-computer-use-replacement" || frame.Type != "response" {
		t.Fatalf("replacement reply=%#v err=%v", frame, err)
	}
}

func TestVMWebSocketControlFrameOvertakesQueuedDataFrames(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	largePath := filepath.Join(root, "large.txt")
	if err := os.WriteFile(largePath, bytes.Repeat([]byte("x"), maxFile), 0o600); err != nil {
		t.Fatal(err)
	}
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	defer ws.Close()
	if tcp, ok := ws.UnderlyingConn().(*net.TCPConn); ok {
		_ = tcp.SetReadBuffer(1024)
	}

	for index := 0; index < 3; index++ {
		if err := ws.WriteJSON(message{
			ID: fmt.Sprintf("large-%d", index), Type: "request", Method: "read",
			Params: map[string]any{"path": "large.txt"},
		}); err != nil {
			t.Fatal(err)
		}
	}
	waitForCondition(t, "three data responses to block or queue", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.requestSlots) == 3
	})
	if err := ws.WriteJSON(message{Type: "heartbeat"}); err != nil {
		t.Fatal(err)
	}

	_ = ws.SetReadDeadline(time.Now().Add(5 * time.Second))
	dataBeforeHeartbeat := 0
	for {
		var frame message
		if err := ws.ReadJSON(&frame); err != nil {
			t.Fatal(err)
		}
		if frame.Type == "heartbeat" {
			break
		}
		if frame.Type == "response" && strings.HasPrefix(frame.ID, "large-") {
			dataBeforeHeartbeat++
		}
	}
	if dataBeforeHeartbeat > 1 {
		t.Fatalf("heartbeat followed %d data frames; at most the already-active frame may lead it", dataBeforeHeartbeat)
	}
	_ = ws.Close()
	waitForCondition(t, "queued data responses to finish", func() bool {
		return len(connector.requestSlots) == 0
	})
}

func TestVMWebSocketRealBlockingRequestsHitAdmissionLimit(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	paths := make([]string, maxConcurrentRequests)
	for index := range paths {
		paths[index] = filepath.Join(root, fmt.Sprintf("blocked-%d.fifo", index))
		if err := syscall.Mkfifo(paths[index], 0o600); err != nil {
			t.Fatal(err)
		}
	}
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	defer ws.Close()

	for index := range paths {
		if err := ws.WriteJSON(message{
			ID: fmt.Sprintf("blocked-%d", index), Type: "request", Method: "read",
			Params: map[string]any{"path": filepath.Base(paths[index])},
		}); err != nil {
			t.Fatal(err)
		}
	}
	waitForCondition(t, "all filesystem request slots to fill", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.requestSlots) == maxConcurrentRequests
	})
	if err := ws.WriteJSON(message{
		ID: "over-limit", Type: "request", Method: "stat", Params: map[string]any{"path": "."},
	}); err != nil {
		t.Fatal(err)
	}
	_ = ws.SetReadDeadline(time.Now().Add(time.Second))
	var frame message
	if err := ws.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	if frame.ID != "over-limit" || frame.Type != "error" || !strings.Contains(frame.Error, "connector request capacity exhausted") {
		t.Fatalf("overload frame=%#v", frame)
	}

	var release sync.WaitGroup
	for _, path := range paths {
		release.Add(1)
		go func() {
			defer release.Done()
			writer, openErr := os.OpenFile(path, os.O_WRONLY, 0)
			if openErr == nil {
				_, _ = writer.Write([]byte("release"))
				_ = writer.Close()
			}
		}()
	}
	release.Wait()
	waitForCondition(t, "released filesystem requests to finish", func() bool {
		return len(connector.requestSlots) == 0
	})
}

func TestVMWebSocketRealBlockingStreamsHitAdmissionLimit(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	paths := make([]string, maxConcurrentStreamWrites+1)
	readers := make([]*os.File, 0, len(paths))
	for index := range paths {
		paths[index] = filepath.Join(root, fmt.Sprintf("stream-%d.fifo", index))
		if err := syscall.Mkfifo(paths[index], 0o600); err != nil {
			t.Fatal(err)
		}
		reader, err := os.OpenFile(paths[index], os.O_RDONLY|syscall.O_NONBLOCK, 0)
		if err != nil {
			t.Fatal(err)
		}
		readers = append(readers, reader)
	}
	defer func() {
		for _, reader := range readers {
			_ = reader.Close()
		}
	}()
	connector, err := newConnector(config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	t.Cleanup(func() {
		_ = ws.Close()
		server.Close()
		connector.closeExternalRuntimes()
	})

	for index := range paths {
		id := fmt.Sprintf("stream-%d", index)
		if err := ws.WriteJSON(message{
			ID: id, Type: "request", Method: "write_stream",
			Params: map[string]any{"path": filepath.Base(paths[index])},
		}); err != nil {
			t.Fatal(err)
		}
		var ready message
		if err := ws.ReadJSON(&ready); err != nil || ready.ID != id || ready.Type != "response" {
			t.Fatalf("ready=%#v err=%v", ready, err)
		}
	}
	payload := base64.StdEncoding.EncodeToString(bytes.Repeat([]byte("x"), 1024*1024))
	for index := 0; index < maxConcurrentStreamWrites; index++ {
		if err := ws.WriteJSON(message{
			ID: fmt.Sprintf("stream-%d", index), Type: "stream",
			Stream: &streamData{Channel: "data", Seq: 1, Data: payload},
		}); err != nil {
			t.Fatal(err)
		}
	}
	waitForCondition(t, "all stream worker slots to fill", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.activeConnection.streamSlots) == maxConcurrentStreamWrites
	})
	overLimitID := fmt.Sprintf("stream-%d", maxConcurrentStreamWrites)
	if err := ws.WriteJSON(message{
		ID: overLimitID, Type: "stream",
		Stream: &streamData{Channel: "data", Seq: 1, Data: base64.StdEncoding.EncodeToString([]byte("rejected"))},
	}); err != nil {
		t.Fatal(err)
	}
	_ = ws.SetReadDeadline(time.Now().Add(time.Second))
	var frame message
	if err := ws.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	if frame.ID != overLimitID || frame.Type != "stream" || !strings.Contains(frame.Error, "connector stream capacity exhausted") {
		t.Fatalf("stream overload frame=%#v", frame)
	}
	for _, reader := range readers {
		_ = reader.Close()
	}
	readers = nil
	waitForCondition(t, "released stream writes to finish", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.activeConnection.streamSlots) == 0
	})
	_ = ws.Close()
	waitForCondition(t, "websocket cleanup to finish", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection == nil
	})
}

func TestVMWebSocketWriteStreamLimitPreservesRejectedTarget(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	rejectedPath := filepath.Join(root, "stream-16.txt")
	if err := os.WriteFile(rejectedPath, []byte("do-not-truncate"), 0o600); err != nil {
		t.Fatal(err)
	}
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"
	ws := dialVMWebSocket(t, wsURL)
	defer ws.Close()

	for index := 0; index <= maxPendingWriteStreams; index++ {
		id := fmt.Sprintf("stream-%d", index)
		if err := ws.WriteJSON(message{
			ID: id, Type: "request", Method: "write_stream",
			Params: map[string]any{"path": id + ".txt"},
		}); err != nil {
			t.Fatal(err)
		}
		var frame message
		if err := ws.ReadJSON(&frame); err != nil || frame.ID != id {
			t.Fatalf("write_stream frame=%#v err=%v", frame, err)
		}
		if index < maxPendingWriteStreams && frame.Type != "response" {
			t.Fatalf("accepted write_stream frame=%#v", frame)
		}
		if index == maxPendingWriteStreams && (frame.Type != "error" || !strings.Contains(frame.Error, "write_stream capacity exhausted")) {
			t.Fatalf("rejected write_stream frame=%#v", frame)
		}
	}
	content, err := os.ReadFile(rejectedPath)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != "do-not-truncate" {
		t.Fatalf("rejected stream truncated target: %q", content)
	}
}

func TestVMWebSocketRequestWatchdogClosesBlockedIOAndReplacementServes(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	fifo := filepath.Join(root, "blocked-read")
	if err := syscall.Mkfifo(fifo, 0o600); err != nil {
		t.Fatal(err)
	}
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"

	blockedWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer blockedWS.Close()
	var metadata message
	if err := blockedWS.ReadJSON(&metadata); err != nil {
		t.Fatal(err)
	}
	connector.connectionMu.Lock()
	blockedSession := connector.activeConnection
	blockedSession.deadline = func(message) time.Duration { return 30 * time.Millisecond }
	connector.connectionMu.Unlock()
	if err := blockedWS.WriteJSON(message{
		ID:     "blocked-read",
		Type:   "request",
		Method: "read",
		Params: map[string]any{"path": fifo},
	}); err != nil {
		t.Fatal(err)
	}
	_ = blockedWS.SetReadDeadline(time.Now().Add(time.Second))
	var reply message
	if err := blockedWS.ReadJSON(&reply); err == nil {
		t.Fatalf("watchdog left blocked request socket alive: %#v", reply)
	}

	replacement, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer replacement.Close()
	if err := replacement.ReadJSON(&metadata); err != nil {
		t.Fatal(err)
	}
	if err := replacement.WriteJSON(message{ID: "replacement-list", Type: "request", Method: "process_list"}); err != nil {
		t.Fatal(err)
	}
	if err := replacement.ReadJSON(&reply); err != nil || reply.ID != "replacement-list" || reply.Type != "response" {
		t.Fatalf("replacement RPC reply=%#v err=%v", reply, err)
	}

	writer, err := os.OpenFile(fifo, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	_, _ = writer.Write([]byte("release"))
	_ = writer.Close()

	// Join the released read goroutine before returning: its teardown still
	// touches the connector root, and returning early races t.TempDir's
	// RemoveAll ("directory not empty").
	if !blockedSession.wait() {
		t.Fatal("blocked request goroutine did not drain after the FIFO release")
	}
}

func TestVMWebSocketRequestWatchdogHonorsLongRunningMethodTimeout(t *testing.T) {
	isolateHostRuntimeCommands(t)

	previousTimeout := requestExecutionTimeout
	requestExecutionTimeout = 20 * time.Millisecond
	defer func() { requestExecutionTimeout = previousTimeout }()

	connector, err := newVMWebSocketTestConnector(t, config{
		vmServer: true, root: t.TempDir(), systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"

	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.Close()
	var frame message
	if err := ws.ReadJSON(&frame); err != nil || frame.Type != "metadata" {
		t.Fatalf("metadata=%#v err=%v", frame, err)
	}
	if err := ws.WriteJSON(message{
		ID: "long-exec", Type: "request", Method: "exec",
		Params: map[string]any{"command": "sleep 0.05; printf ok", "timeout": 1},
	}); err != nil {
		t.Fatal(err)
	}
	_ = ws.SetReadDeadline(time.Now().Add(time.Second))
	if err := ws.ReadJSON(&frame); err != nil || frame.ID != "long-exec" || frame.Type != "response" {
		t.Fatalf("long-running method reply=%#v err=%v", frame, err)
	}
	result, ok := frame.Result.(map[string]any)
	if !ok || result["stdout"] != "ok" {
		t.Fatalf("long-running method result=%#v", frame.Result)
	}
}

func TestVMReplacementKeepsAcceptedProcessWritesButClosesOldReplySink(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	marker := filepath.Join(root, "stdin-markers")
	ready := filepath.Join(root, "process-ready")
	gate := filepath.Join(root, "start-reading")
	connector, err := newVMWebSocketTestConnector(t, config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()
	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + "/connect"

	oldWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer oldWS.Close()
	var frame message
	if err := oldWS.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	if err := oldWS.WriteJSON(message{
		ID:     "start-delayed-reader",
		Type:   "request",
		Method: "process_start",
		Params: map[string]any{
			"process_name": "delayed-reader",
			"command":      "/bin/sh",
			"args": []any{"-c", "printf ready > " + shellQuote(ready) +
				"; while [ ! -f " + shellQuote(gate) + " ]; do sleep 0.01; done; cat > " + shellQuote(marker)},
		},
	}); err != nil {
		t.Fatal(err)
	}
	if err := oldWS.ReadJSON(&frame); err != nil || frame.Type != "response" {
		t.Fatalf("process_start reply=%#v err=%v", frame, err)
	}
	waitForCondition(t, "managed process readiness", func() bool { return fileExists(ready) })
	large := strings.Repeat("A", 1024*1024)
	if err := oldWS.WriteJSON(message{
		ID: "fill-pipe", Type: "request", Method: "process_write",
		Params: map[string]any{"process_name": "delayed-reader", "data": large},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "first process write to hold the stdin slot", func() bool {
		connector.processMu.Lock()
		proc := connector.processes["delayed-reader"]
		connector.processMu.Unlock()
		return proc != nil && len(proc.stdinSlot) == 1
	})
	if err := oldWS.WriteJSON(message{
		ID: "old-marker", Type: "request", Method: "process_write",
		Params: map[string]any{"process_name": "delayed-reader", "data": "OLD_MARKER\n"},
	}); err != nil {
		t.Fatal(err)
	}
	waitForCondition(t, "queued old process write", func() bool {
		connector.connectionMu.Lock()
		defer connector.connectionMu.Unlock()
		return connector.activeConnection != nil && len(connector.requestSlots) == 2
	})

	newWS, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer newWS.Close()
	if err := newWS.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(gate, []byte("open"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := newWS.WriteJSON(message{
		ID: "new-marker", Type: "request", Method: "process_write",
		Params: map[string]any{"process_name": "delayed-reader", "data": "NEW_MARKER\n"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := newWS.ReadJSON(&frame); err != nil || frame.ID != "new-marker" || frame.Type != "response" {
		t.Fatalf("new process_write reply=%#v err=%v", frame, err)
	}
	_ = oldWS.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	if err := oldWS.ReadJSON(&frame); err == nil {
		t.Fatalf("old reply sink remained readable after replacement: %#v", frame)
	}
	time.Sleep(50 * time.Millisecond)
	if err := newWS.WriteJSON(message{
		ID: "stop-reader", Type: "request", Method: "process_stop",
		Params: map[string]any{"process_name": "delayed-reader"},
	}); err != nil {
		t.Fatal(err)
	}
	if err := newWS.ReadJSON(&frame); err != nil {
		t.Fatal(err)
	}
	content, err := os.ReadFile(marker)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Contains(content, []byte("OLD_MARKER")) || !bytes.Contains(content, []byte("NEW_MARKER")) {
		t.Fatalf("accepted process writes were lost across replacement: bytes=%d old=%t new=%t", len(content), bytes.Contains(content, []byte("OLD_MARKER")), bytes.Contains(content, []byte("NEW_MARKER")))
	}
}

func TestRemoteCleanupFatalStopsReconnectAfterServerDisappears(t *testing.T) {
	isolateHostRuntimeCommands(t)

	upgrader := websocket.Upgrader{}
	firstDone := make(chan struct{})
	var dials int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt64(&dials, 1)
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer ws.Close()
		var metadata message
		if ws.ReadJSON(&metadata) != nil {
			return
		}
		_ = ws.WriteJSON(message{
			ID: "pending-write", Type: "request", Method: "write_stream",
			Params: map[string]any{"path": "pending.bin"},
		})
		var ready message
		if ws.ReadJSON(&ready) != nil {
			return
		}
		_ = ws.Close()
		select {
		case <-firstDone:
		default:
			close(firstDone)
		}
	}))

	connector, err := newConnector(config{
		root: t.TempDir(), name: "fatal-remote", server: server.URL, token: "token",
		reconnect: true, systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatal(err)
	}
	blockedCleanup := &blockingCloser{started: make(chan struct{}), release: make(chan struct{})}
	defer close(blockedCleanup.release)
	connector.enqueueCleanup(blockedCleanup)
	select {
	case <-blockedCleanup.started:
	case <-time.After(time.Second):
		t.Fatal("cleanup worker did not enter the blocking closer")
	}
	for index := 0; index < cleanupQueueSize; index++ {
		connector.enqueueCleanup(io.NopCloser(strings.NewReader("occupied")))
	}
	result := make(chan error, 1)
	go func() { result <- connector.runRemote(context.Background()) }()
	select {
	case <-firstDone:
	case <-time.After(2 * time.Second):
		t.Fatal("remote connector did not establish the first websocket")
	}
	server.Close()
	select {
	case err := <-result:
		if !isConnectorFatal(err) {
			t.Fatalf("runRemote returned non-terminal error: %T %v", err, err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("cleanup fatal left runRemote reconnecting")
	}
	time.Sleep(50 * time.Millisecond)
	if got := atomic.LoadInt64(&dials); got != 1 {
		t.Fatalf("connector redialed after sticky fatal: dials=%d", got)
	}
}

func TestVMServerArchiveRoundTrip(t *testing.T) {
	isolateHostRuntimeCommands(t)

	connector, err := newConnector(config{vmServer: true, root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer connector.closeExternalRuntimes()
	connector.forwardRuntimeEvent("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "running",
	})
	waitForDurableEventCount(t, connector, 1)
	if err := os.WriteFile(filepath.Join(connector.root, "hello.txt"), []byte("hello"), 0o644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()

	resp, err := http.Get(server.URL + "/archive")
	if err != nil {
		t.Fatalf("get archive: %v", err)
	}
	raw, err := io.ReadAll(resp.Body)
	_ = resp.Body.Close()
	if err != nil {
		t.Fatalf("read archive: %v", err)
	}
	if !tarGzContains(t, raw, "hello.txt") {
		t.Fatal("archive did not contain hello.txt")
	}
	if tarGzContains(t, raw, externalRuntimeStateRelativePath) {
		t.Fatal("archive included live external runtime state")
	}

	restoreRoot := t.TempDir()
	restored, err := newConnector(config{vmServer: true, root: restoreRoot, systemInfoInterval: 0})
	if err != nil {
		t.Fatalf("new restore connector: %v", err)
	}
	defer restored.closeExternalRuntimes()
	restoreServer := httptest.NewServer(restored.vmHTTPHandler(context.Background()))
	defer restoreServer.Close()

	req, err := http.NewRequest(http.MethodPut, restoreServer.URL+"/archive", bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("new restore request: %v", err)
	}
	restoreResp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("restore archive: %v", err)
	}
	_ = restoreResp.Body.Close()
	if restoreResp.StatusCode != http.StatusOK {
		t.Fatalf("restore status = %d", restoreResp.StatusCode)
	}
	data, err := os.ReadFile(filepath.Join(restoreRoot, "hello.txt"))
	if err != nil {
		t.Fatalf("read restored file: %v", err)
	}
	if string(data) != "hello" {
		t.Fatalf("restored file = %q", data)
	}

	corruptDB := makeTarGz(t, []tarEntry{{name: externalRuntimeStateRelativePath, data: []byte("corrupt")}})
	req, _ = http.NewRequest(http.MethodPut, restoreServer.URL+"/archive", bytes.NewReader(corruptDB))
	restoreResp, err = http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("restore live state: %v", err)
	}
	if restoreResp.StatusCode != http.StatusOK {
		t.Fatalf("restore live state status=%s", restoreResp.Status)
	}
	_ = restoreResp.Body.Close()
	restored.forwardRuntimeEvent("capability", map[string]any{
		"type": "status", "provider": "codex", "state": "running",
	})
	waitForDurableEventCount(t, restored, 1)
}

func TestVMServerArchiveRestoreRejectsSymlinkEscape(t *testing.T) {
	isolateHostRuntimeCommands(t)

	root := t.TempDir()
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "link")); err != nil {
		if runtime.GOOS == "windows" {
			t.Skipf("symlink unavailable: %v", err)
		}
		t.Fatalf("create symlink: %v", err)
	}

	connector, err := newConnector(config{vmServer: true, root: root, systemInfoInterval: 0})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()

	payload := makeTarGz(t, []tarEntry{{name: "link/pwned.txt", data: []byte("escape")}})
	req, err := http.NewRequest(http.MethodPut, server.URL+"/archive", bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("new restore request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("restore archive: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("restore status = %d, want 400", resp.StatusCode)
	}
	if _, err := os.Stat(filepath.Join(outside, "pwned.txt")); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("outside file stat err = %v, want not exists", err)
	}
}

func TestVMServerArchiveRestoreRejectsOversizedFile(t *testing.T) {
	isolateHostRuntimeCommands(t)

	connector, err := newConnector(config{vmServer: true, root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	server := httptest.NewServer(connector.vmHTTPHandler(context.Background()))
	defer server.Close()

	payload := makeTarGz(t, []tarEntry{{name: "too-large.bin", data: bytes.Repeat([]byte("x"), maxArchiveFile+1)}})
	req, err := http.NewRequest(http.MethodPut, server.URL+"/archive", bytes.NewReader(payload))
	if err != nil {
		t.Fatalf("new restore request: %v", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("restore archive: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("restore status = %d, want 400", resp.StatusCode)
	}
}

func TestConnectorStatusAdvertisesLocalFileIndexVersion(t *testing.T) {
	statusPath := filepath.Join(t.TempDir(), "connector.status.json")
	c := &connector{cfg: config{statusPath: statusPath}}
	session := c.claimConnection(context.Background(), func(context.Context, message) error {
		return nil
	}, nil)
	defer session.close(context.Canceled)
	if !c.setIdentity(session, "run_v2_status", "dev_v2_status", "connector_v2_status", "user_v2_status", 17) {
		t.Fatal("failed to bind test connection identity")
	}

	c.writeStatus("connected", "wss://salix.example.test", nil)

	data, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatalf("read connector status: %v", err)
	}
	var status map[string]any
	if err := json.Unmarshal(data, &status); err != nil {
		t.Fatalf("decode connector status: %v", err)
	}
	if got := status["state"]; got != "connected" {
		t.Fatalf("state = %#v, want connected", got)
	}
	if got := status["local_file_index_version"]; got != float64(2) {
		t.Fatalf("local_file_index_version = %#v, want 2", got)
	}
	if got := status["connector_run_id"]; got != "run_v2_status" {
		t.Fatalf("connector_run_id = %#v, want run_v2_status", got)
	}
	if got := status["device_id"]; got != "dev_v2_status" {
		t.Fatalf("device_id = %#v, want dev_v2_status", got)
	}
}

func TestMetadataAdvertisesLocalFileIndexVersion(t *testing.T) {
	c, err := newConnector(config{
		name:               "local-file-reader",
		root:               t.TempDir(),
		localFileIndexRoot: t.TempDir(),
		systemInfoInterval: 0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()

	capabilities := c.metadata().Capabilities
	if got, present := capabilities["scope"]; !present || got != "" {
		t.Fatalf("full metadata scope = %#v present=%v, want explicit empty scope", got, present)
	}
	if got := capabilities["local_file_import_v1"]; got != true {
		t.Fatalf("local_file_import_v1 = %#v, want true", got)
	}
	if got := capabilities["local_file_index_version"]; got != 2 {
		t.Fatalf("local_file_index_version = %#v, want 2", got)
	}
}

func TestLocalFileReadScopeRefusesEveryMethodExceptReadRef(t *testing.T) {
	c, err := newConnector(config{
		name:                "attachment-reader",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "0123456789abcdef0123456789abcdef",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()

	refused := []string{
		"exec",
		"read",
		"write",
		"delete",
		"stat",
		"list",
		"glob",
		"grep",
		"computer_use",
		"read_stream",
		"write_stream",
		"process_start",
		"process_list",
		"process_write",
		"process_tail",
		"process_stop",
		"http_request",
		"agent_runtime_input",
		"runtime_probe",
		"meeting_join",
		"meeting_send_chat",
		"meeting_artifact_read",
	}
	for _, method := range refused {
		_, err := dispatchForTest(c, context.Background(), "req_scope", method, map[string]any{}, func(message) error {
			return nil
		})
		if err == nil || !strings.Contains(err.Error(), "not permitted") {
			t.Fatalf("method %q: error = %v, want scope refusal", method, err)
		}
	}

	// read_ref passes the scope gate and fails on its own parameter
	// validation instead of the scope refusal.
	_, err = dispatchForTest(c, context.Background(), "req_scope", "read_ref", map[string]any{}, func(message) error {
		return nil
	})
	if err == nil || strings.Contains(err.Error(), "not permitted") {
		t.Fatalf("read_ref: error = %v, want a non-scope validation error", err)
	}
}

func TestScopedConnectorsShareOneRootWithoutRuntimeState(t *testing.T) {
	root := t.TempDir()
	index := t.TempDir()

	first, err := newConnector(config{
		name:                "workspace-a",
		parentLifelineFD:    3,
		root:                root,
		runNonce:            "11111111111111111111111111111111",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  index,
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("first scoped connector: %v", err)
	}
	defer first.closeExternalRuntimes()

	// The previous implementation opened <root>/external-runtime/state.db with
	// an exclusive bolt lock, so a second scoped connector on the same root
	// failed with "open external runtime state: timeout". Scoped connectors
	// must not touch that database at all.
	second, err := newConnector(config{
		name:                "workspace-b",
		parentLifelineFD:    3,
		root:                root,
		runNonce:            "22222222222222222222222222222222",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  index,
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("second scoped connector on the same root: %v", err)
	}
	defer second.closeExternalRuntimes()

	if _, err := os.Stat(filepath.Join(root, "external-runtime", "state.db")); !os.IsNotExist(err) {
		t.Fatalf("scoped connectors must not create the external runtime database (stat err = %v)", err)
	}
	if len(first.runtimeImplementations) != 0 {
		t.Fatalf("scoped connector must not instantiate agent runtime implementations")
	}
	if got := first.externalRuntimeState.db; got != nil {
		t.Fatalf("scoped connector must hold a disabled external runtime state")
	}
	if err := first.externalRuntimeState.enqueueInputBatch("codex", externalRuntimeInput{}); !errors.Is(err, errExternalRuntimeStateDisabled) {
		t.Fatalf("enqueueInputBatch = %v, want errExternalRuntimeStateDisabled", err)
	}
}

func TestScopedConnectorNeverProbesAgentRuntimes(t *testing.T) {
	c, err := newConnector(config{
		name:                "attachment-reader",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "33333333333333333333333333333333",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()

	probes := 0
	c.runtimeInventory.run = func(runtimeProbeTarget) map[string]any {
		probes++
		return map[string]any{}
	}

	var sent []message
	err = c.probeAndPublish(context.Background(), "connect", func(m message) error {
		sent = append(sent, m)
		return nil
	})
	if err != nil {
		t.Fatalf("probeAndPublish: %v", err)
	}
	// Probing can launch runtime processes (e.g. a Codex app-server); a
	// read_ref-only connector must publish its minimal metadata untouched.
	if probes != 0 {
		t.Fatalf("scoped connector probed %d runtime targets, want 0", probes)
	}
	if len(sent) != 1 || sent[0].Type != "metadata" {
		t.Fatalf("sent = %#v, want exactly one metadata frame", sent)
	}
	if got := sent[0].Capabilities["scope"]; got != scopeLocalFileRead {
		t.Fatalf("published scope = %#v, want %q", got, scopeLocalFileRead)
	}
}

func TestLocalFileReadScopeAdvertisesMinimalCapabilities(t *testing.T) {
	c, err := newConnector(config{
		name:                "attachment-reader",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "44444444444444444444444444444444",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()

	capabilities := c.metadata().Capabilities
	if got := capabilities["scope"]; got != scopeLocalFileRead {
		t.Fatalf("scope = %#v, want %q", got, scopeLocalFileRead)
	}
	if got := capabilities["local_file_import_v1"]; got != true {
		t.Fatalf("local_file_import_v1 = %#v, want true", got)
	}
	if got := capabilities["local_file_index_version"]; got != 2 {
		t.Fatalf("local_file_index_version = %#v, want 2", got)
	}
	for _, forbidden := range []string{
		"persistent_processes",
		"computer_use_tool",
		"runtime_probe",
		"meeting_runtime",
	} {
		if got := capabilities[forbidden]; got != false {
			t.Fatalf("%s = %#v, want false", forbidden, got)
		}
	}
	if _, present := capabilities["agent_runtimes"]; present {
		t.Fatalf("agent_runtimes must not be advertised by a scoped connector")
	}
	if got := capabilities["execution_boundary"]; got != "local-file-read-only" {
		t.Fatalf("execution_boundary = %#v, want local-file-read-only", got)
	}
}

func TestCommaDesktopScopeChangesInPlaceWithoutStartingExternalRuntimes(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "55555555555555555555555555555555",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()

	if got := c.currentScope(); got != scopeLocalFileRead {
		t.Fatalf("initial scope = %q, want %q", got, scopeLocalFileRead)
	}
	if err := c.setCurrentScope(""); err != nil {
		t.Fatalf("enable full scope: %v", err)
	}
	if got := c.currentScope(); got != "" {
		t.Fatalf("enabled scope = %q, want full", got)
	}
	if len(c.runtimeImplementations) != 0 || c.externalRuntimeState.db != nil {
		t.Fatalf("scope elevation must not initialize external runtimes")
	}

	capabilities := c.metadata().Capabilities
	if got := capabilities["persistent_processes"]; got != true {
		t.Fatalf("persistent_processes = %#v, want true", got)
	}
	if got := capabilities["runtime_probe"]; got != false {
		t.Fatalf("runtime_probe = %#v, want false", got)
	}
	if _, present := capabilities["agent_runtimes"]; present {
		t.Fatalf("dynamically elevated Comma connector must not advertise agent runtimes")
	}
	if _, err := dispatchForTest(c, context.Background(), "req_list", "process_list", map[string]any{}, func(message) error { return nil }); err != nil {
		t.Fatalf("full scope process_list: %v", err)
	}

	if err := c.setCurrentScope(scopeLocalFileRead); err != nil {
		t.Fatalf("restore restricted scope: %v", err)
	}
	if _, err := dispatchForTest(c, context.Background(), "req_blocked", "process_list", map[string]any{}, func(message) error { return nil }); err == nil || !strings.Contains(err.Error(), "not permitted") {
		t.Fatalf("restricted process_list error = %v, want scope refusal", err)
	}
}

func TestScopeControlRequiresExactRunNonceAndPublishesMetadata(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "66666666666666666666666666666666",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()

	var sent []message
	session := c.claimConnection(context.Background(), func(_ context.Context, m message) error {
		sent = append(sent, m)
		return nil
	}, func(error) {})
	defer session.close(nil)

	commands := strings.NewReader(
		`{"type":"set_scope","run_nonce":"wrong","scope":""}` + "\n" +
			`{"type":"set_scope","run_nonce":"66666666666666666666666666666666"}` + "\n" +
			`{"type":"set_scope","run_nonce":"66666666666666666666666666666666","scope":""}` + "\n",
	)
	watchScopeControl(context.Background(), commands, c)

	if got := c.currentScope(); got != "" {
		t.Fatalf("scope = %q, want full after exact-nonce command", got)
	}
	if len(sent) != 1 || sent[0].Type != "metadata" {
		t.Fatalf("published = %#v, want one metadata replacement", sent)
	}
}

func TestScopeDowngradeFencesAnAlreadyAdmittedProcessStart(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "88888888888888888888888888888888",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()
	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}

	insideFence := make(chan struct{})
	releaseFence := make(chan struct{})
	c.beforeManagedProcessStart = func() {
		close(insideFence)
		<-releaseFence
	}
	marker := filepath.Join(t.TempDir(), "escaped")
	startDone := make(chan error, 1)
	go func() {
		_, err := dispatchForTest(c, context.Background(), "req_start_race", "process_start", map[string]any{
			"process_name": "race",
			"command":      "/bin/sh",
			"args":         []any{"-c", "touch " + shellQuote(marker)},
		}, func(message) error { return nil })
		startDone <- err
	}()
	<-insideFence

	downgradeDone := make(chan error, 1)
	go func() { downgradeDone <- c.setCurrentScope(scopeLocalFileRead) }()
	for c.currentScope() != scopeLocalFileRead {
		time.Sleep(time.Millisecond)
	}
	select {
	case err := <-downgradeDone:
		t.Fatalf("downgrade acknowledged before admitted process fence drained: %v", err)
	case <-time.After(20 * time.Millisecond):
	}
	close(releaseFence)
	if err := <-startDone; err == nil {
		t.Fatal("admitted process start unexpectedly succeeded across downgrade")
	}
	if err := <-downgradeDone; err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(marker); !os.IsNotExist(err) {
		t.Fatalf("process escaped restricted transition (stat err = %v)", err)
	}
	c.processMu.Lock()
	defer c.processMu.Unlock()
	if process := c.processes["race"]; process != nil && process.isRunning() {
		t.Fatal("running process survived restricted acknowledgement")
	}
}

func TestScopeDowngradeAbortsPendingWriteStreamAndRejectsLaterFrames(t *testing.T) {
	root := t.TempDir()
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                root,
		runNonce:            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()
	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}

	terminal := make(chan message, 1)
	session := c.claimConnection(context.Background(), func(_ context.Context, frame message) error {
		if frame.ID == "write-after-downgrade" && frame.Type == "stream" {
			terminal <- frame
		}
		return nil
	}, func(error) {})
	defer session.close(nil)
	if _, err := c.dispatchSession(
		context.Background(),
		session,
		"write-after-downgrade",
		"write_stream",
		map[string]any{"path": "bounded.txt"},
	); err != nil {
		t.Fatalf("prepare write_stream: %v", err)
	}
	if session.pendingWrite("write-after-downgrade") == nil {
		t.Fatal("write_stream was not reserved")
	}

	if err := c.setCurrentScope(scopeLocalFileRead); err != nil {
		t.Fatal(err)
	}
	session.handleStream(message{
		ID:   "write-after-downgrade",
		Type: "stream",
		Stream: &streamData{
			Channel: "data",
			Data:    base64.StdEncoding.EncodeToString([]byte("must-not-land")),
			EOF:     true,
			Seq:     1,
		},
	})

	if session.pendingWrite("write-after-downgrade") != nil {
		t.Fatal("restricted transition retained pending write_stream")
	}
	select {
	case frame := <-terminal:
		if frame.Stream == nil || frame.Stream.Channel != "done" || !frame.Stream.EOF ||
			!strings.Contains(frame.Error, "scope restricted") {
			t.Fatalf("scope cancellation frame = %#v", frame)
		}
	case <-time.After(time.Second):
		t.Fatal("scope downgrade did not terminate pending write_stream")
	}
	content, err := os.ReadFile(filepath.Join(root, "bounded.txt"))
	if err != nil {
		t.Fatal(err)
	}
	if len(content) != 0 {
		t.Fatalf("restricted stream frame altered file: %q", content)
	}
}

func TestScopeDowngradeDoesNotWaitForUserFileClose(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()
	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}

	session := c.claimConnection(context.Background(), func(context.Context, message) error {
		return nil
	}, func(error) {})
	defer session.close(nil)
	pending, err := session.reservePendingWrite("blocking-close")
	if err != nil {
		t.Fatal(err)
	}
	closer := &blockingCloseWriteCloser{blockingCloser: &blockingCloser{
		started: make(chan struct{}),
		release: make(chan struct{}),
	}}
	defer close(closer.release)
	if !session.activatePendingWrite("blocking-close", pending, closer) {
		t.Fatal("failed to activate pending write")
	}

	done := make(chan error, 1)
	go func() { done <- c.setCurrentScope(scopeLocalFileRead) }()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(time.Second):
		t.Fatal("scope downgrade waited for user file Close")
	}
	select {
	case <-closer.started:
	case <-time.After(time.Second):
		t.Fatal("asynchronous user file cleanup did not start")
	}
}

func TestScopeStatusAcknowledgesOnlyAfterMetadataPublishAndPeriodicRetry(t *testing.T) {
	statusPath := filepath.Join(t.TempDir(), "connector.status.json")
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "99999999999999999999999999999999",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		statusPath:          statusPath,
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()
	c.writeStatus("connected", "", nil)

	session := c.claimConnection(context.Background(), func(context.Context, message) error {
		return errors.New("transport blocked")
	}, func(error) {})
	defer session.close(nil)
	watchScopeControl(context.Background(), strings.NewReader(
		`{"type":"set_scope","run_nonce":"99999999999999999999999999999999","scope":""}`+"\n",
	), c)

	raw, err := os.ReadFile(statusPath)
	if err != nil {
		t.Fatal(err)
	}
	var status connectorStatusFile
	if err := json.Unmarshal(raw, &status); err != nil {
		t.Fatal(err)
	}
	if status.Scope != scopeLocalFileRead {
		t.Fatalf("scope acknowledgement advanced after failed publish: %q", status.Scope)
	}

	// Unrelated request status must not acknowledge the unpublished scope.
	c.writeStatusLocalRequestError(errors.New("request failed while scope publish is pending"))
	raw, _ = os.ReadFile(statusPath)
	if err := json.Unmarshal(raw, &status); err != nil {
		t.Fatal(err)
	}
	if status.Scope != scopeLocalFileRead {
		t.Fatalf("request error advanced unpublished scope acknowledgement: %q", status.Scope)
	}

	if err := c.publishPeriodicSystemInfo(func(message) error { return nil }); err != nil {
		t.Fatal(err)
	}
	c.writeStatusMetadataSent("")
	raw, _ = os.ReadFile(statusPath)
	if err := json.Unmarshal(raw, &status); err != nil {
		t.Fatal(err)
	}
	if status.Scope != "" {
		t.Fatalf("periodic retry scope acknowledgement = %q, want full", status.Scope)
	}
}

func TestConnectURLCarriesCurrentScopeIncludingFull(t *testing.T) {
	c, err := newConnector(config{
		name:                "comma-desktop",
		parentLifelineFD:    3,
		root:                t.TempDir(),
		runNonce:            "77777777777777777777777777777777",
		shutdownRequestPath: filepath.Join(t.TempDir(), "shutdown-request.json"),
		localFileIndexRoot:  t.TempDir(),
		scope:               scopeLocalFileRead,
		systemInfoInterval:  0,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()

	restrictedURL, err := c.connectURL("https://salix.test")
	if err != nil {
		t.Fatal(err)
	}
	restricted, _ := url.Parse(restrictedURL)
	if got := restricted.Query().Get("scope"); got != scopeLocalFileRead {
		t.Fatalf("restricted query scope = %q", got)
	}

	if err := c.setCurrentScope(""); err != nil {
		t.Fatal(err)
	}
	fullURL, err := c.connectURL("https://salix.test")
	if err != nil {
		t.Fatal(err)
	}
	full, _ := url.Parse(fullURL)
	if values, present := full.Query()["scope"]; !present || len(values) != 1 || values[0] != "" {
		t.Fatalf("full query scope = %#v, want explicit empty value", values)
	}
}

func TestLocalFileReadScopeRequiresRunNonceAndParentLifeline(t *testing.T) {
	base := config{
		localFileIndexRoot: t.TempDir(),
		scope:              scopeLocalFileRead,
	}
	if err := validateConfig(base); err == nil || !strings.Contains(err.Error(), "run nonce") {
		t.Fatalf("missing run nonce: error = %v", err)
	}

	base.runNonce = "0123456789abcdef0123456789abcdef"
	if err := validateConfig(base); err == nil || !strings.Contains(err.Error(), "parent lifeline") {
		t.Fatalf("missing parent lifeline: error = %v", err)
	}

	base.parentLifelineFD = 3
	if err := validateConfig(base); err == nil || !strings.Contains(err.Error(), "shutdown request") {
		t.Fatalf("missing cooperative shutdown request: error = %v", err)
	}

	base.shutdownRequestPath = filepath.Join(t.TempDir(), "shutdown-request.json")
	if err := validateConfig(base); err != nil {
		t.Fatalf("complete containment identity rejected: %v", err)
	}

	base.parentLifelineFD = -1
	base.parentLifelinePipe = `\\.\pipe\comma-salix-parent-test`
	if err := validateConfig(base); err != nil {
		t.Fatalf("Windows named-pipe containment identity rejected: %v", err)
	}

	base.parentLifelineFD = 3
	if err := validateConfig(base); err == nil || !strings.Contains(err.Error(), "exactly one") {
		t.Fatalf("multiple parent lifelines: error = %v", err)
	}
}

func TestParentLifelineCancelsConnectorContextOnEOF(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		watchParentLifeline(ctx, reader, cancel)
		close(done)
	}()

	if _, err := writer.Write([]byte("still-alive")); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ctx.Done():
		t.Fatal("lifeline payload must not terminate the connector before EOF")
	case <-time.After(25 * time.Millisecond):
	}

	if err := writer.Close(); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("connector context remained live after parent lifeline EOF")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("parent lifeline watcher did not return")
	}
}

func TestCooperativeShutdownRequiresExactRunNonce(t *testing.T) {
	requestPath := filepath.Join(t.TempDir(), "shutdown-request.json")
	runNonce := "0123456789abcdef0123456789abcdef"
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan struct{})
	go func() {
		watchShutdownRequest(ctx, requestPath, runNonce, cancel)
		close(done)
	}()

	wrong, err := json.Marshal(map[string]string{
		"runNonce": "ffffffffffffffffffffffffffffffff",
	})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(requestPath, wrong, 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ctx.Done():
		t.Fatal("a shutdown request for another run must not cancel this connector")
	case <-time.After(150 * time.Millisecond):
	}

	exact, err := json.Marshal(map[string]string{"runNonce": runNonce})
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(requestPath, exact, 0o600); err != nil {
		t.Fatal(err)
	}
	select {
	case <-ctx.Done():
	case <-time.After(time.Second):
		t.Fatal("exact cooperative shutdown request did not cancel the connector")
	}
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cooperative shutdown watcher did not return")
	}
}

func TestMetadataIncludesSystemInfo(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()

	meta := c.metadata()
	if meta.Type != "metadata" {
		t.Fatalf("metadata type = %q, want metadata", meta.Type)
	}

	info := meta.SystemInfo
	if info == nil {
		t.Fatal("metadata is missing system_info")
	}

	for _, key := range []string{"hostname", "os_type", "arch", "cpu_count", "collected_at"} {
		if _, ok := info[key]; !ok {
			t.Errorf("system_info missing key %q (got %v)", key, info)
		}
	}

	if got := info["os_type"]; got != runtime.GOOS {
		t.Errorf("system_info os_type = %v, want %v", got, runtime.GOOS)
	}
	if got := info["arch"]; got != runtime.GOARCH {
		t.Errorf("system_info arch = %v, want %v", got, runtime.GOARCH)
	}
}

func TestMetadataReportsCodexAgentRuntime(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	logPath := filepath.Join(t.TempDir(), "fake-codex.log")
	codex := fakeCodexCommand(t, logPath, map[string]string{
		"SALIX_TEST_FAKE_CODEX_VERSION": "codex-cli 1.2.3",
	})
	t.Setenv("PATH", filepath.Dir(codex))

	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer c.closeExternalRuntimes()
	if _, err := c.runtimeInventory.probe(context.Background(), "", "", "connect"); err != nil {
		t.Fatalf("initial runtime probe: %v", err)
	}
	before, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read probe log: %v", err)
	}
	if !strings.Contains(string(before), "cli_output=salix-cli-ok") {
		t.Fatalf("Codex app-server did not receive an executable SALIX_CLI: %q", before)
	}

	meta := c.metadata()
	after, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read metadata log: %v", err)
	}
	if string(after) != string(before) {
		t.Fatalf("metadata executed runtime probe: before=%q after=%q", before, after)
	}
	if got := meta.Capabilities["persistent_processes"]; got != true {
		t.Fatalf("persistent_processes = %v, want true", got)
	}

	runtimes, ok := meta.Capabilities["agent_runtimes"].([]map[string]any)
	if !ok {
		t.Fatalf("agent_runtimes type = %T, want []map[string]any", meta.Capabilities["agent_runtimes"])
	}
	if len(runtimes) != 1 {
		t.Fatalf("agent_runtimes len = %d, want 1: %#v", len(runtimes), runtimes)
	}

	rt := runtimes[0]
	if rt["kind"] != "external" {
		t.Fatalf("runtime kind = %v, want external", rt["kind"])
	}
	if rt["provider"] != "codex" {
		t.Fatalf("runtime provider = %v, want codex", rt["provider"])
	}
	if rt["status"] != "available" {
		t.Fatalf("runtime status = %v, want available: %#v", rt["status"], rt)
	}
	if rt["version"] != "codex-cli 1.2.3" {
		t.Fatalf("runtime version = %v", rt["version"])
	}
	if rt["version_detected"] != true {
		t.Fatalf("runtime version_detected = %v, want true", rt["version_detected"])
	}
	if rt["app_server_startable"] != true {
		t.Fatalf("runtime app_server_startable = %v, want true", rt["app_server_startable"])
	}
	if rt["auth_ready"] != true {
		t.Fatalf("runtime auth_ready = %v, want true", rt["auth_ready"])
	}
	if rt["ready"] != true {
		t.Fatalf("runtime ready = %v, want true", rt["ready"])
	}
	if rt["last_error"] != "" {
		t.Fatalf("runtime last_error = %v, want empty", rt["last_error"])
	}
	if _, ok := rt["readiness_checked_at"].(int64); !ok {
		t.Fatalf("runtime readiness_checked_at = %T, want int64", rt["readiness_checked_at"])
	}
	if _, ok := rt["readiness_valid_until"].(int64); !ok {
		t.Fatalf("runtime readiness_valid_until = %T, want int64", rt["readiness_valid_until"])
	}
	transports, ok := rt["transports"].([]string)
	if !ok || len(transports) != 1 || transports[0] != "ws" {
		t.Fatalf("runtime transports = %#v, want [ws]", rt["transports"])
	}
}

func TestRuntimeProbeCommandReportsReadyCodexRuntime(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	logPath := filepath.Join(t.TempDir(), "fake-codex.log")
	codex := fakeCodexCommand(t, logPath, map[string]string{
		"SALIX_TEST_FAKE_CODEX_VERSION": "codex-cli 2.0.0",
	})
	t.Setenv("PATH", filepath.Dir(codex))

	out, err := captureStdout(t, func() error {
		return runRuntimeProbeCommand([]string{"--json"})
	})
	if err != nil {
		t.Fatalf("runtime-probe: %v\n%s", err, out)
	}

	var report map[string]any
	if err := json.Unmarshal([]byte(out), &report); err != nil {
		t.Fatalf("decode runtime-probe JSON: %v\n%s", err, out)
	}
	if report["ready"] != true || report["status"] != "available" {
		t.Fatalf("runtime-probe report = %#v", report)
	}
	runtimes, ok := report["agent_runtimes"].([]any)
	if !ok || len(runtimes) != 1 {
		t.Fatalf("agent_runtimes = %#v", report["agent_runtimes"])
	}
	runtime, ok := runtimes[0].(map[string]any)
	if !ok {
		t.Fatalf("runtime = %#v", runtimes[0])
	}
	if runtime["command"] != codex || runtime["version"] != "codex-cli 2.0.0" {
		t.Fatalf("runtime = %#v", runtime)
	}
	if runtime["auth_ready"] != true || runtime["app_server_startable"] != true {
		t.Fatalf("runtime readiness = %#v", runtime)
	}
}

func TestCodexReadinessRejectsConfiguredModelMissingFromNativeCatalog(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.Mkdir(filepath.Join(home, ".codex"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(home, ".codex", "config.toml"), []byte("model = \"gpt-required\"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	command := fakeCodexCommand(t, filepath.Join(t.TempDir(), "fake-codex.log"), map[string]string{
		"SALIX_TEST_FAKE_CODEX_MODELS": "gpt-other",
	})

	readiness := detectCodexReadiness(command)
	if readiness["ready"] != false || readiness["app_server_startable"] != false {
		t.Fatalf("readiness = %#v, want configured-model failure", readiness)
	}
	if !strings.Contains(stringFromAny(readiness["last_error"]), "configured model") {
		t.Fatalf("last_error = %#v, want configured-model diagnostic", readiness["last_error"])
	}
}

func TestCodexReadinessReportsAuthenticationMessageFromActualProbe(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CODEX_HOME", "")
	command := fakeCodexCommand(t, filepath.Join(t.TempDir(), "fake-codex.log"), map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none",
	})

	readiness := detectCodexReadiness(command)
	if readiness["ready"] != false || readiness["auth_ready"] != false {
		t.Fatalf("readiness = %#v, want an unauthenticated runtime", readiness)
	}
	if readiness["readiness_issue"] != "authentication_required" {
		t.Fatalf("readiness_issue = %#v, want authentication_required", readiness["readiness_issue"])
	}
	if readiness["readiness_message"] != "Codex reports no authenticated account." {
		t.Fatalf("readiness_message = %#v", readiness["readiness_message"])
	}
}

func TestCodexReadinessMessagesDistinguishNativeFailureStages(t *testing.T) {
	for _, tc := range []struct{ failure, message string }{
		{"app-server start failed: permission denied", "The Codex native server could not be started."},
		{"app-server protocol probe failed: invalid response", "The Codex native server could not complete its readiness handshake."},
		{"app-server websocket probe timed out", "The Codex native server handshake timed out."},
	} {
		issue, message := codexReadinessDetail("", "", tc.failure)
		if issue != "native_server_unavailable" || message != tc.message {
			t.Fatalf("detail for %q = %q/%q", tc.failure, issue, message)
		}
	}
}

func TestCodexRuntimeRPCUsesWebSocket(t *testing.T) {
	received := make(chan map[string]any, 1)
	upgrader := websocket.Upgrader{}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade websocket: %v", err)
			return
		}
		defer ws.Close()

		var msg map[string]any
		if err := ws.ReadJSON(&msg); err != nil {
			t.Errorf("read app-server request: %v", err)
			return
		}
		received <- msg

		if err := ws.WriteJSON(map[string]any{
			"id":     msg["id"],
			"result": map[string]any{"ok": true},
		}); err != nil {
			t.Errorf("write app-server response: %v", err)
		}
	}))
	defer server.Close()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http")
	ws, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial fake app-server: %v", err)
	}

	rt := &codexRuntime{
		ws:      ws,
		done:    make(chan struct{}),
		nextID:  1,
		pending: map[string]chan map[string]any{},
	}
	defer rt.close()
	go rt.readLoop(ws)

	result, err := rt.rpc(
		context.Background(),
		"initialize",
		map[string]any{"hello": "world"},
		time.Second,
	)
	if err != nil {
		t.Fatalf("rpc: %v", err)
	}
	if result["ok"] != true {
		t.Fatalf("rpc result = %#v", result)
	}

	msg := receiveMap(t, received)
	if msg["method"] != "initialize" {
		t.Fatalf("method = %#v, want initialize", msg["method"])
	}
	if mapParam(msg, "params")["hello"] != "world" {
		t.Fatalf("params = %#v", msg["params"])
	}
}

func TestRuntimeBridgeRoutesRegisteredRuntimeContext(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	sent := make(chan message, 1)
	deactivate := activateRuntimeTransportForTest(c, func(msg message) error {
		sent <- msg
		go c.completeRuntimeProxy(message{
			ID:   msg.ID,
			Type: "response",
			Result: map[string]any{
				"status":      200,
				"body_base64": base64.StdEncoding.EncodeToString([]byte(`{"ok":true}`)),
				"headers": map[string]any{
					"content-type": "application/json",
				},
			},
		})
		return nil
	})
	defer deactivate()
	bridgeURL, err := c.ensureRuntimeBridge()
	if err != nil {
		t.Fatalf("ensureRuntimeBridge: %v", err)
	}

	c.registerRuntimeRoute("context-cli", "cap-token")

	resp, err := http.Get(bridgeURL + "/runtime/context-cli/tools")
	if err != nil {
		t.Fatalf("get thread path: %v", err)
	}
	_ = resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("thread path status = %d, want 200", resp.StatusCode)
	}
	msg := receiveMessage(t, sent)
	if msg.Params["capability_token"] != "cap-token" {
		t.Fatalf("capability_token = %#v", msg.Params["capability_token"])
	}
	if msg.Params["route_path"] != "/tools" {
		t.Fatalf("route_path = %#v", msg.Params["route_path"])
	}
}

func TestRuntimeBridgeReturnsStructuredOfflineError(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	bridgeURL, err := c.ensureRuntimeBridge()
	if err != nil {
		t.Fatalf("ensure runtime bridge: %v", err)
	}
	c.registerRuntimeRoute("context-offline", "cap-token")

	resp, err := http.Post(
		bridgeURL+"/runtime/context-offline/tool/env.exec",
		"application/json",
		strings.NewReader(`{"command":"pwd"}`),
	)
	if err != nil {
		t.Fatalf("post offline tool: %v", err)
	}
	defer resp.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode offline response: %v", err)
	}
	if resp.StatusCode != http.StatusServiceUnavailable || body["code"] != "connector_offline" {
		t.Fatalf("offline response status=%d body=%#v", resp.StatusCode, body)
	}
}

func TestRuntimeBridgeReturnsStructuredOfflineErrorWhenTransportDisconnectsDuringCall(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	sent := make(chan message, 1)
	deactivate := activateRuntimeTransportForTest(c, func(msg message) error {
		sent <- msg
		return nil
	})
	defer func() {
		if deactivate != nil {
			deactivate()
		}
	}()

	bridgeURL, err := c.ensureRuntimeBridge()
	if err != nil {
		t.Fatalf("ensure runtime bridge: %v", err)
	}
	c.registerRuntimeRoute("context-disconnect", "cap-token")

	type response struct {
		resp *http.Response
		err  error
	}
	responses := make(chan response, 1)
	go func() {
		resp, err := http.Post(
			bridgeURL+"/runtime/context-disconnect/tool/env.exec",
			"application/json",
			strings.NewReader(`{"command":"pwd"}`),
		)
		responses <- response{resp: resp, err: err}
	}()

	receiveMessage(t, sent)
	deactivate()
	deactivate = nil

	result := <-responses
	if result.err != nil {
		t.Fatalf("post tool during disconnect: %v", result.err)
	}
	defer result.resp.Body.Close()
	raw, err := io.ReadAll(result.resp.Body)
	if err != nil {
		t.Fatalf("read offline response: %v", err)
	}
	var body map[string]any
	if err := json.Unmarshal(raw, &body); err != nil {
		t.Fatalf("decode offline response status=%d body=%q: %v", result.resp.StatusCode, raw, err)
	}
	if result.resp.StatusCode != http.StatusServiceUnavailable || body["code"] != "connector_offline" {
		t.Fatalf("offline response status=%d body=%#v", result.resp.StatusCode, body)
	}
}

func TestProcessMethodsSupportStdioLongRunningProcess(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	started, err := dispatchForTest(c, context.Background(), "req-start", "process_start", map[string]any{
		"process_name": "echoer",
		"command":      "/bin/sh",
		"args": []any{
			"-c",
			"while IFS= read -r line; do printf 'out:%s\\n' \"$line\"; done",
		},
	}, func(message) error { return nil })
	if err != nil {
		t.Fatalf("process_start: %v", err)
	}
	if started.(map[string]any)["process_name"] != "echoer" {
		t.Fatalf("process_start result = %#v", started)
	}

	wrote, err := dispatchForTest(c, context.Background(), "req-write", "process_write", map[string]any{
		"process_name":   "echoer",
		"data":           "hello",
		"append_newline": true,
	}, func(message) error { return nil })
	if err != nil {
		t.Fatalf("process_write: %v", err)
	}
	if wrote.(map[string]any)["bytes_written"].(int) == 0 {
		t.Fatalf("process_write wrote no bytes: %#v", wrote)
	}

	tailed, err := dispatchForTest(c, context.Background(), "req-tail", "process_tail", map[string]any{
		"process_name": "echoer",
		"from_offset":  0,
		"wait_seconds": 2,
		"max_bytes":    1024,
	}, func(message) error { return nil })
	if err != nil {
		t.Fatalf("process_tail: %v", err)
	}

	tail := tailed.(map[string]any)
	if !strings.Contains(tail["data"].(string), "out:hello\n") {
		t.Fatalf("tail data = %#v", tail)
	}
	if tail["next_offset"].(int64) <= 0 {
		t.Fatalf("tail next_offset = %#v", tail["next_offset"])
	}

	listed, err := dispatchForTest(c, context.Background(), "req-list", "process_list", map[string]any{}, func(message) error { return nil })
	if err != nil {
		t.Fatalf("process_list: %v", err)
	}
	if len(listed.(map[string]any)["processes"].([]map[string]any)) != 1 {
		t.Fatalf("process_list result = %#v", listed)
	}

	if _, err := dispatchForTest(c, context.Background(), "req-stop", "process_stop", map[string]any{
		"process_name": "echoer",
	}, func(message) error { return nil }); err != nil {
		t.Fatalf("process_stop: %v", err)
	}
}

func TestRuntimeBridgeProxiesCapabilityRequests(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	sent := make(chan message, 1)
	deactivate := activateRuntimeTransportForTest(c, func(msg message) error {
		sent <- msg
		go c.completeRuntimeProxy(message{
			ID:   msg.ID,
			Type: "response",
			Result: map[string]any{
				"status":      201,
				"body_base64": base64.StdEncoding.EncodeToString([]byte("proxied")),
				"headers": map[string]any{
					"content-type": "text/plain",
				},
			},
		})
		return nil
	})
	defer deactivate()
	bridgeURL, err := c.ensureRuntimeBridge()
	if err != nil {
		t.Fatalf("ensureRuntimeBridge: %v", err)
	}

	c.registerRuntimeRoute("context-proxy", "cap-token")

	resp, err := http.Post(bridgeURL+"/runtime/context-proxy/tool/im_api.slack.post_message?x=1", "application/json", strings.NewReader(`{"ok":true}`))
	if err != nil {
		t.Fatalf("post bridge: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != 201 {
		t.Fatalf("status = %d, want 201", resp.StatusCode)
	}

	msg := receiveMessage(t, sent)
	if msg.Type != "request" || msg.Method != "runtime_proxy" {
		t.Fatalf("runtime proxy message = %#v", msg)
	}
	if msg.Params["capability_token"] != "cap-token" {
		t.Fatalf("capability_token = %#v", msg.Params["capability_token"])
	}
	if msg.Params["method"] != "POST" {
		t.Fatalf("method = %#v", msg.Params["method"])
	}
	if msg.Params["route_path"] != "/tool/im_api.slack.post_message" {
		t.Fatalf("route_path = %#v", msg.Params["route_path"])
	}
	if msg.Params["raw_query"] != "x=1" {
		t.Fatalf("raw_query = %#v", msg.Params["raw_query"])
	}
	if msg.Params["body_base64"] != base64.StdEncoding.EncodeToString([]byte(`{"ok":true}`)) {
		t.Fatalf("body_base64 = %#v", msg.Params["body_base64"])
	}
}

func TestRuntimeBridgeProxiesExecThroughSessionRuntime(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	sent := make(chan message, 1)
	deactivate := activateRuntimeTransportForTest(c, func(msg message) error {
		sent <- msg
		go c.completeRuntimeProxy(message{
			ID:   msg.ID,
			Type: "response",
			Result: map[string]any{
				"status":      200,
				"body_base64": base64.StdEncoding.EncodeToString([]byte(`{"proxied":true}`)),
				"headers": map[string]any{
					"content-type": "application/json",
				},
			},
		})
		return nil
	})
	defer deactivate()
	bridgeURL, err := c.ensureRuntimeBridge()
	if err != nil {
		t.Fatalf("ensureRuntimeBridge: %v", err)
	}

	c.registerRuntimeRoute("context-exec", "cap-token")

	body := `{"environment_id":"laptop","command":"printf SHOULD_NOT_RUN","description":"proxy exec"}`
	resp, err := http.Post(bridgeURL+"/runtime/context-exec/tool/env.exec", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("post bridge: %v", err)
	}
	defer resp.Body.Close()

	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read response: %v", err)
	}
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d body=%q", resp.StatusCode, raw)
	}
	if !strings.Contains(string(raw), `"proxied":true`) {
		t.Fatalf("response body = %q", raw)
	}

	msg := receiveMessage(t, sent)
	if msg.Type != "request" || msg.Method != "runtime_proxy" {
		t.Fatalf("runtime proxy message = %#v", msg)
	}
	if msg.Params["capability_token"] != "cap-token" {
		t.Fatalf("capability_token = %#v", msg.Params["capability_token"])
	}
	if msg.Params["method"] != "POST" {
		t.Fatalf("method = %#v", msg.Params["method"])
	}
	if msg.Params["route_path"] != "/tool/env.exec" {
		t.Fatalf("route_path = %#v", msg.Params["route_path"])
	}
	if msg.Params["body_base64"] != base64.StdEncoding.EncodeToString([]byte(body)) {
		t.Fatalf("body_base64 = %#v", msg.Params["body_base64"])
	}

	select {
	case extra := <-sent:
		t.Fatalf("env.exec should not make a local policy probe or second proxy request: %#v", extra)
	case <-time.After(50 * time.Millisecond):
	}
}

func TestSalixRuntimeCLIUsesRuntimeContext(t *testing.T) {
	c, err := newConnector(config{name: "laptop", root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	sent := make(chan message, 2)
	deactivate := activateRuntimeTransportForTest(c, func(msg message) error {
		sent <- msg
		go c.completeRuntimeProxy(message{
			ID:   msg.ID,
			Type: "response",
			Result: map[string]any{
				"status":      200,
				"body_base64": base64.StdEncoding.EncodeToString([]byte(`{"ok":true}`)),
				"headers": map[string]any{
					"content-type": "application/json",
				},
			},
		})
		return nil
	})
	defer deactivate()
	bridgeURL, err := c.ensureRuntimeBridge()
	if err != nil {
		t.Fatalf("ensureRuntimeBridge: %v", err)
	}

	c.registerRuntimeRoute("context-a", "cap-token-a")
	c.registerRuntimeRoute("context-b", "cap-token-b")
	t.Setenv("SALIX_CONNECT_URL", bridgeURL)
	t.Setenv("SALIX_RUNTIME_CONTEXT", "context-a")

	out, err := captureStdout(t, func() error {
		return runSalixRuntimeCLI([]string{"tools"})
	})
	if err != nil {
		t.Fatalf("salix tools: %v", err)
	}
	if !strings.Contains(out, `"ok":true`) {
		t.Fatalf("salix tools output = %q", out)
	}
	msg := receiveMessage(t, sent)
	if msg.Params["capability_token"] != "cap-token-a" {
		t.Fatalf("capability_token = %#v", msg.Params["capability_token"])
	}
	if msg.Params["method"] != "GET" {
		t.Fatalf("method = %#v", msg.Params["method"])
	}
	if msg.Params["route_path"] != "/tools" {
		t.Fatalf("route_path = %#v", msg.Params["route_path"])
	}

	t.Setenv("SALIX_RUNTIME_CONTEXT", "context-b")
	out, err = captureStdout(t, func() error {
		return runSalixRuntimeCLI([]string{
			"tool", "call", "im_api.slack.post_message",
			"--json", `{"text":"hi"}`,
		})
	})
	if err != nil {
		t.Fatalf("salix tool call: %v", err)
	}
	if !strings.Contains(out, `"ok":true`) {
		t.Fatalf("salix tool call output = %q", out)
	}
	msg = receiveMessage(t, sent)
	if msg.Params["capability_token"] != "cap-token-b" {
		t.Fatalf("capability_token = %#v", msg.Params["capability_token"])
	}
	if msg.Params["method"] != "POST" {
		t.Fatalf("method = %#v", msg.Params["method"])
	}
	if msg.Params["route_path"] != "/tool/im_api.slack.post_message" {
		t.Fatalf("route_path = %#v", msg.Params["route_path"])
	}
	if msg.Params["body_base64"] != base64.StdEncoding.EncodeToString([]byte(`{"text":"hi"}`)) {
		t.Fatalf("body_base64 = %#v", msg.Params["body_base64"])
	}
}

func TestCodexDeveloperInstructionsRequireVisibleIMRepliesThroughCLI(t *testing.T) {
	instructions := codexDeveloperInstructions()

	for _, want := range []string{
		"Assistant text is recorded only in the Salix runtime session",
		"not visible in a Salix conversation",
		"SALIX_CLI",
		"`\"$SALIX_CLI\" tools`",
		"`\"$SALIX_CLI\" tool call <tool_name>",
		"every user-visible IM reply",
	} {
		if !strings.Contains(instructions, want) {
			t.Fatalf("developer instructions missing %q:\n%s", want, instructions)
		}
	}
}

func TestRunRemoteOnceSendsPeriodicSystemInfo(t *testing.T) {
	isolateHostRuntimeCommands(t)

	metas := make(chan message, 4)
	upgrader := websocket.Upgrader{}

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			t.Errorf("upgrade websocket: %v", err)
			return
		}
		defer ws.Close()

		for {
			var m message
			if err := ws.ReadJSON(&m); err != nil {
				return
			}
			if m.Type == "metadata" {
				select {
				case metas <- m:
				default:
				}
			}
		}
	}))
	defer server.Close()

	connector, err := newConnector(config{
		server:             server.URL,
		token:              "test-token",
		name:               "laptop",
		root:               t.TempDir(),
		systemInfoInterval: 50 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { _ = connector.runRemoteOnce(ctx) }()

	// The first frame is the connect-time metadata; a second proves the timer
	// re-reports without any server prompting.
	first := receiveMessage(t, metas)
	if first.SystemInfo == nil {
		t.Fatalf("first metadata missing system_info")
	}

	second := receiveMessage(t, metas)
	if second.Type != "metadata" || second.SystemInfo == nil {
		t.Fatalf("expected periodic metadata with system_info, got %+v", second)
	}
}

func TestSystemInfoLoopRetriesAfterTransientPublishFailure(t *testing.T) {
	connector, err := newConnector(config{
		root:               t.TempDir(),
		systemInfoInterval: 5 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer connector.closeExternalRuntimes()

	done := make(chan struct{})
	defer close(done)
	var attempts atomic.Int32
	recovered := make(chan struct{}, 1)

	go connector.systemInfoLoopWithPublish(func() error {
		if attempts.Add(1) == 1 {
			return errors.New("transient publish failure")
		}
		select {
		case recovered <- struct{}{}:
		default:
		}
		return nil
	}, done, "")

	select {
	case <-recovered:
	case <-time.After(time.Second):
		t.Fatalf("periodic loop stopped after transient failure; attempts=%d", attempts.Load())
	}
	if got := attempts.Load(); got < 2 {
		t.Fatalf("publish attempts = %d, want at least 2", got)
	}
}

func TestPeriodicSystemInfoPublishesCachedMetadataWithoutRuntimeProbe(t *testing.T) {
	connector, err := newConnector(config{root: t.TempDir()})
	if err != nil {
		t.Fatalf("new connector: %v", err)
	}
	defer connector.closeExternalRuntimes()
	connector.runtimeInventory.run = func(runtimeProbeTarget) map[string]any {
		t.Fatal("periodic system info must not run the runtime inventory probe")
		return nil
	}

	var got message
	if err := connector.publishPeriodicSystemInfo(func(m message) error {
		got = m
		return nil
	}); err != nil {
		t.Fatalf("publish periodic system info: %v", err)
	}
	if got.Type != "metadata" {
		t.Fatalf("message type = %q, want metadata", got.Type)
	}
	if got.SystemInfo == nil || got.SystemInfo["hostname"] == "" {
		t.Fatalf("system info = %#v, want host observation", got.SystemInfo)
	}
}

func receiveMessage(t *testing.T, messages <-chan message) message {
	t.Helper()

	select {
	case msg := <-messages:
		return msg
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for connector frame")
		return message{}
	}
}

func readStatusFile(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read status: %v", err)
	}
	var status map[string]any
	if err := json.Unmarshal(data, &status); err != nil {
		t.Fatalf("decode status: %v\n%s", err, data)
	}
	return status
}

func writeJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatalf("encode json: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write json: %v", err)
	}
}

func assertCapability(t *testing.T, values map[string]any, key string, want any) {
	t.Helper()
	if got := values[key]; got != want {
		t.Fatalf("%s = %v, want %v in %v", key, got, want, values)
	}
}

func fakeCodexCommand(t *testing.T, logPath string, env map[string]string) string {
	t.Helper()
	// Readiness tests must not inherit the developer machine's real Codex
	// configuration or configured model.
	t.Setenv("CODEX_HOME", "")

	exe, err := os.Executable()
	if err != nil {
		t.Fatalf("test executable: %v", err)
	}

	codex := filepath.Join(t.TempDir(), "codex")
	envLine := "SALIX_TEST_FAKE_CODEX=1 SALIX_TEST_FAKE_CODEX_LOG=" + shellQuote(logPath)
	for key, value := range env {
		envLine += " " + key + "=" + shellQuote(value)
	}
	script := "#!/bin/sh\n" + envLine + " exec " + shellQuote(exe) + " -test.run=TestHelperCodexAppServer -- \"$@\"\n"
	if err := os.WriteFile(codex, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake codex: %v", err)
	}
	return codex
}

func TestHelperPiRPC(t *testing.T) {
	if os.Getenv("SALIX_TEST_FAKE_PI") != "1" {
		return
	}
	args := helperProcessArgs()
	for _, arg := range args {
		if arg == "--approve" {
			t.Fatal("Pi 0.73 RPC mode does not accept --approve")
		}
	}
	nativeID := "pi-native"
	modelProvider := os.Getenv("SALIX_TEST_FAKE_PI_MODEL_PROVIDER")
	if modelProvider == "" {
		modelProvider = "test"
	}
	if os.Getenv("SALIX_TEST_FAKE_RUNTIME_EXECUTE_SALIX") == "1" {
		for index, arg := range args {
			if arg == "--session-dir" && index+1 < len(args) {
				nativeID += "-" + filepath.Base(args[index+1])
			}
		}
	}
	for index, arg := range args {
		if arg == "--session" && index+1 < len(args) {
			nativeID = args[index+1]
		}
	}
	appendFakeProcessLog(os.Getenv("SALIX_TEST_FAKE_PI_LOG"), "start "+strings.Join(args, " "))
	// Match Pi's prompt-file input so transport E2E still checks the complete
	// prompt received by the child, not only the filename in its argv.
	for index, arg := range args {
		if arg == "--append-system-prompt" && index+1 < len(args) {
			prompt := args[index+1]
			if contents, err := os.ReadFile(prompt); err == nil {
				prompt = string(contents)
			}
			appendFakeProcessLog(os.Getenv("SALIX_TEST_FAKE_PI_LOG"), "system_prompt="+prompt)
		}
	}
	appendFakeProcessLog(os.Getenv("SALIX_TEST_FAKE_PI_LOG"), "context="+os.Getenv("SALIX_RUNTIME_CONTEXT"))
	if cwd, err := os.Getwd(); err == nil {
		appendFakeProcessLog(os.Getenv("SALIX_TEST_FAKE_PI_LOG"), "cwd="+cwd)
	}
	appendFakeLocalShellLog(os.Getenv("SALIX_TEST_FAKE_PI_LOG"))

	encoder := json.NewEncoder(os.Stdout)
	var writeMu sync.Mutex
	write := func(value map[string]any) {
		writeMu.Lock()
		defer writeMu.Unlock()
		_ = encoder.Encode(value)
	}
	scanner := bufio.NewScanner(os.Stdin)
	for scanner.Scan() {
		var request map[string]any
		if json.Unmarshal(scanner.Bytes(), &request) != nil {
			continue
		}
		raw, _ := json.Marshal(request)
		appendFakeProcessLog(os.Getenv("SALIX_TEST_FAKE_PI_LOG"), string(raw))
		response := map[string]any{
			"id":      request["id"],
			"type":    "response",
			"command": request["type"],
			"success": true,
		}
		if stringParam(request, "type") == "get_state" {
			response["data"] = map[string]any{
				"sessionId": nativeID,
				"model":     map[string]any{"provider": modelProvider, "id": "test-model"},
			}
		}
		if stringParam(request, "type") == "get_available_models" {
			models := []any{}
			if os.Getenv("SALIX_TEST_FAKE_PI_AUTH_READY") != "0" {
				models = append(models, map[string]any{"provider": modelProvider, "id": "test-model"})
			}
			response["data"] = map[string]any{"models": models}
		}
		if stringParam(request, "type") == "prompt" {
			runFakeManagedProviderRequest("pi", "")
			if marker := os.Getenv("SALIX_TEST_FAKE_PI_BLOCK_PROMPT_WHILE_EXISTS"); marker != "" {
				if _, err := os.Stat(marker); err == nil {
					appendFakeProcessLog(os.Getenv("SALIX_TEST_FAKE_PI_LOG"), "blocked_batch_prompt")
					for {
						if _, err := os.Stat(marker); os.IsNotExist(err) {
							break
						}
						time.Sleep(25 * time.Millisecond)
					}
				}
			}
		}
		write(response)
		input := stringParam(request, "message")
		if response["success"] != true {
			continue
		}
		if stringParam(request, "type") == "prompt" {
			if marker := os.Getenv("SALIX_TEST_FAKE_PI_FIRST_PROMPT_LIFECYCLE_MARKER"); marker != "" {
				if err := os.Remove(marker); err == nil {
					write(map[string]any{"type": "agent_start"})
					if os.Getenv("SALIX_TEST_FAKE_PI_FIRST_PROMPT_LIFECYCLE") == "settled" {
						write(map[string]any{"type": "agent_settled"})
					}
				}
			}
			runFakeCrashPendingMessageCall(os.Getenv("SALIX_TEST_FAKE_PI_LOG"))
			if decision := recordFakeRecoveryDecision(input); decision != "" {
				runFakeOfflineToolCall(os.Getenv("SALIX_TEST_FAKE_PI_LOG"))
				stopAfterMessage := runFakeOfflineMessageCall(os.Getenv("SALIX_TEST_FAKE_PI_LOG")) &&
					os.Getenv("SALIX_TEST_FAKE_OFFLINE_MESSAGE_EXIT_AFTER") == "1"
				write(map[string]any{"type": "agent_start"})
				write(map[string]any{
					"type":       "tool_execution_start",
					"toolCallId": "pi-recovery-decision",
					"toolName":   "workspace-state",
					"args":       map[string]any{"state": decision},
				})
				write(map[string]any{
					"type":       "tool_execution_end",
					"toolCallId": "pi-recovery-decision",
					"toolName":   "workspace-state",
					"result":     map[string]any{"text": decision},
				})
				write(map[string]any{"type": "agent_settled"})
				if stopAfterMessage {
					os.Exit(0)
				}
			}
			runFakeOfflineMessageCall(os.Getenv("SALIX_TEST_FAKE_PI_LOG"))
			if os.Getenv("SALIX_TEST_FAKE_PI_EXIT_AFTER_PROMPT") == "1" {
				// Normal-stop fixtures must finish their turn; exit 0 alone is
				// interruption evidence when execution is still unfinished.
				write(map[string]any{"type": "agent_start"})
				write(map[string]any{"type": "agent_settled"})
				os.Exit(0)
			}
			if rawBytes := os.Getenv("SALIX_TEST_FAKE_PI_OVERSIZED_TOOL_RESULT_BYTES"); rawBytes != "" {
				emit := true
				if marker := os.Getenv("SALIX_TEST_FAKE_PI_OVERSIZED_TOOL_RESULT_ONCE"); marker != "" {
					emit = os.Remove(marker) == nil
				}
				if emit {
					bytes, _ := strconv.Atoi(rawBytes)
					event := map[string]any{
						"type":       "tool_execution_end",
						"toolCallId": "pi-oversized-result",
						"toolName": defaultString(
							os.Getenv("SALIX_TEST_FAKE_PI_OVERSIZED_TOOL_NAME"),
							"oversized-result",
						),
						"result": map[string]any{"text": strings.Repeat("x", bytes)},
					}
					if path := os.Getenv("SALIX_TEST_FAKE_PI_OVERSIZED_TOOL_PATH"); path != "" {
						event["args"] = map[string]any{
							"path": path, "offset": 7, "limit": bytes,
							"content": "new-input-body-must-not-survive",
						}
					}
					write(event)
				}
			}
			if os.Getenv("SALIX_TEST_FAKE_RUNTIME_EXECUTE_SALIX") != "1" {
				continue
			}
			go func() {
				delayFakeRuntimeLifecycle()
				write(map[string]any{"type": "agent_start"})
				write(map[string]any{
					"type":       "tool_execution_start",
					"toolCallId": "pi-visible-reply",
					"toolName":   "bash",
					"args":       map[string]any{"command": "salix tool call im_api.internal.send_message"},
				})
				if token := completeFakeRuntimeVisibleReply("pi", input); token != "" {
					write(map[string]any{
						"type":       "tool_execution_end",
						"toolCallId": "pi-visible-reply",
						"toolName":   "bash",
						"result":     map[string]any{"text": token},
					})
					write(map[string]any{
						"type": "message_end",
						"message": map[string]any{
							"role":    "assistant",
							"content": []any{map[string]any{"type": "text", "text": token}},
						},
					})
					write(map[string]any{"type": "agent_settled"})
				}
			}()
		}
	}
	os.Exit(0)
}

func runFakeManagedProviderRequest(provider, model string) {
	if os.Getenv("SALIX_TEST_MANAGED_PROVIDER_E2E") != "1" {
		return
	}
	endpoint, protocol, key, authScheme := "", "", "", ""
	switch provider {
	case "pi":
		raw, err := os.ReadFile(filepath.Join(os.Getenv("PI_CODING_AGENT_DIR"), "models.json"))
		if err != nil {
			return
		}
		var config map[string]any
		if json.Unmarshal(raw, &config) != nil {
			return
		}
		entry := mapParam(mapParam(config, "providers"), "salix-managed")
		endpoint, protocol = stringParam(entry, "baseUrl"), stringParam(entry, "api")
		keyRef := strings.TrimPrefix(stringParam(entry, "apiKey"), "$")
		key = os.Getenv(keyRef)
		if entry["authHeader"] == true {
			authScheme = "bearer"
		} else {
			authScheme = "api_key"
		}
		for index, arg := range helperProcessArgs() {
			if arg == "--model" && index+1 < len(helperProcessArgs()) {
				model = helperProcessArgs()[index+1]
			}
		}
	case "claude":
		endpoint, protocol = os.Getenv("ANTHROPIC_BASE_URL"), "anthropic-messages"
		key, authScheme = os.Getenv("ANTHROPIC_AUTH_TOKEN"), "bearer"
		if key == "" {
			key, authScheme = os.Getenv("ANTHROPIC_API_KEY"), "api_key"
		}
	}
	path := map[string]string{"openai-completions": "/chat/completions", "openai-responses": "/responses", "anthropic-messages": "/v1/messages"}[protocol]
	request, err := http.NewRequest(http.MethodPost, strings.TrimRight(endpoint, "/")+path, strings.NewReader(fmt.Sprintf(`{"model":%q}`, model)))
	if err != nil {
		return
	}
	request.Header.Set("Content-Type", "application/json")
	if authScheme == "bearer" {
		request.Header.Set("Authorization", "Bearer "+key)
	} else {
		request.Header.Set("x-api-key", key)
	}
	client := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}, Timeout: 3 * time.Second} // #nosec G402 -- synthetic test server only.
	response, err := client.Do(request)
	if err == nil {
		response.Body.Close()
	}
}

func runFakeOfflineToolCall(logPath string) {
	trigger := os.Getenv("SALIX_TEST_FAKE_OFFLINE_TOOL_TRIGGER")
	if trigger == "" {
		return
	}
	if err := os.Remove(trigger); err != nil {
		return
	}
	started := time.Now()
	output, err := exec.Command(
		"salix",
		"tool",
		"call",
		"env.exec",
		"--json",
		`{"command":"pwd","description":"offline e2e"}`,
	).CombinedOutput()
	appendFakeProcessLog(
		logPath,
		fmt.Sprintf(
			"offline_tool err=%v elapsed_ms=%d output=%s",
			err,
			time.Since(started).Milliseconds(),
			strings.TrimSpace(string(output)),
		),
	)
}

func runFakeOfflineMessageCall(logPath string) bool {
	trigger := os.Getenv("SALIX_TEST_FAKE_OFFLINE_MESSAGE_TRIGGER")
	if trigger == "" {
		return false
	}
	if err := os.Remove(trigger); err != nil {
		return false
	}
	payloadBytes, _ := json.Marshal(map[string]any{
		"connect_id":      "internal",
		"conversation_id": "cnv1_0000000000000000001",
		"content": []any{map[string]any{
			"type": "text", "text": "COMMA31_OFFLINE_MESSAGE",
		}},
	})
	output, err := exec.Command(
		"salix",
		"tool",
		"call",
		"im_api.internal.send_message",
		"--json",
		string(payloadBytes),
	).CombinedOutput()
	appendFakeProcessLog(
		logPath,
		fmt.Sprintf(
			"offline_message err=%v output=%s",
			err,
			strings.TrimSpace(string(output)),
		),
	)
	return true
}

func runFakeCrashPendingMessageCall(logPath string) {
	trigger := os.Getenv("SALIX_TEST_FAKE_CRASH_PENDING_MESSAGE_TRIGGER")
	if trigger == "" {
		return
	}
	if err := os.Remove(trigger); err != nil {
		return
	}
	payload := `{"connect_id":"internal","conversation_id":"cnv1_0000000000000000001","content":[{"type":"text","text":"COMMA31_CRASH_PENDING_MESSAGE"}]}`
	output, err := exec.Command(
		"salix",
		"tool",
		"call",
		"im_api.internal.send_message",
		"--json",
		payload,
	).CombinedOutput()
	appendFakeProcessLog(
		logPath,
		fmt.Sprintf(
			"crash_pending_message err=%v output=%s",
			err,
			strings.TrimSpace(string(output)),
		),
	)
}

func TestHelperKimiServer(t *testing.T) {
	if os.Getenv("SALIX_TEST_FAKE_KIMI") != "1" {
		return
	}
	args := helperProcessArgs()
	if len(args) != 6 || args[0] != "web" || args[1] != "--no-open" || args[2] != "--port" {
		fmt.Fprintf(os.Stderr, "unexpected fake kimi args: %#v\n", args)
		os.Exit(2)
	}
	port := args[3]
	logPath := os.Getenv("SALIX_TEST_FAKE_KIMI_LOG")
	nativeID := "kimi-native"
	if os.Getenv("SALIX_TEST_FAKE_RUNTIME_EXECUTE_SALIX") == "1" {
		nativeID += "-" + filepath.Base(os.Getenv("KIMI_CODE_HOME"))
	}
	appendFakeProcessLog(logPath, "start "+strings.Join(args, " "))
	appendFakeProcessLog(logPath, "context="+os.Getenv("SALIX_RUNTIME_CONTEXT"))
	if cwd, err := os.Getwd(); err == nil {
		appendFakeProcessLog(logPath, "cwd="+cwd)
	}
	appendFakeLocalShellLog(logPath)
	if agents, err := os.ReadFile(filepath.Join(os.Getenv("KIMI_CODE_HOME"), "AGENTS.md")); err == nil {
		appendFakeProcessLog(logPath, "agents="+string(agents))
	}
	if err := os.WriteFile(filepath.Join(os.Getenv("KIMI_CODE_HOME"), "server.token"), []byte("fake-kimi-token\n"), 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "write fake kimi token: %v\n", err)
		os.Exit(2)
	}

	var promptMu sync.Mutex
	promptCount := 0
	upgrader := websocket.Upgrader{}
	var wsMu sync.RWMutex
	var wsWriteMu sync.Mutex
	var activeWS *websocket.Conn
	writeWS := func(event map[string]any) {
		wsMu.RLock()
		ws := activeWS
		wsMu.RUnlock()
		if ws == nil {
			return
		}
		wsWriteMu.Lock()
		defer wsWriteMu.Unlock()
		_ = ws.WriteJSON(event)
	}
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer fake-kimi-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		appendFakeProcessLog(logPath, r.Method+" "+r.URL.Path)
		if r.URL.Path == "/api/v1/healthz" {
			_, _ = io.WriteString(w, "{}")
			return
		}
		if r.URL.Path == "/api/v1/ws" {
			ws, err := upgrader.Upgrade(w, r, nil)
			if err != nil {
				return
			}
			wsMu.Lock()
			activeWS = ws
			wsMu.Unlock()
			defer func() {
				wsMu.Lock()
				if activeWS == ws {
					activeWS = nil
				}
				wsMu.Unlock()
				_ = ws.Close()
			}()
			var hello map[string]any
			if ws.ReadJSON(&hello) != nil {
				return
			}
			appendFakeProcessLog(logPath, "client_hello")
			if ws.WriteJSON(map[string]any{"type": "ping", "payload": map[string]any{"id": "fake-ping"}}) != nil {
				return
			}
			var pong map[string]any
			if ws.ReadJSON(&pong) == nil {
				appendFakeProcessLog(logPath, stringParam(pong, "type"))
			}
			for {
				if _, _, err := ws.ReadMessage(); err != nil {
					return
				}
			}
		}

		writeEnvelope := func(data map[string]any) {
			w.Header().Set("Content-Type", "application/json")
			_ = json.NewEncoder(w).Encode(map[string]any{"code": 0, "data": data})
		}
		switch {
		case r.Method == http.MethodGet && r.URL.Path == "/api/v1/auth":
			if os.Getenv("SALIX_TEST_FAKE_KIMI_AUTH_READY") == "0" {
				writeEnvelope(map[string]any{
					"ready":            false,
					"providers_count":  0,
					"default_model":    nil,
					"managed_provider": nil,
				})
			} else {
				writeEnvelope(map[string]any{
					"ready":           true,
					"providers_count": 1,
					"default_model":   "kimi-test",
					"managed_provider": map[string]any{
						"name":   "kimi-test",
						"status": "authenticated",
					},
				})
			}
		case r.Method == http.MethodPost && r.URL.Path == "/api/v1/sessions":
			writeEnvelope(map[string]any{"id": nativeID})
		case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/api/v1/sessions/"):
			writeEnvelope(map[string]any{"id": strings.TrimPrefix(r.URL.Path, "/api/v1/sessions/")})
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/prompts:steer"):
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			raw, _ := json.Marshal(body)
			appendFakeProcessLog(logPath, string(raw))
			writeEnvelope(map[string]any{})
		case r.Method == http.MethodPost && strings.HasSuffix(r.URL.Path, "/prompts"):
			var body map[string]any
			_ = json.NewDecoder(r.Body).Decode(&body)
			raw, _ := json.Marshal(body)
			appendFakeProcessLog(logPath, string(raw))
			input := contentBlockText(body["content"], "text", "text")
			sessionID := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, "/api/v1/sessions/"), "/prompts")
			promptMu.Lock()
			promptCount++
			current := promptCount
			promptMu.Unlock()
			if current == 2 {
				writeEnvelope(map[string]any{"status": "queued", "prompt_id": "prompt-2"})
			} else {
				writeEnvelope(map[string]any{"status": "running", "prompt_id": "prompt-1"})
			}
			if decision := recordFakeRecoveryDecision(input); decision != "" {
				go func() {
					writeWS(map[string]any{
						"type":       "turn.started",
						"session_id": sessionID,
						"payload":    map[string]any{"status": "running"},
					})
					writeWS(map[string]any{
						"type":       "tool.call.started",
						"session_id": sessionID,
						"payload": map[string]any{
							"type":       "tool.call.started",
							"toolCallId": "kimi-recovery-decision",
							"name":       "workspace-state",
							"args":       map[string]any{"state": decision},
						},
					})
					writeWS(map[string]any{
						"type":       "tool.result",
						"session_id": sessionID,
						"payload": map[string]any{
							"type":       "tool.result",
							"toolCallId": "kimi-recovery-decision",
							"output":     decision,
						},
					})
					writeWS(map[string]any{
						"type":       "turn.ended",
						"session_id": sessionID,
						"payload": map[string]any{
							"type":   "turn.ended",
							"status": "completed",
						},
					})
				}()
			}
			if os.Getenv("SALIX_TEST_FAKE_RUNTIME_EXECUTE_SALIX") == "1" {
				go func() {
					delayFakeRuntimeLifecycle()
					writeWS(map[string]any{
						"type":       "turn.started",
						"session_id": sessionID,
						"payload":    map[string]any{"status": "running"},
					})
					writeWS(map[string]any{
						"type":       "tool.call.started",
						"session_id": sessionID,
						"payload": map[string]any{
							"type":       "tool.call.started",
							"toolCallId": "kimi-visible-reply",
							"name":       "Bash",
							"args":       map[string]any{"command": "salix tool call im_api.internal.send_message"},
						},
					})
					if token := completeFakeRuntimeVisibleReply("kimi", input); token != "" {
						writeWS(map[string]any{
							"type":       "tool.result",
							"session_id": sessionID,
							"payload": map[string]any{
								"type":       "tool.result",
								"toolCallId": "kimi-visible-reply",
								"output":     token,
							},
						})
						writeWS(map[string]any{
							"type":       "assistant.delta",
							"session_id": sessionID,
							"payload":    map[string]any{"type": "assistant.delta", "delta": token},
						})
						writeWS(map[string]any{
							"type":       "turn.ended",
							"session_id": sessionID,
							"payload":    map[string]any{"status": "completed"},
						})
					}
				}()
			}
			if os.Getenv("SALIX_TEST_FAKE_KIMI_EXIT_AFTER_PROMPT") == "1" {
				writeWS(map[string]any{"type": "turn.started", "session_id": sessionID})
				writeWS(map[string]any{"type": "turn.ended", "session_id": sessionID,
					"payload": map[string]any{"status": "completed"}})
				go func() { time.Sleep(50 * time.Millisecond); os.Exit(0) }()
			}
		default:
			http.NotFound(w, r)
		}
	})
	server := &http.Server{Addr: "127.0.0.1:" + port, Handler: handler}
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "fake kimi server: %v\n", err)
		os.Exit(2)
	}
	os.Exit(0)
}

func appendFakeProcessLog(path, line string) {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	_, _ = fmt.Fprintln(file, line)
	_ = file.Close()
}

func recordFakeRecoveryDecision(input string) string {
	recoveryMessage := externalRuntimeRecoveryMessage
	if os.Getenv("SALIX_TEST_FAKE_EXPECT_RECREATED_THREAD") == "1" {
		recoveryMessage = externalRuntimeRecreatedMessage
	}
	if !strings.Contains(input, recoveryMessage) {
		return ""
	}
	statePath := os.Getenv("SALIX_TEST_FAKE_RECOVERY_STATE_PATH")
	decisionPath := os.Getenv("SALIX_TEST_FAKE_RECOVERY_DECISION_PATH")
	state, err := os.ReadFile(statePath)
	if err != nil || decisionPath == "" {
		return ""
	}
	decision := strings.TrimSpace(string(state))
	if decision != "continue" && decision != "complete" {
		return ""
	}
	appendFakeProcessLog(decisionPath, decision)
	return decision
}

func claimFakeCodexRecoveryResponseDrop() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_DROP_RECOVERY_RESPONSE_ONCE")
	if path == "" {
		return false
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return false
	}
	_ = file.Close()
	return true
}

func claimFakeCodexLoginStartResponseDrop() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_DROP_LOGIN_START_RESPONSE_ONCE")
	if path == "" {
		return false
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return false
	}
	_ = file.Close()
	return true
}

func claimFakeCodexAccountReadFailure() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_FAIL_ACCOUNT_READ_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexLoginStartFailure() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_FAIL_LOGIN_START_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexLoginCancelResponseDrop() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_DROP_LOGIN_CANCEL_RESPONSE_ONCE")
	if path == "" {
		return false
	}
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return false
	}
	_ = file.Close()
	return true
}

func TestHelperCodexAppServer(t *testing.T) {
	if os.Getenv("SALIX_TEST_FAKE_CODEX") != "1" {
		return
	}
	args := helperProcessArgs()
	if len(args) == 1 && args[0] == "--version" {
		fmt.Println(defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_VERSION"), "codex fake"))
		os.Exit(0)
	}
	if len(args) == 2 && args[0] == "login" && args[1] == "status" {
		appendFakeCodexLog("login status")
		if marker := os.Getenv("SALIX_TEST_FAKE_CODEX_AUTH_FAILURE_WHILE_EXISTS"); marker != "" {
			if _, err := os.Stat(marker); err == nil {
				fmt.Fprintln(os.Stderr, "Not logged in")
				os.Exit(1)
			}
		}
		if stderr := os.Getenv("SALIX_TEST_FAKE_CODEX_LOGIN_STDERR"); stderr != "" {
			fmt.Fprintln(os.Stderr, stderr)
		}
		if code := os.Getenv("SALIX_TEST_FAKE_CODEX_LOGIN_EXIT"); code != "" {
			exit, _ := strconv.Atoi(code)
			os.Exit(exit)
		}
		fmt.Println("Logged in using fake")
		os.Exit(0)
	}
	if len(args) != 5 || args[0] != "app-server" || args[1] != "--disable" ||
		args[2] != "tool_suggest" || args[3] != "--listen" {
		fmt.Fprintf(os.Stderr, "unexpected fake codex args: %#v\n", args)
		os.Exit(2)
	}
	if stderr := os.Getenv("SALIX_TEST_FAKE_CODEX_APP_SERVER_STDERR"); stderr != "" {
		fmt.Fprintln(os.Stderr, stderr)
	}
	if code := os.Getenv("SALIX_TEST_FAKE_CODEX_APP_SERVER_EXIT"); code != "" {
		exit, _ := strconv.Atoi(code)
		os.Exit(exit)
	}
	listen, err := url.Parse(args[4])
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse listen url: %v\n", err)
		os.Exit(2)
	}
	appendFakeCodexLog("start")
	waitForFakeMarker(os.Getenv("SALIX_TEST_FAKE_CODEX_READINESS_GATE"))
	if claimFakeCodexNormalExitBeforeListen() {
		os.Exit(0)
	}
	appendFakeLocalShellLog(os.Getenv("SALIX_TEST_FAKE_CODEX_LOG"))

	upgrader := websocket.Upgrader{}
	threadSeq := 0
	turnSeq := 0
	accountType := defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE"), "chatgpt")
	loginSeq := 0
	loginCanceled := map[string]bool{}
	var accountMu sync.Mutex
	threadPrefix := ""
	if os.Getenv("SALIX_TEST_FAKE_CODEX_MISSING_THREAD_ON_RESUME") == "1" {
		threadPrefix = fmt.Sprintf("%d-", os.Getpid())
	}
	server := &http.Server{
		Addr: listen.Host,
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			ws, err := upgrader.Upgrade(w, r, nil)
			if err != nil {
				return
			}
			defer ws.Close()
			initialized := false
			var writeMu sync.Mutex
			write := func(payload map[string]any) error {
				writeMu.Lock()
				defer writeMu.Unlock()
				return ws.WriteJSON(payload)
			}
			if gate := os.Getenv("SALIX_TEST_FAKE_CODEX_EXTERNAL_ACCOUNT_GATE"); gate != "" {
				go func() {
					waitForFakeMarker(gate)
					nextType := defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_EXTERNAL_ACCOUNT_TYPE"), "chatgpt")
					accountMu.Lock()
					accountType = nextType
					accountMu.Unlock()
					authMode := any("chatgpt")
					if nextType == "none" {
						authMode = nil
					}
					_ = write(map[string]any{
						"method": "account/updated",
						"params": map[string]any{"authMode": authMode},
					})
				}()
			}
			for {
				var msg map[string]any
				if err := ws.ReadJSON(&msg); err != nil {
					return
				}
				method := stringFromAny(msg["method"])
				appendFakeCodexLog(method)
				if method == "thread/start" || method == "thread/resume" ||
					method == "turn/start" || method == "turn/steer" {
					appendFakeCodexJSONLog(method, mapParam(msg, "params"))
				}
				id := msg["id"]
				if id == "subscription-refresh-test" && method == "" {
					if stringParam(mapParam(msg, "result"), "accessToken") == "rotated-access" {
						appendFakeCodexLog("subscription-refresh-accepted")
					} else {
						appendFakeCodexLog("subscription-refresh-rejected")
					}
					continue
				}
				switch method {
				case "initialize":
					if claimFakeCodexInitializeConnectionClose() {
						return
					}
					if initialized {
						_ = write(map[string]any{
							"id": id,
							"error": map[string]any{
								"code":    -32600,
								"message": "Already initialized",
							},
						})
						continue
					}
					if claimFakeCodexInitializeFailure() {
						_ = write(map[string]any{
							"id": id,
							"error": map[string]any{
								"code":    -32603,
								"message": "transient initialize failure",
							},
						})
						continue
					}
					initialized = true
					if claimFakeCodexInitializeResponseDrop() {
						continue
					}
					_ = write(map[string]any{"id": id, "result": map[string]any{"ok": true}})
				case "config/read":
					_ = write(map[string]any{"id": id, "result": map[string]any{"config": map[string]any{"cli_auth_credentials_store": "file"}}})
				case "account/read":
					waitForFakeMarker(os.Getenv("SALIX_TEST_FAKE_CODEX_ACCOUNT_READ_GATE"))
					if claimFakeCodexAccountReadFailure() {
						_ = write(map[string]any{
							"id":    id,
							"error": map[string]any{"code": -32603, "message": "transient account read failure"},
						})
						continue
					}
					accountMu.Lock()
					currentAccountType := accountType
					accountMu.Unlock()
					if marker := os.Getenv("SALIX_TEST_FAKE_CODEX_AUTH_FAILURE_WHILE_EXISTS"); marker != "" {
						if _, err := os.Stat(marker); err == nil {
							currentAccountType = "none"
						}
					}
					if marker := os.Getenv("SALIX_TEST_FAKE_CODEX_AUTH_SUCCESS_WHILE_EXISTS"); marker != "" {
						if _, err := os.Stat(marker); err == nil {
							currentAccountType = "chatgpt"
						}
					}
					_ = write(map[string]any{
						"id":     id,
						"result": fakeCodexAccountResult(currentAccountType),
					})
				case "account/login/start":
					params := mapParam(msg, "params")
					if stringParam(params, "type") == "chatgptAuthTokens" {
						if stringParam(params, "accessToken") == "" || stringParam(params, "chatgptAccountId") == "" {
							_ = write(map[string]any{"id": id, "error": map[string]any{"code": -32602, "message": "missing external auth material"}})
							continue
						}
						if stringParam(params, "accessToken") == "rotated-access" {
							appendFakeCodexLog("subscription-rotated-login")
						}
						accountMu.Lock()
						accountType = "chatgpt"
						accountMu.Unlock()
						_ = write(map[string]any{"id": id, "result": map[string]any{"type": "chatgptAuthTokens"}})
						continue
					}
					if stringParam(params, "type") != "chatgptDeviceCode" {
						_ = write(map[string]any{
							"id":    id,
							"error": map[string]any{"code": -32602, "message": "unsupported fake login flow"},
						})
						continue
					}
					if claimFakeCodexLoginStartFailure() {
						_ = write(map[string]any{
							"id":    id,
							"error": map[string]any{"code": -32603, "message": "transient login start failure"},
						})
						continue
					}
					accountMu.Lock()
					loginSeq++
					loginID := fmt.Sprintf("native-login-%d", loginSeq)
					loginCanceled[loginID] = false
					accountMu.Unlock()
					if claimFakeCodexLoginStartResponseDrop() {
						continue
					}
					responseLoginID := loginID
					if os.Getenv("SALIX_TEST_FAKE_CODEX_OMIT_LOGIN_ID") == "1" {
						responseLoginID = ""
					}
					_ = write(map[string]any{
						"id": id,
						"result": map[string]any{
							"type":            "chatgptDeviceCode",
							"loginId":         responseLoginID,
							"verificationUrl": defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_VERIFICATION_URL"), "https://auth.openai.com/codex/device"),
							"userCode":        defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_USER_CODE"), "ABCD-EFGH"),
						},
					})
					if os.Getenv("SALIX_TEST_FAKE_CODEX_EXIT_IMMEDIATELY_AFTER_LOGIN_START") == "1" {
						os.Exit(0)
					}
					if os.Getenv("SALIX_TEST_FAKE_CODEX_EXIT_AFTER_LOGIN_START") == "1" {
						go func() {
							time.Sleep(50 * time.Millisecond)
							os.Exit(0)
						}()
					}
					if gate := os.Getenv("SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE"); gate != "" {
						go func(nativeLoginID string) {
							waitForFakeMarker(gate)
							accountMu.Lock()
							canceled := loginCanceled[nativeLoginID]
							failure := os.Getenv("SALIX_TEST_FAKE_CODEX_LOGIN_OUTCOME") == "failure"
							if !canceled && !failure {
								accountType = "chatgpt"
							}
							accountMu.Unlock()
							if canceled {
								return
							}
							completionLoginID := defaultString(
								os.Getenv("SALIX_TEST_FAKE_CODEX_COMPLETION_LOGIN_ID"),
								nativeLoginID,
							)
							_ = write(map[string]any{
								"method": "account/login/completed",
								"params": map[string]any{
									"loginId": completionLoginID,
									"success": !failure,
									"error":   map[bool]any{true: "provider-secret-detail", false: nil}[failure],
								},
							})
							if !failure {
								_ = write(map[string]any{
									"method": "account/updated",
									"params": map[string]any{"authMode": "chatgpt"},
								})
							}
						}(loginID)
					}
				case "account/login/cancel":
					nativeLoginID := stringParam(mapParam(msg, "params"), "loginId")
					if claimFakeCodexLoginCancelResponseDrop() {
						continue
					}
					accountMu.Lock()
					_, found := loginCanceled[nativeLoginID]
					if found {
						loginCanceled[nativeLoginID] = true
					}
					accountMu.Unlock()
					status := "notFound"
					if found {
						status = "canceled"
					}
					_ = write(map[string]any{"id": id, "result": map[string]any{"status": status}})
				case "model/list":
					models := strings.Split(defaultString(os.Getenv("SALIX_TEST_FAKE_CODEX_MODELS"), "gpt-test"), ",")
					items := make([]map[string]any, 0, len(models))
					for _, model := range models {
						items = append(items, map[string]any{"id": model, "model": model})
					}
					_ = write(map[string]any{"id": id, "result": map[string]any{"data": items}})
				case "thread/start":
					threadSeq++
					if claimFakeCodexNormalExitBeforeThreadStartResponse() {
						os.Exit(0)
					}
					_ = write(map[string]any{
						"id":     id,
						"result": map[string]any{"thread": map[string]any{"id": fmt.Sprintf("thread-%s%d", threadPrefix, threadSeq)}},
					})
				case "thread/resume":
					threadID := stringParam(mapParam(msg, "params"), "threadId")
					if claimFakeCodexThreadResumeFailure() {
						_ = write(map[string]any{
							"id": id,
							"error": map[string]any{
								"code":    -32603,
								"message": "transient thread/resume failure",
							},
						})
						continue
					}
					if os.Getenv("SALIX_TEST_FAKE_CODEX_MISSING_THREAD_ON_RESUME") == "1" {
						_ = write(map[string]any{
							"id": id,
							"error": map[string]any{
								"code":    -32600,
								"message": "no rollout found for thread id " + threadID,
							},
						})
						continue
					}
					_ = write(map[string]any{
						"id":     id,
						"result": map[string]any{"thread": map[string]any{"id": threadID}},
					})
				case "thread/read":
					if !initialized {
						_ = write(map[string]any{
							"id": id,
							"error": map[string]any{
								"code":    -32600,
								"message": "Not initialized",
							},
						})
						continue
					}
					threadID := stringParam(mapParam(msg, "params"), "threadId")
					if claimFakeCodexMalformedThreadRead() {
						_ = write(map[string]any{
							"id":     id,
							"result": map[string]any{"thread": map[string]any{"id": "unexpected-thread"}},
						})
						continue
					}
					if claimFakeCodexMissingThreadRead() {
						_ = write(map[string]any{
							"id": id,
							"error": map[string]any{
								"code":    -32600,
								"message": "no rollout found for thread id " + threadID,
							},
						})
						continue
					}
					if claimFakeCodexCloseThreadRead() {
						return
					}
					_ = write(map[string]any{
						"id":     id,
						"result": map[string]any{"thread": map[string]any{"id": threadID}},
					})
				case "turn/start":
					turnSeq++
					turnID := fmt.Sprintf("turn-%d", turnSeq)
					params := mapParam(msg, "params")
					inputText := fakeCodexInputText(params)
					maxInputChars, _ := strconv.Atoi(os.Getenv("SALIX_TEST_FAKE_CODEX_MAX_INPUT_CHARS"))
					if maxInputChars > 0 && utf8.RuneCountInString(inputText) > maxInputChars {
						appendFakeCodexLog("turn/rejected input_too_large")
						_ = write(map[string]any{
							"id": id,
							"error": map[string]any{
								"code":    -32600,
								"message": fmt.Sprintf("Input exceeds the maximum length of %d characters.", maxInputChars),
							},
						})
						continue
					}
					decision := recordFakeRecoveryDecision(inputText)
					if decision != "" {
						_ = write(map[string]any{
							"method": "turn/started",
							"params": map[string]any{
								"threadId": stringParam(params, "threadId"),
								"turn":     map[string]any{"id": turnID, "status": "inProgress"},
							},
						})
						completeFakeCodexRecoveryTurn(write, params, turnID, decision)
						if !claimFakeCodexRecoveryResponseDrop() {
							_ = write(map[string]any{
								"id":     id,
								"result": map[string]any{"turn": map[string]any{"id": turnID}},
							})
						}
					} else {
						_ = write(map[string]any{
							"id":     id,
							"result": map[string]any{"turn": map[string]any{"id": turnID}},
						})
						go func() {
							delayFakeRuntimeLifecycle()
							_ = write(map[string]any{
								"method": "turn/started",
								"params": map[string]any{
									"threadId": stringParam(params, "threadId"),
									"turn":     map[string]any{"id": turnID, "status": "inProgress"},
								},
							})
							completeFakeCodexTurn(write, params, turnID)
							exitFakeCodexAfterCompletedTurnIfRequested()
						}()
					}
					if os.Getenv("SALIX_TEST_FAKE_CODEX_EXIT_AFTER_TURN") == "1" {
						go func() { time.Sleep(50 * time.Millisecond); os.Exit(0) }()
					}
				case "turn/steer":
					params := mapParam(msg, "params")
					turnID := stringParam(params, "expectedTurnId")
					_ = write(map[string]any{"id": id, "result": map[string]any{"ok": true}})
					go func() {
						completeFakeCodexTurn(write, params, turnID)
						exitFakeCodexAfterCompletedTurnIfRequested()
					}()
				default:
					_ = write(map[string]any{"id": id, "result": map[string]any{"ok": true}})
				}
			}
		}),
	}
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		fmt.Fprintf(os.Stderr, "fake codex server: %v\n", err)
		os.Exit(2)
	}
	os.Exit(0)
}

func appendFakeLocalShellLog(logPath string) {
	localRoot := os.Getenv("SALIX_ENV_ROOT")
	localShell := exec.Command("sh", "-c", "test -d \"$SALIX_ENV_ROOT\" && printf local-shell-ok")
	localShell.Env = os.Environ()
	localOutput, localErr := localShell.CombinedOutput()
	cliOutput := ""
	cliErr := error(nil)
	if info, err := os.Stat(os.Getenv("SALIX_CLI")); err != nil {
		cliErr = err
	} else if info.Mode().IsRegular() && info.Mode().Perm()&0o111 != 0 {
		cliOutput = "salix-cli-ok"
	} else {
		cliErr = fmt.Errorf("SALIX_CLI is not an executable regular file")
	}
	appendFakeProcessLog(
		logPath,
		fmt.Sprintf(
			"local_shell root=%s err=%v output=%s cli_err=%v cli_output=%s",
			localRoot,
			localErr,
			strings.TrimSpace(string(localOutput)),
			cliErr,
			cliOutput,
		),
	)
}

func exitFakeCodexAfterCompletedTurnIfRequested() {
	gate := os.Getenv("SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_GATE")
	if gate == "" {
		return
	}
	if _, err := os.Stat(gate); err != nil {
		return
	}
	time.Sleep(50 * time.Millisecond)
	os.Exit(0)
}

func completeFakeCodexRecoveryTurn(write func(map[string]any) error, params map[string]any, turnID, decision string) {
	threadID := stringParam(params, "threadId")
	operationID := "codex-recovery-decision"
	_ = write(map[string]any{
		"method": "item/started",
		"params": map[string]any{
			"threadId": threadID,
			"item": map[string]any{
				"type":    "commandExecution",
				"id":      operationID,
				"status":  "inProgress",
				"command": "inspect workspace recovery state",
				"cwd":     ".",
			},
		},
	})
	_ = write(map[string]any{
		"method": "item/completed",
		"params": map[string]any{
			"threadId": threadID,
			"item": map[string]any{
				"type":             "commandExecution",
				"id":               operationID,
				"status":           "completed",
				"command":          "inspect workspace recovery state",
				"cwd":              ".",
				"aggregatedOutput": decision,
			},
		},
	})
	_ = write(map[string]any{
		"method": "item/completed",
		"params": map[string]any{
			"threadId": threadID,
			"item":     map[string]any{"type": "agentMessage", "text": "recovery-decision:" + decision},
		},
	})
	_ = write(map[string]any{
		"method": "turn/completed",
		"params": map[string]any{
			"threadId": threadID,
			"turn":     map[string]any{"id": turnID, "status": "completed"},
		},
	})
}

func completeFakeCodexTurn(write func(map[string]any) error, params map[string]any, turnID string) {
	if os.Getenv("SALIX_TEST_FAKE_CODEX_EXECUTE_SALIX") != "1" {
		if os.Getenv("SALIX_TEST_FAKE_CODEX_COMPLETE_TURN") == "1" {
			time.Sleep(50 * time.Millisecond)
			_ = write(map[string]any{
				"method": "turn/completed",
				"params": map[string]any{
					"threadId": stringParam(params, "threadId"),
					"turn":     map[string]any{"id": turnID, "status": "completed"},
				},
			})
		}
		return
	}
	input := fakeRuntimeInputText(fakeCodexInputText(params))
	waitForFakeRuntimeObservationLoss(input)
	delay := 50 * time.Millisecond
	if strings.Contains(input, "COMMA31_CONCURRENT_A") {
		delay = 2 * time.Second
	}
	time.Sleep(delay)
	if !waitForFakeRuntimeReconnect(input) {
		appendFakeCodexLog("visible_reply reconnect wait timed out")
		return
	}

	conversationID := lineValue(input, "- conversation_id:")
	replyToken := comma31ReplyText(input)
	if conversationID == "" || replyToken == "" {
		appendFakeCodexLog("visible_reply skipped")
		return
	}
	payload, _ := json.Marshal(map[string]any{
		"connect_id":      "internal",
		"conversation_id": conversationID,
		"content":         []any{map[string]any{"type": "text", "text": replyToken}},
	})
	cmd := exec.Command("salix", "tool", "call", "im_api.internal.send_message", "--json", string(payload))
	cmd.Env = append(os.Environ(), "CODEX_THREAD_ID="+stringParam(params, "threadId"))
	output, err := cmd.CombinedOutput()
	appendFakeCodexLog(fmt.Sprintf("visible_reply %s err=%v output=%s", replyToken, err, strings.TrimSpace(string(output))))
	if err != nil {
		return
	}

	threadID := stringParam(params, "threadId")
	operationID := "codex-visible-reply"
	_ = write(map[string]any{
		"method": "item/started",
		"params": map[string]any{
			"threadId": threadID,
			"item": map[string]any{
				"type":    "commandExecution",
				"id":      operationID,
				"status":  "inProgress",
				"command": "salix tool call im_api.internal.send_message",
				"cwd":     ".",
			},
		},
	})
	_ = write(map[string]any{
		"method": "item/completed",
		"params": map[string]any{
			"threadId": threadID,
			"item": map[string]any{
				"type":             "commandExecution",
				"id":               operationID,
				"status":           "completed",
				"command":          "salix tool call im_api.internal.send_message",
				"cwd":              ".",
				"aggregatedOutput": string(output),
			},
		},
	})
	_ = write(map[string]any{
		"method": "item/completed",
		"params": map[string]any{
			"threadId": threadID,
			"item":     map[string]any{"type": "agentMessage", "text": replyToken},
		},
	})
	_ = write(map[string]any{
		"method": "turn/completed",
		"params": map[string]any{
			"threadId": threadID,
			"turn":     map[string]any{"id": turnID, "status": "completed"},
		},
	})
}

func waitForFakeRuntimeObservationLoss(input string) {
	gate := os.Getenv("SALIX_TEST_FAKE_RUNTIME_OBSERVATION_LOSS_GATE")
	if gate == "" || !strings.Contains(input, "COMMA31_OBSERVATION_LOSS") {
		return
	}
	_ = os.WriteFile(gate+".waiting", []byte("waiting\n"), 0o600)
	waitForFakeMarker(gate)
}

func delayFakeRuntimeLifecycle() {
	if gate := os.Getenv("SALIX_TEST_FAKE_RUNTIME_LIFECYCLE_GATE"); gate != "" {
		_ = os.WriteFile(gate+".waiting", []byte("waiting\n"), 0o600)
		waitForFakeMarker(gate)
	}
	delay, _ := strconv.Atoi(os.Getenv("SALIX_TEST_FAKE_RUNTIME_LIFECYCLE_DELAY_MS"))
	if delay > 0 {
		time.Sleep(time.Duration(delay) * time.Millisecond)
	}
}

func waitForFakeMarker(path string) {
	for path != "" {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func fakeCodexAccountResult(accountType string) map[string]any {
	result := map[string]any{"requiresOpenaiAuth": true, "account": nil}
	switch accountType {
	case "none":
		return result
	case "notRequired":
		result["requiresOpenaiAuth"] = false
		return result
	case "chatgpt":
		result["account"] = map[string]any{
			"type": "chatgpt", "email": "private@example.test", "planType": "enterprise",
		}
	case "amazonBedrock":
		result["account"] = map[string]any{"type": "amazonBedrock", "credentialSource": "awsManaged"}
	default:
		result["account"] = map[string]any{"type": "apiKey"}
	}
	return result
}

func fakeCodexInputText(params map[string]any) string {
	parts := []string{}
	for _, item := range sliceMapParam(params, "input") {
		if text := stringParam(item, "text"); text != "" {
			parts = append(parts, text)
		}
	}
	return strings.Join(parts, "\n")
}

func lineValue(text, prefix string) string {
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if value, ok := strings.CutPrefix(line, prefix); ok {
			return strings.TrimSpace(value)
		}
	}
	return ""
}

func TestFakeRuntimeRepliesToEveryOutstandingMessageInBatch(t *testing.T) {
	batch, err := json.Marshal(map[string]any{
		"schema": "external_session_message_batch_v1",
		"messages": []any{
			map[string]any{"content": []any{map[string]any{"text": "Reply with COMMA31_REPLY_CONCURRENT_A."}}},
			map[string]any{"content": []any{map[string]any{"text": "Reply with COMMA31_REPLY_CONCURRENT_B. Then repeat COMMA31_REPLY_CONCURRENT_B."}}},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	got := comma31ReplyText(fakeRuntimeInputText(string(batch)))
	if want := "COMMA31_REPLY_CONCURRENT_A\nCOMMA31_REPLY_CONCURRENT_B"; got != want {
		t.Fatalf("a settled fake turn must answer both outstanding messages: got %q, want %q", got, want)
	}
}

// A delivered batch can contain several outstanding messages (including an
// earlier message still awaiting a reply). The fake must answer all requested
// markers, not settle the whole batch after replying only to its first message.
func comma31ReplyText(text string) string {
	const prefix = "COMMA31_REPLY_"
	tokens := []string{}
	seen := map[string]bool{}
	for {
		start := strings.Index(text, prefix)
		if start < 0 {
			break
		}
		end := start + len(prefix)
		for end < len(text) {
			char := text[end]
			if (char < 'A' || char > 'Z') && (char < '0' || char > '9') && char != '_' {
				break
			}
			end++
		}
		token := text[start:end]
		if !seen[token] {
			tokens = append(tokens, token)
			seen[token] = true
		}
		text = text[end:]
	}
	return strings.Join(tokens, "\n")
}

func completeFakeRuntimeVisibleReply(provider, input string) string {
	input = fakeRuntimeInputText(input)
	delay := 50 * time.Millisecond
	if strings.Contains(input, "COMMA31_CONCURRENT_A") {
		delay = 2 * time.Second
	}
	time.Sleep(delay)
	if !waitForFakeRuntimeReconnect(input) {
		appendFakeProcessLog(
			os.Getenv("SALIX_TEST_FAKE_"+strings.ToUpper(provider)+"_LOG"),
			"visible_reply reconnect wait timed out",
		)
		return ""
	}

	conversationID := lineValue(input, "- conversation_id:")
	replyToken := comma31ReplyText(input)
	if conversationID == "" || replyToken == "" {
		return ""
	}
	payload, _ := json.Marshal(map[string]any{
		"connect_id":      "internal",
		"conversation_id": conversationID,
		"content":         []any{map[string]any{"type": "text", "text": replyToken}},
	})
	output, err := exec.Command(
		"salix",
		"tool",
		"call",
		"im_api.internal.send_message",
		"--json",
		string(payload),
	).CombinedOutput()
	logPath := os.Getenv("SALIX_TEST_FAKE_" + strings.ToUpper(provider) + "_LOG")
	appendFakeProcessLog(
		logPath,
		fmt.Sprintf("visible_reply %s err=%v output=%s", replyToken, err, strings.TrimSpace(string(output))),
	)
	if err != nil {
		return ""
	}
	return replyToken
}

func fakeRuntimeInputText(input string) string {
	var envelope struct {
		Schema   string `json:"schema"`
		Messages []struct {
			Content []struct {
				Text string `json:"text"`
			} `json:"content"`
		} `json:"messages"`
	}
	if json.Unmarshal([]byte(input), &envelope) != nil || envelope.Schema != "external_session_message_batch_v1" {
		return input
	}
	parts := []string{}
	for _, message := range envelope.Messages {
		for _, content := range message.Content {
			if content.Text != "" {
				parts = append(parts, content.Text)
			}
		}
	}
	return strings.Join(parts, "\n\n")
}

func waitForFakeRuntimeReconnect(input string) bool {
	trigger := os.Getenv("SALIX_TEST_RUNTIME_RECONNECT_TRIGGER")
	if trigger == "" || !strings.Contains(input, "COMMA31_RECONNECT_TOOL") {
		return true
	}
	if err := os.WriteFile(trigger+".waiting", []byte("waiting\n"), 0o600); err != nil {
		return false
	}
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(trigger); err == nil {
			return true
		}
		time.Sleep(50 * time.Millisecond)
	}
	return false
}

func helperProcessArgs() []string {
	for i, arg := range os.Args {
		if arg == "--" {
			return os.Args[i+1:]
		}
	}
	return nil
}

func appendFakeCodexJSONLog(method string, payload map[string]any) {
	raw, err := json.Marshal(payload)
	if err != nil {
		appendFakeCodexLog(method + " <json error>")
		return
	}
	appendFakeCodexLog(method + " " + string(raw))
}

func appendFakeCodexLog(line string) {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_LOG")
	if path == "" {
		return
	}
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return
	}
	defer f.Close()
	_, _ = f.WriteString(line + "\n")
}

func claimFakeCodexNormalExitBeforeThreadStartResponse() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_BEFORE_THREAD_START_RESPONSE_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexNormalExitBeforeListen() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_NORMAL_EXIT_BEFORE_LISTEN_ONCE")
	if path == "" || os.Remove(path) != nil {
		return false
	}
	_ = os.WriteFile(path+".bridge-url", []byte(os.Getenv("SALIX_CONNECT_URL")), 0o600)
	return true
}

func claimFakeCodexMissingThreadRead() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_MISSING_THREAD_ON_READ_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexMalformedThreadRead() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_MALFORMED_THREAD_READ_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexThreadResumeFailure() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_FAIL_THREAD_RESUME_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexInitializeFailure() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_FAIL_INITIALIZE_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexInitializeResponseDrop() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_DROP_INITIALIZE_RESPONSE_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexInitializeConnectionClose() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_CLOSE_INITIALIZE_ONCE")
	return path != "" && os.Remove(path) == nil
}

func claimFakeCodexCloseThreadRead() bool {
	path := os.Getenv("SALIX_TEST_FAKE_CODEX_CLOSE_THREAD_READ_ONCE")
	return path != "" && os.Remove(path) == nil
}

func receiveMap(t *testing.T, messages <-chan map[string]any) map[string]any {
	t.Helper()

	select {
	case msg := <-messages:
		return msg
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for connector frame")
		return map[string]any{}
	}
}

func httpGetJSON(t *testing.T, endpoint string) map[string]any {
	t.Helper()
	resp, err := http.Get(endpoint)
	if err != nil {
		t.Fatalf("GET %s: %v", endpoint, err)
	}
	defer resp.Body.Close()
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode %s: %v", endpoint, err)
	}
	return body
}

func tarGzContains(t *testing.T, raw []byte, name string) bool {
	t.Helper()
	gz, err := gzip.NewReader(bytes.NewReader(raw))
	if err != nil {
		t.Fatalf("gzip reader: %v", err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	for {
		header, err := tr.Next()
		if err == io.EOF {
			return false
		}
		if err != nil {
			t.Fatalf("tar read: %v", err)
		}
		if header.Name == name {
			return true
		}
	}
}

type tarEntry struct {
	name string
	data []byte
}

func makeTarGz(t *testing.T, entries []tarEntry) []byte {
	t.Helper()
	var buf bytes.Buffer
	gz := gzip.NewWriter(&buf)
	tw := tar.NewWriter(gz)
	for _, entry := range entries {
		if err := tw.WriteHeader(&tar.Header{
			Name: entry.name,
			Mode: 0o644,
			Size: int64(len(entry.data)),
		}); err != nil {
			t.Fatalf("write tar header: %v", err)
		}
		if _, err := tw.Write(entry.data); err != nil {
			t.Fatalf("write tar body: %v", err)
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := gz.Close(); err != nil {
		t.Fatalf("close gzip: %v", err)
	}
	return buf.Bytes()
}

func captureStdout(t *testing.T, fn func() error) (string, error) {
	t.Helper()
	oldStdout := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe stdout: %v", err)
	}
	os.Stdout = w
	defer func() {
		os.Stdout = oldStdout
		_ = r.Close()
	}()

	runErr := fn()
	_ = w.Close()
	raw, readErr := io.ReadAll(r)
	if readErr != nil {
		t.Fatalf("read stdout: %v", readErr)
	}
	return string(raw), runErr
}

func TestRetiredFlagsParseWithoutEffect(t *testing.T) {
	fs := flag.NewFlagSet("salix-connect", flag.ContinueOnError)
	var out bytes.Buffer
	fs.SetOutput(&out)
	root := fs.String("root", ".", "base directory for relative paths")
	registerRetiredFlags(fs)

	args := []string{"--root", "/tmp/workdir"}
	for _, name := range retiredFlags {
		args = append(args, "--"+name, "value")
	}
	if err := fs.Parse(args); err != nil {
		t.Fatalf("parse retired flags: %v", err)
	}
	if *root != "/tmp/workdir" {
		t.Fatalf("root = %q", *root)
	}

	fs.Usage()
	for _, name := range retiredFlags {
		if strings.Contains(out.String(), "-"+name) {
			t.Fatalf("usage lists %q:\n%s", name, out.String())
		}
	}
	if !strings.Contains(out.String(), "-root") {
		t.Fatalf("usage omits -root:\n%s", out.String())
	}
}

func TestManagedArchivePreservesExecutableLinksAndNativeFiles(t *testing.T) {
	root := t.TempDir()
	binary := filepath.Join(root, "home/packages/cli/run")
	if err := os.MkdirAll(filepath.Dir(binary), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(binary, []byte("#!/bin/sh\nprintf restored"), 0700); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "home/packages/cli-command")
	if err := os.Symlink("cli/run", link); err != nil {
		t.Fatal(err)
	}
	history := filepath.Join(root, "home/native-history.json")
	if err := os.WriteFile(history, []byte(`{"session":"retained"}`), 0600); err != nil {
		t.Fatal(err)
	}
	var archive bytes.Buffer
	if err := writeTarGz(&archive, root); err != nil {
		t.Fatal(err)
	}
	restored := t.TempDir()
	if err := restoreTarGz(bytes.NewReader(archive.Bytes()), restored); err != nil {
		t.Fatal(err)
	}
	output, err := exec.Command(filepath.Join(restored, "home/packages/cli-command")).Output()
	if err != nil || string(output) != "restored" {
		t.Fatalf("restored CLI: %s %v", output, err)
	}
	data, err := os.ReadFile(filepath.Join(restored, "home/native-history.json"))
	if err != nil || string(data) != `{"session":"retained"}` {
		t.Fatalf("history: %s %v", data, err)
	}
	outside := t.TempDir()
	if err := os.Symlink(outside, filepath.Join(root, "external")); err != nil {
		t.Fatal(err)
	}
	if err := writeTarGz(io.Discard, root); err == nil {
		t.Fatal("archive must fail instead of omitting an external link")
	}
}

func TestManagedArchiveRestoresDormantRuntimeIdentityWithoutReplacingLiveState(t *testing.T) {
	isolateHostRuntimeCommands(t)
	root := t.TempDir()
	home := filepath.Join(root, "home")
	if err := os.MkdirAll(home, 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(home, "runtimes"))
	source, err := newConnector(config{vmServer: true, root: root, externalStateRoot: home})
	if err != nil {
		t.Fatal(err)
	}
	defer source.closeExternalRuntimes()
	identity := externalRuntimeSessionIdentity{Provider: "pi", SessionID: "archived-session", Command: "/usr/local/bin/pi", Workspace: "/workspace/home/.comma/workspaces/archived-session", Payload: map[string]any{}, LastActivityAt: time.Now().Unix()}
	persistRuntimeIdentity(t, source.externalRuntimeState, identity)
	handler := source.vmHTTPHandler(context.Background())
	blocked := httptest.NewRecorder()
	handler.ServeHTTP(blocked, httptest.NewRequest(http.MethodGet, "/archive", nil))
	if blocked.Code != http.StatusConflict {
		t.Fatalf("unquiesced archive: %d", blocked.Code)
	}
	if _, err := source.methodCloudRuntimeLifecycle(context.Background(), "cloud_runtime_quiesce", map[string]any{"token": "archive"}); err != nil {
		t.Fatal(err)
	}
	archived := httptest.NewRecorder()
	handler.ServeHTTP(archived, httptest.NewRequest(http.MethodGet, "/archive", nil))
	if archived.Code != http.StatusOK {
		t.Fatalf("archive: %d %s", archived.Code, archived.Body.String())
	}
	if tarGzContains(t, archived.Body.Bytes(), "home/external-runtime/state.db") {
		t.Fatal("archive copied the live nested database")
	}
	if !tarGzContains(t, archived.Body.Bytes(), externalRuntimeStateRelativePath) {
		t.Fatal("missing transactional snapshot")
	}
	restoredRoot := t.TempDir()
	restoredHome := filepath.Join(restoredRoot, "home")
	if err := os.MkdirAll(restoredHome, 0700); err != nil {
		t.Fatal(err)
	}
	target, err := newConnector(config{vmServer: true, root: restoredRoot, externalStateRoot: restoredHome})
	if err != nil {
		t.Fatal(err)
	}
	defer target.closeExternalRuntimes()
	targetHandler := target.vmHTTPHandler(context.Background())
	restored := httptest.NewRecorder()
	targetHandler.ServeHTTP(restored, httptest.NewRequest(http.MethodPut, "/archive?operation=wake-one", bytes.NewReader(archived.Body.Bytes())))
	if restored.Code != http.StatusOK {
		t.Fatalf("restore: %d %s", restored.Code, restored.Body.String())
	}
	resumable, active, inputs, events := target.externalRuntimeState.healthCounts()
	if resumable != 1 || active != 0 || inputs != 0 || events != 0 {
		t.Fatalf("restored state: %d %d %d %d", resumable, active, inputs, events)
	}
	if got := target.externalRuntimeState.identities[identity.key()]; got.Command != identity.Command || got.Workspace != identity.Workspace {
		t.Fatalf("identity changed: %+v", got)
	}
	if err := os.WriteFile(filepath.Join(restoredRoot, "new-work.txt"), []byte("after restore"), 0600); err != nil {
		t.Fatal(err)
	}
	target.closeExternalRuntimes()
	target, err = newConnector(config{vmServer: true, root: restoredRoot, externalStateRoot: restoredHome})
	if err != nil {
		t.Fatal(err)
	}
	defer target.closeExternalRuntimes()
	targetHandler = target.vmHTTPHandler(context.Background())
	replayed := httptest.NewRecorder()
	targetHandler.ServeHTTP(replayed, httptest.NewRequest(http.MethodPut, "/archive?operation=wake-one", bytes.NewReader(archived.Body.Bytes())))
	if replayed.Code != http.StatusOK {
		t.Fatalf("warm reconnect restore replay: %d %s", replayed.Code, replayed.Body.String())
	}
	if data, err := os.ReadFile(filepath.Join(restoredRoot, "new-work.txt")); err != nil || string(data) != "after restore" {
		t.Fatal("warm retry replaced live files", err)
	}
	repeated := httptest.NewRecorder()
	targetHandler.ServeHTTP(repeated, httptest.NewRequest(http.MethodPut, "/archive?operation=other-wake", bytes.NewReader(archived.Body.Bytes())))
	if repeated.Code != http.StatusConflict {
		t.Fatalf("occupied target overwritten: %d", repeated.Code)
	}
}

func TestManagedArchiveSnapshotSharesExportBudget(t *testing.T) {
	isolateHostRuntimeCommands(t)
	root := t.TempDir()
	t.Setenv("HOME", root)
	source, err := newConnector(config{vmServer: true, root: root, externalStateRoot: root})
	if err != nil {
		t.Fatal(err)
	}
	defer source.closeExternalRuntimes()
	state := source.externalRuntimeState
	var snapshot bytes.Buffer
	if err := state.writeArchiveSnapshot(tar.NewWriter(&snapshot), migrationByteLimit); err != nil {
		t.Fatal(err)
	}
	header, err := tar.NewReader(bytes.NewReader(snapshot.Bytes())).Next()
	if err != nil {
		t.Fatal(err)
	}
	var rejected bytes.Buffer
	if err := state.writeArchiveSnapshot(tar.NewWriter(&rejected), header.Size-1); err == nil {
		t.Fatal("export accepted snapshot beyond restore budget")
	}
	if rejected.Len() != 0 {
		t.Fatal("rejected snapshot emitted an archive entry")
	}
	var exact bytes.Buffer
	tw := tar.NewWriter(&exact)
	if err := state.writeArchiveSnapshot(tw, header.Size); err != nil {
		t.Fatal(err)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	tr := tar.NewReader(bytes.NewReader(exact.Bytes()))
	if _, err := tr.Next(); err != nil {
		t.Fatal(err)
	}
	if n, err := io.Copy(io.Discard, tr); err != nil || n != header.Size {
		t.Fatalf("snapshot: %d %v", n, err)
	}
}

func TestArchiveKeepsGitMetadataAndUserFilesWhileSkippingGeneratedCaches(t *testing.T) {
	root := t.TempDir()
	workspace := filepath.Join(root, ".salix/sprite-home/.local/share/salix/connector-home/.comma/workspaces/session/repo")
	files := map[string]string{
		".git/refs/heads/local":     "unpushed commit",
		".gitignore":                "private.conf\n",
		"private.conf":              "user configuration",
		"node_modules/pkg/index.js": "locally patched dependency",
		"node_modules/notes.txt":    "user data",
		".venv/pyvenv.cfg":          "home = /usr/bin",
		".venv/notes.txt":           "user data",
		".venv/lib/python3.12/site-packages/pkg/source.py":            "patched installation",
		".venv/lib/python3.12/site-packages/pkg-1.dist-info/METADATA": "installation marker",
		".tox/env/user-notes.txt":                                     "user data",
		".nox/env/user-notes.txt":                                     "user data",
		".pixi/envs/default/user-notes.txt":                           "user data",
		"__pypackages__/3.12/lib/user-notes.txt":                      "user data",
		"package.json":                                                "{\"dependencies\":{\"pkg\":\"1.0.0\"}}",
		"package-lock.json":                                           "{\"lockfileVersion\":3}",
		"dist/output.js":                                              "generated build",
		".dart_tool/package_config.json":                              "generated package data",
		".cxx/object.o":                                               "generated native build",
		"xcuserdata/preferences":                                      "user settings",
		".swiftpm/configuration/mirrors.json":                         "user configuration",
		".terraform/terraform.tfstate":                                "backend metadata",
		".tools/local-tool":                                           "user tool",
	}
	for name, content := range files {
		path := filepath.Join(workspace, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	cache := filepath.Join(root, ".salix/sprite-home/.cache/go-build/object")
	if err := os.MkdirAll(filepath.Dir(cache), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cache, []byte("generated"), 0600); err != nil {
		t.Fatal(err)
	}
	store := filepath.Join(root, ".salix/sprite-home/.local/share/salix/connector-home/.local/share/pnpm/store/v10/object")
	if err := os.MkdirAll(filepath.Dir(store), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(store, []byte("generated"), 0600); err != nil {
		t.Fatal(err)
	}
	other := filepath.Join(root, "project/.comma/workspaces/session/repo/build/asset.txt")
	if err := os.MkdirAll(filepath.Dir(other), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(other, []byte("user-owned path"), 0600); err != nil {
		t.Fatal(err)
	}
	generatedHomeFiles := []string{
		".npm/_cacache/object", ".cargo/registry/src/crate/lib.rs",
		".gradle/caches/module.jar", ".android/cache/build.bin",
		".m2/repository/library.jar", ".hex/cache.ets",
		"Library/Developer/Xcode/DerivedData/App/Build/object.o",
		"go/pkg/mod/example/module.go",
	}
	for _, name := range generatedHomeFiles {
		path := filepath.Join(root, ".salix/sprite-home/.local/share/salix/connector-home", name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("generated"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	retainedHomeFiles := []string{
		".npmrc", ".cargo/config.toml", ".cargo/git/db/refs/heads/local",
		".gradle/gradle.properties", ".android/adbkey", ".m2/settings.xml",
		"Library/Developer/Xcode/Archives/App.xcarchive/Info.plist", "go/bin/tool",
	}
	for _, name := range retainedHomeFiles {
		path := filepath.Join(root, ".salix/sprite-home/.local/share/salix/connector-home", name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("retain"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	installation := ".salix/sprite-home/.local/share/sprite-agents/local-patch.js"
	if err := os.MkdirAll(filepath.Dir(filepath.Join(root, installation)), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, installation), []byte("user-patched tool"), 0600); err != nil {
		t.Fatal(err)
	}
	var archive bytes.Buffer
	if err := writeTarGz(&archive, root); err != nil {
		t.Fatal(err)
	}
	restored := t.TempDir()
	if err := restoreTarGz(bytes.NewReader(archive.Bytes()), restored); err != nil {
		t.Fatal(err)
	}
	if data, err := os.ReadFile(filepath.Join(restored, installation)); err != nil || string(data) != "user-patched tool" {
		t.Fatalf("installed tool patch changed: %q, %v", data, err)
	}
	repo := filepath.Join(restored, ".salix/sprite-home/.local/share/salix/connector-home/.comma/workspaces/session/repo")
	for name := range files {
		if strings.HasPrefix(name, ".dart_tool/") || strings.HasPrefix(name, ".cxx/") {
			continue
		}
		data, err := os.ReadFile(filepath.Join(repo, name))
		if err != nil || string(data) != files[name] {
			t.Fatalf("user file %s changed: %q, %v", name, data, err)
		}
	}
	for _, name := range []string{".dart_tool", ".cxx"} {
		if _, err := os.Stat(filepath.Join(repo, name)); !os.IsNotExist(err) {
			t.Fatalf("generated directory %s restored: %v", name, err)
		}
	}
	if _, err := os.Stat(filepath.Join(restored, ".salix/sprite-home/.cache")); !os.IsNotExist(err) {
		t.Fatalf("runtime cache restored: %v", err)
	}
	if _, err := os.Stat(filepath.Join(restored, ".salix/sprite-home/.local/share/salix/connector-home/.local/share/pnpm/store")); !os.IsNotExist(err) {
		t.Fatalf("dependency store restored: %v", err)
	}
	if _, err := os.Stat(filepath.Join(restored, "project/.comma/workspaces/session/repo/build/asset.txt")); err != nil {
		t.Fatalf("unrelated project data missing: %v", err)
	}
	home := filepath.Join(restored, ".salix/sprite-home/.local/share/salix/connector-home")
	for _, name := range generatedHomeFiles {
		if _, err := os.Stat(filepath.Join(home, name)); !os.IsNotExist(err) {
			t.Fatalf("generated home cache %s restored: %v", name, err)
		}
	}
	for _, name := range retainedHomeFiles {
		if _, err := os.Stat(filepath.Join(home, name)); err != nil {
			t.Fatalf("home configuration %s missing: %v", name, err)
		}
	}
}

func TestArchiveExportsMoreThanOneHundredThousandEntries(t *testing.T) {
	root := t.TempDir()
	for i := 0; i < 100_001; i++ {
		if err := os.Mkdir(filepath.Join(root, fmt.Sprintf("entry-%06d", i)), 0700); err != nil {
			t.Fatal(err)
		}
	}
	var archive bytes.Buffer
	if err := writeTarGz(&archive, root); err != nil {
		t.Fatal(err)
	}
	gz, err := gzip.NewReader(bytes.NewReader(archive.Bytes()))
	if err != nil {
		t.Fatal(err)
	}
	defer gz.Close()
	tr := tar.NewReader(gz)
	count := 0
	for {
		_, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		count++
	}
	if count != 100_001 {
		t.Fatalf("archive entries = %d, want 100001", count)
	}
	restored := t.TempDir()
	if err := restoreTarGz(bytes.NewReader(archive.Bytes()), restored); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(restored, "entry-100000")); err != nil {
		t.Fatalf("last archive entry missing after restore: %v", err)
	}
}
