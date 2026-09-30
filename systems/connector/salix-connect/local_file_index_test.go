package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const testLocalFileToken = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

func TestReadRefStreamsOnlyManagedSnapshotForExactLiveIdentity(t *testing.T) {
	root := t.TempDir()
	ref := writeLocalFileFixture(t, root, []byte(strings.Repeat("immutable", 40_000)), "registered")
	if _, err := readLocalFileIndexRecord(root, ref); err != nil {
		t.Fatalf("fixture index did not satisfy the production reader: %v", err)
	}
	c := newLocalFileTestConnector(root)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var session *connectionSession
	var streamed []byte
	session = c.claimConnection(ctx, func(_ context.Context, frame message) error {
		if frame.Stream != nil && frame.Stream.Channel == "data" {
			chunk, err := base64.StdEncoding.DecodeString(frame.Stream.Data)
			if err != nil {
				t.Fatal(err)
			}
			streamed = append(streamed, chunk...)
			session.completePendingAck(frame.ID, frame.Stream.Seq, "")
		}
		return nil
	}, nil)
	defer session.close(context.Canceled)
	if !c.setIdentity(session, "run_exact", "dev_exact", "connector_exact", "user_exact", 17) {
		t.Fatal("failed to bind test identity")
	}

	result, err := c.dispatchSession(ctx, session, "request-1", "read_ref", localFileParams(ref))
	if err != nil {
		t.Fatal(err)
	}
	resultMap := result.(map[string]any)
	if got := resultMap["size"]; got != int64(len(streamed)) {
		t.Fatalf("size=%v want=%d", got, len(streamed))
	}
	if !strings.HasPrefix(string(streamed), "immutable") {
		t.Fatal("snapshot bytes were not streamed")
	}
	encoded, _ := json.Marshal(result)
	if strings.Contains(string(encoded), root) || strings.Contains(string(encoded), "path") {
		t.Fatalf("read_ref result leaked a host path: %s", encoded)
	}
}

func TestReadRefAcceptsV2IndexOnlyForItsExactOwner(t *testing.T) {
	root := t.TempDir()
	ref := writeLocalFileFixtureV2(t, root, []byte("private owner bytes"), "registered", "user_exact")
	record, err := readLocalFileIndexRecord(root, ref)
	if err != nil {
		t.Fatalf("V2 fixture index did not satisfy the production reader: %v", err)
	}
	if record.Version != 2 || record.OwnerUserID != "user_exact" {
		t.Fatalf("unexpected V2 owner record: %#v", record)
	}

	c := newLocalFileTestConnector(root)
	ctx := context.Background()
	var session *connectionSession
	session = c.claimConnection(ctx, func(_ context.Context, frame message) error {
		if frame.Stream != nil {
			session.completePendingAck(frame.ID, frame.Stream.Seq, "")
		}
		return nil
	}, nil)
	defer session.close(context.Canceled)
	c.setIdentity(session, "run_exact", "dev_exact", "connector_exact", "user_exact", 17)

	if _, err := c.dispatchSession(ctx, session, "v2-owner", "read_ref", localFileParams(ref)); err != nil {
		t.Fatalf("exact-owner V2 ref was rejected: %v", err)
	}

	writeLocalFileFixtureV2WithRef(t, root, ref, []byte("private owner bytes"), "registered", "user_other")
	if _, err := c.dispatchSession(ctx, session, "v2-foreign", "read_ref", localFileParams(ref)); err == nil {
		t.Fatal("foreign-owner V2 ref was accepted")
	}
}

