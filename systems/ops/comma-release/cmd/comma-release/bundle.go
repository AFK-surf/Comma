package main

import (
	"context"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"errors"
	"fmt"
	"net/url"
	"os"
	"strconv"
	"strings"

	"github.com/AFK-surf/comma/systems/ops/comma-release/release"
)

func buildBundle(ctx context.Context, spec release.EnvironmentSpec, gcloud, kubectl release.Runner) ([]byte, error) {
	if err := validateEnvironment(); err != nil {
		return nil, err
	}
	suffix := "staging"
	if spec.Environment == "production" {
		suffix = "prod"
	}
	s3, err := readSecretJSON(ctx, gcloud, spec.Project, "salix-s3-"+suffix)
	if err != nil {
		return nil, err
	}
	db, err := readSecretJSON(ctx, gcloud, spec.Project, "bridge-for-teams-db-"+suffix)
	if err != nil {
		return nil, err
	}
	redis, err := readSecretJSON(ctx, gcloud, spec.Project, spec.RedisSecret)
	if err != nil {
		return nil, err
	}
	if err = requireFields(s3, "AWS_ENDPOINT_URL", "AWS_REGION", "BUCKET", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY"); err != nil {
		return nil, err
	}
	if err = requireFields(db, "BRIDGE_DATABASE_URL", "BILLING_DATABASE_URL", "INSTANCE_CONNECTION_NAME"); err != nil {
		return nil, err
	}
	if err = requireFields(redis, "REDIS_URL"); err != nil {
		return nil, err
	}
	// IdP provisioning state is environment-owned (spec.OauthIdp), not a
	// per-dispatch workflow input: once an environment is provisioned, an
	// ordinary release cannot silently drop the signing key from
	// comma-secrets, and decommissioning is an explicit reviewed edit of
	// the environment spec.
	oauthIdPEnv := map[string]string{}
	switch spec.OauthIdp {
	case "", "disabled":
	case "enabled":
		idp, readErr := readSecretJSON(ctx, gcloud, spec.Project, spec.OAuthIdpSecret)
		if readErr != nil {
			return nil, readErr
		}
		// The entry carries only the key-encryption key. Signing key
		// pairs live in the shared comma_oauth_signing_keys table and are
		// managed by the runtime admin command, so no key material and
		// no rotation state flow through the release at all.
		if err = requireFields(idp, "KEK_BASE64"); err != nil {
			return nil, err
		}
		kek := stringField(idp, "KEK_BASE64")
		if decoded, decodeErr := base64.StdEncoding.DecodeString(kek); decodeErr != nil || len(decoded) != 32 {
			return nil, errors.New("KEK_BASE64 must decode to exactly 32 bytes")
		}
		oauthIdPEnv["COMMA_OAUTH_IDP_KEK"] = kek
	default:
		return nil, errors.New(`environment spec oauthIdp must be "enabled" or "disabled"`)
	}
	var salix map[string]any
	if err = json.Unmarshal([]byte(os.Getenv("SALIX_CONFIG_JSON")), &salix); err != nil {
		return nil, errors.New("SALIX_CONFIG_JSON must be valid JSON")
	}
	if _, reserved := salix["alert_router"]; reserved {
		return nil, errors.New("SALIX_CONFIG_JSON must not set reserved alert_router config")
	}
	if err = injectAgentVMMTrustBundle(ctx, salix, kubectl, spec.Namespace); err != nil {
		return nil, err
	}
	salixBaseURL, salixHost, salixSitesDomain, _, bridgeHost, err := releaseNetworkConfig(salix)
	if err != nil {
		return nil, err
	}
	setNested(salix, "cluster", map[string]any{"strategy": "kubernetes_dns", "k8s_headless_service": "comma-headless"})
	setNested(salix, "overlay", map[string]any{"system_path": "/etc/salix-system"})
	setNested(salix, "storage", map[string]any{"endpoint": stringField(s3, "AWS_ENDPOINT_URL"), "region": stringField(s3, "AWS_REGION"), "bucket": stringField(s3, "BUCKET"), "access_key_id": stringField(s3, "AWS_ACCESS_KEY_ID"), "secret_access_key": stringField(s3, "AWS_SECRET_ACCESS_KEY"), "atomic_operations": "gcp", "conditional_delete": "native"})
	setNested(salix, "bridge_for_teams", map[string]any{
		"database": map[string]any{"url": stringField(db, "BRIDGE_DATABASE_URL")},
	})
	redisURL := stringField(redis, "REDIS_URL")
	setNested(salix, "comma", commaBundleConfig(stringField(db, "BRIDGE_DATABASE_URL"), redisURL))
	// Salix control metadata (tenant API keys and cutover markers) shares the
	// same physical database as BridgeForTeams and Comma, exactly as Comma does:
	// ownership comes from distinct table names plus an isolated
	// salix_schema_migrations ledger, not from a separate instance. See
	// docs/storage-search.md. Splitting it onto its own
	// database later only changes this URL source plus a data move.
	setNested(salix, "salix", map[string]any{"database": map[string]any{"url": stringField(db, "BRIDGE_DATABASE_URL")}})
	setNested(salix, "billing", map[string]any{"database": map[string]any{"url": stringField(db, "BILLING_DATABASE_URL")}})
	alertRouterEnabled, alertRouterMode, alertRouterLiveChannelID, err := alertRouterDesiredState(spec)
	if err != nil {
		return nil, err
	}
	releaseSubsystems := "salix,bridge_for_teams,comma_product"
	var alertRouterConfig map[string]any
	if alertRouterEnabled {
		alertRouter, readErr := readSecretJSON(ctx, gcloud, spec.Project, "alert-router-"+suffix)
		if readErr != nil {
			return nil, readErr
		}
		if alertRouterMode != "disabled" {
			slack, slackReadErr := readSecretJSON(ctx, gcloud, spec.Project, "alert-router-slack-"+suffix)
			if slackReadErr != nil {
				return nil, slackReadErr
			}
			if err = requireFields(slack, "SLACK_BOT_TOKEN"); err != nil {
				return nil, err
			}
			alertRouter["SLACK_BOT_TOKEN"] = stringField(slack, "SLACK_BOT_TOKEN")
			for _, key := range []string{"SLACK_SIGNING_SECRET", "SLACK_TEAM_ID", "SLACK_APP_ID", "SLACK_INVESTIGATOR_BOT_ID"} {
				if value, ok := slack[key].(string); ok {
					alertRouter[key] = value
				}
			}
		}
		expectedAudience := salixBaseURL + "/v1/events/gcp"
		var configErr error
		alertRouterConfig, configErr = alertRouterBundleConfig(
			alertRouterMode,
			alertRouterLiveChannelID,
			alertRouter,
			expectedAudience,
			stringField(db, "BRIDGE_DATABASE_URL"),
			stringField(db, "BILLING_DATABASE_URL"),
		)
		if configErr != nil {
			return nil, configErr
		}
		releaseSubsystems += ",alert_router"
	}
	removeRetiredNativeTriageReviewConfig(salix)
	if err = validateCommaAuthConfig(salix); err != nil {
		return nil, err
	}
	webCookieOrigin, err := commaWebCookieOrigin(salix, spec.Environment)
	if err != nil {
		return nil, err
	}
	adminCookieOrigin, err := commaAdminCookieOrigin(salix, spec.Environment)
	if err != nil {
		return nil, err
	}
	salixBody, _ := json.Marshal(salix)
	releaseBody := salixBody
	var alertRouterBody []byte
	if alertRouterEnabled {
		alertRouterBody, _ = json.Marshal(map[string]any{"alert_router": alertRouterConfig})
		combined := cloneMap(salix)
		setNested(combined, "alert_router", alertRouterConfig)
		releaseBody, _ = json.Marshal(combined)
	}
	resources := candidateResources(salixBody, alertRouterBody, releaseBody, redisURL, oauthIdPEnv)
	byBase := map[string]string{}
	for _, resource := range resources {
		base := resource.Name[:strings.LastIndex(resource.Name, "-")]
		byBase[base] = resource.Name
	}
	image := required("COMMA_IMAGE")
	digest := strings.TrimPrefix(image[strings.LastIndex(image, ":")+1:], "sha256:")
	revision := digest
	if len(revision) > 40 {
		revision = revision[:40]
	}
	replacements := map[string]string{
		"COMMA_IMAGE": image, "COMMA_ENVIRONMENT": spec.Environment, "COMMA_CLUSTER": spec.Cluster, "COMMA_REVISION": "sha-" + revision, "COMMA_REVISION_LABEL": "rev-" + shortHash([]byte(image)), "COMMA_TRACE_SAMPLE_RATIO": required("COMMA_TRACE_SAMPLE_RATIO"), "COMMA_STATIC_IP": required("COMMA_STATIC_IP"), "SALIX_HOST": salixHost, "SALIX_SITES_DOMAIN": salixSitesDomain, "BRIDGE_HOST": bridgeHost, "COMMA_WEB_COOKIE_ORIGIN": webCookieOrigin, "COMMA_ADMIN_COOKIE_ORIGIN": adminCookieOrigin, "SALIX_CONFIG_SHA256": hashHex(salixBody), "COMMA_ROLLOUT_PARTITION": "1", "COMMA_LEGACY_MESSAGE_EVENT_CLAIM_WRITER_FENCE_EPOCH": required("COMMA_RELEASE_ID"), "COMMA_ALERT_ROUTER_ENABLED": strconv.FormatBool(alertRouterEnabled), "COMMA_RELEASE_SUBSYSTEMS": releaseSubsystems, "GCP_PROJECT": spec.Project,
		"COMMA_SECRETS_NAME": byBase["comma-secrets"], "INSTANCE_CONNECTION_NAME": stringField(db, "INSTANCE_CONNECTION_NAME"), "SALIX_CONFIG_SECRET_NAME": byBase["salix-config"], "SALIX_TLS_SECRET_NAME": byBase["comma-salix-cloudflare-origin-tls"], "SALIX_SITES_TLS_SECRET_NAME": byBase["comma-salix-sites-cloudflare-origin-tls"], "TEAMS_TLS_SECRET_NAME": byBase["comma-teams-cloudflare-origin-tls"],
	}
	if alertRouterEnabled {
		replacements["ALERT_ROUTER_CONFIG_SECRET_NAME"] = byBase["alert-router-config"]
		replacements["ALERT_ROUTER_CONFIG_SHA256"] = hashHex(alertRouterBody)
		replacements["COMMA_RELEASE_CONFIG_SECRET_NAME"] = byBase["comma-release-config"]
	} else {
		replacements["COMMA_RELEASE_CONFIG_SECRET_NAME"] = byBase["salix-config"]
	}
	return json.Marshal(release.CandidateBundle{SchemaVersion: 1, Replacements: replacements, Resources: resources})
}

