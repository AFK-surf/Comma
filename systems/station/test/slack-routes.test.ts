// Connects and Slack through the pages (admin/tests.rs's cases for these routes, ported): the routes of
// src/api/routes/slack.ts over a real config.json, store and hub, with the connects really connected to a stand-in for
// Slack (test/slack-fake.ts). The overview is the station's (not here): a stand-in gives what these routes are
// answered with, built from what src/slack offers it (state, overview parts).
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { Route } from "../src/api/admin.ts";
import type { Request } from "../src/api/request.ts";
import { routes } from "../src/api/routes/slack.ts";
import type { Viewer } from "../src/mesh/credential.ts";
import { ConfigFile } from "../src/ops/config.ts";
import { hubConfig } from "../src/sessions/config.ts";
import { Hub } from "../src/sessions/hub.ts";
import { InternalChat } from "../src/sessions/internal.ts";
import { connectName, makeConnections, slackManifest } from "../src/slack/index.ts";
import { SlackClient } from "../src/slack/web.ts";
import { Store } from "../src/store/store.ts";
import { FakeDriver, message, settle } from "./hub-fakes.ts";
import { FakeSlack, bot } from "./slack-fake.ts";

type Json = any;

const viewer = (email: string, name: string, role: string): Viewer => ({ sub: `sub-${email}`, email, name, role, workspace: "ws", device: "d" });
/// The workspace's owner, through still.fail cloud (the only way in).
const owner = viewer("owner@example.com", "Owner", "owner");
/// Another member.
const dev = viewer("dev@example.com", "", "member");

const mask = (value: string) => (value === "" ? "" : [...value].length <= 8 ? "••••" : `${[...value].slice(0, 5).join("")}…${[...value].slice(-4).join("")}`);

type Setup = { cloud?: string; teamId?: string; tokens?: Json[] };

async function rig(o: Setup = {}) {
  const data = mkdtempSync(join(tmpdir(), "sr-"));
  delete process.env.STILLFAIL_CONFIG;
  delete process.env.EMBER_CONFIG;
  const path = join(data, "config.json");
  writeFileSync(
    path,
    JSON.stringify({
      profiles: [
        { id: "cc", runtime: "claude", home: "homes/cc", env: { ANTHROPIC_API_KEY: "sk-very-secret-value" } },
        { id: "cx", runtime: "codex", home: "homes/cx" },
      ],
      connects: [
        {
          id: "ds",
          kind: "slack",
          mode: "multi-session",
          bind: { runtime: "claude" },
          slack: { appToken: "xapp-1-aaaaaaaaaaaa", botToken: "xoxb-bbbbbbbbbbbb", appId: "A0DS", team: { id: "T0", name: "Acme" }, botName: "ember" },
        },
      ],
      ...(o.tokens ? { slackConfigTokens: o.tokens } : {}),
    }),
  );
  const fake = await FakeSlack.start();
  bot(fake, { teamId: o.teamId ?? "T1" });
  const config = new ConfigFile(data);
  const store = Store.open(join(data, "stillfail.db"), join(data, "archive"));
  const claude = new FakeDriver("claude");
  let hub: Hub | undefined;
  const slack = makeConnections({
    data,
    store,
    config,
    receive: async (id, event) => {
      await hub?.receive(id, event);
    },
    bound: () => true,
    client: new SlackClient(fake.base),
  });
  hub = new Hub({
    config: () => hubConfig(config.raw(), data),
    store,
    chats: slack.chats,
    drivers: [claude, new FakeDriver("codex")],
    mcpUrl: "http://127.0.0.1:1/mcp",
    internal: new InternalChat(),
    runners: () => [],
  });
  await slack.reconcile();
  const overview = (v: Viewer): Json => {
    const raw = config.raw();
    return {
      connects: slack.connects().map((c) => {
        const r = (raw.connects ?? []).find((x: Json) => x.id === c.id) ?? {};
        return {
          id: c.id,
          name: connectName(c),
          team: c.team?.name ?? null,
          botImage: c.botImage,
          enabled: c.enabled,
          mode: r.mode ?? "multi-session",
          requireMention: r.requireMention ?? true,
          slack: { appToken: mask(c.appToken), botToken: mask(c.botToken) },
          connection: slack.state(c),
          createdBy: r.createdBy ?? null,
        };
      }),
      slackUsers: store.slackIdentities(v.email),
      ...slack.overview(v.email),
    };
  };
  const place = o.cloud ? () => ({ origin: o.cloud!, workspace: "ws", station: "st" }) : undefined;
  const table: Route[] = routes({ slack, config, data, store, hub: () => hub, overview, place });
  const ask = async (method: string, route: string, body?: unknown, who: Viewer = owner): Promise<[number, Json]> => {
    const [path, search] = route.split("?");
    const query: [string, string][] = search ? [...new URLSearchParams(search)] : [];
    const r: Request = { method, path: path!, query, headers: {}, body: Buffer.from(body === undefined ? "" : JSON.stringify(body)), viewer: who, lang: "zh" };
    for (const route of table) {
      const found = route.method === method ? route.pattern.exec(r.path) : null;
      if (found) {
        const a = await route.handle(r, found.slice(1));
        return [a.status, JSON.parse(String(a.body))];
      }
    }
    return [404, { error: `no route ${method} ${path}` }];
  };
  const get = async (route: string, who: Viewer = owner) => (await ask("GET", route, undefined, who))[1];
  const saved = () => JSON.parse(readFileSync(path, "utf8"));
  const close = async () => {
    await slack.close();
    await hub!.shutdown();
    store.close();
    await fake.close();
    rmSync(data, { recursive: true, force: true });
  };
  return { data, path, fake, config, store, hub: hub!, slack, claude, ask, get, saved, overview: () => overview(owner), close };
}

