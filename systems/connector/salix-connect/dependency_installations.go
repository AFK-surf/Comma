package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"
)

const maxDependencyInstallations = 32

type dependencyInstallation struct {
	Path           string   `json:"path"`
	Kind           string   `json:"kind"`
	Manager        string   `json:"manager"`
	WorkingDir     string   `json:"working_directory,omitempty"`
	Packages       []string `json:"packages,omitempty"`
	Omitted        bool     `json:"omitted,omitempty"`
	RestorePending bool     `json:"restore_pending,omitempty"`
	Paused         bool     `json:"paused,omitempty"`
	Attempted      bool     `json:"attempted,omitempty"`
}

type dependencyInstallManifest struct {
	Entries map[string]dependencyInstallation `json:"entries"`
}

type dependencyInstallJob struct {
	Status    string
	Path      string
	StartedAt time.Time
	Error     string
	Completed int
	Total     int
	Cancel    context.CancelFunc
}

func (c *connector) dependencyManifestPath() string {
	return filepath.Join(c.root, ".salix", "dependency-installations.json")
}

func (c *connector) readDependencyManifest() (dependencyInstallManifest, error) {
	manifest := dependencyInstallManifest{Entries: map[string]dependencyInstallation{}}
	raw, err := os.ReadFile(c.dependencyManifestPath())
	if os.IsNotExist(err) {
		return manifest, nil
	}
	if err != nil {
		return manifest, err
	}
	if err := json.Unmarshal(raw, &manifest); err != nil || manifest.Entries == nil || len(manifest.Entries) > maxDependencyInstallations {
		return dependencyInstallManifest{}, errors.New("invalid dependency declarations")
	}
	return manifest, nil
}

func (c *connector) writeDependencyManifest(manifest dependencyInstallManifest) error {
	path := c.dependencyManifestPath()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	raw, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	file, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	if _, err = file.Write(raw); err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err := os.Rename(path+".tmp", path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

func (c *connector) declaredPath(raw string) (string, error) {
	if !filepath.IsAbs(raw) || strings.ContainsRune(raw, 0) {
		return "", errors.New("dependency path must be absolute")
	}
	root, err := filepath.EvalSymlinks(c.root)
	if err != nil {
		return "", err
	}
	resolved, err := filepath.EvalSymlinks(raw)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(resolved)
	if err != nil || !info.IsDir() {
		return "", errors.New("dependency directory is unavailable")
	}
	rel, err := filepath.Rel(root, resolved)
	if err != nil || rel == "." || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
		return "", errors.New("dependency path is outside this VM")
	}
	return filepath.ToSlash(rel), nil
}

func (c *connector) methodDependencyInstallations(params map[string]any) (any, error) {
	if os.Getenv("SALIX_MANAGED_RUNTIME_ROOT") == "" {
		return nil, errors.New("managed VM required")
	}
	action, _ := params["action"].(string)
	c.dependencyMu.Lock()
	defer c.dependencyMu.Unlock()
	manifest, err := c.readDependencyManifest()
	if err != nil {
		return nil, err
	}
	switch action {
	case "list":
		return c.dependencyResult(manifest), nil
	case "declare":
		path, _ := params["path"].(string)
		rel, err := c.declaredPath(path)
		if err != nil {
			return nil, err
		}
		kind, _ := params["kind"].(string)
		manager, _ := params["manager"].(string)
		if (kind != "tool" && kind != "repository") || !allowedDependencyManager(manager) {
			return nil, errors.New("invalid dependency kind or manager")
		}
		if _, found := manifest.Entries[rel]; !found && len(manifest.Entries) == maxDependencyInstallations {
			return nil, errors.New("too many dependency directories")
		}
		entry := dependencyInstallation{Path: rel, Kind: kind, Manager: manager}
		if kind == "repository" {
			working, _ := params["working_directory"].(string)
			entry.WorkingDir, err = c.declaredPath(working)
			if err != nil {
				return nil, err
			}
		} else {
			list, ok := params["packages"].([]any)
			if !ok || len(list) == 0 || len(list) > 32 {
				return nil, errors.New("tool dependencies must name 1-32 packages")
			}
			for _, item := range list {
				name, ok := item.(string)
				if !ok || len(name) == 0 || len(name) > 128 || strings.HasPrefix(name, "-") || strings.ContainsAny(name, " \t\n\r\x00") {
					return nil, errors.New("invalid package name")
				}
				entry.Packages = append(entry.Packages, name)
			}
		}
		manifest.Entries[rel] = entry
		if err := c.writeDependencyManifest(manifest); err != nil {
			return nil, err
		}
		return c.dependencyResult(manifest), nil
	case "remove":
		path, _ := params["path"].(string)
		if !filepath.IsAbs(path) {
			return nil, errors.New("dependency path must be absolute")
		}
		// A deleted path cannot be resolved. Match the original absolute path
		// against the stored source root without following its final component.
		root, err := filepath.EvalSymlinks(c.root)
		if err != nil {
			return nil, err
		}
		parent, err := filepath.EvalSymlinks(filepath.Dir(filepath.Clean(path)))
		if err != nil {
			return nil, err
		}
		rel, err := filepath.Rel(root, filepath.Join(parent, filepath.Base(path)))
		if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
			return nil, errors.New("dependency path is outside this VM")
		}
		key := filepath.ToSlash(rel)
		delete(manifest.Entries, key)
		if err := c.writeDependencyManifest(manifest); err != nil {
			return nil, err
		}
		if job := c.dependencyInstall; job != nil && job.Path == key && job.Status == "running" {
			job.Status = "stopping"
			job.Cancel()
		}
		return c.dependencyResult(manifest), nil
	case "cancel":
		for key, entry := range manifest.Entries {
			if entry.RestorePending {
				entry.Paused = true
				manifest.Entries[key] = entry
			}
		}
		if err := c.writeDependencyManifest(manifest); err != nil {
			return nil, err
		}
		if c.dependencyInstall != nil && c.dependencyInstall.Status == "running" {
			c.dependencyInstall.Status = "stopping"
			c.dependencyInstall.Cancel()
		}
		return c.dependencyResult(manifest), nil
	case "start":
		if job := c.dependencyInstall; job != nil && (job.Status == "running" || job.Status == "stopping") {
			return c.dependencyResult(manifest), nil
		}
		for key, entry := range manifest.Entries {
			entry.Paused = false
			entry.Attempted = false
			manifest.Entries[key] = entry
		}
		if err := c.writeDependencyManifest(manifest); err != nil {
			return nil, err
		}
		c.startDependencyInstallLocked(manifest)
		return c.dependencyResult(manifest), nil
	default:
		return nil, errors.New("unknown dependency action")
	}
}

