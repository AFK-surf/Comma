import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import {
  miniAppCapabilityOps,
  type MiniAppCapability,
  type MiniAppDecisionRequest,
  type MiniAppDecisionResult,
} from "@comma/miniapp-sdk";
import { createFrameComma } from "@comma/miniapp-sdk/frame";
import { describe, expect, it } from "vitest";
import type {
  MiniAppBundle,
  MiniAppInvokeResult,
  MiniAppSessionInfo,
  MiniAppsValue,
  MiniAppValue,
} from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../src/testing/index.ts";

const workspace = { group_id: "g", id: "wsp", name: "Work", status: "ready" };
const appsPath = "/v1/comma/workspaces/wsp/apps";

const app = (id = "a1", extra: Record<string, unknown> = {}) => ({
  id,
  slug: `s-${id}`,
  workspace_id: "wsp",
  name: `App ${id}`,
  description: "Tracks habits",
  icon_url: null,
  repo: { owner: "me", name: `comma-app-${id}` },
  visibility: "private",
  status: "active",
  live_version: 2,
  latest_version: 3,
  author: { name: "Ada" },
  capabilities: [
    "identity.basic",
    "ai.chat",
    "web.search",
    "chat.draft",
    "tasks.create",
    "files.pick",
    "drive.app_folder",
    "calendar.read",
    "notifications",
    "clipboard.write",
    "links.open",
  ],
  egress: ["api.open-meteo.com"],
  storage: ["app", "user", "device"],
  has_backend: true,
  secrets: [],
  grants: [],
  installed: false,
  install: null,
  created_at: "2026-10-01T00:00:00Z",
  updated_at: "2026-10-01T00:00:00Z",
  ...extra,
});

const opened = (id = "a1", extra: Record<string, unknown> = {}, guest = false) => ({
  app: app(id, extra),
  version: 2,
  digest: `digest-${id}`,
  viewer: { id: `pairwise-${id}`, name: "Ada Lovelace", avatar_url: null },
  guest,
});

/** A ustar archive of `files`, as the station packs `dist/`. */
function tar(files: Record<string, string>): Uint8Array {
  const blocks: Uint8Array[] = [];
  const enc = new TextEncoder();
  for (const [name, text] of Object.entries(files)) {
    const data = enc.encode(text);
    const header = new Uint8Array(512);
    header.set(enc.encode(name), 0);
    header.set(enc.encode(data.length.toString(8).padStart(11, "0")), 124);
    header[156] = 0x30;
    header.set(enc.encode("ustar"), 257);
    blocks.push(header);
    const body = new Uint8Array(Math.ceil(data.length / 512) * 512);
    body.set(data);
    blocks.push(body);
  }
  blocks.push(new Uint8Array(1024));
  const out = new Uint8Array(blocks.reduce((n, b) => n + b.length, 0));
  let at = 0;
  for (const b of blocks) {
    out.set(b, at);
    at += b.length;
  }
  return out;
}

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspace] });
  const core = startTestCore(host);
  const connect = () =>
    new CoreClient(inProcessOpener(core, host), { schedule: () => undefined });
  const client = connect();
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      () => undefined
    );
    return () => values.get(key) as T;
  };
  core.observeSession(signedIn());
  return { host, core, client, connect, time: host.time!, api: host.api, watch };
}

type Setup = ReturnType<typeof setup>;

function frame(t: Setup, s: MiniAppSessionInfo, grants: MiniAppCapability[]) {
  return createFrameComma({
    init: {
      app: { id: s.app.id, name: "Test app", version: s.version },
      viewer: null,
      theme: "light",
      tokens: {},
      locale: "en",
      timeZone: "UTC",
      capabilities: s.capabilities,
      grants,
      storage: [],
      backend: false,
    },
    capabilityOps: miniAppCapabilityOps,
    assetUrl: () => undefined,
    call: async (op, args) => {
      const result = await invoke(t, s.session, op, args);
      if (result.status === "done") return result.value;
      if (result.status === "error") throw result;
      throw { code: "not_granted", message: "Permission required." };
    },
  }).comma;
}

const decision: MiniAppDecisionRequest = {
  state: { message: "Schedule a team meeting" },
  questions: {
    route: {
      type: "choice",
      instructions: "Select the task",
      criteria: { meeting: "Arrange a meeting", none: "No task" },
    },
    relevant: { type: "noul", instructions: "Does this need action?" },
    urgency: {
      type: "score",
      instructions: "Rate urgency",
      criteria: ["Routine", "Urgent"],
    },
  },
};

const decisionResult: MiniAppDecisionResult = {
  model: "decision-model",
  answers: {
    route: {
      type: "choice",
      choice: "meeting",
      probabilities_bp: { meeting: 9000, none: 1000 },
      confidence_bp: 8123,
    },
    relevant: { type: "noul", probability_bp: 9234 },
    urgency: {
      type: "score",
      score_milli: 800,
      probabilities_bp: { "0": 2000, "1": 8000 },
      confidence_bp: 7000,
    },
  },
};

const version = (r: SeenRequest) =>
  r.headers?.find(([name]) => name === "x-comma-app-version")?.[1];

