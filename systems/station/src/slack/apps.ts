// Managing a connect's Slack app from still.fail (chat/slack_apps.rs): its name, description, colour, icon and
// permissions live in the app's manifest, which Slack lets a workspace member change with an app configuration token.
// The token lasts 12 hours; its refresh token (single use) yields the next pair, so the station keeps both and rotates
// as needed. Permission changes still need a person to approve them in Slack; the station hands them the link. Also the
// manifest a new app starts from, and the link that opens Slack's "create app" page with it filled in.
import { type Lang, stationLang, tr } from "../ops/i18n.ts";
import { log } from "../ops/log.ts";
import { type SlackIdentity, verifySlackTokens } from "./surface.ts";
import { type Params, SlackApiError, SlackClient } from "./web.ts";
import { wall } from "../ops/fibers.ts";

type Json = any;

/// A permission group in plain words: the scopes and events it adds to the app.
export type SlackGroup = { id: string; label: string; description: string; scopes: string[]; events: string[] };

/// Permissions in plain words. Each group adds its scopes and events to the app; "base" is always on.
export const SLACK_GROUPS: SlackGroup[] = [
  {
    id: "base",
    label: "读取和回复消息",
    description: "被 @ 时收到消息，读取所在频道、私信和群聊的消息并回复，干活时在 thread 里显示进度。",
    scopes: [
      "app_mentions:read",
      "chat:write",
      "channels:history",
      "groups:history",
      "im:history",
      "mpim:history",
      "channels:read",
      "groups:read",
      "im:read",
      "mpim:read",
      "users:read",
      "assistant:write",
    ],
    events: ["app_mention", "message.channels", "message.groups", "message.im", "message.mpim"],
  },
  { id: "public", label: "在没加入的公开频道发言", description: "不用先邀请，也能在公开频道回复。", scopes: ["chat:write.public", "channels:join"], events: [] },
  { id: "dm", label: "主动发私信", description: "给人或多人开启私信对话。", scopes: ["im:write", "mpim:write"], events: [] },
  { id: "customize", label: "用别的名字和头像发消息", description: "每条消息可以换显示名和头像。", scopes: ["chat:write.customize"], events: [] },
  {
    id: "files",
    label: "读写文件",
    description: "读取消息里的附件，上传截图、日志等文件。",
    scopes: ["files:read", "files:write", "remote_files:read", "remote_files:write", "remote_files:share"],
    events: ["file_shared"],
  },
  {
    id: "reactions",
    label: "表情回应、置顶和书签",
    description: "用表情标记进度，置顶消息，管理频道书签。",
    scopes: ["reactions:read", "reactions:write", "pins:read", "pins:write", "bookmarks:read", "bookmarks:write"],
    events: ["reaction_added", "reaction_removed"],
  },
  {
    id: "channels",
    label: "创建和管理频道",
    description: "建频道、邀请成员，知道有人加入或新建频道。",
    scopes: ["channels:manage", "groups:write"],
    events: ["member_joined_channel", "channel_created"],
  },
  {
    id: "people",
    label: "查看成员资料",
    description: "读取邮箱、个人资料、用户组、工作区信息和自定义表情。",
    scopes: ["users:read.email", "users.profile:read", "usergroups:read", "team:read", "emoji:read"],
    events: [],
  },
  {
    id: "extras",
    label: "链接预览、提醒和状态",
    description: "展开链接、设置提醒、读取勿扰和通话状态。",
    scopes: ["links:read", "links:write", "reminders:read", "reminders:write", "dnd:read", "calls:read"],
    events: [],
  },
  { id: "canvases", label: "读写 canvas", description: "新建、编辑和读取 canvas 文档，比如把方案、报告写成频道里的 canvas。", scopes: ["canvases:read", "canvases:write"], events: [] },
  { id: "lists", label: "读写列表", description: "新建、编辑和读取 Slack 列表（Lists），比如维护任务清单。", scopes: ["lists:read", "lists:write"], events: [] },
  {
    id: "topics",
    label: "改频道话题和邀请成员",
    description: "设置频道和私信的话题、用途，把人邀请进频道。",
    scopes: ["channels:write.invites", "channels:write.topic", "groups:write.invites", "groups:write.topic", "im:write.topic", "mpim:write.topic"],
    events: [],
  },
  { id: "usergroups", label: "管理用户组和发起通话", description: "建用户组、改成员，发起和更新 Slack 通话。", scopes: ["usergroups:write", "calls:write"], events: [] },
  // Real-time search: of its kinds only these three take a bot token (private channels and DMs need a person's).
  {
    id: "search",
    label: "搜索消息、文件和成员",
    description: "在公开频道里搜消息和文件、按名字找人，回答问题时自己找上下文。",
    scopes: ["search:read.public", "search:read.files", "search:read.users"],
    events: [],
  },
  {
    id: "connect",
    label: "Slack Connect 跨组织频道",
    description: "查看、发出和接受和别的公司共享频道的邀请。",
    scopes: ["conversations.connect:read", "conversations.connect:write", "conversations.connect:manage"],
    events: [],
  },
  {
    id: "more",
    label: "状态、元数据和斜杠命令",
    description: "设置自己的在线状态，读取消息元数据和工作区设置，嵌入视频链接，响应斜杠命令。",
    scopes: ["users:write", "metadata.message:read", "team.preferences:read", "links.embed:write", "commands"],
    events: [],
  },
];

