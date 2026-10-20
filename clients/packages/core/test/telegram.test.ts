import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { TelegramValue } from "../src/contract.ts";
import type { CoreLimits } from "../src/limits.ts";
import { base64, fromBase64 } from "../src/record.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const WS = "ws-1";
const path = `/v1/comma/workspaces/${WS}/integrations/telegram`;
const integration = (user: string | null) => ({
  bot_url: "https://t.me/CommaBot",
  bot_username: "CommaBot",
  configured: true,
  link: user
    ? {
        telegram_user_id: user,
        telegram_username: user,
        connected_at: 1,
        updated_at: user === "ada" ? 1 : 2,
      }
    : null,
  official_login_available: true,
  workspace_id: WS,
  workspace_name: "Main",
});

function setup(
  workspaces = [{ id: WS, group_id: "g-1", name: "Main" }],
  options: { coalesceMs?: number; limits?: Partial<CoreLimits> } = {}
) {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", { data: workspaces });
  const core = startTestCore(host, options);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = <T>(topic: Topic) => {
    const key = topicKey(topic);
    const stop = client.subscribe(
      topic,
      (v) => values.set(key, v),
      () => undefined
    );
    return Object.assign(() => values.get(key) as T, { stop });
  };
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch };
}

function telegramServer(t: ReturnType<typeof setup>) {
  const server = { user: "ada" as string | null, linksAfter: Infinity };
  t.api.on("GET", path, () => {
    const after = t.api.seen("POST", `${path}/connect`).length > 0;
    const reads = t.api.seen("GET", path).length;
    return json(
      200,
      integration(after && reads > server.linksAfter ? "grace" : server.user)
    );
  });
  t.api.on("POST", `${path}/connect`, {
    authorization_url: "https://oauth.telegram.org/auth?state=attempt-1",
    expires_in_seconds: 600,
    workspace_id: WS,
  });
  t.api.on("DELETE", `${path}/connect`, { cancelled: true });
  t.api.on("DELETE", path, () => {
    server.user = null;
    return json(200, { disconnected: true });
  });
  return server;
}

