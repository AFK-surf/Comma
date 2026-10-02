package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"testing"
	"time"
)

type archiveRoundTripper func(*http.Request) (*http.Response, error)

func (f archiveRoundTripper) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestZstdStreamArchiveRoundTrip(t *testing.T) {
	oldClient := signedArchiveHTTPClient
	defer func() { signedArchiveHTTPClient = oldClient }()
	objects := map[string][]byte{}
	var mu sync.Mutex
	signedArchiveHTTPClient = &http.Client{Transport: archiveRoundTripper(func(request *http.Request) (*http.Response, error) {
		key := request.URL.Path
		mu.Lock()
		defer mu.Unlock()
		if request.Method == http.MethodPut {
			data, err := io.ReadAll(request.Body)
			if err != nil {
				return nil, err
			}
			if _, exists := objects[key]; exists {
				return &http.Response{StatusCode: http.StatusPreconditionFailed, Body: io.NopCloser(bytes.NewReader(nil))}, nil
			}
			objects[key] = data
			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(nil))}, nil
		}
		data, exists := objects[key]
		if !exists {
			return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(bytes.NewReader(nil))}, nil
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(data))}, nil
	})}

	source := t.TempDir()
	destination := t.TempDir()
	data := make([]byte, 36<<20)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "user-data"), data, 0600); err != nil {
		t.Fatal(err)
	}
	transfers := make([]signedArchiveTransfer, 10)
	for i := range transfers {
		url := "https://archive.r2.cloudflarestorage.com/part/" + strconv.Itoa(i) + "?X-Amz-Signature=test"
		transfers[i] = signedArchiveTransfer{PutURL: url, GetURL: url}
	}
	uploader, err := newSignedArchiveUploadWriter(context.Background(), transfers)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeTarZstTrees(context.Background(), uploader, []archiveTree{{source, "."}}, nil, migrationByteLimit); err != nil {
		t.Fatal(err)
	}
	if err := uploader.Close(); err != nil {
		t.Fatal(err)
	}
	if uploader.index < 9 || uploader.uploaded.Load() != uploader.written {
		t.Fatalf("unexpected uploaded parts: %d, bytes: %d/%d", uploader.index, uploader.uploaded.Load(), uploader.written)
	}

	parts := make([]signedArchivePart, uploader.index)
	for i := range parts {
		parts[i] = signedArchivePart{SourceURL: transfers[i].GetURL, Bytes: int64(len(objects["/part/"+strconv.Itoa(i)]))}
	}
	reader, err := newParallelSignedArchiveReader(context.Background(), parts, 8)
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	if err := restoreTarZstStateLimit(reader, destination, nil, migrationByteLimit); err != nil {
		t.Fatal(err)
	}
	restored, err := os.ReadFile(filepath.Join(destination, "user-data"))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(restored, data) {
		t.Fatal("restored file differs")
	}
}

