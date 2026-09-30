package output

import (
	"encoding/json"
	"fmt"
	"io"
	"regexp"
	"strings"
)

const SchemaVersion = "bft.cli.v1"

const (
	ExitOK          = 0
	ExitNeedsManual = 2
	ExitUsage       = 64
	ExitNotFound    = 66
	ExitUnavailable = 69
	ExitSoftware    = 70
)

type Options struct {
	JSON   bool
	Quiet  bool
	Fields []string
}

type Error struct {
	ExitCode   int
	Code       string
	Message    string
	Details    map[string]any
	NextAction string
	Retryable  bool
}

func (e Error) Error() string {
	return e.Message
}

func Usage(code, message string, details map[string]any) Error {
	return Error{ExitCode: ExitUsage, Code: code, Message: message, Details: details, NextAction: message}
}

func RenderSuccess(stdout io.Writer, opts Options, data any, text func() string, exitCode int) int {
	if opts.JSON {
		rendered := Redact(data)
		if len(opts.Fields) > 0 {
			rendered = ProjectFields(rendered, opts.Fields)
		}
		writeJSON(stdout, map[string]any{
			"schema_version": SchemaVersion,
			"ok":             true,
			"data":           rendered,
		})
		return exitCode
	}
	if !opts.Quiet && text != nil {
		fmt.Fprint(stdout, text())
	}
	return exitCode
}

func RenderError(stderr io.Writer, opts Options, err Error) int {
	if err.ExitCode == 0 {
		err.ExitCode = ExitSoftware
	}
	if err.Code == "" {
		err.Code = "cli_error"
	}
	if err.NextAction == "" {
		err.NextAction = err.Message
	}
	if err.Details == nil {
		err.Details = map[string]any{}
	}
	if opts.JSON {
		writeJSON(stderr, map[string]any{
			"schema_version": SchemaVersion,
			"ok":             false,
			"error": map[string]any{
				"code":        err.Code,
				"message":     err.Message,
				"details":     Redact(err.Details),
				"next_action": err.NextAction,
				"retryable":   err.Retryable,
			},
		})
		return err.ExitCode
	}
	fmt.Fprintf(stderr, "bft: %s\n", err.Message)
	return err.ExitCode
}

func writeJSON(w io.Writer, value any) {
	encoder := json.NewEncoder(w)
	encoder.SetIndent("", "  ")
	_ = encoder.Encode(value)
}

var secretQueryPattern = regexp.MustCompile(`(?i)([?&](?:code|token|secret|key|api_key|access_token|refresh_token)=)[^&"'\s]+`)

func Redact(value any) any {
	switch v := value.(type) {
	case map[string]any:
		redacted := make(map[string]any, len(v))
		for key, raw := range v {
			if isExecutableCommandKey(key) {
				if _, ok := raw.(string); ok {
					redacted[key] = raw
				} else {
					redacted[key] = Redact(raw)
				}
			} else if isSensitiveKey(key) {
				redacted[key] = "[REDACTED]"
			} else {
				redacted[key] = Redact(raw)
			}
		}
		return redacted
	case []any:
		redacted := make([]any, 0, len(v))
		for _, item := range v {
			redacted = append(redacted, Redact(item))
		}
		return redacted
	case []map[string]any:
		redacted := make([]any, 0, len(v))
		for _, item := range v {
			redacted = append(redacted, Redact(item))
		}
		return redacted
	case string:
		return secretQueryPattern.ReplaceAllString(v, "$1[REDACTED]")
	default:
		return value
	}
}

func ProjectFields(value any, fields []string) any {
	source, ok := value.(map[string]any)
	if !ok || len(fields) == 0 {
		return value
	}
	projected := make(map[string]any, len(fields))
	for _, field := range fields {
		field = strings.TrimSpace(field)
		if field == "" {
			continue
		}
		if raw, ok := source[field]; ok {
			projected[field] = raw
		}
	}
	return projected
}

func isSensitiveKey(key string) bool {
	normalized := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(key, "-", "_"), " ", "_"))
	if strings.HasSuffix(normalized, "_configured") ||
		strings.HasSuffix(normalized, "_printed") ||
		strings.HasSuffix(normalized, "_env") ||
		normalized == "token_type" ||
		normalized == "exit_code" ||
		normalized == "code" {
		return false
	}
	sensitiveMarkers := []string{
		"secret",
		"token",
		"encrypt_key",
		"api_key",
		"private_key",
		"authorization",
		"bearer",
		"password",
		"message_body",
		"message_text",
		"message_content",
		"raw_message",
		"chat_message",
	}
	for _, marker := range sensitiveMarkers {
		if strings.Contains(normalized, marker) {
			return true
		}
	}
	return false
}

func isExecutableCommandKey(key string) bool {
	normalized := strings.ToLower(strings.ReplaceAll(strings.ReplaceAll(key, "-", "_"), " ", "_"))
	return normalized == "command"
}
