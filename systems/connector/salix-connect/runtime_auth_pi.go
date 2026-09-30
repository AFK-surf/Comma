package main

import (
	"context"
	_ "embed"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

//go:embed native_auth/pi.mjs
var runtimeAuthPiSource string

const runtimeAuthPiBridge = `
import { createInterface } from "node:readline";
const lines = createInterface({ input: process.stdin, crlfDelay: Infinity })[Symbol.asyncIterator]();
const send = (value) => new Promise((resolve, reject) => process.stdout.write(JSON.stringify(value) + "\n", (error) => error ? reject(error) : resolve()));
try {
 const initial = await lines.next();
 const entry = JSON.parse(initial.value);
 const result = await savePiApiKey({
  sdkEntry: process.argv[1], authPath: process.argv[2], stagePath: process.argv[3], entry,
  signal: AbortSignal.timeout(30000),
  commit: async () => {
   await send({ type: "prepared" });
   const reply = await lines.next();
   if (reply.done) throw new Error("owner disconnected");
   return JSON.parse(reply.value);
  },
 });
 await send({ type: "result", ...result });
} catch { await send({ type: "result", save_result: "not_committed", issue: "native_helper_failed" }); }
process.exit(0);
`

type runtimeAuthPiEntry struct {
	Type string `json:"type"`
	Key  string `json:"key"`
}

type runtimeAuthSaveOutcome struct {
	SaveResult string `json:"save_result"`
	Issue      string `json:"issue,omitempty"`
}

func parseRuntimeAuthPiEntry(data []byte) (runtimeAuthPiEntry, error) {
	var entry runtimeAuthPiEntry
	if len(data) > runtimeAuthPlaintextLimit || !utf8.Valid(data) {
		return entry, errRuntimeAuthInputInvalid
	}
	fields, err := runtimeAuthJSONObject(data, "type", "key")
	if err != nil || len(fields) != 2 || fields["type"] == nil || fields["key"] == nil || json.Unmarshal(data, &entry) != nil || entry.Type != "api_key" || entry.Key == "" || strings.HasPrefix(entry.Key, "!") || strings.Contains(entry.Key, "$") {
		return runtimeAuthPiEntry{}, errRuntimeAuthInputInvalid
	}
	for _, r := range entry.Key {
		if unicode.IsSpace(r) || unicode.IsControl(r) {
			return runtimeAuthPiEntry{}, errRuntimeAuthInputInvalid
		}
	}
	return entry, nil
}

// commit reacquires the existing target owner for its final fence and rename.
// Preparation runs outside that lock so cancellation can win before commit.
// The helper never decides whether the native file may be committed.
func saveRuntimeAuthPi(ctx context.Context, nodePath, sdkEntry, authPath string, entry runtimeAuthPiEntry, commit func(string) runtimeAuthSaveOutcome) runtimeAuthSaveOutcome {
	outcome := runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "native_helper_failed"}
	stagePath := filepath.Join(filepath.Dir(authPath), ".auth-input-"+randomHex(16))
	defer os.Remove(stagePath)
	cmd := commandContextWithProcessGroup(ctx, nodePath, "--input-type=module", "-e", runtimeAuthPiSource+runtimeAuthPiBridge, sdkEntry, authPath, stagePath)
	cmd.Stderr = io.Discard
	cmd.WaitDelay = time.Second
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return outcome
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		stdin.Close()
		return outcome
	}
	if cmd.Start() != nil {
		stdin.Close()
		return outcome
	}
	defer stdin.Close()
	encoder := json.NewEncoder(stdin)
	if encoder.Encode(entry) != nil {
		stdin.Close()
		cmd.Wait()
		return outcome
	}
	decoder := json.NewDecoder(io.LimitReader(stdout, 16<<10))
	var reply struct {
		Type string `json:"type"`
		runtimeAuthSaveOutcome
	}
	if decoder.Decode(&reply) != nil {
		stdin.Close()
		cmd.Wait()
		return outcome
	}
	if reply.Type == "prepared" {
		outcome = runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
		if ctx.Err() == nil && commit != nil {
			outcome = commit(stagePath)
		}
		if encoder.Encode(outcome) != nil {
			stdin.Close()
			cmd.Wait()
			if outcome.SaveResult == "committed" && outcome.Issue == "" {
				outcome.Issue = "native_refresh_failed"
			}
			return outcome
		}
		reply.Type = ""
		if decoder.Decode(&reply) != nil {
			stdin.Close()
			cmd.Wait()
			if outcome.SaveResult == "committed" && outcome.Issue == "" {
				outcome.Issue = "native_refresh_failed"
			}
			return outcome
		}
	}
	stdin.Close()
	waitErr := cmd.Wait()
	if outcome.SaveResult == "committed" {
		if outcome.Issue == "" && (waitErr != nil || reply.Issue != "") {
			outcome.Issue = "native_refresh_failed"
		}
		return outcome
	}
	if reply.Type == "result" && (reply.SaveResult == "not_committed" || reply.SaveResult == "unknown") {
		return reply.runtimeAuthSaveOutcome
	}
	return outcome
}

