import { Aes128Gcm, CipherSuite, DhkemP256HkdfSha256, HkdfSha256 } from "@hpke/core";

/*
 * Browser half of runtime authentication. Secret material is checked here for
 * actionable format feedback, then sealed with HPKE to the target's one-time
 * public key; the native owner decrypts and validates it again. Only the
 * ciphertext, identities and finite actions cross the network.
 */

const domain = "comma.runtime-auth.input.v1";
const encoder = new TextEncoder();
export const maximumPlaintext = 64 * 1024;
const pollIntervalMs = 5_000;
const maximumPolls = 60;

/** Context fields bound into the ciphertext, in the order the native owner reads them. */
const fields = [
  "actor_id",
  "tenant_id",
  "project_id",
  "target_kind",
  "workload_id",
  "device_id",
  "runtime_id",
  "provider",
  "backend",
  "method",
  "form",
  "schema_version",
  "attempt_id",
  "runtime_instance_id",
  "generation",
  "connection_epoch",
  "allocation_id",
  "allocation_generation",
  "native_generation",
  "auth_epoch",
  "sequence",
  "expires_at",
] as const;

export class InvalidMaterialError extends Error {
  constructor() {
    super("invalid_format");
    this.name = "InvalidMaterialError";
  }
}

const invalid = () => new InvalidMaterialError();

type Json = Record<string, unknown>;

export const isObject = (value: unknown): value is Json =>
  value !== null && typeof value === "object" && !Array.isArray(value);

const only = (value: unknown, allowed: readonly string[]): value is Json =>
  isObject(value) && Object.keys(value).every((key) => allowed.includes(key));

const token = (value: unknown): value is string =>
  typeof value === "string" && value.length > 0 && !/[\s\p{Cc}]/u.test(value);

const activePhases = ["awaiting_user", "receiving", "applying", "verifying"];

/** An attempt still waiting on someone; the panel polls it. */
export const activeAttempt = (attempt: unknown): attempt is Json =>
  isObject(attempt) && activePhases.includes(String(attempt.phase));

/** One visible panel polls an active attempt every 5 s, for at most five minutes. */
export function runtimeAuthPollDelay(attempt: unknown, polls: number) {
  return activeAttempt(attempt) &&
    Number.isInteger(polls) &&
    polls >= 0 &&
    polls < maximumPolls
    ? pollIntervalMs
    : null;
}

/** Organization-account changes still in flight are polled the same way. */
export function managedAuthPollDelay(state: unknown, polls: number) {
  return ["installing", "revoking", "account_disabled"].includes(String(state)) &&
    Number.isInteger(polls) &&
    polls >= 0 &&
    polls < maximumPolls
    ? pollIntervalMs
    : null;
}

/**
 * Byte-for-byte counterpart of the native `runtimeAuthInputContext.aad`: each
 * value as a 4-byte big-endian length and its UTF-8 bytes. No JSON
 * canonicalization is involved.
 */
export function runtimeAuthAAD(context: Json) {
  const chunks = [
    domain,
    ...fields.map((field) => {
      const value = context[field];
      if (typeof value !== "string" && !Number.isSafeInteger(value)) throw invalid();
      return String(value);
    }),
  ].map((value) => encoder.encode(value));
  const size = chunks.reduce((total, value) => total + 4 + value.length, 0);
  if (size > 8192) throw invalid();
  const result = new Uint8Array(size);
  const view = new DataView(result.buffer);
  let offset = 0;
  for (const chunk of chunks) {
    view.setUint32(offset, chunk.length);
    result.set(chunk, offset + 4);
    offset += chunk.length + 4;
  }
  return result;
}

const decode = (value: string) =>
  Uint8Array.from(atob(value), (char) => char.charCodeAt(0));
const encode = (value: ArrayBuffer | Uint8Array) => {
  let text = "";
  for (const byte of new Uint8Array(value)) text += String.fromCharCode(byte);
  return btoa(text);
};

