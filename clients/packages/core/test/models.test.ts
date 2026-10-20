import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ModelsValue } from "../src/contract.ts";
import { base64, fromBase64 } from "../src/record.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
  type SeenRequest,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const WS = "wsp_models";
const base = `/v1/comma/workspaces/${WS}`;
const profilesPath = `${base}/subscription-accounts`;

const catalog = {
  sources: {
    openai: { name: "OpenAI", kind: "api_key" },
    codex: { name: "ChatGPT", kind: "subscription" },
    "github-copilot": { name: "GitHub Copilot", kind: "subscription" },
    custom: {
      name: "Custom",
      kind: "api_key",
      endpoint_required: true,
      protocols: ["chat_completions", "responses", "anthropic"],
    },
  },
  models: [
    {
      id: "gpt-5.4",
      name: "GPT-5.4",
      family: "GPT",
      vendor: "openai",
      efforts: ["low", "high"],
      routes: { codex: { model: "gpt-5.4", protocol: "responses" } },
    },
    {
      id: "gpt-5.5",
      name: "GPT-5.5",
      family: "GPT",
      vendor: "openai",
      efforts: ["low", "high"],
      routes: {
        openai: { model: "gpt-5.5", protocol: "responses" },
        codex: { model: "gpt-5.5", protocol: "responses" },
        // Copilot speaks Chat Completions, so it cannot run this one.
        "github-copilot": { model: "gpt-5.5", protocol: "responses" },
      },
    },
  ],
};

const codex = {
  id: "profile-codex",
  credential_kind: "subscription_oauth",
  source: "codex",
  name: "member@example.com",
  disabled: false,
  status: "active",
  version: "v1",
  quota: {
    plan_type: "pro",
    reset_credits: { available_count: 2 },
    windows: [
      { period: "weekly", remaining_percent: 8.4 },
      { period: "five_hour", remaining_percent: 62 },
      // A window for one model is not the account's.
      { period: "5h", remaining_percent: 1, model: "gpt-5.5" },
    ],
  },
};
const openaiKey = {
  id: "profile-key",
  credential_kind: "provider_api_key",
  source: "openai",
  name: "Team key",
  key_hint: "sk-…42",
  disabled: true,
  status: "active",
  version: "v1",
};
const tokenDance = {
  id: "profile-td",
  credential_kind: "provider_api_key",
  source: "custom",
  name: "TokenDance",
  models: ["gpt-5.5", "local-llm"],
  connection: {
    endpoint: "https://tokendance.space/gateway/v1/chat/completions",
    protocol: "openai_completions",
  },
  disabled: false,
  status: "active",
  version: "v1",
};
const router = {
  agent_id: "router",
  name: "Router",
  role: "router",
  selection: { kind: "builtin" },
};
const taskModel = {
  kind: "catalog",
  model: "gpt-5.5",
  reasoning_effort: "high",
  allow_paid: false,
  profile_id: null,
};

type Json = Record<string, unknown>;

/**
 * The profile and Agent endpoints over `state`: writes change it, as the server would. Without `taskPlace` the Agents
 * read leaves the place out, as a server older than it does.
 */
function setup(
  state: { profiles: Json[]; taskModel?: Json; taskPlace?: Json; replyStyle?: string },
  host = new FakeHost()
) {
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: WS, group_id: "grp", name: "Main" }],
  });
  host.api.on("GET", "/v1/comma/model-catalog", catalog);
  host.api.on("GET", profilesPath, () =>
    json(200, { accounts: state.profiles, next: "" })
  );
  host.api.on("GET", `${base}/agent-models`, () =>
    json(200, {
      workspace_id: WS,
      agents: {
        router: state.replyStyle
          ? { ...router, reply_style: state.replyStyle }
          : router,
      },
      task_model: { selection: state.taskModel ?? taskModel },
      ...(state.taskPlace ? { task_place: { place: state.taskPlace } } : {}),
    })
  );
  host.api.on("PATCH", `${profilesPath}/*`, (request: SeenRequest) => {
    const id = request.path.split("/").at(-1)!;
    const at = state.profiles.findIndex((p) => p.id === id);
    const { version, ...patch } = request.body as Json;
    if (state.profiles[at]!.version !== version)
      return json(409, { error: "conflict" });
    state.profiles[at] = {
      ...state.profiles[at],
      ...patch,
      version: `${version as string}+`,
    };
    return json(200, state.profiles[at]);
  });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as T;
  };
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch, state };
}

