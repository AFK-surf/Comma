package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/cloudflare/circl/hpke"
)

func TestRuntimeAuthInputBrowserInteroperability(t *testing.T) {
	// Generated with @hpke/core 1.9.0 using synthetic test keys and plaintext.
	// This fixture exercises the browser/Go boundary, not two copies of CIRCL.
	data, err := os.ReadFile("testdata/runtime-auth/hpke-js.json")
	if err != nil {
		t.Fatal(err)
	}
	var fixture struct {
		Private, Enc, Ciphertext, AAD, Plaintext []byte
		Context                                  runtimeAuthInputContext
	}
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	aad, err := fixture.Context.aad()
	if err != nil || !bytes.Equal(aad, fixture.AAD) {
		t.Fatal("browser and target context encoding differ")
	}
	private, err := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPrivateKey(fixture.Private)
	if err != nil {
		t.Fatal(err)
	}
	key := &runtimeAuthInputKey{private: private}
	envelope := runtimeAuthInputEnvelope{EncapsulatedKey: fixture.Enc, Ciphertext: fixture.Ciphertext}
	plain, err := key.open(envelope, fixture.AAD)
	if err != nil || !bytes.Equal(plain, fixture.Plaintext) {
		t.Fatalf("browser envelope did not open: %v", err)
	}
	tests := []struct {
		name     string
		envelope runtimeAuthInputEnvelope
		context  []byte
	}{
		{"wrong target context", envelope, []byte("another target")},
		{"missing context", envelope, nil},
		{"missing encapsulation", runtimeAuthInputEnvelope{Ciphertext: fixture.Ciphertext}, fixture.AAD},
		{"oversize plaintext", runtimeAuthInputEnvelope{EncapsulatedKey: fixture.Enc, Ciphertext: make([]byte, runtimeAuthPlaintextLimit+17)}, fixture.AAD},
	}
	tampered := bytes.Clone(fixture.Ciphertext)
	tampered[len(tampered)-1] ^= 1
	tests = append(tests, struct {
		name     string
		envelope runtimeAuthInputEnvelope
		context  []byte
	}{"tampered tag", runtimeAuthInputEnvelope{EncapsulatedKey: fixture.Enc, Ciphertext: tampered}, fixture.AAD})
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if plain, err := key.open(tt.envelope, tt.context); !errors.Is(err, errRuntimeAuthInputInvalid) || plain != nil {
				t.Fatal("invalid input returned plaintext or non-opaque error")
			}
		})
	}
	other, _, err := newRuntimeAuthInputKey()
	if err != nil {
		t.Fatal(err)
	}
	if _, err := other.open(envelope, fixture.AAD); !errors.Is(err, errRuntimeAuthInputInvalid) {
		t.Fatal("another attempt key accepted ciphertext")
	}
	key.destroy()
	if _, err := key.open(envelope, fixture.AAD); !errors.Is(err, errRuntimeAuthInputInvalid) {
		t.Fatal("destroyed key accepted ciphertext")
	}
}

func TestRuntimeAuthInputWireBoundaries(t *testing.T) {
	valid := runtimeAuthInputEnvelope{EncapsulatedKey: make([]byte, 65), Ciphertext: make([]byte, runtimeAuthPlaintextLimit+16)}
	encoded, err := json.Marshal(valid)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := decodeRuntimeAuthInput(encoded); err != nil {
		t.Fatal("maximum plaintext envelope was rejected")
	}
	for name, data := range map[string][]byte{
		"wire size":      make([]byte, runtimeAuthEnvelopeLimit+1),
		"unknown field":  []byte(`{"enc":"", "ciphertext":"", "secret":"must not be echoed"}`),
		"invalid base64": []byte(`{"enc":"!", "ciphertext":"!"}`),
		"trailing value": append(bytes.Clone(encoded), []byte(` {}`)...),
		"null":           []byte(`null`),
		"duplicate key":  append([]byte(`{"enc":"",`), encoded[1:]...),
		"case alias":     bytes.Replace(encoded, []byte(`"enc"`), []byte(`"Enc"`), 1),
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := decodeRuntimeAuthInput(data); !errors.Is(err, errRuntimeAuthInputInvalid) {
				t.Fatal("malformed wire did not return opaque error")
			}
		})
	}
}