/// The app as the settings form shows it.
export type SlackAppSettings = {
  name: string;
  displayName: string;
  description: string;
  longDescription: string;
  backgroundColor: string;
  groups: Record<string, boolean>;
};

/// The form's edits: what is given changes, the rest stays.
export type SlackAppEdit = {
  name?: string;
  displayName?: string;
  description?: string;
  longDescription?: string;
  backgroundColor?: string;
  groups?: Record<string, boolean>;
};

/// What a Slack app the station makes is called when nobody named it.
export const DEFAULT_APP_NAME = "still.fail";

const at = (value: Json, path: string[]): Json => path.reduce((v, key) => (v !== null && typeof v === "object" && !Array.isArray(v) ? v[key] : undefined), value);
const strings = (value: Json): string[] => (Array.isArray(value) ? value.filter((v): v is string => typeof v === "string") : []);
/// A value as JavaScript's String() writes it, absent as "" (and anything not a string as JSON, as the Rust's).
const text = (value: Json): string => (value === undefined || value === null ? "" : typeof value === "string" ? value : JSON.stringify(value));
const isObject = (v: Json) => v !== null && typeof v === "object" && !Array.isArray(v);
/// The object at `key` of `parent`, made an empty one when missing (`??=`).
function object(parent: Json, key: string): Json {
  if (!isObject(parent[key])) {
    if (parent[key] === undefined || parent[key] === null) parent[key] = {};
    else parent[key] = {};
  }
  return parent[key];
}
const unique = (values: Iterable<string>): string[] => [...new Set(values)];
const knownScopes = () => SLACK_GROUPS.flatMap((g) => g.scopes);
const knownEvents = () => SLACK_GROUPS.flatMap((g) => g.events);

/// The form's view of a manifest. A group counts as on when all its scopes are there.
export function settingsOf(manifest: Json): SlackAppSettings {
  const scopes = strings(at(manifest, ["oauth_config", "scopes", "bot"]));
  const groups: Record<string, boolean> = {};
  for (const g of SLACK_GROUPS) groups[g.id] = g.scopes.every((s) => scopes.includes(s));
  return {
    name: text(at(manifest, ["display_information", "name"])),
    displayName: text(at(manifest, ["features", "bot_user", "display_name"])),
    description: text(at(manifest, ["display_information", "description"])),
    longDescription: text(at(manifest, ["display_information", "long_description"])),
    backgroundColor: text(at(manifest, ["display_information", "background_color"])),
    groups,
  };
}

function setOrDelete(target: Json, key: string, value: string) {
  if (value === "") delete target[key];
  else target[key] = value;
}