// injectAgentVMMTrustBundle binds Host enrollment to the CA that actually
// terminates the selected cluster's gateway. SALIX_CONFIG_JSON owns whether
// remote enrollment is configured, while the release process owns discovery
// of this infrastructure state. A missing or malformed CA fails the release
// before it can publish a Host configuration that cannot connect.
func injectAgentVMMTrustBundle(ctx context.Context, config map[string]any, kubectl release.Runner, namespace string) error {
	agentVMM, ok := config["agent_vmm"].(map[string]any)
	if !ok {
		return nil
	}
	material, ok := agentVMM["install_material"].(map[string]any)
	if !ok {
		return nil
	}
	enrollment, ok := material["remote_enrollment"].(map[string]any)
	if !ok {
		return errors.New("agent_vmm.install_material.remote_enrollment must be an object")
	}
	encoded, err := kubectl.Run(ctx, nil, "-n", namespace, "get", "secret", "salix-vmm-gateway-tls", "-o", `jsonpath={.data.ca\.crt}`)
	if err != nil {
		return fmt.Errorf("read Agent VMM gateway trust bundle: %w", err)
	}
	certificatePEM, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(encoded)))
	if err != nil {
		return errors.New("Agent VMM gateway CA Secret must contain base64-encoded ca.crt")
	}
	block, rest := pem.Decode(certificatePEM)
	if block == nil || block.Type != "CERTIFICATE" || len(strings.TrimSpace(string(rest))) != 0 {
		return errors.New("Agent VMM gateway ca.crt must contain exactly one PEM certificate")
	}
	certificate, err := x509.ParseCertificate(block.Bytes)
	if err != nil || !certificate.IsCA {
		return errors.New("Agent VMM gateway ca.crt must contain a valid CA certificate")
	}
	enrollment["trust_bundle"] = base64.StdEncoding.EncodeToString(certificatePEM)
	return nil
}