const via = (r: SeenRequest) =>
  r.headers?.find(([name]) => name === "x-comma-app-via")?.[1];

async function open(
  t: Setup,
  id = "a1",
  extra: Record<string, unknown> = {},
  options: {
    guest?: boolean;
    client?: CoreClient;
    token?: string;
    platform?: "mac" | "web";
    version?: number;
  } = {}
) {
  t.api.on("POST", `/v1/comma/apps/${id}/open`, opened(id, extra, options.guest));
  return (await (options.client ?? t.client).call("miniApps.session.open", {
    app: id,
    via: options.token ? { token: options.token } : { workspace: "wsp" },
    platform: options.platform ?? "web",
    ...(options.version !== undefined ? { version: options.version } : {}),
  })) as MiniAppSessionInfo;
}

const invoke = (
  t: Setup,
  session: string,
  op: string,
  args: unknown = {},
  confirmed?: boolean,
  client = t.client
) =>
  client.call("miniApps.invoke", {
    session,
    op,
    args,
    ...(confirmed ? { confirmed } : {}),
  }) as Promise<MiniAppInvokeResult>;

describe("a Workspace's apps", () => {
  it("lists them, shows a made app at once, and its settings page reads Versions and the link", async () => {
    const t = setup();
    t.api.on("GET", appsPath, { data: [app("a1")] });
    const list = t.watch<MiniAppsValue>({ topic: "miniApps", workspace: "wsp" });
    await t.time.pass(100);
    expect(list()).toMatchObject({ status: "ready", apps: [{ id: "a1" }] });

    t.api.on("POST", appsPath, app("a2"));
    await t.client.call("miniApps.create", { workspace: "wsp", name: "Habit tracker" });
    expect(t.api.seen("POST", appsPath)[0]!.body).toEqual({ name: "Habit tracker" });
    await t.time.pass(100);
    expect(list().apps.map((a) => a.id)).toEqual(["a2", "a1"]);

    t.api.on("GET", `${appsPath}/a1`, {
      ...app("a1"),
      versions: [
        {
          number: 2,
          state: "ready",
          commit: "c2",
          digest: "d2",
          has_backend: false,
          live: true,
        },
      ],
    });
    t.api.on("GET", `${appsPath}/a1/link`, { link: null });
    const detail = t.watch<MiniAppValue>({
      topic: "miniApp",
      workspace: "wsp",
      app: "a1",
    });
    await t.time.pass(100);
    expect(detail()).toMatchObject({
      status: "ready",
      app: { id: "a1" },
      versions: [{ number: 2, live: true }],
      link: null,
    });

    t.api.on("PUT", `${appsPath}/a1/link`, {
      token: "tok1",
      url: "https://app.comma.surf/a/tok1",
      created_at: "now",
    });
    await t.client.call("miniApps.link.publish", { workspace: "wsp", app: "a1" });
    await t.time.pass(100);
    expect(detail().link).toMatchObject({ token: "tok1" });
    t.api.on("DELETE", `${appsPath}/a1/link`, { status: "revoked" });
    await t.client.call("miniApps.link.revoke", { workspace: "wsp", app: "a1" });
    await t.time.pass(100);
    expect(detail().link).toBeNull();

    t.api.on("DELETE", `${appsPath}/a1`, { status: "deleted" });
    await t.client.call("miniApps.delete", { workspace: "wsp", app: "a1" });
    await t.time.pass(100);
    expect(list().apps.map((a) => a.id)).toEqual(["a2"]);
    expect(detail().status).toBe("missing");
  });

  it("publishes the Version the viewer previewed", async () => {
    const t = setup();
    t.api.on("POST", `${appsPath}/a1/publish`, app("a1", { live_version: 3 }));
    await t.client.call("miniApps.publish", {
      workspace: "wsp",
      app: "a1",
      group: "g",
      conversation: "task-1",
      reviewVersion: 4,
      version: 3,
      visibility: "workspace",
    });
    expect(t.api.seen("POST", `${appsPath}/a1/publish`)[0]!.body).toEqual({
      group_id: "g",
      conversation_id: "task-1",
      review_version: 4,
      version: 3,
      visibility: "workspace",
    });
  });

  it("revokes a grant from Settings for what runs now", async () => {
    const t = setup();
    const s = await open(t, "a1", { grants: ["identity.basic"] });
    expect((await invoke(t, s.session, "viewer")).status).toBe("done");
    t.api.on("PUT", `${appsPath}/a1/grants`, app("a1", { grants: [] }));
    await t.client.call("miniApps.grants.set", {
      workspace: "wsp",
      app: "a1",
      grants: [],
    });
    expect(await invoke(t, s.session, "viewer")).toEqual({
      status: "grant",
      capability: "identity.basic",
    });
  });
});

