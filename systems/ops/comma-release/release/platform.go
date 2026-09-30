package release

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"time"
)

type EnvironmentSpec struct {
	SchemaVersion          int      `json:"schemaVersion"`
	Environment            string   `json:"environment"`
	Namespace              string   `json:"namespace"`
	Project                string   `json:"project"`
	Cluster                string   `json:"cluster"`
	Location               string   `json:"location"`
	RequireProvider        bool     `json:"requireProvider"`
	PublicHosts            []string `json:"publicHosts"`
	AgentVmmGatewayEnabled bool     `json:"agentVmmGatewayEnabled"`
	ComputeRuntimeBaseURL  string   `json:"computeRuntimeBaseURL"`
	// The following fields name live provider resources. They are not stored
	// in the versioned spec. LoadEnvironmentSpec fills them, together with
	// Project and Cluster, from the release environment configuration.
	RuntimeServiceAccount         string `json:"-"`
	ReleaseObserverServiceAccount string `json:"-"`
	RedisSecret                   string `json:"-"`
	OAuthIdpSecret                string `json:"-"`
	// OauthIdp is the environment-owned IdP provisioning state:
	// "enabled" or "disabled" (empty means disabled). It lives in the
	// versioned environment spec — not a per-dispatch workflow input —
	// so an ordinary release can never silently drop the signing key
	// once an environment is provisioned; decommissioning is an explicit
	// reviewed edit of this file.
	OauthIdp string `json:"oauthIdp"`
	// SSHEnabled controls both the listener and TCP LoadBalancer.
	SSHEnabled bool `json:"sshEnabled"`
	// AlertRouter is the environment-owned workload and delivery state. It is
	// deliberately not a workflow input: ordinary reconciliations must preserve
	// the reviewed staging route, while production stays disabled unless its
	// versioned environment spec is changed.
	AlertRouter AlertRouterEnvironmentSpec `json:"alertRouter"`
}

type AlertRouterEnvironmentSpec struct {
	Enabled        bool   `json:"enabled"`
	Mode           string `json:"mode"`
	SlackChannelID string `json:"slackChannelId"`
}

type KubectlPlatform struct {
	Kubectl    Runner
	Gcloud     Runner
	Curl       Runner
	Helm       HelmAdapter
	HelmValues []byte
	Spec       EnvironmentSpec
	Poll       time.Duration
	// JobPendingTimeout bounds time spent waiting for a Job that has not
	// reached a running container. A zero value uses the production default.
	JobPendingTimeout time.Duration
}

type CandidateResource struct {
	Name string            `json:"name"`
	Type string            `json:"type,omitempty"`
	Data map[string]string `json:"data,omitempty"`
}

type CandidateBundle struct {
	SchemaVersion int                 `json:"schemaVersion"`
	Replacements  map[string]string   `json:"replacements"`
	Resources     []CandidateResource `json:"resources"`
}

func (p KubectlPlatform) Preflight(ctx context.Context, bundle []byte) (string, error) {
	var candidate CandidateBundle
	if err := json.Unmarshal(bundle, &candidate); err != nil || candidate.SchemaVersion != 1 {
		return "", errors.New("invalid candidate bundle for Helm preflight")
	}
	var err error
	values := p.HelmValues
	if len(values) == 0 {
		values, err = p.buildHelmValues(candidate.Replacements)
		if err != nil {
			return "", err
		}
	}
	adapter := p.Helm
	adapter.ValuesPath = ""
	adapter.ValuesJSON = values
	if _, err = adapter.Upgrade(ctx, HelmUpgradeOptions{DryRunServer: true}); err != nil {
		return "", err
	}
	sum := sha256.Sum256(values)
	return "sha256:" + hex.EncodeToString(sum[:]), nil
}

func (p KubectlPlatform) CurrentHelmRevision(ctx context.Context) (int, error) {
	if p.Helm.Runner == nil {
		return 0, errors.New("Helm release status is required before coordinator mutation")
	}
	status, err := p.Helm.Status(ctx)
	if err != nil {
		if containsNotFound(err.Error()) || strings.Contains(err.Error(), "release: not found") {
			return 0, errors.New("Helm release comma must be bootstrapped before coordinator mutation")
		}
		return 0, err
	}
	if status.Revision <= 0 {
		return 0, errors.New("Helm release comma has no serving revision")
	}
	if status.Status != "deployed" {
		return 0, fmt.Errorf("Helm release comma is not deployed: status %q", status.Status)
	}
	return status.Revision, nil
}

func (p KubectlPlatform) EnsureBundle(ctx context.Context, name string, bundle []byte) (string, error) {
	var candidate CandidateBundle
	if err := json.Unmarshal(bundle, &candidate); err != nil || candidate.SchemaVersion != 1 {
		return "", errors.New("invalid candidate bundle")
	}
	for _, resource := range candidate.Resources {
		if err := p.ensureCandidateResource(ctx, resource); err != nil {
			return "", err
		}
	}
	publicBundle, _ := json.Marshal(candidate.Replacements)
	manifest := map[string]any{"apiVersion": "v1", "kind": "ConfigMap", "metadata": map[string]any{"name": name, "namespace": p.Spec.Namespace, "labels": map[string]string{"app.kubernetes.io/name": "comma-release-bundle"}}, "immutable": true, "data": map[string]string{"bundle.json": string(publicBundle)}}
	existing, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "configmap/"+name, "-o", "json")
	if err == nil {
		var cm configMap
		var identity struct {
			Immutable bool `json:"immutable"`
		}
		if json.Unmarshal(existing, &cm) != nil || json.Unmarshal(existing, &identity) != nil || !identity.Immutable || cm.Data["bundle.json"] != string(publicBundle) {
			return "", errors.New("content-addressed bundle collision")
		}
		return name, nil
	}
	if !containsNotFound(err.Error()) {
		return "", err
	}
	body, _ := json.Marshal(manifest)
	_, err = p.Kubectl.Run(ctx, body, "create", "-f", "-")
	return name, err
}

func (p KubectlPlatform) ensureCandidateResource(ctx context.Context, resource CandidateResource) error {
	if resource.Name == "" {
		return errors.New("invalid candidate resource")
	}
	digest := CandidateResourceDigest(resource)
	if !strings.HasSuffix(resource.Name, "-"+digest[:12]) {
		return errors.New("candidate resource name is not content addressed")
	}
	manifest := map[string]any{"apiVersion": "v1", "kind": "Secret", "metadata": map[string]any{"name": resource.Name, "namespace": p.Spec.Namespace, "labels": map[string]string{"app.kubernetes.io/name": "comma-release-candidate"}}, "immutable": true}
	if resource.Type != "" {
		manifest["type"] = resource.Type
	}
	if len(resource.Data) > 0 {
		manifest["stringData"] = resource.Data
	}
	ref := "secret/" + resource.Name
	existing, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", ref, "-o", "json")
	if err == nil {
		if validateCandidateResource(existing, resource, digest) != nil {
			return errors.New("content-addressed candidate resource mismatch")
		}
		return nil
	}
	if err != nil && !containsNotFound(err.Error()) {
		return err
	}
	body, _ := json.Marshal(manifest)
	if _, err = p.Kubectl.Run(ctx, body, "create", "-f", "-"); err != nil {
		recovered, readErr := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", ref, "-o", "json")
		if readErr == nil && validateCandidateResource(recovered, resource, digest) == nil {
			return nil
		}
	}
	return err
}

func CandidateResourceDigest(resource CandidateResource) string {
	identity := struct {
		Kind string            `json:"kind"`
		Type string            `json:"type,omitempty"`
		Data map[string]string `json:"data,omitempty"`
	}{"Secret", resource.Type, resource.Data}
	body, _ := json.Marshal(identity)
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}

func validateCandidateResource(body []byte, expected CandidateResource, digest string) error {
	var object struct {
		Kind      string            `json:"kind"`
		Type      string            `json:"type"`
		Immutable bool              `json:"immutable"`
		Data      map[string]string `json:"data"`
	}
	if json.Unmarshal(body, &object) != nil || object.Kind != "Secret" || object.Type != expected.Type || !object.Immutable {
		return errors.New("candidate resource identity mismatch")
	}
	actualType := object.Type
	if expected.Type == "" && object.Type == "Opaque" {
		actualType = ""
	}
	actual := CandidateResource{Type: actualType}
	if len(object.Data) > 0 {
		actual.Data = map[string]string{}
	}
	for key, value := range object.Data {
		decoded, err := base64.StdEncoding.DecodeString(value)
		if err != nil {
			return err
		}
		actual.Data[key] = string(decoded)
	}
	if CandidateResourceDigest(actual) != digest {
		return errors.New("candidate resource content mismatch")
	}
	return nil
}

func (p KubectlPlatform) RunPlan(ctx context.Context, state State) (Plan, error) {
	var attempt *JobAttempt
	for i := len(state.Attempts) - 1; i >= 0; i-- {
		if state.Attempts[i].Stage == "plan" && state.Attempts[i].Status == "pending" {
			attempt = &state.Attempts[i]
			break
		}
	}
	if attempt == nil {
		return Plan{}, errors.New("plan attempt was not durably claimed")
	}
	spec := JobSpec{Name: attempt.Name, Stage: "plan", Image: state.Image, BundleName: state.BundleName, Attempt: attempt.Attempt, Fence: state.ReleaseID}
	logs, err := p.ensureJob(ctx, spec)
	if err != nil {
		return Plan{}, err
	}
	var plan Plan
	lines := strings.Split(strings.TrimSpace(string(logs)), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if json.Unmarshal([]byte(lines[i]), &plan) == nil {
			break
		}
	}
	if state.RequiredMode == ModeBlockedLegacy {
		err = plan.ValidateLegacyUpgrade()
	} else {
		err = plan.Validate()
	}
	if err != nil {
		return Plan{}, fmt.Errorf("candidate plan rejected: %w", err)
	}
	return plan, nil
}

const lifecycleEpochEvidenceMarkerPrefix = "COMMA_SESSION_LIFECYCLE_EPOCH "

func (p KubectlPlatform) RunJob(ctx context.Context, spec JobSpec) error {
	_, err := p.ensureJob(ctx, spec)
	return err
}

func (p KubectlPlatform) RunLifecycleEpoch(ctx context.Context, epochSpec LifecycleEpochSpec) (LifecycleEpochEvidence, error) {
	spec := lifecycleEpochJobSpec(epochSpec)
	logs, err := p.ensureJob(ctx, spec)
	if err != nil {
		return LifecycleEpochEvidence{}, err
	}
	var evidence LifecycleEpochEvidence
	found := false
	for _, line := range strings.Split(strings.TrimSpace(string(logs)), "\n") {
		if !strings.HasPrefix(line, lifecycleEpochEvidenceMarkerPrefix) {
			continue
		}
		if found || json.Unmarshal([]byte(strings.TrimPrefix(line, lifecycleEpochEvidenceMarkerPrefix)), &evidence) != nil {
			return LifecycleEpochEvidence{}, errors.New("invalid or duplicate lifecycle writer epoch evidence")
		}
		found = true
	}
	if !found {
		return LifecycleEpochEvidence{}, errors.New("lifecycle writer epoch job omitted evidence")
	}
	return evidence, nil
}

