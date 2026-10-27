import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type {
  PluginNotice,
  PluginsValue,
  OnboardingPluginList,
  PluginSourcesValue,
} from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  signedOut,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const WS = "ws-1";
const plugin = (id: string, extra: Record<string, unknown> = {}) => ({
  id,
  name: id[0]!.toUpperCase() + id.slice(1),
  summary: `${id} for Comma`,
  brand: id,
  category: "",
  installed: false,
  locked: false,
  mcps: [],
  skills: [],
  ...extra,
});
const catalogPath = `/v1/comma/workspaces/${WS}/plugins`;
const workspace = { id: WS, group_id: "g-1", name: "Mine", status: "ready" };

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      (e) => values.set(key, { error: e.code })
    );
    return () => values.get(key) as T;
  };
  return { host, core, client, time: host.time!, api: host.api, watch };
}

describe("the plugin catalog", () => {
  it("shows what the device kept at once, offline, and what the server says once it answers", async () => {
    const host = new FakeHost();
    host.api.on("GET", catalogPath, {
      data: [plugin("github"), plugin("notion", { installed: true })],
    });
    const first = setup(host);
    first.core.observeSession(signedIn());
    const shown = first.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await first.time.pass(100);
    expect(shown()).toMatchObject({ status: "ready", installed: ["notion"] });
    first.core.close();

    // The app starts again with no network: the catalog comes from the device.
    host.api.on("GET", catalogPath, offline());
    const again = setup(host);
    again.core.observeSession(signedIn());
    const cached = again.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await again.time.pass(50);
    expect(cached()).toMatchObject({ status: "ready", installed: ["notion"] });

    // The network is back: the next try (10 s later) brings the server's catalog in.
    host.api.on("GET", catalogPath, {
      data: [
        plugin("github", { installed: true }),
        plugin("notion", { installed: true }),
      ],
    });
    await again.time.pass(10_000, 500);
    expect(cached()).toMatchObject({
      status: "ready",
      installed: ["github", "notion"],
    });
  });

  it("tells the server what the app is and what this core can do, so it offers nothing an older app cannot use", async () => {
    const host = new FakeHost();
    host.client = { kind: "electron", platform: "macos", version: "1.0.8" };
    host.api.on("GET", catalogPath, { data: [plugin("github")] });
    const t = setup(host);
    t.core.observeSession(signedIn());
    t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    const [request] = t.api.seen("GET", catalogPath);
    expect(request?.headers).toEqual(
      expect.arrayContaining([
        ["x-comma-client", "electron/macos/1.0.8"],
        ["x-comma-client-capabilities", "device-plugins"],
      ])
    );
  });

  it("says why a first read failed, and reads again every 10 s until it can", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, json(503, { error: "upstream_unavailable" }));
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "error",
      error: { code: "upstream_unavailable", status: 503 },
    });
    t.api.on("GET", catalogPath, { data: [plugin("github")] });
    await t.time.pass(9_000, 500);
    expect(t.api.seen("GET", catalogPath)).toHaveLength(1);
    await t.time.pass(1_500, 500);
    expect(t.api.seen("GET", catalogPath)).toHaveLength(2);
    expect(shown()).toMatchObject({
      status: "ready",
      categories: [{ id: "integrations", name: null, plugins: ["github"] }],
    });
  });

  it("picks the preferred workspace when it can have plugins, and the first ready one when not", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/workspaces", {
      data: [
        { ...workspace, id: "ws-0", status: "provisioning" },
        workspace,
        { ...workspace, id: "ws-2" },
      ],
    });
    t.api.on("GET", "/v1/comma/workspaces/*", { data: [] });
    t.core.observeSession(signedIn());
    const preferred = t.watch<PluginsValue>({ topic: "plugins", prefer: "ws-2" });
    const fallback = t.watch<PluginsValue>({ topic: "plugins", prefer: "ws-0" });
    await t.time.pass(100);
    expect(preferred()).toMatchObject({ status: "ready", workspace: "ws-2" });
    expect(fallback()).toMatchObject({ status: "ready", workspace: WS });
  });

  it("keeps nothing of an account that signed out, and shows another account none of it", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, { data: [plugin("github", { installed: true })] });
    t.core.observeSession(signedIn("alice"));
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ status: "ready" });
    const alicesDb = [...t.host.dbs.keys()][0]!;

    t.api.on("GET", catalogPath, offline());
    t.core.observeSession(signedIn("bob"));
    await t.time.pass(100);
    expect(shown()).toMatchObject({ status: "error" });
    expect(t.host.deleted).toEqual([alicesDb]);
    t.core.observeSession(signedOut());
    await t.time.pass(100);
    expect(t.host.dbs.size).toBe(0);
  });

  it("keeps Feishu off the Plugins page's lists", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, {
      data: [
        plugin("feishu", { installed: true }),
        plugin("github"),
        plugin("notion", { installed: true }),
      ],
    });
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "ready",
      plugins: [{ id: "feishu" }, { id: "github" }, { id: "notion" }],
      installed: ["notion"],
      categories: [{ id: "integrations", name: null, plugins: ["github"] }],
    });
  });

  it("keeps Lark off the Plugins page's lists", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, {
      data: [plugin("lark", { installed: true }), plugin("github")],
    });
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      status: "ready",
      plugins: [{ id: "lark" }, { id: "github" }],
      installed: [],
      categories: [{ id: "integrations", name: null, plugins: ["github"] }],
    });
  });
});

