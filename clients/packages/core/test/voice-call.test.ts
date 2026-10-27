import { CoreClient, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { VoiceCallValue } from "../src/contract.ts";
import type { VoiceCallSocketEvent, VoiceCallSocketOp } from "../src/host.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

// The desktop's call to the Router: a key for the call, Main's socket opened with it, `calling` until Salix answers
// `session.started`, then `connected` until the socket closes; the key is deleted when the call ends.

const keys = "/v1/comma/workspaces/wsp_1/voice-api-keys";
const created = {
  key_id: "gak_call",
  name: "Desktop call",
  prefix: "salix_vk_abcdef",
  status: "active",
  key: "salix_vk_secret",
  sessions_url: "wss://salix.example/v1/agent-groups/grp_1/voice/sessions",
};

function setup() {
  const host = new FakeHost();
  const ops: VoiceCallSocketOp[] = [];
  let listener: ((event: VoiceCallSocketEvent) => void) | null = null;
  host.voiceCall = {
    command: (op) => ops.push(op),
    listen: (next) => {
      listener = next;
    },
  };
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "wsp_1", group_id: "grp_1", name: "Main" }],
  });
  host.api.on("POST", keys, () => json(201, created));
  host.api.on("DELETE", `${keys}/gak_call`, { deleted: true });
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  let value: VoiceCallValue | undefined;
  const topic: Topic = { topic: "voiceCall" };
  client.subscribe(
    topic,
    (v) => {
      value = v as VoiceCallValue;
    },
    () => undefined
  );
  core.observeSession(signedIn());
  return {
    host,
    client,
    ops,
    time: host.time!,
    call: () => value,
    socket: (event: VoiceCallSocketEvent) => listener?.(event),
  };
}

describe("a desktop call to the Router", () => {
  it("dials with a key of its own, talks once Salix answers, and deletes the key when hung up", async () => {
    const t = setup();
    await t.time.pass(100);
    expect(t.call()).toMatchObject({ available: true, phase: "idle" });

    const started = t.client.call("voiceCall.start", { workspace: "wsp_1" });
    await t.time.pass(100);
    await started;
    expect(t.call()).toMatchObject({ phase: "calling", workspace: "wsp_1" });
    // The key lasts an hour if the call is never hung up.
    const made = t.host.api.seen("POST", keys)[0]!.body as Record<string, unknown>;
    expect(made.name).toBe("Desktop call");
    expect(typeof made.expires_at).toBe("string");
    // Main opens the socket with the key; the key never reaches the topic.
    expect(t.ops).toEqual([
      { op: "open", url: created.sessions_url, key: "salix_vk_secret" },
    ]);
    expect(JSON.stringify(t.call())).not.toContain("salix_vk_secret");

    t.socket({ kind: "open" });
    expect(t.ops[1]).toEqual({
      op: "send",
      text: JSON.stringify({
        type: "session.start",
        audio_format: "pcm16_24k",
        client: "comma-desktop/1",
      }),
    });
    t.socket({
      kind: "message",
      text: JSON.stringify({ type: "session.started", call_id: "vc_1" }),
    });
    await t.time.pass(100);
    expect(t.call()).toMatchObject({ phase: "connected" });
    expect(t.call()?.connectedAt).toEqual(expect.any(Number));

    const muted = t.client.call("voiceCall.setMuted", { muted: true });
    await t.time.pass(100);
    await muted;
    expect(t.call()?.muted).toBe(true);

    const ended = t.client.call("voiceCall.end", {});
    await t.time.pass(100);
    await ended;
    expect(t.ops.at(-1)).toEqual({ op: "close" });
    expect(t.call()).toMatchObject({ phase: "idle", muted: false, connectedAt: null });
    expect(t.host.api.seen("DELETE", `${keys}/gak_call`)).toHaveLength(1);
  });

  it("ends when Salix closes the socket, and refuses a second call while one is up", async () => {
    const t = setup();
    await t.time.pass(100);
    const started = t.client.call("voiceCall.start", { workspace: "wsp_1" });
    await t.time.pass(100);
    await started;

    const again = expect(
      t.client.call("voiceCall.start", { workspace: "wsp_1" })
    ).rejects.toMatchObject({ code: "busy" });
    await t.time.pass(10);
    await again;

    t.socket({ kind: "closed", code: 4409, reason: "busy" });
    await t.time.pass(100);
    expect(t.call()).toMatchObject({ phase: "idle" });
    expect(t.host.api.seen("DELETE", `${keys}/gak_call`)).toHaveLength(1);
  });

  it("goes back to idle when the key cannot be made", async () => {
    const t = setup();
    t.host.api.on("POST", keys, () => json(503, { error: "unavailable" }));
    await t.time.pass(100);
    const started = expect(
      t.client.call("voiceCall.start", { workspace: "wsp_1" })
    ).rejects.toBeDefined();
    await t.time.pass(100);
    await started;
    expect(t.call()).toMatchObject({ phase: "idle" });
    expect(t.ops).toEqual([]);
  });

  it("is unavailable without Main's socket (the web)", async () => {
    const host = new FakeHost();
    const core = startTestCore(host);
    const client = new CoreClient(inProcessOpener(core, host), {
      schedule: () => undefined,
    });
    let value: VoiceCallValue | undefined;
    client.subscribe(
      { topic: "voiceCall" },
      (v) => {
        value = v as VoiceCallValue;
      },
      () => undefined
    );
    core.observeSession(signedIn());
    await host.time!.pass(100);
    expect(value).toMatchObject({ available: false, phase: "idle" });
    const started = expect(
      client.call("voiceCall.start", { workspace: "wsp_1" })
    ).rejects.toMatchObject({ code: "unavailable" });
    await host.time!.pass(10);
    await started;
  });
});