func lifecycleEpochJobSpec(epochSpec LifecycleEpochSpec) JobSpec {
	stage := "session-lifecycle-epoch-" + string(epochSpec.Action)
	return JobSpec{
		Name:           JobName(epochSpec.ReleaseID, stage, epochSpec.Attempt),
		Stage:          stage,
		Image:          epochSpec.Image,
		BundleName:     epochSpec.BundleName,
		Attempt:        epochSpec.Attempt,
		Fence:          fmt.Sprintf("%s:%s:%d", epochSpec.ReleaseID, epochSpec.Action, epochSpec.Attempt),
		LifecycleEpoch: &epochSpec,
	}
}

func (p KubectlPlatform) StartJob(ctx context.Context, spec JobSpec) error {
	_, err := p.ensureJobCreated(ctx, spec)
	return err
}

func (p KubectlPlatform) AttemptStatus(ctx context.Context, state State, attempt JobAttempt) (string, error) {
	if attempt.Name != JobName(state.ReleaseID, attempt.Stage, attempt.Attempt) {
		return "", fmt.Errorf("release attempt %s has a non-deterministic job name", attempt.Name)
	}
	body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "job/"+attempt.Name, "-o", "json")
	if err != nil {
		if containsNotFound(err.Error()) {
			return "missing", nil
		}
		return "", err
	}
	if _, err = validateAttemptFence(body, state, attempt); err != nil {
		return "", err
	}
	terminal, err := jobTerminalCondition(body)
	if err != nil {
		return "", err
	}
	if terminal == "Complete" {
		return "complete", nil
	}
	if terminal == "Failed" {
		return "failed", nil
	}
	return "active", nil
}

func (p KubectlPlatform) AbortAttempts(ctx context.Context, state State) error {
	for _, attempt := range state.Attempts {
		if attempt.Status == "complete" || attempt.Status == "aborted" {
			continue
		}
		if attempt.Status != "pending" && attempt.Status != "failed" {
			return fmt.Errorf("release attempt %s has unknown status %q", attempt.Name, attempt.Status)
		}
		if attempt.Name != JobName(state.ReleaseID, attempt.Stage, attempt.Attempt) {
			return fmt.Errorf("release attempt %s has a non-deterministic job name", attempt.Name)
		}
		if err := p.abortAttempt(ctx, state, attempt); err != nil {
			return err
		}
	}
	return nil
}

type jobIdentity struct {
	UID             string
	ResourceVersion string
}

func (p KubectlPlatform) abortAttempt(ctx context.Context, state State, attempt JobAttempt) error {
	for retry := 0; retry < 6; retry++ {
		body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "job/"+attempt.Name, "-o", "json")
		if err != nil {
			if containsNotFound(err.Error()) {
				return nil
			}
			return err
		}
		identity, err := validateAttemptFence(body, state, attempt)
		if err != nil {
			return err
		}
		token := "comma.surf/abort-token=" + identity.UID
		_, err = p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "label", "job/"+attempt.Name, token, "--resource-version="+identity.ResourceVersion, "--overwrite")
		if err != nil {
			if containsNotFound(err.Error()) {
				return nil
			}
			if containsConflict(err.Error()) {
				continue
			}
			return fmt.Errorf("claim release job %s for abort: %w", attempt.Name, err)
		}
		if _, err = p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "delete", "job", "-l", token, "--cascade=foreground", "--wait=true", "--timeout=2m"); err != nil {
			return fmt.Errorf("abort release job %s: %w", attempt.Name, err)
		}
	}
	return fmt.Errorf("abort release job %s did not converge after repeated replacement or resource-version conflicts", attempt.Name)
}

func validateAttemptFence(body []byte, state State, attempt JobAttempt) (jobIdentity, error) {
	var job struct {
		Metadata struct {
			Name            string            `json:"name"`
			UID             string            `json:"uid"`
			ResourceVersion string            `json:"resourceVersion"`
			Labels          map[string]string `json:"labels"`
			Annotations     map[string]string `json:"annotations"`
		} `json:"metadata"`
	}
	if err := json.Unmarshal(body, &job); err != nil {
		return jobIdentity{}, err
	}
	fence := state.ReleaseID
	if attempt.Stage != "plan" {
		fence += ":" + state.ManifestDigest
	}
	if job.Metadata.Name != attempt.Name || job.Metadata.Annotations["comma.surf/fence"] != fence || job.Metadata.Labels["comma.surf/release-id"] != sanitize(fence) {
		return jobIdentity{}, fmt.Errorf("release job %s fence mismatch", attempt.Name)
	}
	if job.Metadata.UID == "" || job.Metadata.ResourceVersion == "" {
		return jobIdentity{}, fmt.Errorf("release job %s identity is incomplete", attempt.Name)
	}
	return jobIdentity{UID: job.Metadata.UID, ResourceVersion: job.Metadata.ResourceVersion}, nil
}

func (p KubectlPlatform) ensureJob(ctx context.Context, spec JobSpec) ([]byte, error) {
	manifest, err := p.ensureJobCreated(ctx, spec)
	if err != nil {
		return nil, err
	}
	if err = p.waitForJob(ctx, spec.Name); err != nil {
		logs, logErr := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "logs", "job/"+spec.Name, "--all-containers=true", "--tail=1000", "--limit-bytes=65536")
		if logErr == nil && len(bytes.TrimSpace(logs)) > 0 {
			return nil, fmt.Errorf("%w\nrelease job logs:\n%s", err, releaseJobLogDiagnostic(logs))
		}
		if logErr != nil {
			return nil, fmt.Errorf("%w (failed to read release job logs: %v)", err, logErr)
		}
		return nil, err
	}
	_ = manifest
	return p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "logs", "job/"+spec.Name, "--all-containers=true")
}

func releaseJobLogDiagnostic(logs []byte) string {
	const (
		inputLimit  = 64 * 1024
		outputLimit = 4 * 1024
	)
	logs = bytes.TrimSpace(logs)
	truncated := len(logs) > inputLimit
	if truncated {
		logs = logs[len(logs)-inputLimit:]
	}
	diagnostic := redactAll(string(logs))
	if len(diagnostic) > outputLimit {
		const contextLimit = 2400
		context := releaseFailureContext(diagnostic, contextLimit)
		tailLimit := outputLimit - len(context) - len("\n[final log tail]\n")
		tail := diagnostic[len(diagnostic)-tailLimit:]
		diagnostic = context + "\n[final log tail]\n" + tail
	}
	if truncated {
		return "[truncated to final 65536 bytes] " + diagnostic
	}
	return diagnostic
}

func releaseFailureContext(logs string, limit int) string {
	markers := []string{
		"** (",
		"Postgrex.Error",
		"RuntimeError",
		"MatchError",
		"FunctionClauseError",
		"DBConnection.ConnectionError",
		"exited in:",
	}
	index := -1
	for _, marker := range markers {
		if candidate := strings.LastIndex(logs, marker); candidate > index {
			index = candidate
		}
	}
	if index < 0 {
		index = len(logs) - limit
	}
	if index < 0 {
		index = 0
	}
	end := index + limit
	if end > len(logs) {
		end = len(logs)
	}
	return "[failure context]\n" + logs[index:end]
}

func (p KubectlPlatform) ensureJobCreated(ctx context.Context, spec JobSpec) (map[string]any, error) {
	replacements, err := p.bundleReplacements(ctx, spec.BundleName)
	if err != nil {
		return nil, err
	}
	manifest := p.jobManifest(spec, replacements)
	expected, _ := json.Marshal(manifest)
	existing, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "job/"+spec.Name, "-o", "json")
	if err == nil {
		if err = validateExistingJob(existing, manifest); err != nil {
			return nil, err
		}
	} else if containsNotFound(err.Error()) {
		if _, err = p.Kubectl.Run(ctx, expected, "create", "-f", "-"); err != nil {
			recovered, readErr := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "job/"+spec.Name, "-o", "json")
			if readErr != nil {
				return nil, err
			}
			if validateErr := validateExistingJob(recovered, manifest); validateErr != nil {
				return nil, validateErr
			}
		}
	} else {
		return nil, err
	}
	return manifest, nil
}

func (p KubectlPlatform) waitForJob(ctx context.Context, name string) error {
	waitCtx, cancel := context.WithTimeout(ctx, 35*time.Minute)
	defer cancel()
	pendingTimeout := p.JobPendingTimeout
	if pendingTimeout <= 0 {
		pendingTimeout = 10 * time.Minute
	}
	var pendingSince time.Time
	lastObservation := ""

	for {
		if _, err := p.Kubectl.Run(waitCtx, nil, "-n", p.Spec.Namespace, "wait", "--for=condition=complete", "job/"+name, "--timeout=5s"); err == nil {
			return nil
		}
		if err := waitCtx.Err(); err != nil {
			return fmt.Errorf("release job %s did not finish: %w", name, err)
		}

		body, err := p.Kubectl.Run(waitCtx, nil, "-n", p.Spec.Namespace, "get", "job/"+name, "-o", "json")
		if err != nil {
			return err
		}
		terminal, err := jobTerminalCondition(body)
		if err != nil {
			return err
		}
		switch terminal {
		case "Complete":
			return nil
		case "Failed":
			return fmt.Errorf("release job %s failed", name)
		}

		pods, err := p.Kubectl.Run(waitCtx, nil, "-n", p.Spec.Namespace, "get", "pods", "-l", "job-name="+name, "-o", "json")
		if err != nil {
			return err
		}
		observation, pending, err := jobPendingObservation(pods)
		if err != nil {
			return err
		}
		if observation != "" && observation != lastObservation {
			fmt.Fprintf(os.Stderr, "release job %s status: %s\n", name, observation)
			lastObservation = observation
		}
		if !pending {
			pendingSince = time.Time{}
			continue
		}
		if pendingSince.IsZero() {
			pendingSince = time.Now()
			continue
		}
		if time.Since(pendingSince) >= pendingTimeout {
			return fmt.Errorf("release job %s remained pending for %s: %s", name, pendingTimeout, observation)
		}
	}
}

