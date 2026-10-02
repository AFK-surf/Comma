package release

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"time"
)

const DefaultHelmHistoryMax = 10

type HelmAdapter struct {
	Runner     Runner
	Release    string
	Namespace  string
	Chart      string
	ValuesPath string
	ValuesJSON []byte
	Timeout    time.Duration
	HistoryMax int
}

type HelmRevision struct {
	Revision int    `json:"revision"`
	Status   string `json:"status"`
}

type HelmUpgradeOptions struct {
	DryRunServer bool
	DeferWait    bool
}

type RollbackAuthorization struct {
	ReleaseID       string
	ExpectedRelease string
	Allowed         bool
}

type OCIArtifact struct {
	Reference string `json:"reference"`
	Digest    string `json:"digest"`
}

func (h HelmAdapter) Upgrade(ctx context.Context, options HelmUpgradeOptions) (HelmRevision, error) {
	if h.Release == "" || h.Namespace == "" || h.Chart == "" || (h.ValuesPath == "" && len(h.ValuesJSON) == 0) {
		return HelmRevision{}, errors.New("helm release, namespace, chart, and complete values path are required")
	}
	if strings.HasPrefix(h.Chart, "oci://") {
		if _, err := OCIChartDigest(h.Chart); err != nil {
			return HelmRevision{}, err
		}
	}
	historyMax := h.HistoryMax
	if historyMax == 0 {
		historyMax = DefaultHelmHistoryMax
	}
	if historyMax < 2 || historyMax > 50 {
		return HelmRevision{}, errors.New("helm history max must be between 2 and 50")
	}
	timeout := h.Timeout
	if timeout == 0 {
		timeout = 20 * time.Minute
	}
	args := []string{"upgrade", h.Release, h.Chart,
		"--namespace", h.Namespace, "--reset-values",
		"--history-max", strconv.Itoa(historyMax), "--timeout", timeout.String()}
	if !options.DeferWait {
		args = append(args, "--wait=watcher")
	}
	args = append(args, "--server-side=true", "--force-conflicts")
	input := h.ValuesJSON
	if len(input) > 0 {
		args = append(args, "--values", "-")
	} else {
		args = append(args, "--values", h.ValuesPath)
	}
	if options.DryRunServer {
		args = append(args, "--dry-run=server", "--hide-secret")
	}
	if _, err := h.runInput(ctx, input, args...); err != nil {
		return HelmRevision{}, err
	}
	if options.DryRunServer {
		return HelmRevision{}, nil
	}
	return h.Status(ctx)
}

func (h HelmAdapter) Status(ctx context.Context) (HelmRevision, error) {
	body, err := h.run(ctx, "status", h.Release, "--namespace", h.Namespace, "--output", "json")
	if err != nil {
		return HelmRevision{}, err
	}
	var value struct {
		Revision int    `json:"version"`
		Status   string `json:"status"`
		Info     struct {
			Status string `json:"status"`
		} `json:"info"`
	}
	if err = json.Unmarshal(body, &value); err != nil || value.Revision <= 0 {
		return HelmRevision{}, errors.New("invalid helm status output")
	}
	if value.Status == "" {
		value.Status = value.Info.Status
	}
	return HelmRevision{Revision: value.Revision, Status: value.Status}, nil
}

func (h HelmAdapter) History(ctx context.Context) ([]HelmRevision, error) {
	body, err := h.run(ctx, "history", h.Release, "--namespace", h.Namespace, "--max", strconv.Itoa(DefaultHelmHistoryMax), "--output", "json")
	if err != nil {
		return nil, err
	}
	var raw []struct {
		Revision json.RawMessage `json:"revision"`
		Status   string          `json:"status"`
	}
	if err = json.Unmarshal(body, &raw); err != nil {
		return nil, err
	}
	result := make([]HelmRevision, 0, len(raw))
	for _, item := range raw {
		text := strings.Trim(string(item.Revision), `"`)
		revision, parseErr := strconv.Atoi(text)
		if parseErr != nil || revision <= 0 {
			return nil, errors.New("invalid helm history revision")
		}
		result = append(result, HelmRevision{Revision: revision, Status: item.Status})
	}
	return result, nil
}

func (h HelmAdapter) Rollback(ctx context.Context, revision int, authorization RollbackAuthorization) (HelmRevision, error) {
	if revision <= 0 || !authorization.Allowed || authorization.ReleaseID == "" || authorization.ReleaseID != authorization.ExpectedRelease {
		return HelmRevision{}, errors.New("helm rollback requires matching release-fence authorization")
	}
	timeout := h.Timeout
	if timeout == 0 {
		timeout = 20 * time.Minute
	}
	if _, err := h.run(ctx, "rollback", h.Release, strconv.Itoa(revision), "--namespace", h.Namespace, "--timeout", timeout.String(), "--wait=watcher"); err != nil {
		return HelmRevision{}, err
	}
	return h.Status(ctx)
}

func (h HelmAdapter) GetManifest(ctx context.Context) ([]byte, error) {
	return h.run(ctx, "get", "manifest", h.Release, "--namespace", h.Namespace)
}

