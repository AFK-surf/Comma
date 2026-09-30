package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"github.com/cloudflare/circl/hpke"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func subscriptionFixture(revision int64) map[string]any {
	return map[string]any{"credential_kind": "subscription_oauth", "subscription_account_id": "pool-account", "chatgpt_account_id": "workspace-account",
		"access_token": "synthetic-access", "expires_at": time.Now().Add(time.Hour).Unix(), "credential_revision": "credentials-1", "delivery_revision": revision, "bound": true}
}

func TestSubscriptionRestoresNativeProcessAndRefreshesWithoutFiles(t *testing.T) {
	for _, compute := range []bool{false, true} {
		t.Run(fmtBool(compute), func(t *testing.T) { subscriptionRestoration(t, compute) })
	}
}

func fmtBool(value bool) string {
	if value {
		return "compute"
	}
	return "device"
}

func subscriptionRestoration(t *testing.T, compute bool) {
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
	if compute {
		configureSubscriptionCompute(c)
	}
	var revoked atomic.Bool
	var revision atomic.Int64
	var refreshes atomic.Int64
	off := activateRuntimeTransportForTest(c, func(request message) error {
		if request.Method != "runtime_subscription_access" {
			return nil
		}
		result := subscriptionFixture(revision.Add(1))
		if stringParam(request.Params, "rejected_revision") != "" {
			refreshes.Add(1)
		}
		if refreshes.Load() > 0 {
			result["access_token"] = "rotated-access"
			result["credential_revision"] = "credentials-2"
		}
		if revoked.Load() {
			result = map[string]any{"revoked": true, "subscription_account_id": "pool-account", "delivery_revision": revision.Load()}
		}
		if compute {
			result = sealComputeSubscriptionTest(t, c, request, result)
		}
		c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: result})
		return nil
	})
	defer off()
	m := c.runtimeAuthCoordinator()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	native, err := m.codex.ensureTargetRuntime(context.Background(), target)
	if err != nil {
		t.Fatal(err)
	}
	if err = native.ensureTaskInitialized(context.Background()); err != nil {
		t.Fatal(err)
	}
	firstGeneration := native.generation
	// Repeat delivery must not re-login a busy process with unchanged credentials.
	if err = native.ensureSubscription(context.Background()); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(logPath)
	if strings.Count(string(data), "account/login/start\n") != 1 {
		t.Fatalf("expected one native login after repeated admission, got %d", strings.Count(string(data), "account/login/start\n"))
	}
	native.handleCodexMessage(map[string]any{"id": "subscription-refresh-test", "method": "account/chatgptAuthTokens/refresh", "params": map[string]any{"reason": "unauthorized", "previousAccountId": "workspace-account"}})
	deadline := time.Now().Add(3 * time.Second)
	for {
		data, _ = os.ReadFile(logPath)
		if strings.Contains(string(data), "subscription-refresh-accepted") {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("native refresh response did not complete")
		}
		time.Sleep(10 * time.Millisecond)
	}
	if refreshes.Load() != 1 {
		t.Fatal("refresh did not use central authority")
	}
	m.codex.retireUnusableRuntimeGeneration(native)
	native, err = m.codex.ensureTargetRuntime(context.Background(), target)
	if err != nil {
		t.Fatal(err)
	}
	if native.generation == firstGeneration {
		t.Fatal("process was not replaced")
	}
	if err = native.ensureTaskInitialized(context.Background()); err != nil {
		t.Fatal(err)
	}
	if compute {
		revoked.Store(true)
		targetMap := map[string]any{"tenant_id": "tenant", "project_id": "project", "workload_id": "workload", "runtime_instance_id": "runtime", "generation": 1, "connection_epoch": "epoch", "provider": "codex"}
		req := message{ID: "sync", Method: "runtime_subscription_sync", Params: map[string]any{"target": targetMap}}
		session := computeRuntimeSession{instance: "runtime", epoch: "stale", generation: 1, kind: "external_worker"}
		before := revision.Load()
		if reply := c.computeRuntimeAuthReply(context.Background(), req, session); reply.Type != "error" || revision.Load() != before {
			t.Fatal("stale carrier acquired credentials")
		}
		session.epoch = "epoch"
		reply := c.computeRuntimeAuthReply(context.Background(), req, session)
		if reply.Type != "response" || mapParam(map[string]any{"reply": reply.Result}, "reply")["revoked"] != true {
			t.Fatalf("revocation not acknowledged: %+v", reply)
		}
		if native.subscriptionCurrent() {
			t.Fatal("revoked native remains admitted")
		}
	}
	if _, err = os.Stat(filepath.Join(os.Getenv("HOME"), ".codex", "auth.json")); !os.IsNotExist(err) {
		t.Fatal("access material persisted")
	}
}