func alertRouterDesiredState(spec release.EnvironmentSpec) (bool, string, string, error) {
	mode := strings.ToLower(strings.TrimSpace(spec.AlertRouter.Mode))
	if mode == "" {
		mode = "disabled"
	}
	if mode != "disabled" && mode != "shadow" && mode != "live" {
		return false, "", "", errors.New(`environment spec alertRouter.mode must be "disabled", "shadow", or "live"`)
	}
	if !spec.AlertRouter.Enabled && mode != "disabled" {
		return false, "", "", errors.New("environment spec alertRouter.mode must remain disabled when the workload is disabled")
	}
	liveChannelID := strings.TrimSpace(spec.AlertRouter.SlackChannelID)
	if mode == "live" {
		if spec.Environment != "staging" {
			return false, "", "", errors.New("Alert Router live mode is currently allowed only in staging")
		}
		if !validPublicSlackChannelID(liveChannelID) {
			return false, "", "", errors.New("environment spec alertRouter.slackChannelId must be a public Slack channel ID in live mode")
		}
	}
	return spec.AlertRouter.Enabled, mode, liveChannelID, nil
}

func validPublicSlackChannelID(value string) bool {
	return len(value) > 1 && value[0] == 'C' && strings.Trim(value[1:], "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") == ""
}

