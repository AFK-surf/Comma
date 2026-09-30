package main

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/AFK-surf/comma/systems/ops/comma-release/release"
)

// testIdPKEK is a 32-byte key-encryption key for the fake Secret Manager
// entry; the entry carries nothing else — signing key pairs live in the
// shared database table and never flow through the release.
var testIdPKEK = base64.StdEncoding.EncodeToString([]byte("0123456789abcdef0123456789abcdef"))

// testIdPSecretOverride lets a test replace the fake Secret Manager entry.
var testIdPSecretOverride map[string]any

func testIdPSecret() map[string]any {
	if testIdPSecretOverride != nil {
		return testIdPSecretOverride
	}
	return map[string]any{"KEK_BASE64": testIdPKEK}
}

func buildWithIdPSecret(t *testing.T, secret map[string]any) (map[string]string, error) {
	t.Helper()
	testIdPSecretOverride = secret
	defer func() { testIdPSecretOverride = nil }()

	body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging",
		Project:     "project",
		Cluster:     "cluster",
		OauthIdp:    "enabled",
	}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
	if err != nil {
		return nil, err
	}
	var bundle release.CandidateBundle
	if err := json.Unmarshal(body, &bundle); err != nil {
		t.Fatal(err)
	}
	for _, resource := range bundle.Resources {
		if strings.HasPrefix(resource.Name, "comma-secrets-") {
			return resource.Data, nil
		}
	}
	t.Fatal("release bundle omitted comma-secrets")
	return nil, nil
}

type bundleSecretRunner struct {
	posthog       map[string]any
	slackProgress map[string]any
}

type unexpectedBundleKubectlRunner struct{}

func (unexpectedBundleKubectlRunner) Run(_ context.Context, _ []byte, args ...string) ([]byte, error) {
	return nil, fmt.Errorf("unexpected kubectl call: %v", args)
}

type bundleKubectlRunner struct {
	encodedCA []byte
	err       error
	calls     int
}

func (r *bundleKubectlRunner) Run(_ context.Context, _ []byte, args ...string) ([]byte, error) {
	r.calls++
	want := []string{"-n", "comma", "get", "secret", "salix-vmm-gateway-tls", "-o", `jsonpath={.data.ca\.crt}`}
	if !reflect.DeepEqual(args, want) {
		return nil, fmt.Errorf("kubectl args = %v, want %v", args, want)
	}
	if r.err != nil {
		return nil, r.err
	}
	return r.encodedCA, nil
}

func testCACertificate(t *testing.T) []byte {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	template := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: "test Agent VMM CA"},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, template, template, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
}

func bundleConfig(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var bundle release.CandidateBundle
	if err := json.Unmarshal(body, &bundle); err != nil {
		t.Fatal(err)
	}
	for _, resource := range bundle.Resources {
		if strings.HasPrefix(resource.Name, "salix-config-") {
			var config map[string]any
			if err := json.Unmarshal([]byte(resource.Data["config.json"]), &config); err != nil {
				t.Fatal(err)
			}
			return config
		}
	}
	t.Fatal("release bundle omitted salix-config")
	return nil
}

func (r bundleSecretRunner) Run(_ context.Context, _ []byte, args ...string) ([]byte, error) {
	name := args[len(args)-3]
	if name == "salix-s3-staging" {
		return []byte(`{"AWS_ENDPOINT_URL":"https://s3.example","AWS_REGION":"test","BUCKET":"comma","AWS_ACCESS_KEY_ID":"access","AWS_SECRET_ACCESS_KEY":"secret"}`), nil
	}
	if name == "test-redis" {
		return []byte(`{"REDIS_URL":"redis://10.0.0.2:6379/0"}`), nil
	}
	if name == "test-oauth-idp" {
		body, err := json.Marshal(testIdPSecret())
		if err != nil {
			return nil, err
		}
		return body, nil
	}
	if name == "alert-router-staging" {
		secret := map[string]any{
			"DATABASE_URL":                   "ecto://alert_router:secret@127.0.0.1/alert_router",
			"SHADOW_CHANNEL_ID":              "C0ALMF2AD70",
			"GCP_PUSH_AUDIENCE":              "https://salix.example/v1/events/gcp",
			"GCP_PUSH_SERVICE_ACCOUNT_EMAIL": "alert-router-push@example.iam.gserviceaccount.com",
			"GRAFANA_WEBHOOK_SECRET":         "0123456789abcdef0123456789abcdef",
			"GITHUB_WEBHOOK_SECRET":          "abcdef0123456789abcdef0123456789",
			"GCP_PROJECT_STAGING":            "example-staging-project",
			"GCP_PROJECT_PRODUCTION":         "example-production-project",
			"GKE_CLUSTER":                    "example-cluster",
		}
		if r.posthog != nil {
			secret["POSTHOG_WEBHOOK"] = r.posthog
		}
		return json.Marshal(secret)
	}
	if name == "alert-router-slack-staging" {
		secret := map[string]any{"SLACK_BOT_TOKEN": "xoxb-test"}
		for key, value := range r.slackProgress {
			secret[key] = value
		}
		return json.Marshal(secret)
	}
	return []byte(`{"BRIDGE_DATABASE_URL":"ecto://comma:secret@127.0.0.1/comma","BILLING_DATABASE_URL":"ecto://billing:secret@127.0.0.1/billing","INSTANCE_CONNECTION_NAME":"project:region:instance"}`), nil
}

func TestCommaBundleConfigPreservesConfigOwnedGoogleClientIDs(t *testing.T) {
	target := map[string]any{
		"comma": map[string]any{
			"auth": map[string]any{"secret": "otp-secret"},
			"google_auth": map[string]any{
				"web_client_id":          "comma-staging.apps.googleusercontent.com",
				"electron_client_id":     "comma-desktop.apps.googleusercontent.com",
				"issuer":                 "https://accounts.google.com",
				"electron_client_secret": "desktop-provider-compatibility-secret",
			},
		},
	}
	setNested(target, "comma", commaBundleConfig("ecto://comma", "rediss://redis.example.com/0"))
	merged := target["comma"]
	want := map[string]any{
		"database": map[string]any{"url": "ecto://comma"},
		"google_auth": map[string]any{
			"web_client_id":          "comma-staging.apps.googleusercontent.com",
			"electron_client_id":     "comma-desktop.apps.googleusercontent.com",
			"electron_client_secret": "desktop-provider-compatibility-secret",
			"issuer":                 "https://accounts.google.com",
		},
		"auth": map[string]any{
			"secret":    "otp-secret",
			"redis_url": "rediss://redis.example.com/0",
		},
	}
	if !reflect.DeepEqual(merged, want) {
		t.Fatalf("unexpected Comma bundle config: %#v", merged)
	}

}

