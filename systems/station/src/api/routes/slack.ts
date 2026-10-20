// Connects and Slack through the pages (admin/mod.rs `route`, admin/edits.rs `put_connect`/`delete_connect`,
// admin/slack.rs): connects added, edited, deleted, reconnected and pointed at a session; Slack apps made and edited
// with a person's configuration token, their installs, new connects from tokens, the token check, the people of the
// connected Slack workspaces, and a viewer saying a Slack user is them. Config edits go through config.json
// (ConfigFile.update); what answers with the overview is given it (`overview`).
import { randomBytes } from "node:crypto";
import { type Answer, type Request, error, json, param, percentDecode } from "../request.ts";
import type { Route } from "../admin.ts";
import type { Viewer } from "../../mesh/credential.ts";
import type { ConfigFile } from "../../ops/config.ts";
import { type Lang, tr } from "../../ops/i18n.ts";
import { log } from "../../ops/log.ts";
import { hubConfig, sameModel } from "../../sessions/config.ts";
import type { Hub } from "../../sessions/hub.ts";
import { bindSingle } from "../../sessions/lifecycle.ts";
import type { Store } from "../../store/store.ts";
import {
  DEFAULT_APP_NAME,
  SLACK_GROUPS,
  SlackApiError,
  type SlackAppEdit,
  type SlackService,
  applySettings,
  appIdOf,
  connectName,
  createAppUrl,
  madeApps,
  type SlackAppMade,
  type SlackParts,
  ownerOfConfigToken,
  rotateConfigToken,
  settingsOf,
  shownIdentity,
  slackAppLinks,
  slackError,
  slackManifest,
  upsertToken,
  withSocketMode,
  configTokens,
} from "../../slack/index.ts";
import { wall } from "../../ops/fibers.ts";

type Json = any;
type Input = Record<string, unknown>;

const segment = (s: string) => percentDecode(s.replace(/\+/g, "%2B"));
const ok = (value: unknown) => json(200, JSON.stringify(value));
class Refused extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/// A request's JSON object (`read_json`): nothing is `{}`, as is anything not an object; more than a megabyte refused.
function input(r: Request): Input {
  if (r.body.length > 1_000_000) throw new Refused(413, "request too large");
  if (r.body.length === 0) return {};
  let value: unknown;
  try {
    value = JSON.parse(r.body.toString("utf8"));
  } catch {
    throw new Refused(400, "invalid JSON");
  }
  return isObject(value) ? (value as Input) : {};
}

const isObject = (v: unknown): v is Record<string, Json> => v !== null && typeof v === "object" && !Array.isArray(v);
/// `Input::str`: a string field, as given.
const str = (v: unknown): string | undefined => (typeof v === "string" ? v : undefined);
/// `Input::text`: JavaScript's String(x ?? "") as serde writes it.
const text = (v: unknown): string => (v === undefined || v === null ? "" : typeof v === "string" ? v : JSON.stringify(v));
/// serde's `Value::get`: a field of an object, nothing of anything else.
const get = (v: unknown, key: string): unknown => (isObject(v) ? v[key] : undefined);

/// Who asks: their id (an email), their name, whether they manage the workspace (access.rs `Viewer`).
const idOf = (v: Viewer) => v.email;
const nameOf = (v: Viewer) => (v.name === "" ? v.email : v.name);
const manages = (v: Viewer) => v.role === "owner" || v.role === "admin";

/// admin/slack.rs `url_encode`: everything but A-Z a-z 0-9 - _ . ~ as %XX.
const urlEncode = (s: string) => [...Buffer.from(s, "utf8")].map((b) => (/[A-Za-z0-9\-_.~]/.test(String.fromCharCode(b)) ? String.fromCharCode(b) : `%${b.toString(16).toUpperCase().padStart(2, "0")}`)).join("");

const colorOk = (color: string) => /^#[0-9a-fA-F]{6}$/.test(color.trim());

/// A connect id from its bot's name: lower case, runs of anything else as one dash.
function connectSlug(name: string): string {
  let out = "";
  for (const c of name.toLowerCase()) {
    if (/^[a-z0-9]$/.test(c)) out += c;
    else if (!out.endsWith("-")) out += "-";
  }
  const slug = [...out.replace(/^-+|-+$/g, "")].slice(0, 32).join("").replace(/-+$/, "");
  return slug === "" ? "slack" : slug;
}

/// A form's edits as serde reads them (`SlackAppEdit`): null when a field has the wrong kind.
function editOf(v: unknown): SlackAppEdit | null {
  if (!isObject(v)) return null;
  const edit: SlackAppEdit = {};
  for (const key of ["name", "displayName", "description", "longDescription", "backgroundColor"] as const) {
    const given = v[key];
    if (given === undefined || given === null) continue;
    if (typeof given !== "string") return null;
    edit[key] = given;
  }
  if (v.groups !== undefined && v.groups !== null) {
    const groups = groupsOf(v.groups);
    if (groups === null) return null;
    edit.groups = groups;
  }
  return edit;
}