func jobPendingObservation(body []byte) (string, bool, error) {
	var pods struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Status struct {
				Phase      string `json:"phase"`
				Conditions []struct {
					Type    string `json:"type"`
					Status  string `json:"status"`
					Reason  string `json:"reason"`
					Message string `json:"message"`
				} `json:"conditions"`
				ContainerStatuses []struct {
					Name  string `json:"name"`
					State struct {
						Running *struct{} `json:"running"`
						Waiting *struct {
							Reason  string `json:"reason"`
							Message string `json:"message"`
						} `json:"waiting"`
					} `json:"state"`
				} `json:"containerStatuses"`
			} `json:"status"`
		} `json:"items"`
	}
	if err := json.Unmarshal(body, &pods); err != nil {
		return "", false, err
	}
	if len(pods.Items) == 0 {
		return "no pod has been created", true, nil
	}
	observations := make([]string, 0, len(pods.Items))
	allPending := true
	for _, pod := range pods.Items {
		detail := "phase=" + pod.Status.Phase
		for _, condition := range pod.Status.Conditions {
			if condition.Type == "PodScheduled" && condition.Status == "False" {
				detail += " scheduled=" + condition.Reason
				if condition.Message != "" {
					detail += ": " + condition.Message
				}
			}
		}
		for _, status := range pod.Status.ContainerStatuses {
			if status.State.Running != nil {
				allPending = false
				continue
			}
			if status.State.Waiting != nil {
				detail += " container=" + status.Name + " waiting=" + status.State.Waiting.Reason
				if status.State.Waiting.Message != "" {
					detail += ": " + status.State.Waiting.Message
				}
			}
		}
		observations = append(observations, pod.Metadata.Name+" "+detail)
	}
	return strings.Join(observations, "; "), allPending, nil
}

func jobTerminalCondition(body []byte) (string, error) {
	var job struct {
		Status struct {
			Conditions []struct {
				Type   string `json:"type"`
				Status string `json:"status"`
			} `json:"conditions"`
		} `json:"status"`
	}
	if err := json.Unmarshal(body, &job); err != nil {
		return "", err
	}
	for _, condition := range job.Status.Conditions {
		if condition.Status == "True" && (condition.Type == "Complete" || condition.Type == "Failed") {
			return condition.Type, nil
		}
	}
	return "", nil
}

func (p KubectlPlatform) bundleReplacements(ctx context.Context, name string) (map[string]string, error) {
	body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "configmap/"+name, "-o", "jsonpath={.data.bundle\\.json}")
	if err != nil {
		return nil, err
	}
	var replacements map[string]string
	if err = json.Unmarshal(body, &replacements); err != nil {
		return nil, err
	}
	return replacements, nil
}

const coreReleaseSubsystems = "salix,bridge_for_teams,comma_product"

func alertRouterSelection(replacements map[string]string) (bool, string, error) {
	enabledValue := strings.TrimSpace(replacements["COMMA_ALERT_ROUTER_ENABLED"])
	if enabledValue == "" {
		enabledValue = "false"
	}
	enabled, err := strconv.ParseBool(enabledValue)
	if err != nil {
		return false, "", errors.New("candidate bundle Alert Router enablement must be true or false")
	}
	subsystems := strings.TrimSpace(replacements["COMMA_RELEASE_SUBSYSTEMS"])
	if subsystems == "" {
		subsystems = coreReleaseSubsystems
	}
	wantSubsystems := coreReleaseSubsystems
	if enabled {
		wantSubsystems += ",alert_router"
	}
	if subsystems != wantSubsystems {
		return false, "", errors.New("candidate bundle Alert Router enablement and release subsystems disagree")
	}
	return enabled, subsystems, nil
}

func (p KubectlPlatform) jobManifest(spec JobSpec, replacements map[string]string) map[string]any {
	ids, _ := json.Marshal(spec.AllowedStepIDs)
	command := fmt.Sprintf("Comma.Release.execute_plan_stage(%q, %q, %s)", spec.Stage, spec.ManifestDigest, string(ids))
	legacyUpgrade := strings.HasPrefix(spec.Stage, "legacy-")
	if legacyUpgrade {
		stage := strings.TrimPrefix(spec.Stage, "legacy-")
		command = fmt.Sprintf("Comma.Release.execute_legacy_upgrade_stage(%q, %q, %s)", stage, spec.ManifestDigest, string(ids))
	}
	if spec.LifecycleEpoch != nil {
		command = `Comma.SessionLifecycleWriterEpoch.release_command!(
  System.fetch_env!("COMMA_SESSION_LIFECYCLE_EPOCH_ACTION"),
  System.fetch_env!("COMMA_SESSION_LIFECYCLE_EPOCH_RELEASE_ID"),
  System.fetch_env!("COMMA_SESSION_LIFECYCLE_EPOCH_TOKEN"),
  String.to_integer(System.fetch_env!("COMMA_SESSION_LIFECYCLE_EPOCH_GENERATION")),
  String.to_integer(System.fetch_env!("COMMA_SESSION_LIFECYCLE_EPOCH_LEASE_SECONDS"))
)`
	} else if spec.Stage == "plan" {
		command = "IO.puts(Comma.Release.plan_json())"
	} else if spec.RuntimeRelease != nil {
		command = `Comma.Release.publish_runtime_release(System.fetch_env!("COMMA_RUNTIME_RELEASE_ID"), String.to_integer(System.fetch_env!("COMMA_RUNTIME_HELM_REVISION")))`
	}
	bootExpression := `case Application.ensure_all_started(:salix_store) do
  {:ok, _} -> :ok
  {:error, reason} -> raise "failed to start release storage runtime: #{inspect(reason)}"
end
`
	if spec.Stage == "cutover" {
		// ConversationStore can schedule a durable list-index repair while the
		// cutover job converts a Conversation. The release job starts only the
		// owner fleet, not the full SalixIM application and its live writers.
		bootExpression += `case Process.whereis(SalixIM.ConversationProjectionTasks) do
  nil ->
    case Task.Supervisor.start_link(name: SalixIM.ConversationProjectionTasks, max_children: 64) do
      {:ok, _} -> :ok
      {:error, reason} -> raise "failed to start release conversation projection tasks: #{inspect(reason)}"
    end

  _pid -> :ok
end
`
	}
	bootExpression += `Code.eval_string(System.fetch_env!("COMMA_RELEASE_EXPRESSION"))`
	annotations := map[string]string{"comma.surf/release-stage": spec.Stage, "comma.surf/release-attempt": strconv.Itoa(spec.Attempt), "comma.surf/manifest-digest": spec.ManifestDigest, "comma.surf/fence": spec.Fence, "comma.surf/allowed-step-ids": string(ids), "comma.surf/bundle-name": spec.BundleName}
	podAnnotations := make(map[string]string, len(annotations)+1)
	for key, value := range annotations {
		podAnnotations[key] = value
	}
	if spec.Stage == "cutover" || spec.Stage == "legacy-cutover" {
		podAnnotations["cluster-autoscaler.kubernetes.io/safe-to-evict"] = "false"
	}
	_, releaseSubsystems, _ := alertRouterSelection(replacements)
	// Release Jobs load the same runtime configuration as the serving pods, so they need the same
	// environment; without it runtime.exs falls back to config_env() and validates staging as production.
	env := []any{map[string]any{"name": "COMMA_RELEASE_JOB", "value": "1"}, map[string]any{"name": "COMMA_ENVIRONMENT", "value": p.Spec.Environment}, map[string]any{"name": "COMMA_SUBSYSTEMS", "value": releaseSubsystems}, map[string]any{"name": "SALIX_SNOWFLAKE_WORKER_ID", "value": "1023"}, map[string]any{"name": "COMMA_RELEASE_BOOT_EXPRESSION", "value": bootExpression}, map[string]any{"name": "COMMA_RELEASE_EXPRESSION", "value": command}, map[string]any{"name": "REQUIRE_PROVIDER", "value": strconv.FormatBool(p.Spec.RequireProvider)}, map[string]any{"name": "INSTANCE_CONNECTION_NAME", "value": replacements["INSTANCE_CONNECTION_NAME"]}}
	if spec.RuntimeRelease != nil {
		env = append(env,
			map[string]any{"name": "COMMA_RUNTIME_RELEASE_ID", "value": spec.RuntimeRelease.ReleaseID},
			map[string]any{"name": "COMMA_RUNTIME_HELM_REVISION", "value": strconv.Itoa(spec.RuntimeRelease.Helm.ServingRevision)},
		)
	}
	if legacyUpgrade {
		env = append(env, map[string]any{"name": "COMMA_LEGACY_UPGRADE", "value": "1"})
	}
	if spec.LifecycleEpoch != nil {
		env = append(env,
			map[string]any{"name": "COMMA_SESSION_LIFECYCLE_EPOCH_ACTION", "value": string(spec.LifecycleEpoch.Action)},
			map[string]any{"name": "COMMA_SESSION_LIFECYCLE_EPOCH_RELEASE_ID", "value": spec.LifecycleEpoch.ReleaseID},
			map[string]any{"name": "COMMA_SESSION_LIFECYCLE_EPOCH_TOKEN", "value": spec.LifecycleEpoch.Token},
			map[string]any{"name": "COMMA_SESSION_LIFECYCLE_EPOCH_GENERATION", "value": strconv.FormatInt(spec.LifecycleEpoch.Generation, 10)},
			map[string]any{"name": "COMMA_SESSION_LIFECYCLE_EPOCH_LEASE_SECONDS", "value": strconv.Itoa(spec.LifecycleEpoch.LeaseSeconds)},
		)
	}
	container := map[string]any{"name": "release", "image": spec.Image, "imagePullPolicy": "Always", "command": []string{"/bin/sh", "-c"}, "args": []string{`set -eu
proxy=/usr/local/bin/cloud-sql-proxy
proxy_pid=
attempt=1
while [ "${attempt}" -le 12 ]; do
  "${proxy}" --private-ip --port=5432 --health-check --http-address=127.0.0.1 --http-port=9090 "${INSTANCE_CONNECTION_NAME}" &
  candidate_pid="$!"
  readiness_attempt=1
  while [ "${readiness_attempt}" -le 10 ]; do
    if curl --fail --silent --show-error http://127.0.0.1:9090/readiness >/dev/null 2>&1; then
      proxy_pid="${candidate_pid}"
      break 2
    fi
    if ! kill -0 "${candidate_pid}" >/dev/null 2>&1; then break; fi
    readiness_attempt=$((readiness_attempt + 1))
    sleep 1
  done
  if kill -0 "${candidate_pid}" >/dev/null 2>&1; then
    kill "${candidate_pid}" >/dev/null 2>&1 || true
  fi
  proxy_status=0
  wait "${candidate_pid}" || proxy_status="$?"
  if [ "${proxy_status}" -eq 126 ] || [ "${proxy_status}" -eq 127 ]; then
    exit "${proxy_status}"
  fi
  if [ "${attempt}" -eq 12 ]; then
    echo "cloud-sql-proxy did not become available after ${attempt} attempts" >&2
    exit 1
  fi
  attempt=$((attempt + 1))
  sleep 5
done
trap 'kill "${proxy_pid}" >/dev/null 2>&1 || true' EXIT
bin/comma eval "$COMMA_RELEASE_BOOT_EXPRESSION"`}, "envFrom": []any{map[string]any{"secretRef": map[string]string{"name": replacements["COMMA_SECRETS_NAME"]}}}, "env": env, "volumeMounts": []any{map[string]any{"name": "salix-config", "mountPath": "/etc/salix", "readOnly": true}}}
	releaseConfigSecret := replacements["COMMA_RELEASE_CONFIG_SECRET_NAME"]
	if releaseConfigSecret == "" {
		releaseConfigSecret = replacements["SALIX_CONFIG_SECRET_NAME"]
	}
	podSpec := map[string]any{
		"serviceAccountName": "comma",
		"restartPolicy":      "Never",
		"containers":         []any{container},
		"volumes":            []any{map[string]any{"name": "salix-config", "secret": map[string]any{"secretName": releaseConfigSecret}}},
	}
	template := map[string]any{
		"metadata": map[string]any{"labels": map[string]string{"app.kubernetes.io/name": "comma-release"}, "annotations": podAnnotations},
		"spec":     podSpec,
	}
	jobSpec := map[string]any{"ttlSecondsAfterFinished": 86400, "activeDeadlineSeconds": 2100, "backoffLimit": 0, "template": template}
	return map[string]any{
		"apiVersion": "batch/v1",
		"kind":       "Job",
		"metadata":   map[string]any{"name": spec.Name, "namespace": p.Spec.Namespace, "labels": map[string]string{"app.kubernetes.io/name": "comma-release", "comma.surf/release-id": sanitize(spec.Fence)}, "annotations": annotations},
		"spec":       jobSpec,
	}
}

