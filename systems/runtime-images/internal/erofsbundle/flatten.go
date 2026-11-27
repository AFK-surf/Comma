package erofsbundle

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	mediaTypeImageIndex    = "application/vnd.oci.image.index.v1+json"
	mediaTypeImageManifest = "application/vnd.oci.image.manifest.v1+json"
)

type ociDescriptor struct {
	MediaType   string            `json:"mediaType"`
	Digest      string            `json:"digest"`
	Size        int64             `json:"size"`
	Platform    *ociPlatform      `json:"platform,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

type ociPlatform struct {
	Architecture string `json:"architecture"`
	OS           string `json:"os"`
}

type ociIndex struct {
	SchemaVersion int             `json:"schemaVersion"`
	MediaType     string          `json:"mediaType"`
	Manifests     []ociDescriptor `json:"manifests"`
}

type ociImageManifest struct {
	SchemaVersion int             `json:"schemaVersion"`
	MediaType     string          `json:"mediaType"`
	Config        ociDescriptor   `json:"config"`
	Layers        []ociDescriptor `json:"layers"`
}

type ociImageConfig struct {
	Architecture string            `json:"architecture"`
	OS           string            `json:"os"`
	Config       ContainerDefaults `json:"config"`
	RootFS       struct {
		Type    string   `json:"type"`
		DiffIDs []string `json:"diff_ids"`
	} `json:"rootfs"`
}

type blobRecord struct {
	path string
	size int64
}

type mergedEntry struct {
	header     tar.Header
	fromLayer  int
	layerIdx   int
	dataOffset int64
	inodeID    int64
}

// FlattenOCI strictly validates an OCI archive (.oci.tar), merges its overlay layers
// (honoring OCI whiteouts) into a deterministic tar stream written to tarOut, and returns
// the extracted metadata (manifestDigest, platform, logicalBytes, defaults).
func FlattenOCI(ociPath string, tarOut io.Writer) (FlattenMeta, error) {
	tmpDir, err := os.MkdirTemp("", "comma-flatten-oci-*")
	if err != nil {
		return FlattenMeta{}, err
	}
	defer os.RemoveAll(tmpDir)

	blobsDir := filepath.Join(tmpDir, "blobs")
	if err := os.MkdirAll(blobsDir, 0o700); err != nil {
		return FlattenMeta{}, err
	}

	metaFiles := make(map[string][]byte)
	blobs := make(map[string]blobRecord)

	ociFile, err := os.Open(ociPath)
	if err != nil {
		return FlattenMeta{}, fmt.Errorf("open OCI archive: %w", err)
	}
	defer ociFile.Close()

	tr := tar.NewReader(ociFile)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return FlattenMeta{}, fmt.Errorf("read OCI archive: %w", err)
		}
		if hdr.Typeflag != tar.TypeReg && hdr.Typeflag != tar.TypeRegA {
			continue
		}
		name := strings.TrimPrefix(filepath.ToSlash(hdr.Name), "./")
		if strings.HasPrefix(name, "blobs/sha256/") {
			hexDigest := strings.TrimPrefix(name, "blobs/sha256/")
			if !ValidLowerHex64(hexDigest) {
				return FlattenMeta{}, fmt.Errorf("invalid OCI blob path %q", name)
			}
			dest := filepath.Join(blobsDir, hexDigest)
			size, err := copyAndVerifyBlob(tr, dest, hexDigest)
			if err != nil {
				return FlattenMeta{}, fmt.Errorf("extract blob %s: %w", name, err)
			}
			blobs["sha256:"+hexDigest] = blobRecord{path: dest, size: size}
			continue
		}
		if name == "oci-layout" || name == "index.json" {
			data, err := io.ReadAll(io.LimitReader(tr, 16*1024*1024))
			if err != nil {
				return FlattenMeta{}, fmt.Errorf("read %s: %w", name, err)
			}
			metaFiles[name] = data
		}
	}

	var layout struct {
		ImageLayoutVersion string `json:"imageLayoutVersion"`
	}
	if err := decodeJSONFile(metaFiles, "oci-layout", &layout); err != nil {
		return FlattenMeta{}, err
	}
	if layout.ImageLayoutVersion != "1.0.0" {
		return FlattenMeta{}, fmt.Errorf("unsupported OCI layout version %q", layout.ImageLayoutVersion)
	}

	var root ociIndex
	if err := decodeJSONFile(metaFiles, "index.json", &root); err != nil {
		return FlattenMeta{}, err
	}
	if root.SchemaVersion != 2 || len(root.Manifests) != 1 {
		return FlattenMeta{}, fmt.Errorf("OCI index must contain exactly one manifest, got %d", len(root.Manifests))
	}

	desc := root.Manifests[0]
	if desc.MediaType == mediaTypeImageIndex {
		return FlattenMeta{}, errors.New("nested OCI indexes are not accepted")
	}
	if desc.MediaType != mediaTypeImageManifest {
		return FlattenMeta{}, fmt.Errorf("unsupported manifest media type %q", desc.MediaType)
	}
	if desc.Platform == nil || desc.Platform.OS != "linux" || desc.Platform.Architecture != "arm64" {
		return FlattenMeta{}, fmt.Errorf("image platform must be linux/arm64, got %#v", desc.Platform)
	}

	manifestBlob, ok := blobs[desc.Digest]
	if !ok {
		return FlattenMeta{}, fmt.Errorf("missing manifest blob %s", desc.Digest)
	}
	manifestBytes, err := os.ReadFile(manifestBlob.path)
	if err != nil {
		return FlattenMeta{}, fmt.Errorf("read manifest blob: %w", err)
	}
	var manifest ociImageManifest
	if err := json.Unmarshal(manifestBytes, &manifest); err != nil {
		return FlattenMeta{}, fmt.Errorf("decode image manifest: %w", err)
	}
	if manifest.SchemaVersion != 2 || manifest.MediaType != mediaTypeImageManifest {
		return FlattenMeta{}, errors.New("invalid OCI image manifest")
	}

	configBlob, ok := blobs[manifest.Config.Digest]
	if !ok {
		return FlattenMeta{}, fmt.Errorf("missing config blob %s", manifest.Config.Digest)
	}
	configBytes, err := os.ReadFile(configBlob.path)
	if err != nil {
		return FlattenMeta{}, fmt.Errorf("read config blob: %w", err)
	}
	var config ociImageConfig
	if err := json.Unmarshal(configBytes, &config); err != nil {
		return FlattenMeta{}, fmt.Errorf("decode image config: %w", err)
	}
	if config.OS != "linux" || config.Architecture != "arm64" {
		return FlattenMeta{}, fmt.Errorf("config platform must be linux/arm64, got %s/%s", config.OS, config.Architecture)
	}
	if config.RootFS.Type != "layers" {
		return FlattenMeta{}, fmt.Errorf("unsupported rootfs type %q", config.RootFS.Type)
	}
	if len(config.RootFS.DiffIDs) != len(manifest.Layers) {
		return FlattenMeta{}, fmt.Errorf("rootfs diff_ids count %d != layers count %d", len(config.RootFS.DiffIDs), len(manifest.Layers))
	}

	logicalBytes := manifestBlob.size + configBlob.size
	layerFiles := make([]*os.File, len(manifest.Layers))
	defer func() {
		for _, lf := range layerFiles {
			if lf != nil {
				_ = lf.Close()
			}
		}
	}()

	entries := make(map[string]*mergedEntry)
	var nextInode int64 = 1

	for i, layerDesc := range manifest.Layers {
		layerBlob, ok := blobs[layerDesc.Digest]
		if !ok {
			return FlattenMeta{}, fmt.Errorf("missing layer blob %s", layerDesc.Digest)
		}
		if layerDesc.Size > 0 && layerBlob.size != layerDesc.Size {
			return FlattenMeta{}, fmt.Errorf("layer %d size = %d, want %d", i, layerBlob.size, layerDesc.Size)
		}
		logicalBytes += layerBlob.size

		layerTarPath := filepath.Join(tmpDir, fmt.Sprintf("layer-%04d.tar", i))
		if err := decompressAndVerifyLayer(layerBlob.path, layerDesc.MediaType, config.RootFS.DiffIDs[i], layerTarPath); err != nil {
			return FlattenMeta{}, fmt.Errorf("layer %d (%s): %w", i, layerDesc.Digest, err)
		}
		lf, err := os.Open(layerTarPath)
		if err != nil {
			return FlattenMeta{}, err
		}
		layerFiles[i] = lf

		if err := applyLayer(lf, i, entries, &nextInode); err != nil {
			return FlattenMeta{}, fmt.Errorf("apply layer %d: %w", i, err)
		}
	}

	if err := writeMergedTar(tarOut, entries, layerFiles); err != nil {
		return FlattenMeta{}, fmt.Errorf("write merged tar: %w", err)
	}

	return FlattenMeta{
		ManifestDigest: desc.Digest,
		Platform:       "linux/arm64",
		LogicalBytes:   logicalBytes,
		Defaults:       config.Config,
	}, nil
}

func copyAndVerifyBlob(r io.Reader, destPath, wantHex string) (int64, error) {
	out, err := os.OpenFile(destPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return 0, err
	}
	hash := sha256.New()
	n, copyErr := io.Copy(io.MultiWriter(out, hash), r)
	closeErr := out.Close()
	if copyErr != nil {
		return 0, copyErr
	}
	if closeErr != nil {
		return 0, closeErr
	}
	gotHex := hex.EncodeToString(hash.Sum(nil))
	if gotHex != wantHex {
		return 0, fmt.Errorf("blob sha256 = %s, want %s", gotHex, wantHex)
	}
	return n, nil
}

func decodeJSONFile(files map[string][]byte, name string, target any) error {
	data, ok := files[name]
	if !ok {
		return fmt.Errorf("missing %s", name)
	}
	if err := json.Unmarshal(data, target); err != nil {
		return fmt.Errorf("decode %s: %w", name, err)
	}
	return nil
}

func decompressAndVerifyLayer(blobPath, mediaType, wantDiffID, destTarPath string) error {
	if !ValidDigest(wantDiffID) {
		return fmt.Errorf("invalid diff_id %q", wantDiffID)
	}
	src, err := os.Open(blobPath)
	if err != nil {
		return err
	}
	defer src.Close()

	dst, err := os.OpenFile(destTarPath, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}
	defer dst.Close()

	var reader io.Reader
	var gz *gzip.Reader
	var zstdCmd *exec.Cmd
	var zstdStderr bytes.Buffer

	switch {
	case strings.HasSuffix(mediaType, "+gzip") || strings.HasSuffix(mediaType, ".gzip"):
		gz, err = gzip.NewReader(src)
		if err != nil {
			return fmt.Errorf("open gzip layer: %w", err)
		}
		defer gz.Close()
		reader = gz
	case strings.HasSuffix(mediaType, "+zstd"):
		zstdCmd = exec.Command("zstd", "-d", "-q", "--stdout")
		zstdCmd.Stdin = src
		zstdCmd.Stderr = &zstdStderr
		stdout, pipeErr := zstdCmd.StdoutPipe()
		if pipeErr != nil {
			return pipeErr
		}
		if startErr := zstdCmd.Start(); startErr != nil {
			return fmt.Errorf("start zstd -d for layer: %w", startErr)
		}
		reader = stdout
	case strings.HasSuffix(mediaType, ".tar") || mediaType == "application/vnd.oci.image.layer.v1.tar":
		reader = src
	default:
		// Sniff gzip magic as a fallback for generic media types.
		var magic [2]byte
		n, _ := io.ReadFull(src, magic[:])
		if _, seekErr := src.Seek(0, io.SeekStart); seekErr != nil {
			return seekErr
		}
		if n == 2 && magic[0] == 0x1f && magic[1] == 0x8b {
			gz, err = gzip.NewReader(src)
			if err != nil {
				return fmt.Errorf("open gzip layer: %w", err)
			}
			defer gz.Close()
			reader = gz
		} else {
			reader = src
		}
	}

	hash := sha256.New()
	_, copyErr := io.Copy(io.MultiWriter(dst, hash), reader)
	if zstdCmd != nil {
		waitErr := zstdCmd.Wait()
		if copyErr != nil {
			return copyErr
		}
		if waitErr != nil {
			return fmt.Errorf("zstd layer decompress: %w (%s)", waitErr, strings.TrimSpace(zstdStderr.String()))
		}
	} else if copyErr != nil {
		return copyErr
	}
	if err := dst.Close(); err != nil {
		return err
	}

	gotDiffID := "sha256:" + hex.EncodeToString(hash.Sum(nil))
	if gotDiffID != wantDiffID {
		return fmt.Errorf("diff_id = %s, want %s", gotDiffID, wantDiffID)
	}
	return nil
}

type offsetReader struct {
	r io.Reader
	n int64
}

func (o *offsetReader) Read(p []byte) (int, error) {
	n, err := o.r.Read(p)
	o.n += int64(n)
	return n, err
}

func cleanTarPath(name string) string {
	cleaned := path.Clean("/" + filepath.ToSlash(name))
	cleaned = strings.TrimPrefix(cleaned, "/")
	if cleaned == "." {
		return ""
	}
	return cleaned
}

func applyLayer(lf *os.File, layerIdx int, entries map[string]*mergedEntry, nextInode *int64) error {
	if _, err := lf.Seek(0, io.SeekStart); err != nil {
		return err
	}
	or := &offsetReader{r: lf}
	tr := tar.NewReader(or)

	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("read layer tar: %w", err)
		}
		dataOffset := or.n

		clean := cleanTarPath(hdr.Name)
		if clean == "" {
			if _, err := io.Copy(io.Discard, tr); err != nil {
				return err
			}
			continue
		}

		dir, base := path.Split(clean)
		dir = strings.TrimSuffix(dir, "/")

		if base == ".wh..wh..opq" {
			prefix := ""
			if dir != "" {
				prefix = dir + "/"
			}
			for existingPath, existing := range entries {
				if existing.fromLayer < layerIdx && (prefix == "" || strings.HasPrefix(existingPath, prefix)) {
					delete(entries, existingPath)
				}
			}
			if _, err := io.Copy(io.Discard, tr); err != nil {
				return err
			}
			continue
		}

		if strings.HasPrefix(base, ".wh.") {
			targetName := strings.TrimPrefix(base, ".wh.")
			targetPath := targetName
			if dir != "" {
				targetPath = dir + "/" + targetName
			}
			targetPrefix := targetPath + "/"
			for existingPath, existing := range entries {
				if existing.fromLayer < layerIdx && (existingPath == targetPath || strings.HasPrefix(existingPath, targetPrefix)) {
					delete(entries, existingPath)
				}
			}
			if _, err := io.Copy(io.Discard, tr); err != nil {
				return err
			}
			continue
		}

		if _, err := io.Copy(io.Discard, tr); err != nil {
			return err
		}

		// If replacing an existing directory with a non-directory, remove old descendants.
		if prev, exists := entries[clean]; exists && prev.header.Typeflag == tar.TypeDir && hdr.Typeflag != tar.TypeDir {
			prefix := clean + "/"
			for existingPath := range entries {
				if strings.HasPrefix(existingPath, prefix) {
					delete(entries, existingPath)
				}
			}
		}

		normalized := normalizeHeader(*hdr, clean)
		entry := &mergedEntry{
			header:     normalized,
			fromLayer:  layerIdx,
			layerIdx:   layerIdx,
			dataOffset: dataOffset,
		}

		switch normalized.Typeflag {
		case tar.TypeReg, tar.TypeRegA:
			entry.header.Typeflag = tar.TypeReg
			entry.inodeID = *nextInode
			*nextInode++
		case tar.TypeLink:
			linkTarget := cleanTarPath(normalized.Linkname)
			entry.header.Linkname = linkTarget
			if target, ok := entries[linkTarget]; ok && (target.header.Typeflag == tar.TypeReg || target.header.Typeflag == tar.TypeLink) && target.inodeID != 0 {
				// Copy inode identity and file attributes so hardlink survives even if target is later deleted or sorted after this link.
				entry.layerIdx = target.layerIdx
				entry.dataOffset = target.dataOffset
				entry.inodeID = target.inodeID
				entry.header.Size = target.header.Size
				if entry.header.Mode == 0 {
					entry.header.Mode = target.header.Mode
				}
				if entry.header.Uid == 0 && target.header.Uid != 0 {
					entry.header.Uid = target.header.Uid
				}
				if entry.header.Gid == 0 && target.header.Gid != 0 {
					entry.header.Gid = target.header.Gid
				}
			}
		}

		entries[clean] = entry
	}
	return nil
}

func normalizeHeader(hdr tar.Header, cleanName string) tar.Header {
	out := tar.Header{
		Typeflag: hdr.Typeflag,
		Name:     cleanName,
		Linkname: hdr.Linkname,
		Size:     hdr.Size,
		Mode:     hdr.Mode,
		Uid:      hdr.Uid,
		Gid:      hdr.Gid,
		Uname:    hdr.Uname,
		Gname:    hdr.Gname,
		ModTime:  time.Unix(0, 0).UTC(),
		Devmajor: hdr.Devmajor,
		Devminor: hdr.Devminor,
		Format:   tar.FormatPAX,
	}
	if out.Typeflag == tar.TypeDir && !strings.HasSuffix(out.Name, "/") {
		out.Name += "/"
	}
	if len(hdr.PAXRecords) > 0 {
		kept := make(map[string]string)
		for k, v := range hdr.PAXRecords {
			if strings.HasPrefix(k, "SCHILY.xattr.") {
				kept[k] = v
			}
		}
		if len(kept) > 0 {
			out.PAXRecords = kept
		}
	}
	return out
}

func writeMergedTar(w io.Writer, entries map[string]*mergedEntry, layerFiles []*os.File) error {
	paths := make([]string, 0, len(entries))
	for p := range entries {
		paths = append(paths, p)
	}
	sort.Strings(paths)

	tw := tar.NewWriter(w)
	emittedInode := make(map[int64]string)

	for _, p := range paths {
		entry := entries[p]
		hdr := entry.header

		if entry.inodeID != 0 {
			if firstPath, already := emittedInode[entry.inodeID]; already {
				hdr.Typeflag = tar.TypeLink
				hdr.Linkname = firstPath
				hdr.Size = 0
				if err := tw.WriteHeader(&hdr); err != nil {
					return err
				}
				continue
			}
			emittedInode[entry.inodeID] = p
			hdr.Typeflag = tar.TypeReg
			hdr.Linkname = ""
			if err := tw.WriteHeader(&hdr); err != nil {
				return err
			}
			if hdr.Size > 0 {
				sr := io.NewSectionReader(layerFiles[entry.layerIdx], entry.dataOffset, hdr.Size)
				if _, err := io.CopyN(tw, sr, hdr.Size); err != nil {
					return err
				}
			}
			continue
		}

		// Non-regular entries (dirs, symlinks, fifos, devices, or unresolved links).
		if hdr.Typeflag != tar.TypeReg {
			hdr.Size = 0
		}
		if err := tw.WriteHeader(&hdr); err != nil {
			return err
		}
	}

	return tw.Close()
}
