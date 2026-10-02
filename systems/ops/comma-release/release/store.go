package release

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"regexp"
)

var ErrNotFound = errors.New("not found")
var ErrConflict = errors.New("conflict")

type Record struct {
	State   State
	Version string
}

type StateStore interface {
	Load(context.Context) (Record, error)
	Create(context.Context, State) (Record, error)
	Update(context.Context, Record) (Record, error)
	Archive(context.Context, State) error
	Archived(context.Context, string) (State, error)
}

type Runner interface {
	Run(context.Context, []byte, ...string) ([]byte, error)
}

type ExecRunner struct{ Name string }

func (r ExecRunner) Run(ctx context.Context, input []byte, args ...string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, r.Name, args...)
	cmd.Stdin = bytes.NewReader(input)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s failed: %w: %s", r.Name, err, redact(stderr.String()))
	}
	return stdout.Bytes(), nil
}

type KubectlStore struct {
	Runner    Runner
	Namespace string
}

const stateConfigMap = "comma-release-state"

type configMap struct {
	APIVersion string `json:"apiVersion"`
	Kind       string `json:"kind"`
	Metadata   struct {
		Name            string `json:"name"`
		Namespace       string `json:"namespace"`
		ResourceVersion string `json:"resourceVersion,omitempty"`
	} `json:"metadata"`
	Data map[string]string `json:"data"`
}

func (s KubectlStore) Load(ctx context.Context) (Record, error) {
	body, err := s.Runner.Run(ctx, nil, "-n", s.Namespace, "get", "configmap", stateConfigMap, "-o", "json")
	if err != nil {
		if containsNotFound(err.Error()) {
			return Record{}, ErrNotFound
		}
		return Record{}, err
	}
	return decodeRecord(body)
}

func (s KubectlStore) Create(ctx context.Context, state State) (Record, error) {
	return s.write(ctx, state, "create", "")
}
func (s KubectlStore) Update(ctx context.Context, record Record) (Record, error) {
	return s.write(ctx, record.State, "replace", record.Version)
}

func (s KubectlStore) write(ctx context.Context, state State, verb, version string) (Record, error) {
	if err := state.validatePhaseFacts(); err != nil {
		return Record{}, err
	}
	encoded, err := json.Marshal(state)
	if err != nil {
		return Record{}, err
	}
	cm := configMap{APIVersion: "v1", Kind: "ConfigMap", Data: map[string]string{"state.json": string(encoded)}}
	cm.Metadata.Name = stateConfigMap
	cm.Metadata.Namespace = s.Namespace
	cm.Metadata.ResourceVersion = version
	body, _ := json.Marshal(cm)
	out, err := s.Runner.Run(ctx, body, "-n", s.Namespace, verb, "-f", "-", "-o", "json")
	if err != nil {
		if containsConflict(err.Error()) {
			return Record{}, ErrConflict
		}
		return Record{}, err
	}
	return decodeRecord(out)
}

func decodeRecord(body []byte) (Record, error) {
	var cm configMap
	if err := json.Unmarshal(body, &cm); err != nil {
		return Record{}, err
	}
	stateBody := []byte(cm.Data["state.json"])
	var header struct {
		SchemaVersion int `json:"schemaVersion"`
	}
	if err := json.Unmarshal(stateBody, &header); err != nil {
		return Record{}, err
	}
	if header.SchemaVersion != CurrentStateSchemaVersion {
		return Record{}, fmt.Errorf("unsupported release state schema %d", header.SchemaVersion)
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(stateBody, &fields); err != nil {
		return Record{}, err
	}
	if _, legacy := fields["availability"]; legacy {
		return Record{}, errors.New("release state V4 contains retired availability field")
	}
	var state State
	decoder := json.NewDecoder(bytes.NewReader(stateBody))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return Record{}, err
	}
	var trailing any
	if err := decoder.Decode(&trailing); err != io.EOF {
		return Record{}, errors.New("release state contains trailing JSON")
	}
	if err := state.validatePhaseFacts(); err != nil {
		return Record{}, err
	}
	return Record{State: state, Version: cm.Metadata.ResourceVersion}, nil
}

func containsNotFound(s string) bool {
	return bytes.Contains([]byte(s), []byte("NotFound")) || bytes.Contains([]byte(s), []byte("not found"))
}
func containsConflict(s string) bool {
	return bytes.Contains([]byte(s), []byte("Conflict")) || bytes.Contains([]byte(s), []byte("object has been modified"))
}

func redact(s string) string {
	s = redactAll(s)
	if len(s) > 240 {
		s = s[:240]
	}
	return s
}

func redactAll(s string) string {
	patterns := []struct {
		re          *regexp.Regexp
		replacement string
	}{
		{regexp.MustCompile(`(?i)(authorization:\s*bearer\s+)[^\s]+`), `${1}[redacted]`},
		{regexp.MustCompile(`(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+`), `${1}[redacted]`},
		{regexp.MustCompile(`(?i)((?:token|password|secret|api[_-]?key|access[_-]?key|release_cookie)["']?\s*[:=]\s*["']?)[^\s,"']+`), `${1}[redacted]`},
		{regexp.MustCompile(`(?i)([a-z][a-z0-9+.-]*://)[^:@/\s]*:[^@/\s]+@`), `${1}[redacted]@`},
	}
	for _, pattern := range patterns {
		s = pattern.re.ReplaceAllString(s, pattern.replacement)
	}
	return s
}

// The archive preserves a replaced transaction's facts. It never owns execution.
func (s KubectlStore) Archive(ctx context.Context, state State) error {
	name := JobName(state.ReleaseID, "previous", 1)
	encoded, err := json.Marshal(state)
	if err != nil {
		return err
	}
	body, err := s.Runner.Run(ctx, nil, "-n", s.Namespace, "get", "configmap/"+name, "-o", "json")
	if err == nil {
		var cm configMap
		var flags struct {
			Immutable bool `json:"immutable"`
		}
		if json.Unmarshal(body, &cm) != nil || json.Unmarshal(body, &flags) != nil || !flags.Immutable {
			return errors.New("previous release record differs")
		}
		var previous State
		if err = json.Unmarshal([]byte(cm.Data["state.json"]), &previous); err != nil {
			return err
		}
		// Repeated recovery updates diagnostic time without changing release facts.
		state.UpdatedAt = previous.UpdatedAt
		encoded, err = json.Marshal(state)
		if err != nil || cm.Data["state.json"] != string(encoded) {
			return errors.New("previous release record differs")
		}
		return nil
	}
	if !containsNotFound(err.Error()) {
		return err
	}
	manifest := map[string]any{"apiVersion": "v1", "kind": "ConfigMap", "metadata": map[string]any{"name": name, "namespace": s.Namespace}, "immutable": true, "data": map[string]string{"state.json": string(encoded)}}
	body, err = json.Marshal(manifest)
	if err != nil {
		return err
	}
	_, err = s.Runner.Run(ctx, body, "-n", s.Namespace, "create", "-f", "-")
	return err
}

func (s KubectlStore) Archived(ctx context.Context, releaseID string) (State, error) {
	body, err := s.Runner.Run(ctx, nil, "-n", s.Namespace, "get", "configmap/"+JobName(releaseID, "previous", 1), "-o", "json")
	if err != nil {
		return State{}, err
	}
	record, err := decodeRecord(body)
	if err != nil {
		return State{}, err
	}
	if record.State.ReleaseID != releaseID {
		return State{}, errors.New("previous release identity differs")
	}
	return record.State, nil
}
