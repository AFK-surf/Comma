package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/klauspost/compress/zstd"
	bolt "go.etcd.io/bbolt"
)

const migrationFileLimit = 100_000
const migrationByteLimit int64 = 16 << 30

type runtimeMigrationFile struct {
	Name     string    `json:"name"`
	Size     int64     `json:"size"`
	Mode     int64     `json:"mode"`
	Link     string    `json:"link,omitempty"`
	Kind     byte      `json:"kind"`
	Modified time.Time `json:"modified"`
	Source   string    `json:"-"`
	info     fs.FileInfo
}

type runtimeMigrationManifest struct {
	OperationID string                         `json:"operation_id"`
	Identity    externalRuntimeSessionIdentity `json:"identity"`
	Files       []runtimeMigrationFile         `json:"files"`
	Bytes       int64                          `json:"bytes"`
}

type runtimeDiscardPlan struct {
	Seal             externalRuntimeMigrationSeal `json:"scope"`
	Paths            []string                     `json:"paths"`
	NoNativeIdentity bool                         `json:"no_native_identity,omitempty"`
}

// roots contains only the selected workspace and native Session paths. Walking
// them never follows symlinks or silently excludes build/untracked files.
func migrationFileManifest(ctx context.Context, roots map[string]string) ([]runtimeMigrationFile, int64, error) {
	files := []runtimeMigrationFile{}
	hardlinks := map[[2]uint64]string{}
	var total int64
	for name, root := range roots {
		selected, err := os.Lstat(root)
		if err != nil {
			return nil, 0, err
		}
		if selected.Mode()&os.ModeSymlink != 0 {
			return nil, 0, fmt.Errorf("migration selected root is a symlink: %s", root)
		}
		root, err = filepath.EvalSymlinks(root)
		if err != nil {
			return nil, 0, err
		}
		err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			if len(files) >= migrationFileLimit {
				return errors.New("migration exceeds 100000 files")
			}
			info, err := entry.Info()
			if err != nil {
				return err
			}
			rel, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			file := runtimeMigrationFile{Name: filepath.ToSlash(filepath.Join(name, rel)), Mode: int64(info.Mode().Perm()), Modified: info.ModTime(), Source: path}
			file.info = info
			switch {
			case info.Mode().IsRegular():
				file.Kind, file.Size = tar.TypeReg, info.Size()
				if stat, ok := info.Sys().(*syscall.Stat_t); ok && stat.Nlink > 1 {
					key := [2]uint64{uint64(stat.Dev), uint64(stat.Ino)}
					if previous, ok := hardlinks[key]; ok {
						file.Kind, file.Link, file.Size = tar.TypeLink, previous, 0
					} else {
						hardlinks[key] = file.Name
					}
				}
				total += file.Size
			case info.IsDir():
				file.Kind = tar.TypeDir
			case info.Mode()&os.ModeSymlink != 0:
				link, err := os.Readlink(path)
				if err != nil {
					return err
				}
				resolved, err := filepath.EvalSymlinks(path)
				if err != nil {
					return fmt.Errorf("migration link cannot be resolved: %s: %w", path, err)
				}
				destination, err := filepath.Rel(root, resolved)
				if err != nil || destination == ".." || strings.HasPrefix(destination, ".."+string(filepath.Separator)) {
					return fmt.Errorf("migration link leaves its selected root: %s", path)
				}
				if filepath.IsAbs(link) {
					link, err = filepath.Rel(filepath.Dir(path), resolved)
					if err != nil {
						return err
					}
				}
				file.Kind, file.Link = tar.TypeSymlink, filepath.ToSlash(link)
			default:
				return fmt.Errorf("unsupported migration file: %s (%s)", path, info.Mode())
			}
			if info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 {
				return fmt.Errorf("unsupported special file permissions: %s", path)
			}
			if total > migrationByteLimit {
				return errors.New("migration exceeds 16 GiB")
			}
			files = append(files, file)
			return nil
		})
		if err != nil {
			return nil, 0, err
		}
	}
	return files, total, nil
}

func copyMigrationFile(ctx context.Context, output io.Writer, input io.Reader, size int64) error {
	limited := &io.LimitedReader{R: input, N: size}
	if err := copyChunked(ctx, output, limited); err != nil {
		return err
	}
	if limited.N != 0 {
		return io.ErrUnexpectedEOF
	}
	return nil
}

func writeMigrationArchive(ctx context.Context, output io.Writer, manifest runtimeMigrationManifest) error {
	compressed, err := zstd.NewWriter(output, zstd.WithEncoderConcurrency(1))
	if err != nil {
		return err
	}
	defer compressed.Close()
	archive := tar.NewWriter(compressed)
	raw, err := json.Marshal(manifest)
	if err != nil {
		return err
	}
	if len(raw) > 32<<20 {
		return errors.New("migration manifest exceeds 32 MiB")
	}
	if err := archive.WriteHeader(&tar.Header{Name: "manifest.json", Mode: 0600, Size: int64(len(raw))}); err != nil {
		return err
	}
	if _, err := archive.Write(raw); err != nil {
		return err
	}
	for _, file := range manifest.Files {
		if err := ctx.Err(); err != nil {
			return err
		}
		info, err := os.Lstat(file.Source)
		if err != nil {
			return err
		}
		if file.info == nil || !os.SameFile(file.info, info) || info.ModTime() != file.Modified || int64(info.Mode().Perm()) != file.Mode || file.Kind == tar.TypeReg && info.Size() != file.Size {
			return fmt.Errorf("migration source changed: %s", file.Name)
		}
		if err := archive.WriteHeader(&tar.Header{Name: file.Name, Typeflag: file.Kind, Mode: file.Mode, Size: file.Size, Linkname: file.Link, ModTime: file.Modified}); err != nil {
			return err
		}
		if file.Kind == tar.TypeReg {
			input, err := os.Open(file.Source)
			if err != nil {
				return err
			}
			opened, err := input.Stat()
			if err != nil || !os.SameFile(info, opened) {
				input.Close()
				return fmt.Errorf("migration source replaced: %s", file.Name)
			}
			copyErr := copyMigrationFile(ctx, archive, input, file.Size)
			after, statErr := input.Stat()
			closeErr := input.Close()
			if copyErr != nil {
				return copyErr
			}
			if statErr != nil || after.Size() != file.Size || !after.ModTime().Equal(file.Modified) {
				return fmt.Errorf("migration source changed during copy: %s", file.Name)
			}
			if closeErr != nil {
				return closeErr
			}
		}
	}
	if err := archive.Close(); err != nil {
		return err
	}
	return compressed.Close()
}