/// Groups on and off as serde reads a `BTreeMap<String, bool>`; null when it is not one.
function groupsOf(v: unknown): Record<string, boolean> | null {
  if (!isObject(v)) return null;
  const out: Record<string, boolean> = {};
  for (const [k, on] of Object.entries(v)) {
    if (typeof on !== "boolean") return null;
    out[k] = on;
  }
  return out;
}

/// A field given as a string, trimmed and not empty; null when absent (`given` says whether it was).
function field(object: unknown, key: string): [boolean, string | null] {
  const v = get(object, key);
  if (v === undefined) return [false, null];
  const t = typeof v === "string" ? v.trim() : "";
  return [true, t === "" ? null : t];
}

export type SlackRoutesDeps = {
  /// The connects' connections and Slack's app API (src/slack/index.ts `makeConnections`).
  slack: SlackParts;
  config: ConfigFile;
  data: string;
  store: Store;
  /// The hub, for pointing a single-session connect at a session and for the efforts a model takes; none while the
  /// station starts.
  hub: () => Hub | undefined;
  /// The overview as the viewer sees it, in their language: what the edits answer with.
  overview: (viewer: Viewer, lang: Lang) => unknown;
  /// Where the station is in still.fail cloud, when it is in a workspace: apps made here are installed through Slack's
  /// OAuth and come back by still.fail cloud's page.
  place?: () => { origin: string; workspace: string; station: string } | null;
  /// Slack's app API as the pages use it (default: Slack itself, with the configuration tokens in config.json).
  apps?: SlackService;
  /// Tells the pages the overview changed (an install is in).
  overviewChanged?: () => void;
};

