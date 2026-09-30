package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// The release and idle archive owner stores these bytes outside the Container.
// This local copy is only an export spool and is excluded from the tar stream.
const durableArchiveCompressedLimit int64 = 4 << 30

// Archive diagnostics are observations, never restore checkpoints.
type archiveDiagnostics struct {
	Outcome       string `json:"outcome,omitempty"`
	TotalMS       int64  `json:"total_ms"`
	PackMS        int64  `json:"pack_ms,omitempty"`
	PutMSSum      int64  `json:"put_ms_sum,omitempty"`
	EncoderWaitMS int64  `json:"encoder_wait_ms,omitempty"`
	GetMSSum      int64  `json:"get_ms_sum,omitempty"`
	DecoderWaitMS int64  `json:"decoder_wait_ms,omitempty"`
	DownloadMS    int64  `json:"download_ms,omitempty"`
	ExtractMS     int64  `json:"extract_ms,omitempty"`
}

type durableArchiveExport struct {
	Diagnostics   *archiveDiagnostics `json:"diagnostics,omitempty"`
	Operation     string              `json:"operation"`
	Format        string              `json:"format,omitempty"`
	Phase         string              `json:"phase"`
	Bytes         int64               `json:"bytes"`
	PackedBytes   int64               `json:"packed_bytes"`
	UploadedBytes int64               `json:"uploaded_bytes"`
	ProgressAt    int64               `json:"progress_at"`
	Sessions      int                 `json:"sessions"`
	StartedAt     int64               `json:"started_at"`
}

func (s durableArchiveExport) response() map[string]any {
	return map[string]any{
		"operation": s.Operation, "phase": s.Phase, "bytes": s.Bytes,
		"packed_bytes": s.PackedBytes, "uploaded_bytes": s.UploadedBytes, "progress_at": s.ProgressAt,
		"sessions": s.Sessions, "format": s.format(), "diagnostics": s.Diagnostics,
	}
}

func (s durableArchiveExport) format() string {
	if s.Format == "tar_zst" {
		return "tar_zst"
	}
	return "tar_gz"
}

func durableArchivePath(dir, format string) string {
	if format == "tar_zst" {
		return filepath.Join(dir, "source.tar.zst")
	}
	return filepath.Join(dir, "source.tar.gz")
}

func (c *connector) durableArchiveDir() string {
	return filepath.Join(c.runtimeStateRoot(), "durable-archive")
}