/// Looks every 20 ms until `f` holds: what the stand-in's sockets do has no event here. No deadline (it comes, however
/// slow the machine, or the test hangs).
async function until(_what: string, f: () => boolean) {
  while (!f()) await new Promise((r) => setTimeout(r, 20));
}

/// What Slack's app API remembers of an app's manifest, and what the station asked of it.
function appApi(fake: FakeSlack, start: Json = slackManifest("ember")) {
  const state = { manifest: start, updates: [] as Json[] };
  const scopes = (m: Json) => [...(m?.oauth_config?.scopes?.bot ?? [])].sort().join(",");
  fake.answer("apps.manifest.export", () => ({ ok: true, manifest: state.manifest }));
  fake.answer("apps.manifest.validate", { ok: true });
  fake.answer("apps.manifest.update", (s) => {
    const next = JSON.parse(s.params.manifest!);
    const changed = scopes(state.manifest) !== scopes(next);
    state.updates.push(next);
    state.manifest = next;
    return { ok: true, permissions_updated: changed };
  });
  fake.answer("apps.icon.set", { ok: false, error: "app_not_owned_by_manager_app" });
  return state;
}

const configToken = (teamId: string, team: string, by: string) => ({
  accessToken: `xoxe.xoxp-${teamId}`,
  refreshToken: "xoxe-1",
  expiresAt: Date.now() + 3_600_000,
  teamId,
  by,
  owner: { team, teamDomain: null, teamIcon: null, user: "Ada", email: "ada@example.com", image: null },
});