func extractMigrationArchive(ctx context.Context, input io.Reader, staging, operationID, sessionID string) (runtimeMigrationManifest, error) {
	var manifest runtimeMigrationManifest
	compressed, err := zstd.NewReader(input, zstd.WithDecoderConcurrency(1), zstd.WithDecoderMaxMemory(64<<20))
	if err != nil {
		return manifest, err
	}
	defer compressed.Close()
	archive := tar.NewReader(compressed)
	header, err := archive.Next()
	if err != nil {
		return manifest, err
	}
	if header.Name != "manifest.json" || header.Size > 32<<20 || header.Typeflag != tar.TypeReg {
		return manifest, errors.New("invalid migration manifest")
	}
	if err := json.NewDecoder(io.LimitReader(archive, header.Size)).Decode(&manifest); err != nil {
		return manifest, err
	}
	if manifest.OperationID != operationID || manifest.Identity.SessionID != sessionID || len(manifest.Files) > migrationFileLimit || manifest.Bytes < 0 || manifest.Bytes > migrationByteLimit {
		return manifest, errors.New("migration manifest scope or bounds mismatch")
	}
	var disk syscall.Statfs_t
	if err := syscall.Statfs(staging, &disk); err != nil {
		return manifest, err
	}
	if uint64(manifest.Bytes) > uint64(disk.Bavail)*uint64(disk.Bsize) {
		return manifest, errors.New("migration target has insufficient space for the declared files")
	}
	links := []runtimeMigrationFile{}
	directories := []runtimeMigrationFile{}
	seen := map[string]byte{}
	var total int64
	for _, file := range manifest.Files {
		if err := ctx.Err(); err != nil {
			return manifest, err
		}
		if !validMigrationPath(file.Name) || seen[file.Name] != 0 || file.Size < 0 || file.Mode < 0 || file.Mode > 0777 {
			return manifest, errors.New("invalid migration file")
		}
		seen[file.Name] = file.Kind
		header, err := archive.Next()
		if err != nil {
			return manifest, err
		}
		if header.Name != file.Name || header.Typeflag != file.Kind || header.Size != file.Size || header.Mode != file.Mode || header.Linkname != file.Link {
			return manifest, errors.New("archive does not match migration manifest")
		}
		destination := filepath.Join(staging, filepath.FromSlash(file.Name))
		if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
			return manifest, err
		}
		switch file.Kind {
		case tar.TypeDir:
			if err := os.MkdirAll(destination, 0700); err != nil {
				return manifest, err
			}
			directories = append(directories, file)
		case tar.TypeReg:
			total += file.Size
			if total > manifest.Bytes {
				return manifest, errors.New("migration size exceeds manifest")
			}
			output, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
			if err != nil {
				return manifest, err
			}
			copyErr := copyMigrationFile(ctx, output, archive, file.Size)
			syncErr := output.Sync()
			closeErr := output.Close()
			if copyErr != nil {
				return manifest, copyErr
			}
			if syncErr != nil {
				return manifest, syncErr
			}
			if closeErr != nil {
				return manifest, closeErr
			}
			if err := os.Chmod(destination, os.FileMode(file.Mode)); err != nil {
				return manifest, err
			}
		case tar.TypeSymlink:
			resolved := filepath.ToSlash(filepath.Clean(filepath.Join(filepath.Dir(file.Name), file.Link)))
			if filepath.IsAbs(file.Link) || !validMigrationPath(resolved) || strings.SplitN(resolved, "/", 2)[0] != strings.SplitN(file.Name, "/", 2)[0] {
				return manifest, errors.New("migration link leaves its selected root")
			}
			links = append(links, file)
		case tar.TypeLink:
			if !validMigrationPath(file.Link) || seen[file.Link] != tar.TypeReg {
				return manifest, errors.New("migration hard link has no selected file")
			}
			links = append(links, file)
		default:
			return manifest, errors.New("unsupported migration archive entry")
		}
	}
	if _, err := archive.Next(); err != io.EOF {
		return manifest, errors.New("unexpected trailing migration data")
	}
	if total != manifest.Bytes {
		return manifest, errors.New("migration byte count mismatch")
	}
	for _, file := range links {
		destination := filepath.Join(staging, filepath.FromSlash(file.Name))
		if file.Kind == tar.TypeLink {
			if err := os.Link(filepath.Join(staging, filepath.FromSlash(file.Link)), destination); err != nil {
				return manifest, err
			}
		} else {
			resolved := filepath.ToSlash(filepath.Clean(filepath.Join(filepath.Dir(file.Name), file.Link)))
			if seen[resolved] == 0 {
				return manifest, errors.New("migration link references an unselected entry")
			}
			if err := os.Symlink(file.Link, destination); err != nil {
				return manifest, err
			}
		}
	}
	for index := len(directories) - 1; index >= 0; index-- {
		file := directories[index]
		if err := os.Chmod(filepath.Join(staging, filepath.FromSlash(file.Name)), os.FileMode(file.Mode)); err != nil {
			return manifest, err
		}
	}
	return manifest, syncDirectory(staging)
}

func validMigrationPath(name string) bool {
	return name != "" && !strings.Contains(name, "\\") && !strings.HasPrefix(name, "/") &&
		filepath.ToSlash(filepath.Clean(name)) == name && (name == "workspace" || strings.HasPrefix(name, "workspace/") || strings.HasPrefix(name, "native/"))
}

func (c *connector) migrationNativePaths(ctx context.Context, identity externalRuntimeSessionIdentity) (map[string]string, error) {
	roots := map[string]string{"workspace": identity.Workspace}
	switch identity.Provider {
	case "codex":
		implementation, ok := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
		if !ok {
			return nil, errors.New("Codex migration runtime is unavailable")
		}
		input := externalRuntimeInput{sessionID: identity.SessionID, command: identity.Command, workspace: identity.Workspace, payload: identity.Payload}
		runtime, err := implementation.ensureRuntime(ctx, input, &codexRuntimeSession{})
		if err != nil {
			return nil, err
		}
		if err := runtime.ensureInitialized(ctx); err != nil {
			return nil, err
		}
		id := stringParam(identity.Payload, "thread_id")
		result, err := runtime.rpc(ctx, "thread/read", map[string]any{"threadId": id, "includeTurns": false}, 10*time.Second)
		if err != nil {
			return nil, err
		}
		thread := mapParam(result, "thread")
		if id == "" || stringParam(thread, "id") != id {
			return nil, errors.New("Codex migration native identity changed")
		}
		path := stringParam(thread, "path")
		rel, err := filepath.Rel(filepath.Dir(codexConfigPath()), path)
		if err != nil || (!strings.HasPrefix(filepath.ToSlash(rel), "sessions/") && !strings.HasPrefix(filepath.ToSlash(rel), "archived_sessions/")) {
			return nil, errors.New("Codex native rollout is outside the supported sessions layout")
		}
		roots["native/"+filepath.ToSlash(rel)] = path
	case "claude":
		id := stringParam(identity.Payload, "session_id")
		if !validClaudeSessionID(id) {
			return nil, errors.New("Claude migration native identity is invalid")
		}
		settings, err := runtimeAuthClaudeLocation()
		if err != nil {
			return nil, err
		}
		base := filepath.Dir(settings)
		path, err := findMigrationNativeFile(ctx, filepath.Join(base, "projects"), func(path string) bool { return filepath.Base(path) == id+".jsonl" })
		if err != nil {
			return nil, err
		}
		rel, _ := filepath.Rel(base, path)
		roots["native/"+filepath.ToSlash(rel)] = path
		sidecar := strings.TrimSuffix(path, ".jsonl")
		if _, err := os.Lstat(sidecar); err == nil {
			roots["native/"+filepath.ToSlash(strings.TrimSuffix(rel, ".jsonl"))] = sidecar
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
	case "pi":
		base := filepath.Join(c.runtimeStateRoot(), "external-runtime", "pi", identity.SessionID)
		id := stringParam(identity.Payload, "session_id")
		if id == "" || filepath.Base(id) != id {
			return nil, errors.New("Pi migration native identity is invalid")
		}
		_, err := findMigrationNativeFile(ctx, base, func(path string) bool { return strings.HasSuffix(filepath.Base(path), "_"+id+".jsonl") })
		if err != nil {
			return nil, err
		}
		roots["native/pi/"+identity.SessionID] = base
	default:
		return nil, errors.New("unsupported migration provider")
	}
	return roots, nil
}

func findMigrationNativeFile(ctx context.Context, root string, match func(string) bool) (string, error) {
	count, found := 0, ""
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if err := ctx.Err(); err != nil {
			return err
		}
		count++
		if count > migrationFileLimit {
			return errors.New("native Session lookup exceeds 100000 entries")
		}
		if entry.Type().IsRegular() && match(path) {
			if found != "" {
				return errors.New("native Session file is ambiguous")
			}
			found = path
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	if found == "" {
		return "", errors.New("native Session file is missing")
	}
	return found, nil
}

func validateMigrationNativeFile(ctx context.Context, path string, identity externalRuntimeSessionIdentity, availableWorkspace string) error {
	input, err := os.Open(path)
	if err != nil {
		return err
	}
	defer input.Close()
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 64<<10), 16<<20)
	matched := false
	for scanner.Scan() {
		if err := ctx.Err(); err != nil {
			return err
		}
		var row map[string]any
		if err := json.Unmarshal(scanner.Bytes(), &row); err != nil {
			return fmt.Errorf("native Session JSONL is unreadable: %w", err)
		}
		switch identity.Provider {
		case "codex":
			if stringParam(row, "type") == "session_meta" {
				matched = stringParam(mapParam(row, "payload"), "id") == stringParam(identity.Payload, "thread_id")
			}
		case "claude":
			if id := stringParam(row, "sessionId"); id != "" {
				if id != stringParam(identity.Payload, "session_id") {
					return errors.New("Claude native Session identity mismatch")
				}
				matched = true
			}
		case "pi":
			if stringParam(row, "type") == "session" {
				matched = stringParam(row, "id") == stringParam(identity.Payload, "session_id")
			}
		}
		if _, err := migrationFileReferences(row, identity.Workspace, availableWorkspace, ""); err != nil {
			return err
		}
	}
	if err := scanner.Err(); err != nil {
		return err
	}
	if !matched {
		return errors.New("native Session identity is missing or different")
	}
	return nil
}

