// Whether a profile works, and what models it offers (the Rust station's profiles.rs: the checks, and which access kinds a
// runtime takes). How an access kind reaches its models (the environment, Codex's overrides) is agents/profiles.ts's.
// The providers' addresses can be pointed elsewhere (`Urls`): tests give fake servers.
import { execFile } from "node:child_process";
import { randomUUID } from "node:crypto";
import type { Env } from "../agents/machine-logins.ts";
import { linkCodexAuth } from "../agents/machine-logins.ts";
import { fileCredentials, takeBack } from "../agents/no-keychain.ts";
import { type AccessKind, OPENCODE, profileRuntimes, type Runtime, type Via } from "../agents/profiles.ts";
import { type Endpoints, endpoints, find, type Source } from "../agents/providers.ts";
import type { Capability } from "../sessions/decision.ts";
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { claudeToken as tokenOf } from "./oauth.ts";
import { platform } from "../platform/index.ts";

type Json = any;

/// Whether a profile works, and what models it offers (profiles.rs ProfileCheck, the same JSON).
export type ProfileCheck = {
  decision?: Capability;
  /// runtime → model → reasoning levels, as the runtime reports them.
  modelEfforts?: Record<string, Record<string, string[]>>;
  /// ok: usable; login: needs a subscription sign-in; failed: the key or login was rejected; unknown.
  state: string;
  detail: string;
  /// Models the account can use, when the provider lists them.
  models: string[] | null;
  checkedAt: number;
};

/// `minutes`: how long the window is, where known (the pool weighs what is left by how soon it is lost).
export type QuotaWindow = { label: string; usedPercent: number; resetsAt: number | null; minutes?: number | null };
export type QuotaCredits = { hasCredits: boolean; unlimited: boolean; balance: string | null };

/// How much of a profile's allowance is used, where the provider says (profiles.rs ProfileQuota).
export type ProfileQuota = {
  /// ok: windows filled; unsupported: nothing to show for this kind; unavailable: could not ask; blocked: the provider
  /// refuses the account.
  state: string;
  windows: QuotaWindow[];
  credits?: QuotaCredits;
  resetCount?: number;
  detail: string | null;
  checkedAt: number;
};

/// Where the providers are: the real ones unless a test says otherwise.
export type Urls = {
  /// OpenCode Go (…/zen/go).
  opencode: string;
  /// Anthropic's API (models, OAuth usage).
  anthropic: string;
  /// ChatGPT's backend (Codex's usage).
  chatgpt: string;
  /// Claude's OAuth token endpoint (renewing a login).
  claudeToken: string;
};

export const URLS: Urls = {
  opencode: OPENCODE,
  anthropic: "https://api.anthropic.com",
  chatgpt: "https://chatgpt.com",
  claudeToken: "https://platform.claude.com/v1/oauth/token",
};

/// The access kinds each runtime can use.
export function accessKinds(runtime: Runtime): AccessKind[] {
  return runtime === "claude" ? ["subscription", "opencode-go", "anthropic-api", "api-provider", "env"] : ["subscription", "opencode-go", "api-provider", "env"];
}

/// Access kinds that authenticate with a key the profile stores.
export const keyed = (kind: AccessKind) => kind === "opencode-go" || kind === "anthropic-api" || kind === "api-provider";

/// Whether a profile on this access must have a key: every keyed one but a provider that works without.
export const needsKey = (kind: AccessKind, provider: string | undefined): boolean =>
  keyed(kind) && !(kind === "api-provider" && provider !== undefined && find(provider)?.keyOptional === true);

/// The runtimes an access kind runs without its provider (profiles.rs runtimes_of): a provider's follow from where it
/// speaks (`runtimesFor`).
export function runtimesOf(kind: AccessKind, runtime: Runtime | undefined): Runtime[] {
  if (kind === "opencode-go") return ["claude", "codex"];
  if (kind === "anthropic-api") return ["claude"];
  if (kind === "api-provider") return [];
  return runtime ? [runtime] : [];
}

/// The runtimes of an access as config.json has it (with its provider and address).
/// The runtimes a stored profile runs (none for one that is not a profile).
export const runtimesFor = (p: Json): Runtime[] => (p && typeof p === "object" && typeof p.id === "string" ? profileRuntimes(p) : []);

/// The command to sign a subscription profile in, run on the station's machine.
export const loginCommand = (runtime: Runtime, home: string) => (runtime === "claude" ? `CLAUDE_CONFIG_DIR=${home} claude auth login` : `CODEX_HOME=${home} codex login`);

