package main

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const runtimeProbeConcurrency = 2
const runtimeProbeFrameEvidence = "_probe_frame_evidence"
const runtimeProbeGenerationEvidence = "_runtime_generation_evidence"
const runtimeProbeAuthEpochEvidence = "_runtime_auth_epoch_evidence"
const runtimeProbeNoRetryEvidence = "_runtime_probe_no_retry_evidence"

var errRuntimeProbeSuperseded = errors.New("runtime probe observation was superseded")

type runtimeProbeTarget struct {
	provider         string
	identityMaterial string
}

func (target runtimeProbeTarget) key() string {
	return target.provider + "\x00" + target.identityMaterial
}

type runtimeProbeCall struct {
	done        chan struct{}
	publication *runtimeProbePublication
	runtime     map[string]any
	err         error
}

type runtimeProbePublication struct {
	claimed atomic.Bool
	done    chan struct{}
	once    sync.Once
	mu      sync.Mutex
	err     error
}

func newRuntimeProbePublication() *runtimeProbePublication {
	return &runtimeProbePublication{done: make(chan struct{})}
}

func (publication *runtimeProbePublication) complete(err error) {
	publication.once.Do(func() {
		publication.mu.Lock()
		publication.err = err
		publication.mu.Unlock()
		close(publication.done)
	})
}

func (publication *runtimeProbePublication) wait(ctx context.Context) error {
	select {
	case <-publication.done:
		publication.mu.Lock()
		defer publication.mu.Unlock()
		return publication.err
	case <-ctx.Done():
		return ctx.Err()
	}
}

type runtimeInventory struct {
	mu                 sync.Mutex
	runtimes           map[string]map[string]any
	inflight           map[string]*runtimeProbeCall
	slots              chan struct{}
	run                func(runtimeProbeTarget) map[string]any
	commitGuard        func(runtimeProbeTarget, string, uint64, map[string]any, func()) bool
	workspaceReadiness func() error
}

func newRuntimeInventory() *runtimeInventory {
	return &runtimeInventory{
		runtimes: map[string]map[string]any{},
		inflight: map[string]*runtimeProbeCall{},
		slots:    make(chan struct{}, runtimeProbeConcurrency),
		run:      probeAgentRuntimeTarget,
	}
}

func (inventory *runtimeInventory) snapshot() []map[string]any {
	inventory.mu.Lock()
	defer inventory.mu.Unlock()
	runtimes := make([]map[string]any, 0, len(inventory.runtimes))
	for _, runtime := range inventory.runtimes {
		runtimes = append(runtimes, cloneRuntimeObservation(runtime))
	}
	sort.Slice(runtimes, func(i, j int) bool {
		return runtimeObservationKey(runtimes[i]) < runtimeObservationKey(runtimes[j])
	})
	return runtimes
}

func (inventory *runtimeInventory) probe(
	ctx context.Context,
	provider, identityMaterial, trigger string,
) ([]map[string]any, error) {
	provider, identityMaterial = strings.TrimSpace(provider), strings.TrimSpace(identityMaterial)
	if (provider == "") != (identityMaterial == "") {
		return nil, errors.New("provider and identity_material must be provided together")
	}
	if provider != "" {
		target, ok := inventory.target(provider, identityMaterial)
		if !ok {
			return nil, errors.New("runtime target is not present in the current inventory")
		}
		runtime, err := inventory.probeOne(ctx, target, trigger)
		if err != nil {
			return nil, err
		}
		return []map[string]any{runtime}, nil
	}

	targets := discoverAgentRuntimeTargets()
	discovered := make(map[string]bool, len(targets))
	probed := make([]map[string]any, 0, len(targets))
	for _, target := range targets {
		discovered[target.key()] = true
		runtime, err := inventory.probeOne(ctx, target, trigger)
		if err != nil {
			return nil, err
		}
		probed = append(probed, runtime)
	}
	inventory.mu.Lock()
	for key := range inventory.runtimes {
		if !discovered[key] {
			delete(inventory.runtimes, key)
		}
	}
	inventory.mu.Unlock()
	return mergeRuntimeProbeEvidence(inventory.snapshot(), probed), nil
}

func (inventory *runtimeInventory) target(provider, identityMaterial string) (runtimeProbeTarget, bool) {
	target := runtimeProbeTarget{provider: provider, identityMaterial: identityMaterial}
	inventory.mu.Lock()
	_, ok := inventory.runtimes[target.key()]
	inventory.mu.Unlock()
	return target, ok
}