func (c *connector) handleDurableArchiveExport(w http.ResponseWriter, r *http.Request) {
	if c.externalRuntimeState == nil || os.Getenv("SALIX_MANAGED_RUNTIME_ROOT") == "" {
		http.Error(w, "managed runtime connector required", http.StatusConflict)
		return
	}
	operation := r.URL.Query().Get("operation")
	if !cloudMigrationOperation.MatchString(operation) {
		http.Error(w, "invalid archive operation", http.StatusBadRequest)
		return
	}
	dir := c.durableArchiveDir()
	statePath := filepath.Join(dir, "export.json")
	requestedFormat := r.URL.Query().Get("format")
	if requestedFormat == "" {
		requestedFormat = "tar_gz"
	}
	if requestedFormat != "tar_gz" && requestedFormat != "tar_zst" {
		http.Error(w, "invalid archive format", http.StatusBadRequest)
		return
	}
	archivePath := durableArchivePath(dir, requestedFormat)
	cancelPath := filepath.Join(dir, "cancel-"+operation)
	if r.Method == http.MethodPost {
		c.cloudRuntimeMu.Lock()
		defer c.cloudRuntimeMu.Unlock()
		if _, err := os.Stat(cancelPath); err == nil {
			http.Error(w, "archive export cancelled", http.StatusConflict)
			return
		}
		c.expireCloudRuntimeQuiesce()
		if !c.cloudRuntimeQuiesced || c.cloudRuntimeReleased {
			http.Error(w, "managed archive requires quiescence", http.StatusConflict)
			return
		}
		state, err := readDurableArchiveExport(statePath)
		if err != nil && !os.IsNotExist(err) {
			http.Error(w, "archive export state unavailable", 500)
			return
		}
		if state.Operation == operation && (state.Phase == "preparing" || state.Phase == "exported") {
			if state.format() != requestedFormat {
				http.Error(w, "archive format changed", http.StatusConflict)
				return
			}
			writeJSONResponse(w, 200, state.response())
			return
		}
		if state.Phase == "preparing" {
			http.Error(w, "another archive export is in progress", http.StatusConflict)
			return
		}
		if err := c.prepareDependencyInstallationsForArchive(); err != nil {
			http.Error(w, "dependency declarations unavailable", http.StatusInternalServerError)
			return
		}
		if err := os.MkdirAll(dir, 0700); err != nil {
			http.Error(w, "archive spool unavailable", 500)
			return
		}
		var transfers []signedArchiveTransfer
		if requestedFormat == "tar_zst" {
			var body struct {
				Transfers []signedArchiveTransfer `json:"transfers"`
			}
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4<<20)).Decode(&body); err != nil || len(body.Transfers) != 1024 {
				http.Error(w, "invalid archive transfer list", http.StatusBadRequest)
				return
			}
			transfers = body.Transfers
		}
		for _, format := range []string{"tar_gz", "tar_zst"} {
			if err := os.Remove(durableArchivePath(dir, format)); err != nil && !os.IsNotExist(err) {
				http.Error(w, "archive spool unavailable", 500)
				return
			}
		}
		state = durableArchiveExport{Operation: operation, Format: requestedFormat, Phase: "preparing", StartedAt: time.Now().UnixMilli()}
		if err := writeDurableArchiveExport(statePath, state); err != nil {
			http.Error(w, "archive export state unavailable", 500)
			return
		}
		go c.buildDurableArchive(statePath, archivePath, state, transfers)
		writeJSONResponse(w, http.StatusAccepted, map[string]any{"operation": operation, "phase": "preparing"})
		return
	}
	if r.Method == http.MethodDelete {
		if err := os.MkdirAll(dir, 0700); err != nil {
			http.Error(w, "archive cancel unavailable", 500)
			return
		}
		if err := os.WriteFile(cancelPath, []byte(operation), 0600); err != nil {
			http.Error(w, "archive cancel unavailable", 500)
			return
		}
		state, err := readDurableArchiveExport(statePath)
		if err != nil || state.Operation != operation {
			writeJSONResponse(w, 200, map[string]any{"operation": operation, "phase": "cancelled"})
			return
		}
		archivePath = durableArchivePath(dir, state.format())
		if state.Phase == "cancelled" {
			writeJSONResponse(w, 200, state.response())
			return
		}
		if state.Phase != "preparing" && state.Phase != "exported" && state.Phase != "failed" {
			http.Error(w, "archive export cannot be cancelled", http.StatusConflict)
			return
		}
		writeJSONResponse(w, http.StatusAccepted, map[string]any{"operation": operation, "phase": "cancelling"})
		return
	}
	if r.Method == http.MethodPut {
		state, err := readDurableArchiveExport(statePath)
		if err == nil {
			if state.format() == "tar_zst" {
				http.Error(w, "streaming archive has no local spool", http.StatusMethodNotAllowed)
				return
			}
			archivePath = durableArchivePath(dir, state.format())
		}
		c.uploadDurableArchivePart(w, r, statePath, archivePath, operation)
		return
	}
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	state, err := readDurableArchiveExport(statePath)
	if err != nil || state.Operation != operation {
		if _, cancelErr := os.Stat(cancelPath); cancelErr == nil {
			writeJSONResponse(w, 200, map[string]any{"operation": operation, "phase": "cancelled"})
			return
		}
		http.Error(w, "archive export unavailable", http.StatusNotFound)
		return
	}
	archivePath = durableArchivePath(dir, state.format())
	if _, err := os.Stat(cancelPath); err == nil && c.cloudRuntimeMu.TryLock() {
		state, err = readDurableArchiveExport(statePath)
		if err == nil && state.Operation == operation && state.Phase != "cancelled" {
			_ = os.Remove(archivePath)
			_ = os.Remove(archivePath + ".tmp")
			state.Phase = "cancelled"
			state.ProgressAt = time.Now().UnixMilli()
			_ = writeDurableArchiveExport(statePath, state)
		}
		c.cloudRuntimeMu.Unlock()
	}
	if state.Phase != "exported" {
		writeJSONResponse(w, 200, state.response())
		return
	}
	if r.URL.Query().Get("offset") == "" {
		writeJSONResponse(w, 200, state.response())
		return
	}
	if state.format() == "tar_zst" {
		http.Error(w, "streaming archive has no local spool", http.StatusMethodNotAllowed)
		return
	}
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset < 0 || offset >= state.Bytes {
		http.Error(w, "invalid archive offset", http.StatusBadRequest)
		return
	}
	f, err := os.Open(archivePath)
	if err != nil {
		http.Error(w, "archive spool unavailable", 500)
		return
	}
	defer f.Close()
	chunk := make([]byte, providerMigrationChunkSize)
	n, err := f.ReadAt(chunk, offset)
	if err != nil && !errors.Is(err, io.EOF) {
		http.Error(w, "archive read failed", 500)
		return
	}
	writeJSONResponse(w, 200, map[string]any{"operation": operation, "offset": offset, "data": base64.StdEncoding.EncodeToString(chunk[:n]), "done": offset+int64(n) == state.Bytes})
}

