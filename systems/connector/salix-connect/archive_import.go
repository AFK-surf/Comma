package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"time"
)

// The receipt belongs to the target archive import and survives response loss.
type cloudProviderMigration struct {
	Diagnostics  *archiveDiagnostics `json:"diagnostics,omitempty"`
	Operation    string              `json:"operation"`
	Format       string              `json:"format,omitempty"`
	Phase        string              `json:"phase"`
	Bytes        int64               `json:"bytes"`
	RuntimePaths []string            `json:"runtime_paths"`
	Sessions     int                 `json:"sessions"`
	StartedAt    int64               `json:"started_at,omitempty"`
}

var cloudMigrationOperation = regexp.MustCompile(`^[a-zA-Z0-9_-]{1,128}$`)

const cloudMigrationArchiveLimit int64 = migrationByteLimit + (64 << 20)
const providerMigrationChunkSize = 4 << 20
const providerMigrationRequestLimit = 8 << 20

func writeProviderMigration(path string, value cloudProviderMigration) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	if err = os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	f, err := os.OpenFile(path+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	if _, err = f.Write(raw); err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	if err = os.Rename(path+".tmp", path); err != nil {
		return err
	}
	return syncDirectory(filepath.Dir(path))
}

// Failed-import timing is optional and cannot rewrite the authoritative receipt.
// A partial import rejects further attempts on this target, so one failure starts
// at most one writer. No fsync or retry is required for this observation.
func saveFailedImportDiagnostics(path, operation string, diagnostics archiveDiagnostics) {
	go func() {
		raw, err := json.Marshal(struct {
			Operation   string             `json:"operation"`
			Diagnostics archiveDiagnostics `json:"diagnostics"`
		}{operation, diagnostics})
		if err != nil || os.WriteFile(path+".tmp", raw, 0600) != nil {
			return
		}
		_ = os.Rename(path+".tmp", path)
	}()
}

func providerMigrationResult(receipt cloudProviderMigration) map[string]any {
	return map[string]any{"operation": receipt.Operation, "phase": receipt.Phase, "bytes": receipt.Bytes, "runtime_paths": receipt.RuntimePaths, "sessions": receipt.Sessions, "diagnostics": receipt.Diagnostics}
}

