package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"testing"

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

func TestRuntimeAuthInputJSONSchemaBoundary(t *testing.T) {
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
			return renameForTest(stage, path)
		})
	}()
	<-entered
	revoking, revoked := make(chan struct{}), make(chan struct{})
	go func() { close(revoking); deactivate(); close(revoked) }()
	<-revoking
	// The disconnect waits for the admitted rename, which the test holds.
	waitUntilParked(t, "", "(*connector).activateRuntimeTransport.func")
	select {
	case <-revoked:
		t.Error("disconnect crossed an admitted rename section")
	default:
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
	got := c.commitRuntimeAuthTransport(context.Background(), carrier, func() runtimeAuthSaveOutcome { return renameForTest(stage, path) })
	if got.SaveResult != "not_committed" || got.Issue != "target_changed" {
		t.Fatal("replacement accepted old carrier input")
	}
	if got, err := os.ReadFile(path); err != nil || string(got) != "new" {
		t.Fatal("old carrier replaced native bytes")
	}
}

func renameForTest(stage, path string) runtimeAuthSaveOutcome {
	if os.Rename(stage, path) != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "storage_commit_failed"}
	}
	return runtimeAuthSaveOutcome{SaveResult: "committed"}
}
