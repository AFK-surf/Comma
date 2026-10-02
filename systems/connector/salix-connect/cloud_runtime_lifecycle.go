package main

import (
	"context"
	"errors"
	"os"
	"sort"
	"strings"
	"time"
)

const cloudRuntimeQuietProcessLimit = 128

// Only release idle native processes. The coordinator's target sections fence
// Send, recovery and credential mutation while native quiet checks run. Durable
// inputs, recovery obligations and unacknowledged outputs always prevent quiet.
func (c *connector) quietManagedCloudRuntimes(ctx context.Context) error {
	ctx, cancel := context.WithTimeout(ctx, cloudRuntimeQuietTimeout)
	defer cancel()
	if c.cloudRuntimeRequests != 0 {
		return errRuntimeNotQuiet
	}
	c.processMu.Lock()
	busy := len(c.processes) > cloudRuntimeQuietProcessLimit
	if !busy {
		for _, process := range c.processes {
			if process.isRunning() {
				busy = true
				break
			}
		}
	}
	c.processMu.Unlock()
	if busy {
		return errRuntimeNotQuiet
	}

	owner := c.runtimeAuthCoordinator()
	if owner == nil || c.externalRuntimeState == nil {
		return errRuntimeNotQuiet
	}
	targets := []runtimeProbeTarget{}
	for _, provider := range []string{"codex", "claude"} {
		for _, command := range managedRuntimeCommands(provider) {
			targets = append(targets, runtimeProbeTarget{provider: provider, identityMaterial: command})
		}
	}
	sort.Slice(targets, func(i, j int) bool { return targets[i].key() < targets[j].key() })
	unlocks := []func(){}
	defer func() {
		for n := len(unlocks) - 1; n >= 0; n-- {
			unlocks[n]()
		}
	}()
	for _, target := range targets {
		unlock, ok := owner.tryLockTarget(target.key())
		if !ok {
			return errRuntimeNotQuiet
		}
		unlocks = append(unlocks, unlock)
		if owner.targetBusy(target) || owner.attempt(target.key()) != nil {
			return errRuntimeNotQuiet
		}
	}
	_, active, inputs, events := c.externalRuntimeState.healthCounts()
	if active != 0 || inputs != 0 || events != 0 {
		return errRuntimeNotQuiet
	}
	// Kimi has no native quiet query. Its explicit Stop operation removes the
	// exact session; until then, absence of new inputs cannot prove it is idle.
	if kimi, ok := c.runtimeImplementations["kimi"].(*kimiRuntimeImplementation); ok {
		kimi.mu.Lock()
		present := len(kimi.sessions) != 0
		kimi.mu.Unlock()
		if present {
			return errRuntimeNotQuiet
		}
	}
	for _, provider := range []string{"claude", "codex", "pi"} {
		if implementation, ok := c.runtimeImplementations[provider].(externalRuntimeQuietChecker); ok {
			if err := implementation.Quiet(ctx); err != nil {
				return err
			}
		}
	}
	// Quiet has checked all sessions, including native background terminals.
	// Detach exact idle generations before killing them. Exit callbacks cannot
	// remove a newer process; native history and durable Session identity stay.
	if implementation, ok := c.runtimeImplementations["codex"].(*codexRuntimeImplementation); ok {
		implementation.mu.Lock()
		for _, target := range targets {
			if target.provider != "codex" {
				continue
			}
			if runtime := implementation.runtimes[target.identityMaterial]; runtime != nil {
				delete(implementation.runtimes, target.identityMaterial)
				runtime.terminate()
			}
		}
		implementation.mu.Unlock()
	}
	return nil
}

func (c *connector) expireCloudRuntimeQuiesce() {
	if c.cloudRuntimeControl != nil && c.cloudRuntimeControl.Sealed {
		c.cloudRuntimeQuiesced = true
		return
	}
	if c.cloudRuntimeQuiesced && !c.cloudRuntimeReleased && time.Now().After(c.cloudRuntimeParkUntil) {
		c.cloudRuntimeQuiesced = false
		c.cloudRuntimeParkToken = ""
	}
}

func (c *connector) methodCloudRuntimeLifecycle(ctx context.Context, method string, params map[string]any) (map[string]any, error) {
	if strings.TrimSpace(os.Getenv("SALIX_MANAGED_RUNTIME_ROOT")) == "" {
		return nil, errors.New("not a managed runtime connector")
	}
	ctx, cancel := context.WithTimeout(ctx, cloudRuntimeQuietTimeout)
	defer cancel()
	if err := lockRuntimeContext(ctx, &c.cloudRuntimeMu); err != nil {
		return nil, err
	}
	defer c.cloudRuntimeMu.Unlock()
	c.expireCloudRuntimeQuiesce()
	token := stringParam(params, "token")
	if token == "" || len(token) > 128 {
		return nil, errors.New("invalid idle request")
	}
	if method == "cloud_runtime_quiesce" {
		// An ambiguous release response may leave a fenced process attached.
		// A later sweep may finish parking it; it can never accept input again.
		if c.cloudRuntimeReleased {
			c.cloudRuntimeParkToken = token
			return map[string]any{"quiet": true, "continued": false}, nil
		}
		if c.cloudRuntimeQuiesced && c.cloudRuntimeParkToken != token {
			return nil, errRuntimeNotQuiet
		}
		continued := c.cloudRuntimeQuiesced && c.cloudRuntimeParkToken == token
		if err := c.quietManagedCloudRuntimes(ctx); err != nil {
			return nil, err
		}
		c.cloudRuntimeQuiesced = true
		c.cloudRuntimeParkToken = token
		duration := time.Duration(intParam(params, "timeout_ms", 60_000)) * time.Millisecond
		if duration <= 0 || duration > 70*time.Minute {
			duration = time.Minute
		}
		c.cloudRuntimeParkUntil = time.Now().Add(duration)
		return map[string]any{"quiet": true, "continued": continued}, nil
	}
	if !c.cloudRuntimeQuiesced || c.cloudRuntimeParkToken != token {
		return nil, errRuntimeNotQuiet
	}
	if method == "cloud_runtime_resume" {
		if (c.cloudRuntimeControl != nil && c.cloudRuntimeControl.Sealed) || c.cloudRuntimeReleased {
			return nil, errRuntimeNotQuiet
		}
		c.cloudRuntimeQuiesced = false
		c.cloudRuntimeParkToken = ""
		return map[string]any{"resumed": true}, nil
	}
	c.cloudRuntimeReleased = true
	return map[string]any{"released": true}, nil
}
