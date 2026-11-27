package bundlemanifest

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/AFK-surf/comma/systems/runtime-images/internal/erofsbundle"
)

const SchemaVersion = 4

var requiredClasses = []string{"shell", "station"}

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

func Generate(revision string, inputDigests, archives map[string]string) (Manifest, error) {
	if revision == "" {
		return Manifest{}, errors.New("source revision is required")
	}
	if len(inputDigests) != len(requiredClasses) || len(archives) != len(requiredClasses) {
		return Manifest{}, fmt.Errorf("expected input digests and archives for %v", requiredClasses)
	}
	result := Manifest{SchemaVersion: SchemaVersion, SourceRevision: revision}
	for _, class := range requiredClasses {
		path, ok := archives[class]
		if !ok {
			return Manifest{}, fmt.Errorf("missing %s archive", class)
		}
		inputDigest, ok := inputDigests[class]
		if !ok || !erofsbundle.ValidDigest(inputDigest) {
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
	result, err := erofsbundle.InspectFile(path, true)
	if err != nil {
		return Image{}, err
	}
	return Image{
		Class:          class,
		InputDigest:    inputDigest,
		Reference:      "comma.local/runtime/" + class + "@" + result.Header.ManifestDigest,
		Platform:       result.Header.Platform,
		ArchiveSize:    result.ArchiveSize,
		ArchiveSHA256:  result.ArchiveSHA256,
		ManifestDigest: result.Header.ManifestDigest,
	}, nil
}