func TestRuntimeAuthInputJSONSchemaBoundary(t *testing.T) {
	for name, input := range map[string]string{
		"duplicate credential": `{"type":"api_key","key":"first","key":"second"}`,
		"escaped duplicate":    `{"type":"api_key","key":"first","\u006bey":"second"}`,
		"duplicate type":       `{"type":"oauth","type":"api_key","key":"synthetic"}`,
		"case alias":           `{"type":"api_key","Key":"synthetic"}`,
		"other backend":        `{"openrouter":{"type":"api_key","key":"synthetic"}}`,
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseRuntimeAuthPiEntry([]byte(input)); !errors.Is(err, errRuntimeAuthInputInvalid) {
				t.Fatal("ambiguous or non-selected credential input was accepted")
			}
		})
	}
	for _, depth := range []int{15, 16, 17} {
		// The root object counts as one level, followed by depth-1 arrays.
		input := `{"value":` + strings.Repeat("[", depth-1) + `0` + strings.Repeat("]", depth-1) + `}`
		_, err := runtimeAuthJSONObject([]byte(input), "value")
		if (err == nil) != (depth <= 16) {
			t.Fatalf("depth %d: accepted=%v", depth, err == nil)
		}
	}
	if _, err := runtimeAuthJSONObject([]byte(`{"value":{"x":1,"x":2}}`), "value"); !errors.Is(err, errRuntimeAuthInputInvalid) {
		t.Fatal("nested duplicate accepted")
	}
}

func TestRuntimeAuthTargetLocksRetireAfterOperations(t *testing.T) {
	manager := newRuntimeAuthCoordinator(nil)
	var group sync.WaitGroup
	var active atomic.Int32
	for range 16 {
		group.Add(1)
		go func() {
			defer group.Done()
			for range 50 {
				unlock := manager.lockTarget("same-target")
				if active.Add(1) != 1 {
					t.Error("two mutations own the same target")
				}
				runtime.Gosched()
				active.Add(-1)
				unlock()
			}
		}()
	}
	group.Wait()
	manager.mu.Lock()
	defer manager.mu.Unlock()
	if len(manager.locks) != 0 {
		t.Fatal("completed targets retained lock entries")
	}
}

