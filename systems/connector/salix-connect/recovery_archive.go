package main

import (
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const archiveScopeRelativePath = "external-runtime/archive-scope.json"

type archiveProjection struct {
	Scope          string `json:"scope"`
	RecoveryNotice bool   `json:"recovery_notice,omitempty"`
}

// Only these product-owned paths are disposable during a fault rebuild.
// Unknown files outside those paths keep the full archive's retention rules.
func (c *connector) recoveryArchiveExclusions() ([]string, error) {
	paths := []string{c.externalWorkspaceRoot, os.Getenv("SALIX_MANAGED_RUNTIME_ROOT")}
	if c.workspaceArchiver != nil {
		paths = append(paths, c.workspaceArchiver.archive)
	}
	result := []string{}
	for _, path := range paths {
		if path == "" || !filepath.IsAbs(path) {
			return nil, errors.New("recovery archive scope unavailable")
		}
		real, err := filepath.EvalSymlinks(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return nil, err
		}
		result = append(result, real)
	}
	return result, nil
}

func inArchivePath(path, root string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

// Resolve exact native continuation and credential/config files before the
// final quiet check. Codex thread/read may start its control process; Quiet
// then stops it. The exporter only uses these retained paths and never probes.
func (c *connector) recoveryArchivePaths(ctx context.Context) ([]string, error) {
	if _, err := c.recoveryArchiveExclusions(); err != nil {
		return nil, err
	}
	_, active, inputs, events := c.externalRuntimeState.healthCounts()
	if active != 0 || inputs != 0 || events != 0 {
		return nil, errRuntimeNotQuiet
	}
	c.externalRuntimeState.mu.Lock()
	identities := make([]externalRuntimeSessionIdentity, 0, len(c.externalRuntimeState.identities))
	for _, identity := range c.externalRuntimeState.identities {
		identities = append(identities, identity)
	}
	c.externalRuntimeState.mu.Unlock()
	retained := map[string]bool{}
	add := func(path string, optional bool) error {
		real, err := filepath.EvalSymlinks(path)
		if optional && errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if !inArchivePath(real, c.root) {
			return errors.New("critical native continuation or credential is outside the Group archive scope")
		}
		retained[real] = true
		if inArchivePath(filepath.Clean(path), c.root) {
			retained[filepath.Clean(path)] = true
		}
		return nil
	}
	for _, identity := range identities {
		paths, err := c.migrationNativePaths(ctx, identity)
		if err != nil {
			return nil, err
		}
		for key, path := range paths {
			if key != "workspace" {
				if err := add(path, false); err != nil {
					return nil, err
				}
			}
		}
		var optional []string
		switch identity.Provider {
		case "codex":
			config := codexConfigPath()
			optional = []string{config, filepath.Join(filepath.Dir(config), "auth.json")}
		case "claude":
			settings, err := runtimeAuthClaudeLocation()
			if err != nil {
				return nil, err
			}
			optional = []string{settings, filepath.Join(filepath.Dir(settings), "settings.json"), filepath.Join(filepath.Dir(settings), "settings.local.json"), filepath.Join(filepath.Dir(settings), runtimeAuthClaudeCredentialsName)}
			if home, err := os.UserHomeDir(); err == nil {
				optional = append(optional, filepath.Join(home, ".claude.json"))
			}
		case "pi":
			_, _, auth, err := runtimeAuthPiLocation(ctx, identity.Command)
			if err != nil {
				return nil, err
			}
			optional = []string{auth, filepath.Join(filepath.Dir(auth), "settings.json"), filepath.Join(filepath.Dir(auth), "models.json")}
		}
		for _, path := range optional {
			if err := add(path, true); err != nil {
				return nil, err
			}
		}
	}
	result := make([]string, 0, len(retained))
	for path := range retained {
		result = append(result, path)
	}
	sort.Strings(result)
	return result, nil
}

// A retained file must keep its parents traversable through disposable trees.
// A retained native sidecar directory keeps its own children, not its siblings.
func recoveryArchiveKeeps(path string, retained []string) bool {
	for _, keep := range retained {
		if inArchivePath(path, keep) || inArchivePath(keep, path) {
			return true
		}
	}
	return false
}

func (c *connector) readArchiveProjection() (archiveProjection, error) {
	var value archiveProjection
	raw, err := os.ReadFile(filepath.Join(c.runtimeStateRoot(), archiveScopeRelativePath))
	if errors.Is(err, os.ErrNotExist) {
		return archiveProjection{Scope: "full"}, nil
	}
	if err != nil {
		return value, err
	}
	if json.Unmarshal(raw, &value) != nil || (value.Scope != "full" && value.Scope != "recovery") {
		return value, errors.New("invalid saved archive scope")
	}
	return value, nil
}

func (c *connector) saveArchiveProjection(value archiveProjection) error {
	path := filepath.Join(c.runtimeStateRoot(), archiveScopeRelativePath)
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	f, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err = f.Write(raw); err == nil {
		err = f.Sync()
	}
	closed := f.Close()
	if err != nil {
		return err
	}
	if closed != nil {
		return closed
	}
	if err = os.Rename(path+".tmp", path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

func (c *connector) loadRecoveryArchiveNotice() error {
	projection, err := c.readArchiveProjection()
	if err != nil {
		return err
	}
	if projection.RecoveryNotice || projection.Scope == "recovery" {
		c.noteRecoveryArchive()
	}
	return nil
}

func (c *connector) noteRecoveryArchive() {
	if c.externalRuntimeState == nil {
		return
	}
	c.externalRuntimeState.mu.Lock()
	ids := make([]string, 0, len(c.externalRuntimeState.identities))
	for _, identity := range c.externalRuntimeState.identities {
		ids = append(ids, identity.SessionID)
	}
	c.externalRuntimeState.mu.Unlock()
	for _, id := range ids {
		c.setWorkspaceRuntimeNotice(id, "This Session resumed from a recovery checkpoint. Agent workspaces, cloned or modified repositories, and managed dependencies were not preserved except for retained native continuation and credential files. Inspect the workspace and rebuild what is needed before continuing. Do not replay completed external actions.")
	}
}