export const routes = (deps: SlackRoutesDeps): Route[] => {
  const { slack, config, store } = deps;
  const apps: SlackService = deps.apps ?? slack.apps;
  /// App ids learned from bot tokens, by connect.
  const appIds = new Map<string, string>();

  const answer = (f: (r: Request, args: string[]) => Promise<Answer> | Answer) => async (r: Request, args: string[]) => {
    try {
      return await f(r, args);
    } catch (e) {
      if (e instanceof Refused) return error(e.status, e.message);
      log.error("admin", "admin request failed", { path: r.path, error: (e as Error).message });
      return error(500, (e as Error).message);
    }
  };
  const overview = async (r: Request) => await deps.overview(r.viewer, r.lang);
  /// Edits the config for the viewer (said in the log as `what`); its refusals are the asker's (400).
  const change = (r: Request, what: string, f: (raw: Json) => void) => {
    try {
      config.update(f);
    } catch (e) {
      throw new Refused(400, (e as Error).message);
    }
    log.info("admin", "config changed from the admin page", { what, by: idOf(r.viewer) });
  };
  /// `save`: an edit, answered with the overview as it is then.
  const save = async (r: Request, what: string, f: (raw: Json) => void) => {
    change(r, what, f);
    return overview(r);
  };
  const raw = () => config.raw();
  const connectsRaw = (raw: Json): Json[] => (Array.isArray(raw.connects) ? raw.connects : (raw.connects = []));

  /// A Slack app made here and not connected yet, by its app id or its install's state.
  const madeApp = (key: string): SlackAppMade | undefined => madeApps(raw()).find((a) => a.appId === key || a.oauth?.state === key);

  /// The workspace an app is made in: the one asked for, or the only one the viewer has.
  const teamFor = (i: Input, r: Request): string => {
    const by = idOf(r.viewer);
    const teams = configTokens(raw()).filter((t) => t.by === by);
    if (teams.length === 0) throw new Refused(400, tr(r.lang, "station.slackApp.noConfigToken"));
    const team = str(i.team) ?? (teams.length === 1 ? teams[0]!.teamId : undefined);
    if (team === undefined || !teams.some((t) => t.teamId === team)) throw new Refused(400, tr(r.lang, "station.slackApp.chooseTeam"));
    return team;
  };

  /// The Slack workspace a connect's app is in, as last seen.
  const teamOf = (id: string) => slack.connects().find((c) => c.id === id)?.team?.id ?? null;

  const appId = async (id: string): Promise<string | null> => {
    const connect = slack.connects().find((c) => c.id === id);
    if (!connect) throw new Refused(404, `unknown connect ${id}`);
    if (connect.appId !== null) return connect.appId;
    const known = appIds.get(id);
    if (known !== undefined) return known;
    if (connect.botToken === "") return null;
    const app = await appIdOf(slack.client, connect.botToken);
    appIds.set(id, app);
    return app;
  };

  /// Sets an app's icon (an image's data URL); what went wrong, in words, or null.
  const setIcon = async (by: string, app: string, icon: string, lang: Lang): Promise<string | null> => {
    const at = icon.indexOf(";base64,");
    const [head, data] = at >= 0 ? [icon.slice(0, at), icon.slice(at + 8)] : ["data:image/png", ""];
    const mime = head.startsWith("data:") && head.slice(5).startsWith("image/") ? head.slice(5) : "image/png";
    const bytes = /^[A-Za-z0-9+/]*={0,2}$/.test(data) && data.length % 4 === 0 ? Buffer.from(data, "base64") : Buffer.alloc(0);
    try {
      await apps.setIcon(by, app, bytes, mime);
      return null;
    } catch (e) {
      if (e instanceof SlackApiError && e.code === "app_not_owned_by_manager_app") return tr(lang, "station.slackApp.iconNotOwned");
      return slackError(e, lang);
    }
  };

  /// A connect added or edited (edits.rs `put_connect`): tokens left blank stay, its runtime stays as it was made.
  const putConnect = (r: Request, id: string, i: Input) =>
    save(r, `connect ${id}`, (raw) => {
      const lang = r.lang;
      const connects = connectsRaw(raw);
      const existing = connects.find((c) => c?.id === id);
      const slackIn = i.slack;
      const old: Json = isObject(existing?.slack) ? existing.slack : {};
      const token = (key: string, stored: unknown) => field(slackIn, key)[1] ?? (typeof stored === "string" ? stored : null);
      const appToken = token("appToken", old.appToken);
      const botToken = token("botToken", old.botToken);
      const bind = i.bind;
      const oldBind: Json = existing && isObject(existing.bind) ? existing.bind : null;
      const kept = (key: string) => {
        const [given, value] = field(bind, key);
        return given ? value : typeof oldBind?.[key] === "string" ? (oldBind[key] as string) : null;
      };
      const model = kept("model");
      const effort = kept("effort");
      const profile = kept("profile");
      // A connect's runtime is chosen when it is made: its sessions and their history belong to it.
      const given = get(bind, "runtime");
      let runtime: "claude" | "codex";
      if (oldBind !== null) runtime = oldBind.runtime === "codex" ? "codex" : "claude";
      else if (given !== undefined) {
        if (given !== "claude" && given !== "codex") throw new Error(`unknown runtime ${typeof given === "string" ? given : JSON.stringify(given)}`);
        runtime = given;
      } else throw new Error("runtime is required");
      // The profile its sessions keep to (null: the pool's pick), one that runs its runtime and model.
      if (profile !== null) {
        const p = hubConfig(raw, deps.data).profiles.find((p) => p.id === profile);
        if (!p || !p.runtimes.includes(runtime)) throw new Error(tr(lang, "station.profile.cannotRun", { profile, runtime }));
        if (model !== null) {
          const rawProfile = (Array.isArray(raw.profiles) ? raw.profiles : []).find((x: Json) => x?.id === profile);
          const models: unknown[] = Array.isArray(rawProfile?.models) ? rawProfile.models : [];
          if (!models.some((m) => typeof m === "string" && sameModel(m, model))) {
            throw new Error(tr(lang, "station.profile.modelOff", { profile: typeof rawProfile?.name === "string" ? rawProfile.name : profile, model }));
          }
        }
      }
      if (effort !== null && ["model", "effort", "profile"].some((f) => get(bind, f) !== undefined)) {
        const allowed = deps.hub()?.accounts.modelEfforts(runtime, model, profile);
        if (allowed !== undefined && !allowed.includes(effort)) {
          throw new Error(tr(lang, "station.profile.efforts", { runtime, efforts: allowed.join(tr(lang, "station.list.separator")) }));
        }
      }
      // Who it is in Slack: given with new tokens (as they were verified), else as last seen.
      const givenTeam = get(slackIn, "team");
      const teamOk = isObject(givenTeam) && (givenTeam.id === undefined || typeof givenTeam.id === "string") && (givenTeam.name === undefined || givenTeam.name === null || typeof givenTeam.name === "string");
      let team: Json = null;
      let botName: string | null = null;
      let botImage: string | null = null;
      if (teamOk) {
        team = { id: givenTeam.id ?? "", ...(typeof givenTeam.name === "string" ? { name: givenTeam.name } : {}) };
        botName = str(get(slackIn, "botName")) ?? null;
        const image = str(get(slackIn, "botImage"));
        botImage = image !== undefined && image !== "" ? image : null;
      } else if (old.team !== undefined && old.team !== null) {
        team = old.team;
        botName = typeof old.botName === "string" ? old.botName : null;
        botImage = typeof old.botImage === "string" ? old.botImage : null;
      }
      const oldAppId = typeof old.appId === "string" ? old.appId : null;
      const anySlack = appToken !== null || botToken !== null || oldAppId !== null || team !== null;
      const next: Json = { id };
      const owner = ownerOf(existing?.createdBy ?? null, i.owner, r.viewer, lang);
      next.enabled = typeof i.enabled === "boolean" ? i.enabled : typeof existing?.enabled === "boolean" ? existing.enabled : true;
      next.kind = str(i.kind) ?? (typeof existing?.kind === "string" ? existing.kind : "slack");
      next.mode = i.mode === "multi-session" || i.mode === "single-session" ? i.mode : existing?.mode === "multi-session" || existing?.mode === "single-session" ? existing.mode : "multi-session";
      next.requireMention = typeof i.requireMention === "boolean" ? i.requireMention : typeof existing?.requireMention === "boolean" ? existing.requireMention : true;
      if (anySlack) {
        const s: Json = {};
        if (appToken !== null) s.appToken = appToken;
        if (botToken !== null) s.botToken = botToken;
        if (oldAppId !== null) s.appId = oldAppId;
        if (team !== null) s.team = team;
        if (botName !== null) s.botName = botName;
        if (botImage !== null) s.botImage = botImage;
        next.slack = s;
      }
      if (owner !== null) next.createdBy = owner;
      const b: Json = { runtime };
      if (model !== null) b.model = model;
      if (effort !== null) b.effort = effort;
      if (profile !== null) b.profile = profile;
      next.bind = b;
      // What this station does not know of it is kept.
      const known = new Set(["id", "enabled", "kind", "mode", "requireMention", "slack", "createdBy", "bind"]);
      for (const [k, v] of Object.entries(existing ?? {})) if (!known.has(k)) next[k] = v;
      const at = connects.findIndex((c) => c?.id === id);
      if (at >= 0) connects[at] = next;
      else connects.push(next);
    });

  /// A new Slack connect from its tokens: named as its bot is in Slack, with an id made from that name.
  const newSlackConnect = async (r: Request, i: Input) => {
    const lang = r.lang;
    const slackIn = i.slack;
    const t = (k: string) => (str(get(slackIn, k)) ?? "").trim();
    const appToken = t("appToken");
    // Installed through Slack's OAuth: its bot token is here already.
    const install = str(get(slackIn, "install"));
    const installed = install !== undefined ? madeApp(install)?.oauth : undefined;
    if (install !== undefined && installed?.botToken === undefined) throw new Refused(400, tr(lang, "station.slackApp.notInstalled"));
    const botToken = installed?.botToken ?? t("botToken");
    const [identity, errors] = await apps.verifyTokens(appToken, botToken, lang);
    if (identity === null || errors.length > 0) {
      throw new Refused(400, errors.length === 0 ? tr(lang, "station.slackApp.badToken") : errors.join(tr(lang, "station.list.semicolon")));
    }
    const givenApp = str(get(slackIn, "appId"));
    const appGiven = givenApp !== undefined && givenApp !== "" ? givenApp : null;
    const made = install !== undefined ? madeApp(install) : appGiven !== null ? madeApp(appGiven) : undefined;
    // An app made here, being connected: Socket Mode and its events on in its manifest (Slack has it off until then).
    if (made) {
      try {
        const current = await apps.exportManifest(made.by, made.appId);
        await apps.updateManifest(made.by, made.appId, withSocketMode(current, true));
      } catch (e) {
        throw new Refused(400, tr(lang, "station.slackApp.socketModeFailed", { error: slackError(e, lang) }));
      }
    }
    const name = identity.botName === "" ? DEFAULT_APP_NAME : identity.botName;
    const taken = new Set(slack.connects().map((c) => c.id));
    const base = connectSlug(name);
    let id = base;
    for (let n = 2; taken.has(id); n++) id = `${base}-${n}`;
    const app = made?.appId ?? appGiven;
    const slackFields: Json = { appToken, botToken, team: { id: identity.teamId, name: identity.team }, botName: identity.botName };
    if (identity.botImage !== null) slackFields.botImage = identity.botImage;
    let shown = await putConnect(r, id, { ...i, kind: "slack", slack: slackFields });
    // Its app is connected now: no longer one waiting.
    if (made) {
      config.update((raw) => {
        raw.slackApps = (Array.isArray(raw.slackApps) ? raw.slackApps : []).filter((a: Json) => a?.appId !== made.appId);
      });
    }
    if (app === null) return ok({ id, overview: shown });
    shown = await save(r, `slack app of ${id}`, (raw) => {
      for (const c of connectsRaw(raw).filter((c) => c?.id === id)) c.slack = { ...(isObject(c.slack) ? c.slack : {}), appId: app };
    });
    return ok({ id, overview: shown });
  };

  /// Makes a Slack app for a connect to come. On a station in still.fail cloud it is made to be installed through
  /// Slack's OAuth: `install` is the link, and Slack sends the person back to still.fail cloud's page, which hands the
  /// code to this station (POST /slack/installs), which takes the bot token for it. Elsewhere the token is copied.
  const makeSlackApp = async (r: Request, i: Input) => {
    const lang = r.lang;
    const by = idOf(r.viewer);
    const team = teamFor(i, r);
    const edit = editOf(i.settings) ?? {};
    const trimmed = edit.name?.trim();
    const name = trimmed !== undefined && trimmed !== "" ? trimmed : DEFAULT_APP_NAME;
    if (edit.backgroundColor !== undefined && edit.backgroundColor !== "" && !colorOk(edit.backgroundColor)) throw new Refused(400, tr(lang, "station.slackApp.badColor"));
    edit.name = name;
    const place = deps.place?.() ?? null;
    const redirect = place !== null ? `${place.origin}/slack/installed` : null;
    const manifest = applySettings(slackManifest(name, null, redirect), edit);
    // Made without Socket Mode: its maker turns it on in Slack, which makes the app-level token with its scope picked;
    // the connect that takes it puts Socket Mode and its events in.
    let app;
    try {
      app = await apps.createApp(by, team, withSocketMode(manifest, false));
    } catch (e) {
      throw new Refused(400, tr(lang, "station.slackApp.createFailed", { error: slackError(e, lang) }));
    }
    const icon = str(i.icon);
    const iconError = icon !== undefined && icon !== "" ? await setIcon(by, app.appId, icon, lang) : null;
    // Kept here until a connect takes it: the pages show it, and it can be installed and finished any time later.
    const shownName = typeof manifest.display_information?.name === "string" ? manifest.display_information.name : name;
    const made: SlackAppMade = { appId: app.appId, name: shownName, teamId: team, by, created: wall.now() };
    if (redirect !== null && place !== null && app.clientId !== "" && app.clientSecret !== "") {
      // Which station it is for goes with it, so still.fail cloud's page knows where to hand the code.
      const state = `${place.workspace}/${place.station}~${randomBytes(16).toString("hex")}`;
      const scopes: string[] = (manifest.oauth_config?.scopes?.bot ?? []).filter((s: unknown) => typeof s === "string");
      const install = `https://slack.com/oauth/v2/authorize?client_id=${urlEncode(app.clientId)}&scope=${urlEncode(scopes.join(","))}&redirect_uri=${urlEncode(redirect)}&state=${urlEncode(state)}`;
      made.oauth = { state, clientId: app.clientId, clientSecret: app.clientSecret, redirectUri: redirect, install };
    }
    change(r, `slack app ${app.appId}`, (raw) => {
      raw.slackApps = [...(Array.isArray(raw.slackApps) ? raw.slackApps : []), made];
    });
    return ok({ appId: app.appId, iconError });
  };

  /// GET /connects/:id/slack-app: the connect's app as its settings form shows it.
  const slackApp = async (r: Request, id: string) => {
    const groups = SLACK_GROUPS.map((g) => g.id);
    let app: string | null;
    try {
      app = await appId(id);
    } catch (e) {
      if (e instanceof Refused) throw e;
      // The bot token no longer works, so the app cannot be looked up; the Slack section says why.
      return ok({ state: "no_app", appId: null, links: null, settings: null, groups, error: slackError(e, r.lang) });
    }
    if (app === null) return ok({ state: "no_app", appId: null, links: null, settings: null, groups });
    const links = slackAppLinks(app, teamOf(id));
    const by = idOf(r.viewer);
    if (!apps.configured(by)) return ok({ state: "no_config_token", appId: app, links, settings: null, groups });
    try {
      const manifest = await apps.exportManifest(by, app);
      return ok({ state: "ok", appId: app, links, settings: settingsOf(manifest), groups });
    } catch (e) {
      return ok({ state: "error", appId: app, links, settings: null, groups, error: slackError(e, r.lang) });
    }
  };

  /// PUT /connects/:id/slack-app: the app's name, description, colour, icon and permissions changed in its manifest.
  const putSlackApp = async (r: Request, id: string, i: Input) => {
    const lang = r.lang;
    const app = await appId(id);
    if (app === null) throw new Refused(400, tr(lang, "station.slackApp.none"));
    const edit: SlackAppEdit = {};
    for (const key of ["name", "displayName", "description", "longDescription", "backgroundColor"] as const) {
      const v = str(i[key]);
      if (v !== undefined) edit[key] = v;
    }
    const groups = groupsOf(i.groups);
    if (groups !== null) edit.groups = groups;
    if (edit.name !== undefined && edit.name.trim() === "") throw new Refused(400, tr(lang, "station.slackApp.nameEmpty"));
    if (edit.backgroundColor !== undefined && edit.backgroundColor !== "" && !colorOk(edit.backgroundColor)) throw new Refused(400, tr(lang, "station.slackApp.badColor"));
    const by = idOf(r.viewer);
    let permissionsUpdated: boolean;
    try {
      const current = await apps.exportManifest(by, app);
      permissionsUpdated = await apps.updateManifest(by, app, applySettings(current, edit));
    } catch (e) {
      throw new Refused(400, tr(lang, "station.slackApp.updateRefused", { error: slackError(e, lang) }));
    }
    const icon = str(i.icon);
    const iconError = icon !== undefined && icon !== "" ? await setIcon(by, app, icon, lang) : null;
    // Its name here is its bot's in Slack: read again now, and once more when Slack has surely taken the change.
    if (edit.name !== undefined || edit.displayName !== undefined) {
      const refresh = () => slack.refreshIdentity(id).catch((e) => log.warn("slack", "slack identity refresh failed", { connect: id, error: (e as Error).message }));
      void refresh();
      wall.after(8_000, () => void refresh());
    }
    log.info("slack", "slack app updated from the admin page", { connect: id, app, permissionsUpdated, by });
    return ok({ permissionsUpdated, iconError, links: slackAppLinks(app, teamOf(id)) });
  };

  /// POST /connects/:id/slack-app: the connect's Slack app made with the configuration token, so only installing it is
  /// left to do in Slack.
  const createSlackApp = async (r: Request, id: string, i: Input) => {
    const lang = r.lang;
    const connect = slack.connects().find((c) => c.id === id);
    if (!connect) throw new Refused(404, `unknown connect ${id}`);
    if ((await appId(id)) !== null) throw new Refused(400, tr(lang, "station.slackApp.already"));
    const given = str(i.name)?.trim();
    const name = given !== undefined && given !== "" ? given : connectName(connect);
    const team = teamFor(i, r);
    let app;
    try {
      app = await apps.createApp(idOf(r.viewer), team, slackManifest(name));
    } catch (e) {
      throw new Refused(400, tr(lang, "station.slackApp.createFailed", { error: slackError(e, lang) }));
    }
    change(r, `create slack app for ${id}`, (raw) => {
      for (const c of connectsRaw(raw).filter((c) => c?.id === id)) c.slack = { ...(isObject(c.slack) ? c.slack : {}), appId: app.appId };
    });
    return ok({ appId: app.appId, links: slackAppLinks(app.appId, team) });
  };

  /// POST /slack/config-tokens: a Slack workspace the station makes apps in, by its configuration token's refresh token.
  const addConfigToken = async (r: Request, i: Input) => {
    const lang = r.lang;
    const refresh = text(i.refreshToken).trim();
    if (!refresh.startsWith("xoxe-")) throw new Refused(400, tr(lang, "station.slackApp.badRefreshToken"));
    let token;
    try {
      token = await rotateConfigToken(slack.client, refresh);
    } catch (e) {
      throw new Refused(400, tr(lang, "station.slackApp.tokenRefused", { error: (e as Error).message }));
    }
    const owner = await ownerOfConfigToken(slack.client, token.accessToken);
    const by = idOf(r.viewer);
    const made = { accessToken: token.accessToken, refreshToken: token.refreshToken, expiresAt: token.expiresAt, teamId: token.teamId, by, ...(owner !== null ? { owner } : {}) };
    config.update((raw) => {
      raw.slackConfigTokens = upsertToken(Array.isArray(raw.slackConfigTokens) ? raw.slackConfigTokens : [], made);
    });
    log.info("slack", "slack configuration token added", { team: token.teamId, by });
    return ok({ teamId: token.teamId, overview: await overview(r) });
  };

  /// POST /slack/installs: an app made here was installed; its code becomes its bot token, kept for the connect that
  /// takes it.
  const installed = async (r: Request, i: Input) => {
    const lang = r.lang;
    const state = text(i.state);
    const oauth = madeApp(state)?.oauth;
    if (state === "" || oauth === undefined || oauth.state !== state) throw new Refused(400, tr(lang, "station.slackApp.installNotOurs"));
    let botToken: string;
    let team: string | null;
    try {
      [botToken, team] = await apps.exchangeInstallCode(oauth.clientId, oauth.clientSecret, text(i.code), oauth.redirectUri);
    } catch (e) {
      throw new Refused(400, tr(lang, "station.slackApp.installFailed", { error: slackError(e, lang) }));
    }
    config.update((raw) => {
      for (const app of Array.isArray(raw.slackApps) ? raw.slackApps : []) {
        if (!isObject(app?.oauth) || app.oauth.state !== state) continue;
        app.oauth.botToken = botToken;
        if (team !== null) app.oauth.installedTeam = team;
        else delete app.oauth.installedTeam;
      }
    });
    log.info("slack", "slack app installed", { state, team });
    deps.overviewChanged?.();
    return ok({ team });
  };

  /// POST /slack/verify: the tokens as given, blank ones falling back to the stored ones of `connect`, so replacing one
  /// token can be checked alone; an app installed through Slack's OAuth (`install`) checks with the bot token it got.
  const verify = async (r: Request, i: Input) => {
    const connectId = str(i.connect);
    const stored = connectId !== undefined ? slack.connects().find((c) => c.id === connectId) : undefined;
    const pick = (key: string, kept: string | undefined) => {
      const given = str(i[key])?.trim();
      return given !== undefined && given !== "" ? given : (kept ?? "");
    };
    const appToken = pick("appToken", stored?.appToken);
    const install = str(i.install);
    const fromInstall = install !== undefined ? madeApp(install)?.oauth?.botToken : undefined;
    const botToken = fromInstall ?? pick("botToken", stored?.botToken);
    const [identity, errors] = await apps.verifyTokens(appToken, botToken, r.lang);
    return ok({ identity: identity === null ? null : shownIdentity(identity), errors });
  };

  /// GET /slack/people: the people of the Slack workspaces this station's connects are in, once each by email, for
  /// adding them to the still.fail workspace: bots and deactivated accounts left out; guests marked. Needs
  /// users:read.email to see emails.
  const people = async (r: Request) => {
    const found: Json[] = [];
    const seen = new Set<string>();
    const errors: string[] = [];
    for (const connect of slack.connects()) {
      const chat = slack.chat(connect.id);
      if (!chat?.api) continue;
      let cursor = "";
      for (;;) {
        const params: Record<string, Json> = { limit: 200 };
        if (cursor !== "") params.cursor = cursor;
        let page: Json;
        try {
          page = await chat.api("users.list", params);
        } catch (e) {
          errors.push(tr(r.lang, "station.list.labeled", { name: connectName(connect), note: (e as Error).message }));
          break;
        }
        for (const m of Array.isArray(page?.members) ? page.members : []) {
          const email = (typeof m?.profile?.email === "string" ? m.profile.email : "").toLowerCase();
          const skip = m?.is_bot === true || m?.deleted === true || m?.id === "USLACKBOT" || email === "";
          if (skip || seen.has(email)) continue;
          seen.add(email);
          const name = [m?.profile?.real_name, m?.real_name, m?.name].find((n) => typeof n === "string" && n !== "") ?? email;
          found.push({
            email,
            name,
            image: typeof m?.profile?.image_72 === "string" ? m.profile.image_72 : null,
            guest: m?.is_restricted === true || m?.is_ultra_restricted === true,
            team: connect.team?.name ?? null,
          });
        }
        const next = page?.response_metadata?.next_cursor;
        cursor = typeof next === "string" ? next : "";
        if (cursor === "") break;
      }
    }
    found.sort((a, b) => Number(a.guest) - Number(b.guest) || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    return ok({ people: found, errors });
  };

  const hub = () => {
    const h = deps.hub();
    if (!h) throw new Refused(503, "station starting");
    return h;
  };

  return [
    { method: "POST", pattern: /^\/connects$/, handle: answer((r) => newSlackConnect(r, input(r))) },
    { method: "POST", pattern: /^\/slack\/apps$/, handle: answer((r) => makeSlackApp(r, input(r))) },
    { method: "POST", pattern: /^\/slack\/installs$/, handle: answer((r) => installed(r, input(r))) },
    { method: "POST", pattern: /^\/slack\/verify$/, handle: answer((r) => verify(r, input(r))) },
    { method: "POST", pattern: /^\/slack\/config-tokens$/, handle: answer((r) => addConfigToken(r, input(r))) },
    { method: "GET", pattern: /^\/slack\/people$/, handle: answer((r) => people(r)) },
    {
      method: "GET",
      pattern: /^\/slack\/create-app-url$/,
      handle: answer((r) => {
        const name = param(r, "name")?.trim();
        if (name === undefined || name === "") throw new Refused(400, "name is required");
        return ok({ url: createAppUrl(name) });
      }),
    },
    // "这是我" / "不是我" on a Slack user's name: taken at the viewer's word.
    ...["PUT", "DELETE"].map(
      (method): Route => ({
        method,
        pattern: /^\/*me\/+slack\/+([^/]+)\/*$/,
        handle: answer(async (r, [user]) => {
          store.setSlackIdentity(idOf(r.viewer), segment(user!), method === "PUT");
          return ok(await overview(r));
        }),
      }),
    ),
    // A made app dropped from the waiting ones (it stays in Slack); only its maker's to drop.
    {
      method: "DELETE",
      pattern: /^\/*slack\/+apps\/+([^/]+)(?:\/.*)?$/,
      handle: answer(async (r, [a]) => {
        const app = segment(a!);
        const by = idOf(r.viewer);
        if (!madeApps(raw()).some((m) => m.appId === app && m.by === by)) throw new Refused(404, tr(r.lang, "station.slackApp.notFound"));
        return ok(
          await save(r, `slack app ${app} dropped`, (raw) => {
            raw.slackApps = (Array.isArray(raw.slackApps) ? raw.slackApps : []).filter((m: Json) => m?.appId !== app);
          }),
        );
      }),
    },
    {
      method: "DELETE",
      pattern: /^\/*slack\/+config-tokens\/+([^/]+)(?:\/.*)?$/,
      handle: answer(async (r, [t]) => {
        const team = segment(t!);
        const by = idOf(r.viewer);
        return ok(
          await save(r, "slack configuration token removed", (raw) => {
            raw.slackConfigTokens = (Array.isArray(raw.slackConfigTokens) ? raw.slackConfigTokens : []).filter((x: Json) => x?.by !== by || x?.teamId !== team);
          }),
        );
      }),
    },
    { method: "PUT", pattern: /^\/*connects\/+([^/]+)\/*$/, handle: answer(async (r, [id]) => ok(await putConnect(r, segment(id!), input(r)))) },
    {
      method: "DELETE",
      pattern: /^\/*connects\/+([^/]+)\/*$/,
      handle: answer(async (r, [raw]) => {
        const id = segment(raw!);
        return ok(
          await save(r, `delete connect ${id}`, (raw) => {
            const connects = connectsRaw(raw);
            if (!connects.some((c) => c?.id === id)) throw new Error(`unknown connect ${id}`);
            raw.connects = connects.filter((c) => c?.id !== id);
          }),
        );
      }),
    },
    {
      method: "POST",
      pattern: /^\/*connects\/+([^/]+)\/+session(?:\/.*)?$/,
      handle: answer((r, [raw]) => {
        const id = segment(raw!);
        const i = input(r);
        const target = str(i.session);
        const key = bindSingle(hub(), id, target !== undefined && target !== "" ? target : null, str(i.title) ?? null, idOf(r.viewer));
        log.info("admin", "single-session binding changed from the admin page", { connect: id, session: key, by: idOf(r.viewer) });
        return ok({ session: key });
      }),
    },
    {
      method: "POST",
      pattern: /^\/*connects\/+([^/]+)\/+reconnect(?:\/.*)?$/,
      handle: answer(async (r, [raw]) => {
        const id = segment(raw!);
        await slack.reconcile();
        // Who the bot is, read again: a name changed in Slack shows now.
        await slack.refreshIdentity(id).catch((e) => log.warn("slack", "slack identity refresh failed", { connect: id, error: (e as Error).message }));
        return ok({ ok: true });
      }),
    },
    { method: "GET", pattern: /^\/*connects\/+([^/]+)\/+slack-app(?:\/.*)?$/, handle: answer((r, [id]) => slackApp(r, segment(id!))) },
    { method: "PUT", pattern: /^\/*connects\/+([^/]+)\/+slack-app(?:\/.*)?$/, handle: answer((r, [id]) => putSlackApp(r, segment(id!), input(r))) },
    { method: "POST", pattern: /^\/*connects\/+([^/]+)\/+slack-app(?:\/.*)?$/, handle: answer((r, [id]) => createSlackApp(r, segment(id!), input(r))) },
  ];
};

/// Who a connect belongs to (edits.rs `owner_of`): whoever added it, unless `requested` hands it to someone else. Only
/// a workspace owner or admin, or the current owner, may do that.
function ownerOf(current: Json, requested: unknown, viewer: Viewer, lang: Lang): { id: string; name: string } | null {
  if (requested === undefined) return isObject(current) ? (current as { id: string; name: string }) : { id: idOf(viewer), name: nameOf(viewer) };
  const given = get(requested, "id");
  const id = typeof given === "string" ? given.trim().toLowerCase() : "";
  const at = id.indexOf("@");
  const [a, b] = at >= 0 ? [id.slice(0, at), id.slice(at + 1)] : ["", ""];
  const email = at >= 0 && a !== "" && b !== "" && !/\s/.test(id) && !b.includes("@");
  if (id !== "local" && !email) throw new Error(tr(lang, "station.connect.ownerEmail"));
  if (!manages(viewer) && (!isObject(current) || current.id !== idOf(viewer))) throw new Error(tr(lang, "station.connect.ownerWho"));
  const name = get(requested, "name");
  return { id, name: typeof name === "string" ? [...name].slice(0, 120).join("") : id };
}