func alertRouterBundleConfig(mode, liveChannelID string, secret map[string]any, expectedAudience string, coreDatabaseURLs ...string) (map[string]any, error) {
	if err := requireFields(secret, "DATABASE_URL"); err != nil {
		return nil, err
	}
	if err := validateAlertRouterDatabaseIsolation(stringField(secret, "DATABASE_URL"), coreDatabaseURLs...); err != nil {
		return nil, err
	}
	config := map[string]any{
		"mode":     mode,
		"database": map[string]any{"url": stringField(secret, "DATABASE_URL"), "pool_size": 1},
	}
	if mode == "disabled" {
		return config, nil
	}
	requiredFields := []string{
		"SLACK_BOT_TOKEN",
		"GCP_PUSH_AUDIENCE",
		"GCP_PUSH_SERVICE_ACCOUNT_EMAIL",
		"GRAFANA_WEBHOOK_SECRET",
		"GITHUB_WEBHOOK_SECRET",
		"GCP_PROJECT_STAGING",
		"GCP_PROJECT_PRODUCTION",
		"GKE_CLUSTER",
	}
	if mode == "shadow" {
		requiredFields = append(requiredFields, "SHADOW_CHANNEL_ID")
	}
	if err := requireFields(secret, requiredFields...); err != nil {
		return nil, err
	}
	channelID := liveChannelID
	channelKey := "live_channel_id"
	if mode == "shadow" {
		channelID = stringField(secret, "SHADOW_CHANNEL_ID")
		channelKey = "shadow_channel_id"
		if channelID != "C0ALMF2AD70" {
			return nil, errors.New("Alert Router shadow destination must be #xp-test C0ALMF2AD70")
		}
	} else if mode == "live" {
		if !validPublicSlackChannelID(channelID) {
			return nil, errors.New("Alert Router live destination must be a public Slack channel ID")
		}
	}
	if audience := stringField(secret, "GCP_PUSH_AUDIENCE"); audience != expectedAudience {
		return nil, fmt.Errorf("Alert Router GCP push audience must be %s", expectedAudience)
	}
	if len(stringField(secret, "GRAFANA_WEBHOOK_SECRET")) < 32 {
		return nil, errors.New("Alert Router Grafana webhook secret must contain at least 32 bytes")
	}
	if len(stringField(secret, "GITHUB_WEBHOOK_SECRET")) < 32 {
		return nil, errors.New("Alert Router GitHub webhook secret must contain at least 32 bytes")
	}
	config["slack"] = map[string]any{
		"bot_token": stringField(secret, "SLACK_BOT_TOKEN"),
		channelKey:  channelID,
	}
	// Optional progress ingress fails closed locally without gating other sources.
	for source, target := range map[string]string{
		"SLACK_SIGNING_SECRET": "signing_secret", "SLACK_TEAM_ID": "team_id", "SLACK_APP_ID": "app_id",
		"SLACK_INVESTIGATOR_BOT_ID": "investigator_bot_id",
	} {
		if value, ok := secret[source].(string); ok {
			config["slack"].(map[string]any)[target] = value
		}
	}
	// Live provider identifiers stay in the Secret Manager secret, not in code.
	config["gcp_projects"] = map[string]any{
		"staging":    stringField(secret, "GCP_PROJECT_STAGING"),
		"production": stringField(secret, "GCP_PROJECT_PRODUCTION"),
	}
	config["gke_cluster"] = stringField(secret, "GKE_CLUSTER")
	config["gcp_push"] = map[string]any{
		"audience":              stringField(secret, "GCP_PUSH_AUDIENCE"),
		"service_account_email": stringField(secret, "GCP_PUSH_SERVICE_ACCOUNT_EMAIL"),
	}
	config["grafana_webhook"] = map[string]any{
		"secret": stringField(secret, "GRAFANA_WEBHOOK_SECRET"),
	}
	config["github_webhook"] = map[string]any{
		"secret": stringField(secret, "GITHUB_WEBHOOK_SECRET"),
	}
	// PostHog is opt-in; its ingress owns validation and fails closed independently
	// of other alert sources and core release readiness.
	if source, ok := secret["POSTHOG_WEBHOOK"].(map[string]any); ok {
		selected := map[string]any{}
		for _, key := range []string{"secret", "project_id", "origin", "environment"} {
			if value, ok := source[key].(string); ok {
				selected[key] = value
			}
		}
		config["posthog_webhook"] = selected
	}
	// Optional read-only source configuration. Admission owns its validation;
	// an unavailable alert source must not become a core release/readiness gate.
	if source, ok := secret["RUNTIME_LOG"].(map[string]any); ok {
		selected := map[string]any{}
		for _, key := range []string{"enabled", "bucket", "environment", "cluster", "start_at", "push_audience", "push_service_account_email", "storage_endpoint", "storage_access_key_id", "storage_secret_access_key"} {
			if value, exists := source[key]; exists {
				selected[key] = value
			}
		}
		config["runtime_log"] = selected
	}
	return config, nil
}

