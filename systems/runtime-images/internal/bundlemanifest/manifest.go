package bundlemanifest

import (
	"archive/tar"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

const (
	mediaTypeImageIndex    = "application/vnd.oci.image.index.v1+json"
	mediaTypeImageManifest = "application/vnd.oci.image.manifest.v1+json"
)

var requiredClasses = []string{"external", "meeting", "shell"}

type Manifest struct {
	SchemaVersion  int     `json:"schemaVersion"`
	SourceRevision string  `json:"sourceRevision"`
	Images         []Image `json:"images"`
}

type Image struct {
	Class          string `json:"class"`
	InputDigest    string `json:"inputDigest"`
	Reference      string `json:"reference"`
	Platform       string `json:"platform"`
	ArchiveSize    int64  `json:"archiveSize"`
	ArchiveSHA256  string `json:"archiveSha256"`
	ManifestDigest string `json:"manifestDigest"`
}

type descriptor struct {
	MediaType   string            `json:"mediaType"`
	Digest      string            `json:"digest"`
	Platform    *platform         `json:"platform,omitempty"`
	Annotations map[string]string `json:"annotations,omitempty"`
}

type platform struct {
	Architecture string `json:"architecture"`
	OS           string `json:"os"`
}

type index struct {
	SchemaVersion int          `json:"schemaVersion"`
	MediaType     string       `json:"mediaType"`
	Manifests     []descriptor `json:"manifests"`
}

type imageManifest struct {
	SchemaVersion int        `json:"schemaVersion"`
	MediaType     string     `json:"mediaType"`
	Config        descriptor `json:"config"`
}

type imageConfig struct {
	Architecture string `json:"architecture"`
	OS           string `json:"os"`
}

func Generate(revision string, inputDigests, archives map[string]string) (Manifest, error) {
	if revision == "" {
		return Manifest{}, errors.New("source revision is required")
	}
	if len(inputDigests) != len(requiredClasses) || len(archives) != len(requiredClasses) {
		return Manifest{}, fmt.Errorf("expected input digests and archives for %v", requiredClasses)
	}
	result := Manifest{SchemaVersion: 3, SourceRevision: revision}
	for _, class := range requiredClasses {
		path, ok := archives[class]
		if !ok {
			return Manifest{}, fmt.Errorf("missing %s archive", class)
		}
		inputDigest, ok := inputDigests[class]
		if !ok || !validDigest(inputDigest) {
			return Manifest{}, fmt.Errorf("missing or invalid %s input digest", class)
		}
		image, err := inspectArchive(class, inputDigest, path)
		if err != nil {
			return Manifest{}, fmt.Errorf("validate %s archive: %w", class, err)
		}
		result.Images = append(result.Images, image)
	}
	return result, nil
}

func Write(path string, manifest Manifest) error {
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	return os.WriteFile(path, data, 0o644)
}

func inspectArchive(class, inputDigest, path string) (Image, error) {
	archive, err := os.ReadFile(path)
	if err != nil {
		return Image{}, err
	}
	blobs, err := readArchive(archive)
	if err != nil {
		return Image{}, err
	}

	var layout struct {
		ImageLayoutVersion string `json:"imageLayoutVersion"`
	}
	if err := decodeRequired(blobs, "oci-layout", &layout); err != nil {
		return Image{}, err
	}
	if layout.ImageLayoutVersion != "1.0.0" {
		return Image{}, fmt.Errorf("unsupported OCI layout version %q", layout.ImageLayoutVersion)
	}

	var root index
	if err := decodeRequired(blobs, "index.json", &root); err != nil {
		return Image{}, err
	}
	if root.SchemaVersion != 2 || len(root.Manifests) != 1 {
		return Image{}, fmt.Errorf("OCI index must contain exactly one manifest, got %d", len(root.Manifests))
	}

	desc := root.Manifests[0]
	if desc.MediaType == mediaTypeImageIndex {
		return Image{}, errors.New("nested OCI indexes are not accepted")
	}
	if desc.MediaType != mediaTypeImageManifest {
		return Image{}, fmt.Errorf("unsupported manifest media type %q", desc.MediaType)
	}
	if desc.Platform == nil || desc.Platform.OS != "linux" || desc.Platform.Architecture != "arm64" {
		return Image{}, fmt.Errorf("image platform must be linux/arm64, got %#v", desc.Platform)
	}
	manifestBytes, err := blobByDigest(blobs, desc.Digest)
	if err != nil {
		return Image{}, fmt.Errorf("read image manifest: %w", err)
	}
	if err := verifyDigest(desc.Digest, manifestBytes); err != nil {
		return Image{}, err
	}
	var imageManifest imageManifest
	if err := json.Unmarshal(manifestBytes, &imageManifest); err != nil {
		return Image{}, fmt.Errorf("decode image manifest: %w", err)
	}
	if imageManifest.SchemaVersion != 2 || imageManifest.MediaType != mediaTypeImageManifest {
		return Image{}, errors.New("invalid OCI image manifest")
	}

	configBytes, err := blobByDigest(blobs, imageManifest.Config.Digest)
	if err != nil {
		return Image{}, fmt.Errorf("read image config: %w", err)
	}
	if err := verifyDigest(imageManifest.Config.Digest, configBytes); err != nil {
		return Image{}, err
	}
	var config imageConfig
	if err := json.Unmarshal(configBytes, &config); err != nil {
		return Image{}, fmt.Errorf("decode image config: %w", err)
	}
	if config.OS != "linux" || config.Architecture != "arm64" {
		return Image{}, fmt.Errorf("config platform must be linux/arm64, got %s/%s", config.OS, config.Architecture)
	}
	sum := sha256.Sum256(archive)
	archiveSHA256 := hex.EncodeToString(sum[:])
	return Image{
		Class:          class,
		InputDigest:    inputDigest,
		Reference:      "comma.local/runtime/" + class + "@" + desc.Digest,
		Platform:       "linux/arm64",
		ArchiveSize:    int64(len(archive)),
		ArchiveSHA256:  archiveSHA256,
		ManifestDigest: desc.Digest,
	}, nil
}

func readArchive(data []byte) (map[string][]byte, error) {
	result := make(map[string][]byte)
	reader := tar.NewReader(bytes.NewReader(data))
	for {
		header, err := reader.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, fmt.Errorf("read OCI archive: %w", err)
		}
		if header.Typeflag != tar.TypeReg && header.Typeflag != tar.TypeRegA {
			continue
		}
		name := strings.TrimPrefix(filepath.ToSlash(header.Name), "./")
		body, err := io.ReadAll(reader)
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", name, err)
		}
		result[name] = body
	}
	return result, nil
}