func validateExistingJob(body []byte, expected map[string]any) error {
	var object any
	if err := json.Unmarshal(body, &object); err != nil {
		return err
	}
	expectedBody, _ := json.Marshal(expected)
	var normalizedExpected any
	if err := json.Unmarshal(expectedBody, &normalizedExpected); err != nil {
		return err
	}
	normalizeJobAdmissionFields(object)
	if !jsonSubset(normalizedExpected, object) {
		return fmt.Errorf("deterministic job exists with mismatched spec at %s", jsonMismatchPath(normalizedExpected, object, "$"))
	}
	return nil
}

func jsonMismatchPath(expected, actual any, path string) string {
	switch want := expected.(type) {
	case map[string]any:
		got, ok := actual.(map[string]any)
		if !ok {
			return path
		}
		for key, value := range want {
			if !jsonSubset(value, got[key]) {
				return jsonMismatchPath(value, got[key], path+"."+key)
			}
		}
	case []any:
		got, ok := actual.([]any)
		if !ok || len(want) != len(got) {
			return path
		}
		for i := range want {
			if !jsonSubset(want[i], got[i]) {
				return jsonMismatchPath(want[i], got[i], fmt.Sprintf("%s[%d]", path, i))
			}
		}
	default:
		return path
	}
	return path
}

func normalizeJobAdmissionFields(object any) {
	job, _ := object.(map[string]any)
	spec, _ := job["spec"].(map[string]any)
	template, _ := spec["template"].(map[string]any)
	podSpec, _ := template["spec"].(map[string]any)
	if volumes, ok := podSpec["volumes"].([]any); ok {
		podSpec["volumes"] = slices.DeleteFunc(volumes, func(value any) bool {
			volume, _ := value.(map[string]any)
			name, _ := volume["name"].(string)
			return strings.HasPrefix(name, "kube-api-access-")
		})
	}
	if containers, ok := podSpec["containers"].([]any); ok {
		for _, value := range containers {
			container, _ := value.(map[string]any)
			if mounts, ok := container["volumeMounts"].([]any); ok {
				container["volumeMounts"] = slices.DeleteFunc(mounts, func(value any) bool {
					mount, _ := value.(map[string]any)
					name, _ := mount["name"].(string)
					return strings.HasPrefix(name, "kube-api-access-")
				})
			}
		}
	}
}

func jsonSubset(expected, actual any) bool {
	switch want := expected.(type) {
	case map[string]any:
		got, ok := actual.(map[string]any)
		if !ok {
			return false
		}
		for key, value := range want {
			if !jsonSubset(value, got[key]) {
				return false
			}
		}
		return true
	case []any:
		got, ok := actual.([]any)
		if !ok || len(want) != len(got) {
			return false
		}
		for i := range want {
			if !jsonSubset(want[i], got[i]) {
				return false
			}
		}
		return true
	default:
		return fmt.Sprint(expected) == fmt.Sprint(actual)
	}
}

func (p KubectlPlatform) Quiesce(ctx context.Context, state State) (int, error) {
	revision, err := p.helmUpgrade(ctx, state, true, 0)
	if err != nil {
		return 0, err
	}
	if err = p.waitForWriterAbsence(ctx); err != nil {
		return 0, err
	}
	return revision.Revision, nil
}

func (p KubectlPlatform) waitForWriterAbsence(ctx context.Context) error {
	_, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "wait", "--for=delete", "pod", "-l", "app.kubernetes.io/name=comma", "--timeout=5m")
	if err != nil && !containsNotFound(err.Error()) {
		return err
	}
	return nil
}

func (p KubectlPlatform) Apply(ctx context.Context, state State) (ApplyEvidence, error) {
	partition := 1
	if state.RequiresExclusiveDeployment() {
		partition = 0
	}
	revision, err := p.helmUpgrade(ctx, state, false, partition)
	if err != nil {
		return ApplyEvidence{}, err
	}
	manifest, err := p.Helm.GetManifest(ctx)
	if err != nil {
		return ApplyEvidence{}, err
	}
	sum := sha256.Sum256(manifest)
	return ApplyEvidence{ManifestDigest: "sha256:" + hex.EncodeToString(sum[:]), HelmRevision: revision.Revision}, nil
}

func (p KubectlPlatform) Verify(ctx context.Context, state State) (ApplyEvidence, error) {
	ordinalServices := []string{"comma-salix", "comma-teams", "comma-product"}
	for _, resource := range []string{"deployment/comma-otel-collector", "statefulset/comma"} {
		if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "rollout", "status", resource, "--timeout=15m"); err != nil {
			return ApplyEvidence{}, err
		}
	}
	replacements, err := p.bundleReplacements(ctx, state.BundleName)
	if err != nil {
		return ApplyEvidence{}, err
	}
	alertRouterEnabled, _, err := alertRouterSelection(replacements)
	if err != nil {
		return ApplyEvidence{}, err
	}
	if alertRouterEnabled {
		if _, err = p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "rollout", "status", "deployment/comma-alert-router", "--timeout=15m"); err != nil {
			return ApplyEvidence{}, err
		}
	}
	if state.RequiresExclusiveDeployment() {
		// Exclusive cutover starts from zero replicas. OrderedReady therefore
		// creates candidate ordinal 0 before ordinal 1; partition 1 would
		// restart the old ordinal 0 after an irreversible cutover.
		for _, ordinal := range []string{"0", "1"} {
			if err := p.verifyOrdinal(ctx, ordinal, ordinalServices); err != nil {
				return ApplyEvidence{}, err
			}
		}
	} else {
		if err := p.verifyOrdinal(ctx, "1", ordinalServices); err != nil {
			return ApplyEvidence{}, err
		}
		if _, err := p.helmUpgrade(ctx, state, false, 0); err != nil {
			return ApplyEvidence{}, err
		}
		if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "rollout", "status", "statefulset/comma", "--timeout=15m"); err != nil {
			return ApplyEvidence{}, err
		}
		if err := p.verifyOrdinal(ctx, "0", ordinalServices); err != nil {
			return ApplyEvidence{}, err
		}
	}
	if alertRouterEnabled {
		if err := p.verifyAlertRouterServingPath(ctx, replacements["SALIX_HOST"]); err != nil {
			return ApplyEvidence{}, err
		}
	}
	status, err := p.Helm.Status(ctx)
	if err != nil {
		return ApplyEvidence{}, err
	}
	return ApplyEvidence{HelmRevision: status.Revision}, nil
}

func (p KubectlPlatform) VerifyLifecycleV1(ctx context.Context, state State) error {
	epoch := state.LifecycleWriterEpoch
	if epoch == nil || !epoch.Required || epoch.Status != "active" ||
		epoch.DrainedAt.IsZero() {
		return errors.New("lifecycle-v1 verification requires active epoch and writer-drain evidence")
	}
	replacements, err := p.bundleReplacements(ctx, state.BundleName)
	if err != nil {
		return err
	}
	expectedRevision := replacements["COMMA_REVISION_LABEL"]
	if expectedRevision == "" {
		return errors.New("candidate bundle omits lifecycle-v1 revision label")
	}
	if err := p.verifyTerminalWorkloadShape(ctx); err != nil {
		return err
	}
	alertRouterEnabled, _, err := alertRouterSelection(replacements)
	if err != nil {
		return err
	}
	if alertRouterEnabled {
		if err := p.verifyAlertRouterTerminalWorkloadShape(ctx); err != nil {
			return err
		}
	}
	productPods, err := p.verifyLifecycleV1Workload(
		ctx,
		"statefulset/comma",
		"app.kubernetes.io/name=comma",
		state.Image,
		expectedRevision,
	)
	if err != nil {
		return err
	}
	return p.verifyLifecycleV1Ingress(
		ctx,
		state.ReleaseID,
		expectedRevision,
		replacements,
		productPods,
	)
}

type lifecycleV1ServingPod struct {
	Name string
	UID  string
	IP   string
}

func (p KubectlPlatform) verifyLifecycleV1Workload(
	ctx context.Context,
	resource, selector, image, revision string,
) ([]lifecycleV1ServingPod, error) {
	controllerBody, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", resource, "-o", "json")
	if err != nil {
		return nil, fmt.Errorf("inspect lifecycle-v1 controller %s: %w", resource, err)
	}
	var controller struct {
		Spec struct {
			Replicas int `json:"replicas"`
		} `json:"spec"`
	}
	if json.Unmarshal(controllerBody, &controller) != nil || controller.Spec.Replicas <= 0 {
		return nil, fmt.Errorf("lifecycle-v1 controller %s has invalid serving replicas", resource)
	}
	podsBody, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "pods", "-l", selector, "-o", "json")
	if err != nil {
		return nil, fmt.Errorf("inspect lifecycle-v1 pods for %s: %w", resource, err)
	}
	var pods struct {
		Items []struct {
			Metadata struct {
				Name              string            `json:"name"`
				UID               string            `json:"uid"`
				Labels            map[string]string `json:"labels"`
				DeletionTimestamp string            `json:"deletionTimestamp"`
			} `json:"metadata"`
			Spec struct {
				Containers []struct {
					Name  string `json:"name"`
					Image string `json:"image"`
				} `json:"containers"`
			} `json:"spec"`
			Status struct {
				Phase      string `json:"phase"`
				PodIP      string `json:"podIP"`
				Conditions []struct {
					Type   string `json:"type"`
					Status string `json:"status"`
				} `json:"conditions"`
			} `json:"status"`
		} `json:"items"`
	}
	if json.Unmarshal(podsBody, &pods) != nil {
		return nil, fmt.Errorf("decode lifecycle-v1 pod inventory for %s", resource)
	}
	serving := make([]lifecycleV1ServingPod, 0, controller.Spec.Replicas)
	for _, pod := range pods.Items {
		if pod.Metadata.DeletionTimestamp != "" || pod.Status.Phase != "Running" ||
			!slices.ContainsFunc(pod.Status.Conditions, func(condition struct {
				Type   string `json:"type"`
				Status string `json:"status"`
			}) bool {
				return condition.Type == "Ready" && condition.Status == "True"
			}) {
			continue
		}
		serving = append(serving, lifecycleV1ServingPod{
			Name: pod.Metadata.Name,
			UID:  pod.Metadata.UID,
			IP:   pod.Status.PodIP,
		})
		if pod.Metadata.Labels["comma.surf/revision"] != revision {
			return nil, fmt.Errorf("serving pod %s is not lifecycle-v1 revision %s", pod.Metadata.Name, revision)
		}
		candidate := slices.ContainsFunc(pod.Spec.Containers, func(container struct {
			Name  string `json:"name"`
			Image string `json:"image"`
		}) bool {
			return container.Name == "comma" && container.Image == image
		})
		if !candidate {
			return nil, fmt.Errorf("serving pod %s is not the lifecycle-v1 candidate image", pod.Metadata.Name)
		}
	}
	if len(serving) != controller.Spec.Replicas {
		return nil, fmt.Errorf(
			"%s has %d lifecycle-v1 serving replicas, expected %d",
			resource,
			len(serving),
			controller.Spec.Replicas,
		)
	}
	return serving, nil
}