func TestSubscriptionReplacesProcessAccountWithoutRestartAndFencesStaleDelivery(t *testing.T) {
	for _, accountType := range []string{"none", "chatgpt"} {
		t.Run(accountType, func(t *testing.T) {
			c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": accountType})
			session := newConnectionSession(c, context.Background(), func(context.Context, message) error { return nil }, func(error) {})
			defer session.cancel()
			c.connectionMu.Lock()
			c.activeConnection = session
			c.connectorRunID = "test-run"
			c.connectionGeneration = 1
			c.connectionMu.Unlock()
			params := subscriptionFixture(2)
			delete(params, "bound")
			params["provider"] = "codex"
			params["identity_material"] = command
			params["connector_run_id"] = "test-run"
			params["connection_generation"] = int64(1)
			_, err := c.methodRuntimeAuthSubscription(context.Background(), session, params)
			if err != nil {
				t.Fatal(err)
			}
			native := c.runtimeAuthCoordinator().codex.runtimes[command]
			// The same admission count protects actual in-flight native work.
			leave := c.runtimeAuthCoordinator().enterNativeCall(runtimeProbeTarget{provider: "codex", identityMaterial: command})
			defer leave()
			params["delivery_revision"] = int64(3)
			params["credential_revision"] = "credentials-2"
			params["access_token"] = "rotated-access"
			if _, err = c.methodRuntimeAuthSubscription(context.Background(), session, params); err != nil {
				t.Fatal(err)
			}
			if !native.isRunning() {
				t.Fatal("rotation killed active work")
			}
			logData, _ := os.ReadFile(logPath)
			if !strings.Contains(string(logData), "subscription-rotated-login") {
				t.Fatal("new access token did not reach native login")
			}

			params["delivery_revision"] = int64(2)
			if _, err = c.methodRuntimeAuthSubscription(context.Background(), session, params); err == nil {
				t.Fatal("stale push accepted")
			}
			params["delivery_revision"] = int64(4)
			params["subscription_account_id"] = "another-account"
			params["chatgpt_account_id"] = "another-workspace"
			if _, err = c.methodRuntimeAuthSubscription(context.Background(), session, params); err != nil {
				t.Fatal(err)
			}
			if !native.isRunning() || c.runtimeAuthCoordinator().codex.runtimes[command] != native || native.subscriptionAccountID != "another-account" {
				t.Fatal("account switch must update the same running app-server")
			}
			params["delivery_revision"] = int64(5)
			params["revoked"] = true
			params["require_idle"] = true
			if _, err = c.methodRuntimeAuthSubscription(context.Background(), session, params); err == nil || err.Error() != "runtime_busy" {
				t.Fatalf("idle-only wire revoke must defer active work: %v", err)
			}
			delete(params, "require_idle")
			if _, err = c.methodRuntimeAuthSubscription(context.Background(), session, params); err != nil {
				t.Fatal(err)
			}
			if native.subscriptionCurrent() {
				t.Fatal("revocation acknowledged while native generation still admitted")
			}
			select {
			case <-native.exited:
			case <-time.After(3 * time.Second):
				t.Fatal("revoked native process did not exit")
			}
			params["revoked"] = false
			params["delivery_revision"] = int64(3)
			if _, err = c.methodRuntimeAuthSubscription(context.Background(), session, params); err == nil {
				t.Fatal("old delivery resurrected revoked authentication")
			}
		})
	}
}

func configureSubscriptionCompute(c *connector) {
	c.cfg.computeRuntimeURL = "https://unused.invalid"
	c.cfg.computeRuntimeBootstrapToken = "bootstrap"
	c.cfg.computeRuntimeTenantID = "tenant"
	c.cfg.computeRuntimeProjectID = "project"
	c.cfg.computeRuntimeWorkloadID = "workload"
	c.cfg.computeRuntimeInstanceID = "runtime"
	c.cfg.computeRuntimeEpoch = "epoch"
	c.cfg.computeRuntimeGeneration = 1
	c.cfg.computeRuntimeKind = "external_worker"
	c.cfg.computeRuntimeProvider = "codex"
}

