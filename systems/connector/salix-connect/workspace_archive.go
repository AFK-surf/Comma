package main

import (
	"archive/tar"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/klauspost/compress/zstd"
)

// Workspace archival keeps long-idle external runtime workspaces available
// without paying their full on-disk cost. Idle workspaces are packed into a
// verified tar+zst archive under ~/.comma/workspace-archives and removed from
// the workspaces root. When a session receives new input, the archive is
// extracted back before the runtime starts. Restores deliberately drop
// mtimes so an extracted workspace is immediately non-idle, which also
// prevents an archive pass from racing a just-restored workspace.
const (
	workspaceArchiveDirName       = "workspace-archives"
	workspaceArchiveSuffix        = ".tar.zst"
	workspaceArchiveCheckInterval = 10 * time.Minute
	workspaceArchiveIdleDefault   = 72 * time.Hour
	workspaceArchiveZstdLevel     = zstd.SpeedDefault
	workspaceArchiveTmpSuffix     = ".tmp"
	// Restore runs on the inbound dispatch path: a stuck or huge extraction
	// must degrade to a fresh workspace instead of blocking dispatch forever.
	workspaceArchiveRestoreTimeoutDefault = 60 * time.Second
	// Archival runs on the background sweep; bound each workspace so one
	// pathological tree cannot stall the sweep or hold the archiver mutex
	// indefinitely against incoming restores.
	workspaceArchiveArchiveTimeout = 10 * time.Minute
)

// Regenerable directories never enter an archive. Universal names only:
// generic names such as bin/obj/Library are project-type specific and stay
// archived to avoid dropping non-regenerable content by accident.
var workspaceArchiveSkipDirs = map[string]bool{
	".angular": true, ".expo": true, ".metro": true,
	".turbo": true, ".next": true, ".nuxt": true,
	".cache": true, ".elixir-tools": true,
	".elixir_ls": true, ".lexical": true,
	".xwin-cache": true, ".build": true,
	"DerivedData": true, "__pycache__": true, "__pypackages__": true,
	".pytest_cache": true, ".mypy_cache": true, ".ruff_cache": true, ".tox": true,
	".nox": true, ".pixi": true, ".ipynb_checkpoints": true,
	".gradle": true, ".stack-work": true,
	"zig-cache": true, ".zig-cache": true,
	"cmake-build-debug": true, "cmake-build-release": true,
	".godot-cache": true,
	".dart_tool":   true, ".parcel-cache": true, ".vite": true, ".svelte-kit": true,
	".cxx": true, ".externalNativeBuild": true, ".kotlin": true, "CMakeFiles": true,
}

// errWorkspaceArchiveCorrupt marks archives that can never be restored
// (decode or integrity failure). Corrupt archives are discarded instead of
// occupying space and failing every future dispatch.
var errWorkspaceArchiveCorrupt = errors.New("workspace archive corrupt")

type workspaceArchiver struct {
	mu             chan struct{} // serializes archive/restore passes
	root           string        // workspaces root
	archive        string        // archive directory
	idle           time.Duration
	restoreTimeout time.Duration
	enabled        bool
	runtimeState   *externalRuntimeState
}

func newWorkspaceArchiver(workspaceRoot string, enabled bool, idle, restoreTimeout time.Duration) *workspaceArchiver {
	if idle <= 0 {
		idle = workspaceArchiveIdleDefault
	}
	if restoreTimeout <= 0 {
		restoreTimeout = workspaceArchiveRestoreTimeoutDefault
	}
	return &workspaceArchiver{
		mu:             make(chan struct{}, 1),
		root:           workspaceRoot,
		archive:        filepath.Join(filepath.Dir(workspaceRoot), workspaceArchiveDirName),
		idle:           idle,
		restoreTimeout: restoreTimeout,
		enabled:        enabled && workspaceRoot != "",
	}
}

// acquire takes the serialization slot or fails when ctx finishes first, so
// neither a slow sweep nor a slow restore can block the other path forever.
func (a *workspaceArchiver) acquire(ctx context.Context) error {
	select {
	case a.mu <- struct{}{}:
		return nil
	case <-ctx.Done():
		return ctx.Err()
	}
}

func (a *workspaceArchiver) archivePath(sessionID string) string {
	return filepath.Join(a.archive, sessionID+workspaceArchiveSuffix)
}

// workspaceSweepState carries everything an idle-close pass needs: sessions
// with in-flight executions (never touched), the latest activity time per
// session (the primary idleness signal), and the pids of shared runtime
// processes (never terminated).
type workspaceSweepState struct {
	ActiveSessions map[string]bool
	LastActivity   map[string]int64
	RuntimePIDs    map[int]struct{}
}