/// What a check is given: the account and where it lives.
export type CheckOptions = {
  runtime: Runtime;
  kind: AccessKind;
  key: string;
  /// Of an API-provider profile: which provider and where.
  via: Via;
  home: string;
  /// The station's environment (where a machine login is read, and the CLIs found).
  env: Env;
  /// On the machine's own login.
  machine: boolean;
  /// The machine login's current token, renewed when about to run out (oauth.ts).
  machineToken?: (env: Env) => Promise<{ token: string }>;
  urls?: Urls;
  lang?: Lang;
};

/// `checkedAt`: stamped by whoever keeps it, on its clock (Accounts).
const check = (state: string, detail: string, models: string[] | null): ProfileCheck => ({ state, detail, models, checkedAt: 0 });

async function get(url: string, headers: Record<string, string>): Promise<Response> {
  return fetch(url, { headers, signal: AbortSignal.timeout(15_000) });
}

/// The ids of a `/v1/models` answer.
async function modelIds(response: Response): Promise<string[]> {
  const body: Json = await response.json();
  return Array.isArray(body?.data) ? body.data.map((m: Json) => m?.id).filter((id: unknown): id is string => typeof id === "string") : [];
}

/// Rust's sort of strings (by bytes, which for these ids is by UTF-16 units too).
const sorted = (list: string[]) => list.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0));

/// Runs a runtime's own status command, in `env` only; what it said and how it ended.
function statusOf(command: string, args: string[], env: Env): Promise<{ code: number | null; stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    const r = platform.runnable(command, args, env as NodeJS.ProcessEnv);
    execFile(r.file, r.args, { env: env as NodeJS.ProcessEnv, timeout: 20_000, killSignal: "SIGKILL", windowsVerbatimArguments: r.windowsVerbatimArguments }, (error, stdout, stderr) => {
      if (error && (error as NodeJS.ErrnoException).code === "ENOENT") return reject(new Error(`${command}: ${error.message}`));
      if (error && error.killed) return reject(new Error(`${command} ${args.join(" ")} timed out`));
      const code = error ? (typeof (error as any).code === "number" ? (error as any).code : null) : 0;
      resolve({ code, stdout: String(stdout), stderr: String(stderr) });
    });
  });
}

/// Asks the provider or runtime whether this profile works, and what models it offers (checkProfile). Never throws:
/// what went wrong is a failed check.
export async function checkProfile(o: CheckOptions): Promise<ProfileCheck> {
  const lang = o.lang ?? stationLang();
  try {
    return await checkInner(o, lang);
  } catch (e) {
    return check("failed", tr(lang, "station.profile.checkError", { error: (e as Error).message }), null);
  }
}