// Only typed file references are relocated; user/tool text is never rewritten.
func migrationFileReferences(value any, workspace, availableWorkspace, destinationWorkspace string) (bool, error) {
	changed := false
	switch value := value.(type) {
	case map[string]any:
		if stringParam(value, "type") == "local_image" {
			path := stringParam(value, "path")
			if !filepath.IsAbs(path) {
				path = filepath.Join(workspace, path)
			}
			rel, err := filepath.Rel(workspace, path)
			if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				return false, errors.New("native Session references an image outside the selected workspace")
			}
			if _, err := os.Stat(filepath.Join(availableWorkspace, rel)); err != nil {
				return false, fmt.Errorf("native Session image is unavailable: %w", err)
			}
			if destinationWorkspace != "" {
				replacement := filepath.Join(destinationWorkspace, rel)
				changed = replacement != stringParam(value, "path")
				value["path"] = replacement
			}
		}
		for _, item := range value {
			nested, err := migrationFileReferences(item, workspace, availableWorkspace, destinationWorkspace)
			if err != nil {
				return false, err
			}
			changed = changed || nested
		}
	case []any:
		for _, item := range value {
			nested, err := migrationFileReferences(item, workspace, availableWorkspace, destinationWorkspace)
			if err != nil {
				return false, err
			}
			changed = changed || nested
		}
	}
	return changed, nil
}

func (c *connector) prepareSessionMigration(ctx context.Context, seal externalRuntimeMigrationSeal, token string) error {
	if c.externalRuntimeState == nil || c.externalRuntimeState.db == nil {
		return errExternalRuntimeStateDisabled
	}
	if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
		return migrationDurableQuiet(tx, seal.Provider+"\x00"+seal.SessionID, token)
	}); err != nil {
		return err
	}
	var err error
	switch implementation := c.runtimeImplementations[seal.Provider].(type) {
	case *codexRuntimeImplementation:
		err = implementation.quietSessions(ctx, seal.SessionID)
	case *claudeRuntimeImplementation:
		err = implementation.quietSessions(ctx, seal.SessionID)
	case *piRuntimeImplementation:
		err = implementation.quietSessions(ctx, seal.SessionID)
	default:
		return errors.New("unsupported migration provider")
	}
	if err != nil {
		return err
	}
	a := c.workspaceArchiver
	if a == nil {
		return errors.New("migration workspace owner is unavailable")
	}
	if err := a.acquire(ctx); err != nil {
		return err
	}
	defer func() { <-a.mu }()
	if err := c.externalRuntimeState.prepareMigration(seal, token); err != nil {
		return err
	}
	c.externalRuntimeState.mu.Lock()
	identity, exists := c.externalRuntimeState.identities[seal.Provider+"\x00"+seal.SessionID]
	c.externalRuntimeState.mu.Unlock()
	if !exists {
		return errors.New("migration source identity is unavailable")
	}
	if identity.Workspace != filepath.Join(a.root, seal.SessionID) {
		return errors.New("migration source workspace is outside the managed Session directory")
	}
	if _, err := os.Stat(identity.Workspace); errors.Is(err, os.ErrNotExist) {
		// Unlike the normal restore path, migration never deletes a corrupt
		// archive or substitutes an empty workspace.
		return extractWorkspaceArchive(ctx, a.archivePath(seal.SessionID), identity.Workspace)
	} else {
		return err
	}
}

var externalRuntimeMigrationBucket = []byte("session-migration-seals-v1")
var errRuntimeMigrationFrozen = errors.New("session migration has closed source execution admission")

func (c *connector) methodSessionMigration(ctx context.Context, action string, params map[string]any) (map[string]any, error) {
	if c.externalRuntimeState == nil || c.externalRuntimeState.db == nil {
		return nil, errExternalRuntimeStateDisabled
	}
	seal := externalRuntimeMigrationSeal{OperationID: stringParam(params, "operation_id"), Provider: stringParam(params, "provider"),
		SessionID: stringParam(params, "session_id"), Source: stringParam(params, "source"), Target: stringParam(params, "destination"), Deadline: int64Param(params, "deadline", 0)}
	if seal.OperationID == "" || len(seal.OperationID) > 128 || strings.Trim(seal.OperationID, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != "" ||
		!canonicalExternalRuntimeSessionID.MatchString(seal.SessionID) || seal.Source == "" || seal.Target == "" {
		return nil, errors.New("invalid migration operation scope")
	}
	token := stringParam(params, "capability_token")
	if action == "prepare" && boolParam(params, "cancel") {
		return c.cancelSessionMigration(ctx, seal)
	}
	if action == "prepare" || action == "export" || action == "import" {
		deadline := time.UnixMilli(seal.Deadline)
		if action == "import" && boolParam(params, "activate") && boolParam(params, "repair") {
			// Explicit forward repair has a bounded command budget. It does not
			// change the original Session migration deadline or reopen its source.
			deadline = time.Now().Add(30 * time.Minute)
		}
		if !time.Now().Before(deadline) {
			return nil, errors.New("migration deadline elapsed; cancel before retirement or repair forward afterward")
		}
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, deadline)
		defer cancel()
	}
	if action == "retire" || action == "export" {
		if err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
			previous, err := runtimeMigrationSeal(tx, seal.Provider+"\x00"+seal.SessionID)
			if err != nil {
				return err
			}
			if previous == nil || previous.OperationID != seal.OperationID || previous.Source != seal.Source || previous.Target != seal.Target {
				return errors.New("migration scope changed")
			}
			return nil
		}); err != nil {
			return nil, err
		}
	}
	switch action {
	case "prepare":
		if err := c.prepareSessionMigration(ctx, seal, token); err != nil {
			return nil, err
		}
		return map[string]any{"phase": "prepared"}, nil
	case "retire":
		if err := c.externalRuntimeState.retireMigration(seal.Provider, seal.SessionID, seal.OperationID, token); err != nil {
			return nil, err
		}
		return map[string]any{"phase": "retired"}, nil
	case "export":
		return c.exportSessionMigration(ctx, seal, params)
	case "import":
		return c.importSessionMigration(ctx, seal, params)
	case "status":
		if c.cfg.runtimeAgent {
			directory := filepath.Join(c.runtimeStateRoot(), "session-migrations", seal.OperationID, seal.SessionID)
			if err := checkMigrationDirectoryScope(directory, seal); err != nil {
				return nil, err
			}
			if _, err := os.Stat(filepath.Join(directory, "complete.json")); err == nil {
				c.externalRuntimeState.mu.Lock()
				identity, exists := c.externalRuntimeState.identities[seal.Provider+"\x00"+seal.SessionID]
				c.externalRuntimeState.mu.Unlock()
				if !exists || !boolParam(identity.Payload, "require_native_resume") {
					return nil, errors.New("migration receipt has no durable target identity; repair target before retirement")
				}
				if operation := stringParam(identity.Payload, "migration_operation_id"); operation != "" && operation != seal.OperationID {
					return nil, errors.New("migration target belongs to another operation")
				}
				return map[string]any{"phase": "staged"}, nil
			} else if !errors.Is(err, os.ErrNotExist) {
				return nil, err
			}
			if info, err := os.Stat(filepath.Join(directory, "import.tar.zst")); err == nil {
				return map[string]any{"phase": "receiving", "next_offset": info.Size()}, nil
			} else if !errors.Is(err, os.ErrNotExist) {
				return nil, err
			}
			return map[string]any{"phase": "absent", "next_offset": int64(0)}, nil
		}
		var previous *externalRuntimeMigrationSeal
		err := c.externalRuntimeState.db.View(func(tx *bolt.Tx) error {
			var err error
			previous, err = runtimeMigrationSeal(tx, seal.Provider+"\x00"+seal.SessionID)
			return err
		})
		if err != nil {
			return nil, err
		}
		if previous == nil {
			return map[string]any{"phase": "absent"}, nil
		}
		if previous.OperationID != seal.OperationID || previous.Source != seal.Source || previous.Target != seal.Target {
			return nil, errors.New("migration scope changed")
		}
		return map[string]any{"phase": previous.Phase}, nil
	case "discard":
		if token == "" {
			return nil, errors.New("archive discard requires the exact source capability")
		}
		if err := c.discardSessionRuntime(ctx, seal, token); err != nil {
			return nil, err
		}
		return map[string]any{"phase": "discarded"}, nil
	default:
		return nil, errors.New("unsupported migration action")
	}
}