test("a Slack app made on a station in still.fail cloud is installed through Slack's OAuth, its bot token taken by the station", async () => {
  const s = await rig({ cloud: "https://cloud.test", tokens: [configToken("T1", "Acme", "owner@example.com"), configToken("T2", "Other", "owner@example.com"), configToken("T3", "Theirs", "bob@example.com")] });
  try {
    s.fake.answer("apps.manifest.create", { ok: true, app_id: "A0NEW", credentials: { client_id: "C1", client_secret: "S1" } });
    s.fake.answer("oauth.v2.access", { ok: true, access_token: "xoxb-installed", team: { name: "Acme" } });
    // Several workspaces: the station lists them (never their tokens), and the app goes into the one chosen.
    const overview0 = s.overview();
    assert.deepEqual(
      overview0.slackTeams,
      [configToken("T1", "Acme", "x"), configToken("T2", "Other", "x")].map((t) => ({ teamId: t.teamId, name: t.owner.team, owner: t.owner })),
    );
    assert.ok(!JSON.stringify(overview0).includes("xoxe"));
    assert.equal((await s.ask("POST", "/slack/apps", { settings: { name: "ember" } }))[0], 400, "which workspace, when there are several");
    const [status, made] = await s.ask("POST", "/slack/apps", { team: "T2", settings: { name: "Helper", description: "Hi", groups: { dm: false } } });
    assert.equal(status, 200, JSON.stringify(made));
    assert.deepEqual(made, { appId: "A0NEW", iconError: null });
    const sent = s.fake.calls("apps.manifest.create")[0]!;
    assert.equal(sent.auth, "xoxe.xoxp-T2", "made with the viewer's token of the workspace chosen");
    assert.equal((await s.ask("POST", "/slack/apps", { team: "T3", settings: { name: "x" } }))[0], 400, "not with another's token");
    const manifest = JSON.parse(sent.params.manifest!);
    assert.deepEqual([manifest.display_information.name, manifest.display_information.description], ["Helper", "Hi"]);
    // Slack sends the person back to still.fail cloud's page, which hands the code to the station the state names.
    assert.deepEqual(manifest.oauth_config.redirect_urls, ["https://cloud.test/slack/installed"]);
    const install: string = s.overview().slackApps[0].install;
    const query = Object.fromEntries(new URLSearchParams(install.split("?")[1]));
    // It asks for what the app has on, no more.
    assert.equal(query.scope, manifest.oauth_config.scopes.bot.join(","));
    assert.ok(!query.scope!.split(",").includes("im:write"));
    assert.deepEqual([query.client_id, query.redirect_uri], ["C1", "https://cloud.test/slack/installed"]);
    assert.match(query.state!, /^ws\/st~[0-9a-f]{32}$/);
    // The app is kept on the station from the moment it is made: its maker sees it waiting, to install and finish any time.
    const waiting = s.overview().slackApps;
    assert.equal(waiting.length, 1);
    const w = waiting[0];
    assert.deepEqual([w.appId, w.name, w.teamId, w.team, w.install, w.installed], ["A0NEW", "Helper", "T2", "Other", install, false]);
    assert.deepEqual(w.links.install, "https://app.slack.com/app-settings/T2/A0NEW/install-on-team");
    assert.ok(!JSON.stringify(waiting).includes("S1"), "its secret stays on the station");
    // Kept in the config: a restart of the station loses nothing.
    assert.equal(s.saved().slackApps[0].appId, "A0NEW");
    assert.equal((await s.ask("POST", "/slack/installs", { code: "c", state: "ws/st~other" }))[0], 400, "only an install this station began");
    assert.deepEqual(await s.ask("POST", "/slack/installs", { code: "the-code", state: w.state }), [200, { team: "Acme" }]);
    const exchanged = s.fake.calls("oauth.v2.access")[0]!.params;
    assert.deepEqual([exchanged.code, exchanged.client_secret, exchanged.redirect_uri], ["the-code", "S1", "https://cloud.test/slack/installed"]);
    const overview = s.overview();
    assert.deepEqual([overview.slackApps[0].installed, overview.slackApps[0].installedTeam], [true, "Acme"]);
    assert.ok(!JSON.stringify(overview).includes("xoxb-installed"), "the token stays on the station");
    // Made without Socket Mode (so its maker turns it on in Slack, where the app-level token comes with its scope
    // picked), and so without events; the connect that takes it puts both in.
    assert.equal(manifest.settings.socket_mode_enabled, false);
    assert.equal(manifest.settings.event_subscriptions, undefined);
    const api = appApi(s.fake, manifest);
    // The installed bot is another one, in that workspace.
    bot(s.fake, { user: "UHELP", teamId: "T2", team: "Other", name: "helper", botId: "BHELP" });
    const [connectedStatus, connected] = await s.ask("POST", "/connects", { kind: "slack", mode: "multi-session", bind: { runtime: "claude" }, slack: { appToken: "xapp-1-new", install: w.state } });
    assert.equal(connectedStatus, 200, JSON.stringify(connected));
    assert.equal(connected.id, "helper");
    assert.equal(s.fake.calls("apps.manifest.export").at(-1)!.auth, "xoxe.xoxp-T2", "its manifest changed with its maker's token");
    const turnedOn = api.updates.at(-1);
    assert.equal(turnedOn.settings.socket_mode_enabled, true);
    assert.ok(turnedOn.settings.event_subscriptions.bot_events.includes("app_mention"));
    assert.deepEqual(s.overview().slackApps, [], "connected: no longer waiting");
    const helper = s.saved().connects.find((c: Json) => c.id === "helper");
    assert.deepEqual(helper.slack, { appToken: "xapp-1-new", botToken: "xoxb-installed", appId: "A0NEW", team: { id: "T2", name: "Other" }, botName: "helper", botImage: "https://avatars.slack-edge.com/ember_72.png" });
    assert.deepEqual(helper.createdBy, { id: "owner@example.com", name: "Owner" });
    assert.ok(connected.overview.connects.some((c: Json) => c.id === "helper"), "answered with the overview");
    // And it connects.
    await until("helper connected", () => s.slack.state("helper")?.state === "connected");
    // Another one, to drop.
    await s.ask("POST", "/slack/apps", { team: "T2", settings: { name: "Helper" } });
    // Only its maker sees it, or drops it (it stays in Slack).
    s.config.update((raw) => {
      raw.slackApps.push({ appId: "A0BOB", name: "Bob's", teamId: "T3", by: "bob@example.com", created: 1 });
    });
    assert.deepEqual(s.overview().slackApps.map((a: Json) => a.appId), ["A0NEW"]);
    assert.deepEqual(await s.ask("DELETE", "/slack/apps/A0BOB"), [404, { error: "没有这个 app" }]);
    assert.equal((await s.ask("DELETE", "/slack/apps/A0NEW"))[0], 200);
    assert.deepEqual(s.overview().slackApps, []);
  } finally {
    await s.close();
  }
});

