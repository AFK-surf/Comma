package bundlemanifest

import (
	"bytes"
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/AFK-surf/comma/systems/runtime-images/internal/erofsbundle"
	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimeinputs"
	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimereuse"
)

func TestGenerateValidBundle(t *testing.T) {
	dir := t.TempDir()
	archives := map[string]string{}
	inputDigests := map[string]string{}
	for index, class := range requiredClasses {
		path := filepath.Join(dir, class+".erofs.zst")
		inputDigests[class] = "sha256:" + strings.Repeat(string(rune('a'+index)), 64)
		writeErofsArchive(t, path, "sha256:"+strings.Repeat(string(rune('c'+index)), 64), "linux/arm64", true)
		archives[class] = path
	}

	manifest, err := Generate("release-7", inputDigests, archives)
	if err != nil {
		t.Fatalf("Generate: %v", err)
	}
	if manifest.SchemaVersion != 4 || manifest.SourceRevision != "release-7" {
		t.Fatalf("manifest = %#v", manifest)
	}
	if len(manifest.Images) != len(requiredClasses) {
		t.Fatalf("images = %d, want %d", len(manifest.Images), len(requiredClasses))
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
		path := filepath.Join(approvedDir, class+".erofs.zst")
		inputDigest := "sha256:" + strings.Repeat(string(rune('a'+index)), 64)
		writeErofsArchive(t, path, "sha256:"+strings.Repeat(string(rune('c'+index)), 64), "linux/arm64", true)
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
		reusedArchives[class] = filepath.Join(outputDir, class+".erofs.zst")
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
				writeErofsArchive(t, path, "sha256:"+strings.Repeat("c", 64), "linux/amd64", true)
			})
		}, "platform must be linux/arm64"},
		{"invalid magic", func(t *testing.T) error {
			return generateWithArchives(t, "release-7", func(path string) {
				writeErofsArchive(t, path, "sha256:"+strings.Repeat("c", 64), "linux/arm64", false)
			})
		}, "invalid COMMA_EROFS_V1 magic"},
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
		path := filepath.Join(dir, class+".erofs.zst")
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
	manifestDigest := "sha256:" + strings.Repeat("c", 64)
	firstPath := filepath.Join(dir, "first.erofs.zst")
	secondPath := filepath.Join(dir, "second.erofs.zst")
	writeErofsArchive(t, firstPath, manifestDigest, "linux/arm64", true)
	writeErofsArchive(t, secondPath, manifestDigest, "linux/arm64", true)

	first, err := inspectArchive("shell", firstDigest, firstPath)
	if err != nil {
		t.Fatalf("inspect first archive: %v", err)
	}
	second, err := inspectArchive("shell", secondDigest, secondPath)
	if err != nil {
		t.Fatalf("inspect second archive: %v", err)
	}
	if first.ManifestDigest != second.ManifestDigest || first.Reference != second.Reference {
		t.Fatalf("selector changed archive identity: first=%#v second=%#v", first, second)
	}
}

func writeErofsArchive(t *testing.T, path, manifestDigest, platform string, validMagic bool) {
	t.Helper()
	raw := make([]byte, 4096)
	copy(raw[erofsbundle.ErofsMagicOff:erofsbundle.ErofsMagicOff+4], erofsbundle.ErofsSuperMagic[:])
	sum := sha256.Sum256(raw)

	header := erofsbundle.Header{
		SchemaVersion:  1,
		ManifestDigest: manifestDigest,
		Platform:       platform,
		LogicalBytes:   1024,
		ErofsBytes:     int64(len(raw)),
		ErofsSHA256:    hex.EncodeToString(sum[:]),
		Compression:    erofsbundle.CompressionNone,
	}
	headerJSON, err := json.Marshal(header)
	if err != nil {
		t.Fatal(err)
	}

	var buf bytes.Buffer
	if validMagic {
		buf.Write(erofsbundle.Magic)
	} else {
		buf.WriteString("NOT_COMMA_EROFS!")
	}
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], uint32(len(headerJSON)))
	buf.Write(lenBuf[:])
	buf.Write(headerJSON)
	buf.Write(raw)

	if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
		t.Fatalf("write archive: %v", err)
	}
}

func testInputDigest() string {
	return "sha256:" + strings.Repeat("a", 64)
}