describe("installing a plugin", () => {
  it("requests a credential, reports a rejected token, and installs on retry without publishing the token", async () => {
    const t = setup();
    const credentialSetup = {
      key: "X_BEARER_TOKEN",
      label: "App-only Bearer Token",
      helpUrl: "https://console.x.com/",
    };
    const x = plugin("x", { credentialSetup });
    const installPath = `${catalogPath}/x/install`;
    const rejected = "rejected-test-token";
    const accepted = "accepted-test-token";
    let installed = false;
    t.api.on("GET", catalogPath, () => json(200, { data: [{ ...x, installed }] }));
    t.api.on("POST", installPath, (request) => {
      const token = (request.body as { config_values?: Record<string, string> })
        .config_values?.X_BEARER_TOKEN;
      if (!token)
        return json(200, {
          plugin: x,
          authorization: null,
          configuration: credentialSetup,
        });
      if (token === rejected)
        return json(422, { error: "plugin_credential_rejected", message: rejected });
      installed = true;
      return json(200, { plugin: { ...x, installed }, authorization: null });
    });
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    const doing = t.watch<unknown>({ topic: "doing" });
    await t.time.pass(100);
    await t.client.call("plugin.install", { workspace: WS, plugin: "x" });
    await t.time.pass(100);
    expect(notices().notices).toMatchObject([
      {
        kind: "configure",
        configuration: { workspace: WS, plugin: { id: "x" }, setup: credentialSetup },
      },
    ]);
    const submit = (token: string) =>
      t.client.call("plugin.install", {
        workspace: WS,
        plugin: "x",
        configValues: { X_BEARER_TOKEN: token },
      });
    await expect(submit(rejected)).resolves.toEqual({ failure: "credential_rejected" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ status: "ready", installed: [] });
    await expect(submit(accepted)).resolves.toEqual({});
    await t.time.pass(100);
    expect(shown()).toMatchObject({ status: "ready", installed: ["x"] });
    expect(t.api.seen("POST", installPath).at(-1)?.body).toEqual({
      contract: "unified_v1",
      config_values: { X_BEARER_TOKEN: accepted },
    });
    const published = JSON.stringify([shown(), notices(), doing()]);
    expect(published).not.toContain(rejected);
    expect(published).not.toContain(accepted);
    t.core.close();
    t.api.on("GET", catalogPath, offline());
    const again = setup(t.host);
    again.core.observeSession(signedIn());
    const cached = again.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await again.time.pass(100);
    expect(cached()).toMatchObject({ status: "ready", installed: ["x"] });
    expect(JSON.stringify(cached())).not.toContain(accepted);
  });

  it("opens its authorization, checks it every 2 s, and shows it installed once the browser is done", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, { data: [plugin("github")] });
    let authorized = false;
    t.api.on("POST", `${catalogPath}/github/install`, () =>
      json(
        200,
        authorized
          ? { plugin: plugin("github", { installed: true }), authorization: null }
          : {
              plugin: plugin("github"),
              authorization: {
                state: "attempt-1",
                authorizationUrl: "https://github.test/authorize",
              },
            }
      )
    );
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);

    const answer = t.client.call("plugin.install", { workspace: WS, plugin: "github" });
    await t.time.pass(100);
    await expect(answer).resolves.toEqual({
      authorizationUrl: "https://github.test/authorize",
    });
    expect(shown()).toMatchObject({
      plugins: [{ id: "github", activity: "authorizing" }],
    });

    await t.time.pass(6_000, 250);
    const checks = t.api.seen("POST", `${catalogPath}/github/install`).slice(1);
    expect(checks.length).toBe(3);
    expect(checks[0]!.body).toEqual({
      contract: "unified_v1",
      authorization_state: "attempt-1",
      verify_only: true,
    });

    authorized = true;
    await t.time.pass(2_100, 250);
    expect(shown()).toMatchObject({
      plugins: [{ id: "github", installed: true, activity: "idle" }],
      installed: ["github"],
    });
  });

  it("starts a new install when Add is pressed again while one waits on the browser, and stops checking the old one", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    t.api.on("POST", `${catalogPath}/linear/install`, (request) =>
      json(200, {
        plugin: plugin("linear"),
        authorization: {
          state:
            (request.body as { authorization_state?: string }).authorization_state ??
            `attempt-${t.api.seen("POST", `${catalogPath}/linear/install`).length}`,
        },
      })
    );
    t.core.observeSession(signedIn());
    await t.time.pass(100);
    await t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(1_000, 100);
    await t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(2_100, 100);
    const states = t.api
      .seen("POST", `${catalogPath}/linear/install`)
      .map(
        (r) => (r.body as { authorization_state?: string }).authorization_state ?? "new"
      );
    // Two installs, then the checks of the second attempt only.
    expect(states).toEqual(["new", "new", "attempt-2"]);
  });

  it("gives an authorization up after two minutes, and one window says so", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, { data: [plugin("github")] });
    t.api.on("POST", `${catalogPath}/github/install`, {
      plugin: plugin("github"),
      authorization: { state: "attempt-1" },
    });
    t.core.observeSession(signedIn());
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    await t.time.pass(100);
    void t.client.call("plugin.install", {
      workspace: WS,
      plugin: "github",
      origin: "onboarding",
    });
    await t.time.pass(120_500, 1_000);
    const checks = t.api.seen("POST", `${catalogPath}/github/install`).length - 1;
    expect(checks).toBeLessThanOrEqual(60);
    expect(notices().notices).toMatchObject([
      { kind: "authorization_timed_out", origin: "onboarding", plugin: "github" },
    ]);
    const id = notices().notices[0]!.id;
    const claims = await Promise.all([
      t.client.call("plugin.notice.claim", { id }),
      t.client.call("plugin.notice.claim", { id }),
    ]);
    expect(claims).toEqual([true, false]);
  });

  it("words a refused install by the server's code, and an unanswered one as timed out after 30 s", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, { data: [plugin("github"), plugin("linear")] });
    t.api.on(
      "POST",
      `${catalogPath}/github/install`,
      json(412, { error: "missing_oauth_client" })
    );
    t.core.observeSession(signedIn());
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    await t.time.pass(100);
    void t.client.call("plugin.install", { workspace: WS, plugin: "github" });
    await t.time.pass(100);
    expect(notices().notices).toMatchObject([
      { kind: "install_failed", reason: "not_configured" },
    ]);

    t.api.hold("POST", `${catalogPath}/linear/install`);
    void t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(30_100, 500);
    expect(notices().notices.at(-1)).toMatchObject({
      kind: "install_timed_out",
      plugin: "linear",
    });
  });

  it("stops an install under way when it is cancelled, without a notice", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, { data: [plugin("github")] });
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    await t.time.pass(100);
    t.api.hold("POST", `${catalogPath}/github/install`);
    const install = t.client.call("plugin.install", {
      workspace: WS,
      plugin: "github",
    });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ plugins: [{ activity: "installing" }] });
    await t.client.call("plugin.cancel", { workspace: WS, plugin: "github" });
    await expect(install).rejects.toMatchObject({ code: "cancelled" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ plugins: [{ activity: "idle" }] });
    expect(notices().notices).toEqual([]);
  });

  it("uninstalls, and says what the server said when it could not", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, { data: [plugin("github", { installed: true })] });
    t.api.on("DELETE", `${catalogPath}/github`, json(500, { error: "storage_failed" }));
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    await t.time.pass(100);
    await expect(
      t.client.call("plugin.uninstall", { workspace: WS, plugin: "github" })
    ).rejects.toMatchObject({ code: "storage_failed" });
    await t.time.pass(100);
    expect(notices().notices).toMatchObject([
      { kind: "uninstall_failed", message: "storage_failed" },
    ]);
    t.api.on("DELETE", `${catalogPath}/github`, plugin("github"));
    await t.client.call("plugin.uninstall", { workspace: WS, plugin: "github" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ installed: [] });
  });

  it("lets an install that never answered go after 30 s, and keeps nothing of its late answer", async () => {
    const t = setup();
    const installPath = `${catalogPath}/linear/install`;
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    const late = Promise.withResolvers<ReturnType<typeof json>>();
    let aborted = false;
    t.api.on("POST", installPath, (_request, signal) => {
      signal.addEventListener("abort", () => (aborted = true));
      return late.promise;
    });
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    await t.time.pass(100);
    const answer = t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      plugins: [{ id: "linear", activity: "installing" }],
    });
    await t.time.pass(30_000, 500);
    await expect(answer).resolves.toEqual({});
    expect(aborted).toBe(true);
    expect(notices().notices).toMatchObject([
      { kind: "install_timed_out", plugin: "linear" },
    ]);
    expect(shown()).toMatchObject({ plugins: [{ id: "linear", activity: "idle" }] });

    late.resolve(
      json(200, { plugin: plugin("linear", { installed: true }), authorization: null })
    );
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      installed: [],
      plugins: [{ id: "linear", installed: false, activity: "idle" }],
    });

    // Added again, and answered: it is installed.
    t.api.on("POST", installPath, {
      plugin: plugin("linear", { installed: true }),
      authorization: null,
    });
    const retry = t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(100);
    await expect(retry).resolves.toEqual({});
    expect(shown()).toMatchObject({ installed: ["linear"] });
  });

  it("stops an install under way when another account signs in, and says nothing of it", async () => {
    const t = setup();
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    let aborted = false;
    t.api.on(
      "POST",
      `${catalogPath}/linear/install`,
      (_request, signal) =>
        new Promise(() => {
          signal.addEventListener("abort", () => (aborted = true));
        })
    );
    t.core.observeSession(signedIn());
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    await t.time.pass(100);
    const outcome = t.client
      .call("plugin.install", { workspace: WS, plugin: "linear" })
      .then(
        (answer) => ({ answer }),
        (error: { code?: string }) => ({ error: error.code })
      );
    await t.time.pass(100);
    t.core.observeSession(signedIn("someone-else"));
    await t.time.pass(100);
    expect(aborted).toBe(true);
    expect(await outcome).toEqual({ error: "cancelled" });
    expect(notices().notices).toEqual([]);
  });

  it("checks an authorization at once when a window gets the focus back", async () => {
    const t = setup();
    const installPath = `${catalogPath}/linear/install`;
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    t.api.on("POST", installPath, {
      plugin: plugin("linear"),
      authorization: { state: "attempt-1", authorizationUrl: "https://linear.test/a" },
    });
    t.core.observeSession(signedIn());
    await t.time.pass(100);
    const answer = t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(100);
    await answer;
    await t.client.call("plugin.authorization.check", {});
    await t.time.pass(100);
    // Well before the 2 s check.
    expect(t.api.seen("POST", installPath).map((r) => r.body)).toEqual([
      { contract: "unified_v1" },
      { contract: "unified_v1", authorization_state: "attempt-1", verify_only: true },
    ]);
  });

  it("lets an authorization go when a check finds it unfinished, and checks nothing more", async () => {
    const t = setup();
    const installPath = `${catalogPath}/linear/install`;
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    t.api.on("POST", installPath, (request) =>
      json(
        200,
        (request.body as { verify_only?: boolean }).verify_only
          ? // The person closed the page: the attempt is over, nothing was connected.
            { plugin: plugin("linear"), authorization: null }
          : {
              plugin: plugin("linear"),
              authorization: {
                state: "attempt-1",
                authorizationUrl: "https://linear.test/a",
              },
            }
      )
    );
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    const answer = t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(100);
    await answer;
    await t.client.call("plugin.authorization.check", {});
    await t.time.pass(100);
    expect(t.api.seen("POST", installPath)).toHaveLength(2);
    expect(shown()).toMatchObject({
      installed: [],
      plugins: [{ id: "linear", installed: false, activity: "idle" }],
    });
    await t.client.call("plugin.authorization.check", {});
    await t.time.pass(4_100, 250);
    expect(t.api.seen("POST", installPath)).toHaveLength(2);
  });

  it("checks the same attempt again after a check that failed", async () => {
    const t = setup();
    const installPath = `${catalogPath}/linear/install`;
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    const answers = [
      json(200, {
        plugin: plugin("linear"),
        authorization: {
          state: "attempt-1",
          authorizationUrl: "https://linear.test/a",
        },
      }),
      offline("provider unavailable"),
      json(200, { plugin: plugin("linear", { installed: true }), authorization: null }),
    ];
    t.api.on("POST", installPath, () => answers.shift()!);
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    const answer = t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(100);
    await answer;
    await t.client.call("plugin.authorization.check", {});
    await t.time.pass(100);
    expect(t.api.seen("POST", installPath)).toHaveLength(2);
    expect(shown()).toMatchObject({
      plugins: [{ id: "linear", activity: "authorizing" }],
    });
    await t.time.pass(2_100, 250);
    const checks = t.api.seen("POST", installPath);
    expect(checks).toHaveLength(3);
    expect(checks[2]!.body).toMatchObject({ authorization_state: "attempt-1" });
    expect(shown()).toMatchObject({
      installed: ["linear"],
      plugins: [{ id: "linear", activity: "idle" }],
    });
  });

  it("has one window open the next attempt a check finds, and checks that one", async () => {
    const t = setup();
    const installPath = `${catalogPath}/google/install`;
    t.api.on("GET", catalogPath, { data: [plugin("google")] });
    const attempt = (state: string) => ({
      plugin: plugin("google"),
      authorization: { state, authorizationUrl: `https://google.test/${state}` },
    });
    t.api.on("POST", installPath, (request) => {
      const state = (request.body as { authorization_state?: string })
        .authorization_state;
      if (!state) return json(200, attempt("gmail"));
      // Gmail is done; the server starts Calendar's.
      if (state === "gmail") return json(200, attempt("calendar"));
      return json(200, {
        plugin: plugin("google", { installed: true }),
        authorization: null,
      });
    });
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    await t.time.pass(100);
    const answer = t.client.call("plugin.install", { workspace: WS, plugin: "google" });
    await t.time.pass(100);
    await expect(answer).resolves.toEqual({
      authorizationUrl: "https://google.test/gmail",
    });
    await t.client.call("plugin.authorization.check", {});
    await t.time.pass(100);
    expect(notices().notices).toMatchObject([
      { kind: "authorize", plugin: "google", url: "https://google.test/calendar" },
    ]);
    expect(shown()).toMatchObject({
      plugins: [{ id: "google", activity: "authorizing" }],
    });
    await t.client.call("plugin.authorization.check", {});
    await t.time.pass(100);
    expect(t.api.seen("POST", installPath).at(-1)!.body).toMatchObject({
      authorization_state: "calendar",
      verify_only: true,
    });
    expect(shown()).toMatchObject({ installed: ["google"] });
  });

  it("lets a check still under way at the deadline go, and keeps nothing of its late answer", async () => {
    const t = setup();
    const installPath = `${catalogPath}/linear/install`;
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    const lateCheck = Promise.withResolvers<ReturnType<typeof json>>();
    let asked = 0;
    t.api.on("POST", installPath, () => {
      asked += 1;
      if (asked === 1)
        return json(200, {
          plugin: plugin("linear"),
          authorization: { state: "attempt-1" },
        });
      // The first check hangs; so does each after it.
      return asked === 2 ? lateCheck.promise : new Promise(() => {});
    });
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    await t.time.pass(100);
    void t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(2_100, 100);
    expect(shown()).toMatchObject({
      plugins: [{ id: "linear", activity: "verifying" }],
    });
    await t.time.pass(118_500, 1_000);
    expect(notices().notices).toMatchObject([
      { kind: "authorization_timed_out", plugin: "linear" },
    ]);
    expect(shown()).toMatchObject({ plugins: [{ id: "linear", activity: "idle" }] });

    // Added again while the first check's answer comes in late.
    const next = Promise.withResolvers<ReturnType<typeof json>>();
    t.api.on("POST", installPath, () => next.promise);
    void t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(100);
    lateCheck.resolve(
      json(200, { plugin: plugin("linear", { installed: true }), authorization: null })
    );
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      installed: [],
      plugins: [{ id: "linear", installed: false, activity: "installing" }],
    });
    next.resolve(json(200, { plugin: plugin("linear"), authorization: null }));
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      installed: [],
      plugins: [{ id: "linear", activity: "idle" }],
    });
  });

  it("keeps checking an authorization while no page shows the catalog", async () => {
    const t = setup();
    const installPath = `${catalogPath}/linear/install`;
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    let authorized = false;
    t.api.on("POST", installPath, () =>
      json(
        200,
        authorized
          ? { plugin: plugin("linear", { installed: true }), authorization: null }
          : {
              plugin: plugin("linear"),
              authorization: {
                state: "attempt-1",
                authorizationUrl: "https://linear.test/a",
              },
            }
      )
    );
    t.core.observeSession(signedIn());
    const page = { topic: "plugins", workspace: WS };
    const stop = t.client.subscribe(
      page,
      () => undefined,
      () => undefined
    );
    await t.time.pass(100);
    const answer = t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(100);
    await answer;
    stop();
    await t.time.pass(4_100, 250);
    expect(t.api.seen("POST", installPath)).toHaveLength(3);
    authorized = true;
    await t.time.pass(2_100, 250);
    expect(t.api.seen("POST", installPath)).toHaveLength(4);

    // Shown again with the server out of reach: what the check found is kept.
    t.api.on("GET", catalogPath, offline());
    const shown = t.watch<PluginsValue>(page);
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      installed: ["linear"],
      plugins: [{ id: "linear", activity: "idle" }],
    });
  });

  it("words a 503 '…_unavailable' as unavailable, and a code with no wording of its own as general", async () => {
    const t = setup();
    const installPath = `${catalogPath}/linear/install`;
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    t.api.on("POST", installPath, json(503, { error: "upstream_unavailable" }));
    t.core.observeSession(signedIn());
    const notices = t.watch<{ notices: PluginNotice[] }>({ topic: "pluginNotices" });
    await t.time.pass(100);
    void t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(100);
    t.api.on("POST", installPath, json(500, { error: "internal_error" }));
    void t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(100);
    expect(notices().notices).toMatchObject([
      { kind: "install_failed", reason: "unavailable" },
      { kind: "install_failed", reason: "generic" },
    ]);
  });
});