describe("an opened app's calls", () => {
  it("shares one AI grant for chat and decisions, with bounded decision input", async () => {
    const t = setup();
    const s = await open(t, "a1", { capabilities: ["ai.chat"] }, { version: 2 });
    const path = "/v1/comma/apps/a1/ai/decide";
    const chatPath = "/v1/comma/apps/a1/ai/chat";
    const messages = [{ role: "user" as const, content: "Hello" }];
    const chatReply = { role: "assistant", content: "Hi" };
    t.api.on("POST", path, decisionResult);
    t.api.on("POST", chatPath, { message: chatReply });
    expect(await invoke(t, s.session, "ai.decide", decision)).toEqual({
      status: "grant",
      capability: "ai.chat",
    });
    expect(t.api.seen("POST", path)).toHaveLength(0);
    t.api.on(
      "PUT",
      `${appsPath}/a1/grants`,
      app("a1", { capabilities: ["ai.chat"], grants: ["ai.chat"] })
    );
    await t.client.call("miniApps.grant", {
      session: s.session,
      capability: "ai.chat",
    });
    const comma = frame(t, s, ["ai.chat"]);
    expect(comma.supports("ai.decide")).toBe(true);
    expect(await comma.ai.chat(messages)).toEqual(chatReply);
    expect(await comma.ai.decide(decision)).toEqual(decisionResult);
    expect(t.api.seen("PUT", `${appsPath}/a1/grants`)).toHaveLength(1);
    const request = t.api.seen("POST", path)[0]!;
    expect(request.body).toEqual(decision);
    expect(via(request)).toBe("workspace/wsp");
    expect(version(request)).toBe("2");

    await expect(comma.ai.decide({ ...decision, questions: {} })).rejects.toMatchObject(
      { code: "invalid" }
    );
    await expect(
      comma.ai.decide({ ...decision, state: "界".repeat(4096) })
    ).rejects.toMatchObject({ code: "invalid" });
    expect(t.api.seen("POST", path)).toHaveLength(1);

    t.api.on("POST", path, json(429, { error: "rate_limited" }));
    await expect(comma.ai.decide(decision)).rejects.toMatchObject({
      code: "rate_limited",
    });
    t.api.on("POST", path, json(503, { error: "unavailable" }));
    await expect(comma.ai.decide(decision)).rejects.toMatchObject({
      code: "unavailable",
    });

    t.api.on("PUT", `${appsPath}/a1/grants`, app("a1", { grants: [] }));
    await t.client.call("miniApps.grants.set", {
      workspace: "wsp",
      app: "a1",
      grants: [],
    });
    await expect(comma.ai.decide(decision)).rejects.toMatchObject({
      code: "not_granted",
    });
    await expect(comma.ai.chat(messages)).rejects.toMatchObject({
      code: "not_granted",
    });
    expect(t.api.seen("POST", path)).toHaveLength(3);
    expect(t.api.seen("POST", chatPath)).toHaveLength(1);

    const undeclared = await open(t, "a2", {
      capabilities: [],
      grants: ["ai.chat"],
    });
    expect(await invoke(t, undeclared.session, "ai.decide", decision)).toMatchObject({
      status: "error",
      code: "not_granted",
    });
    expect(t.api.seen("POST", "/v1/comma/apps/a2/ai/decide")).toHaveLength(0);
  });

  it("searches through the SDK and core only after a grant, and stops after revocation", async () => {
    const t = setup();
    const s = await open(t, "a1", {}, { version: 2 });
    const path = "/v1/comma/apps/a1/web/search";
    const results = [
      { title: "Comma", url: "https://example.test/comma", text: "A result" },
    ];
    t.api.on("POST", path, { results });

    expect(await invoke(t, s.session, "web.search", { query: "Comma" })).toEqual({
      status: "grant",
      capability: "web.search",
    });
    expect(t.api.seen("POST", path)).toHaveLength(0);
    t.api.on("PUT", `${appsPath}/a1/grants`, app("a1", { grants: ["web.search"] }));
    await t.client.call("miniApps.grant", {
      session: s.session,
      capability: "web.search",
    });

    const comma = frame(t, s, ["web.search"]);

    expect(comma.supports("web.search")).toBe(true);
    expect(await comma.web.search("  Comma  ")).toEqual(results);
    const request = t.api.seen("POST", path)[0]!;
    expect(request.body).toEqual({ query: "Comma" });
    expect(via(request)).toBe("workspace/wsp");
    expect(version(request)).toBe("2");

    await expect(comma.web.search(" ")).rejects.toMatchObject({ code: "invalid" });
    await expect(comma.web.search("x".repeat(2001))).rejects.toMatchObject({
      code: "invalid",
    });
    expect(t.api.seen("POST", path)).toHaveLength(1);

    t.api.on("POST", path, json(503, { error: "unavailable" }));
    await expect(comma.web.search("Comma")).rejects.toMatchObject({
      code: "unavailable",
    });

    t.api.on("PUT", `${appsPath}/a1/grants`, app("a1", { grants: [] }));
    await t.client.call("miniApps.grants.set", {
      workspace: "wsp",
      app: "a1",
      grants: [],
    });
    await expect(comma.web.search("Comma")).rejects.toMatchObject({
      code: "not_granted",
    });
    expect(t.api.seen("POST", path)).toHaveLength(2);

    const undeclared = await open(t, "a2", {
      capabilities: [],
      grants: ["web.search"],
    });
    expect(
      await invoke(t, undeclared.session, "web.search", { query: "Comma" })
    ).toMatchObject({
      status: "error",
      code: "not_granted",
    });
    expect(t.api.seen("POST", "/v1/comma/apps/a2/web/search")).toHaveLength(0);
  });

  it("names the access path on every runtime request and binds the app from the session", async () => {
    const t = setup();
    const s = await open(t);
    expect(via(t.api.seen("POST", "/v1/comma/apps/a1/open")[0]!)).toBe("workspace/wsp");
    expect(s).toMatchObject({ app: { id: "a1" }, version: 2, grants: [] });
    // The manifest's capabilities that the web can use: the calendar is on Mac only.
    expect(s.capabilities).toContain("drive.app_folder");
    expect(s.capabilities).not.toContain("calendar.read");
    expect(s.capabilities).toContain("tasks.create");

    t.api.on("GET", "/v1/comma/apps/a1/storage/app/k", {
      key: "k",
      value: 1,
      version: 4,
    });
    // An app_id in the args names nothing: the session's app is asked.
    expect(
      await invoke(t, s.session, "storage.app.get", { key: "k", app_id: "a2" })
    ).toEqual({ status: "done", value: { value: 1, version: 4 } });
    expect(via(t.api.seen("GET", "/v1/comma/apps/a1/storage/app/k")[0]!)).toBe(
      "workspace/wsp"
    );
    expect(t.api.seen("GET", "/v1/comma/apps/a2/*")).toHaveLength(0);
  });

  it("maps each op", async () => {
    const t = setup();
    const s = await open(t, "a1", {
      grants: ["identity.basic", "ai.chat", "notifications"],
    });

    expect(await invoke(t, s.session, "viewer")).toEqual({
      status: "done",
      value: { id: "pairwise-a1", name: "Ada Lovelace", avatarUrl: null, guest: false },
    });

    t.api.on("POST", "/v1/comma/apps/a1/ai/chat", {
      message: { role: "assistant", content: "Hi" },
    });
    const messages = [{ role: "user", content: "Hello" }];
    expect(await invoke(t, s.session, "ai.chat", { messages })).toEqual({
      status: "done",
      value: { role: "assistant", content: "Hi" },
    });
    expect(t.api.seen("POST", "/v1/comma/apps/a1/ai/chat")[0]!.body).toEqual({
      messages,
    });

    // The host's own effects: allowed, done by the host.
    for (const [op, args] of [
      ["chat.draft", { text: "Add a streak" }],
      ["clipboard.write", { text: "copied" }],
      ["notify", { title: "Done", body: "3 habits" }],
    ] as const)
      expect(await invoke(t, s.session, op, args)).toEqual({
        status: "host",
        op,
        args,
      });

    t.api.on("POST", "/v1/comma/apps/a1/backend/*", (r) =>
      r.path.endsWith("/weather?city=Oslo")
        ? {
            status: 404,
            headers: [["content-type", "text/plain"]],
            body: new TextEncoder().encode("no city"),
          }
        : json(500, {})
    );
    const fetched = await invoke(t, s.session, "backend.fetch", {
      path: "/weather?city=Oslo",
      method: "PUT",
      headers: { "content-type": "text/plain", authorization: "x" },
      body: "hi",
    });
    // The backend's own answer passes through, a 404 too.
    expect(fetched).toMatchObject({
      status: "done",
      value: { status: 404, headers: { "content-type": "text/plain" } },
    });
    const sent = t.api.seen("POST", "/v1/comma/apps/a1/backend/*")[0]!;
    expect(sent.path).toBe("/v1/comma/apps/a1/backend/weather?city=Oslo");
    expect(sent.headers).toContainEqual(["x-comma-app-method", "PUT"]);
    expect(sent.headers).toContainEqual(["content-type", "text/plain"]);
    expect(sent.headers?.some(([name]) => name === "authorization")).toBe(false);
    expect(
      await invoke(t, s.session, "backend.fetch", { path: "/../../workspaces" })
    ).toMatchObject({ status: "error", code: "invalid" });

    t.api.on("PUT", "/v1/comma/apps/a1/storage/user/notes", {
      key: "notes",
      value: "x",
      version: 1,
    });
    expect(
      await invoke(t, s.session, "storage.user.put", { key: "notes", value: "x" })
    ).toEqual({ status: "done", value: { version: 1 } });
    t.api.on("GET", "/v1/comma/apps/a1/storage/user", {
      data: [{ key: "notes", value: "x", version: 1 }],
      has_more: false,
    });
    expect(await invoke(t, s.session, "storage.user.list", { prefix: "no" })).toEqual({
      status: "done",
      value: { items: [{ key: "notes", value: "x", version: 1 }], hasMore: false },
    });
    t.api.on(
      "PUT",
      "/v1/comma/apps/a1/storage/app/count",
      json(409, { error: "version_conflict" })
    );
    expect(
      await invoke(t, s.session, "storage.app.put", {
        key: "count",
        value: 2,
        ifVersion: 1,
      })
    ).toMatchObject({ status: "error", code: "conflict" });
    t.api.on(
      "GET",
      "/v1/comma/apps/a1/storage/app/missing",
      json(404, { error: "not_found" })
    );
    expect(await invoke(t, s.session, "storage.app.get", { key: "missing" })).toEqual({
      status: "done",
      value: null,
    });
  });

  it("fails ops the manifest, the platform or the grants do not allow", async () => {
    const t = setup();
    const s = await open(t, "a1", {
      capabilities: [
        "identity.basic",
        "drive.app_folder",
        "calendar.read",
        "notifications",
      ],
      storage: ["device"],
      has_backend: false,
    });
    expect(await invoke(t, s.session, "clipboard.write", { text: "x" })).toMatchObject({
      status: "error",
      code: "not_granted",
    });
    expect(
      await invoke(t, s.session, "calendar.events", {
        from: "2026-10-01T00:00:00Z",
        to: "2026-10-02T00:00:00Z",
      })
    ).toMatchObject({ status: "error", code: "unsupported" });
    expect(await invoke(t, s.session, "system.exec")).toMatchObject({
      status: "error",
      code: "unsupported",
    });
    expect(await invoke(t, s.session, "storage.app.get", { key: "k" })).toMatchObject({
      status: "error",
      code: "unsupported",
    });
    expect(await invoke(t, s.session, "backend.fetch", { path: "/x" })).toMatchObject({
      status: "error",
      code: "unsupported",
    });
    // Once: the host asks first, and the grant is kept on the app for this Workspace.
    expect(await invoke(t, s.session, "notify", { title: "Hi" })).toEqual({
      status: "grant",
      capability: "notifications",
    });
    t.api.on("PUT", `${appsPath}/a1/grants`, (r) =>
      json(200, app("a1", { grants: (r.body as { grants: string[] }).grants }))
    );
    expect(
      await t.client.call("miniApps.grant", {
        session: s.session,
        capability: "notifications",
      })
    ).toEqual({ grants: ["notifications"] });
    expect(t.api.seen("PUT", `${appsPath}/a1/grants`)[0]!.body).toEqual({
      grants: ["notifications"],
    });
    expect(await invoke(t, s.session, "notify", { title: "Hi" })).toMatchObject({
      status: "host",
    });
    // A capability the manifest does not list cannot be granted.
    await expect(
      t.client.call("miniApps.grant", { session: s.session, capability: "ai.chat" })
    ).rejects.toMatchObject({ code: "invalid_params" });
  });

  it("makes a Task only after the host's confirm", async () => {
    const t = setup();
    const s = await open(t);
    expect(
      await invoke(t, s.session, "tasks.propose", { text: "Plan my week" })
    ).toEqual({
      status: "confirm",
      capability: "tasks.create",
      op: "tasks.propose",
      args: { text: "Plan my week" },
    });
    expect(t.api.seen("POST", "/v1/comma/groups/g/conversations/*")).toHaveLength(0);

    t.api.on("POST", "/v1/comma/groups/g/assistant-chat", {
      group_id: "g",
      id: "home",
      kind: "user_chat",
      title: "Home",
      status: "active",
    });
    t.api.on("POST", "/v1/comma/groups/g/conversations/home/messages", {
      group_id: "g",
      id: "home",
      kind: "user_chat",
      title: "Home",
      status: "active",
      accepted_message_id: "m1",
    });
    expect(
      await invoke(t, s.session, "tasks.propose", { text: "Plan my week" }, true)
    ).toEqual({ status: "done", value: { created: true } });
    expect(
      (
        t.api.seen("POST", "/v1/comma/groups/g/conversations/home/messages")[0]!
          .body as {
          message: unknown;
        }
      ).message
    ).toEqual({ type: "text", text: "Plan my week" });

    // Each time: links and files ask again, and only https links open.
    expect(
      await invoke(t, s.session, "links.open", { url: "http://x.test" })
    ).toMatchObject({
      status: "error",
      code: "invalid",
    });
    expect(
      await invoke(t, s.session, "links.open", { url: "https://x.test" })
    ).toMatchObject({
      status: "confirm",
    });
    expect(
      await invoke(t, s.session, "links.open", { url: "https://x.test" }, true)
    ).toMatchObject({ status: "host", op: "links.open" });
    expect(await invoke(t, s.session, "files.pick", { multiple: true })).toMatchObject({
      status: "confirm",
      capability: "files.pick",
    });
  });

  it("keeps device storage per app and per account, within its bounds", async () => {
    const t = setup();
    const one = await open(t, "a1");
    const two = await open(t, "a2");
    expect(
      await invoke(t, one.session, "storage.device.put", {
        key: "theme",
        value: "dark",
      })
    ).toEqual({ status: "done", value: { version: 1 } });
    expect(
      await invoke(t, one.session, "storage.device.get", { key: "theme" })
    ).toEqual({
      status: "done",
      value: { value: "dark", version: 1 },
    });
    expect(
      await invoke(t, two.session, "storage.device.get", { key: "theme" })
    ).toEqual({
      status: "done",
      value: null,
    });
    expect(
      await invoke(t, one.session, "storage.device.put", {
        key: "theme",
        value: "light",
        ifVersion: 3,
      })
    ).toMatchObject({ status: "error", code: "conflict" });
    expect(
      await invoke(t, one.session, "storage.device.put", {
        key: "big",
        value: "x".repeat(40_000),
      })
    ).toMatchObject({ status: "error", code: "quota_exceeded" });
    expect(await invoke(t, one.session, "storage.device.list", {})).toEqual({
      status: "done",
      value: { items: [{ key: "theme", value: "dark", version: 1 }], hasMore: false },
    });

    // Another viewer on this device sees none of it, and the last one's session is gone.
    t.core.observeSession(signedIn("user-2"));
    await t.time.pass(100);
    expect(
      await invoke(t, one.session, "storage.device.get", { key: "theme" })
    ).toMatchObject({
      status: "error",
    });
    const again = await open(t, "a1");
    expect(
      await invoke(t, again.session, "storage.device.get", { key: "theme" })
    ).toEqual({
      status: "done",
      value: null,
    });
  });

  it("answers only the window that opened the app", async () => {
    const t = setup();
    const s = await open(t);
    const other = t.connect();
    expect(
      await invoke(t, s.session, "clipboard.write", { text: "x" }, false, other)
    ).toMatchObject({ status: "error", code: "invalid" });
  });

  it("limits each app to 60 calls a minute on this device", async () => {
    const t = setup();
    const s = await open(t);
    for (let i = 0; i < 60; i++)
      expect(
        (await invoke(t, s.session, "clipboard.write", { text: "x" })).status
      ).toBe("host");
    expect(await invoke(t, s.session, "clipboard.write", { text: "x" })).toMatchObject({
      status: "error",
      code: "rate_limited",
    });
    await t.time.pass(60_000);
    expect((await invoke(t, s.session, "clipboard.write", { text: "x" })).status).toBe(
      "host"
    );
  });

  it("follows the guest rules", async () => {
    const t = setup();
    const s = await open(t, "a1", { grants: [] }, { guest: true, token: "tok" });
    expect(via(t.api.seen("POST", "/v1/comma/apps/a1/open")[0]!)).toBe("link/tok");
    expect(s.capabilities).not.toContain("tasks.create");
    expect(s.viewer).toMatchObject({ name: "Guest", guest: true });
    expect(await invoke(t, s.session, "web.search", { query: "Comma" })).toMatchObject({
      status: "error",
      code: "signup_required",
    });
    expect(t.api.seen("POST", "/v1/comma/apps/a1/web/search")).toHaveLength(0);
    expect(await invoke(t, s.session, "ai.decide", decision)).toMatchObject({
      status: "error",
      code: "signup_required",
    });
    expect(t.api.seen("POST", "/v1/comma/apps/a1/ai/decide")).toHaveLength(0);
    expect(
      await invoke(t, s.session, "ai.chat", {
        messages: [{ role: "user", content: "x" }],
      })
    ).toMatchObject({ status: "error", code: "signup_required" });
    expect(await invoke(t, s.session, "tasks.propose", { text: "x" })).toMatchObject({
      status: "error",
      code: "unsupported",
    });
    expect(await invoke(t, s.session, "chat.draft", { text: "x" })).toMatchObject({
      status: "host",
    });
    // A link grant has no Install to live on: it lasts this run, with no request.
    expect(
      await t.client.call("miniApps.grant", {
        session: s.session,
        capability: "identity.basic",
      })
    ).toEqual({ grants: ["identity.basic"] });
    expect(t.api.seen("PUT", "*")).toHaveLength(0);
    expect(await invoke(t, s.session, "viewer")).toMatchObject({
      status: "done",
      value: { id: "pairwise-a1", name: "Guest", guest: true },
    });
  });

  it("pauses the app when its owner is out of credit", async () => {
    const t = setup();
    t.api.on("POST", "/v1/comma/apps/a3/open", json(402, { error: "app_paused" }));
    await expect(
      t.client.call("miniApps.session.open", {
        app: "a3",
        via: { workspace: "wsp" },
        platform: "web",
      })
    ).rejects.toMatchObject({ code: "app_paused" });

    const s = await open(t);
    t.api.on("POST", "/v1/comma/apps/a1/backend/*", json(402, { error: "app_paused" }));
    expect(await invoke(t, s.session, "backend.fetch", { path: "/x" })).toMatchObject({
      status: "error",
      code: "app_paused",
    });
    // A paused app stops at once: nothing more is asked of the server.
    const asked = t.api.requests.length;
    expect(await invoke(t, s.session, "storage.app.get", { key: "k" })).toMatchObject({
      status: "error",
      code: "app_paused",
    });
    expect(t.api.requests.length).toBe(asked);
  });

  it("reads the bundle once per digest", async () => {
    const t = setup();
    const bundle = tar({
      "index.html": "<p>hi</p>",
      "assets/app.js": "1",
      "../x": "no",
    });
    t.api.on("GET", `${appsPath}/a1/versions/2/bundle`, {
      status: 200,
      headers: [["content-type", "application/x-tar"]],
      body: bundle,
    });
    const s = await open(t);
    const read = (await t.client.call("miniApps.bundle", {
      session: s.session,
    })) as MiniAppBundle;
    expect(read.files.map((f) => [f.path, f.mime])).toEqual([
      ["index.html", "text/html"],
      ["assets/app.js", "text/javascript"],
    ]);
    expect(new TextDecoder().decode(read.files[0]!.data)).toBe("<p>hi</p>");
    const again = await open(t);
    await t.client.call("miniApps.bundle", { session: again.session });
    expect(t.api.seen("GET", `${appsPath}/a1/versions/2/bundle`)).toHaveLength(1);
  });

  it("shows an app's icon and cover read with the session and access path, once per account, and nothing else", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/apps/a1/icon", {
      status: 200,
      headers: [["content-type", "image/png"]],
      body: new Uint8Array([0x89, 0x50, 0x4e, 0x47]),
    });
    t.api.on("GET", "/v1/comma/apps/a1/cover", {
      status: 200,
      headers: [["content-type", "image/webp"]],
      body: new Uint8Array([0x52, 0x49, 0x46, 0x46]),
    });
    const shown = (topic: Topic) => {
      const seen: { value?: unknown; error?: unknown } = {};
      const stop = t.client.subscribe(
        topic,
        (value) => (seen.value = value),
        (error) => (seen.error = error)
      );
      return { seen, stop };
    };
    const icon = {
      topic: "miniAppImage",
      url: "/v1/comma/apps/a1/icon?v=3",
      workspace: "wsp",
    };
    const cover = {
      topic: "miniAppImage",
      url: "/v1/comma/apps/a1/cover?v=3",
      workspace: "wsp",
    };

    const first = shown(icon);
    const covered = shown(cover);
    await t.time.pass(100);
    expect(first.seen.value).toEqual({
      status: "ready",
      src: "data:image/png;base64,iVBORw==",
    });
    expect(covered.seen.value).toEqual({
      status: "ready",
      src: "data:image/webp;base64,UklGRg==",
    });
    const seen = t.api.seen("GET", "/v1/comma/apps/a1/icon");
    expect(seen[0]!.path).toBe("/v1/comma/apps/a1/icon?v=3");
    expect(via(seen[0]!)).toBe("workspace/wsp");
    expect(via(t.api.seen("GET", "/v1/comma/apps/a1/cover")[0]!)).toBe("workspace/wsp");

    // Shown again, they are the reads kept; another account reads them again.
    first.stop();
    covered.stop();
    await t.time.pass(100);
    const again = shown(cover);
    await t.time.pass(100);
    expect(again.seen.value).toMatchObject({ status: "ready" });
    expect(t.api.seen("GET", "/v1/comma/apps/a1/cover")).toHaveLength(1);
    t.core.observeSession(signedIn("user-2"));
    await t.time.pass(100);
    expect(again.seen.value).toMatchObject({ status: "ready" });
    expect(t.api.seen("GET", "/v1/comma/apps/a1/cover")).toHaveLength(2);
    again.stop();

    // An answer that is not an image shows none; one the server does not have, neither.
    t.api.on("GET", "/v1/comma/apps/a2/icon", {
      status: 200,
      headers: [["content-type", "text/html"]],
      body: new TextEncoder().encode("<p>no</p>"),
    });
    t.api.on("GET", "/v1/comma/apps/a3/cover", json(404, { error: "not_found" }));
    const html = shown({ ...icon, url: "/v1/comma/apps/a2/icon?v=1" });
    const missing = shown({ ...cover, url: "/v1/comma/apps/a3/cover?v=1" });
    await t.time.pass(100);
    expect(html.seen.value).toEqual({ status: "ready", src: null });
    expect(missing.seen.value).toEqual({ status: "ready", src: null });

    // Only an app's icon or cover is read, through one access path.
    const other = shown({ ...icon, url: "/v1/comma/workspaces" });
    const both = shown({ ...icon, link: "tok" });
    await t.time.pass(100);
    expect(other.seen.error).toMatchObject({ code: "invalid_params" });
    expect(both.seen.error).toMatchObject({ code: "invalid_params" });
  });

  it("reads and writes the app's Drive folder through its own routes", async () => {
    const t = setup();
    const s = await open(t, "a1", { grants: ["drive.app_folder"] });
    t.api.on("GET", "/v1/comma/apps/a1/drive", {
      data: [
        { name: "notes.txt", kind: "file", size: 5, updated_at: "2026-10-01" },
        { name: "drafts", kind: "dir", size: null, updated_at: null },
      ],
    });
    expect(await invoke(t, s.session, "drive.list", { path: "/" })).toEqual({
      status: "done",
      value: [
        { name: "notes.txt", kind: "file", size: 5, updatedAt: "2026-10-01" },
        { name: "drafts", kind: "folder", size: null, updatedAt: null },
      ],
    });
    const listed = t.api.seen("GET", "/v1/comma/apps/a1/drive")[0]!;
    expect(listed.path).toBe("/v1/comma/apps/a1/drive?path=");
    expect(via(listed)).toBe("workspace/wsp");

    t.api.on("GET", "/v1/comma/apps/a1/drive/file", {
      status: 200,
      headers: [["content-type", "text/plain"]],
      body: new TextEncoder().encode("hello"),
    });
    const read = (await invoke(t, s.session, "drive.read", { path: "notes.txt" })) as {
      value: { data: Uint8Array; mime: string };
    };
    expect(new TextDecoder().decode(read.value.data)).toBe("hello");
    expect(read.value.mime).toBe("text/plain");

    t.api.on("PUT", "/v1/comma/apps/a1/drive/file", json(200, { status: "ok" }));
    expect(
      await invoke(t, s.session, "drive.write", { path: "sub/a.txt", data: "hi" })
    ).toEqual({ status: "done", value: null });
    const written = t.api.seen("PUT", "/v1/comma/apps/a1/drive/file")[0]!;
    expect(written.path).toBe("/v1/comma/apps/a1/drive/file?path=sub%2Fa.txt");
    expect(new TextDecoder().decode(written.body as Uint8Array)).toBe("hi");

    t.api.on("DELETE", "/v1/comma/apps/a1/drive/file", { status: "deleted" });
    expect(await invoke(t, s.session, "drive.delete", { path: "sub/a.txt" })).toEqual({
      status: "done",
      value: null,
    });
    // Nothing leaves the folder, and a file is at most 20 MiB.
    expect(
      await invoke(t, s.session, "drive.read", { path: "../secret" })
    ).toMatchObject({
      status: "error",
      code: "invalid",
    });
    expect(
      await invoke(t, s.session, "drive.write", {
        path: "big.bin",
        data: new Uint8Array(20 * 1_048_576 + 1),
      })
    ).toMatchObject({ status: "error", code: "quota_exceeded" });
  });

  it("has no Drive folder for a viewer who came through a link", async () => {
    const t = setup();
    const s = await open(t, "a1", { grants: ["drive.app_folder"] }, { token: "tok" });
    expect(s.capabilities).not.toContain("drive.app_folder");
    expect(await invoke(t, s.session, "drive.list", { path: "" })).toMatchObject({
      status: "error",
      code: "unsupported",
    });
    const guest = await open(t, "a2", { grants: [] }, { guest: true, token: "tok2" });
    expect(await invoke(t, guest.session, "drive.list", { path: "" })).toMatchObject({
      status: "error",
      code: "unsupported",
    });
    expect(t.api.seen("GET", "/v1/comma/apps/*/drive")).toHaveLength(0);
  });

  it("lets Main read the calendar on Mac after the grant", async () => {
    const t = setup();
    const s = await open(t, "a1", { grants: [] }, { platform: "mac" });
    expect(s.capabilities).toContain("calendar.read");
    const range = { from: "2026-10-01T00:00:00Z", to: "2026-10-08T00:00:00Z" };
    expect(await invoke(t, s.session, "calendar.events", range)).toEqual({
      status: "grant",
      capability: "calendar.read",
    });
    t.api.on("PUT", `${appsPath}/a1/grants`, (r) =>
      json(200, app("a1", { grants: (r.body as { grants: string[] }).grants }))
    );
    await t.client.call("miniApps.grant", {
      session: s.session,
      capability: "calendar.read",
    });
    expect(await invoke(t, s.session, "calendar.events", range)).toEqual({
      status: "host",
      op: "calendar.events",
      args: range,
    });
    expect(
      await invoke(t, s.session, "calendar.events", {
        from: "2026-01-01T00:00:00Z",
        to: "2027-02-01T00:00:00Z",
      })
    ).toMatchObject({ status: "error", code: "invalid" });
  });

  it("asks for the Version a card previews on every runtime request", async () => {
    const t = setup();
    const s = await open(t, "a1", { grants: ["drive.app_folder"] }, { version: 3 });
    const opening = t.api.seen("POST", "/v1/comma/apps/a1/open")[0]!;
    expect(opening.body).toEqual({});
    expect(version(opening)).toBe("3");
    t.api.on("GET", "/v1/comma/apps/a1/storage/app/k", {
      key: "k",
      value: 1,
      version: 1,
    });
    t.api.on("POST", "/v1/comma/apps/a1/backend/*", json(200, {}));
    t.api.on("GET", "/v1/comma/apps/a1/drive", { data: [] });
    await invoke(t, s.session, "storage.app.get", { key: "k" });
    await invoke(t, s.session, "backend.fetch", { path: "/x" });
    await invoke(t, s.session, "drive.list", { path: "" });
    for (const r of [
      t.api.seen("GET", "/v1/comma/apps/a1/storage/app/k")[0]!,
      t.api.seen("POST", "/v1/comma/apps/a1/backend/*")[0]!,
      t.api.seen("GET", "/v1/comma/apps/a1/drive")[0]!,
    ])
      expect(version(r)).toBe("3");
    // The live app asks for none: the server serves its live Version.
    const live = await open(t, "a1");
    await invoke(t, live.session, "storage.app.get", { key: "k" });
    expect(
      version(t.api.seen("GET", "/v1/comma/apps/a1/storage/app/k")[1]!)
    ).toBeUndefined();
  });
});