/** An `input_begin` or native-login offer: the one-time key and its context. */
export interface RuntimeAuthOffer {
  public_key: string;
  context: Json;
}

export const isOffer = (value: unknown): value is RuntimeAuthOffer =>
  isObject(value) && typeof value.public_key === "string" && isObject(value.context);

/** Seals `plaintext` to the offer; the envelope is the only thing submitted. */
export async function sealRuntimeAuth(offer: RuntimeAuthOffer, plaintext: Uint8Array) {
  const { context } = offer;
  if (
    plaintext.length === 0 ||
    plaintext.length > maximumPlaintext ||
    context.schema_version !== 1 ||
    context.sequence !== 1 ||
    typeof context.expires_at !== "number" ||
    context.expires_at <= Date.now()
  ) {
    throw invalid();
  }
  const suite = new CipherSuite({
    kem: new DhkemP256HkdfSha256(),
    kdf: new HkdfSha256(),
    aead: new Aes128Gcm(),
  });
  const recipientPublicKey = await suite.kem.deserializePublicKey(
    decode(offer.public_key).buffer
  );
  const sender = await suite.createSenderContext({
    recipientPublicKey,
    info: encoder.encode(domain).buffer,
  });
  // Seal a copy that this function owns, then zero it; the caller zeroes its own.
  const owned = plaintext.slice();
  try {
    const ciphertext = await sender.seal(owned.buffer, runtimeAuthAAD(context).buffer);
    return JSON.stringify({ enc: encode(sender.enc), ciphertext: encode(ciphertext) });
  } finally {
    owned.fill(0);
  }
}

const parseJson = (text: string): unknown => {
  try {
    return JSON.parse(text) as unknown;
  } catch {
    throw invalid();
  }
};

const depth = (node: unknown, level = 1): void => {
  if (level > 16) throw invalid();
  if (node && typeof node === "object") {
    for (const child of Object.values(node)) depth(child, level + 1);
  }
};

const claudeScopes = (scopes: unknown) => {
  if (!Array.isArray(scopes) || scopes.length === 0 || scopes.length > 16)
    throw invalid();
  const seen = new Set<string>();
  let inference = false;
  for (const scope of scopes) {
    if (
      !token(scope) ||
      scope.length > 128 ||
      !scope.startsWith("user:") ||
      seen.has(scope)
    )
      throw invalid();
    seen.add(scope);
    inference ||= scope === "user:inference" || scope === "user:ccr_inference";
  }
  return inference;
};

const positiveInteger = (value: unknown) =>
  Number.isSafeInteger(value) && Number(value) > 0;

/**
 * Checks material for `form` and `backend` and returns the bytes to seal.
 * The native owner still performs the authoritative schema validation and
 * rejects duplicate JSON members.
 */