type databaseIdentity struct {
	host, port, database, username string
}

func validateAlertRouterDatabaseIsolation(routerURL string, coreURLs ...string) error {
	router, err := parseDatabaseIdentity(routerURL)
	if err != nil {
		return errors.New("Alert Router DATABASE_URL must be an absolute PostgreSQL URL")
	}
	for _, candidate := range coreURLs {
		core, parseErr := parseDatabaseIdentity(candidate)
		if parseErr != nil {
			return errors.New("core database URL must be an absolute PostgreSQL URL")
		}
		if router.host == core.host && router.port == core.port && router.database == core.database {
			return errors.New("Alert Router must use a distinct logical database from core workloads")
		}
		if router.host == core.host && router.port == core.port && router.username == core.username {
			return errors.New("Alert Router must use a distinct database credential from core workloads")
		}
	}
	return nil
}

func parseDatabaseIdentity(raw string) (databaseIdentity, error) {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (parsed.Scheme != "ecto" && parsed.Scheme != "postgres" && parsed.Scheme != "postgresql") || parsed.Hostname() == "" || parsed.User == nil || parsed.User.Username() == "" {
		return databaseIdentity{}, errors.New("invalid database URL")
	}
	database := strings.TrimPrefix(parsed.EscapedPath(), "/")
	if database == "" || strings.Contains(database, "/") {
		return databaseIdentity{}, errors.New("invalid database name")
	}
	port := parsed.Port()
	if port == "" {
		port = "5432"
	}
	return databaseIdentity{
		host: strings.ToLower(parsed.Hostname()), port: port,
		database: database, username: parsed.User.Username(),
	}, nil
}