func sealComputeSubscriptionTest(t *testing.T, c *connector, request message, access map[string]any) map[string]any {
	t.Helper()
	var publicBytes []byte
	switch value := request.Params["public_key"].(type) {
	case []byte:
		publicBytes = value
	case string:
		publicBytes, _ = base64.StdEncoding.DecodeString(value)
	}
	public, err := hpke.KEM_P256_HKDF_SHA256.Scheme().UnmarshalBinaryPublicKey(publicBytes)
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
	fields := []string{"comma.subscription.v1", c.cfg.computeRuntimeTenantID, c.cfg.computeRuntimeProjectID, c.cfg.computeRuntimeWorkloadID, c.cfg.computeRuntimeInstanceID, strconv.Itoa(c.cfg.computeRuntimeGeneration), c.cfg.computeRuntimeEpoch, c.cfg.computeRuntimeProvider, stringParam(request.Params, "nonce")}
	var aad []byte
	for _, value := range fields {
		aad = binary.BigEndian.AppendUint32(aad, uint32(len(value)))
		aad = append(aad, []byte(value)...)
	}
	raw, _ := json.Marshal(access)
	ciphertext, err := sealer.Seal(raw, aad)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]any{"enc": enc, "ciphertext": ciphertext}
}

func TestSubscriptionComputeRejectsSwappedEnvelope(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
	configureSubscriptionCompute(c)
	off := activateRuntimeTransportForTest(c, func(request message) error {
		// Same recipient key, wrong request context: another workload cannot install it.
		request.Params["nonce"] = strings.Repeat("f", 32)
		c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: sealComputeSubscriptionTest(t, c, request, subscriptionFixture(1))})
		return nil
	})
	defer off()
	if _, err := c.subscriptionAccess(context.Background(), c.getActiveTransport(), command, ""); err == nil {
		t.Fatal("accepted ciphertext for another request")
	}
}

func TestSubscriptionComputeUsesSealedAccessAfterBootstrapErasure(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
	configureSubscriptionCompute(c)
	c.cfg.computeRuntimeBootstrapToken = ""

	requested := false
	off := activateRuntimeTransportForTest(c, func(request message) error {
		requested = true
		if request.Method != "runtime_subscription_access" {
			t.Fatalf("method = %q", request.Method)
		}
		if _, ok := request.Params["identity_material"]; ok {
			t.Fatal("post-handshake Compute access used the legacy identity payload")
		}
		if stringParam(request.Params, "nonce") == "" || request.Params["public_key"] == nil {
			t.Fatalf("sealed Compute offer = %#v", request.Params)
		}
		c.completeRuntimeProxy(message{
			ID: request.ID, Type: "response",
			Result: sealComputeSubscriptionTest(t, c, request, subscriptionFixture(1)),
		})
		return nil
	})
	defer off()

	if _, err := c.subscriptionAccess(context.Background(), c.getActiveTransport(), command, ""); err != nil {
		t.Fatal(err)
	}
	if !requested {
		t.Fatal("subscription access was not requested")
	}
}

func TestSubscriptionUnboundComputePreservesNativeLogin(t *testing.T) {
	c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "chatgpt"})
	configureSubscriptionCompute(c)
	off := activateRuntimeTransportForTest(c, func(request message) error {
		c.completeRuntimeProxy(message{ID: request.ID, Type: "response", Result: map[string]any{"bound": false}})
		return nil
	})
	defer off()
	native, err := c.runtimeAuthCoordinator().codex.ensureTargetRuntime(context.Background(), runtimeProbeTarget{provider: "codex", identityMaterial: command})
	if err != nil {
		t.Fatal(err)
	}
	if err = native.ensureTaskInitialized(context.Background()); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(logPath)
	if strings.Contains(string(data), "account/login/start") {
		t.Fatal("unbound Compute replaced native login")
	}
}

