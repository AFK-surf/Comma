package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

const (
	computerUseHelloMessage        = "comma-computer-use-daemon"
	computerUseSocketDirectoryName = "comma-computer-use"
	computerUseSocketFileName      = "computeruse.sock"
	computerUseSocketHashLength    = 16
	computerUseSocketLabelLength   = 12
	computerUseSocketPathMaxBytes  = 104
)

// Desktop builds select the helper name for their release flavor.
var computerUseHelperAppName = "Comma Computer Use.app"

var osExecutable = os.Executable

func defaultComputerUseHelperAppPath() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	exe, err := osExecutable()
	if err != nil {
		return ""
	}
	return filepath.Join(filepath.Dir(exe), "native", "macos", computerUseHelperAppName)
}

func defaultComputerUseSocketPath() string {
	return computerUseSocketPathForRuntime("", "")
}

func computerUseSocketPathForRuntime(runtimeNamespace, runtimeRoot string) string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	tempRoot := filepath.Clean(os.TempDir())
	directory := filepath.Join(tempRoot, computerUseSocketDirectoryName)
	fileName := computerUseSocketFileName
	if identity := computerUseSocketIdentity(runtimeNamespace, runtimeRoot); identity != "" {
		fileName = identity + ".sock"
	}
	path := filepath.Join(directory, fileName)
	if len([]byte(path))+1 <= computerUseSocketPathMaxBytes {
		return path
	}

	// macOS Unix sockets have a 104-byte sun_path buffer, including the
	// terminating NUL. TMPDIR itself can be long, so fall back to a compact
	// per-user directory keyed by that temp root. This hash is only a bounded
	// path identity, not a security check.
	tempIdentity := sha256.Sum256([]byte(tempRoot))
	directory = filepath.Join("/tmp", fmt.Sprintf("comma-cu-%x", tempIdentity[:6]))
	return filepath.Join(directory, fileName)
}

func computerUseSocketIdentity(runtimeNamespace, runtimeRoot string) string {
	root := canonicalComputerUseRuntimeRoot(runtimeRoot)
	if root == "" {
		root = strings.TrimSpace(runtimeNamespace)
		if root == "" {
			return ""
		}
		root = "namespace:" + root
	}

	label := safeComputerUseRuntimeNamespace(runtimeNamespace)
	label = strings.Trim(label, "@-_.")
	if label == "" {
		label = "comma"
	}
	if len(label) > computerUseSocketLabelLength {
		label = label[:computerUseSocketLabelLength]
	}
	digest := sha256.Sum256([]byte(root))
	return fmt.Sprintf("%s-%x", label, digest[:computerUseSocketHashLength/2])
}

func canonicalComputerUseRuntimeRoot(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return ""
	}
	absolute, err := filepath.Abs(value)
	if err != nil {
		return filepath.Clean(value)
	}
	absolute = filepath.Clean(absolute)
	if resolved, err := filepath.EvalSymlinks(absolute); err == nil {
		return filepath.Clean(resolved)
	}
	return absolute
}

func safeComputerUseRuntimeNamespace(value string) string {
	var normalized strings.Builder
	for _, character := range strings.TrimSpace(value) {
		switch {
		case character >= 'a' && character <= 'z':
			normalized.WriteRune(character)
		case character >= 'A' && character <= 'Z':
			normalized.WriteRune(character)
		case character >= '0' && character <= '9':
			normalized.WriteRune(character)
		case character == '@' || character == '-' || character == '_' || character == '.':
			normalized.WriteRune(character)
		default:
			normalized.WriteRune('_')
		}
	}
	return strings.Trim(normalized.String(), ".")
}

func runComputerUseRuntimeCLI(args []string) error {
	if len(args) == 0 {
		return errors.New("usage: salix computer-use <action> [--config path] [--json '{...}']")
	}

	action := args[0]
	fs := flag.NewFlagSet("computer-use", flag.ContinueOnError)
	fs.SetOutput(io.Discard)

	cfg := config{
		configPath: getenv("SALIX_CONNECTOR_CONFIG", ""),
		name:       getenv("SALIX_CONNECTOR_NAME", hostname()),
		root:       getenv("SALIX_CONNECTOR_ROOT", "."),
		reconnect:  true,
	}
	paramsJSON := "{}"
	fs.StringVar(&cfg.configPath, "config", cfg.configPath, "connector config JSON path")
	fs.StringVar(&paramsJSON, "json", paramsJSON, "computer_use params JSON object")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}

	if cfg.configPath != "" {
		explicit := map[string]bool{}
		fs.Visit(func(f *flag.Flag) {
			explicit[f.Name] = true
		})
		if err := applyConfigFile(&cfg, explicit); err != nil {
			return err
		}
	}

	var params map[string]any
	if err := json.Unmarshal([]byte(paramsJSON), &params); err != nil {
		return fmt.Errorf("--json must be a JSON object: %w", err)
	}
	if params == nil {
		params = map[string]any{}
	}
	params["action"] = action

	c, err := newConnector(cfg)
	if err != nil {
		return err
	}

	return json.NewEncoder(os.Stdout).Encode(c.methodComputerUse(context.Background(), params))
}
