package main

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"
)

// These are the file forms consumed by packaged Codex 0.153.0. Preserve the
// original file bytes; the adapter does not mint, convert, or refresh tokens.
// Acceptance here is format evidence only, never authenticated/readiness proof.
type runtimeAuthCodexFile struct {
	mode string
}

func parseRuntimeAuthCodexFile(data []byte) (runtimeAuthCodexFile, error) {
	invalid := runtimeAuthCodexFile{}
	if len(data) == 0 || len(data) > runtimeAuthPlaintextLimit {
		return invalid, errRuntimeAuthInputInvalid
	}
	fields, err := runtimeAuthJSONObject(data, "auth_mode", "OPENAI_API_KEY", "tokens", "last_refresh")
	if err != nil {
		return invalid, err
	}
	var mode string
	if raw, present := fields["auth_mode"]; present && json.Unmarshal(raw, &mode) != nil {
		return invalid, errRuntimeAuthInputInvalid
	}
	if mode == "apikey" {
		var key string
		if len(fields) != 2 || json.Unmarshal(fields["OPENAI_API_KEY"], &key) != nil || !runtimeAuthCodexToken(key) {
			return invalid, errRuntimeAuthInputInvalid
		}
		return runtimeAuthCodexFile{mode: mode}, nil
	}
	if mode != "" && mode != "chatgpt" {
		return invalid, errRuntimeAuthInputInvalid
	}
	if raw, present := fields["OPENAI_API_KEY"]; present && string(raw) != "null" {
		return invalid, errRuntimeAuthInputInvalid
	}
	tokens, err := runtimeAuthJSONObject(fields["tokens"], "id_token", "access_token", "refresh_token", "account_id")
	if err != nil || len(tokens) != 4 {
		return invalid, errRuntimeAuthInputInvalid
	}
	for _, field := range []string{"id_token", "access_token", "refresh_token", "account_id"} {
		var value string
		if json.Unmarshal(tokens[field], &value) != nil || !runtimeAuthCodexToken(value) {
			return invalid, errRuntimeAuthInputInvalid
		}
	}
	var refreshed string
	if json.Unmarshal(fields["last_refresh"], &refreshed) != nil {
		return invalid, errRuntimeAuthInputInvalid
	}
	if _, err := time.Parse(time.RFC3339Nano, refreshed); err != nil {
		return invalid, errRuntimeAuthInputInvalid
	}
	return runtimeAuthCodexFile{mode: "chatgpt"}, nil
}

func runtimeAuthCodexToken(value string) bool {
	if value == "" {
		return false
	}
	return strings.IndexFunc(value, func(r rune) bool { return unicode.IsSpace(r) || unicode.IsControl(r) }) < 0
}

// Native stdin login produces its own file format in an isolated preparation
// directory. Only the existing owner can replace the real native file.
func prepareRuntimeAuthCodexAPIKey(ctx context.Context, command, authPath, key string) ([]byte, error) {
	if !runtimeAuthCodexToken(key) {
		return nil, errRuntimeAuthInputInvalid
	}
	parent := filepath.Dir(authPath)
	if err := os.MkdirAll(parent, 0700); err != nil {
		return nil, errRuntimeAuthInputInvalid
	}
	directory, err := os.MkdirTemp(parent, ".auth-login-")
	if err != nil {
		return nil, errRuntimeAuthInputInvalid
	}
	defer os.RemoveAll(directory)
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if os.WriteFile(filepath.Join(directory, "config.toml"), []byte("cli_auth_credentials_store = \"file\"\ncheck_for_update_on_startup = false\n"), 0600) != nil {
		return nil, errRuntimeAuthInputInvalid
	}
	cmd := commandContextWithProcessGroup(ctx, codexExecutionPath(command), "login", "--with-api-key")
	cmd.Dir = directory
	cmd.Env = []string{"PATH=" + runtimeCommandPath(command), "HOME=" + directory, "CODEX_HOME=" + directory, "TMPDIR=" + directory}
	cmd.Stdin = strings.NewReader(key)
	cmd.Stdout, cmd.Stderr = io.Discard, io.Discard
	cmd.WaitDelay = time.Second
	if cmd.Run() != nil {
		return nil, errRuntimeAuthInputInvalid
	}
	file, err := os.Open(filepath.Join(directory, "auth.json"))
	if err != nil {
		return nil, errRuntimeAuthInputInvalid
	}
	defer file.Close()
	data, err := io.ReadAll(io.LimitReader(file, runtimeAuthPlaintextLimit+1))
	if err != nil || len(data) > runtimeAuthPlaintextLimit {
		clear(data)
		return nil, errRuntimeAuthInputInvalid
	}
	parsed, err := parseRuntimeAuthCodexFile(data)
	if err != nil || parsed.mode != "apikey" {
		clear(data)
		return nil, errRuntimeAuthInputInvalid
	}
	return data, nil
}

// The native config/read result is the authority for layered storage/login
// policy. A caller must obtain it from the current target process, not from
// browser input or the legacy top-level TOML scanner. The consumer is import
// admission: keyring/auto must never be silently downgraded to file storage.
// Workspace-restricted targets retain the native login path until this adapter
// can enforce that restriction through the native owner before replacement.
func runtimeAuthCodexImportPolicy(config map[string]any, file runtimeAuthCodexFile) string {
	if stringParam(config, "cli_auth_credentials_store") != "file" {
		return "native_storage_unsupported"
	}
	if workspace := config["forced_chatgpt_workspace_id"]; workspace != nil && workspace != "" {
		return "native_login_required"
	}
	forced, valid := config["forced_login_method"].(string)
	if !valid && config["forced_login_method"] != nil {
		return "native_login_required"
	}
	if forced != "" && !((forced == "api" && file.mode == "apikey") || (forced == "chatgpt" && file.mode == "chatgpt")) {
		return "native_login_required"
	}
	if file.mode != "apikey" && file.mode != "chatgpt" {
		return "invalid_format"
	}
	return ""
}