const lifecycleV1ProbeStatusMarker = "\nCOMMA_RELEASE_LIFECYCLE_V1_STATUS:"

// The serving auth contract only resolves credentials with the comma_sess_
// grammar. Keep the public bearer probe outside it so the request exercises
// routing/auth classification but cannot read or touch a durable Session.
const lifecycleV1InvalidBearer = "comma-release-lifecycle-v1-invalid"

func (p KubectlPlatform) verifyLifecycleV1Ingress(
	ctx context.Context,
	releaseID, revision string,
	replacements map[string]string,
	productPods []lifecycleV1ServingPod,
) error {
	if p.Curl == nil {
		return errors.New("lifecycle-v1 public ingress verification requires curl")
	}
	host, err := p.validatedPublicAPIHost(replacements)
	if err != nil {
		return err
	}
	webOrigin := replacements["COMMA_WEB_COOKIE_ORIGIN"]
	if err = validateLifecycleV1Origin("Web", webOrigin); err != nil {
		return err
	}
	if err = p.verifyPublicIngressOwnership(ctx, host); err != nil {
		return err
	}
	if err = p.verifyLifecycleV1ProductEndpoints(ctx, productPods); err != nil {
		return err
	}

	probeURL := "https://" + host + "/v1/comma/auth/session?comma_release_contract=" +
		url.QueryEscape(releaseID+"-"+revision)
	commonHeaders := []string{
		"accept: application/json",
		"cache-control: no-store",
		"pragma: no-cache",
	}
	webHeaders := append(slices.Clone(commonHeaders),
		"origin: "+webOrigin,
		"x-comma-session-transport: cookie",
		"x-comma-expected-auth-session-id: unknown",
	)
	if err = p.runLifecycleV1Probe(
		ctx,
		probeURL+"&probe=missing-version",
		webHeaders,
		428,
		map[string]any{
			"error":            "session_lifecycle_version_required",
			"contract_version": float64(1),
		},
	); err != nil {
		return fmt.Errorf("lifecycle-v1 missing-version ingress probe: %w", err)
	}
	if err = p.runLifecycleV1Probe(
		ctx,
		probeURL+"&probe=unsupported-version",
		append(slices.Clone(webHeaders), "x-comma-session-lifecycle-version: 0"),
		400,
		map[string]any{
			"error":            "unsupported_session_lifecycle_version",
			"contract_version": float64(1),
		},
	); err != nil {
		return fmt.Errorf("lifecycle-v1 unsupported-version ingress probe: %w", err)
	}
	if err = p.runLifecycleV1Probe(
		ctx,
		probeURL+"&probe=explicit-bearer",
		append(slices.Clone(commonHeaders),
			"authorization: Bearer "+lifecycleV1InvalidBearer,
			"x-comma-session-transport: bearer",
			"x-comma-session-lifecycle-version: 1",
		),
		401,
		map[string]any{"error": "unauthorized"},
	); err != nil {
		return fmt.Errorf("lifecycle-v1 explicit-bearer ingress probe: %w", err)
	}
	return nil
}

func (p KubectlPlatform) validatedPublicAPIHost(replacements map[string]string) (string, error) {
	host := replacements["SALIX_HOST"]
	if host == "" {
		return "", errors.New("candidate bundle omits public API host")
	}
	publicURL, err := url.Parse("https://" + host)
	if err != nil || publicURL.Host != host || publicURL.Hostname() == "" ||
		publicURL.Path != "" || publicURL.RawQuery != "" || publicURL.Fragment != "" {
		return "", errors.New("candidate bundle has invalid public API host")
	}
	if !slices.Contains(p.Spec.PublicHosts, host) {
		return "", fmt.Errorf(
			"candidate public API host %s is absent from the environment public hosts",
			host,
		)
	}
	return host, nil
}

func validateLifecycleV1Origin(surface, origin string) error {
	parsed, err := url.Parse(origin)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") ||
		parsed.Hostname() == "" || parsed.User != nil || parsed.Path != "" ||
		parsed.RawQuery != "" || parsed.Fragment != "" {
		return fmt.Errorf(
			"candidate bundle has invalid lifecycle-v1 %s Cookie origin",
			surface,
		)
	}
	return nil
}

type lifecycleV1RouteRef struct {
	Group     string `json:"group"`
	Kind      string `json:"kind"`
	Name      string `json:"name"`
	Namespace string `json:"namespace"`
}

type lifecycleV1RouteCondition struct {
	Type               string `json:"type"`
	Status             string `json:"status"`
	ObservedGeneration int64  `json:"observedGeneration"`
}

type lifecycleV1RouteParentStatus struct {
	ParentRef  lifecycleV1RouteRef         `json:"parentRef"`
	Conditions []lifecycleV1RouteCondition `json:"conditions"`
}

type lifecycleV1HTTPRoute struct {
	Metadata struct {
		Name       string `json:"name"`
		Generation int64  `json:"generation"`
	} `json:"metadata"`
	Spec struct {
		ParentRefs []lifecycleV1RouteRef `json:"parentRefs"`
		Hostnames  []string              `json:"hostnames"`
		Rules      []struct {
			Matches []struct {
				Path struct {
					Type  string `json:"type"`
					Value string `json:"value"`
				} `json:"path"`
			} `json:"matches"`
			BackendRefs []struct {
				Group string `json:"group"`
				Kind  string `json:"kind"`
				Name  string `json:"name"`
				Port  int    `json:"port"`
			} `json:"backendRefs"`
		} `json:"rules"`
	} `json:"spec"`
	Status struct {
		Parents []lifecycleV1RouteParentStatus `json:"parents"`
	} `json:"status"`
}

func (p KubectlPlatform) verifyAlertRouterServingPath(ctx context.Context, expectedHost string) error {
	body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "httproute/comma-salix", "-o", "json")
	if err != nil {
		return fmt.Errorf("inspect Alert Router HTTPRoute: %w", err)
	}
	var route lifecycleV1HTTPRoute
	if err = json.Unmarshal(body, &route); err != nil {
		return errors.New("decode Alert Router HTTPRoute")
	}
	if route.Metadata.Generation <= 0 || expectedHost == "" || !slices.Contains(route.Spec.Hostnames, expectedHost) ||
		!slices.ContainsFunc(route.Spec.ParentRefs, func(parent lifecycleV1RouteRef) bool {
			return lifecycleV1GatewayRef(parent, p.Spec.Namespace)
		}) || !lifecycleV1RouteAccepted(route, p.Spec.Namespace) {
		return errors.New("Alert Router HTTPRoute is not attached to the public Gateway at its current generation")
	}
	expectedPaths := map[string]bool{
		"/v1/events/gcp":     true,
		"/v1/events/grafana": true,
		"/v1/events/github":  true,
	}
	// Optional sources must not prevent recovery to a serving chart predating them.
	optionalPaths := map[string]bool{
		"/v1/events/runtime-storage": true,
		"/v1/events/posthog":         true,
		"/v1/events/slack":           true,
		"/v1/interactions/slack":     true,
	}
	routerRules := 0
	validRouterRule := false
	for _, rule := range route.Spec.Rules {
		referencesRouter := slices.ContainsFunc(rule.BackendRefs, func(backend struct {
			Group string `json:"group"`
			Kind  string `json:"kind"`
			Name  string `json:"name"`
			Port  int    `json:"port"`
		}) bool {
			return backend.Name == "comma-alert-router"
		})
		if !referencesRouter {
			continue
		}
		routerRules++
		if len(rule.BackendRefs) != 1 || len(rule.Matches) < len(expectedPaths) || len(rule.Matches) > len(expectedPaths)+len(optionalPaths) {
			continue
		}
		backend := rule.BackendRefs[0]
		if (backend.Group != "" || (backend.Kind != "" && backend.Kind != "Service")) || backend.Name != "comma-alert-router" || backend.Port != 80 {
			continue
		}
		paths := make(map[string]bool, len(rule.Matches))
		requiredPaths := 0
		for _, match := range rule.Matches {
			if match.Path.Type != "Exact" || (!expectedPaths[match.Path.Value] && !optionalPaths[match.Path.Value]) || paths[match.Path.Value] {
				paths = nil
				break
			}
			paths[match.Path.Value] = true
			if expectedPaths[match.Path.Value] {
				requiredPaths++
			}
		}
		if len(paths) == len(rule.Matches) && requiredPaths == len(expectedPaths) {
			validRouterRule = true
		}
	}
	if routerRules != 1 || !validRouterRule {
		return errors.New("Alert Router HTTPRoute must contain exactly one Router rule with the three required exact event paths and only the optional exact runtime-storage, posthog, Slack event, and Slack interaction paths to comma-alert-router:80")
	}

	body, err = p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "endpointslice", "-l", "kubernetes.io/service-name=comma-alert-router", "-o", "json")
	if err != nil {
		return fmt.Errorf("inspect Alert Router EndpointSlices: %w", err)
	}
	var endpoints struct {
		Items []struct {
			Endpoints []struct {
				Addresses  []string `json:"addresses"`
				Conditions struct {
					Ready *bool `json:"ready"`
				} `json:"conditions"`
			} `json:"endpoints"`
		} `json:"items"`
	}
	if err = json.Unmarshal(body, &endpoints); err != nil {
		return errors.New("decode Alert Router EndpointSlices")
	}
	for _, item := range endpoints.Items {
		for _, endpoint := range item.Endpoints {
			if endpoint.Conditions.Ready != nil && *endpoint.Conditions.Ready && len(endpoint.Addresses) > 0 {
				return nil
			}
		}
	}
	return errors.New("Alert Router Service has no ready EndpointSlice address")
}

