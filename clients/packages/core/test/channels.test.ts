import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { SignalValue, WeChatConnection, WeChatValue } from "../src/contract.ts";
import { base64, fromBase64 } from "../src/record.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const WS = "ws-1";
const wechat = `/v1/comma/workspaces/${WS}/integrations/wechat`;
const signal = `/v1/comma/workspaces/${WS}/integrations/signal`;

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
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch };
}

/** A WeChat attempt that answers each check with `status()`, until it is connected. */
function wechatServer(t: ReturnType<typeof setup>, expiresAt: number) {
  let pending: WeChatConnection | null = null;
  let connection: WeChatConnection | null = null;
  const server = {
    expiresAt,
    login: "wait" as WeChatConnection["login_status"],
    failCheck: false,
    get pending() {
      return pending;
    },
  };
  t.api.on("GET", wechat, () => json(200, { connection, pending }));
  t.api.on("POST", `${wechat}/connect`, () => {
    pending = {
      connect_id: `attempt-${t.api.seen("POST", `${wechat}/connect`).length}`,
      status: "pending",
      login_status: "wait",
      connection_active: false,
      qrcode_url: "https://weixin.qq.com/qr",
      expires_at: server.expiresAt,
    };
    return json(201, pending);
  });
  t.api.on("POST", `${wechat}/connect/poll`, (request) => {
    if (server.failCheck) return offline();
    const body = request.body as { verify_code?: string };
    if (body.verify_code) {
      connection = {
        ...pending!,
        status: "connected",
        login_status: "confirmed",
        connection_active: true,
        qrcode_url: null,
        wechat_id: "alice",
      };
      pending = null;
      return json(200, connection);
    }
    pending = { ...pending!, login_status: server.login };
    return json(200, pending);
  });
  t.api.on("DELETE", `${wechat}/connect`, () => {
    pending = null;
    return json(200, { cancelled: true });
  });
  return server;
}