func allowedDependencyManager(manager string) bool {
	switch manager {
	case "npm", "pnpm", "yarn", "bun", "pip", "uv", "manual":
		return true
	default:
		return false
	}
}

func (c *connector) dependencyResult(manifest dependencyInstallManifest) map[string]any {
	result := map[string]any{"entries": manifest.Entries}
	if job := c.dependencyInstall; job != nil {
		result["installation"] = map[string]any{
			"status": job.Status, "path": job.Path,
			"started_at": job.StartedAt.UnixMilli(), "elapsed_ms": time.Since(job.StartedAt).Milliseconds(),
			"completed": job.Completed, "total": job.Total, "error": job.Error,
		}
	} else {
		for _, entry := range manifest.Entries {
			if entry.RestorePending && entry.Attempted && !entry.Paused {
				result["installation"] = map[string]any{"status": "unknown", "error": "previous installer may still be running; inspect and stop it before retrying or installing directly"}
				break
			}
		}
	}
	return result
}

func (c *connector) prepareDependencyInstallationsForArchive() error {
	c.dependencyMu.Lock()
	defer c.dependencyMu.Unlock()
	if job := c.dependencyInstall; job != nil && (job.Status == "running" || job.Status == "stopping") {
		return errors.New("dependency installation is still running")
	}
	manifest, err := c.readDependencyManifest()
	if err != nil {
		return err
	}
	if len(manifest.Entries) == 0 {
		return nil
	}
	for key, entry := range manifest.Entries {
		path := filepath.Join(c.root, filepath.FromSlash(key))
		info, err := os.Lstat(path)
		if os.IsNotExist(err) {
			if !entry.RestorePending {
				delete(manifest.Entries, key)
			}
			continue
		}
		if err != nil {
			return err
		}
		if !info.IsDir() {
			delete(manifest.Entries, key)
			continue
		}
		// New Group archives retain installation trees, including local edits.
		// A declaration schedules rebuilds only for previously omitted archives.
		entry.Omitted, entry.RestorePending, entry.Attempted = false, false, false
		manifest.Entries[key] = entry
	}
	return c.writeDependencyManifest(manifest)
}

