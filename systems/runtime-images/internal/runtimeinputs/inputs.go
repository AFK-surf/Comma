package runtimeinputs

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

const schemaVersion = 1

var classes = []string{"external", "meeting", "shell"}

type Manifest struct {
	SchemaVersion int     `json:"schemaVersion"`
	Images        []Image `json:"images"`
}

type Image struct {
	Class       string `json:"class"`
	InputDigest string `json:"inputDigest"`
}

type classInput struct {
	files    []string
	lockKeys []string
}

func Generate(root string) (Manifest, error) {
	lockPath := filepath.Join(root, "systems/runtime-images/runtime-dependencies.lock.json")
	lockBytes, err := os.ReadFile(lockPath)
	if err != nil {
		return Manifest{}, fmt.Errorf("read runtime dependency lock: %w", err)
	}
	var lock map[string]any
	if err := json.Unmarshal(lockBytes, &lock); err != nil {
		return Manifest{}, fmt.Errorf("decode runtime dependency lock: %w", err)
	}
	if lock["schemaVersion"] != float64(1) {
		return Manifest{}, errors.New("runtime dependency lock schemaVersion must be 1")
	}

	connector := "systems/connector/salix-connect"
	buildRecipe := "scripts/build-runtime-images.sh"
	definitions := map[string]classInput{
		"external": {
			files: []string{
				buildRecipe,
				"systems/runtime-images/external/Dockerfile",
				connector,
			},
			lockKeys: []string{"baseImages.go", "baseImages.external", "npm", "npmSecurityPatches", "codex", "claude", "pi"},
		},
		"meeting": {
			files: []string{
				buildRecipe,
				"systems/runtime-images/meeting/Dockerfile",
				"systems/runtime-images/go.mod",
				"systems/runtime-images/cmd/comma-meeting-runtime",
				connector,
			},
			lockKeys: []string{"baseImages.go", "baseImages.meeting", "meetnative"},
		},
		"shell": {
			files: []string{
				buildRecipe,
				"systems/runtime-images/shell/Dockerfile",
				"systems/runtime-images/go.mod",
				"systems/runtime-images/cmd/comma-shell-runtime",
			},
			lockKeys: []string{"baseImages.go", "baseImages.shell"},
		},
	}

	result := Manifest{SchemaVersion: schemaVersion}
	for _, class := range classes {
		digest, err := digestClass(root, class, definitions[class], lock)
		if err != nil {
			return Manifest{}, fmt.Errorf("digest %s runtime inputs: %w", class, err)
		}
		result.Images = append(result.Images, Image{Class: class, InputDigest: digest})
	}
	return result, nil
}

func Write(path string, manifest Manifest) error {
	data, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, append(data, '\n'), 0o644)
}

func digestClass(root, class string, input classInput, lock map[string]any) (string, error) {
	hash := sha256.New()
	writeField(hash, "format", "comma-runtime-input-v1")
	writeField(hash, "class", class)
	writeField(hash, "platform", "linux/arm64")

	for _, key := range input.lockKeys {
		value, ok := nestedValue(lock, strings.Split(key, "."))
		if !ok {
			return "", fmt.Errorf("missing lock value %s", key)
		}
		encoded, err := json.Marshal(value)
		if err != nil {
			return "", fmt.Errorf("encode lock value %s: %w", key, err)
		}
		writeField(hash, "lock:"+key, string(encoded))
	}

	files, err := inputFiles(root, input.files)
	if err != nil {
		return "", err
	}
	for _, path := range files {
		info, err := os.Lstat(filepath.Join(root, filepath.FromSlash(path)))
		if err != nil {
			return "", err
		}
		if !info.Mode().IsRegular() {
			return "", fmt.Errorf("runtime input %s is not a regular file", path)
		}
		writeField(hash, "path", path)
		writeField(hash, "mode", fmt.Sprintf("%04o", info.Mode().Perm()))
		file, err := os.Open(filepath.Join(root, filepath.FromSlash(path)))
		if err != nil {
			return "", err
		}
		_, copyErr := io.Copy(hash, file)
		closeErr := file.Close()
		if copyErr != nil {
			return "", copyErr
		}
		if closeErr != nil {
			return "", closeErr
		}
		hash.Write([]byte{0})
	}

	return "sha256:" + hex.EncodeToString(hash.Sum(nil)), nil
}

func inputFiles(root string, entries []string) ([]string, error) {
	var result []string
	for _, entry := range entries {
		absolute := filepath.Join(root, filepath.FromSlash(entry))
		info, err := os.Stat(absolute)
		if err != nil {
			return nil, err
		}
		if info.Mode().IsRegular() {
			result = append(result, filepath.ToSlash(entry))
			continue
		}
		if !info.IsDir() {
			return nil, fmt.Errorf("runtime input %s is neither a file nor a directory", entry)
		}
		err = filepath.WalkDir(absolute, func(path string, item fs.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			relative, err := filepath.Rel(root, path)
			if err != nil {
				return err
			}
			relative = filepath.ToSlash(relative)
			if item.IsDir() && (item.Name() == ".git" || (relative == "systems/connector/salix-connect/native")) {
				return filepath.SkipDir
			}
			if !item.IsDir() {
				result = append(result, relative)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}
	sort.Strings(result)
	return dedupe(result), nil
}

func nestedValue(value any, path []string) (any, bool) {
	current := value
	for _, key := range path {
		object, ok := current.(map[string]any)
		if !ok {
			return nil, false
		}
		current, ok = object[key]
		if !ok {
			return nil, false
		}
	}
	return current, true
}

func writeField(w io.Writer, name, value string) {
	fmt.Fprintf(w, "%d:%s%d:%s", len(name), name, len(value), value)
}

func dedupe(values []string) []string {
	result := values[:0]
	for _, value := range values {
		if len(result) == 0 || result[len(result)-1] != value {
			result = append(result, value)
		}
	}
	return result
}