describe("WeChat", () => {
  it("checks an attempt every 3 s until WeChat asks for the pairing code, then connects with it", async () => {
    const t = setup();
    const expires = Math.floor(t.time.now() / 1000) + 300;
    const server = wechatServer(t, expires);
    const shown = t.watch<WeChatValue>({ topic: "wechat", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toEqual({
      state: { connection: null, pending: null },
      error: false,
      busy: false,
    });
    const started = t.client.call("wechat.start", { workspace: WS });
    await t.time.pass(100);
    await started;
    const checks = () => t.api.seen("POST", `${wechat}/connect/poll`).length;
    expect(checks()).toBe(1);
    await t.time.pass(6_000, 500);
    expect(checks()).toBe(3);
    server.login = "need_verifycode";
    await t.time.pass(3_000, 500);
    expect(shown().state?.pending?.login_status).toBe("need_verifycode");
    // It waits on the person now: no more checks.
    await t.time.pass(30_000, 1_000);
    expect(checks()).toBe(4);
    const verified = t.client.call("wechat.verify", {
      workspace: WS,
      code: "12-34-56",
    });
    await t.time.pass(100);
    await verified;
    expect(
      (
        t.api.seen("POST", `${wechat}/connect/poll`).at(-1)!.body as {
          verify_code: string;
        }
      ).verify_code
    ).toBe("123456");
    expect(shown().state).toMatchObject({
      connection: { connection_active: true, wechat_id: "alice" },
      pending: null,
    });
  });

  it("calls an attempt past its expiry expired without asking, and a failed check stops the checks until a refresh", async () => {
    const t = setup();
    const expires = Math.floor(t.time.now() / 1000) + 10;
    const server = wechatServer(t, expires);
    const shown = t.watch<WeChatValue>({ topic: "wechat", workspace: WS });
    await t.time.pass(100);
    const started = t.client.call("wechat.start", { workspace: WS });
    await t.time.pass(100);
    await started;
    await t.time.pass(15_000, 500);
    expect(shown().state?.pending?.login_status).toBe("expired");
    const checks = t.api.seen("POST", `${wechat}/connect/poll`).length;
    expect(checks).toBeLessThanOrEqual(4);

    server.expiresAt = Math.floor(t.time.now() / 1000) + 300;
    const again = t.client.call("wechat.start", { workspace: WS });
    await t.time.pass(100);
    await again;
    server.failCheck = true;
    await t.time.pass(3_000, 500);
    expect(shown().error).toBe(true);
    const failed = t.api.seen("POST", `${wechat}/connect/poll`).length;
    await t.time.pass(30_000, 1_000);
    expect(t.api.seen("POST", `${wechat}/connect/poll`).length).toBe(failed);
  });

  it("refuses a second change while one is under way", async () => {
    const t = setup();
    wechatServer(t, Math.floor(t.time.now() / 1000) + 300);
    t.watch<WeChatValue>({ topic: "wechat", workspace: WS });
    await t.time.pass(100);
    const release = t.api.hold("POST", `${wechat}/connect`);
    const first = t.client.call("wechat.start", { workspace: WS });
    await t.time.pass(10);
    const second = expect(
      t.client.call("wechat.start", { workspace: WS })
    ).rejects.toMatchObject({
      code: "busy",
    });
    await t.time.pass(10);
    await second;
    release();
    await t.time.pass(100);
    await first;
  });
});

describe("Signal", () => {
  it("answers a new code to its caller only, and reads every 3 s until it is used", async () => {
    const t = setup();
    let claims = [{ claim_id: "sgc_1", expires_at: 1_900_000_000_000 }];
    let bindings: unknown[] = [];
    claims = [];
    const status = () => ({
      account: { e164: "+15550100001" },
      bindings,
      pending_claims: claims,
    });
    t.api.on("GET", signal, () => json(200, status()));
    t.api.on("GET", `${signal}/number`, { platform: { e164: "+15550100001" } });
    t.api.on("POST", `${signal}/claims`, () => {
      claims = [{ claim_id: "sgc_1", expires_at: 1_900_000_000_000 }];
      return json(200, {
        ...status(),
        claim: {
          claim_id: "sgc_1",
          code: "ABCD",
          command: "comma connect ABCD",
          number: "+15550100001",
          expires_at: 1_900_000_000_000,
        },
      });
    });
    const shown = t.watch<SignalValue>({ topic: "signal", workspace: WS });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      integration: { pending_claims: [] },
      error: false,
    });
    const code = t.client.call("signal.newCode", { workspace: WS });
    await t.time.pass(100);
    expect(await code).toEqual({
      claimId: "sgc_1",
      command: "comma connect ABCD",
      number: "+15550100001",
    });
    expect(JSON.stringify(shown())).not.toContain("ABCD");
    const reads = () => t.api.seen("GET", signal).length;
    const before = reads();
    await t.time.pass(6_000, 500);
    expect(reads()).toBe(before + 2);
    claims = [];
    bindings = [
      {
        binding_id: "sgb_team",
        kind: "group",
        peer: "group:team",
        display_name: "Team",
      },
    ];
    await t.time.pass(3_000, 500);
    expect(shown().integration?.bindings).toHaveLength(1);
    const after = reads();
    await t.time.pass(30_000, 1_000);
    expect(reads()).toBe(after);
  });

  it("shows a failed read until a refresh reads it again", async () => {
    const t = setup();
    let up = false;
    t.api.on("GET", signal, () =>
      up ? json(200, { bindings: [], pending_claims: [] }) : offline()
    );
    t.api.on("GET", `${signal}/number`, {});
    const shown = t.watch<SignalValue>({ topic: "signal", workspace: WS });
    await t.time.pass(100);
    expect(shown().error).toBe(true);
    up = true;
    const refreshed = t.client.call("signal.refresh", { workspace: WS });
    await t.time.pass(100);
    await refreshed;
    expect(shown()).toMatchObject({ error: false, integration: { bindings: [] } });
  });
});

describe("a run of the channels, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    const server = wechatServer(t, Math.floor(t.time.now() / 1000) + 300);
    t.watch({ topic: "wechat", workspace: WS });
    await t.time.pass(100);
    const started = t.client.call("wechat.start", { workspace: WS });
    await t.time.pass(100);
    await started;
    await t.time.pass(3_000, 500);
    server.login = "scaned";
    await t.time.pass(3_000, 500);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const check = told.findLast(
      (input) =>
        input.kind === "response" && input.request.path === `${wechat}/connect/poll`
    )!;
    if (check.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(check.body));
    expect(body).toContain('"scaned"');
    check.body = base64(new TextEncoder().encode(body.replace('"scaned"', '"wait"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
