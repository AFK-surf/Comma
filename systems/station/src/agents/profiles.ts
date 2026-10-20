// A station profile is the Profile Comma's AccountPool keeps too (systems/profiles model.rs: `source`, `credential`,
// `runtime`, `endpoint`, `protocol`, `models`, `disabled_models`, `model`, `env`), stored as it is in config.json, with
// what only a station has beside it: `home` (where its runtime keeps its login), `key` (an API key's), `share` (lent or
// borrowed between the workspace's stations), `fast`, `background_on_message`. How it reaches its runtimes is the
// Profiles' logic too. The admin API still speaks of an access kind (`accessOf`, `storedAccess`): the pages' words.
import type { Profile } from "./runtime.ts";
import { cleanEndpoint, endpoints, find, type Endpoints, type Source } from "./providers.ts";
import { profilesNative, unified } from "./unified.ts";

export type AccessKind = "subscription" | "opencode-go" | "anthropic-api" | "env" | "api-provider";
export type Runtime = "claude" | "codex";
export type Credential = "subscription" | "api_key" | "machine" | "env";

/// Which provider an API-provider profile is on, and where.
export type Via = { provider?: string; endpoint?: string; protocol?: string };

/// A profile's access as the admin API says it (the pages' words).
export type ProfileAccess = { kind?: AccessKind; key?: string; provider?: string; endpoint?: string; protocol?: string };

const str = (v: unknown): string | undefined => (typeof v === "string" && v !== "" ? v : undefined);
const PROTOCOLS = ["chat_completions", "responses", "anthropic"];

/// The access kind a profile is, in the pages' words: an Anthropic or OpenCode Go key is a kind of its own (they came
/// before the list of sources), another key is a provider's.
export function accessKind(p: Profile): AccessKind {
  switch (p.credential ?? "env") {
    case "subscription":
    case "machine":
      return "subscription";
    case "api_key":
      return p.source === "opencode-go" ? "opencode-go" : p.source === "anthropic" ? "anthropic-api" : "api-provider";
    default:
      return "env";
  }
}
/// Its API key, when it has one.
export const keyOf = (p: Profile): string => String(p.key ?? "").trim();
/// Its model, when it names one.
export const profileModel = (p: Profile): string | undefined => str(p.model);
/// On the machine's own login (machine_logins.rs).
export const isMachine = (p: Profile): boolean => p.credential === "machine";
export const profileFast = (p: Profile): boolean => p.fast === true;
export const profileVia = (p: Profile): Via =>
  accessKind(p) === "api-provider"
    ? { provider: str(p.source), endpoint: typeof p.endpoint === "string" ? cleanEndpoint(p.endpoint) : undefined, protocol: str(p.protocol) }
    : {};

/// A profile's access as the admin API says it.
export function accessOf(p: Profile): ProfileAccess {
  const kind = accessKind(p);
  const out: ProfileAccess = { kind };
  const key = keyOf(p);
  if (key !== "") out.key = key;
  if (kind === "api-provider") Object.assign(out, Object.fromEntries(Object.entries(profileVia(p)).filter(([, v]) => v !== undefined)));
  return out;
}

/// What a profile stores for an access kind as the admin API says it (`machine`: on the machine's own login): its
/// credential, source and where it speaks, and its key.
export function storedAccess(runtime: unknown, kind: string, via: Via & { key?: string }, machine = false): Record<string, unknown> {
  const rt = runtime === "claude" || runtime === "codex" ? runtime : undefined;
  const key = str(via.key?.trim());
  switch (kind) {
    case "subscription":
      return { credential: machine ? "machine" : "subscription", source: rt ?? "claude" };
    case "opencode-go":
      return { credential: "api_key", source: "opencode-go", ...(key ? { key } : {}) };
    case "anthropic-api":
      return { credential: "api_key", source: "anthropic", ...(key ? { key } : {}) };
    case "api-provider":
      return {
        credential: "api_key",
        source: via.provider ?? "",
        ...(via.endpoint !== undefined ? { endpoint: via.endpoint } : {}),
        ...(via.protocol !== undefined && PROTOCOLS.includes(via.protocol) ? { protocol: via.protocol } : {}),
        ...(key ? { key } : {}),
      };
    default:
      return { credential: "env", source: "custom" };
  }
}

/// The fields `storedAccess` sets: replaced together when a profile's access changes.
export const ACCESS_FIELDS = ["credential", "source", "endpoint", "protocol", "key"];

/// The source of an API-provider profile and where it speaks, when it names a known provider (and a usable address).
export function apiSource(via: Via): [Source, Endpoints] | undefined {
  const source = via.provider === undefined ? undefined : find(via.provider);
  const at = source && endpoints(source, via.endpoint, via.protocol);
  return source && at ? [source, at] : undefined;
}

export const OPENCODE = "https://opencode.ai/zen/go";

/// A profile made of an access kind alone (a check before a profile is made, the decisions' caller).
const bare = (runtime: Runtime, kind: AccessKind, model: string | undefined, via: Via): Profile =>
  ({ id: "", home: "", runtime, ...storedAccess(runtime, kind, via), ...(model !== undefined ? { model } : {}) }) as Profile;

/// Environment an access kind needs (systems/profiles runtime.rs). `{route}` is expanded per session later.
export function accessEnv(runtime: Runtime, kind: AccessKind, key: string, model: string | undefined, via: Via): Record<string, string> {
  return JSON.parse(profilesNative().profileRuntimeConfig(JSON.stringify(unified(bare(runtime, kind, model, via))), runtime, key)).env;
}

/// Codex reads its model provider from config; the station passes it as `-c` overrides when it starts the app-server,
/// so config.toml stays the user's. Values are TOML. In key order.
export function codexOverrides(kind: AccessKind, model: string | undefined, via: Via): [string, string][] {
  return JSON.parse(profilesNative().profileCodexOverrides(JSON.stringify(unified(bare("codex", kind, model, via)))));
}

/// The runtimes an account runs: an OpenCode Go key both, an Anthropic key Claude Code, a provider's what it speaks; a
/// subscription (and custom variables) the runtime it was made for.
export function profileRuntimes(p: Profile): Runtime[] {
  return profilesNative().profileRuntimes(JSON.stringify(unified(p))) as Runtime[];
}

/// The environment for a profile's processes of `runtime`: none for a runtime it does not run. In values, `{route}` is
/// still to be expanded.
export function profileEnv(p: Profile, runtime: Runtime): Record<string, string> {
  return JSON.parse(profilesNative().profileRuntimeConfig(JSON.stringify(unified(p)), runtime, keyOf(p))).env;
}

export const expandRoute = (env: Record<string, string>, route: string): Record<string, string> =>
  Object.fromEntries(Object.entries(env).map(([k, v]) => [k, v.replaceAll("{route}", route)]));

/// Both names of a variable the station sets for what it starts (former.rs `both`): the new one, and the old one for
/// scripts written against it.
export const bothNames = (name: string): [string, string] => [`STILLFAIL_${name}`, `EMBER_${name}`];