func TestValidateCommaAuthConfigFailsClosedWithoutEverySecret(t *testing.T) {
	valid := commaAuthConfigForTest(strings.Repeat("a", 32), strings.Repeat("b", 32), "rediss://redis.example.com/0")

	if err := validateCommaAuthConfig(valid); err != nil {
		t.Fatalf("valid Comma auth config rejected: %v", err)
	}

	invalid := map[string]any{
		"email": map[string]any{"postmark_server_token": "postmark-token"},
		"comma": map[string]any{"auth": map[string]any{"secret": "otp-secret"}},
	}
	if err := validateCommaAuthConfig(invalid); err == nil || !strings.Contains(err.Error(), "comma.auth.rate_limit_secret") {
		t.Fatalf("missing rate-limit secret was not rejected clearly: %v", err)
	}
}

func TestValidateCommaAuthConfigRejectsWeakReusedOrMalformedValues(t *testing.T) {
	cases := []struct {
		name            string
		secret          string
		rateLimitSecret string
		redisURL        string
		want            string
	}{
		{name: "weak secret", secret: "too-short", rateLimitSecret: strings.Repeat("b", 32), redisURL: "redis://redis.example.com/0", want: "at least 32 bytes"},
		{name: "reused secret", secret: strings.Repeat("s", 32), rateLimitSecret: strings.Repeat("s", 32), redisURL: "redis://redis.example.com/0", want: "must be different"},
		{name: "wrong scheme", secret: strings.Repeat("a", 32), rateLimitSecret: strings.Repeat("b", 32), redisURL: "https://redis.example.com/0", want: "absolute redis:// or rediss:// URL"},
		{name: "missing host", secret: strings.Repeat("a", 32), rateLimitSecret: strings.Repeat("b", 32), redisURL: "redis:///0", want: "absolute redis:// or rediss:// URL"},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			config := commaAuthConfigForTest(tc.secret, tc.rateLimitSecret, tc.redisURL)
			if err := validateCommaAuthConfig(config); err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("invalid Comma auth config was not rejected clearly: %v", err)
			}
		})
	}
}

func commaAuthConfigForTest(secret, rateLimitSecret, redisURL string) map[string]any {
	return map[string]any{
		"email": map[string]any{"postmark_server_token": "postmark-token"},
		"comma": map[string]any{
			"auth": map[string]any{
				"secret":            secret,
				"rate_limit_secret": rateLimitSecret,
				"redis_url":         redisURL,
			},
			"email": map[string]any{"from": "login@comma.test"},
		},
	}
}

func TestBuildBundleInjectsProductDatabasesIntoReleaseConfig(t *testing.T) {
	setBundleEnvironment(t)
	var input map[string]any
	if err := json.Unmarshal([]byte(os.Getenv("SALIX_CONFIG_JSON")), &input); err != nil {
		t.Fatal(err)
	}
	storageKey := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("k", 32)))
	input["subscription_proxy"] = map[string]any{"storage_key": storageKey}
	encoded, err := json.Marshal(input)
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("SALIX_CONFIG_JSON", string(encoded))
	body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging",
		Project:     "project",
		Cluster:     "cluster",
	}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
	if err != nil {
		t.Fatal(err)
	}

	var bundle release.CandidateBundle
	if err := json.Unmarshal(body, &bundle); err != nil {
		t.Fatal(err)
	}
	var configBody string
	var redisURL string
	for _, resource := range bundle.Resources {
		if strings.HasPrefix(resource.Name, "salix-config-") {
			configBody = resource.Data["config.json"]
		}
		if strings.HasPrefix(resource.Name, "comma-secrets-") {
			redisURL = resource.Data["REDIS_URL"]
		}
	}
	if configBody == "" {
		t.Fatal("release bundle omitted salix-config")
	}
	var config map[string]any
	if err := json.Unmarshal([]byte(configBody), &config); err != nil {
		t.Fatal(err)
	}
	if got := config["subscription_proxy"].(map[string]any)["storage_key"]; got != storageKey {
		t.Fatal("subscription storage key was not preserved in the mounted Salix config")
	}
	want := "ecto://comma:secret@127.0.0.1/comma"
	if got := config["comma"].(map[string]any)["database"].(map[string]any)["url"]; got != want {
		t.Fatalf("comma database URL = %q, want %q", got, want)
	}
	// Salix control metadata shares the BridgeForTeams/Comma physical database;
	// a serving node without this key refuses to boot, so the bundle must
	// always carry it (docs/storage-search.md).
	if got := config["salix"].(map[string]any)["database"].(map[string]any)["url"]; got != want {
		t.Fatalf("salix database URL = %q, want %q", got, want)
	}
	wantBilling := "ecto://billing:secret@127.0.0.1/billing"
	if got := config["billing"].(map[string]any)["database"].(map[string]any)["url"]; got != wantBilling {
		t.Fatalf("billing database URL = %q, want %q", got, wantBilling)
	}
	if got := config["comma"].(map[string]any)["auth"].(map[string]any)["secret"]; got != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
		t.Fatalf("comma auth config was not preserved: %q", got)
	}
	if got := config["comma"].(map[string]any)["auth"].(map[string]any)["redis_url"]; got != "redis://10.0.0.2:6379/0" {
		t.Fatalf("comma auth Redis URL = %q", got)
	}
	if redisURL != "redis://10.0.0.2:6379/0" {
		t.Fatalf("comma REDIS_URL = %q", redisURL)
	}
	if _, ok := bundle.Replacements["COMMA_LEGACY_PRODUCT_REPLICAS"]; ok {
		t.Fatal("bundle retained legacy product replica transition control")
	}
	if _, ok := bundle.Replacements["COMMA_PRODUCT_SERVING_OWNER"]; ok {
		t.Fatal("bundle retained product serving owner transition control")
	}
	if got := bundle.Replacements["COMMA_WEB_COOKIE_ORIGIN"]; got != "https://app-staging.comma.surf" {
		t.Fatalf("COMMA_WEB_COOKIE_ORIGIN = %q", got)
	}
	if got := bundle.Replacements["COMMA_ADMIN_COOKIE_ORIGIN"]; got != "https://admin-staging.comma.surf" {
		t.Fatalf("COMMA_ADMIN_COOKIE_ORIGIN = %q", got)
	}
}