test("a new connect from tokens is named as its bot is in Slack; bad tokens are refused with what is wrong", async () => {
  const s = await rig();
  try {
    const [bad, said] = await s.ask("POST", "/connects", { bind: { runtime: "claude" }, slack: { appToken: "xoxb-1", botToken: "xapp-1" } });
    assert.equal(bad, 400);
    assert.equal(said.error, "Bot Token 应该以 xoxb- 开头；App-Level Token 应该以 xapp- 开头");
    assert.deepEqual(await s.ask("POST", "/connects", { slack: { appToken: "xapp-1", install: "nope" } }), [400, { error: "app 还没装好：先在 Slack 里安装" }]);
    bot(s.fake, { name: "ember" });
    // Its name is taken: the next is ember-2. An app id given is kept with it.
    const [ok, made] = await s.ask("POST", "/connects", { bind: { runtime: "codex" }, slack: { appToken: " xapp-2-x ", botToken: "xoxb-2-y", appId: "A0GIVEN" } });
    assert.equal(ok, 200, JSON.stringify(made));
    assert.equal(made.id, "ember");
    const again = await s.ask("POST", "/connects", { bind: { runtime: "codex" }, slack: { appToken: "xapp-3", botToken: "xoxb-3" } });
    assert.equal(again[1].id, "ember-2");
    const saved = s.saved().connects.find((c: Json) => c.id === "ember");
    assert.deepEqual([saved.slack.appToken, saved.slack.appId, saved.bind.runtime, saved.kind], ["xapp-2-x", "A0GIVEN", "codex", "slack"]);
  } finally {
    await s.close();
  }
});

test("editing a connect keeps tokens that were left blank and writes config.json privately", async () => {
  const t = await rig();
  try {
    const [status, answer] = await t.ask("PUT", "/connects/ds", { bind: { model: "deepseek-flash" }, slack: { appToken: "", botToken: "" } });
    assert.equal(status, 200, JSON.stringify(answer));
    // Known by its bot's name in its Slack workspace, kept through the edit (and as Slack says once connected: T1).
    await until("the workspace as Slack says", () => t.saved().connects[0].slack.team.id === "T1");
    // (T1 may be what its first connection said: the edit's reconnection is waited for too.)
    await until("connected again after the edit", () => t.overview().connects[0].connection.state === "connected");
    const saved = t.saved();
    assert.deepEqual([saved.connects[0].slack.team, saved.connects[0].slack.botName], [{ id: "T1", name: "Acme" }, "ember"]);
    const view = t.overview().connects[0];
    assert.deepEqual([view.name, view.team], ["ember", "Acme"]);
    assert.equal(saved.connects[0].slack.botToken, "xoxb-bbbbbbbbbbbb");
    assert.equal(saved.connects[0].slack.appId, "A0DS");
    assert.equal(saved.connects[0].bind.model, "deepseek-flash");
    if (process.platform !== "win32") assert.equal(statSync(t.path).mode & 0o777, 0o600);
    // Connected, and shown masked.
    assert.equal(view.connection.state, "connected");
    assert.deepEqual(view.connection.workspace, { team: "Acme", teamId: "T1", url: "https://acme.slack.com/", botUserId: "UBOT", botName: "ember", botImage: "https://avatars.slack-edge.com/ember_72.png" });
    assert.equal(view.slack.botToken, "xoxb-…bbbb");
  } finally {
    await t.close();
  }
});

test("adding, disabling and deleting connects follows through to connections", async () => {
  const t = await rig();
  try {
    assert.deepEqual(t.slack.connections.ids(), ["ds"]);
    await t.ask("PUT", "/connects/gpt", { bind: { runtime: "codex" }, slack: { appToken: "xapp-2-cccccccccc", botToken: "xoxb-dddddddddd" } });
    await t.slack.reconcile();
    assert.deepEqual(t.slack.connections.ids().sort(), ["ds", "gpt"]);
    await until("gpt's socket", () => t.fake.sockets.length === 2);
    await t.ask("PUT", "/connects/gpt", { bind: { runtime: "claude" } });
    assert.equal(t.saved().connects.find((c: Json) => c.id === "gpt").bind.runtime, "codex", "a connect's runtime stays as it was made");
    await t.ask("PUT", "/connects/gpt", { enabled: false });
    await t.slack.reconcile();
    assert.deepEqual(t.slack.connections.ids(), ["ds"]);
    await until("gpt's socket closed", () => t.fake.sockets[1]!.readyState === t.fake.sockets[1]!.CLOSED);
    const gpt = t.overview().connects.find((c: Json) => c.id === "gpt");
    assert.deepEqual(gpt.connection, { state: "disabled" });
    await t.ask("DELETE", "/connects/gpt");
    assert.deepEqual(t.saved().connects.map((c: Json) => c.id), ["ds"]);
    assert.deepEqual(await t.ask("DELETE", "/connects/gpt"), [400, { error: "unknown connect gpt" }]);
    // One without tokens: none to connect.
    await t.ask("PUT", "/connects/bare", { bind: { runtime: "claude" } });
    assert.deepEqual(t.slack.state("bare"), { state: "no_tokens" });
  } finally {
    await t.close();
  }
});