/// Applies form edits to a manifest. Turning a group off removes only what no group that stays on needs; scopes the
/// station does not know about are kept.
export function applySettings(manifest: Json, edit: SlackAppEdit): Json {
  const next = isObject(manifest) ? structuredClone(manifest) : {};
  object(next, "display_information");
  const features = object(next, "features");
  if (features.bot_user === undefined || features.bot_user === null) {
    features.bot_user = { display_name: edit.displayName ?? edit.name ?? DEFAULT_APP_NAME, always_online: true };
  }
  // People can always message the bot directly (an app made before this is fixed by any change to it).
  const home = object(features, "app_home");
  home.messages_tab_enabled = true;
  home.messages_tab_read_only_enabled = false;
  if (edit.name !== undefined) next.display_information.name = edit.name.trim();
  if (edit.displayName !== undefined) object(features, "bot_user").display_name = edit.displayName.trim();
  const info = next.display_information;
  if (edit.description !== undefined) setOrDelete(info, "description", edit.description.trim());
  if (edit.longDescription !== undefined) setOrDelete(info, "long_description", edit.longDescription.trim());
  if (edit.backgroundColor !== undefined) setOrDelete(info, "background_color", edit.backgroundColor.trim());
  // Every save puts in what "base" has now (an app made before a scope joined it gets it), and the groups as edited.
  const now = settingsOf(manifest).groups;
  const given = edit.groups ?? {};
  const on = SLACK_GROUPS.filter((g) => g.id === "base" || (given[g.id] ?? now[g.id]));
  const keepScopes = unique(on.flatMap((g) => g.scopes));
  const keepEvents = unique(on.flatMap((g) => g.events));
  const [known, eventsKnown] = [knownScopes(), knownEvents()];
  const scopes = unique([...strings(at(next, ["oauth_config", "scopes", "bot"])).filter((s) => !known.includes(s) || keepScopes.includes(s)), ...keepScopes]);
  const events = unique([...strings(at(next, ["settings", "event_subscriptions", "bot_events"])).filter((e) => !eventsKnown.includes(e) || keepEvents.includes(e)), ...keepEvents]);
  object(object(next, "oauth_config"), "scopes").bot = scopes;
  object(object(next, "settings"), "event_subscriptions").bot_events = events;
  return next;
}

/// The events of the groups on (base always).
const eventsOn = (groups: Record<string, boolean>) => SLACK_GROUPS.filter((g) => g.id === "base" || groups[g.id] === true).flatMap((g) => g.events);

/// A manifest with Socket Mode off or on. Off, it has no events either (Slack asks events of an app without Socket Mode
/// to go to a URL): an app made so lets its maker turn Socket Mode on in Slack, which is where Slack makes the app-level
/// token with its scope already picked. On, its events are those of the groups it has on.
export function withSocketMode(manifest: Json, on: boolean): Json {
  const next = isObject(manifest) ? structuredClone(manifest) : {};
  const settings = object(next, "settings");
  settings.socket_mode_enabled = on;
  if (!on) {
    delete settings.event_subscriptions;
    return next;
  }
  const events = eventsOn(settingsOf(manifest).groups);
  const known = knownEvents();
  const others = strings(at(settings, ["event_subscriptions", "bot_events"])).filter((e) => !known.includes(e));
  object(settings, "event_subscriptions").bot_events = unique([...others, ...events]);
  return next;
}

/// Every bot scope of every permission group.
export const botScopes = (): string[] => unique(knownScopes());

/// The Slack app manifest for a still.fail connect. Every permission group is on, so later features (file upload,
/// reactions as status, co-author lookup) do not need a reinstall; people can turn groups off on the connect page.
/// `redirectUrl`: where Slack sends a person who installed it (still.fail cloud's page that hands the code to the
/// station), so the bot token is not copied by hand.
export function slackManifest(name: string, description: string | null = null, redirectUrl: string | null = null): Json {
  const oauth: Json = { scopes: { bot: botScopes() } };
  if (redirectUrl !== null) oauth.redirect_urls = [redirectUrl];
  return {
    display_information: { name, description: description ?? "Coding agent in your threads (still.fail)", background_color: "#7a2e0e" },
    // The Messages tab lets people message the bot directly; without it Slack says messaging the app is turned off.
    features: {
      bot_user: { display_name: name, always_online: true },
      app_home: { home_tab_enabled: false, messages_tab_enabled: true, messages_tab_read_only_enabled: false },
    },
    oauth_config: oauth,
    settings: {
      event_subscriptions: { bot_events: unique(knownEvents()) },
      interactivity: { is_enabled: false },
      org_deploy_enabled: false,
      socket_mode_enabled: true,
      token_rotation_enabled: false,
    },
  };
}

export const createAppUrl = (name: string) => `https://api.slack.com/apps?new_app=1&manifest_json=${encodeURIComponent(JSON.stringify(slackManifest(name)))}`;

/// An error said in words from the catalog (`key`): in the station's language as an Error's message, and in whoever
/// asked's through `slackError`.
export class SlackWords extends Error {
  readonly key: string;
  constructor(key: string) {
    super(tr(stationLang(), key));
    this.key = key;
  }
}