// archiveIdleWorkspaces closes and packs every session idle beyond the
// threshold. Idleness is decided by session activity (input batches and
// runtime events); sessions without an activity record (created before
// tracking existed) fall back to workspace mtimes. Idle-close first
// terminates session-owned stray processes whose cwd is inside the
// workspace (dev servers and similar), while shared runtime processes stay
// untouched; if any stray survives termination the workspace is kept and
// retried on a later pass.
func (a *workspaceArchiver) archiveIdleWorkspaces(ctx context.Context, sweep workspaceSweepState) (archived int, reclaimed int64) {
	if !a.enabled {
		return 0, 0
	}
	entries, err := os.ReadDir(a.root)
	if err != nil {
		return 0, 0
	}
	cutoff := time.Now().Add(-a.idle).Unix()
	for _, entry := range entries {
		if !entry.IsDir() || !validWorkspaceSessionID(entry.Name()) || sweep.ActiveSessions[entry.Name()] {
			continue
		}
		sessionID := entry.Name()
		dir := filepath.Join(a.root, sessionID)
		activity, tracked := sweep.LastActivity[sessionID]
		if tracked {
			if activity >= cutoff {
				continue
			}
		} else {
			idle, _, err := workspaceIdleAndSize(dir, a.idle)
			if err != nil || !idle {
				continue
			}
		}

		var size int64
		_, size, _ = workspaceIdleAndSize(dir, a.idle)
		if err := a.archiveOne(ctx, sessionID, sweep.RuntimePIDs); err != nil {
			logf("workspace archive failed session=%s: %v", sessionID, err)
			continue
		}
		archived++
		reclaimed += size
	}
	return archived, reclaimed
}

// archiveOne packs the workspace into a verified archive and removes the
// original directory only after the archive decodes cleanly and captured
// every archivable entry. Each workspace is bounded by
// workspaceArchiveArchiveTimeout.
func (a *workspaceArchiver) archiveOne(ctx context.Context, sessionID string, runtimePIDs map[int]struct{}) error {
	if !a.enabled || !validWorkspaceSessionID(sessionID) {
		return errors.New("workspace archive unavailable")
	}
	ctx, cancel := context.WithTimeout(ctx, workspaceArchiveArchiveTimeout)
	defer cancel()
	if err := a.acquire(ctx); err != nil {
		return err
	}
	defer func() { <-a.mu }()
	if a.runtimeState != nil {
		if err := a.runtimeState.migrationAllowsArchive(sessionID); err != nil {
			return err
		}
	}
	workspace := filepath.Join(a.root, sessionID)
	if len(findWorkspaceProcesses(workspace, runtimePIDs)) > 0 {
		for _, line := range killWorkspaceProcesses(ctx, workspace, runtimePIDs) {
			logf("idle session stray terminated session=%s %s", sessionID, line)
		}
		if len(findWorkspaceProcesses(workspace, runtimePIDs)) > 0 {
			return errors.New("workspace stray processes remain")
		}
	}
	if _, err := os.Stat(workspace); err != nil {
		return err
	}
	if err := os.MkdirAll(a.archive, 0o700); err != nil {
		return err
	}
	final := a.archivePath(sessionID)
	tmp := final + workspaceArchiveTmpSuffix
	packed, err := writeWorkspaceArchive(ctx, workspace, sessionID, tmp)
	if err != nil {
		_ = os.Remove(tmp)
		return err
	}
	verified, err := verifyWorkspaceArchive(ctx, tmp)
	if err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("workspace archive verification failed: %w", err)
	}
	expected := countArchivableEntries(workspace)
	if verified != packed || packed != expected {
		// The tree changed while archiving; keep the workspace and retry on
		// a later pass rather than trust a partial archive.
		_ = os.Remove(tmp)
		return fmt.Errorf("workspace changed during archive: wrote %d, verified %d, expected %d entries", packed, verified, expected)
	}
	if err := os.Rename(tmp, final); err != nil {
		_ = os.Remove(tmp)
		return err
	}
	if err := os.RemoveAll(workspace); err != nil {
		return err
	}
	logf("workspace archived session=%s entries=%d", sessionID, packed)
	return nil
}