// The source manifest never gains restore work just because export started.
// Only the archive copy records directories that were omitted.
func (c *connector) archivedDependencyManifest() ([]byte, error) {
	manifest, err := c.readDependencyManifest()
	if err != nil {
		return nil, err
	}
	for key, entry := range manifest.Entries {
		entry.RestorePending = entry.Omitted && !entry.Paused
		manifest.Entries[key] = entry
	}
	return json.Marshal(manifest)
}

func (c *connector) startRestoredDependencyInstall() {
	if os.Getenv("SALIX_MANAGED_RUNTIME_ROOT") == "" {
		return
	}
	c.cloudRuntimeMu.Lock()
	quiesced := c.cloudRuntimeQuiesced
	c.cloudRuntimeMu.Unlock()
	if quiesced {
		return
	}
	receipt := filepath.Join(c.runtimeStateRoot(), "provider-import", "receipt.json")
	raw, err := os.ReadFile(receipt)
	if err != nil {
		return
	}
	var restored cloudProviderMigration
	if json.Unmarshal(raw, &restored) != nil || restored.Phase != "restored" {
		return
	}
	c.dependencyMu.Lock()
	defer c.dependencyMu.Unlock()
	manifest, err := c.readDependencyManifest()
	if err == nil && c.dependencyInstall == nil {
		for _, entry := range manifest.Entries {
			if entry.Omitted && entry.RestorePending && !entry.Paused && !entry.Attempted {
				c.startDependencyInstallLocked(manifest)
				break
			}
		}
	}
}