/// Slack's error codes in words people can act on; other errors as they are.
export function slackError(error: unknown, lang: Lang = stationLang()): string {
  if (error instanceof SlackWords) return tr(lang, error.key);
  if (!(error instanceof SlackApiError)) return (error as Error)?.message ?? String(error);
  const words: Record<string, string> = {
    invalid_auth: "station.slackApi.invalidAuth",
    token_expired: "station.slackApi.tokenExpired",
    invalid_refresh_token: "station.slackApi.invalidRefreshToken",
    not_allowed_token_type: "station.slackApi.notConfigToken",
    app_not_found: "station.slackApi.appNotFound",
    invalid_manifest: "station.slackApi.invalidManifest",
  };
  const known = words[error.code] !== undefined ? tr(lang, words[error.code]!) : error.code;
  const details = Array.isArray(error.details)
    ? error.details.map((d: Json) => `${text(d?.pointer)} ${text(d?.message)}`.trim()).join(tr(lang, "station.list.semicolon"))
    : "";
  if (details === "") return known;
  if (known === "") return details;
  return tr(lang, "station.slackApi.withDetails", { error: known, details });
}

/// An installation's code (from Slack's redirect) exchanged for its bot token, with the workspace it went into.
export async function exchangeInstallCode(client: SlackClient, clientId: string, clientSecret: string, code: string, redirectUri: string): Promise<[string, string | null]> {
  const data = await client.app("oauth.v2.access", null, [
    ["client_id", clientId],
    ["client_secret", clientSecret],
    ["code", code],
    ["redirect_uri", redirectUri],
  ]);
  const team = at(data, ["team", "name"]);
  return [text(data.access_token), typeof team === "string" && team !== "" ? team : null];
}

/// A configuration token's next pair, not yet anyone's.
export type RotatedToken = { accessToken: string; refreshToken: string; expiresAt: number; teamId: string };

/// Exchanges a refresh token for a fresh pair. The old refresh token stops working.
export async function rotateConfigToken(client: SlackClient, refreshToken: string): Promise<RotatedToken> {
  const data = await client.app("tooling.tokens.rotate", null, [["refresh_token", refreshToken.trim()]]);
  return {
    accessToken: text(data.token),
    refreshToken: text(data.refresh_token),
    expiresAt: (Number.isSafeInteger(data.exp) ? data.exp : 0) * 1000,
    teamId: text(data.team_id),
  };
}

/// Which app a bot token belongs to.
export async function appIdOf(client: SlackClient, botToken: string): Promise<string> {
  const auth = await client.app("auth.test", botToken, []);
  const bot = await client.app("bots.info", botToken, [["bot", text(auth.bot_id)]]);
  return text(at(bot, ["bot", "app_id"]));
}

/// Pages in Slack's app settings a person may need.
export type SlackAppLinks = { settings: string; install: string; appToken: string; oauth: string };

export function slackAppLinks(appId: string, teamId: string | null): SlackAppLinks {
  // Slack keeps an app's settings under its workspace (app.slack.com/app-settings/<team>/<app>/<page>); without the
  // workspace, its list of apps is where to find it.
  if (teamId === null) {
    const apps = "https://api.slack.com/apps";
    return { settings: apps, install: apps, appToken: apps, oauth: apps };
  }
  const base = `https://app.slack.com/app-settings/${teamId}/${appId}`;
  // An app-level token is made from the Socket Mode page: there Slack has its scope (connections:write) already picked.
  return { settings: base, install: `${base}/install-on-team`, appToken: `${base}/socket-mode`, oauth: `${base}/oauth` };
}

/// Whose a configuration token is, and where, as Slack shows them (read when it is added): what tells tokens apart.
export type ConfigTokenOwner = { team: string; teamDomain: string | null; teamIcon: string | null; user: string; email: string | null; image: string | null };

/// A Slack app configuration token, a person's own (`by`), for one Slack workspace: config.json `slackConfigTokens`.
export type ConfigToken = { accessToken: string; refreshToken: string; expiresAt: number; teamId: string; by: string; owner?: ConfigTokenOwner };