func lifecycleV1RouteAccepted(route lifecycleV1HTTPRoute, namespace string) bool {
	return slices.ContainsFunc(route.Status.Parents, func(parent lifecycleV1RouteParentStatus) bool {
		if !lifecycleV1GatewayRef(parent.ParentRef, namespace) {
			return false
		}
		return slices.ContainsFunc(parent.Conditions, func(condition lifecycleV1RouteCondition) bool {
			return condition.Type == "Accepted" && condition.Status == "True" &&
				condition.ObservedGeneration == route.Metadata.Generation
		}) && slices.ContainsFunc(parent.Conditions, func(condition lifecycleV1RouteCondition) bool {
			return condition.Type == "ResolvedRefs" && condition.Status == "True" &&
				condition.ObservedGeneration == route.Metadata.Generation
		})
	})
}

type lifecycleV1HTTPRouteList struct {
	Items []lifecycleV1HTTPRoute `json:"items"`
}

func (p KubectlPlatform) verifyPublicIngressOwnership(ctx context.Context, host string) error {
	body, err := p.Kubectl.Run(
		ctx,
		nil,
		"-n", p.Spec.Namespace,
		"get", "httproutes",
		"-o", "json",
	)
	if err != nil {
		return fmt.Errorf("inspect public Gateway HTTPRoutes: %w", err)
	}
	var routes lifecycleV1HTTPRouteList
	if err = json.Unmarshal(body, &routes); err != nil {
		return errors.New("decode public Gateway HTTPRoutes")
	}
	gatewayRoutes := make(map[string]struct{}, 3)
	var route *lifecycleV1HTTPRoute
	for index := range routes.Items {
		candidate := &routes.Items[index]
		if !slices.ContainsFunc(candidate.Spec.ParentRefs, func(parent lifecycleV1RouteRef) bool {
			return lifecycleV1GatewayRef(parent, p.Spec.Namespace)
		}) {
			continue
		}
		gatewayRoutes[candidate.Metadata.Name] = struct{}{}
		if candidate.Metadata.Name == "comma-salix" {
			route = candidate
		}
	}
	_, hasSalix := gatewayRoutes["comma-salix"]
	_, hasSites := gatewayRoutes["comma-salix-sites"]
	_, hasTeams := gatewayRoutes["comma-teams"]
	if len(gatewayRoutes) != 3 ||
		!hasSalix || !hasSites || !hasTeams {
		observed := make([]string, 0, len(gatewayRoutes))
		for name := range gatewayRoutes {
			observed = append(observed, name)
		}
		slices.Sort(observed)
		return fmt.Errorf("public Gateway HTTPRoute set drifted: observed %v", observed)
	}
	if route == nil || route.Metadata.Generation <= 0 {
		return errors.New("public Gateway omits current comma-salix HTTPRoute")
	}
	if !slices.Contains(route.Spec.Hostnames, host) {
		return errors.New("public API HTTPRoute has the wrong host")
	}
	if !lifecycleV1RouteAccepted(*route, p.Spec.Namespace) {
		return errors.New("public API HTTPRoute is not accepted at its current generation")
	}
	return nil
}

func lifecycleV1GatewayRef(ref lifecycleV1RouteRef, namespace string) bool {
	return (ref.Group == "" || ref.Group == "gateway.networking.k8s.io") &&
		(ref.Kind == "" || ref.Kind == "Gateway") &&
		ref.Name == "comma" &&
		(ref.Namespace == "" || ref.Namespace == namespace)
}

func (p KubectlPlatform) verifyLifecycleV1ProductEndpoints(
	ctx context.Context,
	productPods []lifecycleV1ServingPod,
) error {
	if len(productPods) == 0 {
		return errors.New("lifecycle-v1 comma-product serving pod inventory is empty")
	}
	expected := make(map[string]lifecycleV1ServingPod, len(productPods))
	for _, pod := range productPods {
		if pod.Name == "" || pod.UID == "" || pod.IP == "" {
			return fmt.Errorf("lifecycle-v1 serving pod %s omits UID or IP evidence", pod.Name)
		}
		expected[pod.Name] = pod
	}
	body, err := p.Kubectl.Run(
		ctx,
		nil,
		"-n", p.Spec.Namespace,
		"get", "endpointslice",
		"-l", "kubernetes.io/service-name=comma-product",
		"-o", "json",
	)
	if err != nil {
		return fmt.Errorf("inspect lifecycle-v1 comma-product EndpointSlices: %w", err)
	}
	var list struct {
		Items []struct {
			Endpoints []struct {
				Addresses  []string `json:"addresses"`
				Conditions struct {
					Ready       *bool `json:"ready"`
					Serving     *bool `json:"serving"`
					Terminating *bool `json:"terminating"`
				} `json:"conditions"`
				TargetRef struct {
					Kind string `json:"kind"`
					Name string `json:"name"`
					UID  string `json:"uid"`
				} `json:"targetRef"`
			} `json:"endpoints"`
		} `json:"items"`
	}
	if err = json.Unmarshal(body, &list); err != nil {
		return errors.New("decode lifecycle-v1 comma-product EndpointSlices")
	}
	seen := make(map[string]bool, len(expected))
	for _, item := range list.Items {
		for _, endpoint := range item.Endpoints {
			ready := endpoint.Conditions.Ready != nil && *endpoint.Conditions.Ready &&
				(endpoint.Conditions.Serving == nil || *endpoint.Conditions.Serving) &&
				(endpoint.Conditions.Terminating == nil || !*endpoint.Conditions.Terminating)
			if !ready {
				continue
			}
			pod, ok := expected[endpoint.TargetRef.Name]
			if !ok || (endpoint.TargetRef.Kind != "" && endpoint.TargetRef.Kind != "Pod") ||
				endpoint.TargetRef.UID != pod.UID ||
				!slices.Contains(endpoint.Addresses, pod.IP) ||
				seen[pod.Name] {
				return fmt.Errorf(
					"ready comma-product endpoint %s is not an exact lifecycle-v1 candidate pod",
					endpoint.TargetRef.Name,
				)
			}
			seen[pod.Name] = true
		}
	}
	if len(seen) != len(expected) {
		return fmt.Errorf(
			"comma-product has %d lifecycle-v1 ready endpoints, expected %d",
			len(seen),
			len(expected),
		)
	}
	return nil
}

func (p KubectlPlatform) runLifecycleV1Probe(
	ctx context.Context,
	probeURL string,
	headers []string,
	wantStatus int,
	wantBody map[string]any,
) error {
	args := []string{
		"--disable",
		"--silent",
		"--show-error",
		"--max-time", "10",
		"--proto", "=https",
		"--request", "GET",
		"--include",
		"--output", "-",
		"--write-out", lifecycleV1ProbeStatusMarker + "%{response_code}",
	}
	for _, header := range headers {
		args = append(args, "--header", header)
	}
	args = append(args, probeURL)
	output, err := p.Curl.Run(ctx, nil, args...)
	if err != nil {
		return err
	}
	response, err := parseLifecycleV1ProbeResponse(output)
	if err != nil {
		return err
	}
	if response.Status != wantStatus {
		return fmt.Errorf("status %d, expected %d", response.Status, wantStatus)
	}
	if !slices.ContainsFunc(response.Headers["content-type"], func(value string) bool {
		return strings.HasPrefix(strings.ToLower(value), "application/json")
	}) {
		return errors.New("response is not application/json")
	}
	if !slices.ContainsFunc(response.Headers["cache-control"], func(value string) bool {
		for _, directive := range strings.Split(value, ",") {
			if strings.EqualFold(strings.TrimSpace(directive), "no-store") {
				return true
			}
		}
		return false
	}) {
		return errors.New("response omits Cache-Control: no-store")
	}
	if len(response.Headers["set-cookie"]) != 0 {
		return errors.New("response attempted to mutate a cookie")
	}
	var gotBody any
	decoder := json.NewDecoder(strings.NewReader(response.Body))
	if err = decoder.Decode(&gotBody); err != nil {
		return errors.New("response body is not JSON")
	}
	if err = decoder.Decode(&struct{}{}); !errors.Is(err, io.EOF) {
		return errors.New("response body contains trailing JSON data")
	}
	gotCanonical, _ := json.Marshal(gotBody)
	wantCanonical, _ := json.Marshal(wantBody)
	if !bytes.Equal(gotCanonical, wantCanonical) {
		return errors.New("response body does not match the token-free lifecycle-v1 contract")
	}
	return nil
}

type lifecycleV1ProbeResponse struct {
	Status  int
	Headers map[string][]string
	Body    string
}

func parseLifecycleV1ProbeResponse(output []byte) (lifecycleV1ProbeResponse, error) {
	marker := []byte(lifecycleV1ProbeStatusMarker)
	markerAt := bytes.LastIndex(output, marker)
	if markerAt < 0 {
		return lifecycleV1ProbeResponse{}, errors.New("curl response omits lifecycle-v1 status evidence")
	}
	curlStatus, err := strconv.Atoi(strings.TrimSpace(string(output[markerAt+len(marker):])))
	if err != nil || curlStatus < 100 || curlStatus > 599 {
		return lifecycleV1ProbeResponse{}, errors.New("curl response has invalid lifecycle-v1 status evidence")
	}
	payload := strings.ReplaceAll(string(output[:markerAt]), "\r\n", "\n")
	for {
		if !strings.HasPrefix(payload, "HTTP/") {
			return lifecycleV1ProbeResponse{}, errors.New("curl response omits HTTP response headers")
		}
		headerEnd := strings.Index(payload, "\n\n")
		if headerEnd < 0 {
			return lifecycleV1ProbeResponse{}, errors.New("curl response has incomplete HTTP response headers")
		}
		headerBlock := payload[:headerEnd]
		payload = payload[headerEnd+2:]
		lines := strings.Split(headerBlock, "\n")
		statusFields := strings.Fields(lines[0])
		if len(statusFields) < 2 {
			return lifecycleV1ProbeResponse{}, errors.New("curl response has invalid HTTP status line")
		}
		headerStatus, parseErr := strconv.Atoi(statusFields[1])
		if parseErr != nil {
			return lifecycleV1ProbeResponse{}, errors.New("curl response has invalid HTTP status line")
		}
		intermediate := headerStatus >= 100 && headerStatus < 200
		connectTunnel := headerStatus == 200 &&
			strings.Contains(strings.ToLower(lines[0]), "connection established")
		if intermediate || connectTunnel {
			continue
		}
		if headerStatus != curlStatus {
			return lifecycleV1ProbeResponse{}, errors.New("curl and HTTP status evidence disagree")
		}
		headers := make(map[string][]string)
		for _, line := range lines[1:] {
			name, value, found := strings.Cut(line, ":")
			if !found {
				return lifecycleV1ProbeResponse{}, errors.New("curl response has malformed HTTP headers")
			}
			name = strings.ToLower(strings.TrimSpace(name))
			headers[name] = append(headers[name], strings.TrimSpace(value))
		}
		return lifecycleV1ProbeResponse{
			Status:  headerStatus,
			Headers: headers,
			Body:    payload,
		}, nil
	}
}