// RestoreIfArchived extracts the archive back into the workspaces root when
// the workspace directory is absent. Extracted files get current mtimes so
// the restored workspace is immediately non-idle.
func (a *workspaceArchiver) RestoreIfArchived(ctx context.Context, sessionID string) (bool, error) {
	if !a.enabled || !validWorkspaceSessionID(sessionID) {
		return false, nil
	}
	workspace := filepath.Join(a.root, sessionID)
	if _, err := os.Stat(workspace); err == nil {
		return false, nil
	} else if !errors.Is(err, fs.ErrNotExist) {
		return false, err
	}
	archive := a.archivePath(sessionID)
	if _, err := os.Stat(archive); err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	// Restore runs on the dispatch path. On timeout (or caller
	// cancellation) it degrades to the restore-failed path instead of
	// blocking dispatch forever; the extraction aborts and cleans its
	// staging directory once it observes the deadline.
	ctx, cancel := context.WithTimeout(ctx, a.restoreTimeout)
	defer cancel()
	if err := a.acquire(ctx); err != nil {
		return false, fmt.Errorf("workspace archive restore failed: %w", err)
	}
	defer func() { <-a.mu }()
	if err := extractWorkspaceArchive(ctx, archive, workspace); err != nil {
		if errors.Is(err, errWorkspaceArchiveCorrupt) {
			// The archive can never be restored; discard it so it stops
			// occupying space and failing every future dispatch.
			if removeErr := os.Remove(archive); removeErr != nil && !errors.Is(removeErr, fs.ErrNotExist) {
				logf("workspace archive corrupt but removal failed session=%s: %v", sessionID, removeErr)
			} else {
				logf("workspace archive corrupt, discarded session=%s", sessionID)
			}
		}
		return false, fmt.Errorf("workspace archive restore failed: %w", err)
	}
	logf("workspace restored session=%s", sessionID)
	return true, nil
}

func validWorkspaceSessionID(sessionID string) bool {
	if sessionID == "" || sessionID == "." || sessionID == ".." ||
		filepath.Base(sessionID) != sessionID || strings.Contains(sessionID, "/") {
		return false
	}
	for _, r := range sessionID {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}

// workspaceIdleAndSize reports whether every activity signal under dir is at
// least idle old, plus the tree's regular-file byte size. Symlink mtimes are
// creation-time only and never refreshed by activity, so they are ignored;
// regular files and directories carry the real recency signal.
func workspaceIdleAndSize(dir string, idle time.Duration) (bool, int64, error) {
	cutoff := time.Now().Add(-idle)
	var newest time.Time
	var size int64
	isIdle := true
	err := filepath.WalkDir(dir, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		if info.ModTime().After(newest) {
			newest = info.ModTime()
		}
		if info.Mode().IsRegular() {
			size += info.Size()
		}
		if newest.After(cutoff) {
			isIdle = false
			return filepath.SkipAll
		}
		return nil
	})
	if err != nil && !errors.Is(err, filepath.SkipAll) {
		return false, 0, err
	}
	return isIdle, size, nil
}

func countArchivableEntries(workspace string) int {
	count := 0
	_ = filepath.WalkDir(workspace, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(workspace, path)
		if err != nil || rel == "." {
			return err
		}
		if entry.IsDir() && (workspaceArchiveSkipDirs[entry.Name()] || installedDependencyDir(path, filepath.ToSlash(rel), entry)) {
			return filepath.SkipDir
		}
		count++
		return nil
	})
	return count
}

// writeWorkspaceArchive streams a tar of the workspace (minus regenerable
// directories) through zstd into destination and returns the entry count.
func writeWorkspaceArchive(ctx context.Context, workspace, sessionID, destination string) (int, error) {
	file, err := os.OpenFile(destination, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return 0, err
	}
	defer file.Close()
	encoder, err := zstd.NewWriter(file, zstd.WithEncoderLevel(workspaceArchiveZstdLevel))
	if err != nil {
		return 0, err
	}
	tw := tar.NewWriter(encoder)
	count := 0
	err = filepath.WalkDir(workspace, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(workspace, path)
		if err != nil || rel == "." {
			return err
		}
		if entry.IsDir() && (workspaceArchiveSkipDirs[entry.Name()] || installedDependencyDir(path, filepath.ToSlash(rel), entry)) {
			return filepath.SkipDir
		}
		info, err := entry.Info()
		if err != nil {
			return err
		}
		link := ""
		if entry.Type()&fs.ModeSymlink != 0 {
			link, err = os.Readlink(path)
			if err != nil {
				return err
			}
		}
		header, err := tar.FileInfoHeader(info, link)
		if err != nil {
			return err
		}
		header.Name = sessionID + "/" + filepath.ToSlash(rel)
		header.Uname = ""
		header.Gname = ""
		var content io.Reader
		if info.Mode().IsRegular() {
			f, err := os.Open(path)
			if err != nil {
				return err
			}
			defer f.Close()
			content = f
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		if err := tw.WriteHeader(header); err != nil {
			return err
		}
		if content != nil {
			if err := copyChunked(ctx, tw, content); err != nil {
				return err
			}
		}
		count++
		return nil
	})
	if err != nil {
		_ = encoder.Close()
		return 0, err
	}
	if err := tw.Close(); err != nil {
		return 0, err
	}
	if err := encoder.Close(); err != nil {
		return 0, err
	}
	return count, nil
}