func (c *connector) discardSessionRuntime(ctx context.Context, seal externalRuntimeMigrationSeal, token string) error {
	directory := filepath.Join(c.runtimeStateRoot(), "session-discards", seal.OperationID, seal.SessionID)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	scopePath := filepath.Join(directory, "scope.json")
	if _, err := os.Stat(scopePath); errors.Is(err, os.ErrNotExist) {
		raw, marshalErr := json.Marshal(seal)
		if marshalErr != nil {
			return marshalErr
		}
		if err := writeMigrationReceipt(scopePath, raw); err != nil {
			return err
		}
	} else if err != nil {
		return err
	} else if err := checkMigrationDirectoryScope(directory, seal); err != nil {
		return err
	}
	if complete, err := discardComplete(directory, seal); err != nil {
		return err
	} else if complete {
		return nil
	}
	if err := c.externalRuntimeState.prepareDiscard(seal, token); err != nil {
		return err
	}
	var quietErr error
	switch implementation := c.runtimeImplementations[seal.Provider].(type) {
	case *codexRuntimeImplementation:
		quietErr = implementation.quietSessions(ctx, seal.SessionID)
	case *claudeRuntimeImplementation:
		quietErr = implementation.quietSessions(ctx, seal.SessionID)
	case *piRuntimeImplementation:
		quietErr = implementation.quietSessions(ctx, seal.SessionID)
	default:
		return errors.New("unsupported archive discard provider")
	}
	if quietErr != nil {
		return quietErr
	}
	if c.workspaceArchiver == nil {
		return errors.New("archive discard workspace owner is unavailable")
	}
	if err := c.workspaceArchiver.acquire(ctx); err != nil {
		return err
	}
	defer func() { <-c.workspaceArchiver.mu }()

	planPath := filepath.Join(directory, "plan.json")
	plan, err := c.loadOrCreateDiscardPlan(ctx, planPath, seal)
	if err != nil {
		return err
	}
	for _, path := range plan.Paths {
		if err := os.RemoveAll(path); err != nil {
			return fmt.Errorf("archive discard remove %s: %w", path, err)
		}
	}
	if err := c.externalRuntimeState.discardSession(seal.Provider, seal.SessionID, seal.OperationID, token); err != nil {
		return err
	}
	result, _ := json.Marshal(map[string]any{"phase": "discarded", "session_id": seal.SessionID})
	return writeMigrationReceipt(filepath.Join(directory, "complete.json"), result)
}

func (c *connector) loadOrCreateDiscardPlan(ctx context.Context, path string, seal externalRuntimeMigrationSeal) (runtimeDiscardPlan, error) {
	var plan runtimeDiscardPlan
	if raw, err := os.ReadFile(path); err == nil {
		if json.Unmarshal(raw, &plan) != nil || plan.Seal != seal || len(plan.Paths) == 0 || len(plan.Paths) > 8 {
			return plan, errors.New("archive discard plan is invalid or belongs to another operation")
		}
		return plan, c.validateDiscardPlan(plan)
	} else if !errors.Is(err, os.ErrNotExist) {
		return plan, err
	}

	key := seal.Provider + "\x00" + seal.SessionID
	c.externalRuntimeState.mu.Lock()
	identity, exists := c.externalRuntimeState.identities[key]
	c.externalRuntimeState.mu.Unlock()
	workspace := filepath.Join(c.workspaceArchiver.root, seal.SessionID)
	native := []string{}
	if exists {
		if identity.Provider != seal.Provider || identity.SessionID != seal.SessionID {
			return plan, errors.New("archive discard source identity changed")
		}
		if identity.Workspace != workspace {
			return plan, errors.New("archive discard workspace is outside the managed Session directory")
		}
		var err error
		native, err = c.discardNativePaths(ctx, identity)
		if err != nil {
			return plan, err
		}
	}
	// A Session can be archived before a provider establishes its native
	// identity. In that case there is no native file that this owner can name;
	// keep the plan to the two fixed, Session-ID-scoped Comma paths.
	paths := append([]string{workspace, c.workspaceArchiver.archivePath(seal.SessionID)}, native...)
	for _, candidate := range paths {
		if !filepath.IsAbs(candidate) {
			return plan, errors.New("archive discard path is not absolute")
		}
		if info, err := os.Lstat(candidate); err == nil && info.Mode()&os.ModeSymlink != 0 {
			return plan, errors.New("archive discard refuses a selected root symlink")
		} else if err != nil && !errors.Is(err, os.ErrNotExist) {
			return plan, err
		}
	}
	plan = runtimeDiscardPlan{Seal: seal, Paths: paths, NoNativeIdentity: !exists}
	if err := c.validateDiscardPlan(plan); err != nil {
		return plan, err
	}
	raw, err := json.Marshal(plan)
	if err != nil {
		return plan, err
	}
	return plan, writeMigrationReceipt(path, raw)
}