export function runtimeAuthMaterial(form: string, backend: string, text: string) {
  if (encoder.encode(text).length > maximumPlaintext) throw invalid();
  if (form === "api_key") {
    if (!token(text) || text.startsWith("!") || text.startsWith("$")) throw invalid();
    const bytes = encoder.encode(JSON.stringify({ key: text }));
    if (bytes.length > maximumPlaintext) throw invalid();
    return bytes;
  }
  if (form === "authorization_code") {
    if (!token(text) || text.length > 4096) throw invalid();
    return encoder.encode(text);
  }
  let value = parseJson(text);
  depth(value);
  if (!isObject(value)) throw invalid();
  if (form === "pi_auth_entry" && backend === "openrouter") {
    if (!Object.hasOwn(value, "type")) value = value[backend];
    if (
      !only(value, ["type", "key"]) ||
      value.type !== "api_key" ||
      !token(value.key) ||
      /^[!$]/.test(value.key)
    )
      throw invalid();
    return encoder.encode(JSON.stringify(value));
  }
  if (form === "codex_auth_file") {
    if (!only(value, ["auth_mode", "OPENAI_API_KEY", "tokens", "last_refresh"]))
      throw invalid();
    if (backend === "openai") {
      if (
        !only(value, ["auth_mode", "OPENAI_API_KEY"]) ||
        value.auth_mode !== "apikey" ||
        !token(value.OPENAI_API_KEY)
      )
        throw invalid();
    } else if (backend === "chatgpt") {
      const keys = ["id_token", "access_token", "refresh_token", "account_id"];
      const tokens = value.tokens;
      if (
        ![undefined, "chatgpt"].includes(value.auth_mode as string | undefined) ||
        ![undefined, null].includes(value.OPENAI_API_KEY as null | undefined) ||
        !only(tokens, keys) ||
        !keys.every((key) => token(tokens[key])) ||
        typeof value.last_refresh !== "string" ||
        !Number.isFinite(Date.parse(value.last_refresh))
      )
        throw invalid();
    } else throw invalid();
    return encoder.encode(text);
  }
  if (form === "claude_backend_config") {
    const env = value.env;
    if (!only(value, ["env"]) || !isObject(env)) throw invalid();
    if (backend === "anthropic") {
      if (
        !(only(env, ["ANTHROPIC_API_KEY"]) && token(env.ANTHROPIC_API_KEY)) &&
        !(only(env, ["CLAUDE_CODE_OAUTH_TOKEN"]) && token(env.CLAUDE_CODE_OAUTH_TOKEN))
      )
        throw invalid();
    } else if (backend === "openrouter") {
      if (
        !only(env, [
          "ANTHROPIC_BASE_URL",
          "ANTHROPIC_AUTH_TOKEN",
          "ANTHROPIC_API_KEY",
        ]) ||
        env.ANTHROPIC_BASE_URL !== "https://openrouter.ai/api" ||
        !token(env.ANTHROPIC_AUTH_TOKEN) ||
        env.ANTHROPIC_API_KEY !== ""
      )
        throw invalid();
    } else throw invalid();
    return encoder.encode(text);
  }
  if (form === "claude_credentials_file" && backend === "anthropic") {
    const auth = value.claudeAiOauth;
    if (!only(value, ["claudeAiOauth"]) || !isObject(auth)) throw invalid();
    if (
      !only(auth, [
        "accessToken",
        "refreshToken",
        "expiresAt",
        "refreshTokenExpiresAt",
        "scopes",
        "clientId",
        "subscriptionType",
        "rateLimitTier",
      ]) ||
      !token(auth.accessToken) ||
      !token(auth.refreshToken) ||
      !positiveInteger(auth.expiresAt) ||
      (auth.refreshTokenExpiresAt !== undefined &&
        !positiveInteger(auth.refreshTokenExpiresAt)) ||
      !claudeScopes(auth.scopes) ||
      (auth.clientId !== undefined && !token(auth.clientId)) ||
      (auth.subscriptionType !== undefined &&
        auth.subscriptionType !== null &&
        !["max", "pro", "team", "enterprise"].includes(
          String(auth.subscriptionType)
        )) ||
      (auth.rateLimitTier !== undefined &&
        auth.rateLimitTier !== null &&
        (typeof auth.rateLimitTier !== "string" ||
          !/^[a-z][a-z0-9_]{0,63}$/.test(auth.rateLimitTier)))
    )
      throw invalid();
    return encoder.encode(text);
  }
  throw invalid();
}

/** A provider login page the panel may link to: OpenAI's device page or Claude's authorize page. */
export function ceremonyLink(
  ceremony: unknown
): { url: string; claude: boolean } | null {
  if (!isObject(ceremony) || typeof ceremony.verification_url !== "string") return null;
  const url = ceremony.verification_url;
  if (
    url === "https://auth.openai.com/codex/device" &&
    typeof ceremony.user_code === "string"
  )
    return { url, claude: false };
  try {
    const parsed = new URL(url);
    if (
      parsed.protocol === "https:" &&
      parsed.host === "claude.com" &&
      parsed.pathname === "/cai/oauth/authorize" &&
      ceremony.user_code === "" &&
      isObject(ceremony.input)
    )
      return { url, claude: true };
  } catch {
    // Not a URL: no link.
  }
  return null;
}