test("a connect that cannot connect says why; out of the workspace none is connected", async () => {
  const t = await rig();
  try {
    t.fake.answer("auth.test", (s) => (s.auth === "xoxb-broken" ? { ok: false, error: "invalid_auth" } : { ok: true, user_id: "UBOT", team: "Acme", team_id: "T1", user: "ember" }));
    await t.ask("PUT", "/connects/broken", { bind: { runtime: "claude" }, slack: { appToken: "xapp-9", botToken: "xoxb-broken" } });
    await t.slack.reconcile();
    // Every reconcile tries it again (it is "starting" meanwhile).
    await until("its error said", () => t.slack.state("broken")?.state === "error");
    assert.deepEqual(t.slack.state("broken"), { state: "error", error: "slack auth.test: invalid_auth" });
    await t.slack.stopAll();
    assert.deepEqual(t.slack.connections.ids(), []);
  } finally {
    await t.close();
  }
});

test("invalid edits are refused and leave the config unchanged", async () => {
  const t = await rig();
  try {
    const before = readFileSync(t.path, "utf8");
    const bad = await t.ask("PUT", "/connects/x", { bind: { runtime: "nope" } });
    assert.equal(bad[0], 400);
    assert.match(bad[1].error, /unknown runtime/);
    assert.deepEqual(await t.ask("PUT", "/connects/y", {}), [400, { error: "runtime is required" }]);
    assert.deepEqual(await t.ask("PUT", "/connects/ds", { bind: { profile: "cx" } }), [400, { error: "「cx」不能跑 claude" }]);
    assert.deepEqual(await t.ask("PUT", "/connects/ds", { bind: { profile: "cc", model: "opus" } }), [400, { error: "「cc」没有启用 opus" }]);
    assert.equal((await t.ask("PUT", "/connects/ds", { bind: { effort: "ultra" } }))[0], 400);
    assert.deepEqual(await t.ask("PUT", "/connects/ds", "{" as unknown as Json).then(([s]) => s), 200, "a body that is a string is no object: {}");
    assert.equal(readFileSync(t.path, "utf8").includes("nope"), false);
    assert.equal(JSON.parse(readFileSync(t.path, "utf8")).connects.length, JSON.parse(before).connects.length);
  } finally {
    await t.close();
  }
});

test("a single-session connect can be set to wake without a mention, and pointed at a session", async () => {
  const t = await rig();
  try {
    assert.equal((await t.ask("PUT", "/connects/ds", { mode: "single-session", requireMention: false }))[0], 200);
    const view = t.overview().connects[0];
    assert.deepEqual([view.mode, view.requireMention], ["single-session", false]);
    const [status, bound] = await t.ask("POST", "/connects/ds/session", { title: "night shift" });
    assert.equal(status, 200, JSON.stringify(bound));
    assert.match(bound.session, /^ds:s-[0-9a-f]{8}$/);
    assert.equal(t.store.binding("ds"), bound.session);
    assert.equal(t.store.getSession(bound.session)!.title, "night shift");
    assert.deepEqual(await t.ask("POST", "/connects/ds/session", { session: "nope" }), [500, { error: "unknown session nope" }]);
    assert.deepEqual(await t.ask("POST", "/connects/ds/session", { session: bound.session }), [200, { session: bound.session }]);
    await t.ask("PUT", "/connects/ds", { mode: "multi-session" });
    assert.equal(hubConfig(t.config.raw(), t.data).connects[0]!.requireMention, true, "multi-session always needs a mention");
    assert.deepEqual(await t.ask("POST", "/connects/ds/session", {}), [500, { error: "connect ds is not single-session" }]);
  } finally {
    await t.close();
  }
});