func commaBundleConfig(databaseURL, redisURL string) map[string]any {
	return map[string]any{
		"database": map[string]any{"url": databaseURL},
		"auth":     map[string]any{"redis_url": redisURL},
	}
}

func releaseNetworkConfig(config map[string]any) (string, string, string, string, string, error) {
	salixBaseURL, salixHost, err := configOrigin(config, "web", "api_base_url")
	if err != nil {
		return "", "", "", "", "", err
	}
	bridgeBaseURL, bridgeHost, err := configOrigin(config, "bridge_for_teams", "dashboard", "public_base_url")
	if err != nil {
		return "", "", "", "", "", err
	}
	sitesDomain := nestedString(config, "web", "sites_domain")
	parsedSites, parseErr := url.Parse("https://" + sitesDomain)
	if parseErr != nil || sitesDomain == "" || parsedSites.Host != sitesDomain || parsedSites.Hostname() == "" ||
		parsedSites.Port() != "" || parsedSites.Path != "" || parsedSites.RawQuery != "" || parsedSites.Fragment != "" {
		return "", "", "", "", "", errors.New("SALIX_CONFIG_JSON web.sites_domain must be one DNS hostname")
	}
	return salixBaseURL, salixHost, sitesDomain, bridgeBaseURL, bridgeHost, nil
}

func configOrigin(config map[string]any, path ...string) (string, string, error) {
	raw := nestedString(config, path...)
	parsed, err := url.Parse(raw)
	if err != nil || parsed.Scheme != "https" || parsed.Hostname() == "" || parsed.User != nil ||
		parsed.Port() != "" || parsed.Path != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", "", fmt.Errorf("SALIX_CONFIG_JSON %s must be one HTTPS origin without a port or path", strings.Join(path, "."))
	}
	return strings.TrimSuffix(raw, "/"), parsed.Hostname(), nil
}