/// Who a configuration token belongs to and in which workspace, as Slack shows them; null if Slack will not say.
export async function ownerOfConfigToken(client: SlackClient, accessToken: string): Promise<ConfigTokenOwner | null> {
  let auth: Json;
  try {
    auth = await client.app("auth.test", accessToken, []);
  } catch {
    return null;
  }
  const [user, team] = await Promise.all([
    client.app("users.info", accessToken, [["user", text(auth.user_id)]]).then((d) => d?.user ?? null, () => null),
    client.app("team.info", accessToken, []).then((d) => d?.team ?? null, () => null),
  ]);
  const some = (v: Json) => (typeof v === "string" && v !== "" ? v : null);
  return {
    team: some(team?.name) ?? text(auth.team),
    teamDomain: some(team?.domain),
    teamIcon: some(at(team, ["icon", "image_68"])),
    user: some(at(user, ["profile", "display_name"])) ?? some(user?.real_name) ?? text(auth.user),
    email: some(at(user, ["profile", "email"])),
    image: some(at(user, ["profile", "image_48"])),
  };
}

/// The tokens with this one in, in place of its person's old one for the workspace (an owner it lacks kept).
export function upsertToken(tokens: ConfigToken[], token: ConfigToken): ConfigToken[] {
  const out = [...tokens];
  const at = out.findIndex((t) => t.by === token.by && t.teamId === token.teamId);
  if (at < 0) out.push(token);
  else {
    const owner = token.owner ?? out[at]!.owner;
    const next: ConfigToken = { ...token };
    if (owner !== undefined) next.owner = owner;
    else delete next.owner;
    out[at] = next;
  }
  return out;
}

/// A new app's id and its OAuth credentials (Slack gives them only when it is made).
export type CreatedApp = { appId: string; clientId: string; clientSecret: string };

/// What the pages need of Slack beyond a connect's own connection (admin/mod.rs `SlackService`): its app API with the
/// viewer's configuration token, an install's code exchanged, and tokens checked. SlackApps is Slack itself.
export interface SlackService {
  configured(by: string): boolean;
  exportManifest(by: string, appId: string): Promise<Json>;
  /// Whether Slack wants permissions approved again.
  updateManifest(by: string, appId: string, manifest: Json): Promise<boolean>;
  createApp(by: string, team: string, manifest: Json): Promise<CreatedApp>;
  setIcon(by: string, appId: string, picture: Uint8Array, mime: string): Promise<void>;
  /// An install's code, for its bot token and its workspace's name.
  exchangeInstallCode(clientId: string, clientSecret: string, code: string, redirectUri: string): Promise<[string, string | null]>;
  verifyTokens(appToken: string, botToken: string, lang: Lang): Promise<[SlackIdentity | null, string[]]>;
}

/// A JSON value's shape, for the log: its keys, and of each string only its kind (an xapp-/xoxb-/… token, or text).
export function shapeOf(value: Json): Json {
  if (Array.isArray(value)) return value.map(shapeOf);
  if (value === null) return "object";
  if (typeof value === "object") return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, shapeOf(v)]));
  if (typeof value === "string") return /^x[a-z]{3}-/.test(value) ? `${value.slice(0, 5)}…` : "string";
  if (typeof value === "number") return "number";
  if (typeof value === "boolean") return "boolean";
  return "object";
}

export type SlackAppsOptions = {
  client: SlackClient;
  /// The configuration tokens as kept now (config.json), and how a rotated one is kept.
  load: () => ConfigToken[];
  save: (token: ConfigToken) => void;
};

/// The Slack app API with the configuration tokens: a person's own (`by`), one per Slack workspace; nobody uses
/// another's. `load` and `save` keep them in the station's config, so a rotation survives restarts. An app is made with
/// the token of the workspace chosen; an app already made is read and changed with whichever of the person's tokens owns
/// it (found once, by asking).
export class SlackApps implements SlackService {
  readonly client: SlackClient;
  private load: () => ConfigToken[];
  private save: (token: ConfigToken) => void;
  /// One rotation at a time per person and workspace: the refresh token works once.
  private rotating = new Map<string, Promise<unknown>>();
  /// Which workspace's token owns an app, once known.
  private owner = new Map<string, string>();

  constructor(options: SlackAppsOptions) {
    this.client = options.client;
    this.load = options.load;
    this.save = options.save;
  }

  /// Whether this person has a token of their own.
  configured(by: string): boolean {
    return this.load().some((t) => t.by === by);
  }

  async exportManifest(by: string, appId: string): Promise<Json> {
    const data = await this.forApp(by, appId, "apps.manifest.export", [["app_id", appId]]);
    return data.manifest ?? null;
  }

