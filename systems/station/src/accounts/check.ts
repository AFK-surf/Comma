// What config.json must be before it is taken (the Rust station's config.rs `parse_config`'s refusals, and the shapes its
// serde types insist on): `checkConfig` throws what is wrong, in the same words. Set as `ConfigFile.check`, so an edit
// that does not pass is not written. What parse_config fills in is read elsewhere (sessions/config.ts `hubConfig`).
import { accessKinds, needsKey, runtimesFor } from "./profiles.ts";
import { accessKind, keyOf } from "../agents/profiles.ts";
import { cleanEndpoint, endpoints, find } from "../agents/providers.ts";
import { fallbackEfforts } from "../sessions/pool.ts";
import { meshPort } from "../mesh/native.ts";

const CREDENTIALS = ["subscription", "api_key", "machine", "env"];
const RUNTIMES = ["claude", "codex"];
const MODES = ["multi-session", "single-session"];

/// config.rs `id_ok`: a lowercase letter or digit, then those and dashes.
export const idOk = (id: string) => /^[a-z0-9][a-z0-9-]*$/.test(id);

const isObject = (v: unknown): v is Record<string, any> => v !== null && typeof v === "object" && !Array.isArray(v);

/// serde's words for a value of the wrong kind (without the line and column it adds).
function variant(value: unknown, expected: string[], what: string) {
  if (typeof value !== "string") throw new Error(`invalid type: ${describe(value)}, expected ${what}`);
  if (!expected.includes(value)) {
    const list = expected.map((e) => `\`${e}\``);
    const said = list.length === 2 ? `${list[0]} or ${list[1]}` : `one of ${list.join(", ")}`;
    throw new Error(`unknown variant \`${value}\`, expected ${said}`);
  }
}

function describe(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "string") return `string ${JSON.stringify(value)}`;
  if (typeof value === "number") return Number.isInteger(value) ? `integer \`${value}\`` : `floating point \`${value}\``;
  if (typeof value === "boolean") return `boolean \`${value}\``;
  return Array.isArray(value) ? "sequence" : "map";
}

const optional = (v: unknown, type: "string" | "boolean" | "number", what: string) => {
  if (v !== undefined && v !== null && typeof v !== type) throw new Error(`invalid type: ${describe(v)}, expected ${what}`);
};

