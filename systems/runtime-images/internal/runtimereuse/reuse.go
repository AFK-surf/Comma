package runtimereuse

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"

	"github.com/AFK-surf/comma/systems/runtime-images/internal/runtimeinputs"
)

type approvedManifest struct {
	SchemaVersion int             `json:"schemaVersion"`
	Images        []approvedImage `json:"images"`
}

type approvedImage struct {
	Class         string `json:"class"`
	InputDigest   string `json:"inputDigest"`
	ArchiveSize   int64  `json:"archiveSize"`
	ArchiveSHA256 string `json:"archiveSha256"`
}

func Copy(inputs runtimeinputs.Manifest, approvedDir, outputDir string) ([]string, error) {
	if approvedDir == "" {
		return nil, nil
	}
	data, err := os.ReadFile(filepath.Join(approvedDir, "manifest.json"))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read approved runtime manifest: %w", err)
	}
	var approved approvedManifest
	if err := json.Unmarshal(data, &approved); err != nil {
		return nil, nil
	}
	// Format 2 bundles predate input identities and are deliberately rebuilt.
	if approved.SchemaVersion != 3 {
		return nil, nil
	}
	if len(approved.Images) != len(inputs.Images) {
		return nil, nil
	}
	indexed := make(map[string]approvedImage, len(approved.Images))
	for _, image := range approved.Images {
		if _, exists := indexed[image.Class]; exists {
			return nil, nil
		}
		indexed[image.Class] = image
	}

	var reused []string
	for _, current := range inputs.Images {
		prior, ok := indexed[current.Class]
		if !ok {
			continue
		}
		if prior.InputDigest != current.InputDigest {
			continue
		}
		source := filepath.Join(approvedDir, current.Class+".oci.tar")
		if err := verifyArchive(source, prior.ArchiveSHA256, prior.ArchiveSize); err != nil {
			continue
		}
		if err := copyFile(source, filepath.Join(outputDir, current.Class+".oci.tar")); err != nil {
			return nil, fmt.Errorf("copy approved %s runtime archive: %w", current.Class, err)
		}
		reused = append(reused, current.Class)
	}
	return reused, nil
}

func verifyArchive(path, wantSHA string, wantSize int64) error {
	if len(wantSHA) != 64 || wantSize <= 0 {
		return fmt.Errorf("invalid archive cache identity")
	}
	if _, err := hex.DecodeString(wantSHA); err != nil {
		return fmt.Errorf("invalid archive cache SHA-256")
	}
	file, err := os.Open(path)
	if err != nil {
		return err
	}
	hash := sha256.New()
	size, copyErr := io.Copy(hash, file)
	closeErr := file.Close()
	if copyErr != nil {
		return copyErr
	}
	if closeErr != nil {
		return closeErr
	}
	gotSHA := hex.EncodeToString(hash.Sum(nil))
	if gotSHA != wantSHA || size != wantSize {
		return fmt.Errorf("bytes differ from approved descriptor")
	}
	return nil
}

func copyFile(source, target string) error {
	input, err := os.Open(source)
	if err != nil {
		return err
	}
	defer input.Close()
	output, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o644)
	if err != nil {
		return err
	}
	_, copyErr := io.Copy(output, input)
	closeErr := output.Close()
	if copyErr != nil {
		return copyErr
	}
	return closeErr
}
