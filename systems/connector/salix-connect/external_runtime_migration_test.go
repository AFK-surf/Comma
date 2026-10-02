package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"io"
	"maps"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	bolt "go.etcd.io/bbolt"
)

func TestMigrationPiRefusesMissingNativeHistory(t *testing.T) {
	for _, kind := range []string{"missing", "empty", "wrong-identity"} {
		t.Run(kind, func(t *testing.T) {
			c, err := newConnector(config{name: "migration-strict-resume", root: t.TempDir()})
			if err != nil {
				t.Fatal(err)
			}
			defer c.closeExternalRuntimes()
			defer func() {
				if c.bridgeServer != nil {
					_ = c.bridgeServer.Shutdown(context.Background())
				}
			}()
			const id = "migrated-session"
			native := filepath.Join(c.root, "external-runtime", "pi", id, "native.jsonl")
			if err := os.MkdirAll(filepath.Dir(native), 0700); err != nil {
				t.Fatal(err)
			}
			if kind != "missing" {
				data := ""
				if kind == "wrong-identity" {
					data = `{"type":"session","id":"another-session"}` + "\n"
				}
				if err := os.WriteFile(native, []byte(data), 0600); err != nil {
					t.Fatal(err)
				}
			}
			launched := filepath.Join(t.TempDir(), "launched")
			command := filepath.Join(t.TempDir(), "pi")
			if err := os.WriteFile(command, []byte("#!/bin/sh\ntouch "+shellQuote(launched)+"\n"), 0700); err != nil {
				t.Fatal(err)
			}
			input := externalRuntimeInput{sessionID: id, command: command, workspace: t.TempDir(), payload: map[string]any{"session_id": "expected-native", "session_file": native, "require_native_resume": true}}
			_, err = c.runtimeImplementations["pi"].(*piRuntimeImplementation).startSession(context.Background(), input)
			if err == nil || !strings.Contains(err.Error(), "migrated Pi Session") {
				t.Fatalf("missing history accepted: %v", err)
			}
			if _, err := os.Stat(launched); !os.IsNotExist(err) {
				t.Fatal("invalid native history launched the CLI")
			}
		})
	}
}

func TestMigrationNativeContinuation(t *testing.T) {
	for _, provider := range []string{"pi", "codex", "claude"} {
		t.Run(provider, func(t *testing.T) { testMigrationNativeContinuation(t, provider) })
	}
}

