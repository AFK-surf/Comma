package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"regexp"
	"runtime"
	"strings"
)

const (
	localFileIndexVersion        = 2
	localFileIndexRecordMaxBytes = 16 * 1024
	localFileMaxBytes            = 512 * 1024 * 1024
	localFileChunkBytes          = 256 * 1024
	localFileStreamLeaseMS       = 60 * 1000
)

var (
	localFileRefPattern     = regexp.MustCompile(`^lfi1_[A-Za-z0-9_-]{43}$`)
	localFileTokenPattern   = regexp.MustCompile(`^[A-Za-z0-9_-]{43}$`)
	localFileHashPattern    = regexp.MustCompile(`^[a-f0-9]{64}$`)
	errLocalFileRequest     = errors.New("local attachment request rejected")
	errLocalFileUnavailable = errors.New("local attachment unavailable")
	errLocalFileCorrupt     = errors.New("local attachment snapshot is corrupt")
)

type localFileIndexRecord struct {
	CreatedAtMS  int64  `json:"created_at_ms"`
	DisplayName  string `json:"display_name"`
	LocalFileRef string `json:"local_file_ref"`
	MediaType    string `json:"media_type"`
	ObjectID     string `json:"object_id"`
	OwnerUserID  string `json:"owner_user_id,omitempty"`
	SHA256       string `json:"sha256"`
	Size         int64  `json:"size"`
	State        string `json:"state"`
	Version      int    `json:"version"`
}

type localFileReadRequest struct {
	ref                  string
	ownerUserID          string
	stableDeviceID       string
	connectorRunID       string
	connectionGeneration int64
	canonicalMessageID   string
	expectedMaxBytes     int64
	streamLeaseMS        int64
}

type localFileIndexHandle struct {
	root          *os.File
	entries       *os.File
	objects       *os.File
	rootedRoot    *os.Root
	rootedEntries *os.Root
	rootedObjects *os.Root
}

func (index *localFileIndexHandle) close() {
	if index == nil {
		return
	}
	if index.objects != nil {
		_ = index.objects.Close()
	}
	if index.rootedObjects != nil {
		_ = index.rootedObjects.Close()
	}
	if index.entries != nil {
		_ = index.entries.Close()
	}
	if index.rootedEntries != nil {
		_ = index.rootedEntries.Close()
	}
	if index.root != nil {
		_ = index.root.Close()
	}
	if index.rootedRoot != nil {
		_ = index.rootedRoot.Close()
	}
}

func (index *localFileIndexHandle) openEntry(objectID string) (*os.File, error) {
	if !localFileTokenPattern.MatchString(objectID) {
		return nil, errLocalFileRequest
	}
	return index.openEntryFile(objectID + ".json")
}

func (index *localFileIndexHandle) openObject(objectID string) (*os.File, error) {
	if !localFileTokenPattern.MatchString(objectID) {
		return nil, errLocalFileRequest
	}
	return index.openObjectFile(objectID)
}