// Codex's public login API owns login ceremonies, but provides no staged
// auth.json import/commit operation. The documented file-mode import therefore
// uses a same-directory 0600 stage and the shared owner commit seam, retaining
// native bytes. The owner supplies the path and effective native config, must
// quiesce its idle native writer, and must fence the rename against new work and
// stale authorization. This adapter alone does not authorize a replacement.
func saveRuntimeAuthCodex(ctx context.Context, authPath string, data []byte, config map[string]any, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	file, err := parseRuntimeAuthCodexFile(data)
	if err != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
	}
	if issue := runtimeAuthCodexImportPolicy(config, file); issue != "" {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: issue}
	}
	if ctx.Err() != nil || commit == nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	}
	stage, err := os.CreateTemp(filepath.Dir(authPath), ".auth-input-*")
	if err != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "storage_prepare_failed"}
	}
	stagePath := stage.Name()
	defer os.Remove(stagePath)
	_, writeErr := stage.Write(data)
	if writeErr == nil {
		writeErr = stage.Sync()
	}
	closeErr := stage.Close()
	if writeErr != nil || closeErr != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "storage_prepare_failed"}
	}
	if ctx.Err() != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	}
	return commit(stagePath)
}

// commitOwnedCodexAuthFileLocked refines the native-writer boundary of an
// already-authorized, idle private input. Caller holds the shared target lock
// and has checked targetBusy. The deployment must own the native file's writers;
// this function cannot establish that for independent user CLI processes.
//
// Native creation shares i.mu. Keep it through confirmed process exit and the
// file commit, so a full probe cannot spawn a replacement against old bytes.
// authEpoch orders observations from this same process; it is not a credential
// revision and does not gate an explicitly authorized replacement.
// Wait on exited, not done: done waits for runtimeClosed, which needs the target
// lock held by the caller. The exit callback later removes only its exact old
// generation. RuntimeAuthNativeFile.tla models the exit-before-commit boundary.
func (i *codexRuntimeImplementation) commitOwnedCodexAuthFileLocked(ctx context.Context, target runtimeProbeTarget, native *codexRuntime, commit func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	rejected := runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	i.mu.Lock()
	defer i.mu.Unlock()
	if ctx.Err() != nil || commit == nil || native == nil || target.provider != "codex" ||
		i.runtimes[target.identityMaterial] != native || native.command != target.identityMaterial ||
		i.authQuarantined[native.generation] || !native.isRunning() {
		return rejected
	}
	// Invalidate old readiness before stopping its writer. File presence will
	// not establish new authentication; the input owner must verify separately.
	if i.connector.runtimeInventory != nil {
		i.connector.runtimeInventory.updateAuthSnapshot(target, map[string]any{
			"schema_version": 1, "status": "unknown", "requires_openai_auth": true,
			"observed_at": time.Now().UnixMilli(),
		}, false)
	}
	native.authEpoch++
	native.fullReadinessProven = false
	i.authQuarantined[native.generation] = true
	native.terminate()
	deadline := time.NewTimer(runtimeAuthNativeCancelTimeout)
	defer deadline.Stop()
	select {
	case <-native.exited:
	case <-ctx.Done():
		return rejected
	case <-deadline.C:
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "native_writer_unavailable"}
	}
	delete(i.runtimes, target.identityMaterial)
	delete(i.authQuarantined, native.generation)
	if ctx.Err() != nil {
		return rejected
	}
	// The callback still owns the final live authorization fence and rename.
	return commit()
}

// savePrivateCodex consumes the same envelope/receipt owner as Pi. The caller
// supplies config/read from the captured native process and its owner-derived
// auth path. withCarrier must serialize the final rename with transport
// revocation; current alone only admits preparation and native shutdown.
func (m *runtimeAuthCoordinator) savePrivateCodex(ctx context.Context, target runtimeProbeTarget, expected runtimeAuthInputContext, envelope runtimeAuthInputEnvelope, native *codexRuntime, authPath string, config map[string]any, current func() bool, withCarrier func(func() runtimeAuthSaveOutcome) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	rejected := runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	if m.codex == nil || native == nil || native.generation != expected.NativeGeneration || withCarrier == nil {
		return rejected
	}
	return m.savePrivateInput(ctx, target, expected, envelope, current, func(data []byte, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
		if expected.Form == "api_key" {
			key, err := parseRuntimeAuthAPIKey(data)
			if err != nil || expected.Backend != "openai" || runtimeAuthCodexImportPolicy(config, runtimeAuthCodexFile{mode: "apikey"}) != "" {
				return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
			}
			data, err = prepareRuntimeAuthCodexAPIKey(ctx, target.identityMaterial, authPath, key)
			if err != nil {
				return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "native_helper_failed"}
			}
			defer clear(data)
		}
		file, err := parseRuntimeAuthCodexFile(data)
		if err != nil || (file.mode == "chatgpt" && expected.Backend != "chatgpt") || (file.mode == "apikey" && expected.Backend != "openai") {
			return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "invalid_format"}
		}
		return saveRuntimeAuthCodex(ctx, authPath, data, config, commit)
	}, func(stage string) runtimeAuthSaveOutcome {
		return m.codex.commitOwnedCodexAuthFileLocked(ctx, target, native, func() runtimeAuthSaveOutcome {
			return withCarrier(func() runtimeAuthSaveOutcome {
				return commitRuntimeAuthFile(ctx, stage, authPath)
			})
		})
	})
}