func TestBuildBundleBindsAgentVMMTrustToSelectedCluster(t *testing.T) {
	setBundleEnvironment(t)
	t.Setenv("SALIX_CONFIG_JSON", `{
		"web":{"api_base_url":"https://salix.example","sites_domain":"sites.example"},
		"email":{"postmark_server_token":"postmark-token"},
		"comma":{"auth":{"secret":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rate_limit_secret":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"email":{"from":"login@comma.test"}},
		"bridge_for_teams":{"dashboard":{"public_base_url":"https://teams.example"}},
		"agent_vmm":{"install_material":{"remote_enrollment":{"gateway_endpoint":"gateway.example:7443","trust_bundle":"stale-config-value"}}}
	}`)
	fixture := makeVMMFixture(t)
	ca := fixture.roots["server"]
	// Issuance output reaches the next release's actual enrollment consumer.
	kubectl := &bundleKubectlRunner{encodedCA: []byte(fixture.bundle.Secrets[vmmTLSBundleName].Data["ca.crt"])}

	body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging",
		Project:     "project",
		Cluster:     "cluster",
		Namespace:   "comma",
	}, bundleSecretRunner{}, kubectl)
	if err != nil {
		t.Fatal(err)
	}
	if kubectl.calls != 1 {
		t.Fatalf("kubectl calls = %d, want 1", kubectl.calls)
	}
	config := bundleConfig(t, body)
	got := nestedString(config, "agent_vmm", "install_material", "remote_enrollment", "trust_bundle")
	want := base64.StdEncoding.EncodeToString(ca)
	if got != want {
		t.Fatal("release config did not use the selected cluster gateway CA")
	}
}

func TestBuildBundleRejectsInvalidClusterAgentVMMCA(t *testing.T) {
	setBundleEnvironment(t)
	t.Setenv("SALIX_CONFIG_JSON", `{
		"web":{"api_base_url":"https://salix.example","sites_domain":"sites.example"},
		"email":{"postmark_server_token":"postmark-token"},
		"comma":{"auth":{"secret":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rate_limit_secret":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"email":{"from":"login@comma.test"}},
		"bridge_for_teams":{"dashboard":{"public_base_url":"https://teams.example"}},
		"agent_vmm":{"install_material":{"remote_enrollment":{"gateway_endpoint":"gateway.example:7443"}}}
	}`)
	kubectl := &bundleKubectlRunner{encodedCA: []byte(base64.StdEncoding.EncodeToString([]byte("not a certificate")))}

	_, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging", Project: "project", Cluster: "cluster", Namespace: "comma",
	}, bundleSecretRunner{}, kubectl)
	if err == nil || !strings.Contains(err.Error(), "exactly one PEM certificate") {
		t.Fatalf("buildBundle() error = %v, want invalid gateway CA rejection", err)
	}
}

func TestBuildBundleDropsLegacyNativeTriageReviewConfig(t *testing.T) {
	legacyValues := []struct {
		name  string
		value string
	}{
		{name: "enabled", value: `{"enabled":true}`},
		{name: "namespace", value: `{"namespace":"legacy-triage"}`},
		{name: "engine", value: `{"engine":"review"}`},
		{name: "timing", value: `{"debounce_ms":1,"max_wait_ms":2,"evaluation_timeout_ms":3}`},
		{name: "invalid fields", value: `{"enabled":"yes","namespace":17,"engine":["review"],"debounce_ms":"fast"}`},
		{name: "invalid scalar", value: `"review"`},
		{name: "invalid list", value: `[true,"review"]`},
	}

	for _, tc := range legacyValues {
		t.Run(tc.name, func(t *testing.T) {
			setBundleEnvironment(t)
			t.Setenv("SALIX_CONFIG_JSON", `{
				"web":{"api_base_url":"https://salix.example","sites_domain":"sites.example"},
				"email":{"postmark_server_token":"postmark-token"},
				"comma":{"auth":{"secret":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rate_limit_secret":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"email":{"from":"login@comma.test"}},
				"bridge_for_teams":{"dashboard":{"public_base_url":"https://teams.example"}},
				"im":{"identity_scan_max_concurrency":7,"native_triage_review":`+tc.value+`}
			}`)

			body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
				Environment: "staging",
				Project:     "project",
				Cluster:     "cluster",
			}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
			if err != nil {
				t.Fatal(err)
			}

			var bundle release.CandidateBundle
			if err := json.Unmarshal(body, &bundle); err != nil {
				t.Fatal(err)
			}

			var configBody string
			for _, resource := range bundle.Resources {
				if strings.HasPrefix(resource.Name, "salix-config-") {
					configBody = resource.Data["config.json"]
				}
			}
			if configBody == "" {
				t.Fatal("release bundle removed the salix-config Secret")
			}

			var config map[string]any
			if err := json.Unmarshal([]byte(configBody), &config); err != nil {
				t.Fatal(err)
			}
			im, ok := config["im"].(map[string]any)
			if !ok {
				t.Fatalf("release bundle removed the im config containing sibling keys: %#v", config["im"])
			}
			if _, ok := im["native_triage_review"]; ok {
				t.Fatalf("release bundle retained retired im.native_triage_review: %#v", im)
			}
			if got := im["identity_scan_max_concurrency"]; got != float64(7) {
				t.Fatalf("release bundle changed im.identity_scan_max_concurrency: %#v", got)
			}
		})
	}
}