// methodReadRefFrames is a dedicated read-only transport, modeled in
// tla/salix/LocalFileImport.tla. It accepts no path
// and performs no generic filesystem resolution: the only possible target is
// the immutable object selected by an opaque ref in Electron's private index.
func (c *connector) methodReadRefFrames(
	ctx context.Context,
	session *connectionSession,
	id string,
	params map[string]any,
) (map[string]any, error) {
	request, err := parseLocalFileReadRequest(params)
	if err != nil {
		return nil, err
	}
	if !c.localFileReadIdentityCurrent(session, request) {
		return nil, errLocalFileUnavailable
	}
	if c.cfg.localFileIndexRoot == "" {
		return nil, errLocalFileUnavailable
	}

	index, err := openPinnedLocalFileIndex(c.cfg.localFileIndexRoot)
	if err != nil {
		return nil, errLocalFileUnavailable
	}
	defer index.close()
	record, err := readLocalFileIndexRecordFrom(index, request.ref)
	if err != nil {
		return nil, err
	}
	// V2 records bind the private Electron snapshot to the same stable user
	// already fenced by the server route and live Connector identity. V1 stays
	// readable only for its bounded legacy retention window.
	if record.Version == 2 && record.OwnerUserID != request.ownerUserID {
		return nil, errLocalFileUnavailable
	}
	// A draft has no authenticated server route yet. Only Electron Main's
	// narrow post-registration transition can make a snapshot readable.
	if (record.State != "registered" && record.State != "bound") || record.Size > request.expectedMaxBytes {
		return nil, errLocalFileUnavailable
	}

	file, err := index.openObject(record.ObjectID)
	if err != nil {
		return nil, errLocalFileUnavailable
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || !localFileModePrivate(info.Mode()) ||
		info.Size() != record.Size || info.Size() > localFileMaxBytes {
		return nil, errLocalFileCorrupt
	}

	// Verify the immutable snapshot before emitting its first byte. A receiver
	// still stages the stream and commits only after the terminal size/hash.
	verifiedHash, err := hashLocalFile(file, record.Size)
	if err != nil || verifiedHash != record.SHA256 {
		return nil, errLocalFileCorrupt
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, errLocalFileUnavailable
	}

	buf := make([]byte, localFileChunkBytes)
	streamHash := sha256.New()
	var sent int64
	seq := 0
	for sent < record.Size {
		remaining := record.Size - sent
		if remaining < int64(len(buf)) {
			buf = buf[:remaining]
		}
		n, readErr := io.ReadFull(file, buf)
		if readErr != nil {
			return nil, errLocalFileCorrupt
		}
		sent += int64(n)
		_, _ = streamHash.Write(buf[:n])
		seq++
		frame := message{
			ID:   id,
			Type: "stream",
			Stream: &streamData{
				Channel: "data",
				Data:    base64.StdEncoding.EncodeToString(buf[:n]),
				EOF:     false,
				Seq:     seq,
			},
		}
		if err := session.sendReadStreamFrame(ctx, id, seq, frame); err != nil {
			return nil, err
		}
	}
	actualHash := hex.EncodeToString(streamHash.Sum(nil))
	if sent != record.Size || actualHash != record.SHA256 {
		return nil, errLocalFileCorrupt
	}
	// EOF is a commit marker, not a property of the final data chunk. Emit it
	// only after the complete delivered byte sequence satisfies the immutable
	// record and the same exact live connection tuple still owns the request.
	if !c.localFileReadIdentityCurrent(session, request) {
		return nil, errLocalFileUnavailable
	}
	seq++
	if err := session.send(message{ID: id, Type: "stream", Stream: &streamData{Channel: "data", EOF: true, Seq: seq}}); err != nil {
		return nil, err
	}
	return map[string]any{
		"local_file_ref":       request.ref,
		"canonical_message_id": request.canonicalMessageID,
		"size":                 sent,
		"sha256":               actualHash,
	}, nil
}

func (c *connector) localFileReadIdentityCurrent(session *connectionSession, request localFileReadRequest) bool {
	if session == nil || session.ctx.Err() != nil {
		return false
	}
	c.connectionMu.Lock()
	defer c.connectionMu.Unlock()
	return c.activeConnection == session &&
		c.connectorRunID != "" && c.deviceID != "" && c.ownerUserID != "" &&
		c.connectionGeneration > 0 &&
		request.connectorRunID == c.connectorRunID &&
		request.stableDeviceID == c.deviceID &&
		request.ownerUserID == c.ownerUserID &&
		request.connectionGeneration == c.connectionGeneration
}

func parseLocalFileReadRequest(params map[string]any) (localFileReadRequest, error) {
	allowed := map[string]bool{
		"canonical_message_id":  true,
		"connection_generation": true,
		"connector_run_id":      true,
		"expected_max_bytes":    true,
		"local_file_ref":        true,
		"owner_user_id":         true,
		"stream_lease_ms":       true,
		"stable_device_id":      true,
	}
	if len(params) != len(allowed) {
		return localFileReadRequest{}, errLocalFileRequest
	}
	for key := range params {
		if !allowed[key] {
			return localFileReadRequest{}, errLocalFileRequest
		}
	}
	request := localFileReadRequest{
		ref:                  stringParam(params, "local_file_ref"),
		ownerUserID:          stringParam(params, "owner_user_id"),
		stableDeviceID:       stringParam(params, "stable_device_id"),
		connectorRunID:       stringParam(params, "connector_run_id"),
		canonicalMessageID:   stringParam(params, "canonical_message_id"),
		expectedMaxBytes:     exactInt64Param(params["expected_max_bytes"]),
		streamLeaseMS:        exactInt64Param(params["stream_lease_ms"]),
		connectionGeneration: exactInt64Param(params["connection_generation"]),
	}
	if !localFileRefPattern.MatchString(request.ref) || request.ownerUserID == "" ||
		request.stableDeviceID == "" || request.connectorRunID == "" ||
		request.canonicalMessageID == "" || len(request.canonicalMessageID) > 160 ||
		request.connectionGeneration <= 0 || request.expectedMaxBytes < 0 ||
		request.expectedMaxBytes > localFileMaxBytes || request.streamLeaseMS != localFileStreamLeaseMS {
		return localFileReadRequest{}, errLocalFileRequest
	}
	return request, nil
}

func readLocalFileIndexRecord(root, ref string) (localFileIndexRecord, error) {
	index, err := openPinnedLocalFileIndex(root)
	if err != nil {
		return localFileIndexRecord{}, errLocalFileUnavailable
	}
	defer index.close()
	return readLocalFileIndexRecordFrom(index, ref)
}

func readLocalFileIndexRecordFrom(index *localFileIndexHandle, ref string) (localFileIndexRecord, error) {
	if !localFileRefPattern.MatchString(ref) {
		return localFileIndexRecord{}, errLocalFileRequest
	}
	objectID := ref[len("lfi1_"):]
	if !localFileTokenPattern.MatchString(objectID) {
		return localFileIndexRecord{}, errLocalFileRequest
	}
	entry, err := index.openEntry(objectID)
	if err != nil {
		return localFileIndexRecord{}, errLocalFileUnavailable
	}
	defer entry.Close()
	info, err := entry.Stat()
	if err != nil || !info.Mode().IsRegular() || !localFileModePrivate(info.Mode()) || info.Size() <= 0 || info.Size() > localFileIndexRecordMaxBytes {
		return localFileIndexRecord{}, errLocalFileCorrupt
	}
	data, err := io.ReadAll(io.LimitReader(entry, localFileIndexRecordMaxBytes+1))
	if err != nil || len(data) > localFileIndexRecordMaxBytes {
		return localFileIndexRecord{}, errLocalFileCorrupt
	}
	var raw map[string]json.RawMessage
	if json.Unmarshal(data, &raw) != nil {
		return localFileIndexRecord{}, errLocalFileCorrupt
	}
	var version int
	if json.Unmarshal(raw["version"], &version) != nil || (version != 1 && version != 2) {
		return localFileIndexRecord{}, errLocalFileCorrupt
	}
	keys := []string{"created_at_ms", "display_name", "local_file_ref", "media_type", "object_id", "sha256", "size", "state", "version"}
	if version == 2 {
		keys = append(keys, "owner_user_id")
	}
	if len(raw) != len(keys) {
		return localFileIndexRecord{}, errLocalFileCorrupt
	}
	for _, key := range keys {
		if _, ok := raw[key]; !ok {
			return localFileIndexRecord{}, errLocalFileCorrupt
		}
	}
	var record localFileIndexRecord
	if json.Unmarshal(data, &record) != nil || record.Version != version ||
		record.LocalFileRef != ref || record.ObjectID != objectID ||
		record.CreatedAtMS <= 0 || record.Size < 0 || record.Size > localFileMaxBytes ||
		record.DisplayName == "" || len(record.DisplayName) > 255 ||
		record.MediaType == "" || len(record.MediaType) > 255 ||
		(record.Version == 1 && record.OwnerUserID != "") ||
		(record.Version == 2 && !validLocalFileOwnerUserID(record.OwnerUserID)) ||
		!localFileHashPattern.MatchString(record.SHA256) ||
		(record.State != "bound" && record.State != "draft" && record.State != "registered" && record.State != "revoked") {
		return localFileIndexRecord{}, errLocalFileCorrupt
	}
	return record, nil
}

func validLocalFileOwnerUserID(value string) bool {
	return value != "" && len(value) <= 160 && !strings.ContainsAny(value, "\x00\r\n")
}

func localFileModePrivate(mode os.FileMode) bool {
	return runtime.GOOS == "windows" || mode.Perm()&0o077 == 0
}

func hashLocalFile(file *os.File, expectedSize int64) (string, error) {
	hash := sha256.New()
	n, err := io.CopyN(hash, file, expectedSize)
	if err != nil || n != expectedSize {
		return "", errLocalFileCorrupt
	}
	var extra [1]byte
	if n, err := file.Read(extra[:]); n != 0 || (err != nil && err != io.EOF) {
		return "", errLocalFileCorrupt
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func exactInt64Param(value any) int64 {
	switch number := value.(type) {
	case int:
		return int64(number)
	case int64:
		return number
	case float64:
		if number == float64(int64(number)) {
			return int64(number)
		}
	case json.Number:
		parsed, _ := number.Int64()
		return parsed
	}
	return 0
}
