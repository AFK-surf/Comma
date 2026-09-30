package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"
)

func (c *connector) runtimeStateRoot() string {
	if c.cfg.deviceMode && c.cfg.deviceStateRoot != "" {
		return c.cfg.deviceStateRoot
	}
	if c.cfg.externalStateRoot != "" {
		return c.cfg.externalStateRoot
	}
	return c.root
}

// Passive discovery never executes a provider binary or reads credentials.
// The same inventory is used for device.get and runtime target discovery.
func (c *connector) discoverDeviceRuntimes() {
	if !c.cfg.deviceMode {
		return
	}
	entries := map[string]map[string]any{}
	for _, target := range discoverAgentRuntimeTargets() {
		if len(entries) >= 32 {
			break
		}
		entries[target.key()] = map[string]any{
			"kind": "external", "provider": target.provider,
			"command": target.identityMaterial, "identity_material": target.identityMaterial,
			"ready": false, "status": "unavailable", "readiness_issue": "permission_required",
			"readiness_message": "Allow operations in Comma Settings > Devices to use this agent.",
		}
	}
	c.runtimeInventory.mu.Lock()
	c.runtimeInventory.runtimes = entries
	c.runtimeInventory.mu.Unlock()
}

func (c *connector) deviceRuntimeObservations() []map[string]any {
	entries := c.runtimeInventory.snapshot()
	for _, entry := range entries {
		entry["ready"] = false
		entry["status"] = "unavailable"
		entry["readiness_issue"] = "permission_required"
		entry["readiness_message"] = "Allow operations in Comma Settings > Devices to use this agent."
	}
	return entries
}

// Native calls use the existing cancellable execution authority. Downgrade
// closes shared native processes after admitted calls leave this section.
func (c *connector) deviceRuntimeAdmission(ctx context.Context) (context.Context, context.CancelFunc, bool) {
	if !c.cfg.deviceMode {
		return ctx, func() {}, true
	}
	callCtx, cancel, allowed := c.commandAdmissionContext(ctx)
	if !allowed {
		return callCtx, cancel, false
	}
	c.deviceRuntimeMu.RLock()
	if callCtx.Err() != nil {
		c.deviceRuntimeMu.RUnlock()
		cancel()
		return callCtx, func() {}, false
	}
	return callCtx, func() { c.deviceRuntimeMu.RUnlock(); cancel() }, true
}

func (c *connector) persistDeviceAccess(scope string) error {
	// Main owns desktop preferences. Standalone devices keep their preference
	// next to their runtime state, so restarting the copied command preserves it.
	if !c.cfg.deviceMode || c.cfg.configPath != "" {
		return nil
	}
	raw, err := json.Marshal(map[string]string{"scope": scope})
	if err != nil {
		return err
	}
	path := filepath.Join(c.runtimeStateRoot(), "device-access.json")
	if err := os.WriteFile(path+".tmp", raw, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}

func (c *connector) loadDeviceAccess() error {
	if !c.cfg.deviceMode || c.cfg.configPath != "" {
		return nil
	}
	raw, err := os.ReadFile(filepath.Join(c.runtimeStateRoot(), "device-access.json"))
	if os.IsNotExist(err) {
		return nil
	}
	if err != nil {
		return err
	}
	var stored struct {
		Scope *string `json:"scope"`
	}
	if json.Unmarshal(raw, &stored) != nil || stored.Scope == nil || (*stored.Scope != "" && *stored.Scope != scopeLocalFileRead) {
		return errors.New("invalid device access preference; restore device-access.json before starting")
	}
	c.scope = *stored.Scope
	if c.scope == "" {
		c.commandContext, c.cancelCommandContext = context.WithCancel(context.Background())
	} else {
		c.cancelCommandContext()
	}
	return nil
}

func (c *connector) refreshDeviceRuntimes() {
	if !c.cfg.deviceMode {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if c.currentScope() == scopeLocalFileRead {
		c.discoverDeviceRuntimes()
	} else {
		_, _ = c.runtimeInventory.probe(ctx, "", "", "operator")
	}
	_ = c.publishCachedMetadata()
	if c.currentScope() == "" {
		c.sendMu.Lock()
		transport := c.activeTransport
		c.sendMu.Unlock()
		if transport != nil {
			c.catchUpExternalRuntimeInputs(ctx, transport)
		}
	}
}

func (c *connector) methodDeviceAccess(params map[string]any) (any, error) {
	if !c.cfg.deviceMode {
		return nil, errors.New("restart this Connector with --device to manage its access")
	}
	allow, ok := params["allow_operations"].(bool)
	if !ok {
		return nil, errors.New("allow_operations must be a boolean")
	}
	// Forward to Main, which persists the preference and sends the same private
	// scope command used by the local switch. The server cannot choose a second
	// workspace: that identity comes from this child's Main-owned config.
	if c.cfg.configPath != "" {
		endpoint := strings.TrimRight(os.Getenv(commaClientControlURLEnv), "/")
		token := os.Getenv(commaClientControlTokenEnv)
		if endpoint == "" || token == "" || c.cfg.deviceWorkspaceID == "" {
			return nil, errors.New("Comma device access owner is unavailable")
		}
		body, _ := json.Marshal(map[string]any{"module": "devices", "api": "set-access", "input": map[string]any{"workspaceId": c.cfg.deviceWorkspaceID, "allow_operations": allow}})
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		raw, err := commaClientResponse(ctx, http.MethodPost, endpoint+"/v1/invoke", token, bytes.NewReader(body))
		if err != nil {
			return nil, err
		}
		var result map[string]any
		if err := json.Unmarshal(raw, &result); err != nil {
			return nil, err
		}
		return result, nil
	}
	scope := scopeLocalFileRead
	if allow {
		scope = ""
	}
	if err := c.setCurrentScope(scope); err != nil {
		return nil, err
	}
	if err := c.publishCachedMetadata(); err != nil {
		return nil, err
	}
	go c.refreshDeviceRuntimes()
	return map[string]any{"allows_operations": allow}, nil
}