test("a connect's Slack app is edited through its manifest; new permissions need approval in Slack", async () => {
  const t = await rig({ teamId: "T0", tokens: [configToken("T0", "Acme", "owner@example.com")] });
  try {
    const api = appApi(t.fake);
    const app = await t.get("/connects/ds/slack-app");
    assert.deepEqual([app.state, app.settings.name, app.appId], ["ok", "ember", "A0DS"]);
    assert.equal(app.links.install, "https://app.slack.com/app-settings/T0/A0DS/install-on-team");
    assert.equal(app.groups.length, 16);
    // Someone without a configuration token sees where to change it in Slack.
    assert.deepEqual((await t.get("/connects/ds/slack-app", dev)).state, "no_config_token");
    const renamed = (await t.ask("PUT", "/connects/ds/slack-app", { name: "ember-ds", description: "DS agent" }))[1];
    assert.equal(renamed.permissionsUpdated, false);
    assert.equal(renamed.iconError, null);
    assert.equal(api.manifest.display_information.name, "ember-ds");
    const fewer = (await t.ask("PUT", "/connects/ds/slack-app", { groups: { files: false }, icon: "data:image/png;base64,AAAA" }))[1];
    assert.equal(fewer.permissionsUpdated, true);
    assert.ok(fewer.iconError.includes("API 创建"), fewer.iconError);
    assert.equal(t.fake.calls("apps.icon.set")[0]!.params.app_id, "A0DS");
    assert.deepEqual(await t.ask("PUT", "/connects/ds/slack-app", { backgroundColor: "red" }), [400, { error: "背景色要写成 #RRGGBB" }]);
    assert.deepEqual(await t.ask("PUT", "/connects/ds/slack-app", { name: "  " }), [400, { error: "名字不能为空" }]);
    t.fake.answer("apps.manifest.validate", { ok: false, error: "invalid_manifest", errors: [{ pointer: "/x", message: "bad" }] });
    assert.deepEqual(await t.ask("PUT", "/connects/ds/slack-app", { description: "x" }), [400, { error: "Slack 没接受这次修改：manifest 不合法：/x bad" }]);
    // Token edits keep the app id the station learned.
    await t.ask("PUT", "/connects/ds", { slack: { botToken: "xoxb-new-token-123" } });
    assert.equal(t.saved().connects[0].slack.appId, "A0DS");
    assert.equal(t.saved().connects[0].slack.botToken, "xoxb-new-token-123");
    assert.deepEqual(await t.ask("GET", "/connects/nope/slack-app"), [404, { error: "unknown connect nope" }]);
  } finally {
    await t.close();
  }
});

test("a connect's app is looked up by its bot token, made for it when it has none, and said when its token no longer works", async () => {
  const t = await rig({ tokens: [configToken("T5", "Five", "owner@example.com")] });
  try {
    t.fake.answer("bots.info", (s) => (s.auth === "xoxb-gone" ? { ok: false, error: "invalid_auth" } : { ok: true, bot: { app_id: "A0LEARNED" } }));
    await t.ask("PUT", "/connects/lookup", { bind: { runtime: "claude" }, slack: { appToken: "xapp-5", botToken: "xoxb-5" } });
    assert.deepEqual(await t.ask("POST", "/connects/lookup/slack-app", {}), [400, { error: "这个连接已经有 Slack app 了" }]);
    assert.equal(t.fake.calls("bots.info").length, 1);
    await t.ask("PUT", "/connects/gone", { bind: { runtime: "claude" }, slack: { appToken: "xapp-6", botToken: "xoxb-gone" } });
    const gone = await t.get("/connects/gone/slack-app");
    assert.deepEqual([gone.state, gone.appId, gone.error], ["no_app", null, "配置 token 无效，请重新填写"]);
    // A connect with no tokens yet: its app made with the configuration token, so only installing it is left.
    await t.ask("PUT", "/connects/fresh", { bind: { runtime: "claude" } });
    assert.deepEqual((await t.get("/connects/fresh/slack-app")).state, "no_app");
    t.fake.answer("apps.manifest.create", { ok: true, app_id: "A0FRESH", credentials: { client_id: "c", client_secret: "s" } });
    const [status, made] = await t.ask("POST", "/connects/fresh/slack-app", { name: " Fresh " });
    assert.equal(status, 200, JSON.stringify(made));
    assert.deepEqual(made, { appId: "A0FRESH", links: { settings: "https://app.slack.com/app-settings/T5/A0FRESH", install: "https://app.slack.com/app-settings/T5/A0FRESH/install-on-team", appToken: "https://app.slack.com/app-settings/T5/A0FRESH/socket-mode", oauth: "https://app.slack.com/app-settings/T5/A0FRESH/oauth" } });
    assert.equal(JSON.parse(t.fake.calls("apps.manifest.create")[0]!.params.manifest!).display_information.name, "Fresh");
    assert.equal(t.saved().connects.find((c: Json) => c.id === "fresh").slack.appId, "A0FRESH");
    assert.deepEqual(await t.ask("PUT", "/connects/fresh/slack-app", { name: "x" }, dev).then(([s]) => s), 400, "with no token of their own, Slack is not asked");
    assert.deepEqual(await t.ask("POST", "/connects/fresh/slack-app", {}, dev), [400, { error: "这个连接已经有 Slack app 了" }]);
    await t.ask("PUT", "/connects/other", { bind: { runtime: "claude" } });
    assert.deepEqual(await t.ask("POST", "/connects/other/slack-app", {}, dev), [400, { error: "你还没有加 Slack 的 App 配置 token" }]);
  } finally {
    await t.close();
  }
});

