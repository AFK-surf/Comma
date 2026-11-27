package erofsbundle

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestPackInspectAndUnpackRoundTrip(t *testing.T) {
	dir := t.TempDir()
	erofsBytes := makeSyntheticErofs(8192)
	erofsPath := filepath.Join(dir, "rootfs.erofs")
	if err := os.WriteFile(erofsPath, erofsBytes, 0o644); err != nil {
		t.Fatal(err)
	}

	meta := FlattenMeta{
		ManifestDigest: "sha256:" + strings.Repeat("a", 64),
		Platform:       "linux/arm64",
		LogicalBytes:   123456,
		Defaults: ContainerDefaults{
			Entrypoint: []string{"/usr/local/bin/comma-shell-runtime"},
			Env:        []string{"PATH=/usr/local/bin:/usr/bin:/bin"},
			WorkingDir: "/workspace",
			User:       "10001:10001",
		},
	}
	metaPath := filepath.Join(dir, "meta.json")
	writeJSON(t, metaPath, meta)

	// Always test compression="none" (pure Go, no external binary required).
	noneArchive := filepath.Join(dir, "shell-none.erofs")
	hdr, err := Pack(metaPath, erofsPath, "", CompressionNone, noneArchive)
	if err != nil {
		t.Fatalf("Pack(none): %v", err)
	}
	if hdr.SchemaVersion != 1 || hdr.ErofsBytes != 8192 || hdr.Compression != CompressionNone {
		t.Fatalf("unexpected header: %#v", hdr)
	}
	if !reflect.DeepEqual(hdr.Defaults, meta.Defaults) {
		t.Fatalf("defaults = %#v, want %#v", hdr.Defaults, meta.Defaults)
	}

	inspected, err := InspectFile(noneArchive, true)
	if err != nil {
		t.Fatalf("InspectFile(none): %v", err)
	}
	if !reflect.DeepEqual(inspected.Header, hdr) {
		t.Fatalf("inspected header = %#v, want %#v", inspected.Header, hdr)
	}

	unpackedNone := filepath.Join(dir, "unpacked-none.erofs")
	if _, err := Unpack(noneArchive, unpackedNone); err != nil {
		t.Fatalf("Unpack(none): %v", err)
	}
	gotNone, err := os.ReadFile(unpackedNone)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(gotNone, erofsBytes) {
		t.Fatal("unpacked none erofs bytes differ")
	}

	// Verify exact binary layout: 16B magic + 4B BE headerLen + JSON + payload.
	rawArchive, err := os.ReadFile(noneArchive)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(rawArchive[:16], Magic) {
		t.Fatalf("magic = %q", rawArchive[:16])
	}
	hLen := binary.BigEndian.Uint32(rawArchive[16:20])
	if int(20+hLen)+len(erofsBytes) != len(rawArchive) {
		t.Fatalf("unexpected archive framing length")
	}

	// Also test compression="zstd" when zstd is available in PATH.
	if _, err := exec.LookPath("zstd"); err == nil {
		zstdPath := filepath.Join(dir, "rootfs.erofs.zst")
		cmd := exec.Command("zstd", "-q", "-3", "-f", erofsPath, "-o", zstdPath)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("zstd compress: %v (%s)", err, out)
		}
		zstdArchive := filepath.Join(dir, "shell.erofs.zst")
		zhdr, err := Pack(metaPath, erofsPath, zstdPath, CompressionZstd, zstdArchive)
		if err != nil {
			t.Fatalf("Pack(zstd): %v", err)
		}
		if zhdr.Compression != CompressionZstd {
			t.Fatalf("compression = %q", zhdr.Compression)
		}
		if _, err := InspectFile(zstdArchive, true); err != nil {
			t.Fatalf("InspectFile(zstd): %v", err)
		}
		unpackedZstd := filepath.Join(dir, "unpacked-zstd.erofs")
		if _, err := Unpack(zstdArchive, unpackedZstd); err != nil {
			t.Fatalf("Unpack(zstd): %v", err)
		}
		gotZstd, err := os.ReadFile(unpackedZstd)
		if err != nil {
			t.Fatal(err)
		}
		if !bytes.Equal(gotZstd, erofsBytes) {
			t.Fatal("unpacked zstd erofs bytes differ")
		}
	}
}

