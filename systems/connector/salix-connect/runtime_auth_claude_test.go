package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/cloudflare/circl/hpke"
)

func TestRuntimeAuthClaudeBackendRejectsExecutableAndCrossBackendInput(t *testing.T) {
	for _, test := range []struct {
		name, backend, input string
		valid                bool
	}{
		{"openrouter", "openrouter", `{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key","ANTHROPIC_API_KEY":""}}`, true},
		{"setup token", "anthropic", `{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"synthetic-token"}}`, true},
		{"mixed token", "anthropic", `{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"synthetic-token","ANTHROPIC_API_KEY":"other"}}`, false},
		{"token endpoint", "anthropic", `{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"synthetic-token","ANTHROPIC_BASE_URL":"https://example.com"}}`, false},
		{"anthropic", "anthropic", `{"env":{"ANTHROPIC_API_KEY":"synthetic-key"}}`, true},
		{"foreign endpoint", "openrouter", `{"env":{"ANTHROPIC_BASE_URL":"https://example.com/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key","ANTHROPIC_API_KEY":""}}`, false},
		{"missing empty api key", "openrouter", `{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key"}}`, false},
		{"competing api key", "openrouter", `{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key","ANTHROPIC_API_KEY":"other-key"}}`, false},
		{"cross backend", "anthropic", `{"env":{"ANTHROPIC_BASE_URL":"https://openrouter.ai/api","ANTHROPIC_AUTH_TOKEN":"synthetic-key","ANTHROPIC_API_KEY":""}}`, false},
		{"helper", "anthropic", `{"env":{"ANTHROPIC_API_KEY":"synthetic-key"},"apiKeyHelper":"touch /tmp/never"}`, false},
		{"hook", "anthropic", `{"env":{"ANTHROPIC_API_KEY":"synthetic-key"},"hooks":{}}`, false},
		{"indirect env", "anthropic", `{"env":{"ANTHROPIC_API_KEY":{"env":"SECRET"}}}`, false},
		{"duplicate", "anthropic", `{"env":{"ANTHROPIC_API_KEY":"one","ANTHROPIC_API_KEY":"two"}}`, false},
		{"null", "anthropic", `{"env":{"ANTHROPIC_API_KEY":null}}`, false},
		{"unsupported backend", "other", `{"env":{"ANTHROPIC_API_KEY":"synthetic-key"}}`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := parseRuntimeAuthClaudeBackend([]byte(test.input), test.backend)
			if (err == nil) != test.valid {
				t.Fatalf("accepted = %v, want %v", err == nil, test.valid)
			}
		})
	}
}

func TestRuntimeAuthClaudeCredentialsRejectsUnknownAndAmbiguousInput(t *testing.T) {
	valid := `{"claudeAiOauth":{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh","expiresAt":4102444800000,"refreshTokenExpiresAt":4102444800000,"scopes":["user:inference"],"clientId":"synthetic-client","subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}`
	for _, test := range []struct {
		name, input string
		valid       bool
	}{
		{"native record", valid, true},
		{"unknown root", `{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["user:inference"]},"hooks":{}}`, false},
		{"unknown credential field", `{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["user:inference"],"command":"run"}}`, false},
		{"missing inference", `{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["user:profile"]}}`, false},
		{"duplicate scope", `{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["user:inference","user:inference"]}}`, false},
		{"invalid tier", `{"claudeAiOauth":{"accessToken":"a","refreshToken":"r","expiresAt":1,"scopes":["user:inference"],"rateLimitTier":"../../other"}}`, false},
		{"duplicate member", `{"claudeAiOauth":{"accessToken":"a","accessToken":"b","refreshToken":"r","expiresAt":1,"scopes":["user:inference"]}}`, false},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := parseRuntimeAuthClaudeCredentials([]byte(test.input))
			if (err == nil) != test.valid {
				t.Fatalf("accepted = %v, want %v", err == nil, test.valid)
			}
		})
	}
}

func TestRuntimeAuthClaudeVersionSupported(t *testing.T) {
	for _, test := range []struct {
		version string
		want    bool
	}{
		{"2.1.258 (Claude Code)", true},
		{"2.1.258", true},
		{"2.1.259 (Claude Code)", false},
		{"", false},
	} {
		if got := runtimeAuthClaudeVersionSupported(test.version); got != test.want {
			t.Fatalf("runtimeAuthClaudeVersionSupported(%q) = %v, want %v", test.version, got, test.want)
		}
	}
}

