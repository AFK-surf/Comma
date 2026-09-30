package main

import (
	"archive/tar"
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
)

func newTestWorkspaceArchiver(t *testing.T) (*workspaceArchiver, string) {
	t.Helper()
	home := t.TempDir()
	root := filepath.Join(home, ".comma", "workspaces")
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatal(err)
	}
	return newWorkspaceArchiver(root, true, 72*time.Hour, workspaceArchiveRestoreTimeoutDefault), root
}

func seedWorkspace(t *testing.T, root, sessionID string) {
	t.Helper()
	ws := filepath.Join(root, sessionID)
	if err := os.MkdirAll(filepath.Join(ws, "src"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "src", "main.ex"), []byte("hello"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "notes.md"), []byte("keep me"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(ws, "node_modules", "left-pad"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, "node_modules", "left-pad", "index.js"), []byte("regenerable"), 0o600); err != nil {
		t.Fatal(err)
	}
	for name, content := range map[string]string{
		"package.json":      "{\"dependencies\":{\"left-pad\":\"1.0.0\"}}",
		"package-lock.json": "{\"lockfileVersion\":3}",
	} {
		if err := os.WriteFile(filepath.Join(ws, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(ws, ".git"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ws, ".git", "HEAD"), []byte("ref: refs/heads/main"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("src", filepath.Join(ws, "src-link")); err != nil {
		t.Fatal(err)
	}
}

func ageTree(t *testing.T, path string, age time.Duration) {
	t.Helper()
	stale := time.Now().Add(-age)
	err := filepath.Walk(path, func(p string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		return os.Chtimes(p, stale, stale)
	})
	if err != nil {
		t.Fatal(err)
	}
}

func TestWorkspaceArchiveRestoreRoundtrip(t *testing.T) {
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_100")
	workspace := filepath.Join(root, "ses1_100")
	for name, content := range map[string]string{
		"venvs/document-math/pyvenv.cfg": "home = /usr/bin",
		"venvs/document-math/bin/python": "installed interpreter",
		"venv/notes.txt":                 "user directory without installation marker",
	} {
		path := filepath.Join(workspace, name)
		if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(content), 0600); err != nil {
			t.Fatal(err)
		}
	}
	ageTree(t, filepath.Join(root, "ses1_100"), 96*time.Hour)

	archived, reclaimed := archiver.archiveIdleWorkspaces(context.Background(), workspaceSweepState{})
	if archived != 1 || reclaimed == 0 {
		t.Fatalf("expected one archived workspace with reclaimed bytes, got archived=%d reclaimed=%d", archived, reclaimed)
	}
	if _, err := os.Stat(filepath.Join(root, "ses1_100")); !os.IsNotExist(err) {
		t.Fatalf("workspace still present after archive: %v", err)
	}
	archive := archiver.archivePath("ses1_100")
	if _, err := os.Stat(archive); err != nil {
		t.Fatalf("archive missing: %v", err)
	}

	// The archive keeps source, .git, and symlinks but drops regenerable dirs.
	names := archivedEntryNames(t, archive)
	want := map[string]bool{
		"ses1_100/src":         true,
		"ses1_100/src/main.ex": true,
		"ses1_100/notes.md":    true,
		"ses1_100/.git":        true,
		"ses1_100/.git/HEAD":   true,
		"ses1_100/src-link":    true,
	}
	for name := range names {
		if strings.Contains(name, "node_modules") {
			t.Fatalf("regenerable dir leaked into archive: %s", name)
		}
	}
	for name := range want {
		if !names[name] {
			t.Fatalf("archive is missing expected entry %s", name)
		}
	}

	restored, err := archiver.RestoreIfArchived(context.Background(), "ses1_100")
	if err != nil || !restored {
		t.Fatalf("restore failed: restored=%v err=%v", restored, err)
	}
	content, err := os.ReadFile(filepath.Join(root, "ses1_100", "src", "main.ex"))
	if err != nil || string(content) != "hello" {
		t.Fatalf("restored source mismatch: %q %v", content, err)
	}
	link, err := os.Readlink(filepath.Join(root, "ses1_100", "src-link"))
	if err != nil || link != "src" {
		t.Fatalf("restored symlink mismatch: %q %v", link, err)
	}
	for _, omitted := range []string{"node_modules", "venvs/document-math"} {
		if _, err := os.Stat(filepath.Join(workspace, omitted)); !os.IsNotExist(err) {
			t.Fatalf("workspace installation %s should not be restored: %v", omitted, err)
		}
	}
	if data, err := os.ReadFile(filepath.Join(workspace, "venv/notes.txt")); err != nil || string(data) != "user directory without installation marker" {
		t.Fatalf("user directory changed: %q, %v", data, err)
	}
	info, err := os.Stat(filepath.Join(root, "ses1_100", "src", "main.ex"))
	if err != nil {
		t.Fatal(err)
	}
	if time.Since(info.ModTime()) > time.Minute {
		t.Fatalf("restored files must carry fresh mtimes so the workspace is non-idle, got %v", info.ModTime())
	}

	// A second restore with the workspace present is a no-op.
	restored, err = archiver.RestoreIfArchived(context.Background(), "ses1_100")
	if err != nil || restored {
		t.Fatalf("expected no-op restore, got restored=%v err=%v", restored, err)
	}
}

func TestWorkspaceArchiveSkipsFreshAndActive(t *testing.T) {
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_fresh")
	seedWorkspace(t, root, "ses1_active")
	ageTree(t, filepath.Join(root, "ses1_active"), 96*time.Hour)

	archived, _ := archiver.archiveIdleWorkspaces(context.Background(), workspaceSweepState{ActiveSessions: map[string]bool{"ses1_active": true}})
	if archived != 0 {
		t.Fatalf("fresh and active workspaces must stay, archived=%d", archived)
	}
	if _, err := os.Stat(filepath.Join(root, "ses1_fresh")); err != nil {
		t.Fatalf("fresh workspace removed: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "ses1_active")); err != nil {
		t.Fatalf("active workspace removed: %v", err)
	}
}

func TestWorkspaceRestoreCorruptArchive(t *testing.T) {
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_dead")
	ageTree(t, filepath.Join(root, "ses1_dead"), 96*time.Hour)
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), workspaceSweepState{}); archived != 1 {
		t.Fatalf("archive pass failed")
	}
	archive := archiver.archivePath("ses1_dead")
	if err := os.WriteFile(archive, []byte("this is not a zstd stream"), 0o600); err != nil {
		t.Fatal(err)
	}

	restored, err := archiver.RestoreIfArchived(context.Background(), "ses1_dead")
	if restored || err == nil {
		t.Fatalf("corrupt archive must fail restore, got restored=%v err=%v", restored, err)
	}
	if !errors.Is(err, errWorkspaceArchiveCorrupt) {
		t.Fatalf("corrupt archive must be reported as corrupt, got %v", err)
	}
	if _, statErr := os.Stat(archive); !os.IsNotExist(statErr) {
		t.Fatalf("corrupt archive must be discarded instead of occupying space: %v", statErr)
	}
	if _, statErr := os.Stat(filepath.Join(root, "ses1_dead", ".restore")); statErr == nil {
		t.Fatalf("restore staging dir must be cleaned up")
	}
	// After the corrupt archive is gone, later dispatches proceed fresh
	// without a restore attempt or notice.
	restored, err = archiver.RestoreIfArchived(context.Background(), "ses1_dead")
	if restored || err != nil {
		t.Fatalf("expected silent no-op after discard, got restored=%v err=%v", restored, err)
	}
}

func TestValidArchiveEntry(t *testing.T) {
	for _, name := range []string{"ses1/ok.txt", "ses1/a/b/c.txt"} {
		if !validArchiveEntry(name) {
			t.Fatalf("%q should be valid", name)
		}
	}
	for _, name := range []string{"", "/abs.txt", "../escape.txt", "ses1/../escape", "./relative", "ses1/a//b", "ses1/.."} {
		if validArchiveEntry(name) {
			t.Fatalf("%q should be invalid", name)
		}
	}
	// Bracket-glob names (Next.js dynamic routes) are legal filenames, not
	// traversal; found in production workspaces.
	for _, name := range []string{
		"ses1/comma-pr881-fix/devtools/salix-web-ui/src/routes/admin/runtime/agents/[id]/files/[...path]",
		"ses1/ellipsis-dir...",
	} {
		if !validArchiveEntry(name) {
			t.Fatalf("%q should be valid", name)
		}
	}
}

func TestWorkspaceSessionIDValidation(t *testing.T) {
	for _, id := range []string{"ses1_123", "kimi_abc"} {
		if !validWorkspaceSessionID(id) {
			t.Fatalf("%q should be valid", id)
		}
	}
	for _, id := range []string{"", ".", "..", "a/b", "ses1\x00x"} {
		if validWorkspaceSessionID(id) {
			t.Fatalf("%q should be invalid", id)
		}
	}
}

func archivedEntryNames(t *testing.T, archivePath string) map[string]bool {
	t.Helper()
	file, err := os.Open(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	zr, err := zstd.NewReader(file)
	if err != nil {
		t.Fatal(err)
	}
	defer zr.Close()
	reader := tar.NewReader(zr)
	names := map[string]bool{}
	for {
		header, err := reader.Next()
		if err != nil {
			break
		}
		names[header.Name] = true
	}
	return names
}

func TestWorkspaceRestoreTimesOutWhenArchiverBusy(t *testing.T) {
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_slow")
	ageTree(t, filepath.Join(root, "ses1_slow"), 96*time.Hour)
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), workspaceSweepState{}); archived != 1 {
		t.Fatalf("archive pass failed")
	}

	// Simulate a long-running sweep holding the serialization slot.
	archiver.mu <- struct{}{}
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	restored, err := archiver.RestoreIfArchived(ctx, "ses1_slow")
	<-archiver.mu
	if restored || err == nil {
		t.Fatalf("restore must fail on timeout while archiver is busy, got restored=%v err=%v", restored, err)
	}
	// The archive must survive a timed-out restore attempt.
	if _, statErr := os.Stat(archiver.archivePath("ses1_slow")); statErr != nil {
		t.Fatalf("archive must be kept after timeout: %v", statErr)
	}
}

func TestWorkspaceRestoreCanceledContext(t *testing.T) {
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_cancel")
	ageTree(t, filepath.Join(root, "ses1_cancel"), 96*time.Hour)
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), workspaceSweepState{}); archived != 1 {
		t.Fatalf("archive pass failed")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	restored, err := archiver.RestoreIfArchived(ctx, "ses1_cancel")
	if restored || err == nil {
		t.Fatalf("canceled context must fail restore immediately, got restored=%v err=%v", restored, err)
	}
	if _, statErr := os.Stat(filepath.Join(root, "ses1_cancel")); !os.IsNotExist(statErr) {
		t.Fatalf("canceled restore must not leave a partial workspace")
	}
}

func TestWorkspaceRestoreFailedMessageIsActionable(t *testing.T) {
	deadlineErr := fmt.Errorf("workspace archive restore failed: %w", context.DeadlineExceeded)
	msg := externalRuntimeWorkspaceRestoreFailedMessage(
		"ses1_x", "/home/root/.comma/workspace-archives/ses1_x.tar.zst", "/home/root/.comma/workspaces/ses1_x",
		deadlineErr, 90*time.Second)
	for _, want := range []string{
		"timed out after 1m30s",
		"/home/root/.comma/workspace-archives/ses1_x.tar.zst",
		"/home/root/.comma/workspaces/ses1_x",
		"tar --zstd -xf",
		"--strip-components=1",
		"ses1_x/",
	} {
		if !strings.Contains(msg, want) {
			t.Fatalf("message missing %q in: %s", want, msg)
		}
	}

	plainErr := fmt.Errorf("workspace archive restore failed: magic number mismatch")
	msg = externalRuntimeWorkspaceRestoreFailedMessage(
		"ses1_x", "/a/ses1_x.tar.zst", "/w/ses1_x", plainErr, time.Minute)
	if strings.Contains(msg, "timed out") {
		t.Fatalf("plain failure must not claim a timeout: %s", msg)
	}
	if !strings.Contains(msg, "/a/ses1_x.tar.zst") || !strings.Contains(msg, "tar --zstd -xf") {
		t.Fatalf("plain failure message must stay actionable: %s", msg)
	}
}

func TestWorkspaceRestoreFailedMessageCorruptVariant(t *testing.T) {
	msg := externalRuntimeWorkspaceRestoreFailedMessage(
		"ses1_x", "/a/ses1_x.tar.zst", "/w/ses1_x",
		fmt.Errorf("workspace archive restore failed: %w: magic number mismatch", errWorkspaceArchiveCorrupt), time.Minute)
	if strings.Contains(msg, "The archive itself is intact") || strings.Contains(msg, "tar --zstd -xf") {
		t.Fatalf("corrupt archive message must not invite self-extraction: %s", msg)
	}
	if !strings.Contains(msg, "data-loss") && !strings.Contains(msg, "data loss") {
		t.Fatalf("corrupt archive message must surface data-loss risk: %s", msg)
	}
}

func TestRearchiveOverwritesPreviousArchive(t *testing.T) {
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_re")
	ageTree(t, filepath.Join(root, "ses1_re"), 96*time.Hour)
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), workspaceSweepState{}); archived != 1 {
		t.Fatalf("first archive pass failed")
	}

	// Restore, modify the workspace, let it go idle again, re-archive.
	if restored, err := archiver.RestoreIfArchived(context.Background(), "ses1_re"); err != nil || !restored {
		t.Fatalf("restore failed: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "ses1_re", "notes.md"), []byte("updated"), 0o600); err != nil {
		t.Fatal(err)
	}
	ageTree(t, filepath.Join(root, "ses1_re"), 96*time.Hour)
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), workspaceSweepState{}); archived != 1 {
		t.Fatalf("second archive pass failed")
	}

	// Exactly one archive file, no temp leftovers, and it holds the new content.
	entries, err := os.ReadDir(archiver.archive)
	if err != nil {
		t.Fatal(err)
	}
	if len(entries) != 1 || entries[0].Name() != "ses1_re.tar.zst" {
		t.Fatalf("expected exactly one archive file, got %d entries", len(entries))
	}
	if restored, err := archiver.RestoreIfArchived(context.Background(), "ses1_re"); err != nil || !restored {
		t.Fatalf("re-restore failed: %v", err)
	}
	content, err := os.ReadFile(filepath.Join(root, "ses1_re", "notes.md"))
	if err != nil || string(content) != "updated" {
		t.Fatalf("re-archived content mismatch: %q %v", content, err)
	}
}