func decodeRequired(files map[string][]byte, name string, target any) error {
	data, ok := files[name]
	if !ok {
		return fmt.Errorf("missing %s", name)
	}
	if err := json.Unmarshal(data, target); err != nil {
		return fmt.Errorf("decode %s: %w", name, err)
	}
	return nil
}

func blobByDigest(files map[string][]byte, digest string) ([]byte, error) {
	parts := strings.SplitN(digest, ":", 2)
	if len(parts) != 2 || parts[0] != "sha256" || len(parts[1]) != 64 {
		return nil, fmt.Errorf("unsupported digest %q", digest)
	}
	data, ok := files["blobs/sha256/"+parts[1]]
	if !ok {
		return nil, fmt.Errorf("missing blob %s", digest)
	}
	return data, nil
}

func verifyDigest(want string, data []byte) error {
	sum := sha256.Sum256(data)
	got := "sha256:" + hex.EncodeToString(sum[:])
	if got != want {
		return fmt.Errorf("blob digest = %s, want %s", got, want)
	}
	return nil
}

func validDigest(value string) bool {
	if !strings.HasPrefix(value, "sha256:") || len(value) != len("sha256:")+64 {
		return false
	}
	_, err := hex.DecodeString(strings.TrimPrefix(value, "sha256:"))
	return err == nil
}
