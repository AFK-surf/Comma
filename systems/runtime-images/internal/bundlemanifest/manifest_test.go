package bundlemanifest

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimeinputs"
	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimereuse"
)

func TestGenerateValidBundle(t *testing.T) {
	dir := t.TempDir()
	archives := map[string]string{}
	inputDigests := map[string]string{}
	for index, class := range requiredClasses {
		path := filepath.Join(dir, class+".oci.tar")
		inputDigests[class] = "sha256:" + strings.Repeat(string(rune('a'+index)), 64)
		writeOCIArchive(t, path, class, inputDigests[class], "linux", "arm64", true)
		archives[class] = path
	}

	manifest, err := Generate("release-7", inputDigests, archives)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if manifest.SchemaVersion != 3 || manifest.SourceRevision != "release-7" {
		t.Fatalf("manifest = %#v", manifest)
	}
	if len(manifest.Images) != 3 {
		t.Fatalf("images = %d, want 3", len(manifest.Images))
	}
	for index, image := range manifest.Images {
		if image.Class != requiredClasses[index] {
			t.Fatalf("image[%d].class = %q", index, image.Class)
		}
		if image.Reference != "comma.local/runtime/"+image.Class+"@"+image.ManifestDigest {
			t.Fatalf("reference = %q", image.Reference)
		}
		if image.InputDigest != inputDigests[image.Class] {
			t.Fatalf("image identity = %#v", image)
		}
		if image.Platform != "linux/arm64" || image.ArchiveSize == 0 || len(image.ArchiveSHA256) != 64 {
			t.Fatalf("image metadata = %#v", image)
		}
	}
}

func TestApprovedReusePreservesAllArtifactIdentitiesAcrossSourceRevisions(t *testing.T) {
	approvedDir := t.TempDir()
	outputDir := t.TempDir()
	archives := map[string]string{}
	inputDigests := map[string]string{}
	inputs := runtimeinputs.Manifest{SchemaVersion: 1}
	for index, class := range requiredClasses {
		path := filepath.Join(approvedDir, class+".oci.tar")
		inputDigest := "sha256:" + strings.Repeat(string(rune('a'+index)), 64)
		writeOCIArchive(t, path, class, inputDigest, "linux", "arm64", true)
		archives[class] = path
		inputDigests[class] = inputDigest
		inputs.Images = append(inputs.Images, runtimeinputs.Image{Class: class, InputDigest: inputDigest})
	}

	approved, err := Generate("main-source-a", inputDigests, archives)
	if err != nil {
		t.Fatalf("generate approved bundle: %v", err)
	}
	if err := Write(filepath.Join(approvedDir, "manifest.json"), approved); err != nil {
		t.Fatalf("write approved manifest: %v", err)
	}

	reused, err := runtimereuse.Copy(inputs, approvedDir, outputDir)
	if err != nil {
		t.Fatalf("reuse approved bundle: %v", err)
	}
	if !reflect.DeepEqual(reused, requiredClasses) {
		t.Fatalf("reused classes = %v, want %v", reused, requiredClasses)
	}

	reusedArchives := map[string]string{}
	for _, class := range requiredClasses {
		reusedArchives[class] = filepath.Join(outputDir, class+".oci.tar")
	}
	regenerated, err := Generate("main-source-b", inputDigests, reusedArchives)
	if err != nil {
		t.Fatalf("generate reused bundle: %v", err)
	}
	if approved.SourceRevision == regenerated.SourceRevision {
		t.Fatalf("source revisions unexpectedly match: %q", approved.SourceRevision)
	}
	if !reflect.DeepEqual(approved.Images, regenerated.Images) {
		t.Fatalf("artifact identities changed across approved reuse:\napproved=%#v\nregenerated=%#v", approved.Images, regenerated.Images)
	}
}

func TestGenerateRejectsInvalidInput(t *testing.T) {
	for _, test := range []struct {
		name     string
		generate func(*testing.T) error
		want     string
	}{
		{"wrong platform", func(t *testing.T) error {
			return generateWithArchives(t, "release-7", func(path string) {
				writeOCIArchive(t, path, "shell", testInputDigest(), "linux", "amd64", true)
			})
		}, "platform must be linux/arm64"},
		{"missing layout", func(t *testing.T) error {
			return generateWithArchives(t, "release-7", func(path string) {
				writeOCIArchive(t, path, "shell", testInputDigest(), "linux", "arm64", false)
			})
		}, "missing oci-layout"},
		{"missing classes", func(*testing.T) error {
			_, err := Generate("release-7", map[string]string{"shell": testInputDigest()}, map[string]string{"shell": "unused"})
			return err
		}, "expected input digests and archives"},
		{"empty source revision", func(*testing.T) error {
			_, err := Generate("", nil, nil)
			return err
		}, "source revision is required"},
	} {
		t.Run(test.name, func(t *testing.T) {
			if err := test.generate(t); err == nil || !strings.Contains(err.Error(), test.want) {
				t.Fatalf("error = %v, want %q", err, test.want)
			}
		})
	}
}