func TestRuntimeAuthClaudeExecEnvIsolatesOnlyManagedProfiles(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "host-api-key")
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "host-auth-token")
	t.Setenv("ANTHROPIC_BASE_URL", "https://host.example")
	t.Setenv("CLAUDE_CODE_OAUTH_TOKEN", "host-setup-token")
	t.Setenv("SALIX_TEST_ENV", "preserved")

	isolated := strings.Join(runtimeAuthClaudeExecEnv(map[string]any{"PATH": "/managed/bin"}, true), "\n")
	for _, forbidden := range []string{"ANTHROPIC_API_KEY=", "ANTHROPIC_AUTH_TOKEN=", "ANTHROPIC_BASE_URL=", "CLAUDE_CODE_OAUTH_TOKEN="} {
		if strings.Contains(isolated, forbidden) {
			t.Fatalf("isolated Claude environment retained %q", forbidden)
		}
	}
	for _, want := range []string{"PATH=/managed/bin", "SALIX_TEST_ENV=preserved"} {
		if !strings.Contains(isolated, want) {
			t.Fatalf("isolated Claude environment omitted %q:\n%s", want, isolated)
		}
	}

	connected := strings.Join(runtimeAuthClaudeExecEnv(map[string]any{"PATH": "/connected/bin"}, false), "\n")
	for _, want := range []string{
		"ANTHROPIC_API_KEY=host-api-key", "ANTHROPIC_AUTH_TOKEN=host-auth-token",
		"ANTHROPIC_BASE_URL=https://host.example", "PATH=/connected/bin",
	} {
		if !strings.Contains(connected, want) {
			t.Fatalf("connected Claude environment omitted %q:\n%s", want, connected)
		}
	}
}