const profileOf = (value: ModelsValue, id: string) =>
  value.profiles?.find((p) => p.id === id);

describe("Settings › Model & API", () => {
  it("reads the catalog, profiles and Agents, and works out what serves each model", async () => {
    const t = setup({ profiles: [codex, openaiKey, tokenDance] });
    const shown = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    await t.time.pass(100);
    const value = shown();
    expect(value).toMatchObject({ workspace: WS, error: false, moreProfiles: false });
    // Tiles for the catalog's sources only: OpenAI with its plan (a device code), Copilot, Custom and Ollama.
    expect(value.presets.map((p) => p.id)).toEqual([
      "openai",
      "github-copilot",
      "ollama",
      "custom",
    ]);
    expect(value.presets[0]).toMatchObject({
      keySource: "openai",
      subscriptionSource: "codex",
      deviceSignIn: true,
    });
    expect(profileOf(value, "profile-codex")).toMatchObject({
      subscription: true,
      usable: true,
      preset: "openai",
      tokenDance: false,
      meters: [
        { window: "5h", percent: 62 },
        { window: "week", percent: 8 },
      ],
      servable: [
        { model: "gpt-5.4", request: "gpt-5.4" },
        { model: "gpt-5.5", request: "gpt-5.5" },
      ],
    });
    expect(profileOf(value, "profile-key")).toMatchObject({ usable: false });
    expect(profileOf(value, "profile-td")).toMatchObject({
      tokenDance: true,
      servable: [
        { model: "gpt-5.5", request: "gpt-5.5" },
        { model: "local-llm", request: "local-llm" },
      ],
    });
    // An off key serves nothing; an id only the Custom endpoint lists runs as listed.
    expect(value.models.map((m) => [m.id, m.serving, m.custom ?? false])).toEqual([
      ["gpt-5.4", ["profile-codex"], false],
      ["gpt-5.5", ["profile-codex", "profile-td"], false],
      ["local-llm", ["profile-td"], true],
    ]);
    // The server leaves out the default place: Tasks run inside Comma's cloud.
    expect(value.agents).toEqual({
      workspace_id: WS,
      agents: { router },
      task_model: { selection: taskModel },
      task_place: { place: { kind: "salix" } },
    });
  });

  it("says when a read fails, and keeps what was read", async () => {
    const t = setup({ profiles: [] });
    const page = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    await t.time.pass(100);
    expect(page()).toMatchObject({ error: false, agents: { workspace_id: WS } });

    t.api.on("GET", "/v1/comma/model-catalog", offline());
    const refreshed = t.client.call("models.refresh", {});
    await t.time.pass(100);
    await refreshed;
    // What was read stays on the page next to the failure.
    expect(page()).toMatchObject({ error: true, agents: { workspace_id: WS } });
  });

  it("reads once for a page refreshed as it opens, and again for a refresh after that read", async () => {
    const t = setup({ profiles: [codex] });
    const reads = () =>
      ["/v1/comma/model-catalog", profilesPath, `${base}/agent-models`].map(
        (path) => t.api.seen("GET", path).length
      );
    // The page starts the topic, and its entry asks again while that read runs.
    const release = t.api.hold("GET", "/v1/comma/model-catalog");
    const page = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    await t.time.pass(100);
    const entered = t.client.call("models.refresh", {});
    await t.time.pass(100);
    release();
    await t.time.pass(100);
    await entered;
    expect(page()).toMatchObject({ workspace: WS, error: false });
    expect(reads()).toEqual([1, 1, 1]);

    const again = t.client.call("models.refresh", {});
    await t.time.pass(100);
    await again;
    expect(reads()).toEqual([2, 2, 2]);
  });

  it("saves a profile's model choices in order, each with the version the last answered, showing the latest at once", async () => {
    const t = setup({ profiles: [structuredClone(codex)] });
    const shown = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    await t.time.pass(100);
    const release = t.api.hold("PATCH", `${profilesPath}/profile-codex`);
    const offer = (models: string[], on: boolean) =>
      t.client.call("models.offer", {
        workspace: WS,
        profile: "profile-codex",
        models,
        on,
      });
    const first = offer(["gpt-5.5"], false);
    const second = offer(["gpt-5.4"], false);
    await t.time.pass(100);
    expect(profileOf(shown(), "profile-codex")?.disabled_models).toEqual([
      "gpt-5.5",
      "gpt-5.4",
    ]);
    // Neither model serves through the profile while they are off.
    expect(shown().models.every((m) => m.serving.length === 0)).toBe(true);
    release();
    await first;
    await second;
    await t.time.pass(100);
    const bodies = t.api
      .seen("PATCH", `${profilesPath}/profile-codex`)
      .map((r) => r.body);
    expect(bodies).toEqual([
      { version: "v1", disabled_models: ["gpt-5.5"] },
      { version: "v1+", disabled_models: ["gpt-5.5", "gpt-5.4"] },
    ]);
    expect(profileOf(shown(), "profile-codex")).toMatchObject({
      version: "v1++",
      disabled_models: ["gpt-5.5", "gpt-5.4"],
    });

    // Changed elsewhere: the save is refused, and the profiles are read again.
    t.state.profiles[0]!.version = "v9";
    const reads = t.api.seen("GET", profilesPath).length;
    const refused = expect(offer(["gpt-5.5"], true)).rejects.toMatchObject({
      code: "conflict",
      status: 409,
    });
    await t.time.pass(100);
    await refused;
    expect(t.api.seen("GET", profilesPath)).toHaveLength(reads + 1);
    expect(profileOf(shown(), "profile-codex")?.version).toBe("v9");
  });

  it("keeps a quota reset's request id on the device until the provider's outcome is known", async () => {
    const host = new FakeHost();
    const first = setup({ profiles: [structuredClone(codex)] }, host);
    first.api.on("POST", `${profilesPath}/profile-codex/quota/reset`, json(503, {}));
    first.watch({ topic: "models", prefer: WS });
    await first.time.pass(100);
    const reset = () =>
      first.client.call("models.resetQuota", {
        workspace: WS,
        profile: "profile-codex",
      });
    const lost = expect(reset()).rejects.toMatchObject({ status: 503 });
    await first.time.pass(100);
    await lost;
    first.core.close();

    // The next run asks with the same id; the provider answers.
    const again = setup({ profiles: [structuredClone(codex)] }, host);
    again.api.on("POST", `${profilesPath}/profile-codex/quota/reset`, {
      outcome: "reset",
      account: { ...codex, version: "v2" },
      quota_refreshed: false,
    });
    const shown = again.watch<ModelsValue>({ topic: "models", prefer: WS });
    await again.time.pass(100);
    const done = again.client.call("models.resetQuota", {
      workspace: WS,
      profile: "profile-codex",
    });
    await again.time.pass(100);
    await expect(done).resolves.toEqual({ outcome: "reset", quota_refreshed: false });
    const ids = host.api
      .seen("POST", `${profilesPath}/profile-codex/quota/reset`)
      .map((r) => (r.body as { request_id: string }).request_id);
    expect(ids).toHaveLength(2);
    expect(ids[0]).toBe(ids[1]);
    expect(profileOf(shown(), "profile-codex")?.version).toBe("v2");
  });

  it("asks again with the server's pending reset, and reads the profiles again on a 409", async () => {
    const t = setup({
      profiles: [
        { ...codex, reset_attempt: { request_id: "req-pending", outcome: "pending" } },
      ],
    });
    t.api.on(
      "POST",
      `${profilesPath}/profile-codex/quota/reset`,
      json(409, {
        error: "reset_in_progress",
      })
    );
    t.watch({ topic: "models", prefer: WS });
    await t.time.pass(100);
    const reads = t.api.seen("GET", profilesPath).length;
    const refused = expect(
      t.client.call("models.resetQuota", { workspace: WS, profile: "profile-codex" })
    ).rejects.toMatchObject({ code: "reset_in_progress", status: 409 });
    await t.time.pass(100);
    await refused;
    expect(
      t.api.seen("POST", `${profilesPath}/profile-codex/quota/reset`)[0]!.body
    ).toEqual({ version: "v1", request_id: "req-pending" });
    expect(t.api.seen("GET", profilesPath)).toHaveLength(reads + 1);
  });

  it("adds an endpoint's profile with the models it lists, named for its host", async () => {
    const t = setup({ profiles: [] });
    const listed = [
      { id: "llama3.2:3b" },
      { id: "llama3.2:3b" },
      { id: "x".repeat(201) },
    ];
    t.api.on("POST", `${base}/model-discovery`, () => json(200, { data: listed }));
    t.api.on("POST", profilesPath, (request: SeenRequest) =>
      json(201, {
        ...(request.body as Json),
        id: "profile-new",
        disabled: false,
        status: "active",
        version: "v1",
      })
    );
    const shown = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    await t.time.pass(100);
    const create = () =>
      t.client.call("models.createProfile", {
        workspace: WS,
        source: "custom",
        base_url: "https://llm.example.com/v1",
        protocol: "chat_completions",
        discover: true,
      });
    const created = create();
    await t.time.pass(100);
    await created;
    expect(t.api.seen("POST", `${base}/model-discovery`)[0]!.body).toEqual({
      base_url: "https://llm.example.com/v1",
      protocol: "chat_completions",
    });
    expect(t.api.seen("POST", profilesPath)[0]!.body).toEqual({
      credential_kind: "provider_api_key",
      source: "custom",
      name: "llm.example.com",
      base_url: "https://llm.example.com/v1",
      protocol: "chat_completions",
      models: ["llama3.2:3b"],
    });
    expect(shown().profiles?.map((p) => p.id)).toEqual(["profile-new"]);

    // An endpoint that lists nothing usable adds nothing.
    listed.splice(0, 2);
    const none = expect(create()).rejects.toMatchObject({ code: "no_models" });
    await t.time.pass(100);
    await none;
    expect(t.api.seen("POST", profilesPath)).toHaveLength(1);
  });

  it("keeps a new API key out of every topic while it is saved", async () => {
    const t = setup({ profiles: [structuredClone(openaiKey)] });
    const shown = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    const doing = t.watch<unknown>({ topic: "doing" });
    await t.time.pass(100);
    const release = t.api.hold("PATCH", `${profilesPath}/profile-key`);
    const saved = t.client.call("models.updateProfile", {
      workspace: WS,
      profile: "profile-key",
      api_key: "sk-secret-123",
    });
    await t.time.pass(100);
    expect(JSON.stringify([shown(), doing()])).not.toContain("sk-secret-123");
    release();
    await t.time.pass(100);
    await saved;
    expect(t.api.seen("PATCH", `${profilesPath}/profile-key`)[0]!.body).toEqual({
      version: "v1",
      api_key: "sk-secret-123",
    });
  });

  it("shows an Agent's choice at once, saves one Agent's choices in order, and reads the Agents again after a refusal", async () => {
    const t = setup({ profiles: [codex] });
    const selections: unknown[] = [];
    t.api.on("PUT", `${base}/agents/router/model`, (request: SeenRequest) => {
      const { selection } = request.body as { selection: { model?: string } };
      if (selection.model === "gpt-5.4")
        return json(400, { error: "invalid_model_configuration" });
      selections.push(selection);
      return json(200, {});
    });
    const shown = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    await t.time.pass(100);
    const choose = (model: string) =>
      t.client.call("models.setAgentModel", {
        workspace: WS,
        agent: "router",
        selection: {
          kind: "catalog",
          model,
          reasoning_effort: "low",
          allow_paid: false,
          profile_id: null,
        },
      });
    const release = t.api.hold("PUT", `${base}/agents/router/model`);
    const refused = expect(choose("gpt-5.4")).rejects.toMatchObject({ status: 400 });
    const later = choose("gpt-5.5");
    await t.time.pass(100);
    expect(shown().agents?.agents.router.selection).toMatchObject({
      model: "gpt-5.5",
      reasoning_effort: "low",
    });
    const reads = t.api.seen("GET", `${base}/agent-models`).length;
    release();
    await refused;
    await later;
    await t.time.pass(100);
    // The refusal read the Agents again; the later choice, saved after it, is what shows.
    expect(t.api.seen("GET", `${base}/agent-models`)).toHaveLength(reads + 1);
    expect(selections).toEqual([expect.objectContaining({ model: "gpt-5.5" })]);
    expect(shown().agents?.agents.router.selection).toMatchObject({
      model: "gpt-5.5",
    });
  });

  it("shows the default Task model at once, saves a workspace's choices in order, and reads the Agents again after a refusal", async () => {
    const t = setup({ profiles: [codex], taskModel: { kind: "builtin" } });
    const sent: unknown[] = [];
    t.api.on("PUT", `${base}/task-model`, (request: SeenRequest) => {
      const { selection } = request.body as { selection: Json };
      sent.push(selection);
      if (selection.model === "gpt-5.4")
        return json(400, { error: "invalid_model_configuration" });
      // The server stores the choice with the effort it settles on.
      t.state.taskModel = { ...selection, reasoning_effort: "high" };
      return json(200, { selection: t.state.taskModel });
    });
    const shown = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    await t.time.pass(100);
    expect(shown().agents?.task_model).toEqual({ selection: { kind: "builtin" } });

    await expect(
      t.client.call("models.setTaskModel", {
        workspace: WS,
        // A runtime's model is an Agent's, never the workspace default.
        selection: { kind: "runtime", model: "gpt-5.5", reasoning_effort: null },
      } as never)
    ).rejects.toMatchObject({ code: "invalid_params" });

    const choose = (model: string) =>
      t.client.call("models.setTaskModel", {
        workspace: WS,
        selection: {
          kind: "catalog",
          model,
          reasoning_effort: null,
          allow_paid: true,
          profile_id: "profile-codex",
        },
      });
    const release = t.api.hold("PUT", `${base}/task-model`);
    const refused = expect(choose("gpt-5.4")).rejects.toMatchObject({ status: 400 });
    const later = choose("gpt-5.5");
    await t.time.pass(100);
    expect(shown().agents?.task_model.selection).toEqual({
      kind: "catalog",
      model: "gpt-5.5",
      reasoning_effort: null,
      allow_paid: true,
      profile_id: "profile-codex",
    });
    const reads = t.api.seen("GET", `${base}/agent-models`).length;
    release();
    await refused;
    await later;
    await t.time.pass(100);
    // In the order chosen; the refusal read the Agents again, and the later save shows what the server stored.
    expect(sent.map((s) => (s as Json).model)).toEqual(["gpt-5.4", "gpt-5.5"]);
    expect(t.api.seen("GET", `${base}/agent-models`)).toHaveLength(reads + 1);
    expect(shown().agents?.task_model.selection).toEqual({
      kind: "catalog",
      model: "gpt-5.5",
      reasoning_effort: "high",
      allow_paid: true,
      profile_id: "profile-codex",
    });
  });

  it("shows the default place to run Tasks at once, saves a workspace's places in order, and reads the Agents again after a refusal", async () => {
    const t = setup({
      profiles: [],
      taskPlace: { kind: "station", device_id: "dev-old" },
    });
    const sent: Json[] = [];
    t.api.on("PUT", `${base}/task-place`, (request: SeenRequest) => {
      const { place } = request.body as { place: Json };
      sent.push(place);
      if (place.kind === "cloud_vm") return json(400, { error: "cloud_vm_disabled" });
      t.state.taskPlace = place;
      return json(200, { place });
    });
    const shown = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    await t.time.pass(100);
    expect(shown().agents?.task_place).toEqual({
      place: { kind: "station", device_id: "dev-old" },
    });

    await expect(
      t.client.call("models.setTaskPlace", {
        workspace: WS,
        // A station names its computer.
        place: { kind: "station" },
      } as never)
    ).rejects.toMatchObject({ code: "invalid_params" });

    const choose = (place: Json) =>
      t.client.call("models.setTaskPlace", { workspace: WS, place } as never);
    const release = t.api.hold("PUT", `${base}/task-place`);
    const refused = expect(choose({ kind: "cloud_vm" })).rejects.toMatchObject({
      code: "cloud_vm_disabled",
      status: 400,
    });
    const later = choose({ kind: "salix" });
    await t.time.pass(100);
    expect(shown().agents?.task_place).toEqual({ place: { kind: "salix" } });
    const reads = t.api.seen("GET", `${base}/agent-models`).length;
    release();
    await refused;
    await later;
    await t.time.pass(100);
    // In the order chosen; the refusal read the Agents again, and the later save shows what the server stored.
    expect(sent).toEqual([{ kind: "cloud_vm" }, { kind: "salix" }]);
    expect(t.api.seen("GET", `${base}/agent-models`)).toHaveLength(reads + 1);
    expect(shown().agents?.task_place).toEqual({ place: { kind: "salix" } });
    expect(t.state.taskPlace).toEqual({ kind: "salix" });
  });

  it("renames the Router by the id its read gave, and shows the name to every window", async () => {
    const t = setup({ profiles: [] });
    t.api.on("PATCH", `${base}/agents/router`, {});
    const name = t.watch<{ name: string } | null>({ topic: "router", workspace: WS });
    await t.time.pass(100);
    expect(name()).toMatchObject({ name: "Router" });
    expect(t.api.seen("GET", `${base}/agent-models`)).toHaveLength(1);
    const renamed = t.client.call("models.renameAgent", {
      workspace: WS,
      name: " Atlas ",
    });
    await t.time.pass(100);
    await renamed;
    expect(t.api.seen("PATCH", `${base}/agents/router`)[0]!.body).toEqual({
      name: "Atlas",
    });
    expect(name()).toMatchObject({ agent: "router", name: "Atlas" });
    expect(t.api.seen("GET", `${base}/agent-models`)).toHaveLength(1);
  });

  it("renaming preserves the selected reply style", async () => {
    const t = setup({ profiles: [], replyStyle: "concise" });
    t.api.on("PATCH", `${base}/agents/router`, {});
    const shown = t.watch<{ name: string; reply_style?: string }>({
      topic: "router",
      workspace: WS,
      read: "settings",
    });
    await t.time.pass(100);
    expect(shown().reply_style).toBe("concise");
    const renamed = t.client.call("models.renameAgent", {
      workspace: WS,
      name: "Atlas",
    });
    await t.time.pass(100);
    await renamed;
    expect(shown().name).toBe("Atlas");
    expect(shown().reply_style).toBe("concise");
  });

  it("shows the Router's reply style at once, saves it, and reads the Router again after a refusal", async () => {
    const t = setup({ profiles: [], replyStyle: "default" });
    let refuse = false;
    t.api.on("PUT", `${base}/reply-style`, (request: SeenRequest) => {
      if (refuse) return json(500, { error: "unavailable" });
      const { reply_style } = request.body as { reply_style: string };
      t.state.replyStyle = reply_style;
      return json(200, { reply_style });
    });
    const shown = t.watch<{ reply_style?: string } | null>({
      topic: "router",
      workspace: WS,
      read: "settings",
    });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ reply_style: "default" });

    await expect(
      t.client.call("models.setReplyStyle", { workspace: WS, style: "terse" } as never)
    ).rejects.toMatchObject({ code: "invalid_params" });

    const release = t.api.hold("PUT", `${base}/reply-style`);
    const saved = t.client.call("models.setReplyStyle", {
      workspace: WS,
      style: "concise",
    });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ reply_style: "concise" });
    release();
    await saved;
    expect(t.api.seen("PUT", `${base}/reply-style`)[0]!.body).toEqual({
      reply_style: "concise",
    });
    expect(t.state.replyStyle).toBe("concise");

    refuse = true;
    const reads = t.api.seen("GET", `${base}/agent-models`).length;
    await expect(
      t.client.call("models.setReplyStyle", { workspace: WS, style: "default" })
    ).rejects.toMatchObject({ status: 500 });
    await t.time.pass(100);
    // The refusal read the Router again: it shows what the server holds.
    expect(t.api.seen("GET", `${base}/agent-models`).length).toBeGreaterThan(reads);
    expect(shown()).toMatchObject({ reply_style: "concise" });
  });

  it("waits on a device-code sign-in at the server's interval until it expires", async () => {
    const t = setup({ profiles: [] });
    const expires = new Date(t.time.now() + 60_000).toISOString();
    t.api.on("POST", `${profilesPath}/oauth`, {
      id: "attempt-1",
      url: "https://example.com/device",
      expires_at: expires,
      mode: "device",
      user_code: "ABCD-1234",
      interval: 5,
    });
    t.api.on("POST", `${profilesPath}/oauth/attempt-1`, {
      status: "pending",
      interval: 20,
    });
    t.watch({ topic: "models", prefer: WS });
    await t.time.pass(100);
    const begun = t.client.call("models.signIn.begin", {
      workspace: WS,
      provider: "codex",
      account: "profile-codex",
      version: "v1",
    });
    await t.time.pass(100);
    await expect(begun).resolves.toMatchObject({ user_code: "ABCD-1234" });
    expect(t.api.seen("POST", `${profilesPath}/oauth`)[0]!.body).toEqual({
      provider: "codex",
      mode: "device",
      account_id: "profile-codex",
      version: "v1",
    });
    const waited = expect(
      t.client.call("models.signIn.wait", { workspace: WS, attempt: "attempt-1" })
    ).rejects.toMatchObject({ code: "authorization_expired" });
    const polls = () => t.api.seen("POST", `${profilesPath}/oauth/attempt-1`).length;
    await t.time.pass(4_900, 100);
    expect(polls()).toBe(0);
    await t.time.pass(200, 100);
    expect(polls()).toBe(1);
    // Then every 20 s, as the server said: at 25 s and 45 s; at 65 s it has expired.
    await t.time.pass(70_000, 1_000);
    await waited;
    expect(polls()).toBe(3);
  });

  it("finishes a device-code sign-in with the new profile, and reads the profiles again", async () => {
    const t = setup({ profiles: [] });
    t.api.on("POST", `${profilesPath}/oauth`, {
      id: "attempt-2",
      url: "https://example.com/device",
      expires_at: new Date(t.time.now() + 600_000).toISOString(),
      mode: "device",
      user_code: "WXYZ-0000",
    });
    t.api.on("POST", `${profilesPath}/oauth/attempt-2`, () => {
      t.state.profiles.push(codex);
      return json(200, codex);
    });
    const shown = t.watch<ModelsValue>({ topic: "models", prefer: WS });
    await t.time.pass(100);
    const begun = t.client.call("models.signIn.begin", {
      workspace: WS,
      provider: "codex",
    });
    await t.time.pass(100);
    await begun;
    const waited = t.client.call("models.signIn.wait", {
      workspace: WS,
      attempt: "attempt-2",
    });
    await t.time.pass(5_100, 100);
    await expect(waited).resolves.toMatchObject({ id: "profile-codex" });
    expect(shown().profiles?.map((p) => p.id)).toEqual(["profile-codex"]);
  });
});

describe("Settings › Model & API, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup({ profiles: [structuredClone(codex)] });
    t.watch({ topic: "models", prefer: WS });
    await t.time.pass(100);
    const saved = t.client.call("models.offer", {
      workspace: WS,
      profile: "profile-codex",
      models: ["gpt-5.5"],
      on: false,
    });
    await t.time.pass(100);
    await saved;
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) =>
        input.kind === "response" && input.request.path.startsWith(profilesPath)
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(
      new TextEncoder().encode(body.replace("member@example.com", "other@example.com"))
    );
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
