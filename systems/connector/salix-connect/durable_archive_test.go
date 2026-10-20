package main

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

type archiveTransportFunc func(*http.Request) (*http.Response, error)

func (f archiveTransportFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestSignedArchivePartSettlesConditionalRetryByComparingBytes(t *testing.T) {
	oldClient := signedArchiveHTTPClient
	defer func() { signedArchiveHTTPClient = oldClient }()
	part := []byte("retained archive bytes")
	stored := []byte(nil)
	putCount := 0
	signedArchiveHTTPClient = &http.Client{Transport: archiveTransportFunc(func(request *http.Request) (*http.Response, error) {
		if request.Method == http.MethodPut {
			putCount++
			if request.Header.Get("If-None-Match") != "*" {
				t.Fatal("archive part can overwrite an existing object")
			}
			if stored != nil {
				return &http.Response{StatusCode: http.StatusPreconditionFailed, Body: io.NopCloser(strings.NewReader(""))}, nil
			}
			stored, _ = io.ReadAll(request.Body)
			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(""))}, nil
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(stored))}, nil
	})}
	url := "https://bucket.account.r2.cloudflarestorage.com/part?X-Amz-Signature=test"
	if err := putSignedArchiveChunk(context.Background(), url, url, part); err != nil {
		t.Fatal(err)
	}
	if err := putSignedArchiveChunk(context.Background(), url, url, part); err != nil {
		t.Fatal(err)
	}
	if putCount != 2 {
		t.Fatalf("expected retry to be settled against existing object, got %d PUTs", putCount)
	}
	if err := putSignedArchiveChunk(context.Background(), url, url, []byte("different archive bytes")); err == nil {
		t.Fatal("different bytes under the same archive key were accepted")
	}
}

func TestSignedArchiveReadRetriesTransientFailure(t *testing.T) {
	oldClient := signedArchiveHTTPClient
	defer func() { signedArchiveHTTPClient = oldClient }()
	attempts := 0
	signedArchiveHTTPClient = &http.Client{Transport: archiveTransportFunc(func(request *http.Request) (*http.Response, error) {
		attempts++
		if attempts == 1 {
			return &http.Response{StatusCode: http.StatusServiceUnavailable, Body: io.NopCloser(strings.NewReader(""))}, nil
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader("retained"))}, nil
	})}
	part, err := readSignedArchiveChunk(context.Background(), "https://bucket.account.r2.cloudflarestorage.com/part?X-Amz-Signature=test", 8)
	if err != nil || string(part) != "retained" || attempts != 2 {
		t.Fatalf("transient R2 failure was not retried: attempts=%d part=%q error=%v", attempts, part, err)
	}
}

