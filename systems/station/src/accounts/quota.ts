// How much of a profile's allowance is used, where the provider says; what it says is read by the Profiles' logic
// (systems/profiles quota.rs), as Comma's account-proxy answers are:
// - OpenCode Go: GET /zen/go/v1/usage (rolling, weekly and monthly windows);
// - ChatGPT subscription (Codex): the app-server's account/rateLimits/read;
// - Claude subscription: Claude Code's OAuth usage endpoint (what /usage shows), with the token Claude Code keeps in the
//   profile's home (renewed first when about to run out, and once more when the provider says it is not good: oauth.ts);
// - Anthropic API keys and other providers bill per use and have no allowance to show.
import { readFileSync } from "node:fs";
import { loadMesh } from "../mesh/native.ts";
import { codexAuthFile, type Env } from "../agents/machine-logins.ts";
import type { Profile } from "../sessions/config.ts";
import { accessKind, isMachine, keyOf } from "../agents/profiles.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { claudeOAuthToken } from "./oauth.ts";
import { type ProfileQuota, type QuotaWindow, URLS, type Urls } from "./profiles.ts";

type Json = any;

const TIMEOUT_MS = 15_000;

/// `checkedAt`: stamped by whoever keeps it, on its clock (Accounts, MachineLogins).
const quota = (state: string, windows: QuotaWindow[], detail: string | null): ProfileQuota => ({ state, windows, detail, checkedAt: 0 });

/// transcript.rs parse_iso: an RFC 3339 time, as epoch ms.
function parseIso(text: string): number | null {
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}/.test(text)) return null;
  const ms = Date.parse(text);
  return Number.isNaN(ms) ? null : ms;
}

/// A time as a provider gives it: epoch seconds or ms, or an ISO string.
export function at(value: unknown): number | null {
  if (typeof value === "number") return value > 1e12 ? Math.trunc(value) : Math.trunc(value * 1000);
  if (typeof value === "string" && value !== "") return parseIso(value);
  return null;
}

/// A window's label, as the pages show it (systems/profiles quota.rs `window_label`). Labels are not translated: cores
/// read them (client/core-ts/src/format.ts `window_mark`).
export function windowLabel(minutes: number | null | undefined, fallback: string): string {
  return loadMesh().profileWindowLabel(typeof minutes === "number" ? minutes : null, fallback);
}

/// A provider's answer, read by the Profiles' logic (systems/profiles quota.rs), as the station's allowance.
function shared(provider: string, body: Json): ProfileQuota & { windows: QuotaWindow[] } {
  const q = JSON.parse(loadMesh().profileQuota(provider, JSON.stringify(body ?? null), 0));
  const out: ProfileQuota = {
    state: "ok",
    windows: (q.windows as Json[]).map((w) => ({ label: w.label, usedPercent: w.used_percent, resetsAt: w.resets_at ?? null, minutes: w.minutes ?? null })),
    detail: null,
    checkedAt: 0,
  };
  if (q.credits) out.credits = { hasCredits: q.credits.has_credits, unlimited: q.credits.unlimited, balance: q.credits.balance ?? null };
  if (q.reset_credits) out.resetCount = q.reset_credits.available_count;
  return out;
}

/// Whether a provider's words refuse an account itself, not a token or a request.
export function blocked(text: string): boolean {
  const lower = text.toLowerCase();
  return ["on hold", "restricted", "suspend", "disabled", "deactivat", "banned", "terminated", "violat"].some((w) => lower.includes(w));
}

/// A provider's error body, in a line when it has one.
function message(text: string): string | undefined {
  let body: Json;
  try {
    body = JSON.parse(text);
  } catch {
    return undefined;
  }
  const error = body?.error;
  let said: unknown = typeof error === "string" ? error : error !== undefined && error !== null ? error?.message : undefined;
  if (typeof said !== "string") said = typeof body?.detail === "string" ? body.detail : typeof body?.message === "string" ? body.message : undefined;
  return typeof said === "string" ? [...said].slice(0, 200).join("") : undefined;
}

/// A provider's refusal as a quota: the account refused (blocked), or its sign-in no longer good.
async function refused(provider: string, response: Response, lang: Lang): Promise<ProfileQuota> {
  const status = response.status;
  let text = "";
  try {
    text = [...(await response.text())].slice(0, 500).join("");
  } catch {}
  if (blocked(text) || status === 403) {
    const said = message(text);
    const detail = said !== undefined ? tr(lang, "station.quota.refusedSaying", { provider, status, said }) : tr(lang, "station.quota.refused", { provider, status });
    return quota("blocked", [], detail);
  }
  if (status === 401) return quota("unavailable", [], tr(lang, "station.quota.signInExpired"));
  return quota("unavailable", [], tr(lang, "station.quota.providerStatus", { provider, status }));
}

const get = (url: string, headers: Record<string, string>) => fetch(url, { headers, signal: AbortSignal.timeout(TIMEOUT_MS) });