// probeOne's joined-probe retry contract is modeled in tla/connector/RuntimeAuth.tla.
func (inventory *runtimeInventory) probeOne(
	ctx context.Context,
	target runtimeProbeTarget,
	trigger string,
) (map[string]any, error) {
	for {
		runtime, err := inventory.probeOneAttempt(ctx, target, trigger)
		if !errors.Is(err, errRuntimeProbeSuperseded) {
			return runtime, err
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
	}
}

func (inventory *runtimeInventory) probeOneAttempt(
	ctx context.Context,
	target runtimeProbeTarget,
	trigger string,
) (map[string]any, error) {
	key := target.key()
	inventory.mu.Lock()
	if call := inventory.inflight[key]; call != nil {
		inventory.mu.Unlock()
		select {
		case <-call.done:
			return cloneRuntimeObservation(call.runtime), call.err
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	call := &runtimeProbeCall{done: make(chan struct{}), publication: newRuntimeProbePublication()}
	inventory.inflight[key] = call
	inventory.mu.Unlock()

	select {
	case inventory.slots <- struct{}{}:
	case <-ctx.Done():
		inventory.finishProbe(target, call, nil, "", 0, false, ctx.Err())
		return nil, ctx.Err()
	}
	started := time.Now()
	runtime := inventory.run(target)
	if inventory.workspaceReadiness != nil {
		applyExternalRuntimeWorkspaceReadiness([]map[string]any{runtime}, inventory.workspaceReadiness())
	}
	<-inventory.slots
	runtime["probe_trigger"] = normalizeRuntimeProbeTrigger(trigger)
	runtime["probe_duration_ms"] = time.Since(started).Milliseconds()
	runtime[runtimeProbeFrameEvidence] = call.publication
	generation := stringParam(runtime, runtimeProbeGenerationEvidence)
	authEpoch, _ := runtime[runtimeProbeAuthEpochEvidence].(uint64)
	noRetry, _ := runtime[runtimeProbeNoRetryEvidence].(bool)
	delete(runtime, runtimeProbeGenerationEvidence)
	delete(runtime, runtimeProbeAuthEpochEvidence)
	delete(runtime, runtimeProbeNoRetryEvidence)
	inventory.finishProbe(target, call, runtime, generation, authEpoch, noRetry, nil)
	return cloneRuntimeObservation(call.runtime), call.err
}

// finishProbe's guarded publication is modeled in tla/connector/RuntimeAuth.tla.
func (inventory *runtimeInventory) finishProbe(
	target runtimeProbeTarget,
	call *runtimeProbeCall,
	runtime map[string]any,
	generation string,
	authEpoch uint64,
	noRetry bool,
	err error,
) {
	key := target.key()
	accepted := runtime != nil
	if runtime != nil {
		commit := func() {
			inventory.mu.Lock()
			inventory.runtimes[key] = cachedRuntimeObservation(runtime)
			inventory.mu.Unlock()
		}
		if inventory.commitGuard != nil {
			accepted = inventory.commitGuard(target, generation, authEpoch, runtime, commit)
		} else {
			commit()
		}
	}

	inventory.mu.Lock()
	call.err = err
	if runtime != nil {
		if accepted {
			call.runtime = cloneRuntimeObservation(runtime)
		} else {
			call.runtime = cloneRuntimeObservation(inventory.runtimes[key])
			if call.err == nil && !noRetry {
				call.err = errRuntimeProbeSuperseded
			}
		}
	}
	delete(inventory.inflight, key)
	close(call.done)
	inventory.mu.Unlock()
}

func cachedRuntimeObservation(runtime map[string]any) map[string]any {
	cached := cloneRuntimeObservation(runtime)
	delete(cached, "probe_trigger")
	delete(cached, "probe_duration_ms")
	delete(cached, runtimeProbeFrameEvidence)
	delete(cached, runtimeProbeGenerationEvidence)
	delete(cached, runtimeProbeAuthEpochEvidence)
	delete(cached, runtimeProbeNoRetryEvidence)
	return cached
}

func mergeRuntimeProbeEvidence(runtimes, probed []map[string]any) []map[string]any {
	evidence := map[string]map[string]any{}
	for _, runtime := range probed {
		if _, ok := runtime[runtimeProbeFrameEvidence].(*runtimeProbePublication); ok {
			evidence[runtimeObservationKey(runtime)] = runtime
		}
	}
	for _, runtime := range runtimes {
		if observed := evidence[runtimeObservationKey(runtime)]; observed != nil {
			runtime["probe_trigger"] = observed["probe_trigger"]
			runtime["probe_duration_ms"] = observed["probe_duration_ms"]
			runtime[runtimeProbeFrameEvidence] = observed[runtimeProbeFrameEvidence]
		}
	}
	return runtimes
}

func discoverAgentRuntimeTargets() []runtimeProbeTarget {
	targets := make([]runtimeProbeTarget, 0)
	for _, path := range detectCodexCommands() {
		targets = append(targets, runtimeProbeTarget{provider: "codex", identityMaterial: path})
	}
	for _, path := range detectCommands("pi", nil) {
		targets = append(targets, runtimeProbeTarget{provider: "pi", identityMaterial: path})
	}
	for _, path := range detectCommands("kimi", defaultKimiCommandPaths()) {
		targets = append(targets, runtimeProbeTarget{provider: "kimi", identityMaterial: path})
	}
	for _, path := range detectCommands("claude", defaultClaudeCommandPaths()) {
		targets = append(targets, runtimeProbeTarget{provider: "claude", identityMaterial: path})
	}
	sort.Slice(targets, func(i, j int) bool { return targets[i].key() < targets[j].key() })
	return targets[:min(len(targets), 32)]
}

func probeAgentRuntimeTarget(target runtimeProbeTarget) map[string]any {
	switch target.provider {
	case "codex":
		return codexRuntimeEntries([]string{target.identityMaterial})[0]
	case "pi":
		return portableRuntimeEntry("pi", target.identityMaterial, "rpc", []string{"stdio"})
	case "kimi":
		return portableRuntimeEntry("kimi", target.identityMaterial, "server", []string{"http", "ws"})
	case "claude":
		return portableRuntimeEntry("claude", target.identityMaterial, "agent-sdk-stream-json", []string{"stdio"})
	default:
		panic(fmt.Sprintf("unsupported discovered runtime provider %q", target.provider))
	}
}

func runtimeObservationKey(runtime map[string]any) string {
	return stringParam(runtime, "provider") + "\x00" + stringParam(runtime, "identity_material")
}

func cloneRuntimeObservation(runtime map[string]any) map[string]any {
	cloned := maps.Clone(runtime)
	if auth, ok := runtime["auth"].(map[string]any); ok {
		cloned["auth"] = cloneAuthSnapshot(auth)
	}
	return cloned
}

func (inventory *runtimeInventory) updateAuthSnapshot(
	target runtimeProbeTarget,
	snapshot map[string]any,
	preserveFullReadiness bool,
) bool {
	inventory.mu.Lock()
	defer inventory.mu.Unlock()
	runtime := inventory.runtimes[target.key()]
	if runtime == nil {
		return false
	}
	status := stringParam(snapshot, "status")
	runtime["auth"] = cloneAuthSnapshot(snapshot)
	runtime["auth_ready"] = status == "authenticated" || status == "not_required"
	switch status {
	case "authenticated", "not_required":
		if !preserveFullReadiness {
			// Authentication is only one readiness input. A replacement process or
			// a process that was previously non-ready has not validated model/list.
			runtime["ready"] = false
			runtime["status"] = "unavailable"
			runtime["readiness_issue"] = "runtime_probe_failed"
			runtime["readiness_message"] = "The Codex runtime has not completed a full readiness probe for this process."
		}
	case "unknown", "configured", "pending", "unauthenticated", "error":
		runtime["ready"] = false
		runtime["status"] = "unavailable"
		if status == "unauthenticated" || status == "pending" {
			runtime["readiness_issue"] = "authentication_required"
			runtime["readiness_message"] = "Codex reports no authenticated account."
		} else {
			runtime["readiness_issue"] = "runtime_probe_failed"
			runtime["readiness_message"] = "The Codex authentication state could not be confirmed."
		}
	}
	return true
}

func (inventory *runtimeInventory) fullReadinessInputsReady(target runtimeProbeTarget) bool {
	inventory.mu.Lock()
	defer inventory.mu.Unlock()
	runtime := inventory.runtimes[target.key()]
	return runtime != nil && runtime["auth_ready"] == true
}

func normalizeRuntimeProbeTrigger(trigger string) string {
	if trigger != "connect" && trigger != "periodic" && trigger != "operator" {
		trigger = "other"
	}
	return trigger
}