func validateCommaAuthConfig(config map[string]any) error {
	requiredPaths := [][]string{
		{"comma", "auth", "secret"},
		{"comma", "auth", "rate_limit_secret"},
		{"comma", "auth", "redis_url"},
		{"comma", "email", "from"},
		{"email", "postmark_server_token"},
	}
	for _, path := range requiredPaths {
		if nestedString(config, path...) == "" {
			return errors.New("SALIX_CONFIG_JSON is missing " + strings.Join(path, "."))
		}
	}

	authSecret := nestedString(config, "comma", "auth", "secret")
	rateLimitSecret := nestedString(config, "comma", "auth", "rate_limit_secret")
	if len(authSecret) < 32 || len(rateLimitSecret) < 32 {
		return errors.New("comma.auth secrets must each contain at least 32 bytes")
	}
	if authSecret == rateLimitSecret {
		return errors.New("comma.auth.secret and comma.auth.rate_limit_secret must be different")
	}

	redisURL := nestedString(config, "comma", "auth", "redis_url")
	parsedRedisURL, err := url.Parse(redisURL)
	if err != nil || (parsedRedisURL.Scheme != "redis" && parsedRedisURL.Scheme != "rediss") || parsedRedisURL.Hostname() == "" {
		return errors.New("comma.auth.redis_url must be an absolute redis:// or rediss:// URL")
	}
	return nil
}

func commaWebCookieOrigin(config map[string]any, environment string) (string, error) {
	return commaCookieOrigin(
		config,
		environment,
		"web_cookie_origin",
		"https://app.comma.surf",
		"https://app-staging.comma.surf",
	)
}

func commaAdminCookieOrigin(config map[string]any, environment string) (string, error) {
	return commaCookieOrigin(
		config,
		environment,
		"admin_cookie_origin",
		"https://admin.comma.surf",
		"https://admin-staging.comma.surf",
	)
}

func commaCookieOrigin(
	config map[string]any,
	environment, key, productionDefault, stagingDefault string,
) (string, error) {
	var configured any
	if comma, ok := config["comma"].(map[string]any); ok {
		if web, ok := comma["web"].(map[string]any); ok {
			configured = web[key]
		}
	}

	var origin string
	switch value := configured.(type) {
	case nil:
		switch environment {
		case "production", "prod":
			origin = productionDefault
		case "staging":
			origin = stagingDefault
		default:
			return "", fmt.Errorf(
				"SALIX_CONFIG_JSON must set comma.web.%s for environment %q",
				key,
				environment,
			)
		}
	case string:
		origin = strings.TrimSpace(value)
	default:
		return "", fmt.Errorf("SALIX_CONFIG_JSON comma.web.%s must be one origin string", key)
	}

	parsed, err := url.Parse(origin)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") ||
		parsed.Hostname() == "" || parsed.User != nil || parsed.Path != "" ||
		parsed.RawQuery != "" || parsed.Fragment != "" {
		return "", fmt.Errorf(
			"SALIX_CONFIG_JSON comma.web.%s must be an absolute HTTP(S) origin",
			key,
		)
	}
	return origin, nil
}

func nestedString(value map[string]any, path ...string) string {
	var current any = value
	for _, key := range path {
		object, ok := current.(map[string]any)
		if !ok {
			return ""
		}
		current, ok = object[key]
		if !ok {
			return ""
		}
	}
	result, _ := current.(string)
	return strings.TrimSpace(result)
}

func candidateResources(salixBody, alertRouterBody, releaseBody []byte, redisURL string, oauthIdPEnv map[string]string) []release.CandidateResource {
	commaSecrets := map[string]string{"RELEASE_COOKIE": required("COMMA_RELEASE_COOKIE"), "REDIS_URL": redisURL}
	for key, value := range oauthIdPEnv {
		commaSecrets[key] = value
	}
	resources := []release.CandidateResource{
		secret("comma-secrets", "Opaque", commaSecrets),
		secret("salix-config", "Opaque", map[string]string{"config.json": string(salixBody)}),
		secret("comma-salix-cloudflare-origin-tls", "kubernetes.io/tls", map[string]string{"tls.crt": required("SALIX_CLOUDFLARE_ORIGIN_CERT"), "tls.key": required("SALIX_CLOUDFLARE_ORIGIN_KEY")}),
		secret("comma-salix-sites-cloudflare-origin-tls", "kubernetes.io/tls", map[string]string{"tls.crt": required("SALIX_SITES_CLOUDFLARE_ORIGIN_CERT"), "tls.key": required("SALIX_SITES_CLOUDFLARE_ORIGIN_KEY")}),
		secret("comma-teams-cloudflare-origin-tls", "kubernetes.io/tls", map[string]string{"tls.crt": required("BFT_CLOUDFLARE_ORIGIN_CERT"), "tls.key": required("BFT_CLOUDFLARE_ORIGIN_KEY")}),
	}
	if len(alertRouterBody) > 0 {
		resources = append(resources,
			secret("alert-router-config", "Opaque", map[string]string{"config.json": string(alertRouterBody)}),
			secret("comma-release-config", "Opaque", map[string]string{"config.json": string(releaseBody)}),
		)
	}
	return resources
}