func TestBuildBundleDropsLegacyNativeTriageReviewFromCombinedReleaseConfig(t *testing.T) {
	setBundleEnvironment(t)
	t.Setenv("SALIX_CONFIG_JSON", `{
		"web":{"api_base_url":"https://salix.example","sites_domain":"sites.example"},
		"email":{"postmark_server_token":"postmark-token"},
		"comma":{"auth":{"secret":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rate_limit_secret":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"email":{"from":"login@comma.test"}},
		"bridge_for_teams":{"dashboard":{"public_base_url":"https://teams.example"}},
		"im":{"identity_scan_max_concurrency":7,"native_triage_review":{"engine":"review"}}
	}`)

	body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging",
		Project:     "project",
		Cluster:     "cluster",
		AlertRouter: release.AlertRouterEnvironmentSpec{Enabled: true, Mode: "disabled"},
	}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
	if err != nil {
		t.Fatal(err)
	}

	var bundle release.CandidateBundle
	if err := json.Unmarshal(body, &bundle); err != nil {
		t.Fatal(err)
	}
	for _, resource := range bundle.Resources {
		if !strings.HasPrefix(resource.Name, "comma-release-config-") {
			continue
		}
		var config map[string]any
		if err := json.Unmarshal([]byte(resource.Data["config.json"]), &config); err != nil {
			t.Fatal(err)
		}
		im := config["im"].(map[string]any)
		if _, ok := im["native_triage_review"]; ok {
			t.Fatalf("combined release config retained retired im.native_triage_review: %#v", im)
		}
		if got := im["identity_scan_max_concurrency"]; got != float64(7) {
			t.Fatalf("combined release config changed im.identity_scan_max_concurrency: %#v", got)
		}
		return
	}
	t.Fatal("release bundle omitted the combined comma-release-config Secret")
}

func TestBuildBundleSelectsAlertRouterAndInjectsDisabledConfig(t *testing.T) {
	setBundleEnvironment(t)
	body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging", Project: "project", Cluster: "cluster",
		AlertRouter: release.AlertRouterEnvironmentSpec{Enabled: true, Mode: "disabled"},
	}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
	if err != nil {
		t.Fatal(err)
	}
	var bundle release.CandidateBundle
	if err = json.Unmarshal(body, &bundle); err != nil {
		t.Fatal(err)
	}
	if got := bundle.Replacements["COMMA_RELEASE_SUBSYSTEMS"]; got != "salix,bridge_for_teams,comma_product,alert_router" {
		t.Fatalf("release subsystems = %q", got)
	}
	if got := bundle.Replacements["COMMA_ALERT_ROUTER_ENABLED"]; got != "true" {
		t.Fatalf("Alert Router enabled replacement = %q", got)
	}
	configs := map[string]map[string]any{}
	for _, resource := range bundle.Resources {
		for _, base := range []string{"salix-config-", "alert-router-config-", "comma-release-config-"} {
			if !strings.HasPrefix(resource.Name, base) {
				continue
			}
			var config map[string]any
			if err = json.Unmarshal([]byte(resource.Data["config.json"]), &config); err != nil {
				t.Fatal(err)
			}
			configs[strings.TrimSuffix(base, "-")] = config
		}
	}
	if _, ok := configs["salix-config"]["alert_router"]; ok {
		t.Fatal("core runtime config leaked Alert Router credentials")
	}
	if len(configs["alert-router-config"]) != 1 {
		t.Fatalf("Alert Router runtime config leaked core sections: %#v", configs["alert-router-config"])
	}
	router := configs["alert-router-config"]["alert_router"].(map[string]any)
	if router["mode"] != "disabled" {
		t.Fatalf("Alert Router mode = %#v", router["mode"])
	}
	if got := router["database"].(map[string]any)["url"]; got != "ecto://alert_router:secret@127.0.0.1/alert_router" {
		t.Fatalf("Alert Router database URL = %q", got)
	}
	if got := router["database"].(map[string]any)["pool_size"]; got != float64(1) {
		t.Fatalf("Alert Router serving pool size = %#v, want 1", got)
	}
	if configs["comma-release-config"]["comma"] == nil || configs["comma-release-config"]["alert_router"] == nil {
		t.Fatalf("ephemeral release config does not contain both subsystem configs: %#v", configs["comma-release-config"])
	}
	if bundle.Replacements["SALIX_CONFIG_SECRET_NAME"] == bundle.Replacements["ALERT_ROUTER_CONFIG_SECRET_NAME"] ||
		bundle.Replacements["SALIX_CONFIG_SECRET_NAME"] == bundle.Replacements["COMMA_RELEASE_CONFIG_SECRET_NAME"] {
		t.Fatal("resident and release config Secret identities were not isolated")
	}
}

func TestBuildBundleRejectsAlertRouterConfigInResidentCoreInput(t *testing.T) {
	setBundleEnvironment(t)
	t.Setenv("SALIX_CONFIG_JSON", `{"email":{"postmark_server_token":"postmark-token"},"comma":{"auth":{"secret":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rate_limit_secret":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"email":{"from":"login@comma.test"}},"alert_router":{"slack":{"bot_token":"must-not-reach-core"}}}`)

	_, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging", Project: "project", Cluster: "cluster",
	}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
	if err == nil || !strings.Contains(err.Error(), "must not set reserved alert_router") {
		t.Fatalf("buildBundle() error = %v, want reserved Alert Router rejection", err)
	}
}

func TestAlertRouterDatabaseIsolationRejectsSharedCoreIdentity(t *testing.T) {
	for _, tc := range []struct {
		name, router, want string
	}{
		{name: "same logical database", router: "ecto://router:other@db.example/comma", want: "distinct logical database"},
		{name: "same credential", router: "postgres://comma:other@db.example/alert_router", want: "distinct database credential"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := validateAlertRouterDatabaseIsolation(tc.router, "ecto://comma:secret@db.example/comma", "ecto://billing:secret@db.example/billing")
			if err == nil || !strings.Contains(err.Error(), tc.want) {
				t.Fatalf("validation error = %v, want %q", err, tc.want)
			}
		})
	}
	if err := validateAlertRouterDatabaseIsolation("ecto://alert_router:secret@db.example/alert_router", "ecto://comma:secret@db.example/comma", "ecto://billing:secret@db.example/billing"); err != nil {
		t.Fatalf("distinct Alert Router database identity rejected: %v", err)
	}
}