/// Throws what parse_config refuses in `raw` (config.json as written); `data` is the data directory homes are under.
export function checkConfig(raw: any, _data: string): void {
  if (!isObject(raw)) throw new Error(`invalid type: ${describe(raw)}, expected struct RawConfig`);
  // The computer's access (src/device/access.ts).
  if (raw.tools !== undefined && raw.tools !== null) {
    if (!isObject(raw.tools)) throw new Error(`invalid type: ${describe(raw.tools)}, expected struct RawTools`);
    if (raw.tools.access !== undefined && !["off", "read", "full"].includes(raw.tools.access)) throw new Error("tools.access: one of off, read, full");
    optional(raw.tools.computer, "boolean", "a boolean");
    optional(raw.tools.owner, "string", "a string");
  }
  const profiles = raw.profiles ?? [];
  if (!Array.isArray(profiles)) throw new Error(`invalid type: ${describe(profiles)}, expected a sequence`);
  const profileIds: string[] = [];
  for (const p of profiles) {
    if (!isObject(p)) throw new Error(`invalid type: ${describe(p)}, expected struct RawProfile`);
    if (typeof p.id !== "string") throw new Error(p.id === undefined ? "missing field `id`" : `invalid type: ${describe(p.id)}, expected a string`);
    if (typeof p.home !== "string") throw new Error(p.home === undefined ? "missing field `home`" : `invalid type: ${describe(p.home)}, expected a string`);
    if (p.runtime !== undefined && p.runtime !== null) variant(p.runtime, RUNTIMES, "a runtime");
    // The Profile Comma keeps too (systems/profiles model.rs), with the station's fields beside it.
    // Neither said: only the variables it sets (`env`).
    if (p.credential !== undefined && p.credential !== null) variant(p.credential, CREDENTIALS, "a credential");
    for (const f of ["source", "key", "endpoint", "protocol"]) optional(p[f], "string", "a string");
    for (const f of ["background_on_message", "fast"]) optional(p[f], "boolean", "a boolean");
    optional(p.name, "string", "a string");
    optional(p.model, "string", "a string");
    for (const f of ["models", "disabled_models"]) {
      if (p[f] !== undefined && p[f] !== null && (!Array.isArray(p[f]) || p[f].some((m: unknown) => typeof m !== "string"))) {
        throw new Error("invalid type: expected a sequence of strings");
      }
    }
    if (p.env !== undefined && p.env !== null && (!isObject(p.env) || Object.values(p.env).some((v) => typeof v !== "string"))) {
      throw new Error("invalid type: expected a map of strings");
    }

    if (!idOk(p.id)) throw new Error(`profile id ${JSON.stringify(p.id)}: use lowercase letters, digits and dashes`);
    if (p.home === "") throw new Error(`profile ${p.id}: home is required`);
    const kind = accessKind(p as any);
    const runtimes = runtimesFor(p);
    const provider = typeof p.source === "string" && p.source !== "" ? p.source : undefined;
    const endpoint = typeof p.endpoint === "string" ? cleanEndpoint(p.endpoint) : undefined;
    const protocol = typeof p.protocol === "string" && p.protocol !== "" ? p.protocol : undefined;
    if (kind === "api-provider") {
      // Which runtimes it runs follows from its provider; one that runs neither still serves the automatic decisions.
      const source = provider === undefined ? undefined : find(provider);
      if (!source) throw new Error(`profile ${p.id}: api-provider needs a known provider`);
      if (endpoints(source, endpoint, protocol) === undefined) throw new Error(`profile ${p.id}: ${source.name} needs an endpoint address`);
    } else if (runtimes.length === 0) {
      throw new Error(`profile ${p.id}: ${kind} needs a runtime (claude or codex)`);
    }
    if (!runtimes.every((r) => accessKinds(r).includes(kind as any))) throw new Error(`profile ${p.id}: ${runtimes.join("/")} cannot use access ${kind}`);
    if (needsKey(kind as any, provider) && keyOf(p as any) === "") throw new Error(`profile ${p.id}: access ${kind} needs a key`);
    profileIds.push(p.id);
  }
  unique("profile", profileIds);

  const connects = raw.connects ?? [];
  if (!Array.isArray(connects)) throw new Error(`invalid type: ${describe(connects)}, expected a sequence`);
  const connectIds: string[] = [];
  for (const c of connects) {
    if (!isObject(c)) throw new Error(`invalid type: ${describe(c)}, expected struct RawConnect`);
    if (typeof c.id !== "string") throw new Error(c.id === undefined ? "missing field `id`" : `invalid type: ${describe(c.id)}, expected a string`);
    if (!isObject(c.bind)) throw new Error(c.bind === undefined ? "missing field `bind`" : `invalid type: ${describe(c.bind)}, expected struct RawBind`);
    if (c.bind.runtime === undefined) throw new Error("missing field `runtime`");
    variant(c.bind.runtime, RUNTIMES, "a runtime");
    if (c.mode !== undefined && c.mode !== null) variant(c.mode, MODES, "a connect mode");
    for (const f of ["model", "effort", "profile"]) optional(c.bind[f], "string", "a string");

    if (!idOk(c.id)) throw new Error(`connect id ${JSON.stringify(c.id)}: use lowercase letters, digits and dashes`);
    const kind = c.kind ?? "slack";
    if (kind !== "slack") throw new Error(`connect ${c.id}: unknown kind ${kind}`);
    const runtime: string = c.bind.runtime;
    const effort = c.bind.effort;
    if (typeof effort === "string" && effort !== "") {
      // Codex reports an open set of levels per model, after sign-in: a newly advertised level is not refused.
      const legacy = fallbackEfforts(runtime);
      if (runtime !== "codex" && !legacy.includes(effort)) throw new Error(`connect ${c.id}: ${runtime} has no effort ${effort}; use ${legacy.join(", ")}`);
    }
    connectIds.push(c.id);
  }
  unique("connect", connectIds);

  meshPort(raw);

  // decision.rs AutomaticDecisions (deny_unknown_fields).
  const decisions = raw.automaticDecisions;
  if (decisions !== undefined && decisions !== null) checkAutomaticDecisions(decisions);
}

/// decision.rs `AutomaticDecisions` as serde reads it: `{completion?: {enabled?: bool, model?: string|null}}`, nothing
/// else. Throws when it is not.
export function checkAutomaticDecisions(value: unknown) {
  if (!isObject(value)) throw new Error(`invalid type: ${describe(value)}, expected struct AutomaticDecisions`);
  for (const k of Object.keys(value)) if (k !== "completion") throw new Error(`unknown field \`${k}\`, expected \`completion\``);
  const rule = value.completion;
  if (rule === undefined) return;
  if (!isObject(rule)) throw new Error(`invalid type: ${describe(rule)}, expected struct DecisionRule`);
  for (const k of Object.keys(rule)) if (k !== "enabled" && k !== "model") throw new Error(`unknown field \`${k}\`, expected \`enabled\` or \`model\``);
  if (rule.enabled !== undefined) optional(rule.enabled, "boolean", "a boolean");
  if (rule.enabled === null) throw new Error("invalid type: null, expected a boolean");
  optional(rule.model, "string", "a string");
}

function unique(kind: string, ids: string[]) {
  const seen = new Set<string>();
  for (const id of ids) {
    if (seen.has(id)) throw new Error(`duplicate ${kind} id ${id}`);
    seen.add(id);
  }
}