describe("a server from before the one install", () => {
  it("finishes its authorize step as part of the one install", async () => {
    const t = setup();
    const installed = plugin("linear", { installed: true });
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    t.api.on("POST", `${catalogPath}/linear/install`, installed);
    t.api.on("POST", `${catalogPath}/linear/authorize`, {
      state: "legacy-state",
      authorizationUrl: "https://linear.test/authorize?state=legacy-state",
    });
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    await expect(
      t.client.call("plugin.install", { workspace: WS, plugin: "linear" })
    ).resolves.toEqual({
      authorizationUrl: "https://linear.test/authorize?state=legacy-state",
    });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      plugins: [{ id: "linear", installed: false, activity: "authorizing" }],
    });
  });

  it("rolls its install back when a check would start another authorization", async () => {
    const t = setup();
    const installed = plugin("linear", { installed: true });
    t.api.on("GET", catalogPath, { data: [plugin("linear")] });
    t.api.on("POST", `${catalogPath}/linear/install`, installed);
    t.api.on("POST", `${catalogPath}/linear/authorize`, { state: "replacement" });
    t.api.on("DELETE", `${catalogPath}/linear`, plugin("linear"));
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    await t.client.call("plugin.install", { workspace: WS, plugin: "linear" });
    await t.time.pass(2_100, 100);
    expect(t.api.seen("DELETE", `${catalogPath}/linear`)).toHaveLength(1);
    expect(shown()).toMatchObject({
      plugins: [{ id: "linear", installed: false, activity: "idle" }],
    });
  });
});