type signedArchiveTransfer struct {
	PutURL string `json:"put_url"`
	GetURL string `json:"get_url"`
}

func (c *connector) uploadDurableArchivePart(w http.ResponseWriter, r *http.Request, statePath, archivePath, operation string) {
	state, err := readDurableArchiveExport(statePath)
	if err != nil || state.Operation != operation || state.Phase != "exported" {
		http.Error(w, "archive export unavailable", http.StatusConflict)
		return
	}
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset < 0 || offset >= state.Bytes || offset%providerMigrationChunkSize != 0 {
		http.Error(w, "invalid archive offset", http.StatusBadRequest)
		return
	}
	var transfer signedArchiveTransfer
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 8192)).Decode(&transfer); err != nil {
		http.Error(w, "invalid archive transfer", http.StatusBadRequest)
		return
	}
	if err := validateSignedArchiveURL(transfer.PutURL); err != nil {
		http.Error(w, "invalid archive upload URL", http.StatusBadRequest)
		return
	}
	if err := validateSignedArchiveURL(transfer.GetURL); err != nil {
		http.Error(w, "invalid archive read URL", http.StatusBadRequest)
		return
	}
	putTarget, _ := url.Parse(transfer.PutURL)
	getTarget, _ := url.Parse(transfer.GetURL)
	if putTarget.Host != getTarget.Host || putTarget.EscapedPath() != getTarget.EscapedPath() {
		http.Error(w, "archive transfer targets differ", http.StatusBadRequest)
		return
	}
	f, err := os.Open(archivePath)
	if err != nil {
		http.Error(w, "archive spool unavailable", http.StatusInternalServerError)
		return
	}
	defer f.Close()
	part := make([]byte, min(int64(providerMigrationChunkSize), state.Bytes-offset))
	if _, err := f.ReadAt(part, offset); err != nil {
		http.Error(w, "archive spool read failed", http.StatusInternalServerError)
		return
	}
	if err := putSignedArchiveChunk(r.Context(), transfer.PutURL, transfer.GetURL, part); err != nil {
		http.Error(w, "archive upload failed", http.StatusBadGateway)
		return
	}
	writeJSONResponse(w, http.StatusOK, map[string]any{"operation": operation, "next_offset": offset + int64(len(part))})
}

func validateSignedArchiveURL(raw string) error {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Fragment != "" || u.Port() != "" ||
		!strings.HasSuffix(u.Hostname(), ".r2.cloudflarestorage.com") || u.RawQuery == "" {
		return errors.New("invalid signed R2 URL")
	}
	return nil
}

var signedArchiveHTTPClient = &http.Client{
	Timeout:       60 * time.Second,
	CheckRedirect: func(_ *http.Request, _ []*http.Request) error { return http.ErrUseLastResponse },
}

func readSignedArchiveChunk(ctx context.Context, raw string, expected int64) ([]byte, error) {
	if err := validateSignedArchiveURL(raw); err != nil {
		return nil, err
	}
	if expected <= 0 || expected > providerMigrationChunkSize {
		return nil, errors.New("invalid archive part size")
	}
	for attempt := 0; attempt < 3; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
		if err != nil {
			return nil, err
		}
		resp, err := signedArchiveHTTPClient.Do(req)
		if err == nil && resp.StatusCode == http.StatusOK {
			part, readErr := io.ReadAll(io.LimitReader(resp.Body, expected+1))
			resp.Body.Close()
			if readErr == nil && int64(len(part)) != expected {
				return nil, errors.New("signed archive part size mismatch")
			}
			if readErr == nil {
				return part, nil
			}
			if attempt == 2 || ctx.Err() != nil {
				return nil, readErr
			}
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-time.After(time.Duration(attempt+1) * 250 * time.Millisecond):
			}
			continue
		}
		retry := err != nil
		if resp != nil {
			resp.Body.Close()
			retry = resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500
		}
		if !retry || attempt == 2 || ctx.Err() != nil {
			if err != nil {
				return nil, err
			}
			return nil, errors.New("signed archive read failed")
		}
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(time.Duration(attempt+1) * 250 * time.Millisecond):
		}
	}
	return nil, errors.New("signed archive read failed")
}