func discardComplete(directory string, seal externalRuntimeMigrationSeal) (bool, error) {
	raw, err := os.ReadFile(filepath.Join(directory, "complete.json"))
	if errors.Is(err, os.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	var receipt map[string]any
	if json.Unmarshal(raw, &receipt) != nil || stringParam(receipt, "phase") != "discarded" ||
		stringParam(receipt, "session_id") != seal.SessionID {
		return false, errors.New("archive discard completion receipt is invalid")
	}
	return true, nil
}

func (c *connector) validateDiscardPlan(plan runtimeDiscardPlan) error {
	if len(plan.Paths) < 2 || plan.Paths[0] != filepath.Join(c.workspaceArchiver.root, plan.Seal.SessionID) ||
		plan.Paths[1] != c.workspaceArchiver.archivePath(plan.Seal.SessionID) {
		return errors.New("archive discard plan changed its managed workspace scope")
	}
	if plan.NoNativeIdentity {
		if plan.Seal.Provider != "codex" && plan.Seal.Provider != "claude" && plan.Seal.Provider != "pi" {
			return errors.New("archive discard plan has an unsupported provider")
		}
		if len(plan.Paths) != 2 {
			return errors.New("archive discard plan without native identity changed scope")
		}
		return nil
	}
	if len(plan.Paths) < 3 {
		return errors.New("archive discard plan omitted its native Session path")
	}
	var roots []string
	switch plan.Seal.Provider {
	case "codex":
		base := filepath.Dir(codexConfigPath())
		roots = []string{filepath.Join(base, "sessions"), filepath.Join(base, "archived_sessions")}
	case "claude":
		settings, err := runtimeAuthClaudeLocation()
		if err != nil {
			return err
		}
		roots = []string{filepath.Join(filepath.Dir(settings), "projects")}
	case "pi":
		roots = []string{filepath.Join(c.runtimeStateRoot(), "external-runtime", "pi", plan.Seal.SessionID)}
	default:
		return errors.New("archive discard plan has an unsupported provider")
	}
	seen := map[string]bool{}
	for index, candidate := range plan.Paths {
		if !filepath.IsAbs(candidate) || seen[candidate] {
			return errors.New("archive discard plan has an invalid or duplicate path")
		}
		seen[candidate] = true
		if index < 2 {
			continue
		}
		inside := false
		for _, root := range roots {
			rel, err := filepath.Rel(root, candidate)
			if err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator)) {
				inside = true
				break
			}
		}
		if !inside {
			return errors.New("archive discard native path leaves its provider scope")
		}
	}
	if plan.Seal.Provider == "pi" && (len(plan.Paths) != 3 || plan.Paths[2] != roots[0]) {
		return errors.New("Pi archive discard plan changed its Session directory")
	}
	return nil
}

func (c *connector) discardNativePaths(ctx context.Context, identity externalRuntimeSessionIdentity) ([]string, error) {
	switch identity.Provider {
	case "codex":
		id := stringParam(identity.Payload, "thread_id")
		if id == "" || filepath.Base(id) != id {
			return nil, errors.New("Codex archive discard native identity is invalid")
		}
		base := filepath.Dir(codexConfigPath())
		return findDiscardNativeFiles(ctx, []string{filepath.Join(base, "sessions"), filepath.Join(base, "archived_sessions")}, func(path string) bool {
			name := filepath.Base(path)
			return name == id+".jsonl" || strings.HasSuffix(name, "-"+id+".jsonl")
		})
	case "claude":
		id := stringParam(identity.Payload, "session_id")
		if !validClaudeSessionID(id) {
			return nil, errors.New("Claude archive discard native identity is invalid")
		}
		settings, err := runtimeAuthClaudeLocation()
		if err != nil {
			return nil, err
		}
		file, err := findMigrationNativeFile(ctx, filepath.Join(filepath.Dir(settings), "projects"), func(path string) bool {
			return filepath.Base(path) == id+".jsonl"
		})
		if err != nil {
			return nil, err
		}
		paths := []string{file}
		if _, err := os.Lstat(strings.TrimSuffix(file, ".jsonl")); err == nil {
			paths = append(paths, strings.TrimSuffix(file, ".jsonl"))
		} else if !errors.Is(err, os.ErrNotExist) {
			return nil, err
		}
		return paths, nil
	case "pi":
		id := stringParam(identity.Payload, "session_id")
		base := filepath.Join(c.runtimeStateRoot(), "external-runtime", "pi", identity.SessionID)
		if id == "" || filepath.Base(id) != id {
			return nil, errors.New("Pi archive discard native identity is invalid")
		}
		if _, err := findMigrationNativeFile(ctx, base, func(path string) bool {
			return strings.HasSuffix(filepath.Base(path), "_"+id+".jsonl")
		}); err != nil {
			return nil, err
		}
		return []string{base}, nil
	default:
		return nil, errors.New("unsupported archive discard provider")
	}
}

