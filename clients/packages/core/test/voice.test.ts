import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { VoiceValue } from "../src/contract.ts";
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

const line = "/v1/comma/workspaces/wsp_1/integrations/voice";
const keys = "/v1/comma/workspaces/wsp_1/voice-api-keys";
const status = (numbers: unknown[] = []) => ({
  lines: ["+15550001111"],
  numbers,
  readiness: { ready: true, reason: null },
});
const number = {
  e164: "+15551234567",
  line: "+15550001111",
  verified_at: 1_700_000_000_000,
  pin_set: true,
  pin_locked_until: null,
  status: "verified",
};
const key = {
  key_id: "gak_v1",
  name: "Kiosk",
  prefix: "salix_vk_abcdef",
  status: "active",
  readiness_url: "https://salix.example/v1/agent-groups/grp_1/voice",
};

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "wsp_1", group_id: "grp_1", name: "Main" }],
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
  return { host, core, client, time: host.time!, api: host.api, watch };
}

describe("Settings › Voice", () => {
  it("reads the numbers and keys apart: one failing does not hide the other", async () => {
    const t = setup();
    t.api.on("GET", line, offline());
    t.api.on("GET", keys, [key]);
    const shown = t.watch<VoiceValue>({ topic: "voice" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      workspace: "wsp_1",
      integration: null,
      integrationError: true,
      keys: [{ key_id: "gak_v1" }],
      keysError: false,
    });
  });

  it("verifies a caller number with the requests the server expects, and says why one is refused", async () => {
    const t = setup();
    let numbers: unknown[] = [];
    t.api.on("GET", line, () => json(200, status(numbers)));
    t.api.on("GET", keys, []);
    t.api.on("POST", `${line}/numbers/verify-start`, (request) =>
      (request.body as { e164: string }).e164 === "+15557654321"
        ? json(409, { error: "voice_number_in_use" })
        : json(200, { e164: "+15551234567", status: "pending" })
    );
    t.api.on("POST", `${line}/numbers/verify-check`, () => {
      numbers = [number];
      return json(200, status(numbers));
    });
    t.api.on("DELETE", `${line}/numbers/%2B15551234567`, () => {
      numbers = [];
      return json(200, status(numbers));
    });
    const shown = t.watch<VoiceValue>({ topic: "voice" });
    await t.time.pass(100);
    const started = t.client.call("voice.startVerification", {
      workspace: "wsp_1",
      e164: "+15551234567",
    });
    await t.time.pass(100);
    await started;
    expect(t.api.seen("POST", `${line}/numbers/verify-start`)[0]!.body).toEqual({
      e164: "+15551234567",
    });
    const checked = t.client.call("voice.checkCode", {
      workspace: "wsp_1",
      e164: "+15551234567",
      code: "123456",
    });
    await t.time.pass(100);
    await checked;
    expect(shown().integration?.numbers).toHaveLength(1);
    // The "+" of an E.164 number survives the path segment.
    const removed = t.client.call("voice.removeNumber", {
      workspace: "wsp_1",
      e164: "+15551234567",
    });
    await t.time.pass(100);
    await removed;
    expect(
      t.api.requests.some((r) => r.path === `${line}/numbers/%2B15551234567`)
    ).toBe(true);
    expect(shown().integration?.numbers).toHaveLength(0);
    const refused = expect(
      t.client.call("voice.startVerification", {
        workspace: "wsp_1",
        e164: "+15557654321",
      })
    ).rejects.toMatchObject({ code: "voice_number_in_use", status: 409 });
    await t.time.pass(100);
    await refused;
  });

  it("sets the call voice, makes a custom voice and turns Router calls on", async () => {
    const t = setup();
    let preferences: unknown = { voice: null, custom_voice: null, router_calls: false };
    const answer = () =>
      json(200, { ...status(), preferences, voices: ["quartz", "gleam"] });
    t.api.on("GET", line, answer);
    t.api.on("GET", keys, []);
    t.api.on("PUT", `${line}/preferences`, (request) => {
      const body = request.body as { voice?: unknown; router_calls?: boolean };
      preferences = {
        ...(preferences as object),
        ...("voice" in body ? { voice: body.voice } : {}),
        ...(body.router_calls === undefined ? {} : { router_calls: body.router_calls }),
      };
      return answer();
    });
    t.api.on("POST", `${line}/custom-voice`, (request) => {
      const body = request.body as { description: string };
      preferences = {
        ...(preferences as object),
        voice: { kind: "custom" },
        custom_voice: { name: "", description: body.description },
      };
      return answer();
    });
    const shown = t.watch<VoiceValue>({ topic: "voice" });
    await t.time.pass(100);
    expect(shown().integration?.voices).toEqual(["quartz", "gleam"]);

    const preset = t.client.call("voice.setPreferences", {
      workspace: "wsp_1",
      voice: { kind: "preset", name: "gleam" },
    });
    await t.time.pass(100);
    await preset;
    // Only the changed field is sent: the other keeps its stored value.
    expect(t.api.seen("PUT", `${line}/preferences`)[0]!.body).toEqual({
      voice: { kind: "preset", name: "gleam" },
    });

    const router = t.client.call("voice.setPreferences", {
      workspace: "wsp_1",
      routerCalls: true,
    });
    await t.time.pass(100);
    await router;
    expect(t.api.seen("PUT", `${line}/preferences`)[1]!.body).toEqual({
      router_calls: true,
    });

    const custom = t.client.call("voice.createCustomVoice", {
      workspace: "wsp_1",
      description: "  A warm voice speaking Mandarin.  ",
    });
    await t.time.pass(100);
    await custom;
    expect(t.api.seen("POST", `${line}/custom-voice`)[0]!.body).toEqual({
      description: "A warm voice speaking Mandarin.",
    });
    expect(shown().integration?.preferences).toEqual({
      voice: { kind: "custom" },
      custom_voice: { name: "", description: "A warm voice speaking Mandarin." },
      router_calls: true,
    });

    const nothing = expect(
      t.client.call("voice.setPreferences", { workspace: "wsp_1" })
    ).rejects.toMatchObject({ code: "invalid_params" });
    await t.time.pass(100);
    await nothing;
  });

  it("answers a new key's plaintext to its caller only, and lists keys without it", async () => {
    const t = setup();
    let list = [key];
    t.api.on("GET", line, status());
    t.api.on("GET", keys, () => json(200, list));
    t.api.on("POST", keys, () => {
      list = [...list, { ...key, key_id: "gak_v2", name: "Front desk" }];
      return json(201, {
        ...key,
        key_id: "gak_v2",
        name: "Front desk",
        key: "salix_vk_secret",
        sessions_url: "wss://salix.example/sessions",
      });
    });
    const shown = t.watch<VoiceValue>({ topic: "voice" });
    await t.time.pass(100);
    const created = t.client.call("voice.createKey", {
      workspace: "wsp_1",
      name: "Front desk",
    });
    await t.time.pass(100);
    expect(await created).toMatchObject({ key: "salix_vk_secret" });
    expect(shown().keys).toHaveLength(2);
    expect(JSON.stringify(shown())).not.toContain("salix_vk_secret");
  });
});

describe("a voice key that ends", () => {
  it("is made with the end it is asked for", async () => {
    const t = setup();
    t.api.on("GET", line, status());
    t.api.on("GET", keys, [key]);
    t.api.on("POST", keys, () =>
      json(201, {
        ...key,
        key: "salix_vk_secret",
        sessions_url: "wss://salix.example/sessions",
      })
    );
    const created = t.client.call("voice.createKey", {
      workspace: "wsp_1",
      name: "Android voice calls",
      expiresAt: 1_900_000_000,
    });
    await t.time.pass(100);
    await created;
    expect(t.api.seen("POST", keys)[0]!.body).toEqual({
      name: "Android voice calls",
      expires_at: "2030-03-17T17:46:40.000Z",
    });
  });
});

describe("Settings › Voice, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", line, status([number]));
    t.api.on("GET", keys, [key]);
    t.watch({ topic: "voice" });
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path === keys
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replace('"Kiosk"', '"Lobby"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