describe("the onboarding's apps", () => {
  it("waits for the workspace, saying when the network is gone, then lists the integrations most people connect first", async () => {
    const t = setup();
    let ready = false;
    let reachable = false;
    t.api.on("POST", "/v1/comma/me/bootstrap", () =>
      !reachable
        ? offline()
        : json(
            200,
            ready
              ? { status: "ready", workspace }
              : { status: "provisioning", retry_after_seconds: 30, workspace }
          )
    );
    t.api.on("GET", catalogPath, {
      data: [
        plugin("zendesk"),
        plugin("github"),
        plugin("figma", { category: "Design" }),
        plugin("google"),
        plugin("locked", { locked: true }),
      ],
    });
    t.core.observeSession(signedIn());
    const apps = t.watch<OnboardingPluginList>({ topic: "onboardingApps" });
    await t.time.pass(100);
    expect(apps()).toEqual({ status: "preparing", unreachable: true });

    reachable = true;
    await t.time.pass(10_000, 500);
    expect(apps()).toEqual({ status: "preparing" });
    // retry_after is clamped to 10 s.
    ready = true;
    await t.time.pass(10_000, 500);
    expect(t.api.seen("POST", "/v1/comma/me/bootstrap")).toHaveLength(3);
    expect(apps()).toMatchObject({
      status: "ready",
      rows: [{ id: "google" }, { id: "github" }, { id: "zendesk" }],
    });
  });
});