func TestUnpackRejectsCorruptedPayload(t *testing.T) {
	dir := t.TempDir()
	erofsBytes := makeSyntheticErofs(4096)
	erofsPath := filepath.Join(dir, "rootfs.erofs")
	if err := os.WriteFile(erofsPath, erofsBytes, 0o644); err != nil {
		t.Fatal(err)
	}
	metaPath := filepath.Join(dir, "meta.json")
	writeJSON(t, metaPath, FlattenMeta{
		ManifestDigest: "sha256:" + strings.Repeat("b", 64),
		Platform:       "linux/arm64",
		LogicalBytes:   512,
	})
	archivePath := filepath.Join(dir, "shell.erofs")
	if _, err := Pack(metaPath, erofsPath, "", CompressionNone, archivePath); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	raw[len(raw)-1] ^= 0xff
	if err := os.WriteFile(archivePath, raw, 0o644); err != nil {
		t.Fatal(err)
	}
	if _, err := Unpack(archivePath, filepath.Join(dir, "out.erofs")); err == nil || !strings.Contains(err.Error(), "sha256") {
		t.Fatalf("expected sha256 mismatch, got %v", err)
	}
}

func TestFlattenOCIWhiteoutsHardlinksAndDeterminism(t *testing.T) {
	dir := t.TempDir()
	layer0 := buildLayerTar(t, []tarEntry{
		{name: "etc/", typeflag: tar.TypeDir, mode: 0o755},
		{name: "etc/keep.txt", body: "keep-v1", mode: 0o644},
		{name: "etc/delete.txt", body: "delete-me", mode: 0o644},
		{name: "opt/", typeflag: tar.TypeDir, mode: 0o755},
		{name: "opt/old.txt", body: "old-opaque", mode: 0o644},
		{name: "usr/bin/target", body: "shared-binary", mode: 0o755},
		{name: "a-link", typeflag: tar.TypeLink, linkname: "usr/bin/target"},
	})
	layer1 := buildLayerTar(t, []tarEntry{
		{name: "etc/.wh.delete.txt", body: "", mode: 0o644},
		{name: "etc/keep.txt", body: "keep-v2", mode: 0o644},
		{name: "opt/.wh..wh..opq", body: "", mode: 0o644},
		{name: "opt/new.txt", body: "fresh", mode: 0o644},
	})

	ociPath := filepath.Join(dir, "test.oci.tar")
	wantDefaults := ContainerDefaults{
		Entrypoint: []string{"/usr/local/bin/comma-shell-runtime"},
		Env:        []string{"HOME=/workspace"},
		WorkingDir: "/workspace",
		User:       "10001:10001",
	}
	writeTestOCI(t, ociPath, [][]byte{layer0, layer1}, wantDefaults)

	var firstBuf, secondBuf bytes.Buffer
	meta1, err := FlattenOCI(ociPath, &firstBuf)
	if err != nil {
		t.Fatalf("FlattenOCI(1): %v", err)
	}
	meta2, err := FlattenOCI(ociPath, &secondBuf)
	if err != nil {
		t.Fatalf("FlattenOCI(2): %v", err)
	}
	if !bytes.Equal(firstBuf.Bytes(), secondBuf.Bytes()) {
		t.Fatal("FlattenOCI output is not byte-for-byte deterministic")
	}
	if !reflect.DeepEqual(meta1, meta2) {
		t.Fatalf("meta differs: %#v vs %#v", meta1, meta2)
	}
	if !reflect.DeepEqual(meta1.Defaults, wantDefaults) {
		t.Fatalf("defaults = %#v, want %#v", meta1.Defaults, wantDefaults)
	}

	got := readMergedTar(t, firstBuf.Bytes())
	if got["etc/keep.txt"].body != "keep-v2" {
		t.Fatalf("etc/keep.txt = %#v", got["etc/keep.txt"])
	}
	if _, exists := got["etc/delete.txt"]; exists {
		t.Fatal("etc/delete.txt should have been removed by whiteout")
	}
	if _, exists := got["opt/old.txt"]; exists {
		t.Fatal("opt/old.txt should have been removed by opaque whiteout")
	}
	if got["opt/new.txt"].body != "fresh" {
		t.Fatalf("opt/new.txt = %#v", got["opt/new.txt"])
	}
	// Sorted order puts "a-link" before "usr/bin/target", so a-link is emitted as TypeReg
	// and usr/bin/target becomes a hardlink to a-link.
	if got["a-link"].typeflag != tar.TypeReg || got["a-link"].body != "shared-binary" {
		t.Fatalf("a-link = %#v", got["a-link"])
	}
	if got["usr/bin/target"].typeflag != tar.TypeLink || got["usr/bin/target"].linkname != "a-link" {
		t.Fatalf("usr/bin/target = %#v", got["usr/bin/target"])
	}
}

func makeSyntheticErofs(size int) []byte {
	buf := make([]byte, size)
	copy(buf[ErofsMagicOff:ErofsMagicOff+4], ErofsSuperMagic[:])
	return buf
}