// verifyWorkspaceArchive fully decodes the archive (integrity check) and
// returns its entry count, rejecting unsafe entry names.
func verifyWorkspaceArchive(ctx context.Context, path string) (int, error) {
	file, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer file.Close()
	decoder, err := zstd.NewReader(file)
	if err != nil {
		return 0, err
	}
	defer decoder.Close()
	reader := tar.NewReader(decoder)
	count := 0
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return count, err
		}
		if !validArchiveEntry(header.Name) {
			return count, fmt.Errorf("unsafe archive entry %q", header.Name)
		}
		if err := ctx.Err(); err != nil {
			return count, err
		}
		if _, err := io.Copy(io.Discard, reader); err != nil {
			return count, err
		}
		count++
	}
	return count, nil
}

func extractWorkspaceArchive(ctx context.Context, archivePath, workspace string) error {
	file, err := os.Open(archivePath)
	if err != nil {
		return err
	}
	defer file.Close()
	decoder, err := zstd.NewReader(file)
	if err != nil {
		return err
	}
	defer decoder.Close()
	if err := os.MkdirAll(filepath.Dir(workspace), 0o700); err != nil {
		return err
	}
	staging := workspace + ".restore" + workspaceArchiveTmpSuffix
	_ = os.RemoveAll(staging)
	if err := os.MkdirAll(staging, 0o700); err != nil {
		return err
	}
	fail := func(err error) error {
		_ = os.RemoveAll(staging)
		return err
	}
	failCorrupt := func(err error) error {
		_ = os.RemoveAll(staging)
		return fmt.Errorf("%w: %v", errWorkspaceArchiveCorrupt, err)
	}
	reader := tar.NewReader(decoder)
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return failCorrupt(err)
		}
		if err := ctx.Err(); err != nil {
			return fail(err)
		}
		if !validArchiveEntry(header.Name) {
			return fail(fmt.Errorf("%w: unsafe archive entry %q", errWorkspaceArchiveCorrupt, header.Name))
		}
		// Archive entries carry a session-id prefix directory; strip it so the
		// workspace contents land directly in the staging root.
		parts := strings.SplitN(header.Name, "/", 2)
		if len(parts) != 2 || parts[1] == "" {
			return fail(fmt.Errorf("unexpected archive entry %q", header.Name))
		}
		target := filepath.Join(staging, filepath.FromSlash(parts[1]))
		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, fs.FileMode(header.Mode).Perm()); err != nil {
				return fail(err)
			}
		case tar.TypeReg:
			if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
				return fail(err)
			}
			out, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, fs.FileMode(header.Mode).Perm())
			if err != nil {
				return fail(err)
			}
			if err := copyChunked(ctx, out, reader); err != nil {
				out.Close()
				return fail(err)
			}
			out.Close()
		case tar.TypeSymlink:
			if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
				return fail(err)
			}
			if err := os.Symlink(header.Linkname, target); err != nil {
				return fail(err)
			}
		default:
			// Rare entry types (devices, fifos, hardlinks) are skipped; a
			// workspace that needs them reports the gap on next use.
		}
	}
	if err := os.Rename(staging, workspace); err != nil {
		return fail(err)
	}
	return nil
}

// validArchiveEntry rejects absolute paths and per-segment traversal. The
// check is segment-exact: "..." and bracket-glob directory names such as
// Next.js "[...path]" routes are legal filenames, only a literal ".."
// segment escapes the archive root.
func validArchiveEntry(name string) bool {
	if name == "" || strings.HasPrefix(name, "/") {
		return false
	}
	for _, segment := range strings.Split(name, "/") {
		if segment == "" || segment == "." || segment == ".." {
			return false
		}
	}
	return true
}

// copyChunked copies with periodic deadline checks so a stuck copy cannot
// outlive the surrounding context.
func copyChunked(ctx context.Context, dst io.Writer, src io.Reader) error {
	buffer := make([]byte, 256*1024)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		n, err := src.Read(buffer)
		if n > 0 {
			if _, werr := dst.Write(buffer[:n]); werr != nil {
				return werr
			}
		}
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
	}
}

func (c *connector) externalRuntimeWorkspaceArchiveLoop(ctx context.Context) {
	archiver := c.workspaceArchiver
	if archiver == nil || !archiver.enabled {
		return
	}
	ticker := time.NewTicker(workspaceArchiveCheckInterval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			state := workspaceSweepState{
				ActiveSessions: c.externalRuntimeState.workspaceSessionIDs(),
				LastActivity:   c.externalRuntimeState.sessionActivity(),
				RuntimePIDs:    runtimeProcessPIDs(c.runtimeImplementations),
			}
			archived, reclaimed := archiver.archiveIdleWorkspaces(ctx, state)
			if archived > 0 {
				logf("workspace archive pass archived=%d reclaimed_bytes=%d", archived, reclaimed)
			}
		}
	}
}
