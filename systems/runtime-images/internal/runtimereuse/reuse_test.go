package runtimereuse

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimeinputs"
)

func TestCopyReusesOnlyUnchangedApprovedInputs(t *testing.T) {
	approvedDir := t.TempDir()
	outputDir := t.TempDir()
	inputs := runtimeinputs.Manifest{SchemaVersion: 1}
	manifest := approvedManifest{SchemaVersion: 3}
	for index, class := range []string{"external", "meeting", "shell"} {
		inputDigest := digest(strings.Repeat(string(rune('a'+index)), 3))
		body := []byte(class + "-approved-archive")
		archiveSHA := sha256.Sum256(body)
		image := approvedImage{
			Class:         class,
			InputDigest:   inputDigest,
			ArchiveSize:   int64(len(body)),
			ArchiveSHA256: hex.EncodeToString(archiveSHA[:]),
		}
		inputs.Images = append(inputs.Images, runtimeinputs.Image{Class: class, InputDigest: inputDigest})
		manifest.Images = append(manifest.Images, image)
		if err := os.WriteFile(filepath.Join(approvedDir, class+".oci.tar"), body, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	inputs.Images[1].InputDigest = digest("changed-meeting-input")
	writeManifest(t, approvedDir, manifest)

	reused, err := Copy(inputs, approvedDir, outputDir)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Join(reused, ",") != "external,shell" {
		t.Fatalf("reused = %v", reused)
	}
	for _, class := range reused {
		if _, err := os.Stat(filepath.Join(outputDir, class+".oci.tar")); err != nil {
			t.Fatalf("reused archive %s: %v", class, err)
		}
	}
	if _, err := os.Stat(filepath.Join(outputDir, "meeting.oci.tar")); !os.IsNotExist(err) {
		t.Fatalf("changed meeting archive should not be reused: %v", err)
	}
}

func TestCopyTreatsChangedApprovedBytesAsACacheMiss(t *testing.T) {
	approvedDir := t.TempDir()
	outputDir := t.TempDir()
	inputDigest := digest("input")
	writeManifest(t, approvedDir, approvedManifest{
		SchemaVersion: 3,
		Images: []approvedImage{{
			Class: "external", InputDigest: inputDigest, ArchiveSize: 4,
			ArchiveSHA256: strings.Repeat("0", 64),
		}},
	})
	if err := os.WriteFile(filepath.Join(approvedDir, "external.oci.tar"), []byte("evil"), 0o644); err != nil {
		t.Fatal(err)
	}
	reused, err := Copy(runtimeinputs.Manifest{
		SchemaVersion: 1,
		Images:        []runtimeinputs.Image{{Class: "external", InputDigest: inputDigest}},
	}, approvedDir, outputDir)
	if err != nil || len(reused) != 0 {
		t.Fatalf("reused = %v, error = %v", reused, err)
	}
}

func TestCopySkipsLegacyBundleWithoutInputIdentity(t *testing.T) {
	approvedDir := t.TempDir()
	outputDir := t.TempDir()
	if err := os.WriteFile(filepath.Join(approvedDir, "manifest.json"), []byte(`{"schemaVersion":2}`), 0o644); err != nil {
		t.Fatal(err)
	}
	reused, err := Copy(runtimeinputs.Manifest{SchemaVersion: 1}, approvedDir, outputDir)
	if err != nil || len(reused) != 0 {
		t.Fatalf("reused = %v, error = %v", reused, err)
	}
}

func writeManifest(t *testing.T, dir string, manifest approvedManifest) {
	t.Helper()
	data, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "manifest.json"), data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func digest(value string) string {
	sum := sha256.Sum256([]byte(value))
	return "sha256:" + hex.EncodeToString(sum[:])
}