func TestRuntimeAuthPrivateOwnerPiReplayAndFencing(t *testing.T) {
	sdk := os.Getenv("COMMA_PI_TEST_SDK")
	if sdk == "" {
		t.Skip("set COMMA_PI_TEST_SDK to run the packaged Pi SDK integration")
	}
	node, err := exec.LookPath("node")
	if err != nil {
		t.Fatal(err)
	}
	for _, scenario := range []string{"commit_and_replay", "cancel", "stale_context", "stale_generation", "generation_changes_during_prepare", "native_call_busy", "execution_busy"} {
		t.Run(scenario, func(t *testing.T) {
			c := newEventTestConnector(t, t.TempDir())
			defer c.externalRuntimeState.close()
			c.runtimeInventory = newRuntimeInventory()
			implementation := newCodexRuntimeImplementation(c)
			c.runtimeImplementations = map[string]externalRuntimeImplementation{"codex": implementation}
			c.runtimeInventory.commitGuard = implementation.commitRuntimeProbe
			c.cfg.runtimeAgent = true
			c.cfg.computeRuntimeKind = "external_worker"
			c.cfg.computeRuntimeProvider = "pi"
			m := implementation.auth
			target := runtimeProbeTarget{provider: "pi", identityMaterial: "synthetic-runtime"}
			if scenario == "native_call_busy" {
				leave := m.enterNativeCall(target)
				defer leave()
			}
			if scenario == "execution_busy" {
				record := testRecoveryObligationRecord("pi", "busy-session", "busy-dispatch", "busy-execution")
				record.Command = target.identityMaterial
				if err := c.externalRuntimeState.watch(record); err != nil {
					t.Fatal(err)
				}
			}
			binding := runtimeAuthInputContext{ActorID: "admin", TenantID: "tenant", ProjectID: "project", TargetKind: "compute_workload", WorkloadID: "workload", Provider: "pi", Backend: "openrouter", Method: "credential_import", Form: "pi_auth_entry", SchemaVersion: 1, ConnectionEpoch: "epoch"}
			attempt, err := m.beginPrivateInput(target, binding)
			if err != nil {
				t.Fatal(err)
			}
			defer func() {
				unlock := m.lockTarget(target.key())
				defer unlock()
				m.removeAttemptIfCurrent(target.key(), attempt)
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
			ciphertext, err := sealer.Seal([]byte(`{"type":"api_key","key":"synthetic-new-key"}`), aad)
			if err != nil {
				t.Fatal(err)
			}
			envelope := runtimeAuthInputEnvelope{EncapsulatedKey: enc, Ciphertext: ciphertext}
			path := filepath.Join(t.TempDir(), "auth.json")
			previous := []byte(`{"other":{"type":"api_key","key":"synthetic-retained"}}`)
			if err := os.WriteFile(path, previous, 0600); err != nil {
				t.Fatal(err)
			}
			if scenario == "cancel" {
				m.cancelPrivateInput(target, attempt.attemptID, func() bool { return true })
			}
			if scenario == "stale_context" {
				expected.ActorID = "other-admin"
			}
			checks := 0
			current := func() bool {
				checks++
				return scenario != "stale_generation" && (scenario != "generation_changes_during_prepare" || checks == 1)
			}
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			result := m.savePrivatePi(ctx, target, expected, envelope, node, sdk, path, current)
			got, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if scenario != "commit_and_replay" {
				if result.SaveResult != "not_committed" || !bytes.Equal(got, previous) {
					t.Fatalf("rejected input changed native state: %+v", result)
				}
				if (scenario == "native_call_busy" || scenario == "execution_busy") && result.Issue != "runtime_busy" {
					t.Fatal("active native work was not reported as busy")
				}
				return
			}
			if result.SaveResult != "committed" || result.Issue != "" {
				t.Fatalf("save failed: %+v", result)
			}
			// A subsequent external native write must survive a duplicate old envelope.
			if err := os.WriteFile(path, previous, 0600); err != nil {
				t.Fatal(err)
			}
			replay := m.savePrivatePi(ctx, target, expected, envelope, node, sdk, path, current)
			got, err = os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			if replay.SaveResult != "committed" || !bytes.Equal(got, previous) {
				t.Fatalf("replay repeated a native mutation: %+v", replay)
			}
			canceled := m.cancelPrivateInput(target, attempt.attemptID, func() bool { return true })
			if canceled.SaveResult != "committed" {
				t.Fatal("cancel concealed committed outcome")
			}
			if attempt.input.key.private != nil {
				t.Fatal("terminal attempt retained decryption key")
			}
		})
	}
}

func TestRuntimeAuthTransportCommitSerializesDisconnect(t *testing.T) {
	c := &connector{}
	deactivate := c.activateRuntimeTransport(func(context.Context, message) error { return nil })
	defer deactivate()
	carrier := c.getActiveTransport()
	dir := t.TempDir()
	path, stage := filepath.Join(dir, "auth.json"), filepath.Join(dir, ".staged")
	if err := os.WriteFile(path, []byte("old"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(stage, []byte("new"), 0600); err != nil {
		t.Fatal(err)
	}
	entered, release := make(chan struct{}), make(chan struct{})
	defer func() {
		select {
		case <-release:
		default:
			close(release)
		}
	}()
	result := make(chan runtimeAuthSaveOutcome, 1)
	go func() {
		result <- c.commitRuntimeAuthTransport(context.Background(), carrier, func() runtimeAuthSaveOutcome {
			close(entered)
			<-release
			return commitRuntimeAuthFile(context.Background(), stage, path)
		})
	}()
	<-entered
	revoking, revoked := make(chan struct{}), make(chan struct{})
	go func() { close(revoking); deactivate(); close(revoked) }()
	<-revoking
	select {
	case <-revoked:
		t.Error("disconnect crossed an admitted rename section")
	case <-time.After(50 * time.Millisecond):
	}
	close(release)
	if got := <-result; got.SaveResult != "committed" {
		t.Fatal("admitted rename failed")
	}
	<-revoked
	if got, err := os.ReadFile(path); err != nil || string(got) != "new" {
		t.Fatal("committed bytes missing")
	}
	if err := os.WriteFile(stage, []byte("stale"), 0600); err != nil {
		t.Fatal(err)
	}
	replacementOff := c.activateRuntimeTransport(func(context.Context, message) error { return nil })
	defer replacementOff()
	got := c.commitRuntimeAuthTransport(context.Background(), carrier, func() runtimeAuthSaveOutcome { return commitRuntimeAuthFile(context.Background(), stage, path) })
	if got.SaveResult != "not_committed" || got.Issue != "target_changed" {
		t.Fatal("replacement accepted old carrier input")
	}
	if got, err := os.ReadFile(path); err != nil || string(got) != "new" {
		t.Fatal("old carrier replaced native bytes")
	}
}

func TestComputePrivateRuntimeAuthRPC(t *testing.T) {
	for _, scenario := range []string{"commit", "cancel", "other_admin_cancel", "replaced_carrier", "changed_actor", "changed_lease", "duplicate_envelope"} {
		t.Run(scenario, func(t *testing.T) {
			c, _, _ := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
			c.cfg.runtimeAgent = true
			c.cfg.computeRuntimeWorkloadID = "workload"
			c.cfg.computeRuntimeInstanceID = "runtime"
			c.cfg.computeRuntimeGeneration = 1
			c.cfg.computeRuntimeEpoch = "epoch"
			c.cfg.computeRuntimeKind = "external_worker"
			c.cfg.computeRuntimeProvider = "codex"
			c.cfg.computeRuntimeTenantID = "tenant"
			c.cfg.computeRuntimeProjectID = "project"
			off := c.activateRuntimeTransport(runtimeOperationTestAuthority(c))
			defer off()
			session := computeRuntimeSession{instance: "runtime", generation: 1, epoch: "epoch", kind: "external_worker"}
			target := map[string]any{"tenant_id": "tenant", "project_id": "project", "workload_id": "workload", "runtime_instance_id": "runtime", "generation": 1, "connection_epoch": "epoch", "provider": "codex", "actor_id": "admin", "allocation_id": "allocation", "allocation_generation": "1"}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			begin := c.computeRuntimeAuthReply(ctx, message{ID: "begin", Method: "runtime_auth_input_begin", Params: map[string]any{"target": target, "backend": "chatgpt", "form": "codex_auth_file"}}, session)
			if begin.Type != "response" {
				t.Fatalf("begin failed: %s", begin.Error)
			}
			encoded, err := json.Marshal(begin.Result)
			if err != nil {
				t.Fatal(err)
			}
			var offered struct {
				Context   runtimeAuthInputContext `json:"context"`
				PublicKey []byte                  `json:"public_key"`
			}
			if err := json.Unmarshal(encoded, &offered); err != nil {
				t.Fatal(err)
			}
			if offered.Context.ActorID != "admin" || offered.Context.AllocationGeneration != "1" || offered.Context.NativeGeneration == "" {
				t.Fatal("incomplete exact-target input offer")
			}
			for _, actor := range []string{"admin", "other-admin"} {
				target["actor_id"] = actor
				status := c.computeRuntimeAuthReply(ctx, message{ID: "status", Method: "runtime_auth_status", Params: map[string]any{"target": target}}, session)
				value, _ := status.Result.(map[string]any)
				attempt := mapParam(value, "attempt")
				if status.Type != "response" || attempt["owned"] != (actor == "admin") || attempt["phase"] != "awaiting_user" || attempt["attempt_id"] != offered.Context.AttemptID {
					t.Fatal("status did not preserve bounded owner projection")
				}
				if len(attempt) != 6 || len(value) != 6 {
					t.Fatal("status leaked private input context or ceremony")
				}
			}
			target["actor_id"] = "admin"
			public, err := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPublicKey(offered.PublicKey)
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
			aad, err := offered.Context.aad()
			if err != nil {
				t.Fatal(err)
			}
			data := syntheticRuntimeAuthCodexFile(t)
			ciphertext, err := sealer.Seal(data, aad)
			if err != nil {
				t.Fatal(err)
			}
			envelope, err := json.Marshal(runtimeAuthInputEnvelope{EncapsulatedKey: enc, Ciphertext: ciphertext})
			if err != nil {
				t.Fatal(err)
			}
			path := filepath.Join(filepath.Dir(codexConfigPath()), "auth.json")
			if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
				t.Fatal(err)
			}
			previous := []byte(`{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic-old"}`)
			if err := os.WriteFile(path, previous, 0600); err != nil {
				t.Fatal(err)
			}
			params := map[string]any{"target": target, "attempt_id": offered.Context.AttemptID, "envelope": string(envelope)}
			if scenario == "other_admin_cancel" {
				target["actor_id"] = "other-admin"
			}
			if scenario == "cancel" || scenario == "other_admin_cancel" {
				reply := c.computeRuntimeAuthReply(ctx, message{ID: "cancel", Method: "runtime_auth_input_cancel", Params: map[string]any{"target": target, "attempt_id": offered.Context.AttemptID}}, session)
				if reply.Type != "response" {
					t.Fatalf("cancel failed: %#v", reply)
				}
				target["actor_id"] = "admin"
			}
			if scenario == "replaced_carrier" {
				off()
				nextOff := c.activateRuntimeTransport(runtimeOperationTestAuthority(c))
				defer nextOff()
				status := c.computeRuntimeAuthReply(ctx, message{ID: "status-after-reconnect", Method: "runtime_auth_status", Params: map[string]any{"target": target}}, session)
				statusResult, _ := status.Result.(map[string]any)
				if status.Type != "response" || statusResult["attempt"] != nil {
					t.Fatalf("reconnected carrier retained old attempt: %#v", status)
				}
				restarted := c.computeRuntimeAuthReply(ctx, message{ID: "begin-after-reconnect", Method: "runtime_auth_input_begin", Params: map[string]any{"target": target, "backend": "chatgpt", "form": "codex_auth_file"}}, session)
				if restarted.Type != "response" {
					t.Fatalf("reconnected carrier could not start a new attempt: %#v", restarted)
				}
			}
			if scenario == "changed_actor" {
				target["actor_id"] = "other"
			}
			if scenario == "changed_lease" {
				target["allocation_generation"] = "2"
			}
			if scenario == "duplicate_envelope" {
				params["envelope"] = `{"enc":"",` + string(envelope[1:])
			}
			reply := c.computeRuntimeAuthReply(ctx, message{ID: "submit", Method: "runtime_auth_input_submit", Params: params}, session)
			got, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			result, _ := reply.Result.(map[string]any)
			if scenario == "commit" {
				if reply.Type != "response" || result["save_result"] != "committed" || !bytes.Equal(got, data) {
					t.Fatalf("private RPC did not commit exact native bytes: reply=%#v result=%#v", reply, result)
				}
			} else if result["save_result"] == "committed" || !bytes.Equal(got, previous) {
				t.Fatal("rejected private RPC changed native credentials")
			}
		})
	}
}