async function checkInner(o: CheckOptions, lang: Lang): Promise<ProfileCheck> {
  const urls = o.urls ?? URLS;
  const t = (key: string, args?: Record<string, unknown>) => tr(lang, key, args);
  if (o.kind === "opencode-go") {
    // The model list answers any key; the usage is the key's own, so it is what tells a key that works.
    const usage = await get(`${urls.opencode}/v1/usage`, { authorization: `Bearer ${o.key}` });
    if (!usage.ok) return check("failed", t("station.profile.keyRefused", { provider: "OpenCode Go", status: usage.status }), null);
    const response = await get(`${urls.opencode}/v1/models`, { authorization: `Bearer ${o.key}` });
    if (!response.ok) return check("failed", t("station.profile.modelsUnreadable", { provider: "OpenCode Go", status: response.status }), null);
    const models = sorted(await modelIds(response));
    return check("ok", t("station.profile.works", { n: models.length }), models);
  }
  if (o.kind === "anthropic-api") {
    const response = await get(`${urls.anthropic}/v1/models?limit=100`, { "x-api-key": o.key, "anthropic-version": "2023-06-01" });
    if (!response.ok) return check("failed", t("station.profile.keyRefused", { provider: "Anthropic", status: response.status }), null);
    const models = await modelIds(response);
    return check("ok", t("station.profile.works", { n: models.length }), models);
  }
  if (o.kind === "api-provider") {
    const source = o.via.provider === undefined ? undefined : find(o.via.provider);
    if (!source) return check("failed", t("station.profile.unknownProvider"), null);
    const at = endpoints(source, o.via.endpoint, o.via.protocol);
    if (!at) return check("failed", t("station.profile.addressNeeded"), null);
    return checkApi(source, at, o.key, lang);
  }
  if (o.kind === "subscription" && o.runtime === "claude") {
    const env: Env = { ...o.env, CLAUDE_CONFIG_DIR: o.home };
    let machineToken: string | undefined;
    if (o.machine) {
      if (!o.machineToken) throw new Error("the machine's Claude Code login could not be read");
      machineToken = (await o.machineToken(o.env)).token;
      env.CLAUDE_CODE_OAUTH_TOKEN = machineToken;
    } else {
      await takeBack(o.home);
      fileCredentials(env as Record<string, string>);
    }
    const output = await statusOf("claude", ["auth", "status"], env);
    // Signed out, it says so and exits 1: its answer is still the JSON on stdout.
    if (output.code !== 0 && !(output.code === 1 && output.stdout.trimStart().startsWith("{"))) throw new Error(`Command failed: claude auth status\n${output.stderr}`);
    const status: Json = JSON.parse(output.stdout);
    if (status?.loggedIn !== true) return check("login", t("station.profile.signedOut"), null);
    // What the subscription runs, as Anthropic lists it for the account's own token.
    const token = machineToken ?? tokenOf(o.home);
    const models = token === undefined ? null : await claudeModels(urls, token);
    const detail = [t("station.profile.signedIn"), typeof status.email === "string" ? status.email : "", typeof status.subscriptionType === "string" ? status.subscriptionType : ""].filter((s) => s !== "");
    return check("ok", detail.join(t("station.list.comma")), models);
  }
  if (o.kind === "subscription" && o.runtime === "codex") {
    if (o.machine) linkCodexAuth(o.home, o.env);
    const output = await statusOf("codex", ["login", "status"], { ...o.env, CODEX_HOME: o.home });
    const text = `${output.stdout}${output.stderr}`.trim();
    if (text.toLowerCase().includes("not logged in")) return check("login", t("station.profile.signedOut"), null);
    if (output.code !== 0) throw new Error(`Command failed: codex login status\n${text}`);
    return check("ok", text.split("\n")[0] || t("station.profile.signedIn"), null);
  }
  return check("unknown", t("station.profile.envUnchecked"), null);
}

/// The models a Claude subscription's OAuth token may use; null when Anthropic does not say.
async function claudeModels(urls: Urls, token: string): Promise<string[] | null> {
  try {
    const response = await get(`${urls.anthropic}/v1/models?limit=100`, { authorization: `Bearer ${token}`, "anthropic-version": "2023-06-01", "anthropic-beta": "oauth-2025-04-20" });
    return response.ok ? await modelIds(response) : null;
  } catch {
    return null;
  }
}

/// The header OpenCode's gateways ask of every request: any id will do.
export const opencodeSession = (): [string, string] => ["x-opencode-session", randomUUID()];

/// A provider's key, asked by its model list: a refusal (401/403) is a key that does not work; a provider with no list
/// is not held against it, its key is only unchecked.
async function checkApi(source: Source, at: Endpoints, key: string, lang: Lang): Promise<ProfileCheck> {
  const t = (k: string, args?: Record<string, unknown>) => tr(lang, k, args);
  // A decision-only provider has no model list and nothing to name: its key is tried by the decision probe.
  if (at.decision !== undefined && at.chat === undefined && at.responses === undefined && at.anthropic === undefined) {
    return check("ok", t("station.profile.decisionOnly", { provider: source.name }), null);
  }
  const base = at.chat ?? at.responses ?? (at.anthropic !== undefined ? `${at.anthropic}/v1` : undefined);
  if (base === undefined) return check("failed", t("station.profile.addressNeeded"), null);
  const anthropicOnly = at.chat === undefined && at.responses === undefined;
  const headers: Record<string, string> = {};
  if (key !== "") headers.authorization = `Bearer ${key}`;
  if (anthropicOnly) Object.assign(headers, { "x-api-key": key, "anthropic-version": "2023-06-01" });
  if (source.sessionHeader) {
    const [name, value] = opencodeSession();
    headers[name] = value;
  }
  const response = await get(`${base}/models`, headers);
  if (response.status === 401 || response.status === 403) return check("failed", t("station.profile.keyRefused", { provider: source.name, status: response.status }), null);
  if (!response.ok) return check("unknown", t("station.profile.noModelList", { provider: source.name }), null);
  const models = sorted(await modelIds(response));
  return check("ok", t("station.profile.works", { n: models.length }), models);
}