async function opencode(urls: Urls, key: string, lang: Lang): Promise<ProfileQuota> {
  const response = await get(`${urls.opencode}/v1/usage`, { authorization: `Bearer ${key}` });
  if (!response.ok) throw new Error(tr(lang, "station.quota.providerStatus", { provider: "OpenCode Go ", status: response.status }));
  return shared("opencode-go", await response.json());
}

/// A Claude subscription's allowance with its token; asked again once with a renewed token when the provider says the
/// token is not good. `home`: the profile's (null: the machine's own login).
export async function claudeWithRefresh(env: Env, home: string | null, urls: Urls = URLS, lang: Lang = stationLang()): Promise<ProfileQuota> {
  const [token] = await claudeOAuthToken(env, home, null, urls.claudeToken, lang);
  const [first, unauthorized] = await claudeUsageResponse(urls.anthropic, token, lang);
  if (!unauthorized) return first;
  const [renewed] = await claudeOAuthToken(env, home, token, urls.claudeToken, lang);
  return (await claudeUsageResponse(urls.anthropic, renewed, lang))[0];
}

/// A Claude subscription's allowance, by its access token: what /usage shows.
export async function claudeUsage(base: string, token: string, lang: Lang = stationLang()): Promise<ProfileQuota> {
  return (await claudeUsageResponse(base, token, lang))[0];
}

async function claudeUsageResponse(base: string, token: string, lang: Lang): Promise<[ProfileQuota, boolean]> {
  const response = await get(`${base}/api/oauth/usage`, { authorization: `Bearer ${token}`, "anthropic-beta": "oauth-2025-04-20" });
  if (!response.ok) return [await refused("Anthropic ", response, lang), response.status === 401];
  return [shared("claude", await response.json()), false];
}

/// The windows of the app-server's account/rateLimits/read.
export function codexWindows(result: Json): QuotaWindow[] {
  return shared("codex", result).windows;
}

/// A ChatGPT subscription's allowance as the app-server reports it.
export function codexQuota(result: Json, lang: Lang = stationLang()): ProfileQuota {
  const q = shared("codex", result);
  return q.windows.length === 0 && q.credits === undefined && q.resetCount === undefined ? quota("unavailable", [], tr(lang, "station.quota.chatgptNoWindows")) : q;
}

/// Reaches a profile's codex app-server for its account/rateLimits/read.
export type CodexRateLimits = (profile: Profile) => Promise<Json>;

function failed(error: unknown): ProfileQuota {
  const detail = error instanceof Error ? error.message : String(error);
  return quota(blocked(detail) ? "blocked" : "unavailable", [], detail);
}

/// Asks the provider. `codexRateLimits` reaches the profile's codex app-server; `env` is the station's (for a machine
/// profile's login). Never throws: what went wrong is an unavailable (or blocked) allowance.
export async function checkQuota(profile: Profile, env: Env, codexRateLimits: CodexRateLimits | undefined, urls: Urls = URLS, lang: Lang = stationLang()): Promise<ProfileQuota> {
  try {
    const kind = accessKind(profile);
    if (kind === "opencode-go") return await opencode(urls, keyOf(profile), lang);
    if (kind === "anthropic-api" || kind === "api-provider") return quota("unsupported", [], tr(lang, "station.quota.payAsYouGo"));
    if (kind === "env") return quota("unsupported", [], tr(lang, "station.quota.envUnsupported"));
    if (profile.runtime === "claude") return await claudeWithRefresh(env, isMachine(profile) ? null : profile.home, urls, lang);
    if (!codexRateLimits) throw new Error("no codex app-server to ask");
    return codexQuota(await codexRateLimits(profile), lang);
  } catch (e) {
    return failed(e);
  }
}

/// A ChatGPT subscription's allowance read with the tokens of a Codex auth.json (the machine's own login, which no
/// app-server of the station's runs on): what Codex's /status shows. Null when there is no such file or token.
export async function codexUsage(authFile: string, urls: Urls = URLS, lang: Lang = stationLang()): Promise<ProfileQuota | null> {
  let tokens: Json;
  try {
    tokens = JSON.parse(readFileSync(authFile, "utf8"))?.tokens;
  } catch {
    return null;
  }
  const access = tokens?.access_token;
  if (typeof access !== "string" || access === "") return null;
  const headers: Record<string, string> = { authorization: `Bearer ${access}`, "user-agent": "codex_cli_rs" };
  if (typeof tokens.account_id === "string") headers["chatgpt-account-id"] = tokens.account_id;
  const response = await get(`${urls.chatgpt}/backend-api/wham/usage`, headers);
  if (!response.ok) return refused("ChatGPT ", response, lang);
  return codexQuota(await response.json(), lang);
}

/// The allowance of the machine's own login of a runtime, read without starting anything of the station's. Null when
/// there is nothing to read it with.
export async function machineUsage(runtime: "claude" | "codex", env: Env, urls: Urls = URLS, lang: Lang = stationLang()): Promise<ProfileQuota | null> {
  try {
    return runtime === "codex" ? await codexUsage(codexAuthFile(env), urls, lang) : await claudeWithRefresh(env, null, urls, lang);
  } catch (e) {
    return failed(e);
  }
}