func idleSweep(active map[string]bool, activity map[string]int64) workspaceSweepState {
	state := workspaceSweepState{LastActivity: activity}
	if active != nil {
		state.ActiveSessions = active
	}
	return state
}

func TestSweepUnknownActivityFallsBackToMtimes(t *testing.T) {
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_legacy")
	// Fresh files, session absent from the activity map (legacy record):
	// the mtime fallback keeps it on disk.
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), idleSweep(nil, nil)); archived != 0 {
		t.Fatalf("legacy session with fresh files must stay, archived=%d", archived)
	}
	// Aged files with the same absent record: the fallback sweeps it.
	ageTree(t, filepath.Join(root, "ses1_legacy"), 96*time.Hour)
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), idleSweep(nil, nil)); archived != 1 {
		t.Fatalf("legacy session with stale files must archive, got %d", archived)
	}
}

func TestSweepRespectsActivityOverMtimes(t *testing.T) {
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_live")
	ageTree(t, filepath.Join(root, "ses1_live"), 96*time.Hour) // files look idle
	swept := idleSweep(nil, map[string]int64{"ses1_live": time.Now().Unix()})
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), swept); archived != 0 {
		t.Fatalf("session with recent activity must never be archived")
	}
	if _, err := os.Stat(filepath.Join(root, "ses1_live")); err != nil {
		t.Fatalf("workspace removed despite recent activity: %v", err)
	}

	// Same session whose activity is now three days stale gets swept even
	// though fresh file mtimes would otherwise protect it (post-kill state).
	restored, err := archiver.RestoreIfArchived(context.Background(), "ses1_nostale")
	if err != nil || restored {
		t.Fatalf("unexpected restore: %v", err)
	}
	stale := time.Now().Add(-96 * time.Hour).Unix()
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), idleSweep(nil, map[string]int64{"ses1_live": stale})); archived != 1 {
		t.Fatalf("stale activity must archive the session, got %d", archived)
	}
}

