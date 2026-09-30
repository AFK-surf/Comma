package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestConnectedPrivateRuntimeAuthRejectsUnownedCredentialImport(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	c.runtimeAuthSlots = make(chan struct{}, runtimeAuthConcurrency)
	c.runtimeInventory = newRuntimeInventory()
	implementation := newCodexRuntimeImplementation(c)
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": implementation}
	c.runtimeInventory.commitGuard = implementation.commitRuntimeProbe
	session := c.claimConnection(context.Background(), func(context.Context, message) error { return nil }, nil)
	defer session.close(nil)
	if !c.setIdentity(session, "run", "device", "connector", "admin", 1) {
		t.Fatal("identity rejected")
	}
	off := c.activateRuntimeTransport(session.sendCtx)
	defer off()
	directory := t.TempDir()
	t.Setenv("PI_CODING_AGENT_DIR", directory)
	sdkRoot := filepath.Join(t.TempDir(), "dist")
	if err := os.MkdirAll(filepath.Join(sdkRoot, "bundle"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(
		filepath.Join(sdkRoot, "index.js"),
		[]byte(`export function getAgentDir(){ return process.env.PI_CODING_AGENT_DIR; }`),
		0o600,
	); err != nil {
		t.Fatal(err)
	}
	command := filepath.Join(sdkRoot, "bundle", "cli.js")
	if err := os.WriteFile(command, []byte(""), 0o600); err != nil {
		t.Fatal(err)
	}
	target := runtimeProbeTarget{provider: "pi", identityMaterial: command}
	c.runtimeInventory.runtimes[target.key()] = map[string]any{
		"kind": "external", "provider": "pi", "identity_material": target.identityMaterial,
		"readiness_valid_until": time.Now().Add(time.Minute).UnixMilli(),
	}
	wire := map[string]any{
		"actor_id": "admin", "tenant_id": "tenant", "project_id": "project",
		"device_id": "device", "runtime_id": "pi-runtime", "provider": "pi",
		"identity_material": target.identityMaterial, "runtime_instance_id": "run",
		"generation": 1, "connection_epoch": "1",
	}

	status, err := c.connectedPrivateRuntimeAuth(
		context.Background(), session, "runtime_auth_status", map[string]any{"target": wire},
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, method := range status["methods"].([]map[string]any) {
		if stringParam(method, "method") == "credential_import" {
			t.Fatalf("connected target advertised an unowned writer: %#v", method)
		}
	}

	if _, err := c.connectedPrivateRuntimeAuth(
		context.Background(), session, "runtime_auth_input_begin",
		map[string]any{"target": wire, "backend": "openrouter", "form": "api_key"},
	); err == nil {
		t.Fatal("connected target accepted credential import without single-writer ownership")
	}
	binding := runtimeAuthInputContext{
		ActorID: "admin", TargetKind: "connected_runtime", RuntimeID: "pi-runtime",
		Provider: "pi", Backend: "openrouter", Method: "credential_import",
		Form: "api_key", SchemaVersion: 1,
	}
	if _, err := implementation.auth.beginPrivateInput(target, binding); err == nil {
		t.Fatal("target owner accepted connected credential import")
	}
	if _, err := os.Stat(filepath.Join(directory, "auth.json")); !os.IsNotExist(err) {
		t.Fatalf("rejected import touched provider state: %v", err)
	}
}

func TestConnectedPrivateRuntimeAuthRejectsUnownedClaudeMutation(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	command := fakeClaudeRuntimeCommand(t)
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	c.runtimeAuthSlots = make(chan struct{}, runtimeAuthConcurrency)
	c.runtimeInventory = newRuntimeInventory()
	codex := newCodexRuntimeImplementation(c)
	claude := newClaudeRuntimeImplementation(c)
	c.runtimeImplementations = map[string]externalRuntimeImplementation{
		"codex": codex, "claude": claude,
	}
	c.runtimeInventory.commitGuard = codex.commitRuntimeProbe
	session := c.claimConnection(context.Background(), func(context.Context, message) error { return nil }, nil)
	defer session.close(nil)
	if !c.setIdentity(session, "run", "device", "connector", "admin", 1) {
		t.Fatal("identity rejected")
	}
	off := c.activateRuntimeTransport(session.sendCtx)
	defer off()
	target := runtimeProbeTarget{provider: "claude", identityMaterial: command}
	c.runtimeInventory.runtimes[target.key()] = map[string]any{
		"kind": "external", "provider": "claude", "identity_material": command,
		"version":               "2.1.258 (Claude Code)",
		"readiness_valid_until": time.Now().Add(time.Minute).UnixMilli(),
	}
	wire := map[string]any{
		"actor_id": "admin", "tenant_id": "tenant", "project_id": "project",
		"device_id": "device", "runtime_id": "claude-runtime", "provider": "claude",
		"identity_material": command, "runtime_instance_id": "run",
		"generation": 1, "connection_epoch": "1",
	}

	status, err := c.connectedPrivateRuntimeAuth(
		context.Background(), session, "runtime_auth_status", map[string]any{"target": wire},
	)
	if err != nil {
		t.Fatal(err)
	}
	for _, method := range status["methods"].([]map[string]any) {
		if stringParam(method, "method") == "credential_import" ||
			stringParam(method, "method") == "native_login" {
			t.Fatalf("connected target advertised an unowned writer: %#v", method)
		}
	}

	if _, err := c.connectedPrivateRuntimeAuth(
		context.Background(), session, "runtime_auth_input_begin",
		map[string]any{"target": wire, "backend": "anthropic", "form": "api_key"},
	); err == nil {
		t.Fatal("connected target accepted Claude credential import")
	}
	if _, err := c.connectedPrivateRuntimeAuth(
		context.Background(), session, "runtime_auth_login_start",
		map[string]any{"target": wire, "backend": "anthropic", "flow": runtimeAuthClaudeLoginFlow},
	); err == nil {
		t.Fatal("connected target accepted Claude login that commits provider state")
	}
	binding := runtimeAuthInputContext{
		ActorID: "admin", TargetKind: "connected_runtime", RuntimeID: "claude-runtime",
		Provider: "claude", Backend: "anthropic", Method: "credential_import",
		Form: "api_key", SchemaVersion: 1,
	}
	if _, err := codex.auth.beginPrivateInput(target, binding); err == nil {
		t.Fatal("target owner accepted connected Claude credential import")
	}
}

func TestConnectedRuntimeAuthCloseCannotCrossRename(t *testing.T) {
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	session := c.claimConnection(context.Background(), func(context.Context, message) error { return nil }, nil)
	defer session.close(nil)
	c.setIdentity(session, "run", "device", "connector", "admin", 1)
	off := c.activateRuntimeTransport(session.sendCtx)
	defer off()
	local := &runtimeAuthPrivateTarget{carrier: c.getActiveTransport(), connection: session}
	scope := runtimeAuthInputContext{DeviceID: "device", RuntimeInstanceID: "run", Generation: "1"}
	entered, release, done := make(chan struct{}), make(chan struct{}), make(chan runtimeAuthSaveOutcome, 1)
	go func() {
		done <- c.commitPrivateRuntimeAuth(context.Background(), local, scope, func() runtimeAuthSaveOutcome {
			close(entered)
			<-release
			return runtimeAuthSaveOutcome{SaveResult: "committed"}
		})
	}()
	<-entered
	closed := make(chan struct{})
	go func() { session.close(nil); close(closed) }()
	select {
	case <-closed:
		t.Error("connection close crossed admitted native mutation")
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	if (<-done).SaveResult != "committed" {
		t.Fatal("admitted commit failed")
	}
	<-closed
	called := false
	result := c.commitPrivateRuntimeAuth(context.Background(), local, scope, func() runtimeAuthSaveOutcome { called = true; return runtimeAuthSaveOutcome{} })
	if called || result.Issue != "target_changed" {
		t.Fatal("closed connection retained write authority")
	}
}

func TestConnectedNativeLoginScopesCeremonyAndCancellation(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{
		"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE":          "none",
		"SALIX_TEST_FAKE_CODEX_LOGIN_COMPLETION_GATE": filepath.Join(t.TempDir(), "complete"),
	})
	session := c.claimConnection(context.Background(), func(context.Context, message) error { return nil }, nil)
	defer session.close(nil)
	if !c.setIdentity(session, "run", "device", "connector", "admin", 1) {
		t.Fatal("identity rejected")
	}
	off := c.activateRuntimeTransport(session.sendCtx)
	defer off()
	wire := map[string]any{"actor_id": "admin", "tenant_id": "tenant", "project_id": "project", "device_id": "device", "runtime_id": "runtime", "provider": "codex", "identity_material": command, "runtime_instance_id": "run", "generation": 1, "connection_epoch": "1"}
	call := func(method string, attrs map[string]any) (map[string]any, error) {
		attrs["target"] = wire
		return c.connectedPrivateRuntimeAuth(context.Background(), session, method, attrs)
	}
	started, err := call("runtime_auth_login_start", map[string]any{"backend": "chatgpt", "flow": "device_code"})
	if err != nil {
		t.Fatal(err)
	}
	status, err := call("runtime_auth_status", map[string]any{})
	if err != nil || stringParam(mapParam(mapParam(status, "attempt"), "ceremony"), "user_code") == "" {
		t.Fatal("initiator cannot read ceremony", err)
	}
	wire["actor_id"] = "other-admin"
	status, err = call("runtime_auth_status", map[string]any{})
	if err != nil || mapParam(status, "attempt")["owned"] != false || mapParam(status, "attempt")["ceremony"] != nil {
		t.Fatal("ceremony exposed to another administrator", err)
	}
	if _, err = call("runtime_auth_login_start", map[string]any{"backend": "chatgpt", "flow": "device_code"}); err == nil {
		t.Fatal("another administrator reused the code")
	}
	canceled, err := call("runtime_auth_input_cancel", map[string]any{"attempt_id": started["attempt_id"]})
	if err != nil || canceled["issue"] != "canceled" {
		t.Fatal("administrator cannot cancel ceremony", err)
	}
	status, err = call("runtime_auth_status", map[string]any{})
	if err != nil || status["attempt"] != nil {
		t.Fatalf("canceled ceremony remained active: %#v, %v", status, err)
	}
}