test("connects remember who created them; only a manager or its owner hands one to someone else", async () => {
  const t = await rig();
  try {
    const created = (id: string) => t.saved().connects.find((c: Json) => c.id === id).createdBy;
    await t.ask("PUT", "/connects/fresh", { bind: { runtime: "claude" } });
    assert.deepEqual(created("fresh"), { id: "owner@example.com", name: "Owner" });
    await t.ask("PUT", "/connects/fresh", { mode: "single-session" });
    assert.equal(created("fresh").id, "owner@example.com", "editing keeps the creator");
    assert.equal(t.overview().connects.find((c: Json) => c.id === "ds").createdBy, null, "older connects have none");
    await t.ask("PUT", "/connects/ds", { owner: { id: "Bob@Example.test", name: "Bob" } });
    assert.deepEqual(created("ds"), { id: "bob@example.test", name: "Bob" });
    assert.deepEqual(await t.ask("PUT", "/connects/ds", { owner: { id: "not an email" } }), [400, { error: "所属用户要写成邮箱" }]);
    assert.deepEqual(await t.ask("PUT", "/connects/ds", { owner: { id: "dev@example.com" } }, dev), [400, { error: "只有 workspace 的 owner、管理员或者当前所属用户能改所属用户" }]);
    await t.ask("PUT", "/connects/mine", { bind: { runtime: "claude" } }, dev);
    assert.deepEqual(created("mine"), { id: "dev@example.com", name: "dev@example.com" });
    assert.equal((await t.ask("PUT", "/connects/mine", { owner: { id: "local" } }, dev))[0], 200, "its owner hands it on");
    assert.deepEqual(created("mine"), { id: "local", name: "local" });
  } finally {
    await t.close();
  }
});

test("the Slack people of the station's connects are listed once each by email, bots and the deactivated left out, guests marked", async () => {
  const s = await rig();
  try {
    s.fake.answer("users.list", (seen) =>
      seen.params.cursor === undefined
        ? {
            ok: true,
            members: [
              { id: "U1", profile: { real_name: "Ada", email: "Ada@Example.test", image_72: "https://img/ada" } },
              { id: "U2", is_bot: true, profile: { real_name: "Bot", email: "bot@example.test" } },
              { id: "U3", deleted: true, profile: { real_name: "Gone", email: "gone@example.test" } },
            ],
            response_metadata: { next_cursor: "more" },
          }
        : {
            ok: true,
            members: [
              { id: "U4", is_restricted: true, profile: { real_name: "Guest", email: "guest@example.test" } },
              { id: "U5", profile: { real_name: "No email" } },
              { id: "USLACKBOT", profile: { real_name: "Slackbot", email: "slackbot@example.test" } },
              { id: "U6", profile: { real_name: "Ada again", email: "ada@example.test" } },
            ],
          },
    );
    const [status, body] = await s.ask("GET", "/slack/people");
    assert.equal(status, 200);
    assert.deepEqual(
      body.people.map((p: Json) => [p.email, p.name, p.guest, p.team]),
      [
        ["ada@example.test", "Ada", false, "Acme"],
        ["guest@example.test", "Guest", true, "Acme"],
      ],
    );
    assert.equal(body.people[0].image, "https://img/ada");
    assert.deepEqual(s.fake.calls("users.list").map((c) => c.params), [{ limit: "200" }, { limit: "200", cursor: "more" }]);
    assert.deepEqual(body.errors, []);
    s.fake.answer("users.list", { ok: false, error: "missing_scope" });
    assert.deepEqual((await s.get("/slack/people")).errors, ["ember：slack users.list: missing_scope"]);
  } finally {
    await s.close();
  }
});

test("a viewer says a Slack user is them, or not: each for themselves", async () => {
  const t = await rig();
  try {
    assert.deepEqual((await t.ask("PUT", "/me/slack/U42"))[1].slackUsers, ["U42"]);
    assert.deepEqual((await t.ask("PUT", "/me/slack/U7", undefined, dev))[1].slackUsers, ["U7"]);
    assert.deepEqual(t.store.slackIdentities("owner@example.com"), ["U42"]);
    assert.deepEqual((await t.ask("DELETE", "/me/slack/U7", undefined, dev))[1].slackUsers, []);
    assert.equal((await t.ask("PUT", "/me/slack/U7/more"))[0], 404);
  } finally {
    await t.close();
  }
});