func TestDurableArchiveExportsAndRestoresFileAboveLegacyLimit(t *testing.T) {
	isolateHostRuntimeCommands(t)
	sourceRoot := t.TempDir()
	sourceState := filepath.Join(sourceRoot, ".salix", "state")
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(sourceState, "runtimes"))
	source, err := newConnector(config{root: sourceRoot, externalStateRoot: sourceState})
	if err != nil {
		t.Fatal(err)
	}
	defer source.closeRuntimes()
	source.cloudRuntimeQuiesced = true
	source.cloudRuntimeParkUntil = testFarFuture
	large := make([]byte, maxArchiveBytes+4096)
	incompressibleBytes(large)
	if err := os.WriteFile(filepath.Join(sourceRoot, "owned.bin"), large, 0600); err != nil {
		t.Fatal(err)
	}
	// State left by an earlier release is never exported.
	legacyState := filepath.Join(sourceState, legacyExternalRuntimeDir, "state.db")
	if err := os.MkdirAll(filepath.Dir(legacyState), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(legacyState, []byte("legacy"), 0600); err != nil {
		t.Fatal(err)
	}

	operation := "durable-one"
	request := httptest.NewRequest(http.MethodPost, "/archive/export?operation="+operation, nil)
	out := httptest.NewRecorder()
	source.handleDurableArchiveExport(out, request)
	if out.Code != http.StatusAccepted {
		t.Fatalf("start export: %d %s", out.Code, out.Body.String())
	}
	var status struct {
		Diagnostics *archiveDiagnostics `json:"diagnostics"`
		Phase       string              `json:"phase"`
		Bytes       int64               `json:"bytes"`
		Sessions    int                 `json:"sessions"`
	}
	// Gzipping 64 MiB of incompressible data takes 20-45s under -race on
	// 4-vCPU CI runners; the go test timeout stops a stuck export.
	waitForCondition(t, "the export to finish", func() bool {
		out = httptest.NewRecorder()
		source.handleDurableArchiveExport(out, httptest.NewRequest(http.MethodGet, "/archive/export?operation="+operation, nil))
		if out.Code != 200 || json.Unmarshal(out.Body.Bytes(), &status) != nil {
			t.Fatalf("export status: %d %s", out.Code, out.Body.String())
		}
		if status.Phase == "failed" {
			t.Fatalf("export did not complete: %+v", status)
		}
		return status.Phase == "exported"
	})
	if status.Diagnostics == nil || status.Diagnostics.TotalMS <= 0 || status.Diagnostics.PackMS <= 0 || status.Diagnostics.Outcome != "exported" {
		t.Fatalf("export timing unavailable after completion: %+v", status.Diagnostics)
	}
	if status.Bytes <= maxArchiveBytes || status.Sessions != 0 {
		t.Fatalf("export omitted large file or reported Sessions: %+v", status)
	}

	targetRoot := t.TempDir()
	targetState := filepath.Join(targetRoot, ".salix", "state")
	target, err := newConnector(config{vmServer: true, root: targetRoot, externalStateRoot: targetState})
	if err != nil {
		t.Fatal(err)
	}
	defer target.closeRuntimes()
	oldClient := signedArchiveHTTPClient
	defer func() { signedArchiveHTTPClient = oldClient }()
	var storedPart []byte
	signedArchiveHTTPClient = &http.Client{Transport: archiveTransportFunc(func(request *http.Request) (*http.Response, error) {
		if request.Method == http.MethodPut {
			if request.Header.Get("If-None-Match") != "*" {
				t.Fatal("direct upload must not overwrite an existing part")
			}
			storedPart, _ = io.ReadAll(request.Body)
			return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(""))}, nil
		}
		return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(bytes.NewReader(storedPart))}, nil
	})}
	importRequest := func(body map[string]any) *httptest.ResponseRecorder {
		t.Helper()
		body["operation"] = operation
		raw, _ := json.Marshal(body)
		out := httptest.NewRecorder()
		target.handleVMArchive(out, httptest.NewRequest(http.MethodPost, "/archive", bytes.NewReader(raw)))
		return out
	}
	for offset := int64(0); offset < status.Bytes; {
		if offset == 0 {
			partURL := "https://bucket.account.r2.cloudflarestorage.com/part?X-Amz-Signature=test"
			payload, _ := json.Marshal(signedArchiveTransfer{PutURL: partURL, GetURL: partURL})
			out = httptest.NewRecorder()
			url := "/archive/export?operation=" + operation + "&offset=0"
			source.handleDurableArchiveExport(out, httptest.NewRequest(http.MethodPut, url, bytes.NewReader(payload)))
			if out.Code != 200 {
				t.Fatalf("direct export part: %d %s", out.Code, out.Body.String())
			}
			var uploaded struct {
				NextOffset int64 `json:"next_offset"`
			}
			if err := json.Unmarshal(out.Body.Bytes(), &uploaded); err != nil || uploaded.NextOffset == 0 {
				t.Fatalf("direct export response: %v", err)
			}
			result := importRequest(map[string]any{"action": "part", "offset": offset, "source_url": partURL, "bytes": uploaded.NextOffset})
			if result.Code != 200 {
				t.Fatalf("direct import part: %d %s", result.Code, result.Body.String())
			}
			offset = uploaded.NextOffset
			continue
		}
		out = httptest.NewRecorder()
		url := "/archive/export?operation=" + operation + "&offset=" + strconv.FormatInt(offset, 10)
		source.handleDurableArchiveExport(out, httptest.NewRequest(http.MethodGet, url, nil))
		if out.Code != 200 {
			t.Fatalf("read export chunk: %d %s", out.Code, out.Body.String())
		}
		var part struct {
			Data string `json:"data"`
		}
		if err := json.Unmarshal(out.Body.Bytes(), &part); err != nil {
			t.Fatal(err)
		}
		decoded, err := base64.StdEncoding.DecodeString(part.Data)
		if err != nil || len(decoded) == 0 {
			t.Fatalf("invalid export part: %v", err)
		}
		result := importRequest(map[string]any{"action": "part", "offset": offset, "data": part.Data})
		if result.Code != 200 {
			t.Fatalf("import part: %d %s", result.Code, result.Body.String())
		}
		offset += int64(len(decoded))
	}
	out = importRequest(map[string]any{"action": "finish", "bytes": status.Bytes, "sessions": status.Sessions, "runtime_paths": []string{}})
	if out.Code != 200 {
		t.Fatalf("finish restore: %d %s", out.Code, out.Body.String())
	}
	// Read the saved receipt after the final response, without tailing logs.
	out = importRequest(map[string]any{"action": "status"})
	var result cloudProviderMigration
	if err := json.Unmarshal(out.Body.Bytes(), &result); err != nil || result.Diagnostics == nil || result.Diagnostics.Outcome != "restored" || result.Diagnostics.TotalMS < result.Diagnostics.ExtractMS {
		t.Fatalf("restore timing unavailable: %s, %v", out.Body.String(), err)
	}
	restored, err := os.ReadFile(filepath.Join(targetRoot, "owned.bin"))
	if err != nil || !bytes.Equal(restored, large) {
		t.Fatalf("large file restore mismatch: %v", err)
	}
	if _, err := os.Lstat(filepath.Join(targetState, legacyExternalRuntimeDir)); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("legacy external runtime state was archived: %v", err)
	}
}