func TestAlertRouterShadowConfigPinsXpTest(t *testing.T) {
	secret := map[string]any{
		"DATABASE_URL": "ecto://alert_router:secret@db.example/alert_router", "SLACK_BOT_TOKEN": "xoxb-test",
		"SHADOW_CHANNEL_ID": "C0ALMF2AD70", "GCP_PUSH_AUDIENCE": "https://salix.example/v1/events/gcp",
		"GCP_PUSH_SERVICE_ACCOUNT_EMAIL": "push@example.iam.gserviceaccount.com",
		"GRAFANA_WEBHOOK_SECRET":         strings.Repeat("s", 32),
		"GITHUB_WEBHOOK_SECRET":          strings.Repeat("h", 32),
		"GCP_PROJECT_STAGING":            "example-staging-project",
		"GCP_PROJECT_PRODUCTION":         "example-production-project",
		"GKE_CLUSTER":                    "example-cluster",
		"RUNTIME_LOG":                    map[string]any{"enabled": true, "bucket": "runtime-logs", "storage_access_key_id": "read-only", "unexpected": "not-exported"},
	}
	config, err := alertRouterBundleConfig("shadow", "", secret, "https://salix.example/v1/events/gcp")
	if err != nil {
		t.Fatal(err)
	}
	if got := config["slack"].(map[string]any)["shadow_channel_id"]; got != "C0ALMF2AD70" {
		t.Fatalf("shadow channel = %q", got)
	}
	if got := config["github_webhook"].(map[string]any)["secret"]; got != strings.Repeat("h", 32) {
		t.Fatalf("GitHub webhook secret was not isolated in Router config")
	}
	if source := config["runtime_log"].(map[string]any); source["bucket"] != "runtime-logs" || source["storage_access_key_id"] != "read-only" || source["unexpected"] != nil {
		t.Fatalf("runtime source config was not narrowly projected: %#v", source)
	}
	if got := config["gcp_projects"].(map[string]any); got["staging"] != "example-staging-project" || got["production"] != "example-production-project" || config["gke_cluster"] != "example-cluster" {
		t.Fatalf("live project and cluster identifiers were not delivered: %#v", config)
	}
	secret["SHADOW_CHANNEL_ID"] = "CNOTXPTEST"
	if _, err = alertRouterBundleConfig("shadow", "", secret, "https://salix.example/v1/events/gcp"); err == nil || !strings.Contains(err.Error(), "#xp-test") {
		t.Fatalf("non-xp-test shadow destination was accepted: %v", err)
	}
	secret["SHADOW_CHANNEL_ID"] = "C0ALMF2AD70"
	secret["GCP_PUSH_AUDIENCE"] = "https://wrong.example/v1/events/gcp"
	if _, err = alertRouterBundleConfig("shadow", "", secret, "https://salix.example/v1/events/gcp"); err == nil || !strings.Contains(err.Error(), "GCP push audience") {
		t.Fatalf("wrong GCP audience was accepted: %v", err)
	}
	secret["GCP_PUSH_AUDIENCE"] = "https://salix.example/v1/events/gcp"
	delete(secret, "GKE_CLUSTER")
	if _, err = alertRouterBundleConfig("shadow", "", secret, "https://salix.example/v1/events/gcp"); err == nil || !strings.Contains(err.Error(), "GKE_CLUSTER") {
		t.Fatalf("missing GKE cluster was accepted: %v", err)
	}
	secret["GKE_CLUSTER"] = "example-cluster"
	secret["GITHUB_WEBHOOK_SECRET"] = "too-short"
	if _, err = alertRouterBundleConfig("shadow", "", secret, "https://salix.example/v1/events/gcp"); err == nil || !strings.Contains(err.Error(), "GitHub webhook secret") {
		t.Fatalf("short GitHub webhook secret was accepted: %v", err)
	}
}

func TestBuildBundleInjectsEnvironmentOwnedLiveRouteAndDedicatedBotToken(t *testing.T) {
	setBundleEnvironment(t)
	body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging",
		Project:     "project",
		Cluster:     "cluster",
		AlertRouter: release.AlertRouterEnvironmentSpec{
			Enabled:        true,
			Mode:           "live",
			SlackChannelID: "C0BJ1699HSN",
		},
	}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
	if err != nil {
		t.Fatal(err)
	}

	var bundle release.CandidateBundle
	if err = json.Unmarshal(body, &bundle); err != nil {
		t.Fatal(err)
	}
	for _, resource := range bundle.Resources {
		if !strings.HasPrefix(resource.Name, "alert-router-config-") {
			continue
		}
		var config map[string]any
		if err = json.Unmarshal([]byte(resource.Data["config.json"]), &config); err != nil {
			t.Fatal(err)
		}
		router := config["alert_router"].(map[string]any)
		if router["mode"] != "live" {
			t.Fatalf("Alert Router mode = %#v", router["mode"])
		}
		slack := router["slack"].(map[string]any)
		if slack["bot_token"] != "xoxb-test" || slack["live_channel_id"] != "C0BJ1699HSN" {
			t.Fatalf("live Slack config = %#v", slack)
		}
		return
	}
	t.Fatal("release bundle omitted Alert Router config")
}