func putSignedArchiveChunk(ctx context.Context, putURL, getURL string, part []byte) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodPut, putURL, bytes.NewReader(part))
	if err != nil {
		return err
	}
	req.Header.Set("If-None-Match", "*")
	resp, putErr := signedArchiveHTTPClient.Do(req)
	if putErr == nil {
		resp.Body.Close()
		if resp.StatusCode >= 200 && resp.StatusCode < 300 {
			return nil
		}
		if resp.StatusCode != http.StatusPreconditionFailed && resp.StatusCode < 500 {
			return errors.New("signed archive upload rejected")
		}
	}
	// A timeout or 412 may mean that this exact part was already stored.
	existing, err := readSignedArchiveChunk(ctx, getURL, int64(len(part)))
	if err != nil {
		return err
	}
	if !bytes.Equal(existing, part) {
		return errors.New("signed archive part conflict")
	}
	return nil
}

func (c *connector) buildDurableArchive(statePath, archivePath string, state durableArchiveExport, transfers []signedArchiveTransfer) {
	startedAt := time.Now()
	c.cloudRuntimeMu.Lock()
	defer c.cloudRuntimeMu.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Minute)
	defer cancel()
	cancelPath := filepath.Join(filepath.Dir(statePath), "cancel-"+state.Operation)
	watchDone := make(chan struct{})
	go func() {
		ticker := time.NewTicker(100 * time.Millisecond)
		defer ticker.Stop()
		for {
			if _, err := os.Stat(cancelPath); err == nil {
				cancel()
				return
			}
			select {
			case <-watchDone:
				return
			case <-ticker.C:
			}
		}
	}()
	defer close(watchDone)
	state.Diagnostics = &archiveDiagnostics{}
	finish := func(phase string) {
		if _, err := os.Stat(cancelPath); err == nil {
			phase = "cancelled"
		}
		state.Phase = phase
		state.Diagnostics.Outcome = phase
		state.Diagnostics.TotalMS = time.Since(startedAt).Milliseconds()
		state.ProgressAt = time.Now().UnixMilli()
		_ = writeDurableArchiveExport(statePath, state)
	}
	c.expireCloudRuntimeQuiesce()
	if !c.cloudRuntimeQuiesced || c.cloudRuntimeReleased {
		finish("failed")
		return
	}
	if state.format() == "tar_zst" {
		uploader, err := newSignedArchiveUploadWriter(ctx, transfers)
		if err != nil {
			logf("cloud_vm_archive stage=stream_upload_setup_failed operation=%s error=%v", state.Operation, err)
			finish("failed")
			return
		}
		lastProgress := time.Now()
		packed := &durableArchiveProgressWriter{writer: &archiveLimitWriter{writer: uploader, remaining: durableArchiveCompressedLimit}, report: func(n int64) {
			state.PackedBytes = n
			state.UploadedBytes = uploader.uploaded.Load()
			if time.Since(lastProgress) >= time.Second {
				state.ProgressAt = time.Now().UnixMilli()
				_ = writeDurableArchiveExport(statePath, state)
				lastProgress = time.Now()
			}
		}}
		c.externalRuntimeState.mu.Lock()
		state.Sessions = len(c.externalRuntimeState.identities)
		c.externalRuntimeState.mu.Unlock()
		packStart := time.Now()
		err = writeTarZstTrees(ctx, packed, []archiveTree{{c.root, "."}}, c.externalRuntimeState, migrationByteLimit)
		packDuration := time.Since(packStart)
		state.Diagnostics.PackMS = packDuration.Milliseconds()
		if err == nil {
			done := make(chan error, 1)
			go func() { done <- uploader.Close() }()
			ticker := time.NewTicker(time.Second)
			for waiting := true; waiting; {
				select {
				case err = <-done:
					waiting = false
				case <-ticker.C:
					state.UploadedBytes = uploader.uploaded.Load()
					state.ProgressAt = time.Now().UnixMilli()
					_ = writeDurableArchiveExport(statePath, state)
				}
			}
			ticker.Stop()
		} else {
			uploader.Cancel()
		}
		state.Diagnostics.PutMSSum = uploader.putNS.Load() / 1_000_000
		state.Diagnostics.EncoderWaitMS = uploader.waitNS.Load() / 1_000_000
		state.Bytes = packed.written
		state.UploadedBytes = uploader.uploaded.Load()
		if err != nil || state.Bytes == 0 || state.UploadedBytes != state.Bytes {
			logf("cloud_vm_archive stage=stream_upload_failed operation=%s packed_bytes=%d uploaded_bytes=%d duration_ms=%d error=%v", state.Operation, state.Bytes, state.UploadedBytes, time.Since(startedAt).Milliseconds(), err)
			finish("failed")
			return
		}
		logf("cloud_vm_archive stage=stream_upload_complete operation=%s format=tar_zst bytes=%d parts=%d concurrency=8 pack_ms=%d total_ms=%d put_ms_sum=%d encoder_wait_ms=%d", state.Operation, state.Bytes, uploader.index, packDuration.Milliseconds(), time.Since(startedAt).Milliseconds(), uploader.putNS.Load()/1_000_000, uploader.waitNS.Load()/1_000_000)
		finish("exported")
		return
	}
	f, err := os.OpenFile(archivePath+".tmp", os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0600)
	if err != nil {
		finish("failed")
		return
	}
	c.externalRuntimeState.mu.Lock()
	state.Sessions = len(c.externalRuntimeState.identities)
	c.externalRuntimeState.mu.Unlock()
	lastProgress := time.Now()
	packed := &durableArchiveProgressWriter{writer: &archiveLimitWriter{writer: f, remaining: durableArchiveCompressedLimit}, report: func(n int64) {
		state.PackedBytes = n
		if time.Since(lastProgress) >= time.Second {
			state.ProgressAt = time.Now().UnixMilli()
			_ = writeDurableArchiveExport(statePath, state)
			lastProgress = time.Now()
		}
	}}
	if state.format() == "tar_zst" {
		err = writeTarZstTrees(ctx, packed, []archiveTree{{c.root, "."}}, c.externalRuntimeState, migrationByteLimit)
	} else {
		err = writeTarGzTrees(ctx, packed, []archiveTree{{c.root, "."}}, c.externalRuntimeState, migrationByteLimit)
	}
	packDuration := time.Since(startedAt)
	state.Diagnostics.PackMS = packDuration.Milliseconds()
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil || closeErr != nil {
		logf("cloud_vm_archive stage=pack_failed operation=%s format=%s packed_bytes=%d pack_ms=%d error=%v", state.Operation, state.format(), state.PackedBytes, packDuration.Milliseconds(), err)
		_ = os.Remove(archivePath + ".tmp")
		finish("failed")
		return
	}
	if err = os.Rename(archivePath+".tmp", archivePath); err != nil {
		finish("failed")
		return
	}
	info, err := os.Stat(archivePath)
	if err != nil || info.Size() == 0 {
		finish("failed")
		return
	}
	state.Bytes = info.Size()
	logf("cloud_vm_archive stage=pack_complete operation=%s format=%s bytes=%d pack_ms=%d total_ms=%d", state.Operation, state.format(), state.Bytes, packDuration.Milliseconds(), time.Since(startedAt).Milliseconds())
	finish("exported")
}

type durableArchiveProgressWriter struct {
	writer  io.Writer
	written int64
	report  func(int64)
}

func (w *durableArchiveProgressWriter) Write(p []byte) (int, error) {
	n, err := w.writer.Write(p)
	w.written += int64(n)
	w.report(w.written)
	return n, err
}

func readDurableArchiveExport(path string) (durableArchiveExport, error) {
	var state durableArchiveExport
	raw, err := os.ReadFile(path)
	if err == nil {
		err = json.Unmarshal(raw, &state)
	}
	return state, err
}

func writeDurableArchiveExport(path string, state durableArchiveExport) error {
	raw, err := json.Marshal(state)
	if err != nil {
		return err
	}
	if err := os.WriteFile(path+".tmp", raw, 0600); err != nil {
		return err
	}
	return os.Rename(path+".tmp", path)
}