func TestZstdStreamArchiveHandlers(t *testing.T) {
	isolateHostRuntimeCommands(t)
	oldClient := signedArchiveHTTPClient
	defer func() { signedArchiveHTTPClient = oldClient }()
	objects := map[string][]byte{}
	var mu sync.Mutex
	signedArchiveHTTPClient = &http.Client{Transport: archiveRoundTripper(func(request *http.Request) (*http.Response, error) {
		key := request.URL.Path
		mu.Lock()
		defer mu.Unlock()
		if request.Method == http.MethodPut {
			if request.Header.Get("If-None-Match") != "*" {
				t.Error("archive part can overwrite an existing object")
			}
			data, err := io.ReadAll(request.Body)
			if err != nil {
				return nil, err
			}
			objects[key] = data
			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(nil))}, nil
		}
		data, ok := objects[key]
		if !ok {
			return &http.Response{StatusCode: http.StatusNotFound, Body: io.NopCloser(bytes.NewReader(nil))}, nil
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(data))}, nil
	})}

	sourceRoot := t.TempDir()
	sourceState := filepath.Join(sourceRoot, ".salix", "state")
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(sourceState, "runtimes"))
	source, err := newConnector(config{root: sourceRoot, externalStateRoot: sourceState})
	if err != nil {
		t.Fatal(err)
	}
	defer source.closeExternalRuntimes()
	source.cloudRuntimeQuiesced = true
	source.cloudRuntimeParkUntil = time.Now().Add(time.Minute)
	data := make([]byte, 9<<20)
	if _, err := rand.Read(data); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(sourceRoot, "owned.bin"), data, 0600); err != nil {
		t.Fatal(err)
	}
	// Older archives can retain a command link while omitting its package.
	commandLink := filepath.Join(".salix", "sprite-home", ".local", "bin", "codex")
	omittedCommand := filepath.Join(sourceRoot, ".salix", "sprite-home", ".cache", "codex")
	if err := os.MkdirAll(filepath.Dir(omittedCommand), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(omittedCommand, []byte("cached command"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(filepath.Join(sourceRoot, commandLink)), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../../.cache/codex", filepath.Join(sourceRoot, commandLink)); err != nil {
		t.Fatal(err)
	}
	operation := "zstd-handler-roundtrip"
	transfers := make([]signedArchiveTransfer, 1024)
	for index := range transfers {
		partURL := "https://archive.r2.cloudflarestorage.com/part/" + strconv.Itoa(index) + "?X-Amz-Signature=test"
		transfers[index] = signedArchiveTransfer{PutURL: partURL, GetURL: partURL}
	}
	body, _ := json.Marshal(map[string]any{"transfers": transfers})
	out := httptest.NewRecorder()
	source.handleDurableArchiveExport(out, httptest.NewRequest(http.MethodPost, "/archive/export?operation="+operation+"&format=tar_zst", bytes.NewReader(body)))
	if out.Code != http.StatusAccepted {
		t.Fatalf("start export: %d %s", out.Code, out.Body.String())
	}
	var status durableArchiveExport
	deadline := time.Now().Add(30 * time.Second)
	for {
		out = httptest.NewRecorder()
		source.handleDurableArchiveExport(out, httptest.NewRequest(http.MethodGet, "/archive/export?operation="+operation, nil))
		if out.Code != http.StatusOK || json.Unmarshal(out.Body.Bytes(), &status) != nil {
			t.Fatalf("export status: %d %s", out.Code, out.Body.String())
		}
		if status.Phase == "exported" {
			break
		}
		if status.Phase == "failed" || time.Now().After(deadline) {
			t.Fatalf("export did not complete: %+v", status)
		}
		time.Sleep(50 * time.Millisecond)
	}
	if status.Format != "tar_zst" || status.Bytes != status.UploadedBytes || status.Bytes <= 2*providerMigrationChunkSize {
		t.Fatalf("unexpected export status: %+v", status)
	}
	if status.Diagnostics == nil || status.Diagnostics.Outcome != "exported" || status.Diagnostics.TotalMS < status.Diagnostics.EncoderWaitMS {
		t.Fatalf("export timing unavailable: %+v", status.Diagnostics)
	}
	if _, err := os.Stat(filepath.Join(source.durableArchiveDir(), "source.tar.zst")); !os.IsNotExist(err) {
		t.Fatalf("streaming export wrote a local archive: %v", err)
	}

	targetRoot := t.TempDir()
	targetState := filepath.Join(targetRoot, ".salix", "state")
	target, err := newConnector(config{vmServer: true, root: targetRoot, externalStateRoot: targetState})
	if err != nil {
		t.Fatal(err)
	}
	defer target.closeExternalRuntimes()
	count := int((status.Bytes + providerMigrationChunkSize - 1) / providerMigrationChunkSize)
	parts := make([]signedArchivePart, count)
	for index := range parts {
		parts[index] = signedArchivePart{SourceURL: transfers[index].GetURL, Bytes: int64(len(objects["/part/"+strconv.Itoa(index)]))}
	}
	importBody, _ := json.Marshal(map[string]any{
		"operation": operation, "action": "stream", "format": "tar_zst",
		"bytes": status.Bytes, "sessions": status.Sessions, "parts": parts, "runtime_paths": []string{},
	})
	out = httptest.NewRecorder()
	target.handleVMArchive(out, httptest.NewRequest(http.MethodPost, "/archive", bytes.NewReader(importBody)))
	if out.Code != http.StatusOK {
		t.Fatalf("restore stream: %d %s", out.Code, out.Body.String())
	}
	restored, err := os.ReadFile(filepath.Join(targetRoot, "owned.bin"))
	if err != nil || !bytes.Equal(restored, data) {
		t.Fatalf("restored data differs: %v", err)
	}
	if link, err := os.Readlink(filepath.Join(targetRoot, commandLink)); err != nil || link != "../../.cache/codex" {
		t.Fatalf("restored command link differs: %q %v", link, err)
	}
	if _, err := os.Stat(filepath.Join(targetRoot, commandLink)); !os.IsNotExist(err) {
		t.Fatalf("omitted command must remain absent: %v", err)
	}
	var nextArchive bytes.Buffer
	if err := writeTarZstTrees(context.Background(), &nextArchive, []archiveTree{{targetRoot, "."}}, nil, migrationByteLimit); err != nil {
		t.Fatalf("archive restored workspace: %v", err)
	}
	nextRoot := t.TempDir()
	if err := restoreTarZstStateLimit(&nextArchive, nextRoot, nil, migrationByteLimit); err != nil {
		t.Fatalf("restore next archive: %v", err)
	}
	if link, err := os.Readlink(filepath.Join(nextRoot, commandLink)); err != nil || link != "../../.cache/codex" {
		t.Fatalf("re-archived command link differs: %q %v", link, err)
	}
	assertStreamReceipt := func(target *connector, outcome string) {
		t.Helper()
		statusBody, _ := json.Marshal(map[string]any{"operation": operation, "action": "status"})
		deadline := time.Now().Add(time.Second)
		for {
			saved := httptest.NewRecorder()
			target.handleVMArchive(saved, httptest.NewRequest(http.MethodPost, "/archive", bytes.NewReader(statusBody)))
			var receipt cloudProviderMigration
			if saved.Code == http.StatusOK && json.Unmarshal(saved.Body.Bytes(), &receipt) == nil && receipt.Diagnostics != nil && receipt.Diagnostics.Outcome == outcome && receipt.Diagnostics.TotalMS >= receipt.Diagnostics.DecoderWaitMS {
				return
			}
			if time.Now().After(deadline) {
				t.Fatalf("%s restore timing unavailable: %d %s", outcome, saved.Code, saved.Body.String())
			}
			time.Sleep(time.Millisecond)
		}
	}
	assertStreamReceipt(target, "restored")
	mu.Lock()
	delete(objects, "/part/0")
	mu.Unlock()
	failedRoot := t.TempDir()
	failedState := filepath.Join(failedRoot, ".salix", "state")
	failedTarget, err := newConnector(config{vmServer: true, root: failedRoot, externalStateRoot: failedState})
	if err != nil {
		t.Fatal(err)
	}
	defer failedTarget.closeExternalRuntimes()
	out = httptest.NewRecorder()
	failedTarget.handleVMArchive(out, httptest.NewRequest(http.MethodPost, "/archive", bytes.NewReader(importBody)))
	if out.Code != http.StatusConflict {
		t.Fatalf("incomplete archive was accepted: %d %s", out.Code, out.Body.String())
	}
	assertStreamReceipt(failedTarget, "failed")
	if _, err := os.Stat(filepath.Join(failedRoot, "owned.bin")); !os.IsNotExist(err) {
		t.Fatalf("incomplete archive restored a file: %v", err)
	}
}