func testMigrationNativeContinuation(t *testing.T, provider string) {
	cliDir := os.Getenv("COMMA_MIGRATION_NATIVE_CLI_DIR")
	if cliDir == "" {
		t.Skip("set COMMA_MIGRATION_NATIVE_CLI_DIR to the locked Linux CLI fixture")
	}
	command := filepath.Join(cliDir, provider)
	sourceCommand := command
	if sourceCodex := os.Getenv("COMMA_MIGRATION_SOURCE_CODEX"); provider == "codex" && sourceCodex != "" {
		sourceCommand = sourceCodex
	}
	realModel := os.Getenv("COMMA_MIGRATION_OPENROUTER_KEY_FILE") != ""
	model := "fixture"
	if realModel {
		model = "anthropic/claude-haiku-4.5"
		if provider == "codex" {
			model = "openai/gpt-5.4-mini"
		}
	}
	requests := make(chan string, 16)
	var server *httptest.Server
	endpoint := "https://openrouter.ai/api"
	if !realModel {
		server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			body, _ := io.ReadAll(io.LimitReader(r.Body, 4<<20))
			if !strings.Contains(string(body), "source-native-marker") && !strings.Contains(string(body), "target-native-marker") {
				w.Header().Set("Content-Type", "application/json")
				fmt.Fprint(w, `{"input_tokens":10}`)
				return
			}
			requests <- string(body)
			writeMigrationModelResponse(w, provider)
		}))
		defer server.Close()
		endpoint = server.URL
	}
	if provider == "claude" {
		wrapper := filepath.Join(t.TempDir(), "claude")
		// The Compute adapter isolates inherited provider credentials. Supply
		// this fixture's endpoint at the executable boundary, after isolation.
		script := "#!/bin/sh\nexport ANTHROPIC_BASE_URL=" + shellQuote(endpoint) + "\nexport ANTHROPIC_API_KEY=synthetic-fixture-key\nexec " + shellQuote(command) + " \"$@\"\n"
		if realModel {
			script = "#!/bin/sh\nexport ANTHROPIC_BASE_URL=" + shellQuote(endpoint) + "\nexport ANTHROPIC_API_KEY=\nexport ANTHROPIC_AUTH_TOKEN=\"$(cat " + shellQuote(os.Getenv("COMMA_MIGRATION_OPENROUTER_KEY_FILE")) + ")\"\nexec " + shellQuote(command) + " \"$@\"\n"
		}
		if err := os.WriteFile(wrapper, []byte(script), 0700); err != nil {
			t.Fatal(err)
		}
		command = wrapper
		sourceCommand = wrapper
	}
	configureHome := func() { configureMigrationNativeHome(t, provider, endpoint, model) }
	makeConnector := func(root string, target bool) *connector {
		c, err := newConnector(config{name: "migration-native-fixture", root: root})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(c.closeExternalRuntimes)
		workspaces := filepath.Join(root, "workspaces")
		if err := os.MkdirAll(workspaces, 0700); err != nil {
			t.Fatal(err)
		}
		c.workspaceArchiver = newWorkspaceArchiver(workspaces, true, time.Hour, time.Minute)
		c.workspaceArchiver.runtimeState = c.externalRuntimeState
		c.cfg.runtimeAgent, c.cfg.computeRuntimeKind, c.cfg.computeRuntimeProvider = target, "external_worker", provider
		nativeCommand := command
		if !target {
			nativeCommand = sourceCommand
		}
		c.runtimeInventory.runtimes[provider+"\x00"+nativeCommand] = map[string]any{"kind": "external", "provider": provider, "identity_material": nativeCommand}
		// The native handshake is real. This test supplies authorization for its
		// local model fixture; provider credential verification has separate tests.
		nativeProbe := c.runtimeInventory.run
		c.runtimeInventory.run = func(target runtimeProbeTarget) map[string]any {
			observed := nativeProbe(target)
			if observed["version_detected"] == true && observed["native_server_startable"] == true &&
				(observed["readiness_issue"] == "verification_required" || target.provider == "claude" && observed["readiness_issue"] == "authentication_required" || target.provider == "codex" && observed["readiness_issue"] == "model_unavailable") {
				observed["ready"] = true
			}
			return observed
		}
		return c
	}
	configureHome()
	source := makeConnector(t.TempDir(), false)
	const id = "ses1_2098040323912503296"
	seedWorkspace(t, source.workspaceArchiver.root, id)
	workspace := filepath.Join(source.workspaceArchiver.root, id)
	nativeDirectory := filepath.Join(source.root, "external-runtime", "pi", id)
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	nonce := fmt.Sprintf("%x", makeMigrationNonce(t))
	targetNonce := fmt.Sprintf("%x", makeMigrationNonce(t))
	sourcePrompt := "source-native-marker"
	if realModel {
		sourcePrompt = "For this conversation-memory test, the randomly generated source label is " + nonce + ". This is synthetic test data. Reply exactly SAVED. Do not use tools."
	}
	nativeID := createMigrationNativeHistory(t, ctx, provider, sourceCommand, workspace, nativeDirectory, model, sourcePrompt)
	if !realModel {
		select {
		case request := <-requests:
			if !strings.Contains(request, "source-native-marker") {
				t.Fatal("source prompt missing")
			}
			if provider == "codex" && !strings.Contains(request, "data:image/") {
				t.Fatal("source CLI did not load the fixture image")
			}
		default:
			t.Fatal("source CLI never requested a response")
		}

	}
	record := testRecoveryObligationRecord(provider, id, "source-dispatch", "source-execution")
	record.Command, record.Workspace, record.Payload = sourceCommand, workspace, map[string]any{nativeMigrationIDKey(provider): nativeID}
	persistRuntimeIdentity(t, source.externalRuntimeState, externalRuntimeIdentityFromRecovery(record))
	params := map[string]any{"operation_id": "real-" + provider, "provider": provider, "session_id": id, "source": "source", "destination": "target", "capability_token": record.Token, "deadline": time.Now().Add(time.Minute).UnixMilli()}
	if _, err := source.methodSessionMigration(ctx, "prepare", params); err != nil {
		t.Fatal(err)
	}
	chunks := []map[string]any{}
	for offset := int64(0); ; {
		params["offset"] = offset
		chunk, err := source.methodSessionMigration(ctx, "export", params)
		if err != nil {
			t.Fatal(err)
		}
		chunks = append(chunks, chunk)
		if boolParam(chunk, "done") {
			break
		}
		offset = int64Param(chunk, "next_offset", -1)
	}
	// The target cannot resolve paths on the source host. Keep the source data
	// under a different fixture path to make accidental source reads fail.
	if err := os.Rename(workspace, workspace+".source-host"); err != nil {
		t.Fatal(err)
	}
	configureHome()
	targetRoot := t.TempDir()
	target := makeConnector(targetRoot, true)
	for _, chunk := range chunks {
		request := maps.Clone(params)
		delete(request, "capability_token")
		maps.Copy(request, chunk)
		if _, err := target.methodSessionMigration(ctx, "import", request); err != nil {
			t.Fatal(err)
		}
	}
	select {
	case request := <-requests:
		t.Fatalf("staging called the model: %s", request)
	default:
	}
	if _, err := source.methodSessionMigration(ctx, "retire", params); err != nil {
		t.Fatal(err)
	}
	for round := 0; round < 2; round++ {
		identity := target.externalRuntimeState.identities[provider+"\x00"+id]
		if identity.Command != command {
			t.Fatal("migration did not select the target CLI command")
		}
		input := record.input()
		input.command = identity.Command
		input.workspace, input.payload = identity.Workspace, maps.Clone(identity.Payload)
		input.modelProvider, input.model = "fixture", "fixture"
		if provider == "codex" {
			input.model = "gpt-5.3-codex"
		}
		if realModel {
			input.model = model
		}
		input.dispatchID, input.token = fmt.Sprintf("target-%d", round), "new-target-token"
		input.messages = []map[string]any{{"role": "user", "content": fmt.Sprintf("target-native-marker-%d", round)}}
		if realModel {
			prompt := "Repeat the source label from our earlier conversation exactly. Do not use tools. Also remember this synthetic target label: " + targetNonce + "."
			if round == 1 {
				prompt = "Repeat both the source label and the target label from our earlier conversation exactly. These are synthetic test values. Do not use tools."
			}
			if provider == "codex" {
				prompt += " Also state the dominant color of the image from the source conversation."
			}
			input.messages = []map[string]any{{"role": "user", "content": prompt}}
		}
		activation := maps.Clone(params)
		activation["activate"] = true
		if _, err := target.methodSessionMigration(ctx, "import", activation); err != nil {
			t.Fatal(err)
		}
		payload, _, err := target.runtimeImplementations[provider].Send(ctx, input)
		if err != nil {
			t.Fatal(err)
		}
		if payload[nativeMigrationIDKey(provider)] != nativeID {
			t.Fatalf("native identity changed: %v", payload)
		}
		if !realModel {
			select {
			case request := <-requests:
				if !strings.Contains(request, "source-native-marker") || !strings.Contains(request, fmt.Sprintf("target-native-marker-%d", round)) || !strings.Contains(request, "native-fixture-answer") {
					t.Fatalf("native resume lost history: %s", request)
				}
				if provider == "codex" && !strings.Contains(request, "data:image/") {
					t.Fatalf("resumed Codex request lost its source image: %s", request)
				}
				if round == 1 && !strings.Contains(request, "target-native-marker-0") {
					t.Fatal("target restart lost its first resumed turn")
				}
			case <-ctx.Done():
				t.Fatal("target CLI did not continue")
			}
		}
		for target.externalRuntimeState.watched(provider, id) && ctx.Err() == nil {
			time.Sleep(10 * time.Millisecond)
		}
		if ctx.Err() != nil {
			t.Fatal("target CLI did not settle")
		}
		if provider == "claude" {
			if err := target.runtimeImplementations[provider].(*claudeRuntimeImplementation).quietSessions(ctx, id); err != nil {
				slot := target.runtimeImplementations[provider].(*claudeRuntimeImplementation).sessionSlot(id)
				t.Logf("Claude fixture diagnostics: %s", slot.session.diagnostics.text())
				t.Fatal(err)
			}

		}
		if realModel {
			var answer strings.Builder
			for _, event := range runtimeEventPayloads(t, target) {
				if event["dispatch_id"] == input.dispatchID && event["type"] == "message" {
					answer.WriteString(stringParam(event, "content"))
				}
			}
			if !strings.Contains(answer.String(), nonce) || round == 1 && !strings.Contains(answer.String(), targetNonce) || provider == "codex" && !strings.Contains(strings.ToLower(answer.String()), "red") {
				t.Fatalf("real model lost native history at round %d: answer=%q events=%v", round, answer.String(), runtimeEventPayloads(t, target))
			}
			t.Logf("real OpenRouter continuation passed: provider=%s round=%d native_id=%s", provider, round, nativeID)
		}
		if round == 0 {
			target.closeExternalRuntimes()
			target = makeConnector(targetRoot, true)
		}
	}
}