func TestLocalFileIndexKeepsStrictV1CompatibilityAndRejectsUnknownV2Shape(t *testing.T) {
	root := t.TempDir()
	ref := writeLocalFileFixture(t, root, []byte("legacy"), "registered")
	if record, err := readLocalFileIndexRecord(root, ref); err != nil || record.Version != 1 {
		t.Fatalf("strict legacy V1 record was rejected: record=%#v err=%v", record, err)
	}

	writeLocalFileFixtureV2WithRef(t, root, ref, []byte("v2"), "registered", "user_exact")
	entryPath := filepath.Join(root, "entries", testLocalFileToken+".json")
	data, err := os.ReadFile(entryPath)
	if err != nil {
		t.Fatal(err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatal(err)
	}
	raw["unknown"] = true
	encoded, err := json.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(entryPath, encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readLocalFileIndexRecord(root, ref); err == nil {
		t.Fatal("V2 record with an unknown key was accepted")
	}

	delete(raw, "unknown")
	raw["version"] = 3
	encoded, err = json.Marshal(raw)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(entryPath, encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := readLocalFileIndexRecord(root, ref); err == nil {
		t.Fatal("unknown local index version was accepted")
	}
}

func TestReadRefNeverSignalsEOFAfterSnapshotMutatesDuringStream(t *testing.T) {
	root := t.TempDir()
	contents := []byte(strings.Repeat("A", localFileChunkBytes*2))
	ref := writeLocalFileFixture(t, root, contents, "registered")
	objectPath := filepath.Join(root, "objects", testLocalFileToken)
	c := newLocalFileTestConnector(root)
	ctx := context.Background()
	var session *connectionSession
	mutated := false
	sawEOF := false
	session = c.claimConnection(ctx, func(_ context.Context, frame message) error {
		if frame.Stream == nil || frame.Stream.Channel != "data" {
			return nil
		}
		if frame.Stream.EOF {
			sawEOF = true
		}
		if frame.Stream.Data != "" && !mutated {
			mutated = true
			file, err := os.OpenFile(objectPath, os.O_WRONLY, 0)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := file.WriteAt([]byte(strings.Repeat("B", localFileChunkBytes)), localFileChunkBytes); err != nil {
				_ = file.Close()
				t.Fatal(err)
			}
			if err := file.Close(); err != nil {
				t.Fatal(err)
			}
		}
		if frame.Stream.Data != "" {
			session.completePendingAck(frame.ID, frame.Stream.Seq, "")
		}
		return nil
	}, nil)
	defer session.close(context.Canceled)
	c.setIdentity(session, "run_exact", "dev_exact", "connector_exact", "user_exact", 17)

	if _, err := c.dispatchSession(ctx, session, "mutated", "read_ref", localFileParams(ref)); err == nil {
		t.Fatal("mutation during stream was accepted")
	}
	if !mutated {
		t.Fatal("test did not mutate the streamed snapshot")
	}
	if sawEOF {
		t.Fatal("stream signaled EOF before terminal size/hash validation")
	}
}

func TestReadRefNeverSignalsEOFAfterConnectionReplacement(t *testing.T) {
	root := t.TempDir()
	ref := writeLocalFileFixture(t, root, []byte("one frame"), "registered")
	c := newLocalFileTestConnector(root)
	ctx := context.Background()
	var old *connectionSession
	var replacement *connectionSession
	sawEOF := false
	old = c.claimConnection(ctx, func(_ context.Context, frame message) error {
		if frame.Stream != nil && frame.Stream.Channel == "data" {
			if frame.Stream.EOF {
				sawEOF = true
			}
			if frame.Stream.Data != "" && replacement == nil {
				replacement = c.claimConnection(ctx, func(_ context.Context, _ message) error { return nil }, nil)
			}
		}
		return nil
	}, nil)
	c.setIdentity(old, "run_exact", "dev_exact", "connector_exact", "user_exact", 17)

	if _, err := c.dispatchSession(ctx, old, "replaced", "read_ref", localFileParams(ref)); err == nil {
		t.Fatal("replaced connection completed its read")
	}
	if replacement == nil {
		t.Fatal("test did not replace the connection")
	}
	defer replacement.close(context.Canceled)
	if sawEOF {
		t.Fatal("replaced connection signaled EOF before exact terminal validation")
	}
}

func TestReadRefFailsClosedForIdentityShapeRevocationAndBounds(t *testing.T) {
	root := t.TempDir()
	ref := writeLocalFileFixture(t, root, []byte("secret"), "registered")
	c := newLocalFileTestConnector(root)
	ctx := context.Background()
	var session *connectionSession
	session = c.claimConnection(ctx, func(_ context.Context, frame message) error {
		if frame.Stream != nil {
			session.completePendingAck(frame.ID, frame.Stream.Seq, "")
		}
		return nil
	}, nil)
	defer session.close(context.Canceled)
	c.setIdentity(session, "run_exact", "dev_exact", "connector_exact", "user_exact", 17)

	mutations := []func(map[string]any){
		func(p map[string]any) { p["owner_user_id"] = "user_other" },
		func(p map[string]any) { p["stable_device_id"] = "dev_other" },
		func(p map[string]any) { p["connector_run_id"] = "run_other" },
		func(p map[string]any) { p["connection_generation"] = 18 },
		func(p map[string]any) { p["stream_lease_ms"] = int64(localFileStreamLeaseMS + 1) },
		func(p map[string]any) { p["path"] = "/etc/passwd" },
		func(p map[string]any) { p["expected_max_bytes"] = 5 },
	}
	for index, mutate := range mutations {
		params := localFileParams(ref)
		mutate(params)
		if _, err := c.dispatchSession(ctx, session, "rejected", "read_ref", params); err == nil {
			t.Fatalf("mutation %d was accepted", index)
		}
	}

	writeLocalFileFixtureWithRef(t, root, ref, []byte("secret"), "revoked")
	if _, err := c.dispatchSession(ctx, session, "revoked", "read_ref", localFileParams(ref)); err == nil {
		t.Fatal("revoked ref was accepted")
	}
	writeLocalFileFixtureWithRef(t, root, ref, []byte("secret"), "draft")
	if _, err := c.dispatchSession(ctx, session, "draft", "read_ref", localFileParams(ref)); err == nil {
		t.Fatal("unregistered draft ref was accepted")
	}
	writeLocalFileFixtureWithRef(t, root, ref, []byte("secret"), "bound")
	if _, err := c.dispatchSession(ctx, session, "bound", "read_ref", localFileParams(ref)); err != nil {
		t.Fatalf("canonical-bound ref was rejected: %v", err)
	}
}

func TestReadRefRejectsSymlinkAndReplacementConnection(t *testing.T) {
	root := t.TempDir()
	ref := writeLocalFileFixture(t, root, []byte("secret"), "registered")
	c := newLocalFileTestConnector(root)
	ctx := context.Background()
	old := c.claimConnection(ctx, func(_ context.Context, _ message) error { return nil }, nil)
	c.setIdentity(old, "run_exact", "dev_exact", "connector_exact", "user_exact", 17)
	newSession := c.claimConnection(ctx, func(_ context.Context, _ message) error { return nil }, nil)
	defer newSession.close(context.Canceled)
	if _, err := c.dispatchSession(ctx, old, "old", "read_ref", localFileParams(ref)); err == nil {
		t.Fatal("replaced connection read was accepted")
	}

	objectPath := filepath.Join(root, "objects", testLocalFileToken)
	outside := filepath.Join(t.TempDir(), "outside")
	if err := os.WriteFile(outside, []byte("outside"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(objectPath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, objectPath); err != nil {
		t.Fatal(err)
	}
	c.setIdentity(newSession, "run_exact", "dev_exact", "connector_exact", "user_exact", 17)
	if _, err := c.dispatchSession(ctx, newSession, "symlink", "read_ref", localFileParams(ref)); err == nil {
		t.Fatal("symlink object was accepted")
	}
}

func TestPinnedLocalFileIndexDoesNotFollowRenamedRoot(t *testing.T) {
	root := t.TempDir()
	ref := writeLocalFileFixture(t, root, []byte("trusted"), "registered")
	index, err := openPinnedLocalFileIndex(root)
	if err != nil {
		t.Fatal(err)
	}
	defer index.close()

	moved := root + "-moved"
	if err := os.Rename(root, moved); err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(moved)
	outside := t.TempDir()
	writeLocalFileFixtureWithRef(t, outside, ref, []byte("attacker"), "registered")
	if err := os.Symlink(outside, root); err != nil {
		t.Fatal(err)
	}
	if _, err := openPinnedLocalFileIndex(root); err == nil {
		t.Fatal("symlinked replacement root was accepted")
	}

	record, err := readLocalFileIndexRecordFrom(index, ref)
	if err != nil {
		t.Fatal(err)
	}
	file, err := index.openObject(record.ObjectID)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	bytes, err := io.ReadAll(file)
	if err != nil {
		t.Fatal(err)
	}
	if string(bytes) != "trusted" {
		t.Fatalf("pinned index escaped to replacement root: %q", bytes)
	}
}

func TestLocalFileIndexConfigAndCapabilityAreLocalOnly(t *testing.T) {
	root := filepath.Join(t.TempDir(), "local-file-index")
	configPath := filepath.Join(t.TempDir(), "connector.json")
	encoded := []byte(`{"connector":{"root":"."},"electron":{"local_file_index_root":` +
		strconv.Quote(root) + `}}`)
	if err := os.WriteFile(configPath, encoded, 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := config{configPath: configPath}
	if err := applyConfigFile(&cfg, map[string]bool{}); err != nil {
		t.Fatal(err)
	}
	normalizeConfig(&cfg)
	if cfg.localFileIndexRoot != root {
		t.Fatalf("localFileIndexRoot=%q want=%q", cfg.localFileIndexRoot, root)
	}
	c := newLocalFileTestConnector(root)
	if !c.localFileImportAvailable() {
		t.Fatal("local_file_import_v1 capability should be enabled")
	}
}

func newLocalFileTestConnector(root string) *connector {
	return &connector{
		cfg: config{
			localFileIndexRoot: root,
		},
		requestSlots:      make(chan struct{}, maxConcurrentRequests),
		requestOperations: map[string]*requestOperation{},
	}
}

func localFileParams(ref string) map[string]any {
	return map[string]any{
		"canonical_message_id":  "msg1_exact",
		"connection_generation": int64(17),
		"connector_run_id":      "run_exact",
		"expected_max_bytes":    int64(localFileMaxBytes),
		"local_file_ref":        ref,
		"owner_user_id":         "user_exact",
		"stream_lease_ms":       int64(localFileStreamLeaseMS),
		"stable_device_id":      "dev_exact",
	}
}

func writeLocalFileFixture(t *testing.T, root string, bytes []byte, state string) string {
	t.Helper()
	ref := "lfi1_" + testLocalFileToken
	writeLocalFileFixtureWithRef(t, root, ref, bytes, state)
	return ref
}

func writeLocalFileFixtureWithRef(t *testing.T, root, ref string, bytes []byte, state string) {
	t.Helper()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	objectID := strings.TrimPrefix(ref, "lfi1_")
	if err := os.MkdirAll(filepath.Join(root, "entries"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "objects"), 0o700); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(bytes)
	record := localFileIndexRecord{
		CreatedAtMS:  1,
		DisplayName:  "fixture.bin",
		LocalFileRef: ref,
		MediaType:    "application/octet-stream",
		ObjectID:     objectID,
		SHA256:       hex.EncodeToString(hash[:]),
		Size:         int64(len(bytes)),
		State:        state,
		Version:      1,
	}
	encoded, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "objects", objectID), bytes, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "entries", objectID+".json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}

func writeLocalFileFixtureV2(t *testing.T, root string, bytes []byte, state, ownerUserID string) string {
	t.Helper()
	ref := "lfi1_" + testLocalFileToken
	writeLocalFileFixtureV2WithRef(t, root, ref, bytes, state, ownerUserID)
	return ref
}

func writeLocalFileFixtureV2WithRef(t *testing.T, root, ref string, bytes []byte, state, ownerUserID string) {
	t.Helper()
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	objectID := strings.TrimPrefix(ref, "lfi1_")
	if err := os.MkdirAll(filepath.Join(root, "entries"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "objects"), 0o700); err != nil {
		t.Fatal(err)
	}
	hash := sha256.Sum256(bytes)
	record := map[string]any{
		"created_at_ms":  int64(1),
		"display_name":   "fixture.bin",
		"local_file_ref": ref,
		"media_type":     "application/octet-stream",
		"object_id":      objectID,
		"owner_user_id":  ownerUserID,
		"sha256":         hex.EncodeToString(hash[:]),
		"size":           int64(len(bytes)),
		"state":          state,
		"version":        2,
	}
	encoded, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "objects", objectID), bytes, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "entries", objectID+".json"), encoded, 0o600); err != nil {
		t.Fatal(err)
	}
}