// Called inside the target owner's final fenced commit section.
func commitRuntimeAuthFile(ctx context.Context, stagePath, authPath string) runtimeAuthSaveOutcome {
	if ctx.Err() != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "target_changed"}
	}
	if err := os.Rename(stagePath, authPath); err != nil {
		return runtimeAuthSaveOutcome{SaveResult: "not_committed", Issue: "storage_commit_failed"}
	}
	outcome := runtimeAuthSaveOutcome{SaveResult: "committed"}
	directory, err := os.Open(filepath.Dir(authPath))
	if err != nil {
		outcome.Issue = "storage_sync_failed"
		return outcome
	}
	defer directory.Close()
	if directory.Sync() != nil {
		outcome.Issue = "storage_sync_failed"
	}
	return outcome
}

// Resolve only the installed Pi npm layout. The SDK owns its native directory;
// neither an uploaded filename nor a browser field chooses the destination.
func runtimeAuthPiLocation(ctx context.Context, command string) (node, sdk, authPath string, err error) {
	unsupported := errors.New("pi native auth layout is unsupported")
	executable, err := filepath.EvalSymlinks(command)
	if err != nil || filepath.Base(executable) != "cli.js" || filepath.Base(filepath.Dir(executable)) != "bundle" || filepath.Base(filepath.Dir(filepath.Dir(executable))) != "dist" {
		return "", "", "", unsupported
	}
	sdk = filepath.Join(filepath.Dir(filepath.Dir(executable)), "index.js")
	node, err = exec.LookPath("node")
	if err != nil {
		return "", "", "", unsupported
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := commandContextWithProcessGroup(ctx, node, "--input-type=module", "-e", `import {pathToFileURL} from "node:url"; import {join} from "node:path"; const {getAgentDir} = await import(pathToFileURL(process.argv[1]).href); process.stdout.write(JSON.stringify(join(getAgentDir(), "auth.json")));`, sdk)
	cmd.Stderr = io.Discard
	stdout, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		return "", "", "", unsupported
	}
	output, readErr := io.ReadAll(io.LimitReader(stdout, 4097))
	if readErr != nil || len(output) > 4096 {
		cancel()
		cmd.Wait()
		return "", "", "", unsupported
	}
	if cmd.Wait() != nil || json.Unmarshal(output, &authPath) != nil || !filepath.IsAbs(authPath) {
		return "", "", "", unsupported
	}
	return node, sdk, authPath, nil
}

type runtimeAuthVerificationOutcome struct {
	Status string `json:"status"`
	Issue  string `json:"issue,omitempty"`
}

func verifyRuntimeAuthPi(ctx context.Context, node, sdk, authPath, model string) runtimeAuthVerificationOutcome {
	failed := runtimeAuthVerificationOutcome{Status: "error", Issue: "provider_unavailable"}
	parent := ctx
	if parent.Err() != nil {
		return runtimeAuthVerificationOutcome{Status: "error", Issue: "canceled"}
	}
	ctx, cancel := context.WithTimeout(ctx, 31*time.Second)
	defer cancel()
	bridge := `const result=await verifyPiApiKey({sdkEntry:process.argv[1],authPath:process.argv[2],modelId:process.argv[3]}); await new Promise((resolve,reject)=>process.stdout.write(JSON.stringify(result),(error)=>error?reject(error):resolve())); process.exit(0);`
	cmd := commandContextWithProcessGroup(ctx, node, "--input-type=module", "-e", runtimeAuthPiSource+bridge, sdk, authPath, model)
	cmd.Stderr = io.Discard
	cmd.WaitDelay = time.Second
	stdout, err := cmd.StdoutPipe()
	if err != nil || cmd.Start() != nil {
		return failed
	}
	output, readErr := io.ReadAll(io.LimitReader(stdout, 4097))
	if readErr != nil || len(output) > 4096 {
		cancel()
		cmd.Wait()
		return failed
	}
	waitErr := cmd.Wait()
	if ctx.Err() != nil {
		failed.Issue = "verification_timeout"
		if parent.Err() != nil {
			failed.Issue = "canceled"
		}
		return failed
	}
	var result runtimeAuthVerificationOutcome
	if waitErr != nil || json.Unmarshal(output, &result) != nil {
		return failed
	}
	if result.Status != "authenticated" && result.Status != "unauthenticated" && result.Status != "error" {
		return failed
	}
	return result
}