func findDiscardNativeFiles(ctx context.Context, roots []string, match func(string) bool) ([]string, error) {
	count := 0
	found := ""
	for _, root := range roots {
		if _, err := os.Lstat(root); errors.Is(err, os.ErrNotExist) {
			continue
		} else if err != nil {
			return nil, err
		}
		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if err := ctx.Err(); err != nil {
				return err
			}
			count++
			if count > migrationFileLimit {
				return errors.New("archive discard native lookup exceeds 100000 entries")
			}
			if entry.Type().IsRegular() && match(path) {
				if found != "" {
					return errors.New("archive discard native Session file is ambiguous")
				}
				found = path
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	if found == "" {
		return nil, errors.New("archive discard native Session file is missing")
	}
	return []string{found}, nil
}

func (c *connector) cancelSessionMigration(ctx context.Context, seal externalRuntimeMigrationSeal) (map[string]any, error) {
	if err := c.workspaceArchiver.acquire(ctx); err != nil {
		return nil, err
	}
	defer func() { <-c.workspaceArchiver.mu }()
	directory := filepath.Join(c.runtimeStateRoot(), "session-migrations", seal.OperationID, seal.SessionID)
	if err := checkMigrationDirectoryScope(directory, seal); err != nil {
		return nil, err
	}
	s := c.externalRuntimeState
	key := seal.Provider + "\x00" + seal.SessionID
	s.mu.Lock()
	defer s.mu.Unlock()
	err := s.db.Update(func(tx *bolt.Tx) error {
		if c.cfg.runtimeAgent {
			identity, exists := s.identities[key]
			if !exists {
				return nil
			}
			if stringParam(identity.Payload, "migration_operation_id") != seal.OperationID {
				return errors.New("migration target has already activated or belongs to another operation")
			}
			prefix := []byte(key + "\x00")
			input, _ := tx.Bucket(externalRuntimeInputBatchesBucket).Cursor().Seek(prefix)
			if tx.Bucket(externalRuntimeActiveExecutionsBucket).Get([]byte(key)) != nil || bytes.HasPrefix(input, prefix) {
				return errRuntimeNotQuiet
			}
			return tx.Bucket(externalRuntimeIdentitiesBucket).Delete([]byte(key))
		}
		previous, err := runtimeMigrationSeal(tx, key)
		if err != nil {
			return err
		}
		if previous == nil {
			return nil
		}
		if previous.OperationID != seal.OperationID || previous.Source != seal.Source || previous.Target != seal.Target || previous.Phase != "prepared" {
			return errors.New("retired or different migration cannot be cancelled")
		}
		return tx.Bucket(externalRuntimeMigrationBucket).Delete([]byte(key))
	})
	if err != nil {
		return nil, err
	}
	if c.cfg.runtimeAgent {
		if identity, exists := s.identities[key]; exists {
			s.removeRuntimeSessionLocked(identity)
			delete(s.identities, key)
			s.rebuildRuntimeSessionSnapshotsLocked()
		}
	}
	if err := os.RemoveAll(directory); err != nil {
		return nil, err
	}
	return map[string]any{"phase": "cancelled"}, nil
}

func checkMigrationDirectoryScope(directory string, seal externalRuntimeMigrationSeal) error {
	raw, err := os.ReadFile(filepath.Join(directory, "scope.json"))
	if errors.Is(err, os.ErrNotExist) {
		if _, err := os.Lstat(directory); errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return errors.New("migration directory has no confirmed operation scope")
	}
	if err != nil {
		return err
	}
	var previous externalRuntimeMigrationSeal
	if json.Unmarshal(raw, &previous) != nil || previous.OperationID != seal.OperationID || previous.Provider != seal.Provider || previous.SessionID != seal.SessionID || previous.Source != seal.Source || previous.Target != seal.Target {
		return errors.New("migration staging scope conflicts with this operation")
	}
	return nil
}

func (c *connector) migrationDirectory(seal externalRuntimeMigrationSeal) (string, error) {
	directory := filepath.Join(c.runtimeStateRoot(), "session-migrations", seal.OperationID, seal.SessionID)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return "", err
	}
	scopePath := filepath.Join(directory, "scope.json")
	if _, err := os.Stat(scopePath); err == nil {
		return directory, checkMigrationDirectoryScope(directory, seal)
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	raw, err := json.Marshal(seal)
	if err != nil {
		return "", err
	}
	return directory, writeMigrationReceipt(scopePath, raw)
}

func (c *connector) exportSessionMigration(ctx context.Context, seal externalRuntimeMigrationSeal, params map[string]any) (map[string]any, error) {
	if err := c.workspaceArchiver.acquire(ctx); err != nil {
		return nil, err
	}
	defer func() { <-c.workspaceArchiver.mu }()
	directory, err := c.migrationDirectory(seal)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(directory, "export.tar.zst")
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		c.externalRuntimeState.mu.Lock()
		identity, exists := c.externalRuntimeState.identities[seal.Provider+"\x00"+seal.SessionID]
		c.externalRuntimeState.mu.Unlock()
		if !exists {
			return nil, errors.New("source native identity is unavailable")
		}
		roots, err := c.migrationNativePaths(ctx, identity)
		if err != nil {
			return nil, err
		}
		files, size, err := migrationFileManifest(ctx, roots)
		if err != nil {
			return nil, err
		}
		if err := validateMigrationPrimary(ctx, files, identity, ""); err != nil {
			return nil, err
		}
		output, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
		if err != nil {
			return nil, err
		}
		err = writeMigrationArchive(ctx, output, runtimeMigrationManifest{OperationID: seal.OperationID, Identity: identity, Files: files, Bytes: size})
		if err == nil {
			err = output.Sync()
		}
		closeErr := output.Close()
		if err != nil {
			return nil, err
		}
		if closeErr != nil {
			return nil, closeErr
		}
		if err := os.Rename(path+".tmp", path); err != nil {
			return nil, err
		}
		if err := syncDirectory(directory); err != nil {
			return nil, err
		}
	} else if err != nil {
		return nil, err
	}
	input, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer input.Close()
	info, err := input.Stat()
	if err != nil {
		return nil, err
	}
	offset := int64Param(params, "offset", 0)
	if offset < 0 || offset > info.Size() {
		return nil, errors.New("migration export offset is invalid")
	}
	chunk := make([]byte, 1<<20)
	count, err := input.ReadAt(chunk, offset)
	if err != nil && err != io.EOF {
		return nil, err
	}
	return map[string]any{"data": base64.StdEncoding.EncodeToString(chunk[:count]), "offset": offset, "next_offset": offset + int64(count), "done": offset+int64(count) == info.Size()}, nil
}

func validateMigrationPrimary(ctx context.Context, files []runtimeMigrationFile, identity externalRuntimeSessionIdentity, staging string) error {
	id := stringParam(identity.Payload, "session_id")
	if identity.Provider == "codex" {
		id = stringParam(identity.Payload, "thread_id")
	}
	if id == "" {
		return errors.New("migration native identity is empty")
	}
	matched := false
	for _, file := range files {
		if !strings.HasPrefix(file.Name, "native/") || file.Kind != tar.TypeReg {
			continue
		}
		name := filepath.Base(file.Name)
		if name != id+".jsonl" && !strings.HasSuffix(name, "-"+id+".jsonl") && !strings.HasSuffix(name, "_"+id+".jsonl") {
			continue
		}
		if matched {
			return errors.New("migration native Session is ambiguous")
		}
		path := file.Source
		availableWorkspace := identity.Workspace
		if staging != "" {
			path = filepath.Join(staging, filepath.FromSlash(file.Name))
			availableWorkspace = filepath.Join(staging, "workspace")
		}
		if err := validateMigrationNativeFile(ctx, path, identity, availableWorkspace); err != nil {
			return err
		}
		matched = true
	}
	if !matched {
		return errors.New("migration native Session file is absent")
	}
	return nil
}

func (c *connector) importSessionMigration(ctx context.Context, seal externalRuntimeMigrationSeal, params map[string]any) (map[string]any, error) {
	if !c.cfg.runtimeAgent || c.cfg.computeRuntimeKind != "external_worker" || c.cfg.computeRuntimeProvider != seal.Provider {
		return nil, errors.New("migration target must be the exact Compute provider")
	}
	if err := c.workspaceArchiver.acquire(ctx); err != nil {
		return nil, err
	}
	defer func() { <-c.workspaceArchiver.mu }()
	directory, err := c.migrationDirectory(seal)
	if err != nil {
		return nil, err
	}
	if boolParam(params, "activate") {
		if _, err := os.Stat(filepath.Join(directory, "complete.json")); err != nil {
			return nil, errors.New("migration target is not fully staged")
		}
		if err := c.installSessionMigration(ctx, seal, directory, filepath.Join(directory, "import.tar.zst"), true); err != nil {
			return nil, err
		}
		return map[string]any{"phase": "activated"}, nil
	}
	chunk, err := base64.StdEncoding.DecodeString(stringParam(params, "data"))
	if err != nil || len(chunk) > 1<<20 {
		return nil, errors.New("invalid migration chunk")
	}
	offset := int64Param(params, "offset", -1)
	if offset < 0 || offset+int64(len(chunk)) > migrationByteLimit+(64<<20) {
		return nil, errors.New("migration import exceeds its size bound")
	}
	path := filepath.Join(directory, "import.tar.zst")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	if offset > info.Size() {
		file.Close()
		return nil, errors.New("migration import has a missing chunk")
	}
	if offset < info.Size() {
		existing := make([]byte, len(chunk))
		count, readErr := file.ReadAt(existing, offset)
		if readErr != nil || count != len(chunk) || !bytes.Equal(existing, chunk) {
			file.Close()
			return nil, errors.New("migration retry changed a previously received chunk")
		}
	} else {
		_, err = file.WriteAt(chunk, offset)
	}
	if err == nil {
		err = file.Sync()
	}
	closeErr := file.Close()
	if err != nil {
		return nil, err
	}
	if closeErr != nil {
		return nil, closeErr
	}
	if !boolParam(params, "done") {
		return map[string]any{"next_offset": offset + int64(len(chunk))}, nil
	}
	if err := c.installSessionMigration(ctx, seal, directory, path, false); err != nil {
		return nil, err
	}
	return map[string]any{"phase": "staged", "next_offset": offset + int64(len(chunk))}, nil
}

func (c *connector) installSessionMigration(ctx context.Context, seal externalRuntimeMigrationSeal, directory, path string, activate bool) error {
	if raw, err := os.ReadFile(filepath.Join(directory, "complete.json")); err == nil && string(raw) == `{"phase":"activated"}` {
		return nil
	}
	command, err := c.computeRuntimeCommand(seal.Provider)
	if err != nil {
		return err
	}
	runtimes, err := c.runtimeInventory.probe(ctx, seal.Provider, command, "session_migration")
	if err != nil || len(runtimes) != 1 || runtimes[0]["ready"] != true {
		return errors.New("migration target requires provider authentication or native readiness")
	}
	staging := filepath.Join(directory, "staging")
	intent := filepath.Join(directory, "install.json")
	var manifest runtimeMigrationManifest
	if raw, err := os.ReadFile(intent); err == nil {
		if json.Unmarshal(raw, &manifest) != nil || manifest.OperationID != seal.OperationID || manifest.Identity.SessionID != seal.SessionID {
			return errors.New("migration install intent is invalid")
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	} else {
		if err := os.RemoveAll(staging); err != nil {
			return err
		}
		if err := os.Mkdir(staging, 0700); err != nil {
			return err
		}
		input, err := os.Open(path)
		if err != nil {
			return err
		}
		manifest, err = extractMigrationArchive(ctx, input, staging, seal.OperationID, seal.SessionID)
		input.Close()
		if err != nil {
			return err
		}
		if manifest.Identity.Provider != seal.Provider {
			return errors.New("migration native provider changed")
		}
		if err := validateMigrationPrimary(ctx, manifest.Files, manifest.Identity, staging); err != nil {
			return err
		}
		if manifest.Identity.Provider == "pi" || manifest.Identity.Provider == "codex" {
			for _, file := range manifest.Files {
				if strings.HasPrefix(file.Name, "native/") && file.Kind == tar.TypeReg && strings.HasSuffix(file.Name, ".jsonl") {
					if err := rebaseMigrationNative(ctx, filepath.Join(staging, filepath.FromSlash(file.Name)), manifest.Identity, filepath.Join(staging, "workspace"), filepath.Join(c.workspaceArchiver.root, seal.SessionID)); err != nil {
						return err
					}
				}
			}
		}

		c.externalRuntimeState.mu.Lock()
		_, exists := c.externalRuntimeState.identities[manifest.Identity.key()]
		c.externalRuntimeState.mu.Unlock()
		if exists {
			return errors.New("migration target already owns this Session")
		}
		if _, err := os.Lstat(filepath.Join(c.workspaceArchiver.root, seal.SessionID)); !errors.Is(err, os.ErrNotExist) {
			return errors.New("migration target workspace already exists")
		}
		for _, file := range manifest.Files {
			if strings.HasPrefix(file.Name, "native/") {
				destination, err := c.migrationNativeDestination(manifest.Identity, file.Name)
				if err != nil {
					return err
				}
				if file.Kind != tar.TypeDir {
					if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
						return errors.New("migration native destination already exists")
					}
				}
			}
		}
		raw, err := json.Marshal(manifest)
		if err != nil {
			return err
		}
		if err := writeMigrationReceipt(intent, raw); err != nil {
			return err
		}
	}
	workspace := filepath.Join(c.workspaceArchiver.root, seal.SessionID)
	if activate {
		for _, file := range manifest.Files {
			if err := ctx.Err(); err != nil {
				return err
			}
			if !strings.HasPrefix(file.Name, "native/") {
				continue
			}
			destination, err := c.migrationNativeDestination(manifest.Identity, file.Name)
			if err != nil {
				return err
			}
			if file.Kind == tar.TypeDir {
				if err := os.MkdirAll(destination, os.FileMode(file.Mode)); err != nil {
					return err
				}
				continue
			}
			if err := os.MkdirAll(filepath.Dir(destination), 0700); err != nil {
				return err
			}
			source := filepath.Join(staging, filepath.FromSlash(file.Name))
			if _, err := os.Lstat(source); errors.Is(err, os.ErrNotExist) {
				if _, err := os.Lstat(destination); err != nil {
					return err
				}
				continue
			} else if err != nil {
				return err
			}
			if _, err := os.Lstat(destination); !errors.Is(err, os.ErrNotExist) {
				return errors.New("migration native destination changed during installation")
			}
			if err := os.Rename(source, destination); err != nil {
				return err
			}
			if err := syncDirectory(filepath.Dir(destination)); err != nil {
				return err
			}
		}
		if _, err := os.Stat(workspace); errors.Is(err, os.ErrNotExist) {
			if err := os.Rename(filepath.Join(staging, "workspace"), workspace); err != nil {
				return err
			}
			if err := syncDirectory(c.workspaceArchiver.root); err != nil {
				return err
			}
		} else if err != nil {
			return err
		}
	}
	identity := manifest.Identity
	identity.Command, identity.Workspace = command, workspace
	identity.Payload = maps.Clone(identity.Payload)
	identity.Payload["require_native_resume"] = true
	identity.LastActivityAt = time.Now().Unix()
	if identity.Provider == "pi" {
		id := stringParam(identity.Payload, "session_id")
		for _, file := range manifest.Files {
			if strings.HasPrefix(file.Name, "native/pi/") && strings.HasSuffix(file.Name, "_"+id+".jsonl") {
				identity.Payload["session_file"] = filepath.Join(c.runtimeStateRoot(), "external-runtime", filepath.FromSlash(strings.TrimPrefix(file.Name, "native/")))
			}
		}
	}
	if !activate {
		if identity.Provider == "codex" {
			implementation := c.runtimeImplementations["codex"].(*codexRuntimeImplementation)
			if err := implementation.validateMigrationHistory(ctx, command, filepath.Join(staging, "native"), stringParam(identity.Payload, "thread_id")); err != nil {
				return err
			}
		}
		identity.Payload["migration_operation_id"] = seal.OperationID
	} else {
		delete(identity.Payload, "migration_operation_id")
	}
	c.externalRuntimeState.mu.Lock()
	err = c.externalRuntimeState.persistIdentityLocked(identity.key(), identity)
	if err == nil {
		c.externalRuntimeState.addRuntimeSessionLocked(identity)
		c.externalRuntimeState.rebuildRuntimeSessionSnapshotsLocked()
	}
	c.externalRuntimeState.mu.Unlock()
	if err != nil {
		return err
	}
	phase := "staged"
	if activate {
		phase = "activated"
	}
	return writeMigrationReceipt(filepath.Join(directory, "complete.json"), []byte(`{"phase":"`+phase+`"}`))
}

// Pi's CLI restores cwd from its header; the SDK's cwdOverride is only
// process-local and forkFrom changes session lineage. Codex stores local_image
// locations in typed records. Relocate that metadata, retaining all text and IDs.
func rebaseMigrationNative(ctx context.Context, path string, identity externalRuntimeSessionIdentity, availableWorkspace, workspace string) error {
	input, err := os.Open(path)
	if err != nil {
		return err
	}
	defer input.Close()
	info, err := input.Stat()
	if err != nil {
		return err
	}
	output, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, info.Mode().Perm())
	if err != nil {
		return err
	}
	defer output.Close()
	defer os.Remove(path + ".tmp")
	reader := bufio.NewReaderSize(input, 16<<20)
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		line, readErr := reader.ReadSlice('\n')
		if readErr != nil && readErr != io.EOF {
			return errors.New("native Session line exceeds 16 MiB")
		}
		if len(line) > 0 {
			var row map[string]any
			decoder := json.NewDecoder(bytes.NewReader(line))
			decoder.UseNumber()
			if err := decoder.Decode(&row); err != nil {
				return err
			}
			changed := false
			if identity.Provider == "pi" && stringParam(row, "type") == "session" {
				row["cwd"] = workspace
				changed = true
			}
			if identity.Provider == "codex" {
				changed, err = migrationFileReferences(row, identity.Workspace, availableWorkspace, workspace)
				if err != nil {
					return err
				}
			}
			if changed {
				raw, err := json.Marshal(row)
				if err != nil {
					return err
				}
				if line[len(line)-1] == '\n' {
					raw = append(raw, '\n')
				}
				line = raw
			}
			if _, err := output.Write(line); err != nil {
				return err
			}
		}
		if readErr == io.EOF {
			break
		}
	}
	if err := output.Sync(); err != nil {
		return err
	}
	if err := output.Close(); err != nil {
		return err
	}
	if err := os.Rename(path+".tmp", path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

func writeMigrationReceipt(path string, raw []byte) error {
	file, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, err = file.Write(raw)
	if err == nil {
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

func (i *codexRuntimeImplementation) validateMigrationHistory(ctx context.Context, command, home, threadID string) error {
	native, err := i.startRuntimeAtHome(externalRuntimeInput{command: command}, "", home)
	if err != nil {
		return err
	}
	native.implementation = nil
	native.readLimit = 32 << 20
	native.start()
	defer func() { native.terminate(); <-native.done }()
	if err := native.connect(ctx); err != nil {
		return err
	}
	if err := native.ensureInitialized(ctx); err != nil {
		return err
	}
	result, err := native.rpc(ctx, "thread/read", map[string]any{"threadId": threadID, "includeTurns": true}, 30*time.Second)
	if err != nil {
		return err
	}
	if stringParam(mapParam(result, "thread"), "id") != threadID {
		return errors.New("staged Codex history has a different native identity")
	}
	return nil
}

func (c *connector) migrationNativeDestination(identity externalRuntimeSessionIdentity, name string) (string, error) {
	if !validMigrationPath(name) || !strings.HasPrefix(name, "native/") {
		return "", errors.New("invalid native migration path")
	}
	path := strings.TrimPrefix(name, "native/")
	id := stringParam(identity.Payload, "session_id")
	var base string
	switch identity.Provider {
	case "codex":
		id = stringParam(identity.Payload, "thread_id")
		if (!strings.HasPrefix(path, "sessions/") && !strings.HasPrefix(path, "archived_sessions/")) || !strings.HasSuffix(path, "-"+id+".jsonl") {
			return "", errors.New("unsupported Codex native migration path")
		}
		base = filepath.Dir(codexConfigPath())
	case "claude":
		if !strings.HasPrefix(path, "projects/") || (filepath.Base(path) != id+".jsonl" && !strings.Contains(path, "/"+id+"/") && !strings.HasSuffix(path, "/"+id)) {
			return "", errors.New("unsupported Claude native migration path")
		}
		settings, err := runtimeAuthClaudeLocation()
		if err != nil {
			return "", err
		}
		base = filepath.Dir(settings)
	case "pi":
		if path != "pi/"+identity.SessionID && !strings.HasPrefix(path, "pi/"+identity.SessionID+"/") {
			return "", errors.New("unsupported Pi native migration path")
		}
		base = filepath.Join(c.runtimeStateRoot(), "external-runtime")
	default:
		return "", errors.New("unsupported migration provider")
	}
	destination := filepath.Join(base, filepath.FromSlash(path))
	for parent := filepath.Dir(destination); parent != base; parent = filepath.Dir(parent) {
		if err := rejectExistingSymlink(parent); err != nil {
			return "", err
		}
	}
	return destination, nil
}

func (s *externalRuntimeState) migrationAllowsArchive(sessionID string) error {
	if s.db == nil {
		return errExternalRuntimeStateDisabled
	}
	return s.db.View(func(tx *bolt.Tx) error {
		for _, provider := range []string{"codex", "claude", "pi"} {
			if err := allowRuntimeMigrationInput(tx, provider+"\x00"+sessionID); err != nil {
				return err
			}
		}
		return nil
	})
}

// The source seal shares the identity owner's transaction. It is never copied
// to the target and never expires into permission to execute again.
type externalRuntimeMigrationSeal struct {
	OperationID string `json:"operation_id"`
	Provider    string `json:"provider"`
	SessionID   string `json:"session_id"`
	Source      string `json:"source"`
	Target      string `json:"target"`
	Phase       string `json:"phase"`
	Deadline    int64  `json:"deadline"`
}

func runtimeMigrationSeal(tx *bolt.Tx, key string) (*externalRuntimeMigrationSeal, error) {
	bucket := tx.Bucket(externalRuntimeMigrationBucket)
	if bucket == nil || bucket.Get([]byte(key)) == nil {
		return nil, nil
	}
	var seal externalRuntimeMigrationSeal
	if err := json.Unmarshal(bucket.Get([]byte(key)), &seal); err != nil {
		return nil, err
	}
	return &seal, nil
}

func allowRuntimeMigrationInput(tx *bolt.Tx, key string) error {
	seal, err := runtimeMigrationSeal(tx, key)
	if err != nil {
		return err
	}
	if seal != nil {
		return errRuntimeMigrationFrozen
	}
	return nil
}

func (s *externalRuntimeState) prepareMigration(seal externalRuntimeMigrationSeal, token string) error {
	if s.db == nil {
		return errExternalRuntimeStateDisabled
	}
	if seal.OperationID == "" || seal.Source == "" || seal.Target == "" || seal.Source == seal.Target ||
		!canonicalExternalRuntimeSessionID.MatchString(seal.SessionID) || token == "" ||
		(seal.Provider != "codex" && seal.Provider != "claude" && seal.Provider != "pi") {
		return errors.New("invalid session migration scope")
	}
	key := seal.Provider + "\x00" + seal.SessionID
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.db.Update(func(tx *bolt.Tx) error {
		previous, err := runtimeMigrationSeal(tx, key)
		if err != nil {
			return err
		}
		if previous != nil {
			if previous.OperationID != seal.OperationID || previous.Source != seal.Source || previous.Target != seal.Target || previous.Deadline != seal.Deadline {
				return errors.New("session migration operation conflicts with the source seal")
			}
			return nil
		}
		if time.Now().UnixMilli() >= seal.Deadline {
			return errors.New("session migration deadline elapsed")
		}
		if tx.Bucket(externalRuntimeIdentitiesBucket).Get([]byte(key)) == nil {
			return errors.New("session has no settled native identity")
		}
		if err := migrationDurableQuiet(tx, key, token); err != nil {
			return err
		}
		seal.Phase = "prepared"
		raw, err := json.Marshal(seal)
		if err != nil {
			return err
		}
		bucket, err := tx.CreateBucketIfNotExists(externalRuntimeMigrationBucket)
		if err != nil {
			return err
		}
		return bucket.Put([]byte(key), raw)
	})
}

func migrationDurableQuiet(tx *bolt.Tx, key, token string) error {
	if tx.Bucket(externalRuntimeActiveExecutionsBucket).Get([]byte(key)) != nil {
		return errRuntimeNotQuiet
	}
	prefix := []byte(key + "\x00")
	k, _ := tx.Bucket(externalRuntimeInputBatchesBucket).Cursor().Seek(prefix)
	if bytes.HasPrefix(k, prefix) {
		return errRuntimeNotQuiet
	}
	// Event keys are globally ordered. Bound this preflight; a larger backlog
	// must drain before migration rather than turning it into an unbounded scan.
	events := tx.Bucket(externalRuntimeSessionEventsBucket)
	if events.Stats().KeyN > 1024 {
		return errors.New("migration event inspection exceeds 1024 pending events; drain the backlog")
	}
	return events.ForEach(func(_, raw []byte) error {
		var event message
		if err := json.Unmarshal(raw, &event); err != nil {
			return err
		}
		if stringParam(event.Params, "capability_token") == token {
			return errRuntimeNotQuiet
		}
		return nil
	})
}

func (s *externalRuntimeState) retireMigration(provider, sessionID, operationID, token string) error {
	if s.db == nil {
		return errExternalRuntimeStateDisabled
	}
	if token == "" {
		return errors.New("migration source capability is required")
	}
	key := provider + "\x00" + sessionID
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.db.Update(func(tx *bolt.Tx) error {
		seal, err := runtimeMigrationSeal(tx, key)
		if err != nil {
			return err
		}
		if seal == nil || seal.OperationID != operationID {
			return errors.New("source migration is not prepared for this operation")
		}
		if seal.Phase == "retired" {
			return nil
		}
		if err := migrationDurableQuiet(tx, key, token); err != nil {
			return err
		}
		seal.Phase = "retired"
		raw, err := json.Marshal(seal)
		if err != nil {
			return err
		}
		return tx.Bucket(externalRuntimeMigrationBucket).Put([]byte(key), raw)
	})
}