const source = (state: string) => ({
  connectionId: "c-1",
  toolkit: "gmail",
  kind: "composio",
  state,
  candidates: [{ id: "acct-1" }],
});

describe("a plugin's personal sources", () => {
  it("confirms an account, and reads the connections again once it is confirmed", async () => {
    const t = setup();
    const sourcesPath = `${catalogPath}/google/personal-sources`;
    let confirmed = false;
    t.api.on("GET", sourcesPath, () =>
      json(200, {
        pluginId: "google",
        sources: [source(confirmed ? "ready" : "needs_confirmation")],
      })
    );
    t.api.on("POST", `${sourcesPath}/prepare`, {
      state: "confirm-1",
      toolkit: "gmail",
      connectionId: "c-1",
      identity: "me@example.test",
    });
    t.api.on("POST", `${sourcesPath}/confirm`, () => {
      confirmed = true;
      return json(200, { state: "ready", toolkit: "gmail", connectionId: "c-1" });
    });
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginSourcesValue>({
      topic: "pluginSources",
      workspace: WS,
      plugin: "google",
    });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      sources: [{ state: "needs_confirmation" }],
      confirmation: null,
    });
    await t.client.call("plugin.sources.prepare", {
      workspace: WS,
      plugin: "google",
      toolkit: "gmail",
      account: "acct-1",
    });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      confirmation: { identity: "me@example.test" },
      pending: null,
    });
    await t.client.call("plugin.sources.confirm", { workspace: WS, plugin: "google" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      sources: [{ state: "ready" }],
      confirmation: null,
      pending: null,
      error: null,
    });
  });
});