func TestBuildBundleProjectsPostHogOnlyIntoRouterConfigs(t *testing.T) {
	want := map[string]any{
		"secret": strings.Repeat("p", 32), "project_id": "597221",
		"origin": "https://us.posthog.com", "environment": "staging",
	}
	for _, mode := range []string{"disabled", "shadow", "live"} {
		for _, tc := range []struct {
			name              string
			source, projected map[string]any
		}{
			{name: "absent"},
			{name: "configured", source: map[string]any{"secret": want["secret"], "project_id": want["project_id"], "origin": want["origin"], "environment": want["environment"], "unexpected": "must-not-export"}, projected: want},
			{name: "malformed", source: map[string]any{"secret": map[string]any{}, "project_id": []any{"597221"}, "origin": false, "environment": 1}, projected: map[string]any{}},
		} {
			t.Run(mode+"/"+tc.name, func(t *testing.T) {
				setBundleEnvironment(t)
				runner := bundleSecretRunner{posthog: tc.source}
				body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
					Environment: "staging", Project: "project", Cluster: "cluster",
					AlertRouter: release.AlertRouterEnvironmentSpec{Enabled: true, Mode: mode, SlackChannelID: "C0BJ1699HSN"},
				}, runner, unexpectedBundleKubectlRunner{})
				if err != nil {
					t.Fatal(err)
				}
				var bundle release.CandidateBundle
				if err := json.Unmarshal(body, &bundle); err != nil {
					t.Fatal(err)
				}
				seen := 0
				for _, resource := range bundle.Resources {
					configBody, ok := resource.Data["config.json"]
					if !ok {
						continue
					}
					var config map[string]any
					if err := json.Unmarshal([]byte(configBody), &config); err != nil {
						t.Fatal(err)
					}
					if strings.HasPrefix(resource.Name, "salix-config-") {
						if config["alert_router"] != nil || strings.Contains(configBody, want["secret"].(string)) {
							t.Fatal("PostHog server configuration reached resident core config")
						}
						continue
					}
					router, ok := config["alert_router"].(map[string]any)
					if !ok {
						continue
					}
					seen++
					if tc.source != nil && mode != "disabled" {
						if !reflect.DeepEqual(router["posthog_webhook"], tc.projected) {
							t.Fatal("release bundle dropped or widened PostHog webhook configuration")
						}
					} else if router["posthog_webhook"] != nil {
						t.Fatal("unconfigured or disabled Router gained a PostHog source")
					}
				}
				if seen != 2 {
					t.Fatalf("got %d Router configs, want dedicated and migration configs", seen)
				}
			})
		}
	}
}

func TestAlertRouterDesiredStateRejectsUnsafeLiveSelection(t *testing.T) {
	for _, spec := range []release.EnvironmentSpec{
		{
			Environment: "production",
			AlertRouter: release.AlertRouterEnvironmentSpec{Enabled: true, Mode: "live", SlackChannelID: "C0BJ1699HSN"},
		},
		{
			Environment: "staging",
			AlertRouter: release.AlertRouterEnvironmentSpec{Enabled: false, Mode: "live", SlackChannelID: "C0BJ1699HSN"},
		},
		{
			Environment: "staging",
			AlertRouter: release.AlertRouterEnvironmentSpec{Enabled: true, Mode: "live", SlackChannelID: "GPRIVATE"},
		},
	} {
		if _, _, _, err := alertRouterDesiredState(spec); err == nil {
			t.Fatalf("unsafe Alert Router desired state was accepted: %#v", spec.AlertRouter)
		}
	}
}

func TestCommaWebCookieOriginMatchesEffectiveRuntimeConfiguration(t *testing.T) {
	for _, tc := range []struct {
		name        string
		config      map[string]any
		environment string
		want        string
		wantErr     string
	}{
		{
			name:        "production default",
			config:      map[string]any{},
			environment: "production",
			want:        "https://app.comma.surf",
		},
		{
			name: "candidate override",
			config: map[string]any{
				"comma": map[string]any{
					"web": map[string]any{
						"web_cookie_origin": "  https://preview.example.test:8443  ",
					},
				},
			},
			environment: "staging",
			want:        "https://preview.example.test:8443",
		},
		{
			name:        "unknown environment requires explicit origin",
			config:      map[string]any{},
			environment: "preview",
			wantErr:     "must set comma.web.web_cookie_origin",
		},
		{
			name: "non-string override",
			config: map[string]any{
				"comma": map[string]any{
					"web": map[string]any{"web_cookie_origin": []any{"https://app.example.test"}},
				},
			},
			environment: "staging",
			wantErr:     "must be one origin string",
		},
		{
			name: "origin with path",
			config: map[string]any{
				"comma": map[string]any{
					"web": map[string]any{"web_cookie_origin": "https://app.example.test/path"},
				},
			},
			environment: "staging",
			wantErr:     "absolute HTTP(S) origin",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := commaWebCookieOrigin(tc.config, tc.environment)
			if tc.wantErr == "" {
				if err != nil || got != tc.want {
					t.Fatalf("commaWebCookieOrigin() = %q, %v; want %q", got, err, tc.want)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("commaWebCookieOrigin() error = %v; want %q", err, tc.wantErr)
			}
		})
	}
}

func TestCommaAdminCookieOriginMatchesEffectiveRuntimeConfiguration(t *testing.T) {
	for _, tc := range []struct {
		name        string
		config      map[string]any
		environment string
		want        string
		wantErr     string
	}{
		{
			name:        "production default",
			config:      map[string]any{},
			environment: "production",
			want:        "https://admin.comma.surf",
		},
		{
			name: "candidate override",
			config: map[string]any{
				"comma": map[string]any{
					"web": map[string]any{
						"admin_cookie_origin": "  https://admin-preview.example.test:8443  ",
					},
				},
			},
			environment: "staging",
			want:        "https://admin-preview.example.test:8443",
		},
		{
			name:        "unknown environment requires explicit origin",
			config:      map[string]any{},
			environment: "preview",
			wantErr:     "must set comma.web.admin_cookie_origin",
		},
		{
			name: "non-string override",
			config: map[string]any{
				"comma": map[string]any{
					"web": map[string]any{
						"admin_cookie_origin": []any{"https://admin.example.test"},
					},
				},
			},
			environment: "staging",
			wantErr:     "must be one origin string",
		},
		{
			name: "origin with path",
			config: map[string]any{
				"comma": map[string]any{
					"web": map[string]any{
						"admin_cookie_origin": "https://admin.example.test/path",
					},
				},
			},
			environment: "staging",
			wantErr:     "absolute HTTP(S) origin",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := commaAdminCookieOrigin(tc.config, tc.environment)
			if tc.wantErr == "" {
				if err != nil || got != tc.want {
					t.Fatalf("commaAdminCookieOrigin() = %q, %v; want %q", got, err, tc.want)
				}
				return
			}
			if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
				t.Fatalf("commaAdminCookieOrigin() error = %v; want %q", err, tc.wantErr)
			}
		})
	}
}

