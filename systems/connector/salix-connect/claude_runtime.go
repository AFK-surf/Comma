package main

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"time"
)

const (
	claudeCloseTimeout          = 3 * time.Second
	claudeDiagnosticMaxBytes    = 32 * 1024
	claudeReadinessMaxLineBytes = 1024 * 1024
)

// claudeRuntimeImplementation is the Claude runtime owner. Claude has no
// long-lived native process on this Connector: readiness probes and provider
// verification start their own short-lived commands.
type claudeRuntimeImplementation struct{}

func newClaudeRuntimeImplementation() *claudeRuntimeImplementation {
	return &claudeRuntimeImplementation{}
}

func (i *claudeRuntimeImplementation) Close() {}

func managedClaudeConfigAuthConflict(directory string) bool {
	return managedClaudeAuthFilesConflict(
		filepath.Join(directory, "settings.json"),
		filepath.Join(directory, "settings.local.json"),
	)
}

func managedClaudeAuthFilesConflict(paths ...string) bool {
	for _, path := range paths {
		file, err := os.Open(path)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			return true
		}
		var value any
		err = json.NewDecoder(io.LimitReader(file, runtimeAuthPlaintextLimit+1)).Decode(&value)
		file.Close()
		if err != nil || managedClaudeValueHasAuth(value) {
			return true
		}
	}
	return false
}

func managedClaudeValueHasAuth(value any) bool {
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			switch key {
			case "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "CLAUDE_CODE_OAUTH_TOKEN", "apiKeyHelper":
				return true
			}
			if managedClaudeValueHasAuth(child) {
				return true
			}
		}
	case []any:
		for _, child := range value {
			if managedClaudeValueHasAuth(child) {
				return true
			}
		}
	}
	return false
}

func newClaudeSessionID() (string, error) {
	bytes := make([]byte, 16)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	bytes[6] = (bytes[6] & 0x0f) | 0x40
	bytes[8] = (bytes[8] & 0x3f) | 0x80
	encoded := hex.EncodeToString(bytes)
	return encoded[0:8] + "-" + encoded[8:12] + "-" + encoded[12:16] + "-" + encoded[16:20] + "-" + encoded[20:32], nil
}