describe("a run of the plugin catalog, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    let catalogUp = false;
    t.api.on("GET", catalogPath, () =>
      catalogUp ? json(200, { data: [plugin("github")] }) : offline()
    );
    let authorized = false;
    t.api.on("POST", `${catalogPath}/github/install`, () =>
      json(
        200,
        authorized
          ? { plugin: plugin("github", { installed: true }), authorization: null }
          : {
              plugin: plugin("github"),
              authorization: {
                state: "attempt-1",
                authorizationUrl: "https://github.test/authorize",
              },
            }
      )
    );
    t.core.observeSession(signedIn());
    const shown = t.watch<PluginsValue>({ topic: "plugins", workspace: WS });
    await t.time.pass(100);
    // The first read fails; the next one, 10 s on, finds the catalog.
    catalogUp = true;
    await t.time.pass(10_000, 250);
    const answer = t.client.call("plugin.install", { workspace: WS, plugin: "github" });
    await t.time.pass(100);
    await answer;
    await t.time.pass(4_100, 250);
    authorized = true;
    await t.time.pass(2_100, 250);
    expect(shown()).toMatchObject({ installed: ["github"] });

    const recorded = t.core.recorder!;
    const kinds = new Set(recorded.inputs.map((input) => input.kind));
    expect([...kinds]).toEqual(
      expect.arrayContaining(["tick", "response", "failure", "ui"])
    );
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
