package main

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"os"
	"strconv"
	"strings"
	"testing"

	"github.com/cloudflare/circl/hpke"
)

func subscriptionFixture(revision int64) map[string]any {
	return map[string]any{"credential_kind": "subscription_oauth", "subscription_account_id": "pool-account", "chatgpt_account_id": "workspace-account",
		"access_token": "synthetic-access", "expires_at": testFarFuture.Unix(), "credential_revision": "credentials-1", "delivery_revision": revision, "bound": true}
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
			params["delivery_revision"] = int64(3)
			params["credential_revision"] = "credentials-2"
			params["access_token"] = "rotated-access"
			if _, err = c.methodRuntimeAuthSubscription(context.Background(), session, params); err != nil {
				t.Fatal(err)
			}
			if !native.isRunning() {
				t.Fatal("rotation restarted the native process")
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
			if _, err = c.methodRuntimeAuthSubscription(context.Background(), session, params); err != nil {
				t.Fatal(err)
			}
			if native.subscriptionCurrent() {
				t.Fatal("revocation acknowledged while native generation still admitted")
			}
			<-native.exited
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

func TestSubscriptionRevocationRetiresGenerationAndFencesStaleRevoke(t *testing.T) {
	c, command, _ := newRuntimeAuthTestConnector(t, map[string]string{"SALIX_TEST_FAKE_CODEX_ACCOUNT_TYPE": "none"})
	m := c.runtimeAuthCoordinator()
	target := runtimeProbeTarget{provider: "codex", identityMaterial: command}
	current := func() bool { return true }
	if _, err := c.applySubscriptionDelivery(context.Background(), target, subscriptionFixture(1), current); err != nil {
		t.Fatal(err)
	}
	native := m.codex.runtimes[command]
	revoke := map[string]any{"revoked": true, "require_idle": true, "subscription_account_id": "pool-account", "delivery_revision": int64(2)}
	if _, err := c.applySubscriptionDelivery(context.Background(), target, revoke, current); err != nil {
		t.Fatal(err)
	}
	if native.subscriptionCurrent() {
		t.Fatal("revocation left old generation admitted")
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