test("tokens are checked as given, blank ones as stored; the create-app link; reconnecting reads who the bot is again", async () => {
  const t = await rig();
  try {
    const [status, checked] = await t.ask("POST", "/slack/verify", { connect: "ds", appToken: " ", botToken: "" });
    assert.equal(status, 200);
    assert.deepEqual(checked, { identity: { team: "Acme", teamId: "T1", url: "https://acme.slack.com/", botUserId: "UBOT", botName: "ember", botImage: "https://avatars.slack-edge.com/ember_72.png" }, errors: [] });
    const opened = t.fake.calls("apps.connections.open").at(-1)!;
    assert.equal(opened.auth, "xapp-1-aaaaaaaaaaaa");
    assert.deepEqual((await t.ask("POST", "/slack/verify", { appToken: "nope", botToken: "nope" }))[1], { identity: null, errors: ["Bot Token 应该以 xoxb- 开头", "App-Level Token 应该以 xapp- 开头"] });

    const [made, url] = await t.ask("GET", "/slack/create-app-url?name=%20ember%20");
    assert.equal(made, 200);
    assert.equal(JSON.parse(decodeURIComponent(url.url.split("manifest_json=")[1])).display_information.name, "ember");
    assert.deepEqual(await t.ask("GET", "/slack/create-app-url?name=%20"), [400, { error: "name is required" }]);

    const before = t.fake.calls("auth.test").length;
    bot(t.fake, { name: "ember renamed" });
    assert.deepEqual(await t.ask("POST", "/connects/ds/reconnect"), [200, { ok: true }]);
    assert.equal(t.fake.calls("auth.test").length, before + 1);
    await until("the new name kept", () => t.saved().connects[0].slack.botName === "ember renamed");
  } finally {
    await t.close();
  }
});

test("configuration tokens are added by their refresh token, with whose they are, and removed", async () => {
  const t = await rig();
  try {
    assert.deepEqual(await t.ask("POST", "/slack/config-tokens", { refreshToken: "xoxe.xoxp-1-abc" }), [400, { error: "Refresh token 应该以 xoxe- 开头（不是 xoxe.xoxp- 开头的那个）" }]);
    t.fake.answer("tooling.tokens.rotate", (s) =>
      s.params.refresh_token === "xoxe-1-good" ? { ok: true, token: "xoxe.xoxp-1-access", refresh_token: "xoxe-1-next", exp: 2_000_000_000, team_id: "T5" } : { ok: false, error: "invalid_refresh_token" },
    );
    t.fake.answer("team.info", { ok: true, team: { name: "Five", domain: "five", icon: { image_68: "https://img/five" } } });
    assert.deepEqual(await t.ask("POST", "/slack/config-tokens", { refreshToken: "xoxe-1-bad" }), [400, { error: "Slack 没接受这个 token：tooling.tokens.rotate: invalid_refresh_token" }]);
    const [status, added] = await t.ask("POST", "/slack/config-tokens", { refreshToken: " xoxe-1-good " });
    assert.equal(status, 200, JSON.stringify(added));
    assert.equal(added.teamId, "T5");
    assert.deepEqual(added.overview.slackTeams, [{ teamId: "T5", name: "Five", owner: { team: "Five", teamDomain: "five", teamIcon: "https://img/five", user: "ember", email: null, image: null } }]);
    const kept = t.saved().slackConfigTokens[0];
    assert.deepEqual([kept.accessToken, kept.refreshToken, kept.expiresAt, kept.teamId, kept.by], ["xoxe.xoxp-1-access", "xoxe-1-next", 2_000_000_000_000, "T5", "owner@example.com"]);
    assert.deepEqual((await t.ask("DELETE", "/slack/config-tokens/T5", undefined, dev))[1].slackTeams, [], "another's is not theirs to remove");
    assert.equal(t.saved().slackConfigTokens.length, 1);
    assert.deepEqual((await t.ask("DELETE", "/slack/config-tokens/T5"))[1].slackTeams, []);
    assert.deepEqual(t.saved().slackConfigTokens, []);
  } finally {
    await t.close();
  }
});

test("a message a connect hears in Slack reaches the hub and its session", async () => {
  const t = await rig();
  try {
    await until("ds's socket", () => t.fake.sockets.length === 1);
    const m = message({ ts: "11.000001", threadTs: "11.000001", user: "U42", text: "<@UBOT> hi" });
    t.fake.event("ev1", { type: "app_mention", channel: m.channel, user: m.user, ts: m.ts, text: m.text });
    await t.fake.until("acknowledged", () => t.fake.acks.some((a) => a.envelope_id === "ev1"));
    await settle();
    const key = "ds:C1:11.000001";
    assert.ok(t.store.getSession(key), "its session made");
    assert.equal(t.store.getSession(key)!.createdBy, "slack:ds:U42");
    const thread = t.store.threadAt("slack:T1", "C1", "11.000001");
    assert.ok(thread, "its thread under its Slack workspace");
    await until("a turn", () => t.claude.count() === 1 && t.claude.last().prompts.length === 1);
    assert.match(t.claude.last().prompts[0]!, /hi/);
  } finally {
    await t.close();
  }
});