  /// Validates, then updates. Whether Slack wants the permissions approved again.
  async updateManifest(by: string, appId: string, manifest: Json): Promise<boolean> {
    const json = JSON.stringify(manifest);
    const params: Params = [
      ["app_id", appId],
      ["manifest", json],
    ];
    await this.forApp(by, appId, "apps.manifest.validate", params);
    const data = await this.forApp(by, appId, "apps.manifest.update", params);
    return data.permissions_updated === true;
  }

  /// Makes the app in one of this person's workspaces (`team`); its OAuth credentials come only now, once.
  async createApp(by: string, team: string, manifest: Json): Promise<CreatedApp> {
    const token = await this.token(by, team);
    const data = await this.client.app("apps.manifest.create", token, [["manifest", JSON.stringify(manifest)]]);
    // What Slack answers beyond what is read here, by shape only (never a value): whether an app-level token comes with
    // a Socket Mode app is not documented (its errors name one: failed_generating_app_token).
    log.info("slack", "slack app made", { shape: shapeOf(data) });
    const appId = text(data.app_id);
    this.owner.set(`${by}|${appId}`, team);
    return { appId, clientId: text(at(data, ["credentials", "client_id"])), clientSecret: text(at(data, ["credentials", "client_secret"])) };
  }

  /// `mime`: the picture's (image/png or image/jpeg).
  async setIcon(by: string, appId: string, picture: Uint8Array, mime: string): Promise<void> {
    const file = mime === "image/jpeg" ? { bytes: picture, name: "icon.jpg", mime: "image/jpeg" } : { bytes: picture, name: "icon.png", mime: "image/png" };
    await this.forApp(by, appId, "apps.icon.set", [["app_id", appId]], file);
  }

  exchangeInstallCode(clientId: string, clientSecret: string, code: string, redirectUri: string) {
    return exchangeInstallCode(this.client, clientId, clientSecret, code, redirectUri);
  }

  verifyTokens(appToken: string, botToken: string, lang: Lang) {
    return verifySlackTokens(this.client, appToken, botToken, lang);
  }

  /// A call about an app, with the person's token that owns it: the one known, else each in turn until one is not
  /// refused.
  private async forApp(by: string, appId: string, method: string, params: Params, file?: { bytes: Uint8Array; name: string; mime: string }): Promise<Json> {
    const key = `${by}|${appId}`;
    const known = this.owner.get(key);
    if (known !== undefined) return this.client.app(method, await this.token(by, known), params, file);
    const tokens = this.load().filter((t) => t.by === by);
    if (tokens.length === 0) throw new SlackWords("station.slackApi.noConfigToken");
    let last: unknown;
    for (const token of tokens) {
      try {
        const data = await this.client.app(method, await this.token(by, token.teamId), params, file);
        this.owner.set(key, token.teamId);
        return data;
      } catch (e) {
        last = e;
      }
    }
    throw last;
  }

  /// A working access token of a person's workspace, rotating first when the current one is about to expire.
  private async token(by: string, team: string): Promise<string> {
    const current = () => this.load().find((t) => t.by === by && t.teamId === team);
    const fresh = (t: ConfigToken) => t.expiresAt - wall.now() > 5 * 60_000;
    const token = current();
    if (!token) throw new SlackWords("station.slackApi.noTokenForTeam");
    if (fresh(token)) return token.accessToken;
    const lock = `${by}|${team}`;
    const before = this.rotating.get(lock) ?? Promise.resolve();
    const mine = before.catch(() => {}).then(async () => {
      // Another call may have rotated it meanwhile: its refresh token is spent, the pair it made is the one to use.
      const now = current();
      if (!now) throw new SlackWords("station.slackApi.noTokenForTeam");
      if (fresh(now)) return now.accessToken;
      const next = await rotateConfigToken(this.client, now.refreshToken);
      log.info("slack", "slack configuration token rotated", { team: next.teamId });
      const kept: ConfigToken = { accessToken: next.accessToken, refreshToken: next.refreshToken, expiresAt: next.expiresAt, teamId: next.teamId, by };
      if (now.owner !== undefined) kept.owner = now.owner;
      this.save(kept);
      return next.accessToken;
    });
    this.rotating.set(lock, mine);
    try {
      return await mine;
    } finally {
      if (this.rotating.get(lock) === mine) this.rotating.delete(lock);
    }
  }
}