func TestBuildBundleInjectsOauthIdPKEKWhenSpecEnabled(t *testing.T) {
	setBundleEnvironment(t)

	// Sticky-enablement regression: enablement is environment-spec state,
	// so two successive ordinary releases (no special inputs anywhere)
	// both carry the KEK — a later normal release can no longer silently
	// remove it. Decommissioning requires editing the spec file.
	for i := 0; i < 2; i++ {
		commaSecrets, err := buildWithIdPSecret(t, nil)
		if err != nil {
			t.Fatal(err)
		}
		if got := commaSecrets["COMMA_OAUTH_IDP_KEK"]; got != testIdPKEK {
			t.Fatalf("release %d: COMMA_OAUTH_IDP_KEK = %q", i, got)
		}
		// Nothing else IdP-related flows through the release: key pairs
		// live in the shared database table.
		for key := range commaSecrets {
			if strings.HasPrefix(key, "COMMA_OAUTH_IDP_") && key != "COMMA_OAUTH_IDP_KEK" {
				t.Fatalf("release %d: unexpected IdP field %s in comma-secrets", i, key)
			}
		}
	}
}

func TestBuildBundleEnablesSSHWithoutExtraSecrets(t *testing.T) {
	setBundleEnvironment(t)
	spec := release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp", Environment: "staging", Project: "project", Cluster: "cluster", SSHEnabled: true}
	if _, err := buildBundle(context.Background(), spec, bundleSecretRunner{}, unexpectedBundleKubectlRunner{}); err != nil {
		t.Fatal(err)
	}
}

func TestBuildBundleRejectsBadKEK(t *testing.T) {
	setBundleEnvironment(t)

	cases := []struct {
		name   string
		secret map[string]any
		want   string
	}{
		{"missing KEK", map[string]any{}, "KEK_BASE64"},
		{"not base64", map[string]any{"KEK_BASE64": "not-base64!!"}, "32 bytes"},
		{"wrong length", map[string]any{"KEK_BASE64": base64.StdEncoding.EncodeToString([]byte("short"))}, "32 bytes"},
	}
	for _, c := range cases {
		if _, err := buildWithIdPSecret(t, c.secret); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: expected error containing %q, got %v", c.name, c.want, err)
		}
	}
}

func TestBuildBundleOmitsOauthIdPFieldsWhenSpecDisabled(t *testing.T) {
	setBundleEnvironment(t)

	for _, state := range []string{"", "disabled"} {
		body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
			Environment: "staging",
			Project:     "project",
			Cluster:     "cluster",
			OauthIdp:    state,
		}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
		if err != nil {
			t.Fatal(err)
		}

		var bundle release.CandidateBundle
		if err := json.Unmarshal(body, &bundle); err != nil {
			t.Fatal(err)
		}
		for _, resource := range bundle.Resources {
			if strings.HasPrefix(resource.Name, "comma-secrets-") {
				for key := range resource.Data {
					if strings.HasPrefix(key, "COMMA_OAUTH_IDP_") {
						t.Fatalf("disabled bundle leaked %s into comma-secrets", key)
					}
				}
			}
		}
	}
}

func TestBuildBundleRejectsInvalidOauthIdPState(t *testing.T) {
	setBundleEnvironment(t)
	_, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging",
		Project:     "project",
		Cluster:     "cluster",
		OauthIdp:    "true",
	}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
	if err == nil || !strings.Contains(err.Error(), `oauthIdp must be`) {
		t.Fatalf("expected invalid-state error, got %v", err)
	}
}

func TestBuildBundleProjectsSourcedContextExecutorIntent(t *testing.T) {
	for _, enabled := range []bool{true, false} {
		t.Run(strconv.FormatBool(enabled), func(t *testing.T) {
			setBundleEnvironment(t)
			t.Setenv("SALIX_CONFIG_JSON", fmt.Sprintf(`{"web":{"api_base_url":"https://salix.example","sites_domain":"sites.example"},"email":{"postmark_server_token":"postmark-token"},"comma":{"auth":{"secret":"%s","rate_limit_secret":"%s"},"email":{"from":"login@comma.test"}},"bridge_for_teams":{"dashboard":{"public_base_url":"https://teams.example"},"sourced_context":{"background_executor":{"enabled":%t}}}}`, strings.Repeat("a", 32), strings.Repeat("b", 32), enabled))

			body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
				Environment: "staging",
				Project:     "project",
				Cluster:     "cluster",
			}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
			if err != nil {
				t.Fatal(err)
			}

			var bundle release.CandidateBundle
			if err := json.Unmarshal(body, &bundle); err != nil {
				t.Fatal(err)
			}

			var config map[string]any
			for _, resource := range bundle.Resources {
				if strings.HasPrefix(resource.Name, "salix-config-") {
					if err := json.Unmarshal([]byte(resource.Data["config.json"]), &config); err != nil {
						t.Fatal(err)
					}
				}
			}
			if config == nil {
				t.Fatal("release bundle omitted salix-config")
			}

			got := config["bridge_for_teams"].(map[string]any)["sourced_context"].(map[string]any)["background_executor"].(map[string]any)["enabled"]
			if got != enabled {
				t.Fatalf("background executor enabled = %v, want %v", got, enabled)
			}
		})
	}
}

