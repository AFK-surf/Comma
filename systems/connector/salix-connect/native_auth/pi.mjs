import { constants } from "node:fs";
import { open, unlink, mkdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { randomBytes } from "node:crypto";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const invalid = () => new Error("pi_auth_input_invalid");
const nativeStateLimit = 1024 * 1024;

function validEntry(value) {
  return value && typeof value === "object" && !Array.isArray(value) &&
    Object.keys(value).length === 2 && value.type === "api_key" &&
    typeof value.key === "string" && value.key.length > 0 &&
    Buffer.byteLength(value.key) <= 64 * 1024 && !/[\s\p{Cc}$]/u.test(value.key) &&
    !value.key.startsWith("!");
}

async function readNativeState(path) {
  let file;
  try {
    file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
    const stat = await file.stat();
    if (!stat.isFile() || stat.size > nativeStateLimit) throw invalid();
    const bytes = Buffer.alloc(nativeStateLimit + 1);
    let length = 0;
    while (length < bytes.length) {
      const { bytesRead } = await file.read(bytes, length, bytes.length - length, null);
      if (!bytesRead) break;
      length += bytesRead;
    }
    if (length > nativeStateLimit) throw invalid();
    const value = JSON.parse(bytes.subarray(0, length).toString("utf8"));
    bytes.fill(0);
    if (!value || typeof value !== "object" || Array.isArray(value)) throw invalid();
    return value;
  } catch (error) {
    if (error.code === "ENOENT") return {};
    throw invalid();
  } finally {
    await file?.close();
  }
}

// sdkEntry and authPath come from the target owner, never from uploaded JSON.
// commit keeps the target owner's final fence and rename in one serialized
// section, and returns a save_result even when directory sync fails afterward.
// The SDK's default AuthStorage truncates auth.json in place; its public
// CredentialStore extension point lets this adapter stage an atomic replacement.
export async function savePiApiKey({ sdkEntry, authPath, entry, signal, commit, stagePath }) {
  if (!validEntry(entry)) return { save_result: "not_committed", issue: "invalid_format" };
  const { ModelRuntime } = await import(pathToFileURL(sdkEntry).href);
  const require = createRequire(sdkEntry);
  const lockfile = require("proper-lockfile");
  let saveResult = "not_committed";
  let issue;
  const credentials = {
    async read(provider) {
      if (provider !== "openrouter") return undefined;
      return (await readNativeState(authPath))[provider];
    },
    async list() {
      const value = (await readNativeState(authPath)).openrouter;
      return value ? [{ providerId: "openrouter", type: value.type }] : [];
    },
    async delete() { throw invalid(); },
    async modify(provider, update, options) {
      if (provider !== "openrouter") throw invalid();
      options?.signal?.throwIfAborted();
      await mkdir(dirname(authPath), { recursive: true, mode: 0o700 });
      let compromised = false;
      let release;
      try {
        release = await lockfile.lock(authPath, { realpath: false, retries: 0, stale: 30000, onCompromised: () => { compromised = true; } });
      } catch (error) {
        if (error.code === "ELOCKED") issue = "runtime_busy";
        throw error;
      }
      let temporaryPath;
      try {
        const current = await readNativeState(authPath);
        const next = await update(current.openrouter);
        if (!validEntry(next)) throw invalid();
        options?.signal?.throwIfAborted();
        temporaryPath = stagePath ?? join(dirname(authPath), `.auth-input-${randomBytes(16).toString("hex")}`);
        const file = await open(temporaryPath, "wx", 0o600);
        try {
          await file.writeFile(JSON.stringify({ ...current, openrouter: next }, null, 2));
          await file.sync();
        } finally { await file.close(); }
        options?.signal?.throwIfAborted();
        if (compromised) throw invalid();
        saveResult = "unknown";
        const result = await commit({ temporaryPath, destinationPath: authPath });
        if (!["not_committed", "committed", "unknown"].includes(result?.save_result)) throw invalid();
        saveResult = result.save_result;
        issue = result.issue ?? (compromised ? "storage_lock_changed" : undefined);
        if (saveResult !== "committed") throw invalid();
        return next;
      } finally {
        if (temporaryPath) await unlink(temporaryPath).catch(() => {});
        await release();
      }
    },
  };
  try {
    const runtime = await ModelRuntime.create({ credentials, modelsPath: null, allowModelNetwork: false, refreshOnCreate: false, signal });
    await runtime.login("openrouter", "api_key", {
      signal,
      prompt: async (prompt) => {
        if (prompt.type !== "secret") throw invalid();
        return entry.key;
      },
      notify: () => {},
    });
    return { save_result: saveResult, ...(issue ? { issue } : {}) };
  } catch {
    return { save_result: saveResult, issue: issue ?? (saveResult === "committed" ? "native_refresh_failed" : "storage_operation_failed") };
  }
}

// Verification is a separate, explicit action. The fixed request uses no tools,
// project configuration, environment credential fallback, or client-side retry.
export async function verifyPiApiKey({ sdkEntry, authPath, modelId, signal }) {
  let status;
  const deadline = AbortSignal.any([AbortSignal.timeout(30000), ...(signal ? [signal] : [])]);
  try {
    let entry;
    try { entry = (await readNativeState(authPath)).openrouter; }
    catch { return { status: "error", issue: "invalid_format" }; }
    if (entry === undefined) return { status: "unauthenticated", issue: "credentials_missing" };
    if (!validEntry(entry)) return { status: "error", issue: "invalid_format" };
    const { ModelRuntime } = await import(pathToFileURL(sdkEntry).href);
    const credentials = {
      async read(provider) { return provider === "openrouter" ? entry : undefined; },
      async list() { return [{ providerId: "openrouter", type: "api_key" }]; },
      async modify() { throw invalid(); },
      async delete() { throw invalid(); },
    };
    const runtime = await ModelRuntime.create({ credentials, modelsPath: null, allowModelNetwork: false, refreshOnCreate: false });
    const model = runtime.getModel("openrouter", modelId);
    if (!model) return { status: "error", issue: "verification_model_unavailable" };
    const result = await runtime.complete(model, { messages: [{ role: "user", content: "Reply OK.", timestamp: Date.now() }] }, {
      signal: deadline, maxTokens: 64, timeoutMs: 30000, maxRetries: 0,
      fetch: async (input, init) => {
        const response = await globalThis.fetch(input, init);
        status = response.status;
        return response;
      },
    });
    if (status === 200 && ["stop", "length"].includes(result.stopReason)) return { status: "authenticated" };
  } catch { /* Provider errors may contain secrets; return only fixed issues. */ }
  if (deadline.aborted) return { status: "error", issue: signal?.aborted ? "canceled" : "verification_timeout" };
  if (status === 401) return { status: "unauthenticated", issue: "credentials_rejected" };
  return { status: "error", issue: ({ 402: "quota_exhausted", 403: "permission_denied", 404: "verification_model_unavailable", 429: "rate_limited" })[status] ?? "provider_unavailable" };
}