var cloudSQLInstanceConnectionNamePattern = regexp.MustCompile(`^[a-z][a-z0-9-]{4,28}[a-z0-9]:[a-z][a-z0-9-]*:[a-z][a-z0-9-]*$`)

type terminalContainerShape struct {
	Name string   `json:"name"`
	Args []string `json:"args"`
	Env  []struct {
		Name string `json:"name"`
	} `json:"env"`
	VolumeMounts []struct {
		Name      string `json:"name"`
		MountPath string `json:"mountPath"`
	} `json:"volumeMounts"`
}

type terminalPodShape struct {
	InitContainers []terminalContainerShape `json:"initContainers"`
	Containers     []terminalContainerShape `json:"containers"`
	Volumes        []struct {
		Name string `json:"name"`
	} `json:"volumes"`
}

func (p KubectlPlatform) verifyTerminalWorkloadShape(ctx context.Context) error {
	for _, resource := range []string{"statefulset/comma"} {
		body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", resource, "-o", "json")
		if err != nil {
			return fmt.Errorf("inspect terminal workload %s: %w", resource, err)
		}
		var controller struct {
			Spec struct {
				Template struct {
					Spec terminalPodShape `json:"spec"`
				} `json:"template"`
			} `json:"spec"`
		}
		if err = json.Unmarshal(body, &controller); err != nil {
			return fmt.Errorf("decode terminal workload %s: %w", resource, err)
		}
		if err = validateTerminalPodShape(resource, controller.Spec.Template.Spec); err != nil {
			return err
		}
	}
	for _, inventory := range []struct {
		selector string
		resource string
	}{
		{selector: "app.kubernetes.io/name=comma", resource: "statefulset/comma"},
	} {
		body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "pods", "-l", inventory.selector, "-o", "json")
		if err != nil {
			return fmt.Errorf("inspect terminal pods for %s: %w", inventory.selector, err)
		}
		var pods struct {
			Items []struct {
				Metadata struct {
					Name string `json:"name"`
				} `json:"metadata"`
				Spec terminalPodShape `json:"spec"`
			} `json:"items"`
		}
		if err = json.Unmarshal(body, &pods); err != nil {
			return fmt.Errorf("terminal pod inventory for %s is invalid", inventory.selector)
		}
		if len(pods.Items) == 0 {
			replicas, replicaErr := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", inventory.resource, "-o", "jsonpath={.spec.replicas}")
			if replicaErr != nil || strings.TrimSpace(string(replicas)) != "0" {
				return fmt.Errorf("terminal pod inventory for %s is empty while %s is not scaled to zero", inventory.selector, inventory.resource)
			}
			continue
		}
		for _, pod := range pods.Items {
			if err = validateTerminalPodShape("pod/"+pod.Metadata.Name, pod.Spec); err != nil {
				return err
			}
		}
	}
	return nil
}

func (p KubectlPlatform) verifyAlertRouterTerminalWorkloadShape(ctx context.Context) error {
	const resource = "deployment/comma-alert-router"
	body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", resource, "-o", "json")
	if err != nil {
		return fmt.Errorf("inspect terminal workload %s: %w", resource, err)
	}
	var controller struct {
		Spec struct {
			Template struct {
				Spec terminalPodShape `json:"spec"`
			} `json:"template"`
		} `json:"spec"`
	}
	if err = json.Unmarshal(body, &controller); err != nil {
		return fmt.Errorf("decode terminal workload %s: %w", resource, err)
	}
	return validateTerminalPodShape(resource, controller.Spec.Template.Spec)
}

func validateTerminalPodShape(resource string, spec terminalPodShape) error {
	for _, container := range spec.InitContainers {
		if container.Name == "comma-system-files" {
			return fmt.Errorf("%s retains retired comma-system-files init container", resource)
		}
	}
	for _, volume := range spec.Volumes {
		if volume.Name == "comma-system-files" || volume.Name == "comma-system-files-archive" {
			return fmt.Errorf("%s retains retired %s volume", resource, volume.Name)
		}
	}
	proxyFound := false
	for _, container := range append(spec.InitContainers, spec.Containers...) {
		for _, mount := range container.VolumeMounts {
			if mount.Name == "comma-system-files" || mount.Name == "comma-system-files-archive" || mount.MountPath == "/etc/salix-system" {
				return fmt.Errorf("%s retains retired system-files mount %s", resource, mount.MountPath)
			}
		}
		if container.Name != "cloud-sql-proxy" {
			continue
		}
		proxyFound = true
		for _, env := range container.Env {
			if env.Name == "INSTANCE_CONNECTION_NAME" {
				return fmt.Errorf("%s retains retired Cloud SQL INSTANCE_CONNECTION_NAME environment source", resource)
			}
		}
		if len(container.Args) == 0 || !cloudSQLInstanceConnectionNamePattern.MatchString(container.Args[len(container.Args)-1]) {
			return fmt.Errorf("%s Cloud SQL proxy omits the terminal direct instance argument", resource)
		}
	}
	if !proxyFound {
		return fmt.Errorf("%s omits the Cloud SQL proxy", resource)
	}
	return nil
}

func (p KubectlPlatform) verifyOrdinal(ctx context.Context, ordinal string, services []string) error {
	pod := "comma-" + ordinal
	if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "wait", "--for=condition=Ready", "pod/"+pod, "--timeout=5m"); err != nil {
		return err
	}
	poll := p.Poll
	if poll <= 0 {
		poll = 20 * time.Second
	}
	deadline, cancel := context.WithTimeout(ctx, 5*time.Minute)
	defer cancel()
	consecutive := 0
	var lastErr error
	for {
		if err := p.verifyOrdinalOnce(deadline, pod, services); err == nil {
			consecutive++
			if consecutive == 2 {
				return nil
			}
		} else {
			consecutive = 0
			lastErr = err
		}
		select {
		case <-deadline.Done():
			return fmt.Errorf("%s did not reach two consecutive health checks: %w", pod, lastErr)
		case <-time.After(poll):
		}
	}
}

func (p KubectlPlatform) verifyOrdinalOnce(ctx context.Context, pod string, services []string) error {
	ip, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "pod/"+pod, "-o", "jsonpath={.status.podIP}")
	if err != nil || len(ip) == 0 {
		return fmt.Errorf("cannot resolve %s pod IP: %w", pod, err)
	}
	for _, service := range services {
		body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "endpointslice", "-l", "kubernetes.io/service-name="+service, "-o", "json")
		if err != nil {
			return err
		}
		if !endpointReady(body, pod, string(ip)) {
			return fmt.Errorf("%s missing from ready EndpointSlice %s", pod, service)
		}
	}
	for _, host := range p.Spec.PublicHosts {
		if _, err := p.Curl.Run(ctx, nil, "-fsS", "--max-time", "10", "https://"+host+"/ready"); err != nil {
			return err
		}
	}
	return p.verifyBackends(ctx, pod, string(ip), services)
}

func (p KubectlPlatform) verifyBackends(ctx context.Context, pod, ip string, services []string) error {
	list, err := p.Gcloud.Run(ctx, nil, "compute", "backend-services", "list", "--project", p.Spec.Project, "--regions", p.Spec.Location, "--format=value(name)")
	if err != nil {
		return err
	}
	for _, service := range services {
		var match string
		for _, name := range strings.Fields(string(list)) {
			if strings.Contains(name, "-"+p.Spec.Namespace+"-"+service+"-80-") {
				if match != "" {
					return fmt.Errorf("multiple backend services for %s", service)
				}
				match = name
			}
		}
		if match == "" {
			return fmt.Errorf("backend service missing for %s", service)
		}
		health, err := p.Gcloud.Run(ctx, nil, "compute", "backend-services", "get-health", match, "--project", p.Spec.Project, "--region", p.Spec.Location, "--format=json")
		if err != nil {
			return err
		}
		if !backendHealthy(health, ip) {
			return fmt.Errorf("%s is not healthy in %s", pod, service)
		}
	}
	return nil
}

func endpointReady(body []byte, pod, ip string) bool {
	var list struct {
		Items []struct {
			Endpoints []struct {
				Addresses  []string `json:"addresses"`
				Conditions struct {
					Ready       *bool `json:"ready"`
					Serving     *bool `json:"serving"`
					Terminating *bool `json:"terminating"`
				} `json:"conditions"`
				TargetRef struct {
					Name string `json:"name"`
				} `json:"targetRef"`
			} `json:"endpoints"`
		} `json:"items"`
	}
	if json.Unmarshal(body, &list) != nil {
		return false
	}
	for _, item := range list.Items {
		for _, endpoint := range item.Endpoints {
			if endpoint.TargetRef.Name == pod && slices.Contains(endpoint.Addresses, ip) && endpoint.Conditions.Ready != nil && *endpoint.Conditions.Ready && (endpoint.Conditions.Serving == nil || *endpoint.Conditions.Serving) && (endpoint.Conditions.Terminating == nil || !*endpoint.Conditions.Terminating) {
				return true
			}
		}
	}
	return false
}

func backendHealthy(body []byte, ip string) bool {
	var value any
	if json.Unmarshal(body, &value) != nil {
		return false
	}
	var walk func(any) bool
	walk = func(current any) bool {
		switch typed := current.(type) {
		case map[string]any:
			if typed["ipAddress"] == ip && typed["healthState"] == "HEALTHY" {
				return true
			}
			for _, child := range typed {
				if walk(child) {
					return true
				}
			}
		case []any:
			for _, child := range typed {
				if walk(child) {
					return true
				}
			}
		}
		return false
	}
	return walk(value)
}

func (p KubectlPlatform) Restore(ctx context.Context, state State) error {
	target := state.Helm.SnapshotRevision
	if state.CutoverMayHaveStarted {
		target = state.Helm.MaintenanceRevision
	}
	if target <= 0 {
		return errors.New("no known Helm revision is available for recovery")
	}
	if _, err := p.Helm.Rollback(ctx, target, RollbackAuthorization{ReleaseID: state.ReleaseID, ExpectedRelease: state.ReleaseID, Allowed: true}); err != nil {
		return err
	}
	if state.CutoverMayHaveStarted {
		if err := p.waitForWriterAbsence(ctx); err != nil {
			return fmt.Errorf("maintenance workload remained after rollback: %w", err)
		}
		if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "rollout", "status", "deployment/comma-otel-collector", "--timeout=15m"); err != nil {
			return fmt.Errorf("maintenance diagnostics did not become ready: %w", err)
		}
		return nil
	}
	for _, resource := range []string{"deployment/comma-otel-collector", "statefulset/comma"} {
		if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "rollout", "status", resource, "--timeout=15m"); err != nil {
			return fmt.Errorf("restored %s did not become ready: %w", resource, err)
		}
	}
	if _, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "deployment/comma-alert-router", "-o", "name"); err == nil {
		if _, err = p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "rollout", "status", "deployment/comma-alert-router", "--timeout=15m"); err != nil {
			return fmt.Errorf("restored deployment/comma-alert-router did not become ready: %w", err)
		}
		if err = p.verifyAlertRouterTerminalWorkloadShape(ctx); err != nil {
			return err
		}
		expectedHost, hostErr := p.restoredPublicAPIHost(ctx)
		if hostErr != nil {
			return fmt.Errorf("inspect restored Alert Router public host: %w", hostErr)
		}
		if err = p.verifyAlertRouterServingPath(ctx, expectedHost); err != nil {
			return fmt.Errorf("restored Alert Router serving path is not ready: %w", err)
		}
	} else if !containsNotFound(err.Error()) {
		return fmt.Errorf("inspect restored Alert Router workload: %w", err)
	}
	return nil
}