func TestSweepKillsStrayProcessBeforeArchiving(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("posix process semantics")
	}
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_stray")
	stray := exec.Command("sleep", "30")
	stray.Dir = filepath.Join(root, "ses1_stray")
	if err := stray.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = stray.Process.Kill() }()
	stale := time.Now().Add(-96 * time.Hour).Unix()
	archived, _ := archiver.archiveIdleWorkspaces(context.Background(), idleSweep(nil, map[string]int64{"ses1_stray": stale}))
	if archived != 1 {
		t.Fatalf("idle session with stray must still archive, got %d", archived)
	}
	waited := make(chan error, 1)
	go func() { waited <- stray.Wait() }()
	select {
	case <-waited:
		// Wait returned: the stray exited (killed by the sweep).
	case <-time.After(2 * time.Second):
		t.Fatalf("stray process should have been terminated")
	}
	if _, err := os.Stat(archiver.archivePath("ses1_stray")); err != nil {
		t.Fatalf("archive missing: %v", err)
	}
}

func TestSweepProtectsSharedRuntimeProcesses(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("posix process semantics")
	}
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_shared")
	shared := exec.Command("sleep", "30")
	shared.Dir = filepath.Join(root, "ses1_shared")
	if err := shared.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = shared.Process.Kill() }()
	time.Sleep(200 * time.Millisecond)
	stale := time.Now().Add(-96 * time.Hour).Unix()
	swept := workspaceSweepState{
		LastActivity: map[string]int64{"ses1_shared": stale},
		RuntimePIDs:  map[int]struct{}{shared.Process.Pid: {}},
	}
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), swept); archived != 1 {
		t.Fatalf("session should archive while protected runtime survives, got %d", archived)
	}
	if err := shared.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("protected shared runtime process must survive: %v", err)
	}
}

func TestSweepLeavesOutsideProcessesAlone(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("posix process semantics")
	}
	archiver, root := newTestWorkspaceArchiver(t)
	seedWorkspace(t, root, "ses1_quiet")
	outside := exec.Command("sleep", "30")
	outside.Dir = t.TempDir()
	if err := outside.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = outside.Process.Kill() }()
	stale := time.Now().Add(-96 * time.Hour).Unix()
	if archived, _ := archiver.archiveIdleWorkspaces(context.Background(), idleSweep(nil, map[string]int64{"ses1_quiet": stale})); archived != 1 {
		t.Fatalf("quiet session should archive, got %d", archived)
	}
	if err := outside.Process.Signal(syscall.Signal(0)); err != nil {
		t.Fatalf("unrelated process must survive the sweep: %v", err)
	}
}