describe("Telegram", () => {
  it("reads the account's one workspace, and refuses to choose among none or several", async () => {
    const one = setup();
    telegramServer(one);
    const shown = one.watch<TelegramValue>({ topic: "telegram" });
    await one.time.pass(100);
    expect(shown()).toMatchObject({
      workspace: WS,
      error: false,
      state: { link: { telegram_user_id: "ada" } },
    });

    const two = setup([
      { id: "a", group_id: "g-a", name: "A" },
      { id: "b", group_id: "g-b", name: "B" },
    ]);
    const refused = two.watch<TelegramValue>({ topic: "telegram" });
    await two.time.pass(100);
    expect(refused()).toMatchObject({ workspace: null, error: true });
    expect(two.api.seen("GET", path)).toHaveLength(0);

    const none = setup([]);
    const empty = none.watch<TelegramValue>({ topic: "telegram" });
    await none.time.pass(100);
    expect(empty()).toMatchObject({ workspace: null, error: true });
    expect(none.api.seen("GET", path)).toHaveLength(0);
  });

  it("follows a login every 1.5 s until a new link shows", async () => {
    const t = setup();
    const server = telegramServer(t);
    const shown = t.watch<TelegramValue>({ topic: "telegram" });
    await t.time.pass(100);
    server.linksAfter = 3;
    const started = t.client.call("telegram.connect", { environment: "dev" });
    await t.time.pass(100);
    expect(await started).toEqual({
      authorizationUrl: "https://oauth.telegram.org/auth?state=attempt-1",
    });
    expect(t.api.seen("POST", `${path}/connect`)[0]!.body).toEqual({
      environment: "dev",
    });
    expect(shown()).toMatchObject({ attempt: "attempt-1", busy: true });
    await t.time.pass(4_000, 500);
    expect(shown()).toMatchObject({
      attempt: null,
      busy: false,
      state: { link: { telegram_user_id: "grace" } },
    });
  });

  it("gives a login up after its last read, and cancels it with the server, a closed window as a failure", async () => {
    // The limit is 200 reads (limits.test.ts); 5 reach it the same way.
    const t = setup(undefined, { limits: { telegramLoginReads: 5 } });
    telegramServer(t);
    const shown = t.watch<TelegramValue>({ topic: "telegram" });
    await t.time.pass(100);
    const before = t.api.seen("GET", path).length;
    const started = t.client.call("telegram.connect", { environment: "dev" });
    await t.time.pass(100);
    await started;
    // A read at once, then one every 1.5 s: the fifth is at 6 s, and the login gives up 1.5 s after it.
    await t.time.pass(7_000);
    expect(t.api.seen("GET", path)).toHaveLength(before + 5);
    expect(shown()).toMatchObject({ busy: true, error: false });
    await t.time.pass(1_000);
    expect(shown()).toMatchObject({ error: true, busy: false, attempt: "attempt-1" });
    const reads = t.api.seen("GET", path).length;
    expect(reads).toBe(before + 5);
    await t.time.pass(10_000, 1_000);
    expect(t.api.seen("GET", path)).toHaveLength(reads);

    const cancelled = t.client.call("telegram.cancel", { closed: true });
    await t.time.pass(100);
    await cancelled;
    expect(t.api.seen("DELETE", `${path}/connect`)[0]!.body).toEqual({
      state: "attempt-1",
    });
    expect(shown()).toMatchObject({ attempt: null, error: true });
  });

  it("disconnects and shows the connection the server has after", async () => {
    const t = setup();
    telegramServer(t);
    const shown = t.watch<TelegramValue>({ topic: "telegram" });
    await t.time.pass(100);
    const done = t.client.call("telegram.disconnect", {});
    await t.time.pass(100);
    await done;
    expect(shown()).toMatchObject({ state: { link: null }, busy: false, error: false });
  });

  it("goes on with a login or a disconnect while no page shows it, and shows it on return", async () => {
    const t = setup();
    telegramServer(t);
    const shown = t.watch<TelegramValue>({ topic: "telegram" });
    await t.time.pass(100);
    const started = t.client.call("telegram.connect", { environment: "dev" });
    await t.time.pass(100);
    await started;
    shown.stop();
    const reads = t.api.seen("GET", path).length;
    await t.time.pass(3_000, 500);
    // The login is still followed with no page to show it.
    expect(t.api.seen("GET", path).length).toBeGreaterThan(reads);
    const back = t.watch<TelegramValue>({ topic: "telegram" });
    await t.time.pass(100);
    expect(back()).toMatchObject({ attempt: "attempt-1", busy: true });
    expect(t.api.seen("POST", `${path}/connect`)).toHaveLength(1);

    const cancelled = t.client.call("telegram.cancel", {});
    await t.time.pass(100);
    await cancelled;
    const done = t.client.call("telegram.disconnect", {});
    back.stop();
    await t.time.pass(100);
    await done;
    const again = t.watch<TelegramValue>({ topic: "telegram" });
    await t.time.pass(100);
    expect(t.api.seen("DELETE", path)).toHaveLength(1);
    expect(again()).toMatchObject({ state: { link: null }, busy: false, error: false });
  });
});

describe("a Telegram login, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    const server = telegramServer(t);
    t.watch({ topic: "telegram" });
    await t.time.pass(100);
    server.linksAfter = 2;
    const started = t.client.call("telegram.connect", { environment: "dev" });
    await t.time.pass(100);
    await started;
    await t.time.pass(3_000, 500);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const last = told.findLast(
      (input) => input.kind === "response" && input.request.path === path
    )!;
    if (last.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(last.body));
    expect(body).toContain('"grace"');
    last.body = base64(
      new TextEncoder().encode(
        body.replaceAll('"grace"', '"ada"').replace('"updated_at":2', '"updated_at":1')
      )
    );
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    ).catch(() => null);
    expect(changed && comparable(changed.outputs)).not.toEqual(
      comparable(recorded.outputs)
    );
  });
});