func TestBuildBundleDoesNotOverrideConfigFromRetiredWorkflowVariables(t *testing.T) {
	setBundleEnvironment(t)
	t.Setenv("BFT_CLI_ARTIFACT_BASE_URL", "https://wrong.example/bft-cli")
	t.Setenv("BFT_CLI_RELEASE_ID", "wrong-release")
	t.Setenv("BFT_SOURCED_CONTEXT_EXECUTOR_ENABLED", "true")
	t.Setenv("COMMA_GOOGLE_WEB_CLIENT_ID", "wrong-web-client")
	t.Setenv("COMMA_GOOGLE_ELECTRON_CLIENT_ID", "wrong-electron-client")
	t.Setenv("SALIX_HOST", "wrong-salix.example")
	t.Setenv("SALIX_SITES_DOMAIN", "wrong-sites.example")
	t.Setenv("BRIDGE_HOST", "wrong-teams.example")
	t.Setenv("BRIDGE_PUBLIC_BASE_URL", "https://wrong-teams.example")

	body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging",
		Project:     "project",
		Cluster:     "cluster",
	}, bundleSecretRunner{}, unexpectedBundleKubectlRunner{})
	if err != nil {
		t.Fatal(err)
	}

	config := bundleConfig(t, body)
	bft := config["bridge_for_teams"].(map[string]any)
	if bft["bft_cli"].(map[string]any)["release_id"] != "config-release" {
		t.Fatalf("workflow variable overrode config-owned BFT CLI: %#v", bft["bft_cli"])
	}
	if bft["sourced_context"].(map[string]any)["background_executor"].(map[string]any)["enabled"] != false {
		t.Fatalf("workflow variable overrode config-owned executor intent")
	}
	google := config["comma"].(map[string]any)["google_auth"].(map[string]any)
	if google["web_client_id"] != "config-web-client" || google["electron_client_id"] != "config-electron-client" {
		t.Fatalf("workflow variable overrode config-owned Google clients: %#v", google)
	}
	var bundle release.CandidateBundle
	if err := json.Unmarshal(body, &bundle); err != nil {
		t.Fatal(err)
	}
	wantReplacements := map[string]string{
		"SALIX_HOST":         "salix.example",
		"SALIX_SITES_DOMAIN": "sites.example",
		"BRIDGE_HOST":        "teams.example",
	}
	for name, want := range wantReplacements {
		if got := bundle.Replacements[name]; got != want {
			t.Fatalf("%s = %q, want config-owned %q", name, got, want)
		}
	}
}

func setBundleEnvironment(t *testing.T) {
	t.Helper()
	for name, value := range map[string]string{
		"SALIX_CONFIG_JSON":                  `{"web":{"api_base_url":"https://salix.example","sites_domain":"sites.example"},"email":{"postmark_server_token":"postmark-token"},"comma":{"auth":{"secret":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rate_limit_secret":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"email":{"from":"login@comma.test"},"google_auth":{"web_client_id":"config-web-client","electron_client_id":"config-electron-client","electron_client_secret":"desktop-provider-compatibility-secret"}},"bridge_for_teams":{"dashboard":{"public_base_url":"https://teams.example"},"bft_cli":{"artifact_base_url":"https://config.example/bft-cli","release_id":"config-release"},"sourced_context":{"background_executor":{"enabled":false}}}}`,
		"COMMA_RELEASE_COOKIE":               "cookie",
		"SALIX_CLOUDFLARE_ORIGIN_CERT":       "cert",
		"SALIX_CLOUDFLARE_ORIGIN_KEY":        "key",
		"SALIX_SITES_CLOUDFLARE_ORIGIN_CERT": "cert",
		"SALIX_SITES_CLOUDFLARE_ORIGIN_KEY":  "key",
		"BFT_CLOUDFLARE_ORIGIN_CERT":         "cert",
		"BFT_CLOUDFLARE_ORIGIN_KEY":          "key",
		"COMMA_IMAGE":                        "ghcr.io/afk-surf/comma@sha256:" + strings.Repeat("a", 64),
		"COMMA_CHART_REF":                    "oci://example/chart:version",
		"COMMA_TRACE_SAMPLE_RATIO":           "0.1",
		"COMMA_STATIC_IP":                    "127.0.0.1",
		"COMMA_RELEASE_ID":                   "release-1",
	} {
		t.Setenv(name, value)
	}
}

func TestBuildBundleKeepsSlackProgressCredentialsInRouter(t *testing.T) {
	setBundleEnvironment(t)
	runner := bundleSecretRunner{slackProgress: map[string]any{
		"SLACK_SIGNING_SECRET": "only-router-signing-secret", "SLACK_TEAM_ID": "TTEST", "SLACK_APP_ID": "ATEST", "SLACK_INVESTIGATOR_BOT_ID": "BINVESTIGATOR", "UNRELATED": "must-not-copy",
	}}
	body, err := buildBundle(context.Background(), release.EnvironmentSpec{RedisSecret: "test-redis", OAuthIdpSecret: "test-oauth-idp",
		Environment: "staging", Project: "project", Cluster: "cluster",
		AlertRouter: release.AlertRouterEnvironmentSpec{Enabled: true, Mode: "live", SlackChannelID: "C0BJ1699HSN"},
	}, runner, unexpectedBundleKubectlRunner{})
	if err != nil {
		t.Fatal(err)
	}
	var bundle release.CandidateBundle
	if err := json.Unmarshal(body, &bundle); err != nil {
		t.Fatal(err)
	}
	seen := 0
	for _, resource := range bundle.Resources {
		configBody, ok := resource.Data["config.json"]
		if !ok {
			continue
		}
		var config map[string]any
		if err := json.Unmarshal([]byte(configBody), &config); err != nil {
			t.Fatal(err)
		}
		router, ok := config["alert_router"].(map[string]any)
		if !ok {
			if strings.Contains(configBody, "only-router-signing-secret") {
				t.Fatal("signing secret reached a non-router config")
			}
			continue
		}
		seen++
		slack := router["slack"].(map[string]any)
		if slack["signing_secret"] != "only-router-signing-secret" || slack["team_id"] != "TTEST" || slack["app_id"] != "ATEST" || slack["investigator_bot_id"] != "BINVESTIGATOR" {
			t.Fatal("release bundle omitted progress callback configuration")
		}
		if strings.Contains(configBody, "must-not-copy") {
			t.Fatal("unrelated Slack secret key was copied")
		}
	}
	if seen != 2 {
		t.Fatalf("got %d router configs, want serving and migration", seen)
	}
}