func nativeMigrationIDKey(provider string) string {
	if provider == "codex" {
		return "thread_id"
	}
	return "session_id"
}

func configureMigrationNativeHome(t *testing.T, provider, url, model string) {
	t.Helper()
	configureMigrationNativeHomeAt(t, t.TempDir(), provider, url, model)
}

func configureMigrationNativeHomeAt(t *testing.T, home, provider, url, model string) {
	t.Helper()
	t.Setenv("HOME", home)
	write := func(path, body string) {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	key := "fixture-key"
	realModel := os.Getenv("COMMA_MIGRATION_OPENROUTER_KEY_FILE") != ""
	if realModel {
		raw, err := os.ReadFile(os.Getenv("COMMA_MIGRATION_OPENROUTER_KEY_FILE"))
		if err != nil {
			t.Fatal("cannot read isolated OpenRouter credential")
		}
		key = strings.TrimSpace(string(raw))
	}
	switch provider {
	case "pi":
		directory := filepath.Join(home, ".pi", "agent")
		t.Setenv("PI_CODING_AGENT_DIR", directory)
		models := map[string]any{"providers": map[string]any{"fixture": map[string]any{
			"baseUrl": url + "/v1", "api": "openai-completions", "apiKey": key,
			"models": []map[string]any{{"id": model, "reasoning": false, "contextWindow": 32000, "maxTokens": 1024}},
		}}}
		raw, _ := json.Marshal(models)
		write(filepath.Join(directory, "models.json"), string(raw))
		write(filepath.Join(directory, "settings.json"), fmt.Sprintf(`{"defaultProvider":"fixture","defaultModel":%q}`, model))
	case "codex":
		directory := filepath.Join(home, ".codex")
		t.Setenv("CODEX_HOME", directory)
		write(filepath.Join(directory, "config.toml"), fmt.Sprintf("model = \"gpt-5.3-codex\"\nmodel_provider = \"fixture\"\ncli_auth_credentials_store = \"file\"\ncheck_for_update_on_startup = false\n[model_providers.fixture]\nname = \"Local fixture\"\nbase_url = %q\nwire_api = \"responses\"\nrequires_openai_auth = false\n", url+"/v1"))
		if realModel {
			configPath := filepath.Join(directory, "config.toml")
			raw, _ := os.ReadFile(configPath)
			config := strings.Replace(string(raw), "gpt-5.3-codex", model, 1)
			config += "experimental_bearer_token = " + fmt.Sprintf("%q", key) + "\n"
			write(configPath, config)
		} else {
			write(filepath.Join(directory, "auth.json"), `{"OPENAI_API_KEY":"synthetic-fixture-key"}`)
		}
	case "claude":
		t.Setenv("CLAUDE_CONFIG_DIR", filepath.Join(home, ".claude"))
		t.Setenv("ANTHROPIC_API_KEY", "synthetic-fixture-key")
		t.Setenv("ANTHROPIC_BASE_URL", url)
		t.Setenv("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1")
		write(filepath.Join(home, ".claude", "settings.json"), `{}`)
	}
}

func createMigrationNativeHistory(t *testing.T, ctx context.Context, provider, command, workspace, nativeDirectory, model, prompt string) string {
	t.Helper()
	var args []string
	nativeID := ""
	switch provider {
	case "pi":
		args = []string{"--mode", "json", "--provider", "fixture", "--model", model, "--session-dir", nativeDirectory, "-p", prompt}
	case "codex":
		pictureData := image.NewRGBA(image.Rect(0, 0, 16, 16))
		for y := 0; y < 16; y++ {
			for x := 0; x < 16; x++ {
				pictureData.Set(x, y, color.RGBA{R: 200, A: 255})
			}
		}
		var encoded bytes.Buffer
		if err := png.Encode(&encoded, pictureData); err != nil {
			t.Fatal(err)
		}
		picture := filepath.Join(workspace, "uncommitted-image.png")
		if err := os.WriteFile(picture, encoded.Bytes(), 0600); err != nil {
			t.Fatal(err)
		}
		args = []string{"exec", "--skip-git-repo-check", "--json", "--sandbox", "read-only", prompt, "--image", picture}
	case "claude":
		var err error
		nativeID, err = newClaudeSessionID()
		if err != nil {
			t.Fatal(err)
		}
		args = []string{"-p", prompt, "--output-format", "json", "--model", model, "--session-id", nativeID, "--tools", ""}
	}
	cmd := commandContextWithProcessGroup(ctx, command, args...)
	cmd.WaitDelay = time.Second
	cmd.Dir = workspace
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("source CLI: %v %s", err, out)
	}
	if os.Getenv("COMMA_MIGRATION_OPENROUTER_KEY_FILE") != "" && !bytes.Contains(out, []byte("SAVED")) {
		t.Fatalf("source model did not acknowledge the synthetic label: %s", out)
	}
	if provider == "claude" {
		return nativeID
	}
	root := nativeDirectory
	if provider == "codex" {
		root = filepath.Join(os.Getenv("CODEX_HOME"), "sessions")
	}
	files := []string{}
	if err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type().IsRegular() && strings.HasSuffix(path, ".jsonl") {
			files = append(files, path)
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if len(files) != 1 {
		t.Fatalf("native files: %v", files)
	}
	raw, err := os.ReadFile(files[0])
	if err != nil {
		t.Fatal(err)
	}
	var header map[string]any
	if err := json.Unmarshal(bytes.SplitN(raw, []byte("\n"), 2)[0], &header); err != nil {
		t.Fatal(err)
	}
	if provider == "codex" {
		return stringParam(mapParam(header, "payload"), "id")
	}
	return stringParam(header, "id")
}

func writeMigrationModelResponse(w http.ResponseWriter, provider string) {
	w.Header().Set("Content-Type", "text/event-stream")
	events := []string{}
	switch provider {
	case "pi":
		events = []string{
			`{"id":"fixture","object":"chat.completion.chunk","created":1,"model":"fixture","choices":[{"index":0,"delta":{"role":"assistant","content":"native-fixture-answer"},"finish_reason":null}]}`,
			`{"id":"fixture","object":"chat.completion.chunk","created":1,"model":"fixture","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":5,"completion_tokens":3,"total_tokens":8}}`,
			`[DONE]`,
		}
	case "codex":
		events = []string{
			`{"type":"response.created","response":{"id":"resp_fixture","object":"response","status":"in_progress","output":[]}}`,
			`{"type":"response.output_item.added","output_index":0,"item":{"id":"msg_fixture","type":"message","role":"assistant","status":"in_progress","content":[]}}`,
			`{"type":"response.content_part.added","item_id":"msg_fixture","output_index":0,"content_index":0,"part":{"type":"output_text","text":"","annotations":[]}}`,
			`{"type":"response.output_text.delta","item_id":"msg_fixture","output_index":0,"content_index":0,"delta":"native-fixture-answer"}`,
			`{"type":"response.output_text.done","item_id":"msg_fixture","output_index":0,"content_index":0,"text":"native-fixture-answer"}`,
			`{"type":"response.output_item.done","output_index":0,"item":{"id":"msg_fixture","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"native-fixture-answer","annotations":[]}]}}`,
			`{"type":"response.completed","response":{"id":"resp_fixture","object":"response","status":"completed","output":[{"id":"msg_fixture","type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"native-fixture-answer","annotations":[]}]}],"usage":{"input_tokens":5,"output_tokens":3,"total_tokens":8}}}`,
		}
	case "claude":
		events = []string{
			`{"type":"message_start","message":{"id":"msg_fixture","type":"message","role":"assistant","model":"fixture","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":5,"output_tokens":0}}}`,
			`{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}`,
			`{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"native-fixture-answer"}}`,
			`{"type":"content_block_stop","index":0}`,
			`{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":null},"usage":{"output_tokens":3}}`,
			`{"type":"message_stop"}`,
		}
	}
	for _, event := range events {
		if provider != "pi" {
			var value map[string]any
			_ = json.Unmarshal([]byte(event), &value)
			fmt.Fprintf(w, "event: %s\n", value["type"])
		}
		fmt.Fprintf(w, "data: %s\n\n", event)
	}
}

// Exercises both durable Connector owners and archive transport. Provider
// readiness is injected here; real CLI continuation is a separate E2E boundary.
func TestMigrationTransferStagesWithoutExecutionAndActivatesAfterRestart(t *testing.T) {
	ctx := context.Background()
	const id = "ses1_2098040323912503296"
	makeConnector := func(root string, target bool) *connector {
		c := newEventTestConnector(t, root)
		a, _ := newTestWorkspaceArchiver(t)
		a.root = filepath.Join(root, "workspaces")
		if err := os.MkdirAll(a.root, 0700); err != nil {
			t.Fatal(err)
		}
		a.runtimeState = c.externalRuntimeState
		c.workspaceArchiver = a
		c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": newPiRuntimeImplementation(c)}
		c.cfg.runtimeAgent = target
		c.cfg.computeRuntimeKind = "external_worker"
		c.cfg.computeRuntimeProvider = "pi"
		c.runtimeInventory = newRuntimeInventory()
		c.runtimeInventory.run = func(p runtimeProbeTarget) map[string]any {
			return map[string]any{"kind": "external", "provider": p.provider, "identity_material": p.identityMaterial, "ready": true}
		}
		c.runtimeInventory.runtimes["pi\x00/test/pi"] = c.runtimeInventory.run(runtimeProbeTarget{provider: "pi", identityMaterial: "/test/pi"})
		if err := c.externalRuntimeState.load(); err != nil {
			t.Fatal(err)
		}
		return c
	}
	source := makeConnector(t.TempDir(), false)
	defer source.externalRuntimeState.close()
	targetRoot := t.TempDir()
	target := makeConnector(targetRoot, true)
	defer func() { target.externalRuntimeState.close() }()
	seedWorkspace(t, source.workspaceArchiver.root, id)
	large := make([]byte, 2<<20)
	if _, err := rand.Read(large); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source.workspaceArchiver.root, id, "uncommitted.bin"), large, 0600); err != nil {
		t.Fatal(err)
	}
	record := testRecoveryObligationRecord("pi", id, "dispatch", "execution")
	record.Workspace = filepath.Join(source.workspaceArchiver.root, id)
	record.Payload = map[string]any{"session_id": "native-id"}
	native := filepath.Join(source.root, "external-runtime", "pi", id, "date_native-id.jsonl")
	if err := os.MkdirAll(filepath.Dir(native), 0700); err != nil {
		t.Fatal(err)
	}
	history := []byte("{\"type\":\"session\",\"version\":3,\"id\":\"native-id\",\"cwd\":\"/original\"}\n" + `{"type":"message", "message":{"role":"user","content":"unchanged transcript /original"}}` + "\n")
	if err := os.WriteFile(native, history, 0600); err != nil {
		t.Fatal(err)
	}
	persistRuntimeIdentity(t, source.externalRuntimeState, externalRuntimeIdentityFromRecovery(record))
	params := map[string]any{"operation_id": "move-transfer", "provider": "pi", "session_id": id,
		"source": "connected-source", "destination": "compute-target", "deadline": time.Now().Add(time.Minute).UnixMilli(), "capability_token": record.Token}
	if _, err := source.methodSessionMigration(ctx, "prepare", params); err != nil {
		t.Fatal(err)
	}
	var last map[string]any
	for attempt := 0; attempt < 2; attempt++ {
		for offset := int64(0); ; {
			export := maps.Clone(params)
			export["offset"] = offset
			chunk, err := source.methodSessionMigration(ctx, "export", export)
			if err != nil {
				t.Fatal(err)
			}
			last = maps.Clone(params)
			delete(last, "capability_token")
			maps.Copy(last, chunk)
			if offset == 0 {
				missing := maps.Clone(last)
				missing["offset"] = int64(1 << 20)
				if _, err := target.methodSessionMigration(ctx, "import", missing); err == nil {
					t.Fatal("target accepted a missing first chunk")
				}
			}
			receipt, err := target.methodSessionMigration(ctx, "import", last)
			if err != nil {
				t.Fatal(err)
			}
			offset = int64Param(receipt, "next_offset", -1)
			if _, err := target.methodSessionMigration(ctx, "import", last); err != nil {
				t.Fatalf("chunk retry: %v", err)
			}
			if boolParam(chunk, "done") {
				break
			}
			target.externalRuntimeState.close()
			target = makeConnector(targetRoot, true)
			status, err := target.methodSessionMigration(ctx, "status", params)
			if err != nil || int64Param(status, "next_offset", -1) != offset {
				t.Fatalf("restart lost chunk offset: %v %v", status, err)
			}
		}
		if attempt == 0 {
			cancel := maps.Clone(params)
			cancel["cancel"] = true
			for _, c := range []*connector{target, source} {
				if _, err := c.methodSessionMigration(ctx, "prepare", cancel); err != nil {
					t.Fatal(err)
				}
			}
			if _, exists := target.externalRuntimeState.identities["pi\x00"+id]; exists {
				t.Fatal("cancel left target identity")
			}
			if _, err := os.Stat(native); err != nil {
				t.Fatalf("cancel deleted source history: %v", err)
			}
			if _, err := source.methodSessionMigration(ctx, "prepare", params); err != nil {
				t.Fatal(err)
			}
		}
	}
	workspace := filepath.Join(target.workspaceArchiver.root, id)
	if _, err := os.Stat(workspace); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stage published workspace: %v", err)
	}
	if len(target.externalRuntimeState.activeExecutions) != 0 {
		t.Fatal("stage started execution")
	}
	target.externalRuntimeState.close()
	target = makeConnector(targetRoot, true)
	if status, err := target.methodSessionMigration(ctx, "status", params); err != nil || status["phase"] != "staged" {
		t.Fatalf("restart lost staging: %v %v", status, err)
	}
	if _, err := source.methodSessionMigration(ctx, "retire", params); err != nil {
		t.Fatal(err)
	}
	activation := maps.Clone(params)
	activation["activate"] = true
	if _, err := target.methodSessionMigration(ctx, "import", activation); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(workspace, "notes.md")); err != nil {
		t.Fatal(err)
	}
	if got, err := os.ReadFile(filepath.Join(workspace, "uncommitted.bin")); err != nil || !bytes.Equal(got, large) {
		t.Fatalf("chunk transfer changed uncommitted bytes: %v", err)
	}
	installed := target.externalRuntimeState.identities["pi\x00"+id]
	got, err := os.ReadFile(stringParam(installed.Payload, "session_file"))
	if err != nil || !bytes.Equal(bytes.SplitN(got, []byte("\n"), 2)[1], bytes.SplitN(history, []byte("\n"), 2)[1]) {
		t.Fatalf("native history changed: %s %v", got, err)
	}
	var relocatedHeader map[string]any
	if err := json.Unmarshal(bytes.SplitN(got, []byte("\n"), 2)[0], &relocatedHeader); err != nil || relocatedHeader["cwd"] != workspace || relocatedHeader["id"] != "native-id" {
		t.Fatalf("native location or identity changed incorrectly: %v %v", relocatedHeader, err)
	}
	if _, err := target.methodSessionMigration(ctx, "import", last); err != nil {
		t.Fatal(err)
	}
	if stringParam(target.externalRuntimeState.identities["pi\x00"+id].Payload, "migration_operation_id") != "" {
		t.Fatal("late import restored staging identity")
	}
	cancel := maps.Clone(params)
	cancel["cancel"] = true
	if _, err := source.methodSessionMigration(ctx, "prepare", cancel); err == nil {
		t.Fatal("retired source resumed")
	}
	if _, err := target.methodSessionMigration(ctx, "prepare", cancel); err == nil {
		t.Fatal("activated target was deleted")
	}
}