func cloneMap(value map[string]any) map[string]any {
	body, _ := json.Marshal(value)
	var cloned map[string]any
	_ = json.Unmarshal(body, &cloned)
	return cloned
}

func readSecretJSON(ctx context.Context, runner release.Runner, project, name string) (map[string]any, error) {
	body, err := runner.Run(ctx, nil, "secrets", "versions", "access", "latest", "--secret", name, "--project", project)
	if err != nil {
		return nil, err
	}
	var value map[string]any
	if json.Unmarshal(body, &value) != nil {
		return nil, errors.New("invalid Secret Manager JSON")
	}
	return value, nil
}
func stringField(value map[string]any, key string) string { s, _ := value[key].(string); return s }
func required(name string) string                         { return os.Getenv(name) }

// requiredReleaseInputs contains release-operation inputs only. Application
// behavior belongs to SALIX_CONFIG_JSON; infrastructure credentials and
// discovered database/storage state are merged separately above.
var requiredReleaseInputs = []string{"SALIX_CONFIG_JSON", "COMMA_RELEASE_COOKIE", "SALIX_CLOUDFLARE_ORIGIN_CERT", "SALIX_CLOUDFLARE_ORIGIN_KEY", "SALIX_SITES_CLOUDFLARE_ORIGIN_CERT", "SALIX_SITES_CLOUDFLARE_ORIGIN_KEY", "BFT_CLOUDFLARE_ORIGIN_CERT", "BFT_CLOUDFLARE_ORIGIN_KEY", "COMMA_IMAGE", "COMMA_CHART_REF", "COMMA_TRACE_SAMPLE_RATIO", "COMMA_STATIC_IP", "COMMA_RELEASE_ID"}

func validateEnvironment() error {
	for _, name := range requiredReleaseInputs {
		if os.Getenv(name) == "" {
			return errors.New("missing required release input " + name)
		}
	}
	return nil
}

func requireFields(value map[string]any, keys ...string) error {
	for _, key := range keys {
		if stringField(value, key) == "" {
			return errors.New("Secret Manager payload is missing " + key)
		}
	}
	return nil
}

func setNested(target map[string]any, key string, value map[string]any) {
	current, _ := target[key].(map[string]any)
	if current == nil {
		current = map[string]any{}
	}
	deepMerge(current, value)
	target[key] = current
}

func deepMerge(target, updates map[string]any) {
	for key, value := range updates {
		incoming, incomingIsMap := value.(map[string]any)
		existing, existingIsMap := target[key].(map[string]any)
		if incomingIsMap && existingIsMap {
			deepMerge(existing, incoming)
			continue
		}
		target[key] = value
	}
}

func removeRetiredNativeTriageReviewConfig(config map[string]any) {
	im, ok := config["im"].(map[string]any)
	if !ok {
		return
	}
	delete(im, "native_triage_review")
}

func secret(base, typ string, data map[string]string) release.CandidateResource {
	resource := release.CandidateResource{Type: typ, Data: data}
	resource.Name = base + "-" + release.CandidateResourceDigest(resource)[:12]
	return resource
}
func shortHash(body []byte) string { return hashHex(body)[:12] }
func hashHex(body []byte) string   { sum := sha256.Sum256(body); return hex.EncodeToString(sum[:]) }