func TestRuntimeAuthClaudeCredentialsCommitRemovesSettingsCarrier(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", directory)
	settingsPath, err := runtimeAuthClaudeLocation()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(settingsPath, []byte(`{"env":{"ANTHROPIC_API_KEY":"old-api-key"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	credentialsPath := filepath.Join(directory, runtimeAuthClaudeCredentialsName)
	data := []byte(`{"claudeAiOauth":{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh","expiresAt":4102444800000,"scopes":["user:inference"]}}`)
	outcome := saveRuntimeAuthClaudeCredentials(context.Background(), credentialsPath, data, func(stage string) runtimeAuthSaveOutcome {
		return commitRuntimeAuthClaudeCredentials(context.Background(), stage, credentialsPath)
	})
	if outcome.SaveResult != "committed" || outcome.Issue != "" {
		t.Fatalf("save = %+v", outcome)
	}
	if _, err := os.Stat(settingsPath); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("settings carrier remains: %v", err)
	}
	got, err := os.ReadFile(credentialsPath)
	if err != nil || !bytes.Equal(got, data) {
		t.Fatalf("credentials = %q/%v", got, err)
	}
}

func TestRuntimeAuthClaudeAuthorizationLoginUsesIsolatedNativeWriter(t *testing.T) {
	t.Setenv("CLAUDE_CODE_OAUTH_TOKEN", "host-setup-token")
	command := filepath.Join(t.TempDir(), "claude")
	query := "code=true&client_id=synthetic-client&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=synthetic-challenge&code_challenge_method=S256&state=synthetic-state"
	script := `#!/bin/sh
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || exit 5
printf '%s\n' 'Opening browser: https://claude.com/cai/oauth/authorize?` + query + `'
IFS= read -r code
[ "$code" = "synthetic-code" ] || exit 4
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '%s' '{"claudeAiOauth":{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh","expiresAt":4102444800000,"scopes":["user:inference"]}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
chmod 600 "$CLAUDE_CONFIG_DIR/.credentials.json"
`
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	carrier := &runtimeTransport{done: make(chan struct{})}
	login, authorizationURL, err := startRuntimeAuthClaudeLogin(context.Background(), command, carrier)
	if err != nil || authorizationURL != "https://claude.com/cai/oauth/authorize?"+query {
		t.Fatalf("start = %q/%v", authorizationURL, err)
	}
	data, err := login.submit(context.Background(), []byte("synthetic-code"))
	login.close()
	if err != nil || parseRuntimeAuthClaudeCredentials(data) != nil {
		t.Fatalf("submit = %q/%v", data, err)
	}
	clear(data)
}

func TestRuntimeAuthClaudeAuthorizationURLRejectsRedirectAndExtraFields(t *testing.T) {
	base := "https://claude.com/cai/oauth/authorize?code=true&client_id=client&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=challenge&code_challenge_method=S256&state=state"
	for _, value := range []string{
		base,
		strings.Replace(base, "claude.com/cai", "evil.example/cai", 1),
		strings.Replace(base, "platform.claude.com", "evil.example", 1),
		base + "&command=run",
	} {
		got, ok := runtimeAuthClaudeAuthorizationURL([]byte(value + "\nPaste code >"))
		if (value == base) != ok || ok && got != base {
			t.Fatalf("url %q accepted=%v result=%q", value, ok, got)
		}
	}
}

func TestRuntimeAuthClaudeAuthorizationCodeCommitsThroughTargetOwner(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", directory)
	command := filepath.Join(t.TempDir(), "claude")
	query := "code=true&client_id=synthetic-client&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=user%3Ainference&code_challenge=synthetic-challenge&code_challenge_method=S256&state=synthetic-state"
	script := `#!/bin/sh
printf '%s\n' 'https://claude.com/cai/oauth/authorize?` + query + `'
IFS= read -r code
[ "$code" = "synthetic-code" ] || exit 4
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '%s' '{"claudeAiOauth":{"accessToken":"synthetic-access","refreshToken":"synthetic-refresh","expiresAt":4102444800000,"scopes":["user:inference"]}}' > "$CLAUDE_CONFIG_DIR/.credentials.json"
`
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	c.runtimeInventory = newRuntimeInventory()
	c.cfg.runtimeAgent = true
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "claude"
	codex := newCodexRuntimeImplementation(c)
	claude := newClaudeRuntimeImplementation(c)
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": codex, "claude": claude}
	carrier := &runtimeTransport{send: func(context.Context, message) error { return nil }, done: make(chan struct{})}
	c.sendMu.Lock()
	c.activeTransport = carrier
	c.sendMu.Unlock()
	t.Cleanup(func() { carrier.close() })
	target := runtimeProbeTarget{provider: "claude", identityMaterial: command}
	generation, epoch := claude.authFence()
	binding := runtimeAuthInputContext{
		ActorID: "admin", TenantID: "tenant", ProjectID: "project", TargetKind: "compute_workload", WorkloadID: "workload",
		Provider: "claude", Backend: "anthropic", Method: "native_login", Form: runtimeAuthClaudeLoginFlow, SchemaVersion: 1,
		RuntimeInstanceID: "runtime", Generation: "1", ConnectionEpoch: "epoch", AllocationID: "allocation", AllocationGeneration: "1",
		NativeGeneration: generation, AuthEpoch: epoch,
	}
	local := &runtimeAuthPrivateTarget{carrier: carrier, claude: claude, authPath: filepath.Join(directory, runtimeAuthClaudeCredentialsName)}
	started, err := codex.auth.startPrivateClaudeLogin(context.Background(), target, binding, local)
	if err != nil {
		t.Fatal(err)
	}
	encoded, _ := json.Marshal(started)
	var offer struct {
		Context   runtimeAuthInputContext `json:"context"`
		PublicKey []byte                  `json:"public_key"`
	}
	if err := json.Unmarshal(encoded, &offer); err != nil {
		t.Fatal(err)
	}
	public, _ := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPublicKey(offer.PublicKey)
	sender, _ := hpke.NewSuite(hpke.KEM_P256_HKDF_SHA256, hpke.KDF_HKDF_SHA256, hpke.AEAD_AES128GCM).NewSender(public, []byte(runtimeAuthInputDomain))
	enc, sealer, _ := sender.Setup(rand.Reader)
	aad, _ := offer.Context.aad()
	ciphertext, _ := sealer.Seal([]byte("synthetic-code"), aad)
	attempt := codex.auth.attempt(target.key())
	current := func() bool { return c.privateRuntimeAuthCurrent(context.Background(), local, offer.Context) }
	outcome := codex.auth.submitPrivateClaudeLogin(context.Background(), target, attempt, offer.Context, runtimeAuthInputEnvelope{EncapsulatedKey: enc, Ciphertext: ciphertext}, claude, local.authPath, current, func(commit func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
		return c.commitRuntimeAuthTransport(context.Background(), carrier, commit)
	})
	if outcome.SaveResult != "committed" || outcome.Issue != "" {
		t.Fatalf("submit = %+v", outcome)
	}
	data, err := os.ReadFile(local.authPath)
	if err != nil || parseRuntimeAuthClaudeCredentials(data) != nil {
		t.Fatalf("committed credentials = %q/%v", data, err)
	}
}

func TestRuntimeAuthClaudeSettingsSaveAndProfile(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", directory)
	path, err := runtimeAuthClaudeLocation()
	if err != nil {
		t.Fatal(err)
	}
	for _, backend := range []string{"anthropic", "openrouter"} {
		t.Run(backend, func(t *testing.T) {
			data, err := runtimeAuthClaudeSettings(backend, "synthetic-key")
			if err != nil {
				t.Fatal(err)
			}
			outcome := saveRuntimeAuthClaude(context.Background(), path, data, backend, func(stage string) runtimeAuthSaveOutcome {
				return commitRuntimeAuthFile(context.Background(), stage, path)
			})
			if outcome.SaveResult != "committed" || outcome.Issue != "" {
				t.Fatalf("save = %+v", outcome)
			}
			profilePath, gotBackend, err := runtimeAuthClaudeProfile()
			if err != nil || profilePath != path || gotBackend != backend {
				t.Fatalf("profile = %q/%q/%v", profilePath, gotBackend, err)
			}
			info, err := os.Stat(path)
			if err != nil || info.Mode().Perm() != 0o600 {
				t.Fatalf("settings mode = %v/%v", info, err)
			}
		})
	}
	previous, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	result := saveRuntimeAuthClaude(context.Background(), path, []byte(`{"env":{"ANTHROPIC_BASE_URL":"https://evil.example","ANTHROPIC_AUTH_TOKEN":"secret","ANTHROPIC_API_KEY":""}}`), "openrouter", func(string) runtimeAuthSaveOutcome {
		t.Fatal("invalid profile reached commit")
		return runtimeAuthSaveOutcome{}
	})
	got, err := os.ReadFile(path)
	if err != nil || result.SaveResult != "not_committed" || result.Issue != "invalid_format" || !bytes.Equal(got, previous) {
		t.Fatalf("invalid save changed profile: result=%+v err=%v", result, err)
	}
}

func TestRuntimeAuthClaudePrivateOwnerCommitsOnceAndRetiresGeneration(t *testing.T) {
	t.Setenv("CLAUDE_CONFIG_DIR", t.TempDir())
	c := newEventTestConnector(t, t.TempDir())
	defer c.externalRuntimeState.close()
	c.runtimeInventory = newRuntimeInventory()
	c.cfg.runtimeAgent = true
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "claude"
	codex := newCodexRuntimeImplementation(c)
	claude := newClaudeRuntimeImplementation(c)
	c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": codex, "claude": claude}
	c.runtimeInventory.commitGuard = codex.commitRuntimeProbe
	m := codex.auth
	target := runtimeProbeTarget{provider: "claude", identityMaterial: "/synthetic/claude"}
	generation, epoch := claude.authFence()
	binding := runtimeAuthInputContext{
		ActorID: "admin", TenantID: "tenant", ProjectID: "project", TargetKind: "compute_workload", WorkloadID: "workload",
		Provider: "claude", Backend: "openrouter", Method: "credential_import", Form: "api_key", SchemaVersion: 1,
		RuntimeInstanceID: "runtime", Generation: "1", ConnectionEpoch: "epoch", AllocationID: "allocation", AllocationGeneration: "1",
		NativeGeneration: generation, AuthEpoch: epoch,
	}
	attempt, err := m.beginPrivateInput(target, binding)
	if err != nil {
		t.Fatal(err)
	}
	expected := attempt.input.context
	public, err := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPublicKey(attempt.input.publicKey)
	if err != nil {
		t.Fatal(err)
	}
	sender, err := hpke.NewSuite(hpke.KEM_P256_HKDF_SHA256, hpke.KDF_HKDF_SHA256, hpke.AEAD_AES128GCM).NewSender(public, []byte(runtimeAuthInputDomain))
	if err != nil {
		t.Fatal(err)
	}
	enc, sealer, err := sender.Setup(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	aad, err := expected.aad()
	if err != nil {
		t.Fatal(err)
	}
	ciphertext, err := sealer.Seal([]byte(`{"key":"synthetic-key"}`), aad)
	if err != nil {
		t.Fatal(err)
	}
	oldGeneration := claude.authGeneration
	oldGeneration.wait.Add(1)
	retired := make(chan struct{})
	go func() {
		<-oldGeneration.stop
		close(retired)
		oldGeneration.wait.Done()
	}()
	path, _ := runtimeAuthClaudeLocation()
	outcome := savePrivateClaude(context.Background(), m, target, expected, runtimeAuthInputEnvelope{EncapsulatedKey: enc, Ciphertext: ciphertext}, claude, path, func() bool { return true }, func(commit func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome { return commit() })
	if outcome.SaveResult != "committed" || outcome.Issue != "" {
		t.Fatalf("save = %+v", outcome)
	}
	select {
	case <-retired:
	case <-time.After(time.Second):
		t.Fatal("old Claude generation was not retired")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := parseRuntimeAuthClaudeBackend(data, "openrouter"); err != nil {
		t.Fatal("committed settings did not contain the fixed OpenRouter profile")
	}
	if next, _ := claude.authFence(); next == generation {
		t.Fatal("committed settings did not advance the native generation")
	}
	if err := os.WriteFile(path, []byte(`{"env":{"ANTHROPIC_API_KEY":"later-native-value"}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	replay := savePrivateClaude(context.Background(), m, target, expected, runtimeAuthInputEnvelope{EncapsulatedKey: enc, Ciphertext: ciphertext}, claude, path, func() bool { return true }, func(commit func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome { return commit() })
	got, err := os.ReadFile(path)
	if err != nil || replay.SaveResult != "committed" || !strings.Contains(string(got), "later-native-value") {
		t.Fatalf("replay repeated mutation: %+v %v", replay, err)
	}
}

func TestRuntimeAuthClaudeVerificationIsBoundedAndToolFree(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("CLAUDE_CONFIG_DIR", directory)
	settings, err := runtimeAuthClaudeSettings("anthropic", "synthetic-key")
	if err != nil {
		t.Fatal(err)
	}
	path, _ := runtimeAuthClaudeLocation()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, settings, 0o600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("ANTHROPIC_API_KEY", "host-api-key")
	t.Setenv("ANTHROPIC_AUTH_TOKEN", "host-auth-token")
	t.Setenv("ANTHROPIC_BASE_URL", "https://host.example")
	logPath := filepath.Join(t.TempDir(), "args.json")
	command := filepath.Join(t.TempDir(), "claude")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" > " + shellQuote(logPath) + "\nprintf '%s\\n' \"$CLAUDE_CODE_MAX_OUTPUT_TOKENS/$CLAUDE_CODE_MAX_RETRIES/$MAX_THINKING_TOKENS\" >> " + shellQuote(logPath) + "\nprintf 'provider-env=%s/%s/%s\\n' \"${ANTHROPIC_API_KEY-unset}\" \"${ANTHROPIC_AUTH_TOKEN-unset}\" \"${ANTHROPIC_BASE_URL-unset}\" >> " + shellQuote(logPath) + "\nprintf '{\"is_error\":false,\"result\":\"OK\"}'\n"
	if err := os.WriteFile(command, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	result := verifyRuntimeAuthClaude(context.Background(), command, "anthropic", "claude-test-model")
	if result.Status != "authenticated" || result.Issue != "" {
		t.Fatalf("verification = %+v", result)
	}
	log, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatal(err)
	}
	text := string(log)
	for _, want := range []string{"--settings\n" + path, "--safe-mode", "--setting-sources\n\n", "--strict-mcp-config", "--tools\n\n", "--no-session-persistence", "--model\nclaude-test-model", "64/0/0", "provider-env=unset/unset/unset"} {
		if !strings.Contains(text, want) {
			t.Fatalf("verification omitted %q:\n%s", want, text)
		}
	}
}

func TestClaudeVerificationIssueClassification(t *testing.T) {
	for input, want := range map[string]string{
		`status 401 authentication_error`: "credentials_rejected",
		`status 403 forbidden`:            "permission_denied",
		`status 429 rate limit`:           "rate_limited",
		`status 402 credit balance`:       "quota_exhausted",
		`model not found`:                 "verification_model_unavailable",
		`connection reset`:                "provider_unavailable",
	} {
		if got := claudeVerificationIssue(input, ""); got != want {
			t.Fatalf("%q = %q, want %q", input, got, want)
		}
	}
}

func TestComputeClaudePrivateSaveAndVerify(t *testing.T) {
	t.Run("openrouter", func(t *testing.T) {
		testComputeClaudePrivateSaveAndVerify(t, "openrouter", "api_key", `{"key":"synthetic-openrouter-key"}`, false)
	})
	t.Run("setup token", func(t *testing.T) {
		testComputeClaudePrivateSaveAndVerify(t, "anthropic", "claude_backend_config", `{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"synthetic-setup-token"}}`, false)
	})
	t.Run("rejected setup token", func(t *testing.T) {
		testComputeClaudePrivateSaveAndVerify(t, "anthropic", "claude_backend_config", `{"env":{"CLAUDE_CODE_OAUTH_TOKEN":"synthetic-rejected-token"}}`, true)
	})
}

func testComputeClaudePrivateSaveAndVerify(t *testing.T, backend, form, material string, reject bool) {
	t.Setenv("HOME", t.TempDir())
	command := fakeClaudeRuntimeCommand(t)
	t.Setenv("PATH", filepath.Dir(command)+string(os.PathListSeparator)+os.Getenv("PATH"))
	c, err := newConnector(config{name: "claude-auth-test", root: t.TempDir(), systemInfoInterval: 0})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(c.closeExternalRuntimes)
	if _, err := c.runtimeInventory.probe(context.Background(), "", "", "connect"); err != nil {
		t.Fatal(err)
	}
	c.cfg.runtimeAgent = true
	c.cfg.computeRuntimeWorkloadID = "workload"
	c.cfg.computeRuntimeInstanceID = "runtime"
	c.cfg.computeRuntimeGeneration = 1
	c.cfg.computeRuntimeEpoch = "epoch"
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "claude"
	c.cfg.computeRuntimeTenantID = "tenant"
	c.cfg.computeRuntimeProjectID = "project"
	off := c.activateRuntimeTransport(runtimeOperationTestAuthority(c))
	t.Cleanup(off)
	session := computeRuntimeSession{instance: "runtime", generation: 1, epoch: "epoch", kind: "external_worker"}
	target := map[string]any{
		"tenant_id": "tenant", "project_id": "project", "workload_id": "workload", "runtime_instance_id": "runtime",
		"generation": 1, "connection_epoch": "epoch", "provider": "claude", "actor_id": "admin",
		"allocation_id": "allocation", "allocation_generation": "1",
	}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	begin := c.computeRuntimeAuthReply(ctx, message{ID: "begin", Method: "runtime_auth_input_begin", Params: map[string]any{
		"target": target, "backend": backend, "form": form,
	}}, session)
	if begin.Type != "response" {
		t.Fatalf("begin failed: %s", begin.Error)
	}
	encoded, _ := json.Marshal(begin.Result)
	var offer struct {
		Context   runtimeAuthInputContext `json:"context"`
		PublicKey []byte                  `json:"public_key"`
	}
	if err := json.Unmarshal(encoded, &offer); err != nil {
		t.Fatal(err)
	}
	if offer.Context.NativeGeneration == "" || offer.Context.AuthEpoch == "" || offer.Context.Provider != "claude" {
		t.Fatalf("incomplete Claude offer: %+v", offer.Context)
	}
	public, err := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPublicKey(offer.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	sender, err := hpke.NewSuite(hpke.KEM_P256_HKDF_SHA256, hpke.KDF_HKDF_SHA256, hpke.AEAD_AES128GCM).NewSender(public, []byte(runtimeAuthInputDomain))
	if err != nil {
		t.Fatal(err)
	}
	enc, sealer, err := sender.Setup(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	aad, _ := offer.Context.aad()
	ciphertext, err := sealer.Seal([]byte(material), aad)
	if err != nil {
		t.Fatal(err)
	}
	envelope, _ := json.Marshal(runtimeAuthInputEnvelope{EncapsulatedKey: enc, Ciphertext: ciphertext})
	saved := c.computeRuntimeAuthReply(ctx, message{ID: "submit", Method: "runtime_auth_input_submit", Params: map[string]any{
		"target": target, "attempt_id": offer.Context.AttemptID, "envelope": string(envelope),
	}}, session)
	saveResult, _ := saved.Result.(map[string]any)
	if saved.Type != "response" || saveResult["save_result"] != "committed" || saveResult["issue"] != "" {
		t.Fatalf("save failed: type=%s error=%s result=%#v", saved.Type, saved.Error, saved.Result)
	}
	status := c.computeRuntimeAuthReply(ctx, message{ID: "status", Method: "runtime_auth_status", Params: map[string]any{"target": target}}, session)
	statusResult, _ := status.Result.(map[string]any)
	if stringParam(mapParam(statusResult, "auth"), "backend") != backend || stringParam(mapParam(statusResult, "auth"), "status") != "configured" {
		t.Fatalf("saved Claude profile was not projected as configured: status=%#v inventory=%#v", status.Result, c.runtimeInventory.snapshot())
	}
	foundVerify := false
	for _, raw := range statusResult["methods"].([]map[string]any) {
		if stringParam(raw, "method") == "verify" && stringParam(raw, "backend") == backend {
			foundVerify = true
		}
	}
	if !foundVerify {
		t.Fatalf("Claude verification was not advertised: %#v", statusResult["methods"])
	}
	if statusResult["dispatch_ready"] != false {
		t.Fatal("unverified credentials admitted dispatch")
	}
	if reject {
		t.Setenv("SALIX_TEST_FAKE_CLAUDE_VERIFY_REJECT", "1")
		rejected := c.computeRuntimeAuthReply(ctx, message{ID: "reject", Method: "runtime_auth_verify", Params: map[string]any{"target": target, "backend": backend}}, session)
		rejection, _ := rejected.Result.(map[string]any)
		if rejected.Type != "response" || rejection["status"] != "unauthenticated" || rejection["issue"] != "credentials_rejected" {
			t.Fatalf("provider rejection = %#v", rejected)
		}
		rejectedStatus := c.computeRuntimeAuthReply(ctx, message{ID: "rejected-status", Method: "runtime_auth_status", Params: map[string]any{"target": target}}, session)
		if result, _ := rejectedStatus.Result.(map[string]any); result["dispatch_ready"] != false {
			t.Fatal("rejected credentials admitted dispatch")
		}
		return
	}
	verified := c.computeRuntimeAuthReply(ctx, message{ID: "verify", Method: "runtime_auth_verify", Params: map[string]any{"target": target, "backend": backend}}, session)
	verification, _ := verified.Result.(map[string]any)
	if verified.Type != "response" || verification["status"] != "authenticated" {
		t.Fatalf("verification failed: type=%s error=%s result=%#v", verified.Type, verified.Error, verified.Result)
	}
	readyStatus := c.computeRuntimeAuthReply(ctx, message{ID: "ready-status", Method: "runtime_auth_status", Params: map[string]any{"target": target}}, session)
	if result, _ := readyStatus.Result.(map[string]any); result["dispatch_ready"] != true {
		t.Fatalf("verified credentials did not admit dispatch: %#v", readyStatus)
	}
	c.runtimeInventory.mu.Lock()
	c.runtimeInventory.runtimes[target["provider"].(string)+"\x00"+command]["version"] = "2.1.259 (Claude Code)"
	c.runtimeInventory.mu.Unlock()
	status = c.computeRuntimeAuthReply(ctx, message{ID: "unsupported-status", Method: "runtime_auth_status", Params: map[string]any{"target": target}}, session)
	statusResult, _ = status.Result.(map[string]any)
	if methods := statusResult["methods"].([]map[string]any); len(methods) != 0 {
		t.Fatalf("unsupported Claude version advertised mutations: %#v", methods)
	}
	unsupported := c.computeRuntimeAuthReply(ctx, message{ID: "unsupported-begin", Method: "runtime_auth_input_begin", Params: map[string]any{
		"target": target, "backend": backend, "form": form,
	}}, session)
	if unsupported.Type != "error" {
		t.Fatalf("unsupported Claude version mutation = type=%s error=%q", unsupported.Type, unsupported.Error)
	}
}