// Import is available only on the authenticated provider HTTP carrier before
// it becomes the Group's current connection. Parts are bounded and replayable.
func (c *connector) handleProviderMigrationImport(w http.ResponseWriter, r *http.Request) {
	c.cloudRuntimeMu.Lock()
	defer c.cloudRuntimeMu.Unlock()
	c.connectionMu.Lock()
	defer c.connectionMu.Unlock()
	if c.activeConnection != nil || c.externalRuntimeState == nil {
		http.Error(w, "migration target is connected", 409)
		return
	}
	var request struct {
		Operation    string              `json:"operation"`
		Action       string              `json:"action"`
		Format       string              `json:"format"`
		Offset       int64               `json:"offset"`
		Data         string              `json:"data"`
		SourceURL    string              `json:"source_url"`
		Parts        []signedArchivePart `json:"parts"`
		Bytes        int64               `json:"bytes"`
		RuntimePaths []string            `json:"runtime_paths"`
		Sessions     int                 `json:"sessions"`
		Provider     string              `json:"provider"`
		SessionID    string              `json:"session_id"`
	}
	if json.NewDecoder(http.MaxBytesReader(w, r.Body, providerMigrationRequestLimit)).Decode(&request) != nil || !cloudMigrationOperation.MatchString(request.Operation) {
		http.Error(w, "invalid migration request", 400)
		return
	}
	dir := filepath.Join(c.runtimeStateRoot(), "provider-import")
	receipt := filepath.Join(dir, "receipt.json")
	var status cloudProviderMigration
	raw, err := os.ReadFile(receipt)
	if err == nil && json.Unmarshal(raw, &status) != nil {
		http.Error(w, "invalid import receipt", 409)
		return
	}
	if err != nil && !os.IsNotExist(err) {
		http.Error(w, "import receipt unavailable", 500)
		return
	}
	if status.Operation != "" && status.Operation != request.Operation {
		http.Error(w, "import operation changed", 409)
		return
	}
	if status.Diagnostics == nil {
		var saved struct {
			Operation   string              `json:"operation"`
			Diagnostics *archiveDiagnostics `json:"diagnostics"`
		}
		if raw, err := os.ReadFile(filepath.Join(dir, "diagnostics.json")); err == nil && json.Unmarshal(raw, &saved) == nil && saved.Operation == status.Operation {
			status.Diagnostics = saved.Diagnostics
		}
	}
	archive := filepath.Join(dir, "target.tar.gz")
	offset := int64(0)
	if info, err := os.Stat(archive); err == nil {
		offset = info.Size()
	}
	if request.Action == "status" {
		if status.Phase == "restored" {
			if err := removeRestoredImportArchive(dir, archive); err != nil {
				http.Error(w, "restored import cleanup pending", 500)
				return
			}
			offset = status.Bytes
		}
		missing, missingCount := c.missingProviderMigrationNative()
		writeJSONResponse(w, 200, map[string]any{"diagnostics": status.Diagnostics, "phase": status.Phase, "next_offset": offset, "runtime_paths": status.RuntimePaths, "sessions": status.Sessions, "missing_native_sessions": missing, "missing_native_count": missingCount})
		return
	}
	if status.Phase == "restored" {
		if err := removeRestoredImportArchive(dir, archive); err != nil {
			http.Error(w, "restored import cleanup pending", 500)
			return
		}
		writeJSONResponse(w, 200, providerMigrationResult(status))
		return
	}
	if status.Phase == "restoring" {
		http.Error(w, "partial restore requires a fresh unused target", 409)
		return
	}
	if !c.externalRuntimeState.emptyArchiveTarget() {
		http.Error(w, "migration target contains runtime state", 409)
		return
	}
	if err := os.MkdirAll(dir, 0700); err != nil {
		http.Error(w, "import storage unavailable", 500)
		return
	}
	switch request.Action {
	case "stream":
		if request.Format != "tar_zst" || status.Operation != "" || offset != 0 ||
			request.Bytes < 1 || request.Bytes > cloudMigrationArchiveLimit || request.Sessions < 0 ||
			len(request.RuntimePaths) != 0 || len(request.Parts) == 0 || len(request.Parts) > 1024 {
			http.Error(w, "invalid streaming archive", 400)
			return
		}
		var expected int64
		for index, part := range request.Parts {
			remaining := request.Bytes - int64(index)*providerMigrationChunkSize
			if remaining <= 0 || part.Bytes != min(int64(providerMigrationChunkSize), remaining) {
				http.Error(w, "invalid streaming archive part", 400)
				return
			}
			expected += part.Bytes
		}
		if expected != request.Bytes {
			http.Error(w, "streaming archive size mismatch", 400)
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), 15*time.Minute)
		defer cancel()
		reader, err := newParallelSignedArchiveReader(ctx, request.Parts, 8)
		if err != nil {
			http.Error(w, "invalid streaming archive part", 400)
			return
		}
		defer reader.Close()
		status = cloudProviderMigration{Operation: request.Operation, Format: request.Format, Phase: "restoring"}
		if err := writeProviderMigration(receipt, status); err != nil {
			http.Error(w, "import receipt unavailable", 500)
			return
		}
		startedAt := time.Now()
		status.Diagnostics = &archiveDiagnostics{Outcome: "failed"}
		defer func() {
			status.Diagnostics.TotalMS = time.Since(startedAt).Milliseconds()
			status.Diagnostics.GetMSSum = reader.fetchNS.Load() / 1_000_000
			status.Diagnostics.DecoderWaitMS = reader.waitNS.Load() / 1_000_000
			if status.Diagnostics.Outcome == "failed" {
				saveFailedImportDiagnostics(filepath.Join(dir, "diagnostics.json"), status.Operation, *status.Diagnostics)
			}
		}()
		if err := restoreTarZstStateLimit(reader, c.root, c.externalRuntimeState, migrationByteLimit); err != nil {
			logf("cloud_vm_archive stage=stream_restore_failed operation=%s downloaded_bytes=%d duration_ms=%d error=%v", request.Operation, reader.downloaded, time.Since(startedAt).Milliseconds(), err)
			http.Error(w, "streaming restore failed: "+err.Error(), 409)
			return
		}
		if reader.downloaded != request.Bytes {
			http.Error(w, "streaming restore did not read full archive", 409)
			return
		}
		c.externalRuntimeState.mu.Lock()
		count := len(c.externalRuntimeState.identities)
		c.externalRuntimeState.mu.Unlock()
		if count != request.Sessions {
			http.Error(w, "restored Session count differs", 409)
			return
		}
		status.Diagnostics.Outcome = "restored"
		status.Diagnostics.TotalMS = time.Since(startedAt).Milliseconds()
		status.Diagnostics.GetMSSum = reader.fetchNS.Load() / 1_000_000
		status.Diagnostics.DecoderWaitMS = reader.waitNS.Load() / 1_000_000
		status.Phase, status.Bytes, status.Sessions = "restored", request.Bytes, count
		if err := writeProviderMigration(receipt, status); err != nil {
			http.Error(w, "import receipt unavailable", 500)
			return
		}
		logf("cloud_vm_archive stage=stream_restore_complete operation=%s format=%s bytes=%d parts=%d concurrency=8 duration_ms=%d get_ms_sum=%d decoder_wait_ms=%d", request.Operation, request.Format, request.Bytes, len(request.Parts), time.Since(startedAt).Milliseconds(), reader.fetchNS.Load()/1_000_000, reader.waitNS.Load()/1_000_000)
		writeJSONResponse(w, 200, providerMigrationResult(status))
	case "part":
		var data []byte
		if request.SourceURL != "" && request.Data == "" && request.Bytes > 0 && request.Bytes <= providerMigrationChunkSize {
			data, err = readSignedArchiveChunk(r.Context(), request.SourceURL, request.Bytes)
		} else if request.SourceURL == "" {
			data, err = base64.StdEncoding.DecodeString(request.Data)
		} else {
			err = errors.New("invalid signed archive part")
		}
		if err != nil || len(data) > providerMigrationChunkSize || request.Offset < 0 || request.Offset+int64(len(data)) > cloudMigrationArchiveLimit {
			http.Error(w, "invalid migration part", 400)
			return
		}
		if request.Offset > offset {
			http.Error(w, "migration offset gap", 409)
			return
		}
		if request.Offset < offset {
			f, err := os.Open(archive)
			if err != nil {
				http.Error(w, "import unavailable", 500)
				return
			}
			previous := make([]byte, len(data))
			n, readErr := f.ReadAt(previous, request.Offset)
			f.Close()
			if readErr != nil || n != len(data) || string(previous) != string(data) {
				http.Error(w, "migration part conflict", 409)
				return
			}
			writeJSONResponse(w, 200, map[string]any{"next_offset": offset})
			return
		}
		if status.Operation == "" {
			status = cloudProviderMigration{Operation: request.Operation, Phase: "receiving", StartedAt: time.Now().UnixMilli()}
			if err := writeProviderMigration(receipt, status); err != nil {
				http.Error(w, "import receipt unavailable", 500)
				return
			}
		}
		f, err := os.OpenFile(archive, os.O_CREATE|os.O_WRONLY, 0600)
		if err != nil {
			http.Error(w, "import unavailable", 500)
			return
		}
		_, err = f.WriteAt(data, offset)
		if err == nil {
			err = f.Sync()
		}
		closeErr := f.Close()
		if err != nil || closeErr != nil {
			http.Error(w, "import write failed", 500)
			return
		}
		if next := offset + int64(len(data)); next%(16*providerMigrationChunkSize) == 0 || len(data) < providerMigrationChunkSize {
			logf("cloud_vm_archive stage=download_progress operation=%s bytes=%d elapsed_ms=%d", request.Operation, next, time.Now().UnixMilli()-status.StartedAt)
		}
		writeJSONResponse(w, 200, map[string]any{"next_offset": offset + int64(len(data))})
	case "finish":
		if request.Bytes != offset || offset == 0 || len(request.RuntimePaths) > 32 || request.Sessions < 0 {
			http.Error(w, "migration archive incomplete", 409)
			return
		}
		status.Phase = "restoring"
		if err := writeProviderMigration(receipt, status); err != nil {
			http.Error(w, "import receipt unavailable", 500)
			return
		}
		logf("cloud_vm_archive stage=download_complete operation=%s format=%s bytes=%d duration_ms=%d", request.Operation, request.Format, offset, time.Now().UnixMilli()-status.StartedAt)
		f, err := os.Open(archive)
		if err != nil {
			http.Error(w, "import unavailable", 500)
			return
		}
		startedAt := time.Now()
		status.Diagnostics = &archiveDiagnostics{Outcome: "failed", DownloadMS: max(0, time.Now().UnixMilli()-status.StartedAt)}
		defer func() {
			status.Diagnostics.ExtractMS = time.Since(startedAt).Milliseconds()
			status.Diagnostics.TotalMS = status.Diagnostics.DownloadMS + status.Diagnostics.ExtractMS
			if status.Diagnostics.Outcome == "failed" {
				saveFailedImportDiagnostics(filepath.Join(dir, "diagnostics.json"), status.Operation, *status.Diagnostics)
			}
		}()
		if request.Format == "tar_zst" {
			err = restoreTarZstStateLimit(f, c.root, c.externalRuntimeState, migrationByteLimit)
		} else if request.Format == "" || request.Format == "tar_gz" {
			err = restoreTarGzStateLimit(f, c.root, c.externalRuntimeState, migrationByteLimit)
		} else {
			err = errors.New("unsupported archive format")
		}
		f.Close()
		if err != nil {
			logf("cloud_vm_archive stage=extract_failed operation=%s format=%s bytes=%d duration_ms=%d error=%v", request.Operation, request.Format, offset, time.Since(startedAt).Milliseconds(), err)
			http.Error(w, "restore failed: "+err.Error(), 409)
			return
		}
		logf("cloud_vm_archive stage=extract_complete operation=%s format=%s bytes=%d duration_ms=%d", request.Operation, request.Format, offset, time.Since(startedAt).Milliseconds())
		for _, path := range request.RuntimePaths {
			if !executable(path) {
				http.Error(w, "restored native entry path missing", 409)
				return
			}
			ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
			cmd := commandContextWithProcessGroup(ctx, path, "--version")
			cmd.Stdout, cmd.Stderr, cmd.WaitDelay = io.Discard, io.Discard, time.Second
			err := cmd.Run()
			cancel()
			if err != nil {
				http.Error(w, "restored native entry cannot run on target", 409)
				return
			}
		}
		c.externalRuntimeState.mu.Lock()
		count := len(c.externalRuntimeState.identities)
		c.externalRuntimeState.mu.Unlock()
		if count != request.Sessions {
			http.Error(w, "restored Session count differs", 409)
			return
		}
		status.Diagnostics.Outcome = "restored"
		status.Diagnostics.ExtractMS = time.Since(startedAt).Milliseconds()
		status.Diagnostics.TotalMS = status.Diagnostics.DownloadMS + status.Diagnostics.ExtractMS
		status.Phase, status.Format, status.Bytes, status.RuntimePaths, status.Sessions = "restored", request.Format, offset, request.RuntimePaths, count
		if err := writeProviderMigration(receipt, status); err != nil {
			http.Error(w, "import receipt unavailable", 500)
			return
		}
		if err := removeRestoredImportArchive(dir, archive); err != nil {
			http.Error(w, "restored import cleanup pending", 500)
			return
		}
		writeJSONResponse(w, 200, providerMigrationResult(status))
	default:
		http.Error(w, "unknown migration action", 400)
	}
}

func removeRestoredImportArchive(dir, archive string) error {
	if err := os.Remove(archive); err != nil && !os.IsNotExist(err) {
		return err
	}
	return syncDirectory(dir)
}

func (c *connector) missingProviderMigrationNative() ([]map[string]string, int) {
	if c.externalRuntimeState == nil {
		return nil, 0
	}
	state := c.externalRuntimeState
	state.mu.Lock()
	defer state.mu.Unlock()
	missing := make([]map[string]string, 0, 32)
	count := 0
	for _, identity := range state.identities {
		if executable(identity.Command) {
			continue
		}
		count++
		if len(missing) < 32 {
			missing = append(missing, map[string]string{"provider": identity.Provider, "session_id": identity.SessionID})
		}
	}
	sort.Slice(missing, func(i, j int) bool {
		if missing[i]["session_id"] == missing[j]["session_id"] {
			return missing[i]["provider"] < missing[j]["provider"]
		}
		return missing[i]["session_id"] < missing[j]["session_id"]
	})
	return missing, count
}
