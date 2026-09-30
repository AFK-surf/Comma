package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"github.com/cloudflare/circl/hpke"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

func TestRuntimeAuthCodexFileCommitBoundary(t *testing.T) {
	for _, scenario := range []string{"save", "cancel", "keyring", "managed", "invalid"} {
		t.Run(scenario, func(t *testing.T) {
			directory := t.TempDir()
			path := filepath.Join(directory, "auth.json")
			previous := []byte(`{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-old"}`)
			if err := os.WriteFile(path, previous, 0600); err != nil {
				t.Fatal(err)
			}
			data := syntheticRuntimeAuthCodexFile(t)
			config := map[string]any{"cli_auth_credentials_store": "file"}
			if scenario == "keyring" {
				config["cli_auth_credentials_store"] = "keyring"
			}
			if scenario == "managed" {
				config["forced_chatgpt_workspace_id"] = "restricted"
			}
			if scenario == "invalid" {
				data = []byte(`{"hooks":{}}`)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			commits := 0
			result := saveRuntimeAuthCodex(ctx, path, data, config, func(stage string) runtimeAuthSaveOutcome {
				commits++
				info, err := os.Stat(stage)
				if err != nil || info.Mode().Perm() != 0600 || filepath.Dir(stage) != directory {
					t.Fatal("native stage has incorrect permissions or destination")
				}
				if scenario == "cancel" {
					cancel()
				}
				return commitRuntimeAuthFile(ctx, stage, path)
			})
			got, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if scenario == "save" {
				if result.SaveResult != "committed" || !bytes.Equal(got, data) || commits != 1 {
					t.Fatal("native file import did not preserve exact input bytes")
				}
			} else if result.SaveResult != "not_committed" || !bytes.Equal(got, previous) {
				t.Fatal("rejected native import changed the previous file")
			}
			if scenario != "save" && scenario != "cancel" && commits != 0 {
				t.Fatal("policy/format rejection reached native commit")
			}
			entries, err := os.ReadDir(directory)
			if err != nil || len(entries) != 1 || entries[0].Name() != "auth.json" {
				t.Fatal("native import left secret staging residue")
			}
		})
	}
}

func TestRuntimeAuthCodexOwnedWriterExitsBeforeCommit(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
	i := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	native, err := i.ensureTargetRuntime(ctx, target)
	if err != nil {
		t.Fatal(err)
	}
	unlock := i.auth.lockTarget(target.key())
	committed := false
	result := i.commitOwnedCodexAuthFileLocked(ctx, target, native, func() runtimeAuthSaveOutcome {
		select {
		case <-native.exited:
		default:
			t.Error("native writer was still alive at file replacement")
			return runtimeAuthSaveOutcome{SaveResult: "not_committed"}
		}
		committed = true
		return runtimeAuthSaveOutcome{SaveResult: "committed"}
	})
	unlock()
	if !committed || result.SaveResult != "committed" {
		t.Fatalf("native writer could not be quiesced: %+v", result)
	}
	select {
	case <-native.done:
	case <-ctx.Done():
		t.Fatal("native cleanup deadlocked with the auth target section")
	}
	replacement, err := i.ensureTargetRuntime(ctx, target)
	if err != nil || replacement == native || !replacement.isRunning() {
		t.Fatal("native process did not lazily restart after the file commit")
	}
}

func TestRuntimeAuthCodexUnconfirmedStopPreservesFile(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
	i := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	native, err := i.ensureTargetRuntime(context.Background(), target)
	if err != nil {
		t.Fatal(err)
	}
	// Inject a stop request with no process exit. The real child stays alive;
	// an unconfirmed shutdown cannot authorize replacing its credential file.
	native.stopOnce.Do(func() {})
	t.Cleanup(func() { killProcessGroup(native.cmd) })
	path := filepath.Join(t.TempDir(), "auth.json")
	previous := []byte(`{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-old"}`)
	if err := os.WriteFile(path, previous, 0600); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	unlock := i.auth.lockTarget(target.key())
	result := saveRuntimeAuthCodex(ctx, path, syntheticRuntimeAuthCodexFile(t), map[string]any{"cli_auth_credentials_store": "file"}, func(stage string) runtimeAuthSaveOutcome {
		return i.commitOwnedCodexAuthFileLocked(ctx, target, native, func() runtimeAuthSaveOutcome {
			return commitRuntimeAuthFile(ctx, stage, path)
		})
	})
	unlock()
	got, err := os.ReadFile(path)
	if err != nil || result.SaveResult != "not_committed" || !bytes.Equal(got, previous) || !native.isRunning() {
		t.Fatal("unconfirmed native shutdown did not preserve the old credential file")
	}
}

func syntheticRuntimeAuthCodexFile(t *testing.T) []byte {
	t.Helper()
	segment := func(value string) string { return base64.RawURLEncoding.EncodeToString([]byte(value)) }
	id := segment(`{"alg":"none"}`) + "." + segment(`{"email":"synthetic@example.test","https://api.openai.com/auth":{"chatgpt_account_id":"synthetic-account","chatgpt_plan_type":"plus"}}`) + ".synthetic"
	data, err := json.Marshal(map[string]any{
		"auth_mode": "chatgpt", "OPENAI_API_KEY": nil,
		"tokens":       map[string]any{"id_token": id, "access_token": "synthetic-access", "refresh_token": "synthetic-refresh", "account_id": "synthetic-account"},
		"last_refresh": time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func TestRuntimeAuthCodexFileSchemaAndPolicy(t *testing.T) {
	for _, data := range [][]byte{syntheticRuntimeAuthCodexFile(t), []byte(`{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-key"}`)} {
		file, err := parseRuntimeAuthCodexFile(data)
		if err != nil {
			t.Fatal("supported native file rejected")
		}
		if issue := runtimeAuthCodexImportPolicy(map[string]any{"cli_auth_credentials_store": "file"}, file); issue != "" {
			t.Fatal(issue)
		}
		for _, config := range []map[string]any{
			{"cli_auth_credentials_store": "keyring"},
			{"cli_auth_credentials_store": "auto"},
			{},
			{"cli_auth_credentials_store": "file", "forced_chatgpt_workspace_id": "restricted"},
			{"cli_auth_credentials_store": "file", "forced_login_method": true},
			{"cli_auth_credentials_store": "file", "forced_login_method": "unknown"},
		} {
			if runtimeAuthCodexImportPolicy(config, file) == "" {
				t.Fatal("unsupported native policy allowed import")
			}
		}
		for _, forced := range []string{"api", "chatgpt"} {
			allowed := (forced == "api" && file.mode == "apikey") || (forced == "chatgpt" && file.mode == "chatgpt")
			issue := runtimeAuthCodexImportPolicy(map[string]any{"cli_auth_credentials_store": "file", "forced_login_method": forced}, file)
			if (issue == "") != allowed {
				t.Fatal("forced native login policy was not enforced")
			}
		}
	}
	for _, input := range []string{
		`{"auth_mode":"apikey","OPENAI_API_KEY":"first","OPENAI_API_KEY":"second"}`,
		`{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic","hooks":{}}`,
		`{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic","tokens":{}}`,
		`{"auth_mode":"chatgpt","tokens":{}}`,
		`{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic\nkey"}`,
		`{"auth_mode":"chatgptAuthTokens","access_token":"synthetic"}`,
	} {
		if _, err := parseRuntimeAuthCodexFile([]byte(input)); err == nil {
			t.Fatal("unsupported native file accepted")
		}
	}
}

// Run against the packaged binary with entirely synthetic credentials and an
// isolated native home. This checks native serialization/consumption, not remote
// provider authentication; account/read deliberately does not refresh a token.
func TestRuntimeAuthCodexNativeFileCompatibility(t *testing.T) {
	binary := os.Getenv("COMMA_CODEX_TEST_BINARY")
	if binary == "" {
		t.Skip("set COMMA_CODEX_TEST_BINARY to the packaged Codex 0.153.0 binary")
	}
	for _, mode := range []string{"apikey", "chatgpt"} {
		t.Run(mode, func(t *testing.T) {
			directory := t.TempDir()
			environment := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + directory, "CODEX_HOME=" + directory, "TMPDIR=" + directory}
			if err := os.WriteFile(filepath.Join(directory, "config.toml"), []byte("cli_auth_credentials_store = \"file\"\ncheck_for_update_on_startup = false\n"), 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			path := filepath.Join(directory, "auth.json")
			if mode == "apikey" {
				cmd := commandContextWithProcessGroup(ctx, binary, "login", "--with-api-key")
				cmd.Dir, cmd.Env, cmd.Stdin = directory, environment, strings.NewReader("synthetic-comma-native-test-key")
				cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
				if cmd.Run() != nil {
					t.Fatal("native synthetic API login failed")
				}
			} else if err := os.WriteFile(path, syntheticRuntimeAuthCodexFile(t), 0600); err != nil {
				t.Fatal(err)
			}
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			file, err := parseRuntimeAuthCodexFile(data)
			if err != nil || file.mode != mode {
				t.Fatal("adapter disagrees with the native file format")
			}
			cmd := commandContextWithProcessGroup(ctx, binary, "app-server")
			cmd.Dir, cmd.Env, cmd.Stderr = directory, environment, io.Discard
			stdin, err := cmd.StdinPipe()
			if err != nil {
				t.Fatal(err)
			}
			stdout, err := cmd.StdoutPipe()
			if err != nil || cmd.Start() != nil {
				t.Fatal("native app-server could not start")
			}
			defer func() { cancel(); cmd.Wait() }()
			encoder := json.NewEncoder(stdin)
			decoder := json.NewDecoder(io.LimitReader(stdout, 1<<20))
			rpc := func(id int, method string, params map[string]any) map[string]any {
				if encoder.Encode(map[string]any{"id": id, "method": method, "params": params}) != nil {
					t.Fatal("native request failed")
				}
				for {
					var reply map[string]any
					if decoder.Decode(&reply) != nil {
						t.Fatal("native response failed")
					}
					if reply["id"] == float64(id) {
						if reply["error"] != nil {
							t.Fatal("native request rejected")
						}
						return mapParam(reply, "result")
					}
				}
			}
			rpc(1, "initialize", map[string]any{"clientInfo": map[string]any{"name": "comma_auth_test", "version": "1"}})
			if encoder.Encode(map[string]any{"method": "initialized", "params": map[string]any{}}) != nil {
				t.Fatal("native initialize failed")
			}
			account := mapParam(rpc(2, "account/read", map[string]any{"refreshToken": false}), "account")
			expected := "chatgpt"
			if mode == "apikey" {
				expected = "apiKey"
			}
			if stringParam(account, "type") != expected {
				t.Fatal("native reader rejected the imported file")
			}
		})
	}
}

func TestRuntimeAuthCodexAPIKeyPreparationPreservesTarget(t *testing.T) {
	binary := os.Getenv("COMMA_CODEX_TEST_BINARY")
	if binary == "" {
		t.Skip("set COMMA_CODEX_TEST_BINARY to the packaged Codex 0.153.0 binary")
	}
	directory := t.TempDir()
	path := filepath.Join(directory, "auth.json")
	previous := []byte(`{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-old"}`)
	if os.WriteFile(path, previous, 0600) != nil {
		t.Fatal("write fixture")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	data, err := prepareRuntimeAuthCodexAPIKey(ctx, binary, path, "synthetic-new-api-key")
	if err != nil {
		t.Fatal("native API preparation failed")
	}
	defer clear(data)
	var native map[string]any
	if json.Unmarshal(data, &native) != nil || native["OPENAI_API_KEY"] != "synthetic-new-api-key" {
		t.Fatal("native login did not consume stdin key")
	}
	got, _ := os.ReadFile(path)
	if !bytes.Equal(got, previous) {
		t.Fatal("preparation changed target before owner commit")
	}
	entries, err := os.ReadDir(directory)
	if err != nil || len(entries) != 1 || entries[0].Name() != "auth.json" {
		t.Fatal("native preparation left credentials or logs")
	}
}

func TestRuntimeAuthPrivateCodexCommitAndRevocation(t *testing.T) {
	for _, scenario := range []string{"commit", "carrier_revoked", "observation_advanced", "wrong_backend", "connected"} {
		t.Run(scenario, func(t *testing.T) {
			c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
			i := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
			c.cfg.runtimeAgent = true
			c.cfg.computeRuntimeURL = "https://synthetic.invalid"
			// The live carrier erases bootstrap credentials after its first handshake.
			c.cfg.computeRuntimeBootstrapToken = ""
			c.cfg.computeRuntimeWorkloadID = "workload"
			c.cfg.computeRuntimeInstanceID = "instance"
			c.cfg.computeRuntimeEpoch = "epoch"
			c.cfg.computeRuntimeKind = "external_worker"
			c.cfg.computeRuntimeProvider = "codex"
			c.cfg.computeRuntimeTenantID = "tenant"
			c.cfg.computeRuntimeProjectID = "project"
			c.cfg.computeRuntimeGeneration = 1
			target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			native, err := i.ensureTargetRuntime(ctx, target)
			if err != nil {
				t.Fatal(err)
			}
			binding := runtimeAuthInputContext{ActorID: "admin", TargetKind: "compute_workload", Provider: "codex", Backend: "chatgpt", Method: "credential_import", Form: "codex_auth_file", SchemaVersion: 1, NativeGeneration: native.generation, AuthEpoch: strconv.FormatUint(native.authEpoch, 10)}
			if scenario == "connected" {
				binding.TargetKind = "connected_runtime"
			}
			if scenario == "wrong_backend" {
				binding.Backend = "openai"
			}
			attempt, err := i.auth.beginPrivateInput(target, binding)
			if scenario == "connected" {
				if err == nil {
					t.Fatal("connected target advertised unmanaged file replacement")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			defer func() {
				unlock := i.auth.lockTarget(target.key())
				defer unlock()
				i.auth.removeAttemptIfCurrent(target.key(), attempt)
			}()
			expected := attempt.input.context
			public, err := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPublicKey(attempt.input.publicKey)
			if err != nil {
				t.Fatal(err)
			}
			suite := hpke.NewSuite(hpke.KEM_P256_HKDF_SHA256, hpke.KDF_HKDF_SHA256, hpke.AEAD_AES128GCM)
			sender, err := suite.NewSender(public, []byte(runtimeAuthInputDomain))
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
			data := syntheticRuntimeAuthCodexFile(t)
			ciphertext, err := sealer.Seal(data, aad)
			if err != nil {
				t.Fatal(err)
			}
			envelope := runtimeAuthInputEnvelope{EncapsulatedKey: enc, Ciphertext: ciphertext}
			path := filepath.Join(t.TempDir(), "auth.json")
			previous := []byte(`{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-old"}`)
			if err := os.WriteFile(path, previous, 0600); err != nil {
				t.Fatal(err)
			}
			if scenario == "observation_advanced" {
				if !i.auth.publishSnapshotForRuntime(target, native, map[string]any{
					"schema_version": 1,
					"status":         "authenticated",
					"observed_at":    time.Now().UnixMilli(),
				}) {
					t.Fatal("could not publish intervening auth observation")
				}
			}
			deactivate := c.activateRuntimeTransport(func(context.Context, message) error { return nil })
			defer deactivate()
			carrier := c.getActiveTransport()
			carrierCalls := 0
			withCarrier := func(commit func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
				carrierCalls++
				select {
				case <-native.exited:
				default:
					t.Fatal("carrier commit reached before writer exit")
				}
				if scenario == "carrier_revoked" {
					deactivate()
				}
				return c.commitRuntimeAuthTransport(ctx, carrier, commit)
			}
			config := map[string]any{"cli_auth_credentials_store": "file"}
			result := i.auth.savePrivateCodex(ctx, target, expected, envelope, native, path, config, func() bool { return true }, withCarrier)
			got, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if scenario != "commit" && scenario != "observation_advanced" {
				if result.SaveResult != "not_committed" || !bytes.Equal(got, previous) {
					t.Fatal("rejected input replaced native credentials")
				}
				return
			}
			if result.SaveResult != "committed" || !bytes.Equal(got, data) || carrierCalls != 1 {
				t.Fatal("private import failed")
			}
			if err := os.WriteFile(path, previous, 0600); err != nil {
				t.Fatal(err)
			}
			replay := i.auth.savePrivateCodex(ctx, target, expected, envelope, native, path, config, func() bool { return true }, withCarrier)
			got, err = os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if replay.SaveResult != "committed" || !bytes.Equal(got, previous) || carrierCalls != 1 {
				t.Fatal("replay repeated native mutation")
			}
		})
	}
}
