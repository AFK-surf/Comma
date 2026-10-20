package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
)

// runtimeImplementation is a provider's native process owner. Codex keeps
// shared app-server processes for probes, login and subscription credentials;
// Claude keeps only its credential fence.
type runtimeImplementation interface {
	Close()
}

const runtimeStateLockName = "connector.lock"

// acquireRuntimeStateLock makes this process the only Connector that runs
// agent runtimes for its runtime state root, including concurrent installer
// retries. The lock ends with the process or closeRuntimes.
func (c *connector) acquireRuntimeStateLock() error {
	root := c.runtimeStateRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	f, err := os.OpenFile(filepath.Join(root, runtimeStateLockName), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	if err := lockRuntimeStateFile(f); err != nil {
		_ = f.Close()
		return fmt.Errorf("another Connector owns this runtime state: %w", err)
	}
	c.runtimeStateLock = f
	return nil
}

func (c *connector) closeRuntimes() {
	c.backgroundMu.Lock()
	c.backgroundClosed = true
	if c.backgroundCancel != nil {
		c.backgroundCancel()
	}
	c.backgroundMu.Unlock()
	c.background.Wait()
	for _, implementation := range c.runtimeImplementations {
		implementation.Close()
	}
	if c.runtimeStateLock != nil {
		_ = c.runtimeStateLock.Close()
		c.runtimeStateLock = nil
	}
}

// goBackground runs work that closeRuntimes cancels and waits for.
func (c *connector) goBackground(work func(context.Context)) {
	c.backgroundMu.Lock()
	defer c.backgroundMu.Unlock()
	if c.backgroundCtx == nil {
		c.backgroundCtx, c.backgroundCancel = context.WithCancel(context.Background())
		if c.backgroundClosed {
			c.backgroundCancel()
		}
	}
	ctx := c.backgroundCtx
	c.background.Go(func() { work(ctx) })
}

func resolveRuntimeWorkspaceRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("resolve runtime workspace home: %w", err)
	}
	if !filepath.IsAbs(home) {
		return "", errors.New("resolve runtime workspace home: HOME must be absolute")
	}
	return filepath.Join(home, ".comma", "workspaces"), nil
}

func runtimeWorkspaceReadinessMessage(err error) string {
	if err == nil {
		return ""
	}
	if strings.TrimSpace(os.Getenv("HOME")) == "" {
		return "HOME is not set; the external runtime workspace root cannot be resolved."
	}
	if !filepath.IsAbs(os.Getenv("HOME")) {
		return "HOME is not an absolute path; the external runtime workspace root cannot be resolved."
	}
	if errors.Is(err, os.ErrPermission) {
		return "The external runtime workspace is not writable by the Connector."
	}
	if errors.Is(err, syscall.ENOSPC) {
		return "The external runtime workspace cannot be prepared because the device has no free disk space."
	}
	return "The external runtime workspace could not be prepared."
}

// runtimeWorkspaceReadiness reports whether the runtime workspace root this
// device advertises its agent runtimes against can be prepared.
func (c *connector) runtimeWorkspaceReadiness() error {
	if c.runtimeWorkspaceError != nil {
		return c.runtimeWorkspaceError
	}
	return prepareRuntimeWorkspace(c.runtimeWorkspaceRoot)
}

func prepareRuntimeWorkspace(workspace string) error {
	if workspace == "" || !filepath.IsAbs(workspace) {
		return errors.New("external runtime workspace must be absolute")
	}
	if err := os.MkdirAll(workspace, 0o700); err != nil {
		return fmt.Errorf("create external runtime workspace: %w", err)
	}
	return nil
}

func syncDirectory(dir string) error {
	directory, err := os.Open(dir)
	if err != nil {
		return err
	}
	defer directory.Close()
	return directory.Sync()
}