func TestMigrationArchivePreservesUncommittedFilesAndLinks(t *testing.T) {
	_, root := newTestWorkspaceArchiver(t)
	id := "ses1_2098040323912503296"
	seedWorkspace(t, root, id)
	workspace := filepath.Join(root, id)
	original := filepath.Join(workspace, "notes.md")
	if err := os.Chmod(original, 0751); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(original, filepath.Join(workspace, "notes-hardlink")); err != nil {
		t.Fatal(err)
	}
	files, size, err := migrationFileManifest(context.Background(), map[string]string{"workspace": workspace})
	if err != nil {
		t.Fatal(err)
	}
	record := testRecoveryObligationRecord("pi", id, "dispatch", "execution")
	manifest := runtimeMigrationManifest{OperationID: "move-1", Identity: externalRuntimeIdentityFromRecovery(record), Files: files, Bytes: size}
	var archive bytes.Buffer
	if err := writeMigrationArchive(context.Background(), &archive, manifest); err != nil {
		t.Fatal(err)
	}
	target := t.TempDir()
	if _, err := extractMigrationArchive(context.Background(), &archive, target, "move-1", id); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"notes.md", ".git/HEAD", "node_modules/left-pad/index.js", "src-link/main.ex"} {
		before, err := os.ReadFile(filepath.Join(workspace, name))
		if err != nil {
			t.Fatal(err)
		}
		after, err := os.ReadFile(filepath.Join(target, "workspace", name))
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(before, after) {
			t.Fatalf("migration changed %s", name)
		}
	}
	info, err := os.Stat(filepath.Join(target, "workspace", "notes.md"))
	if err != nil {
		t.Fatal(err)
	}
	linked, err := os.Stat(filepath.Join(target, "workspace", "notes-hardlink"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0751 || !os.SameFile(info, linked) {
		t.Fatal("migration lost permissions or hard-link identity")
	}
}

func TestMigrationRejectsWorkspaceLinkToUnselectedData(t *testing.T) {
	root := t.TempDir()
	workspace := filepath.Join(root, "workspace")
	if err := os.Mkdir(workspace, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "private"), []byte("unselected"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../private", filepath.Join(workspace, "outside")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := migrationFileManifest(context.Background(), map[string]string{"workspace": workspace}); err == nil {
		t.Fatal("migration accepted an out-of-scope file")
	}
	rootLink := filepath.Join(root, "selected-link")
	if err := os.Remove(filepath.Join(workspace, "outside")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(workspace, rootLink); err != nil {
		t.Fatal(err)
	}
	if _, _, err := migrationFileManifest(context.Background(), map[string]string{"workspace": rootLink}); err == nil {
		t.Fatal("migration followed a selected root symlink")
	}
}

func TestMigrationFreezeProtectsWorkspaceAlreadySelectedForArchive(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	a, root := newTestWorkspaceArchiver(t)
	a.runtimeState = c.externalRuntimeState
	id := "ses1_2098040323912503296"
	seedWorkspace(t, root, id)
	record := testRecoveryObligationRecord("pi", id, "dispatch", "execution")
	record.Workspace = filepath.Join(root, id)
	persistRuntimeIdentity(t, c.externalRuntimeState, externalRuntimeIdentityFromRecovery(record))
	seal := externalRuntimeMigrationSeal{OperationID: "move-1", Provider: "pi", SessionID: id,
		Source: "source", Target: "target", Deadline: time.Now().Add(time.Minute).UnixMilli()}
	if err := c.externalRuntimeState.prepareMigration(seal, record.Token); err != nil {
		t.Fatal(err)
	}
	if err := a.archiveOne(context.Background(), id, nil); !errors.Is(err, errRuntimeMigrationFrozen) {
		t.Fatalf("selected archive bypassed freeze: %v", err)
	}
	if _, err := os.Stat(filepath.Join(record.Workspace, "notes.md")); err != nil {
		t.Fatalf("migration source files changed: %v", err)
	}
}

func TestMigrationSourceSealSurvivesLostRetireReplyAndRestart(t *testing.T) {
	root := t.TempDir()
	c := newEventTestConnector(t, root)
	record := testRecoveryObligationRecord("pi", "ses1_2098040323912503296", "dispatch", "execution")
	persistRuntimeIdentity(t, c.externalRuntimeState, externalRuntimeIdentityFromRecovery(record))
	seal := externalRuntimeMigrationSeal{OperationID: "move-1", Provider: "pi", SessionID: record.SessionID,
		Source: "connected-source", Target: "workload-target", Deadline: time.Now().Add(time.Minute).UnixMilli()}
	if err := c.externalRuntimeState.prepareMigration(seal, record.Token); err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.watch(record); !errors.Is(err, errRuntimeMigrationFrozen) {
		t.Fatalf("prepared source accepted native execution: %v", err)
	}
	if err := c.externalRuntimeState.retireMigration("pi", record.SessionID, "move-1", record.Token); err != nil {
		t.Fatal(err)
	}
	c.externalRuntimeState.close()
	c = newEventTestConnector(t, root)
	defer c.externalRuntimeState.close()
	if err := c.externalRuntimeState.retireMigration("pi", record.SessionID, "move-1", record.Token); err != nil {
		t.Fatalf("lost reply could not be retried after restart: %v", err)
	}
	input := record.input()
	input.messages = []map[string]any{{"role": "user", "content": "late source input"}}
	if err := c.externalRuntimeState.enqueueInputBatch("pi", input); !errors.Is(err, errRuntimeMigrationFrozen) {
		t.Fatalf("restarted source accepted late input: %v", err)
	}
	changed := seal
	changed.Target = "different-target"
	if err := c.externalRuntimeState.prepareMigration(changed, record.Token); err == nil {
		t.Fatal("operation changed its target after retirement")
	}
	other := testRecoveryObligationRecord("pi", "ses1_2098040323912503297", "other", "other")
	if err := c.externalRuntimeState.watch(other); err != nil {
		t.Fatalf("migration blocked another Session: %v", err)
	}
}

func TestArchiveDiscardRemovesOnlyExactSessionAndIsReplaySafe(t *testing.T) {
	root := t.TempDir()
	c := newEventTestConnector(t, root)
	defer c.externalRuntimeState.close()
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": newPiRuntimeImplementation(c)}
	workspaces := filepath.Join(root, "workspaces")
	c.workspaceArchiver = newWorkspaceArchiver(workspaces, true, time.Hour, time.Minute)
	c.workspaceArchiver.runtimeState = c.externalRuntimeState

	id := "ses1_2098040323912503296"
	otherID := "ses1_2098040323912503297"
	seedWorkspace(t, workspaces, id)
	seedWorkspace(t, workspaces, otherID)
	nativeID := "01JARCHIVEDISCARD"
	nativeDir := filepath.Join(root, "external-runtime", "pi", id)
	if err := os.MkdirAll(nativeDir, 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(nativeDir, "2026-09-16_"+nativeID+".jsonl"), []byte(`{"type":"session","id":"`+nativeID+`"}`+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	record := testRecoveryObligationRecord("pi", id, "discard-dispatch", "discard-execution")
	record.Workspace = filepath.Join(workspaces, id)
	record.Payload = map[string]any{"session_id": nativeID}
	persistRuntimeIdentity(t, c.externalRuntimeState, externalRuntimeIdentityFromRecovery(record))
	input := record.input()
	input.messages = []map[string]any{{"role": "user", "content": "owned pending copy"}}
	batch := externalRuntimeInputBatch{
		Version: 1, Session: externalRuntimeRecoveryRecordFromInput("pi", input), Messages: input.messages,
	}
	raw, err := json.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeInputBatchesBucket).Put([]byte(batch.key()), raw)
	}); err != nil {
		t.Fatal(err)
	}

	params := map[string]any{
		"operation_id": "archive-discard-1", "provider": "pi", "session_id": id,
		"source": "connected-source", "destination": "permanent-archive:agent", "capability_token": record.Token,
	}
	for attempt := 0; attempt < 2; attempt++ {
		value, err := c.dispatchSession(context.Background(), nil, "discard-request", "session_migration_discard", params)
		result, _ := value.(map[string]any)
		if err != nil || stringParam(result, "phase") != "discarded" {
			t.Fatalf("archive discard attempt %d: result=%v err=%v", attempt, result, err)
		}
	}
	for _, removed := range []string{record.Workspace, nativeDir} {
		if _, err := os.Lstat(removed); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("archive discard retained %s: %v", removed, err)
		}
	}
	if _, err := os.Stat(filepath.Join(workspaces, otherID, "notes.md")); err != nil {
		t.Fatalf("archive discard changed another Session: %v", err)
	}
	if _, exists := c.externalRuntimeState.identities["pi\x00"+id]; exists {
		t.Fatal("archive discard retained source identity")
	}
	if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
		prefix := []byte("pi\x00" + id + "\x00")
		key, _ := tx.Bucket(externalRuntimeInputBatchesBucket).Cursor().Seek(prefix)
		if bytes.HasPrefix(key, prefix) {
			return errors.New("archive discard retained input rows")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestArchiveDiscardRemovesUnsettledSessionWithoutNativeIdentity(t *testing.T) {
	root := t.TempDir()
	c := newEventTestConnector(t, root)
	defer c.externalRuntimeState.close()
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"pi": newPiRuntimeImplementation(c)}
	workspaces := filepath.Join(root, "workspaces")
	c.workspaceArchiver = newWorkspaceArchiver(workspaces, true, time.Hour, time.Minute)
	c.workspaceArchiver.runtimeState = c.externalRuntimeState

	id := "ses1_2098040323912503296"
	otherID := "ses1_2098040323912503297"
	seedWorkspace(t, workspaces, id)
	seedWorkspace(t, workspaces, otherID)
	nativeSentinel := filepath.Join(root, "external-runtime", "pi", id, "unowned-native.jsonl")
	sharedCredentialSentinel := filepath.Join(root, "external-runtime", "pi", "shared-auth.json")
	for _, path := range []string{nativeSentinel, sharedCredentialSentinel} {
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("preserve"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Dir(c.workspaceArchiver.archivePath(id)), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(c.workspaceArchiver.archivePath(id), []byte("empty archive"), 0600); err != nil {
		t.Fatal(err)
	}
	record := testRecoveryObligationRecord("pi", id, "discard-dispatch", "")
	input := record.input()
	input.messages = []map[string]any{{"role": "user", "content": "owned pending copy"}}
	batch := externalRuntimeInputBatch{
		Version: 1, Session: externalRuntimeRecoveryRecordFromInput("pi", input), Messages: input.messages,
	}
	raw, err := json.Marshal(batch)
	if err != nil {
		t.Fatal(err)
	}
	if err := c.externalRuntimeState.db.Update(func(tx *bolt.Tx) error {
		return tx.Bucket(externalRuntimeInputBatchesBucket).Put([]byte(batch.key()), raw)
	}); err != nil {
		t.Fatal(err)
	}

	params := map[string]any{
		"operation_id": "archive-discard-unsettled", "provider": "pi", "session_id": id,
		"source": "connected-source", "destination": "permanent-archive:agent", "capability_token": record.Token,
	}
	for attempt := 0; attempt < 2; attempt++ {
		value, err := c.dispatchSession(context.Background(), nil, "discard-request", "session_migration_discard", params)
		result, _ := value.(map[string]any)
		if err != nil || stringParam(result, "phase") != "discarded" {
			t.Fatalf("archive discard attempt %d: result=%v err=%v", attempt, result, err)
		}
	}
	for _, removed := range []string{filepath.Join(workspaces, id), c.workspaceArchiver.archivePath(id)} {
		if _, err := os.Lstat(removed); !errors.Is(err, os.ErrNotExist) {
			t.Fatalf("archive discard retained %s: %v", removed, err)
		}
	}
	if _, err := os.Stat(filepath.Join(workspaces, otherID, "notes.md")); err != nil {
		t.Fatalf("archive discard changed another Session: %v", err)
	}
	for _, preserved := range []string{nativeSentinel, sharedCredentialSentinel} {
		if _, err := os.Stat(preserved); err != nil {
			t.Fatalf("archive discard changed unowned provider data %s: %v", preserved, err)
		}
	}
	if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
		prefix := []byte("pi\x00" + id + "\x00")
		key, _ := tx.Bucket(externalRuntimeInputBatchesBucket).Cursor().Seek(prefix)
		if bytes.HasPrefix(key, prefix) {
			return errors.New("archive discard retained input rows")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

func TestMigrationPreparePreservesUnsettledExecution(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	record := testRecoveryObligationRecord("pi", "ses1_2098040323912503296", "dispatch", "execution")
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	seal := externalRuntimeMigrationSeal{OperationID: "move-1", Provider: "pi", SessionID: record.SessionID,
		Source: "source", Target: "target", Deadline: time.Now().Add(time.Minute).UnixMilli()}
	if err := c.externalRuntimeState.prepareMigration(seal, record.Token); !errors.Is(err, errRuntimeNotQuiet) {
		t.Fatalf("unsettled execution accepted for migration: %v", err)
	}
	if !c.externalRuntimeState.watched("pi", record.SessionID) {
		t.Fatal("prepare discarded accepted work")
	}
}

func makeMigrationNonce(t *testing.T) []byte {
	t.Helper()
	value := make([]byte, 16)
	if _, err := rand.Read(value); err != nil {
		t.Fatal(err)
	}
	return value
}