func writeJSON(t *testing.T, path string, value any) {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

type tarEntry struct {
	name     string
	typeflag byte
	linkname string
	body     string
	mode     int64
}

func buildLayerTar(t *testing.T, entries []tarEntry) []byte {
	t.Helper()
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	for _, e := range entries {
		tf := e.typeflag
		if tf == 0 {
			tf = tar.TypeReg
		}
		hdr := &tar.Header{
			Name:     e.name,
			Typeflag: tf,
			Linkname: e.linkname,
			Mode:     e.mode,
		}
		if tf == tar.TypeReg {
			hdr.Size = int64(len(e.body))
		}
		if err := tw.WriteHeader(hdr); err != nil {
			t.Fatal(err)
		}
		if tf == tar.TypeReg && len(e.body) > 0 {
			if _, err := tw.Write([]byte(e.body)); err != nil {
				t.Fatal(err)
			}
		}
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func writeTestOCI(t *testing.T, path string, uncompressedLayers [][]byte, defaults ContainerDefaults) {
	t.Helper()
	blobs := map[string][]byte{}
	var diffIDs []string
	var layerDescs []ociDescriptor

	for _, raw := range uncompressedLayers {
		rawSum := sha256.Sum256(raw)
		diffIDs = append(diffIDs, "sha256:"+hex.EncodeToString(rawSum[:]))

		var gzBuf bytes.Buffer
		gw := gzip.NewWriter(&gzBuf)
		if _, err := gw.Write(raw); err != nil {
			t.Fatal(err)
		}
		if err := gw.Close(); err != nil {
			t.Fatal(err)
		}
		gzBytes := gzBuf.Bytes()
		gzSum := sha256.Sum256(gzBytes)
		gzDigest := "sha256:" + hex.EncodeToString(gzSum[:])
		blobs[gzDigest] = gzBytes
		layerDescs = append(layerDescs, ociDescriptor{
			MediaType: "application/vnd.oci.image.layer.v1.tar+gzip",
			Digest:    gzDigest,
			Size:      int64(len(gzBytes)),
		})
	}

	var cfg ociImageConfig
	cfg.Architecture = "arm64"
	cfg.OS = "linux"
	cfg.Config = defaults
	cfg.RootFS.Type = "layers"
	cfg.RootFS.DiffIDs = diffIDs
	cfgBytes, err := json.Marshal(cfg)
	if err != nil {
		t.Fatal(err)
	}
	cfgSum := sha256.Sum256(cfgBytes)
	cfgDigest := "sha256:" + hex.EncodeToString(cfgSum[:])
	blobs[cfgDigest] = cfgBytes

	manifest := ociImageManifest{
		SchemaVersion: 2,
		MediaType:     mediaTypeImageManifest,
		Config: ociDescriptor{
			MediaType: "application/vnd.oci.image.config.v1+json",
			Digest:    cfgDigest,
			Size:      int64(len(cfgBytes)),
		},
		Layers: layerDescs,
	}
	manifestBytes, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	manifestSum := sha256.Sum256(manifestBytes)
	manifestDigest := "sha256:" + hex.EncodeToString(manifestSum[:])
	blobs[manifestDigest] = manifestBytes

	idx := ociIndex{
		SchemaVersion: 2,
		MediaType:     mediaTypeImageIndex,
		Manifests: []ociDescriptor{{
			MediaType: mediaTypeImageManifest,
			Digest:    manifestDigest,
			Size:      int64(len(manifestBytes)),
			Platform:  &ociPlatform{OS: "linux", Architecture: "arm64"},
		}},
	}
	idxBytes, err := json.Marshal(idx)
	if err != nil {
		t.Fatal(err)
	}

	var out bytes.Buffer
	tw := tar.NewWriter(&out)
	writeSimpleTar := func(name string, data []byte) {
		if err := tw.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data))}); err != nil {
			t.Fatal(err)
		}
		if _, err := tw.Write(data); err != nil {
			t.Fatal(err)
		}
	}
	writeSimpleTar("oci-layout", []byte(`{"imageLayoutVersion":"1.0.0"}`))
	writeSimpleTar("index.json", idxBytes)
	for d, b := range blobs {
		writeSimpleTar("blobs/sha256/"+strings.TrimPrefix(d, "sha256:"), b)
	}
	if err := tw.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, out.Bytes(), 0o644); err != nil {
		t.Fatal(err)
	}
}

type readEntry struct {
	typeflag byte
	linkname string
	body     string
}

func readMergedTar(t *testing.T, data []byte) map[string]readEntry {
	t.Helper()
	res := map[string]readEntry{}
	tr := tar.NewReader(bytes.NewReader(data))
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		var body []byte
		if hdr.Typeflag == tar.TypeReg {
			body, err = io.ReadAll(tr)
			if err != nil {
				t.Fatal(err)
			}
		}
		res[strings.TrimSuffix(hdr.Name, "/")] = readEntry{
			typeflag: hdr.Typeflag,
			linkname: hdr.Linkname,
			body:     string(body),
		}
	}
	return res
}
