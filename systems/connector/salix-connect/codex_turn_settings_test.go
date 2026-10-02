package main

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"github.com/gorilla/websocket"
)

// fakeCodexDefaultsServer answers config/read, model/list and turn/start.
type fakeCodexDefaultsServer struct {
	mu          sync.Mutex
	configs     map[string]map[string]any
	models      []any
	failConfig  int
	configReads []string
	listParams  []map[string]any
	turns       []map[string]any
}

func (f *fakeCodexDefaultsServer) runtime(t *testing.T) *codexRuntime {
	t.Helper()
	upgrader := websocket.Upgrader{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
		conn, err := upgrader.Upgrade(w, req, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			var msg map[string]any
			if conn.ReadJSON(&msg) != nil {
				return
			}
			params := mapParam(msg, "params")
			reply := map[string]any{"id": msg["id"]}
			f.mu.Lock()
			switch stringParam(msg, "method") {
			case "config/read":
				f.configReads = append(f.configReads, stringParam(params, "cwd"))
				if f.failConfig > 0 {
					f.failConfig--
					reply["error"] = map[string]any{"code": -32603, "message": "config unavailable"}
				} else {
					reply["result"] = map[string]any{"config": f.configs[stringParam(params, "cwd")]}
				}
			case "model/list":
				f.listParams = append(f.listParams, params)
				reply["result"] = map[string]any{"data": f.models}
			case "turn/start":
				f.turns = append(f.turns, params)
				reply["result"] = map[string]any{"turn": map[string]any{"id": "turn-1"}}
			default:
				reply["result"] = map[string]any{}
			}
			f.mu.Unlock()
			if conn.WriteJSON(reply) != nil {
				return
			}
		}
	}))
	t.Cleanup(server.Close)
	ws, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(server.URL, "http"), nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = ws.Close() })
	runtime := &codexRuntime{ws: ws, pending: map[string]chan map[string]any{}}
	go func() {
		for {
			var msg map[string]any
			if ws.ReadJSON(&msg) != nil {
				runtime.closePending()
				return
			}
			runtime.handleCodexMessage(msg)
		}
	}()
	return runtime
}

func codexModel(name string, isDefault bool, defaultEffort string, supported ...string) map[string]any {
	options := make([]any, 0, len(supported))
	for _, effort := range supported {
		options = append(options, map[string]any{"reasoningEffort": effort, "description": effort})
	}
	return map[string]any{
		"id": name, "model": name, "isDefault": isDefault,
		"defaultReasoningEffort": defaultEffort, "supportedReasoningEfforts": options,
	}
}

func assertCodexTurn(t *testing.T, params map[string]any, model, effort string) {
	t.Helper()
	gotModel, hasModel := params["model"]
	gotEffort, hasEffort := params["effort"]
	if hasModel != (model != "") || (hasModel && gotModel != model) ||
		hasEffort != (effort != "") || (hasEffort && gotEffort != effort) {
		t.Fatalf("turn/start params = %v, want model %q effort %q", params, model, effort)
	}
}

// A blank choice sends Codex's own default explicitly, because turn/start
// overrides persist on the thread and null does not clear them. The default
// follows the thread's workspace config, then Codex's model list.
func TestCodexTurnSendsCodexDefaultsForBlankChoice(t *testing.T) {
	fake := &fakeCodexDefaultsServer{
		configs: map[string]map[string]any{
			"/work/plain":      {"cli_auth_credentials_store": "file"},
			"/work/configured": {"model": "gpt-configured", "model_reasoning_effort": "xhigh"},
		},
		models: []any{
			codexModel("gpt-default", true, "medium", "low", "medium", "high"),
			codexModel("gpt-5.5", false, "low", "low", "medium", "high", "xhigh"),
		},
	}
	runtime := fake.runtime(t)
	turns := []struct{ cwd, model, effort, wantModel, wantEffort string }{
		{"/work/plain", "gpt-5.5", "high", "gpt-5.5", "high"},
		{"/work/plain", "", "", "gpt-default", "medium"},
		{"/work/plain", "gpt-5.5", "", "gpt-5.5", "low"},
		// A workspace config wins over the model list.
		{"/work/configured", "", "", "gpt-configured", "xhigh"},
		// An effort the model does not support becomes the closest one.
		{"/work/plain", "gpt-5.5", "max", "gpt-5.5", "xhigh"},
		{"/work/plain", "", "minimal", "gpt-default", "low"},
	}
	for _, turn := range turns {
		if _, err := runtime.startTurn(context.Background(), "thread-1", nil, turn.cwd, turn.model, turn.effort); err != nil {
			t.Fatal(err)
		}
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	for index, turn := range turns {
		assertCodexTurn(t, fake.turns[index], turn.wantModel, turn.wantEffort)
	}
	// The model list is read once per process with hidden models; the config
	// once per workspace.
	if len(fake.listParams) != 1 || fake.listParams[0]["includeHidden"] != true {
		t.Fatalf("model/list requests = %v", fake.listParams)
	}
	if strings.Join(fake.configReads, ",") != "/work/plain,/work/configured" {
		t.Fatalf("config/read requests = %q", fake.configReads)
	}
}

// A failed config read is not cached, and a field Codex reports no default
// for stays omitted.
func TestCodexTurnRetriesFailedDefaultsAndOmitsUnknownDefaults(t *testing.T) {
	fake := &fakeCodexDefaultsServer{
		configs:    map[string]map[string]any{"/work": {"model": "gpt-configured"}},
		models:     []any{codexModel("gpt-test", false, "")},
		failConfig: 1,
	}
	runtime := fake.runtime(t)
	for range 2 {
		if _, err := runtime.startTurn(context.Background(), "thread-1", nil, "/work", "", ""); err != nil {
			t.Fatal(err)
		}
	}
	fake.mu.Lock()
	defer fake.mu.Unlock()
	assertCodexTurn(t, fake.turns[0], "", "")
	assertCodexTurn(t, fake.turns[1], "gpt-configured", "")
	if len(fake.configReads) != 2 {
		t.Fatalf("failed config/read was cached: %q", fake.configReads)
	}
}