func (c *connector) startDependencyInstallLocked(manifest dependencyInstallManifest) {
	if c.dependencyInstall != nil && (c.dependencyInstall.Status == "running" || c.dependencyInstall.Status == "stopping") {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	job := &dependencyInstallJob{Status: "running", StartedAt: time.Now(), Cancel: cancel}
	queued := dependencyInstallManifest{Entries: map[string]dependencyInstallation{}}
	for key, entry := range manifest.Entries {
		if entry.Omitted && entry.RestorePending && !entry.Paused && !entry.Attempted {
			job.Total++
			entry.Attempted = true
			manifest.Entries[key] = entry
			queued.Entries[key] = entry
		}
	}
	if err := c.writeDependencyManifest(manifest); err != nil {
		cancel()
		c.dependencyInstall = &dependencyInstallJob{Status: "failed", StartedAt: time.Now(), Error: "installation state unavailable"}
		return
	}
	c.dependencyInstall = job
	go c.runDependencyInstall(ctx, job, queued)
}

func (c *connector) runDependencyInstall(ctx context.Context, job *dependencyInstallJob, manifest dependencyInstallManifest) {
	defer job.Cancel()
	keys := make([]string, 0, len(manifest.Entries))
	for key := range manifest.Entries {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	manualRequired := false
	for _, key := range keys {
		c.dependencyMu.Lock()
		current, readErr := c.readDependencyManifest()
		entry, found := current.Entries[key]
		if readErr == nil && found && entry.Omitted && entry.RestorePending && !entry.Paused {
			job.Path = key
		}
		c.dependencyMu.Unlock()
		if readErr != nil {
			c.finishDependencyInstall(job, "failed", "installation state unavailable")
			return
		}
		if !found || !entry.Omitted || !entry.RestorePending || entry.Paused {
			continue
		}
		if !automaticDependencyInstallSupported(entry) {
			manualRequired = true
			c.dependencyMu.Lock()
			job.Completed++
			c.dependencyMu.Unlock()
			continue
		}
		if err := ctx.Err(); err != nil {
			c.finishDependencyInstall(job, "cancelled", "")
			return
		}
		err := c.installDependency(ctx, entry)
		if err != nil {
			if ctx.Err() != nil {
				c.finishDependencyInstall(job, "cancelled", "")
			} else {
				c.finishDependencyInstall(job, "failed", err.Error())
			}
			return
		}
		c.dependencyMu.Lock()
		current, readErr = c.readDependencyManifest()
		if readErr == nil {
			if currentEntry, found := current.Entries[key]; found && currentEntry.RestorePending && !currentEntry.Paused {
				currentEntry.RestorePending = false
				current.Entries[key] = currentEntry
				readErr = c.writeDependencyManifest(current)
			}
		}
		c.dependencyMu.Unlock()
		if readErr != nil {
			c.finishDependencyInstall(job, "failed", "installation state unavailable")
			return
		}
		c.dependencyMu.Lock()
		job.Completed++
		c.dependencyMu.Unlock()
	}
	if manualRequired {
		c.finishDependencyInstall(job, "needs_agent_install", "some declared packages need an agent install")
	} else {
		c.finishDependencyInstall(job, "completed", "")
	}
}

func automaticDependencyInstallSupported(entry dependencyInstallation) bool {
	switch entry.Kind {
	case "repository":
		working := filepath.FromSlash(entry.WorkingDir)
		if entry.Manager == "npm" || entry.Manager == "pnpm" || entry.Manager == "bun" {
			return filepath.Clean(filepath.FromSlash(entry.Path)) == filepath.Join(working, "node_modules")
		}
		return entry.Manager == "pip" && strings.HasPrefix(filepath.FromSlash(entry.Path), working+string(filepath.Separator))
	case "tool":
		if entry.Manager == "npm" {
			return entry.Path == ".salix/sprite-home/.local/lib/node_modules"
		}
		return entry.Manager == "pip" && entry.Path == ".salix/sprite-home/.local/lib/python3.13/site-packages"
	default:
		return false
	}
}

func (c *connector) finishDependencyInstall(job *dependencyInstallJob, status, message string) {
	c.dependencyMu.Lock()
	defer c.dependencyMu.Unlock()
	if c.dependencyInstall == job {
		job.Status, job.Error = status, message
	}
}

func (c *connector) installDependency(ctx context.Context, entry dependencyInstallation) error {
	path := filepath.Join(c.root, filepath.FromSlash(entry.Path))
	working := filepath.Join(c.root, filepath.FromSlash(entry.WorkingDir))
	var commands [][]string
	switch {
	case entry.Kind == "repository" && entry.Manager == "npm":
		commands = [][]string{{"npm", "ci"}}
	case entry.Kind == "repository" && entry.Manager == "pnpm":
		commands = [][]string{{"pnpm", "install", "--frozen-lockfile"}}
	case entry.Kind == "repository" && entry.Manager == "bun":
		commands = [][]string{{"bun", "install", "--frozen-lockfile"}}
	case entry.Kind == "repository" && entry.Manager == "pip":
		commands = [][]string{{"python3", "-m", "venv", path}, {filepath.Join(path, "bin", "python"), "-m", "pip", "install", "-r", filepath.Join(working, "requirements.txt")}}
	case entry.Kind == "tool" && entry.Manager == "npm":
		if entry.Path != ".salix/sprite-home/.local/lib/node_modules" {
			return errors.New("automatic npm tool installation needs the global Node directory")
		}
		prefix := filepath.Dir(filepath.Dir(path))
		commands = [][]string{append([]string{"npm", "install", "--global", "--prefix", prefix}, entry.Packages...)}
	case entry.Kind == "tool" && entry.Manager == "pip":
		if !strings.HasPrefix(entry.Path, ".salix/sprite-home/.local/lib/python3.") || !strings.HasSuffix(entry.Path, "/site-packages") {
			return errors.New("automatic pip tool installation needs the user site-packages directory")
		}
		commands = [][]string{append([]string{"python3", "-m", "pip", "install", "--user"}, entry.Packages...)}
	default:
		return errors.New("automatic installation is unavailable; agent can install directly")
	}
	for _, argv := range commands {
		command := exec.CommandContext(ctx, argv[0], argv[1:]...)
		command.Dir = working
		if entry.Kind == "tool" {
			command.Dir = c.root
		}
		log := &limitedInstallLog{limit: 4096}
		command.Stdout, command.Stderr = log, log
		command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		command.Cancel = func() error {
			if command.Process == nil {
				return nil
			}
			return syscall.Kill(-command.Process.Pid, syscall.SIGKILL)
		}
		if err := command.Run(); err != nil {
			return fmt.Errorf("%s install failed: %w: %s", entry.Manager, err, log.String())
		}
	}
	if info, err := os.Stat(path); err != nil || !info.IsDir() {
		return errors.New("installer finished without the declared directory")
	}
	return nil
}

type limitedInstallLog struct {
	mu    sync.Mutex
	limit int
	data  []byte
}

func (l *limitedInstallLog) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if len(p) >= l.limit {
		l.data = append(l.data[:0], p[len(p)-l.limit:]...)
	} else {
		if len(l.data)+len(p) > l.limit {
			l.data = append([]byte(nil), l.data[len(l.data)+len(p)-l.limit:]...)
		}
		l.data = append(l.data, p...)
	}
	return len(p), nil
}

func (l *limitedInstallLog) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return string(l.data)
}
