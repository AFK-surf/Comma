package release

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"
)

type unexpectedStoreRunner struct{ calls int }

func (r *unexpectedStoreRunner) Run(context.Context, []byte, ...string) ([]byte, error) {
	r.calls++
	return nil, errors.New("runner must not be called")
}

func TestRedactRemovesExternalCommandSecrets(t *testing.T) {
	input := `Authorization: Bearer top.secret token=abc123 password:"hunter2" https://user:pass@example.com postgres://db:pass@database/comma redis://:redis-pass@redis/0`
	output := redact(input)
	for _, secret := range []string{"top.secret", "abc123", "hunter2", "user:pass", "db:pass", "redis-pass"} {
		if strings.Contains(output, secret) {
			t.Fatalf("secret %q leaked in %q", secret, output)
		}
	}
}

func TestDecodeRecordRejectsV3State(t *testing.T) {
	stateBody := `{"schemaVersion":3,"releaseId":"current","phase":"succeeded"}`
	cm := configMap{APIVersion: "v1", Kind: "ConfigMap", Data: map[string]string{"state.json": stateBody}}
	cm.Metadata.Name = stateConfigMap
	cm.Metadata.Namespace = "comma"
	cm.Metadata.ResourceVersion = "7"
	body, _ := json.Marshal(cm)
	_, err := decodeRecord(body)
	if err == nil || !strings.Contains(err.Error(), "unsupported release state schema 3") {
		t.Fatalf("V3 record error = %v", err)
	}
}

func TestV4StoreStopsOnV3BeforeAnyKubernetesMutation(t *testing.T) {
	cm := configMap{
		APIVersion: "v1",
		Kind:       "ConfigMap",
		Data: map[string]string{
			"state.json": `{"schemaVersion":3,"releaseId":"terminal-v3","phase":"succeeded"}`,
		},
	}
	cm.Metadata.Name = stateConfigMap
	cm.Metadata.Namespace = "comma"
	cm.Metadata.ResourceVersion = "9"
	body, _ := json.Marshal(cm)
	calls := 0
	runner := runnerFunc(func(_ context.Context, input []byte, args ...string) ([]byte, error) {
		calls++
		if len(input) != 0 || !slices.Contains(args, "get") {
			return nil, errors.New("V3 state reached a Kubernetes mutation")
		}
		return body, nil
	})
	store := KubectlStore{Runner: runner, Namespace: "comma"}

	if _, err := store.Load(context.Background()); err == nil ||
		!strings.Contains(err.Error(), "unsupported release state schema 3") {
		t.Fatalf("V3 Store.Load error = %v", err)
	}
	if calls != 1 {
		t.Fatalf("V3 state caused %d Kubernetes calls, want one read", calls)
	}
}

func TestDecodeRecordRejectsRetiredAvailabilityField(t *testing.T) {
	stateBody := `{"schemaVersion":4,"releaseId":"current","phase":"succeeded","availability":{"resources":{"statefulset/comma":true},"replicas":{"statefulset/comma":2},"configRefs":{"statefulset/comma":"comma-runtime"},"revisions":{"statefulset/comma":"revision-1"},"helmRevision":13},"helm":{"snapshotRevision":13,"servingRevision":13}}`
	cm := configMap{APIVersion: "v1", Kind: "ConfigMap", Data: map[string]string{"state.json": stateBody}}
	body, err := json.Marshal(cm)
	if err != nil {
		t.Fatal(err)
	}
	_, err = decodeRecord(body)
	if err == nil || !strings.Contains(err.Error(), "retired availability field") {
		t.Fatalf("V4 state with retired availability error = %v", err)
	}
}

func TestDecodeRecordAcceptsEveryCurrentPhase(t *testing.T) {
	for _, phase := range []Phase{
		PhasePrepared, PhasePlanned, PhaseOnline, PhaseQuiescing, PhaseCutover,
		PhaseApplying, PhaseVerifying, PhaseSucceeded, PhaseRecovering, PhaseRecovered,
	} {
		t.Run(string(phase), func(t *testing.T) {
			decodeStateRecord(t, State{SchemaVersion: CurrentStateSchemaVersion, Phase: phase, Helm: HelmFacts{SnapshotRevision: 1, ServingRevision: 1}})
		})
	}
	for _, forwardPhase := range []Phase{PhaseCutover, PhaseApplying, PhaseVerifying} {
		t.Run("forward_"+string(forwardPhase), func(t *testing.T) {
			decodeStateRecord(t, State{SchemaVersion: CurrentStateSchemaVersion, Phase: PhaseForwardOnly, ForwardPhase: forwardPhase, CutoverMayHaveStarted: true, Helm: HelmFacts{SnapshotRevision: 1, ServingRevision: 1, MaintenanceRevision: 1}})
		})
	}
}