func TestSubscriptionComputeRevocationFencesDelayedSyncAcrossNativeRestart(t *testing.T) {
	for _, callback := range []bool{false, true} {
		t.Run(map[bool]string{false: "admission", true: "native_refresh"}[callback], func(t *testing.T) {
			c, command, logPath := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
			configureSubscriptionCompute(c)
			delayed := make(chan message, 1)
			var revision atomic.Int64
			off := activateRuntimeTransportForTest(c, func(request message) error {
				if request.Method != "runtime_subscription_access" {
					return nil
				}
				n := revision.Add(1)
				access := subscriptionFixture(n)
				if n == 3 {
					access = map[string]any{"revoked": true, "subscription_account_id": "pool-account", "delivery_revision": n}
				}
				reply := message{ID: request.ID, Type: "response", Result: sealComputeSubscriptionTest(t, c, request, access)}
				if n == 2 {
					delayed <- reply
				} else {
					c.completeRuntimeProxy(reply)
				}
				return nil
			})
			defer off()
			m := c.runtimeAuthCoordinator()
			native, err := m.codex.ensureTargetRuntime(context.Background(), runtimeProbeTarget{provider: "codex", identityMaterial: command})
			if err != nil {
				t.Fatal(err)
			}
			if err = native.ensureTaskInitialized(context.Background()); err != nil {
				t.Fatal(err)
			}
			target := map[string]any{"tenant_id": "tenant", "project_id": "project", "workload_id": "workload", "runtime_instance_id": "runtime", "generation": 1, "connection_epoch": "epoch", "provider": "codex"}
			req := message{ID: "delayed-sync", Method: "runtime_subscription_sync", Params: map[string]any{"target": target}}
			session := computeRuntimeSession{instance: "runtime", epoch: "epoch", generation: 1, kind: "external_worker"}
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			done := make(chan message, 1)
			go func() { done <- c.computeRuntimeAuthReply(ctx, req, session) }()
			var old message
			select {
			case old = <-delayed:
			case <-ctx.Done():
				t.Fatal("background sync did not request access")
			}
			if callback {
				native.handleCodexMessage(map[string]any{"id": "revocation-refresh", "method": "account/chatgptAuthTokens/refresh", "params": map[string]any{"reason": "unauthorized", "previousAccountId": "workspace-account"}})
			} else if err = native.ensureSubscription(ctx); err == nil {
				t.Fatal("revoked task was admitted")
			}
			select {
			case <-native.exited:
			case <-ctx.Done():
				t.Fatal("revoked native did not exit")
			}
			c.completeRuntimeProxy(old)
			select {
			case reply := <-done:
				if reply.Type != "error" {
					t.Errorf("delayed credentials were accepted after revocation: %+v", reply)
				}
			case <-ctx.Done():
				t.Fatal("delayed sync did not settle")
			}
			data, err := os.ReadFile(logPath)
			if err != nil {
				t.Fatal(err)
			}
			starts := 0
			for _, line := range strings.Split(string(data), "\n") {
				if line == "start" {
					starts++
				}
			}
			if strings.Count(string(data), "account/login/start\n") != 1 || starts != 1 {
				t.Fatalf("stale sync started or authenticated another native process: %s", data)
			}
		})
	}
}

func TestSubscriptionIdleRevocationDefersActiveWork(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
	m := c.runtimeAuthCoordinator()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	current := func() bool { return true }
	if _, err := c.applySubscriptionDelivery(context.Background(), target, subscriptionFixture(1), current); err != nil {
		t.Fatal(err)
	}
	native := m.codex.runtimes[command]
	leave := m.enterNativeCall(target)
	revoke := map[string]any{"revoked": true, "require_idle": true, "subscription_account_id": "pool-account", "delivery_revision": int64(2)}
	if _, err := c.applySubscriptionDelivery(context.Background(), target, revoke, current); err == nil || err.Error() != "runtime_busy" {
		t.Fatalf("active rotation = %v", err)
	}
	if !native.subscriptionCurrent() || !native.isRunning() {
		t.Fatal("deferred rotation retired active work")
	}
	leave()
	record := testRecoveryObligationRecord("codex", canonicalStopSessionID(t), "quota-dispatch", "quota-execution")
	record.Command = command
	if err := c.externalRuntimeState.watch(record); err != nil {
		t.Fatal(err)
	}
	if _, err := c.applySubscriptionDelivery(context.Background(), target, revoke, current); err == nil || err.Error() != "runtime_busy" {
		t.Fatalf("durable recovery obligation was not fenced: %v", err)
	}
	settleWatchedExecution(t, c, record)
	if _, err := c.applySubscriptionDelivery(context.Background(), target, revoke, current); err != nil {
		t.Fatal(err)
	}
	if native.subscriptionCurrent() {
		t.Fatal("idle revocation left old generation admitted")
	}
	replacement := subscriptionFixture(3)
	replacement["subscription_account_id"] = "replacement-account"
	replacement["chatgpt_account_id"] = "replacement-workspace"
	if _, err := c.applySubscriptionDelivery(context.Background(), target, replacement, current); err != nil {
		t.Fatal(err)
	}
	if m.codex.runtimes[command].subscriptionAccountID != "replacement-account" {
		t.Fatal("replacement was not bound")
	}
	if _, err := c.applySubscriptionDelivery(context.Background(), target, revoke, current); err == nil {
		t.Fatal("stale revoke accepted after replacement")
	}
}