func (h HelmAdapter) GetValues(ctx context.Context) ([]byte, error) {
	return h.run(ctx, "get", "values", h.Release, "--namespace", h.Namespace, "--output", "json")
}

// PackageOCI packages the application chart without publishing it. The
// resulting archive is an intermediate; deployment identity is established by
// PushOCI's registry-reported digest.
func (h HelmAdapter) PackageOCI(ctx context.Context, destination string) (string, error) {
	if h.Chart == "" || destination == "" {
		return "", errors.New("chart and package destination are required")
	}
	body, err := h.run(ctx, "package", h.Chart, "--destination", destination)
	if err != nil {
		return "", err
	}
	const marker = "Successfully packaged chart and saved it to: "
	for _, line := range strings.Split(string(body), "\n") {
		if strings.HasPrefix(line, marker) {
			path := strings.TrimSpace(strings.TrimPrefix(line, marker))
			if path != "" {
				return path, nil
			}
		}
	}
	return "", errors.New("helm package did not report the archive path")
}

// PushOCI publishes an archive and returns the immutable registry identity.
// plainHTTP is restricted to disposable local-registry validation.
func (h HelmAdapter) PushOCI(ctx context.Context, archive, registry string, plainHTTP bool) (OCIArtifact, error) {
	if archive == "" || !strings.HasPrefix(registry, "oci://") || strings.Contains(registry, "@") {
		return OCIArtifact{}, errors.New("archive and tag-free OCI registry are required")
	}
	args := []string{"push", archive, registry}
	if plainHTTP {
		args = append(args, "--plain-http")
	}
	body, err := h.run(ctx, args...)
	if err != nil {
		return OCIArtifact{}, err
	}
	artifact := OCIArtifact{}
	for _, line := range strings.Split(string(body), "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "Pushed: ") {
			artifact.Reference = strings.TrimSpace(strings.TrimPrefix(line, "Pushed: "))
		}
		if strings.HasPrefix(line, "Digest: ") {
			artifact.Digest = strings.TrimSpace(strings.TrimPrefix(line, "Digest: "))
		}
	}
	if artifact.Reference == "" || !validSHA256Digest(artifact.Digest) {
		return OCIArtifact{}, errors.New("helm push did not report a valid OCI reference and digest")
	}
	repository := strings.TrimPrefix(artifact.Reference, "oci://")
	lastSlash := strings.LastIndex(repository, "/")
	if tag := strings.LastIndex(repository, ":"); tag > lastSlash {
		repository = repository[:tag]
	}
	artifact.Reference = repository + "@" + artifact.Digest
	return artifact, nil
}

func (h HelmAdapter) PullOCIByDigest(ctx context.Context, reference, destination string, plainHTTP bool) error {
	if _, err := OCIChartDigest(reference); err != nil || destination == "" {
		return errors.New("OCI pull requires a sha256 digest reference and destination")
	}
	args := []string{"pull", reference, "--destination", destination}
	if plainHTTP {
		args = append(args, "--plain-http")
	}
	_, err := h.run(ctx, args...)
	return err
}

// OCIChartDigest validates the immutable deployment reference and returns the
// registry digest recorded in durable release state. Tags are intentionally
// rejected even when accompanied by a digest so one canonical identity flows
// from the release workflow through Helm and recovery.
func OCIChartDigest(reference string) (string, error) {
	if !strings.HasPrefix(reference, "oci://") || strings.Count(reference, "@") != 1 {
		return "", errors.New("OCI chart reference must be pinned by digest")
	}
	repository, digest, found := strings.Cut(reference, "@")
	if !found || repository == "oci://" || !validSHA256Digest(digest) {
		return "", errors.New("OCI chart reference must be pinned by digest")
	}
	leaf := repository[strings.LastIndex(repository, "/")+1:]
	if leaf == "" || strings.Contains(leaf, ":") {
		return "", errors.New("OCI chart reference must not include a tag")
	}
	return digest, nil
}

func validSHA256Digest(value string) bool {
	if !strings.HasPrefix(value, "sha256:") || len(value) != len("sha256:")+64 {
		return false
	}
	for _, char := range strings.TrimPrefix(value, "sha256:") {
		if !strings.ContainsRune("0123456789abcdef", char) {
			return false
		}
	}
	return true
}

func (h HelmAdapter) run(ctx context.Context, args ...string) ([]byte, error) {
	return h.runInput(ctx, nil, args...)
}

func (h HelmAdapter) runInput(ctx context.Context, input []byte, args ...string) ([]byte, error) {
	for _, arg := range args {
		if arg == "--install" || arg == "--reuse-values" || arg == "--reset-then-reuse-values" || arg == "--atomic" || arg == "--rollback-on-failure" {
			return nil, fmt.Errorf("forbidden helm argument %q", arg)
		}
	}
	if h.Runner == nil {
		return nil, errors.New("helm runner is required")
	}
	return h.Runner.Run(ctx, input, args...)
}