func TestDecodeRecordValidatesLifecycleAcquiringState(t *testing.T) {
	now := time.Now().UTC()
	valid := NewState("staging", "lifecycle-v1", "image", 1, now)
	valid.Phase = PhaseQuiescing
	valid.LifecycleWriterEpoch = &LifecycleWriterEpochFacts{
		Required: true, Status: "acquiring",
		FencingToken: strings.Repeat("a", 64), OperationAttempt: 1,
	}
	decodeStateRecord(t, valid)

	legacyTerminal := valid
	legacyTerminal.Phase = PhaseRecovered
	legacyEpoch := *valid.LifecycleWriterEpoch
	legacyEpoch.Status = ""
	legacyTerminal.LifecycleWriterEpoch = &legacyEpoch
	decodeStateRecord(t, legacyTerminal)

	for _, test := range []struct {
		name   string
		mutate func(*State, *LifecycleWriterEpochFacts)
		want   string
	}{
		{
			name: "missing token",
			mutate: func(_ *State, epoch *LifecycleWriterEpochFacts) {
				epoch.FencingToken = ""
			},
			want: "acquiring lifecycle writer epoch requires durable token and operation attempt",
		},
		{
			name: "missing attempt",
			mutate: func(_ *State, epoch *LifecycleWriterEpochFacts) {
				epoch.OperationAttempt = 0
			},
			want: "acquiring lifecycle writer epoch requires durable token and operation attempt",
		},
		{
			name: "terminal acquiring",
			mutate: func(state *State, _ *LifecycleWriterEpochFacts) {
				state.Phase = PhaseRecovered
			},
			want: "recovered pre-cutover release cannot retain an acquiring or active lifecycle writer epoch",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			state := valid
			epoch := *valid.LifecycleWriterEpoch
			state.LifecycleWriterEpoch = &epoch
			test.mutate(&state, &epoch)
			_, err := decodeStateRecordError(t, state)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("decodeRecord() error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestDecodeRecordRejectsLegacyOrInconsistentPhases(t *testing.T) {
	for _, test := range []struct {
		name  string
		state State
		want  string
	}{
		{name: "missing phase", state: State{SchemaVersion: CurrentStateSchemaVersion, Helm: HelmFacts{SnapshotRevision: 1, ServingRevision: 1}}, want: `unsupported release state phase ""`},
		{name: "legacy provider phase", state: State{SchemaVersion: CurrentStateSchemaVersion, Phase: Phase("provider"), Helm: HelmFacts{SnapshotRevision: 1, ServingRevision: 1}}, want: `unsupported release state phase "provider"`},
		{name: "unknown phase", state: State{SchemaVersion: CurrentStateSchemaVersion, Phase: Phase("future"), Helm: HelmFacts{SnapshotRevision: 1, ServingRevision: 1}}, want: `unsupported release state phase "future"`},
		{name: "missing Helm revision", state: State{SchemaVersion: CurrentStateSchemaVersion, Phase: PhaseSucceeded}, want: `requires durable Helm snapshot and serving revisions`},
		{name: "missing forward phase", state: State{SchemaVersion: CurrentStateSchemaVersion, Phase: PhaseForwardOnly, Helm: HelmFacts{SnapshotRevision: 1, ServingRevision: 1}}, want: `unsupported release state forward phase ""`},
		{name: "legacy provider forward phase", state: State{SchemaVersion: CurrentStateSchemaVersion, Phase: PhaseForwardOnly, ForwardPhase: Phase("provider"), Helm: HelmFacts{SnapshotRevision: 1, ServingRevision: 1}}, want: `unsupported release state forward phase "provider"`},
		{name: "forward phase outside fence", state: State{SchemaVersion: CurrentStateSchemaVersion, Phase: PhaseApplying, ForwardPhase: PhaseApplying, Helm: HelmFacts{SnapshotRevision: 1, ServingRevision: 1}}, want: `release state phase "applying" cannot carry forward phase "applying"`},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := decodeStateRecordError(t, test.state)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("decodeRecord() error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestKubectlStoreRejectsLegacyPhaseBeforeMutation(t *testing.T) {
	runner := &unexpectedStoreRunner{}
	store := KubectlStore{Runner: runner, Namespace: "comma"}
	_, err := store.Create(context.Background(), State{SchemaVersion: CurrentStateSchemaVersion, Phase: Phase("provider"), Helm: HelmFacts{SnapshotRevision: 1, ServingRevision: 1}})
	if err == nil || !strings.Contains(err.Error(), `unsupported release state phase "provider"`) {
		t.Fatalf("Create() error = %v", err)
	}
	if runner.calls != 0 {
		t.Fatalf("invalid state reached Kubernetes runner %d time(s)", runner.calls)
	}
}

func decodeStateRecord(t *testing.T, state State) Record {
	t.Helper()
	record, err := decodeStateRecordError(t, state)
	if err != nil {
		t.Fatal(err)
	}
	return record
}

func decodeStateRecordError(t *testing.T, state State) (Record, error) {
	t.Helper()
	stateBody, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	cm := configMap{APIVersion: "v1", Kind: "ConfigMap", Data: map[string]string{"state.json": string(stateBody)}}
	body, err := json.Marshal(cm)
	if err != nil {
		t.Fatal(err)
	}
	return decodeRecord(body)
}

func TestDecodeRecordRejectsNonV4State(t *testing.T) {
	for _, test := range []struct {
		name string
		body string
		want string
	}{
		{name: "V1", body: `{"schemaVersion":1,"releaseId":"legacy"}`, want: "unsupported release state schema 1"},
		{name: "V2", body: `{"schemaVersion":2,"releaseId":"legacy"}`, want: "unsupported release state schema 2"},
		{name: "V3", body: `{"schemaVersion":3,"releaseId":"legacy"}`, want: "unsupported release state schema 3"},
		{name: "unknown", body: `{"schemaVersion":5,"releaseId":"future"}`, want: "unsupported release state schema 5"},
		{name: "missing", body: `{"releaseId":"unversioned"}`, want: "unsupported release state schema 0"},
	} {
		t.Run(test.name, func(t *testing.T) {
			cm := configMap{APIVersion: "v1", Kind: "ConfigMap", Data: map[string]string{"state.json": test.body}}
			body, err := json.Marshal(cm)
			if err != nil {
				t.Fatal(err)
			}
			_, err = decodeRecord(body)
			if err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("decodeRecord() error = %v, want %q", err, test.want)
			}
		})
	}
}

func TestV4StrictDecoderRejectsUnknownFenceFields(t *testing.T) {
	state := NewState("staging", "release-v4", "image", 1, time.Now())
	state.Phase = PhaseSucceeded
	body, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err = json.Unmarshal(body, &fields); err != nil {
		t.Fatal(err)
	}
	fields["futureFence"] = map[string]any{"enabled": true}
	stateBody, _ := json.Marshal(fields)
	cm := configMap{Data: map[string]string{"state.json": string(stateBody)}}
	cmBody, _ := json.Marshal(cm)

	if _, err = decodeRecord(cmBody); err == nil ||
		!strings.Contains(err.Error(), `unknown field "futureFence"`) {
		t.Fatalf("unknown V4 fence field was not rejected: %v", err)
	}
}

func TestLegacyV3ReaderRejectsV4BeforeItCanDropLifecycleFence(t *testing.T) {
	now := time.Now().UTC()
	state := NewState("staging", "lifecycle-v1", "image", 1, now)
	state.Phase = PhaseQuiescing
	state.LifecycleWriterEpoch = &LifecycleWriterEpochFacts{
		Required: true, Status: "active", Generation: 1,
		FencingToken: strings.Repeat("a", 64), LeaseExpiresAt: now.Add(time.Minute),
		DrainedAt: now,
	}
	body, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	if rewritten, err := legacyV3RoundTrip(body); err == nil || rewritten != nil ||
		!strings.Contains(err.Error(), "unsupported release state schema 4") {
		t.Fatalf("legacy V3 reader did not fail closed: body=%s err=%v", rewritten, err)
	}

	var vulnerable map[string]any
	if err = json.Unmarshal(body, &vulnerable); err != nil {
		t.Fatal(err)
	}
	vulnerable["schemaVersion"] = float64(3)
	vulnerableBody, _ := json.Marshal(vulnerable)
	rewritten, err := legacyV3RoundTrip(vulnerableBody)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(rewritten), "lifecycleWriterEpoch") {
		t.Fatalf("test setup no longer reproduces the V3 field-drop hazard: %s", rewritten)
	}

	var relabeled map[string]any
	if err = json.Unmarshal(rewritten, &relabeled); err != nil {
		t.Fatal(err)
	}
	relabeled["schemaVersion"] = float64(CurrentStateSchemaVersion)
	relabeledBody, _ := json.Marshal(relabeled)
	cmBody, _ := json.Marshal(configMap{
		Data: map[string]string{"state.json": string(relabeledBody)},
	})
	if _, err = decodeRecord(cmBody); err != nil {
		t.Fatalf("version-only V3-to-V4 hard cut was rejected: %v", err)
	}
}

func legacyV3RoundTrip(body []byte) ([]byte, error) {
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(body, &fields); err != nil {
		return nil, err
	}
	var schemaVersion int
	if err := json.Unmarshal(fields["schemaVersion"], &schemaVersion); err != nil {
		return nil, err
	}
	if schemaVersion != 3 {
		return nil, fmt.Errorf("unsupported release state schema %d", schemaVersion)
	}
	delete(fields, "lifecycleWriterEpoch")
	return json.Marshal(fields)
}