func TestDurableArchiveCancelStopsSameOperationBeforeOrDuringExport(t *testing.T) {
	isolateHostRuntimeCommands(t)
	root := t.TempDir()
	stateRoot := filepath.Join(root, ".salix", "state")
	t.Setenv("SALIX_MANAGED_RUNTIME_ROOT", filepath.Join(stateRoot, "runtimes"))
	c, err := newConnector(config{root: root, externalStateRoot: stateRoot})
	if err != nil {
		t.Fatal(err)
	}
	defer c.closeRuntimes()
	c.cloudRuntimeQuiesced = true
	c.cloudRuntimeParkUntil = testFarFuture
	if err := os.WriteFile(filepath.Join(root, "owned.txt"), []byte("retain me"), 0600); err != nil {
		t.Fatal(err)
	}
	request := func(method, operation string) *httptest.ResponseRecorder {
		out := httptest.NewRecorder()
		c.handleDurableArchiveExport(out, httptest.NewRequest(method, "/archive/export?operation="+operation, nil))
		return out
	}
	if out := request(http.MethodDelete, "archive-before"); out.Code != 200 {
		t.Fatalf("cancel before export: %d %s", out.Code, out.Body.String())
	}
	if out := request(http.MethodPost, "archive-before"); out.Code != http.StatusConflict {
		t.Fatalf("cancelled operation restarted: %d %s", out.Code, out.Body.String())
	}
	if out := request(http.MethodPost, "archive-during"); out.Code != http.StatusAccepted {
		t.Fatalf("start export: %d %s", out.Code, out.Body.String())
	}
	if out := request(http.MethodDelete, "archive-during"); out.Code != http.StatusAccepted {
		t.Fatalf("cancel export: %d %s", out.Code, out.Body.String())
	}
	waitForCondition(t, "the cancelled export to stop", func() bool {
		out := request(http.MethodGet, "archive-during")
		var status durableArchiveExport
		if out.Code != 200 || json.Unmarshal(out.Body.Bytes(), &status) != nil {
			t.Fatalf("cancel status: %d %s", out.Code, out.Body.String())
		}
		return status.Phase == "cancelled"
	})
	if data, err := os.ReadFile(filepath.Join(root, "owned.txt")); err != nil || string(data) != "retain me" {
		t.Fatalf("cancel changed user file: %v", err)
	}
}