func generateWithArchives(t *testing.T, revision string, write func(string)) error {
	t.Helper()
	dir := t.TempDir()
	archives := map[string]string{}
	inputDigests := map[string]string{}
	for _, class := range requiredClasses {
		path := filepath.Join(dir, class+".oci.tar")
		write(path)
		archives[class] = path
		inputDigests[class] = testInputDigest()
	}
	_, err := Generate(revision, inputDigests, archives)
	return err
}

func TestInputDigestIsOnlyAReuseSelectorAndDoesNotChangeArtifactIdentity(t *testing.T) {
	dir := t.TempDir()
	firstDigest := "sha256:" + strings.Repeat("1", 64)
	secondDigest := "sha256:" + strings.Repeat("2", 64)
	firstPath := filepath.Join(dir, "first.oci.tar")
	secondPath := filepath.Join(dir, "second.oci.tar")
	writeOCIArchive(t, firstPath, "shell", firstDigest, "linux", "arm64", true)
	writeOCIArchive(t, secondPath, "shell", secondDigest, "linux", "arm64", true)

	first, err := inspectArchive("shell", firstDigest, firstPath)
	if err != nil {
		t.Fatalf("inspect first archive: %v", err)
	}
	second, err := inspectArchive("shell", secondDigest, secondPath)
	if err != nil {
		t.Fatalf("inspect second archive: %v", err)
	}
	if first.ManifestDigest != second.ManifestDigest || first.Reference != second.Reference {
		t.Fatalf("selector changed OCI identity: first=%#v second=%#v", first, second)
	}
}

func writeOCIArchive(t *testing.T, path, class, inputDigest, osName, architecture string, includeLayout bool) {
	t.Helper()
	config := imageConfig{Architecture: architecture, OS: osName}
	configBytes := mustJSON(t, config)
	configDigest := digest(configBytes)

	manifestBytes := mustJSON(t, imageManifest{
		SchemaVersion: 2,
		MediaType:     mediaTypeImageManifest,
		Config: descriptor{
			MediaType: "application/vnd.oci.image.config.v1+json",
			Digest:    configDigest,
		},
	})
	manifestDigest := digest(manifestBytes)
	indexBytes := mustJSON(t, index{
		SchemaVersion: 2,
		MediaType:     mediaTypeImageIndex,
		Manifests: []descriptor{{
			MediaType: mediaTypeImageManifest,
			Digest:    manifestDigest,
			Platform:  &platform{OS: osName, Architecture: architecture},
		}},
	})

	var buffer bytes.Buffer
	w := tar.NewWriter(&buffer)
	if includeLayout {
		writeTarFile(t, w, "oci-layout", []byte(`{"imageLayoutVersion":"1.0.0"}`))
	}
	writeTarFile(t, w, "index.json", indexBytes)
	writeTarFile(t, w, blobPath(configDigest), configBytes)
	writeTarFile(t, w, blobPath(manifestDigest), manifestBytes)
	if err := w.Close(); err != nil {
		t.Fatalf("close tar: %v", err)
	}
	if err := os.WriteFile(path, buffer.Bytes(), 0o644); err != nil {
		t.Fatalf("write archive: %v", err)
	}
}

func testInputDigest() string {
	return "sha256:" + strings.Repeat("a", 64)
}

func writeTarFile(t *testing.T, w *tar.Writer, name string, data []byte) {
	t.Helper()
	if err := w.WriteHeader(&tar.Header{Name: name, Mode: 0o644, Size: int64(len(data))}); err != nil {
		t.Fatalf("write header: %v", err)
	}
	if _, err := w.Write(data); err != nil {
		t.Fatalf("write body: %v", err)
	}
}

func mustJSON(t *testing.T, value any) []byte {
	t.Helper()
	data, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	return data
}

func digest(data []byte) string {
	sum := sha256.Sum256(data)
	return "sha256:" + hex.EncodeToString(sum[:])
}

func blobPath(value string) string {
	return "blobs/sha256/" + strings.TrimPrefix(value, "sha256:")
}