func (p KubectlPlatform) restoredPublicAPIHost(ctx context.Context) (string, error) {
	body, err := p.Helm.GetValues(ctx)
	if err != nil {
		return "", err
	}
	var values struct {
		Network struct {
			SalixHost string `json:"salixHost"`
		} `json:"network"`
	}
	if err = json.Unmarshal(body, &values); err != nil || strings.TrimSpace(values.Network.SalixHost) == "" {
		return "", errors.New("restored Helm values omit network.salixHost")
	}
	return values.Network.SalixHost, nil
}

func (p KubectlPlatform) helmUpgrade(ctx context.Context, state State, maintenance bool, partition int) (HelmRevision, error) {
	valuesBody := p.HelmValues
	if len(valuesBody) == 0 {
		replacements, err := p.bundleReplacements(ctx, state.BundleName)
		if err != nil {
			return HelmRevision{}, err
		}
		valuesBody, err = p.buildHelmValues(replacements)
		if err != nil {
			return HelmRevision{}, err
		}
	}
	var values map[string]any
	if err := json.Unmarshal(valuesBody, &values); err != nil {
		return HelmRevision{}, errors.New("invalid deterministic Helm values")
	}
	values["maintenance"] = map[string]any{"enabled": maintenance}
	rollout, ok := values["rollout"].(map[string]any)
	if !ok {
		return HelmRevision{}, errors.New("deterministic Helm values omit rollout")
	}
	rollout["partition"] = partition
	body, err := json.Marshal(values)
	if err != nil {
		return HelmRevision{}, err
	}
	adapter := p.Helm
	adapter.ValuesPath = ""
	adapter.ValuesJSON = body
	return adapter.Upgrade(ctx, HelmUpgradeOptions{})
}

func (p KubectlPlatform) buildHelmValues(replacements map[string]string) ([]byte, error) {
	required := func(name string) (string, error) {
		value := replacements[name]
		if value == "" {
			return "", fmt.Errorf("candidate bundle omits Helm value %s", name)
		}
		return value, nil
	}
	keys := []string{"COMMA_IMAGE", "COMMA_REVISION", "COMMA_REVISION_LABEL", "COMMA_TRACE_SAMPLE_RATIO",
		"COMMA_LEGACY_MESSAGE_EVENT_CLAIM_WRITER_FENCE_EPOCH", "SALIX_CONFIG_SHA256",
		"COMMA_SECRETS_NAME", "INSTANCE_CONNECTION_NAME", "SALIX_CONFIG_SECRET_NAME",
		"SALIX_TLS_SECRET_NAME", "SALIX_SITES_TLS_SECRET_NAME", "TEAMS_TLS_SECRET_NAME", "COMMA_STATIC_IP",
		"SALIX_HOST", "SALIX_SITES_DOMAIN", "BRIDGE_HOST"}
	for _, key := range keys {
		if _, err := required(key); err != nil {
			return nil, err
		}
	}
	runtimeServiceAccount := p.Spec.RuntimeServiceAccount
	if runtimeServiceAccount == "" {
		return nil, errors.New("release environment omits the runtime service account (COMMA_RUNTIME_SERVICE_ACCOUNT)")
	}
	alertRouterEnabled, _, err := alertRouterSelection(replacements)
	if err != nil {
		return nil, err
	}
	alertRouterConfigSecret := replacements["ALERT_ROUTER_CONFIG_SECRET_NAME"]
	alertRouterChecksum := replacements["ALERT_ROUTER_CONFIG_SHA256"]
	if alertRouterEnabled {
		if alertRouterConfigSecret == "" {
			return nil, errors.New("candidate bundle omits Helm value ALERT_ROUTER_CONFIG_SECRET_NAME")
		}
		if alertRouterChecksum == "" {
			return nil, errors.New("candidate bundle omits Helm value ALERT_ROUTER_CONFIG_SHA256")
		}
	} else {
		alertRouterConfigSecret = replacements["SALIX_CONFIG_SECRET_NAME"]
		alertRouterChecksum = replacements["SALIX_CONFIG_SHA256"]
	}
	values := map[string]any{
		"environment": p.Spec.Environment, "cluster": p.Spec.Cluster, "project": p.Spec.Project,
		"serviceAccount": map[string]any{"gcpServiceAccount": runtimeServiceAccount, "releaseObserver": p.Spec.ReleaseObserverServiceAccount},
		"image":          map[string]any{"reference": replacements["COMMA_IMAGE"], "revision": replacements["COMMA_REVISION"], "revisionLabel": replacements["COMMA_REVISION_LABEL"]},
		"rollout":        map[string]any{"partition": 1, "historyMax": 10, "timeoutSeconds": 1200},
		"maintenance":    map[string]any{"enabled": false},
		"workloads":      map[string]any{"commaReplicas": 2, "collectorReplicas": 2},
		"alertRouter":    map[string]any{"enabled": alertRouterEnabled, "replicas": 2},
		"runtime":        map[string]any{"traceSampleRatio": replacements["COMMA_TRACE_SAMPLE_RATIO"], "claimWriterFenceEpoch": replacements["COMMA_LEGACY_MESSAGE_EVENT_CLAIM_WRITER_FENCE_EPOCH"], "cloudSqlInstanceConnectionName": replacements["INSTANCE_CONNECTION_NAME"], "agentVmmGatewayEnabled": p.Spec.AgentVmmGatewayEnabled, "computeRuntimeBaseURL": p.Spec.ComputeRuntimeBaseURL},
		"config":         map[string]any{"salixChecksum": replacements["SALIX_CONFIG_SHA256"], "alertRouterChecksum": alertRouterChecksum},
		"references":     map[string]any{"commaSecrets": replacements["COMMA_SECRETS_NAME"], "salixConfigSecret": replacements["SALIX_CONFIG_SECRET_NAME"], "alertRouterConfigSecret": alertRouterConfigSecret, "agentVmmGatewayRuntimeSecret": "salix-vmm-gateway-runtime", "agentVmmGatewayClientTlsSecret": "salix-vmm-gateway-client-tls", "computeWorkloadCredentialSecret": "salix-compute-runtime", "salixTlsSecret": replacements["SALIX_TLS_SECRET_NAME"], "salixSitesTlsSecret": replacements["SALIX_SITES_TLS_SECRET_NAME"], "teamsTlsSecret": replacements["TEAMS_TLS_SECRET_NAME"]},
		"ssh":            map[string]any{"enabled": p.Spec.SSHEnabled},
		"network":        map[string]any{"staticIpName": replacements["COMMA_STATIC_IP"], "salixHost": replacements["SALIX_HOST"], "salixSitesDomain": replacements["SALIX_SITES_DOMAIN"], "bridgeHost": replacements["BRIDGE_HOST"]},
	}
	return json.Marshal(values)
}

func (p KubectlPlatform) Cleanup(ctx context.Context, state State) error {
	if err := p.deleteTerminalJobs(ctx); err != nil {
		return err
	}
	replacements, err := p.bundleReplacements(ctx, state.BundleName)
	if err != nil {
		return err
	}
	keep := map[string]bool{state.BundleName: true}
	for _, name := range replacements {
		keep[name] = true
	}
	for _, query := range []struct{ resources, label string }{
		{"secret", "app.kubernetes.io/name=comma-release-candidate"},
		{"configmap", "app.kubernetes.io/name=comma-release-bundle"},
	} {
		body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", query.resources, "-l", query.label, "-o", "json")
		if err != nil {
			return err
		}
		var list struct {
			Items []struct {
				Kind     string `json:"kind"`
				Metadata struct {
					Name string `json:"name"`
				} `json:"metadata"`
			} `json:"items"`
		}
		if err = json.Unmarshal(body, &list); err != nil {
			return err
		}
		for _, item := range list.Items {
			if keep[item.Metadata.Name] {
				continue
			}
			resource := strings.ToLower(item.Kind) + "/" + item.Metadata.Name
			if _, err = p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "delete", resource, "--ignore-not-found=true"); err != nil {
				return err
			}
		}
	}
	return nil
}

func (p KubectlPlatform) deleteTerminalJobs(ctx context.Context) error {
	body, err := p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "get", "job", "-l", "app.kubernetes.io/name=comma-release", "-o", "json")
	if err != nil {
		return err
	}
	var list struct {
		Items []struct {
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
			Status struct {
				Conditions []struct {
					Type   string `json:"type"`
					Status string `json:"status"`
				} `json:"conditions"`
			} `json:"status"`
		} `json:"items"`
	}
	if err = json.Unmarshal(body, &list); err != nil {
		return err
	}
	for _, item := range list.Items {
		terminal := slices.ContainsFunc(item.Status.Conditions, func(condition struct {
			Type   string `json:"type"`
			Status string `json:"status"`
		}) bool {
			return condition.Status == "True" && (condition.Type == "Complete" || condition.Type == "Failed")
		})
		if !terminal {
			continue
		}
		if _, err = p.Kubectl.Run(ctx, nil, "-n", p.Spec.Namespace, "delete", "job/"+item.Metadata.Name, "--ignore-not-found=true"); err != nil {
			return err
		}
	}
	return nil
}

// LoadEnvironmentSpec overlays the live provider resource names, which the
// versioned spec does not carry, from the release environment configuration.
func LoadEnvironmentSpec(spec *EnvironmentSpec, getenv func(string) string) error {
	spec.ReleaseObserverServiceAccount = getenv("COMMA_RELEASE_OBSERVER_SERVICE_ACCOUNT")
	fields := []struct {
		name string
		dst  *string
	}{
		{"COMMA_GCP_PROJECT", &spec.Project},
		{"COMMA_GKE_CLUSTER", &spec.Cluster},
		{"COMMA_RUNTIME_SERVICE_ACCOUNT", &spec.RuntimeServiceAccount},
		{"COMMA_REDIS_SECRET_NAME", &spec.RedisSecret},
		{"COMMA_OAUTH_IDP_SECRET_NAME", &spec.OAuthIdpSecret},
	}
	for _, field := range fields {
		value := getenv(field.name)
		if value == "" {
			if field.name == "COMMA_OAUTH_IDP_SECRET_NAME" && spec.OauthIdp != "enabled" {
				continue
			}
			return fmt.Errorf("release environment configuration %s is required", field.name)
		}
		*field.dst = value
	}
	return nil
}
