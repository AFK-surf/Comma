import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ProfileValue } from "../src/contract.ts";
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

const PATH = "/v1/comma/me/profile";
const ada = {
  id: "usr_ada",
  email: "ada@example.com",
  name: "Ada",
  avatar_id: null,
  locale: null,
};

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops = new Map<string, () => void>();
  const watch = (topic: Topic) => {
    const k = topicKey(topic);
    stops.set(
      k,
      client.subscribe(
        topic,
        (v) => values.set(k, v),
        () => undefined
      )
    );
    return () => values.get(k) as ProfileValue;
  };
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch, stops };
}

describe("the account's profile", () => {
  it("is read when shown, kept for the next showing, and read again then", async () => {
    const t = setup();
    t.api.on("GET", PATH, ada);
    const shown = t.watch({ topic: "profile" });
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "ready", profile: ada });
    t.stops.get(topicKey({ topic: "profile" }))!();
    await t.time.pass(61_000, 1_000);
    t.api.on("GET", PATH, () => offline());
    const again = t.watch({ topic: "profile" });
    await t.time.pass(100);
    // The kept profile stands while a read fails.
    expect(again()).toEqual({ status: "ready", profile: ada });
    expect(t.api.seen("GET", PATH)).toHaveLength(2);
  });

  it("says a failed first read failed, and reads again on refresh", async () => {
    const t = setup();
    let up = false;
    t.api.on("GET", PATH, () => (up ? json(200, ada) : offline()));
    const shown = t.watch({ topic: "profile" });
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "error", profile: null });
    up = true;
    const done = t.client.call("profile.refresh", {});
    await t.time.pass(100);
    await done;
    await t.time.pass(100);
    expect(shown()).toEqual({ status: "ready", profile: ada });
  });

  it("saves a name or language and shows the saved profile everywhere", async () => {
    const t = setup();
    t.api.on("GET", PATH, ada);
    t.api.on("PATCH", PATH, { ...ada, name: "Ada L." });
    const shown = t.watch({ topic: "profile" });
    await t.time.pass(100);
    const saved = t.client.call("profile.update", { name: "  Ada L. " });
    await t.time.pass(100);
    expect(await saved).toMatchObject({ name: "Ada L." });
    await t.time.pass(100);
    expect(shown().profile).toMatchObject({ name: "Ada L." });
    expect(t.api.seen("PATCH", PATH)[0]!.body).toEqual({ name: "Ada L." });
    await expect(
      t.client.call("profile.update", { name: "x".repeat(65) })
    ).rejects.toMatchObject({
      code: "invalid_params",
    });
  });

  it("sends an avatar as multipart form data", async () => {
    const t = setup();
    t.api.on("PUT", "/v1/comma/me/avatar", { ...ada, avatar_id: "avt_1" });
    const shown = t.watch({ topic: "profile" });
    const saved = t.client.call("profile.uploadAvatar", {
      bytes: new Uint8Array([0x89, 0x50, 0x4e, 0x47]),
      type: "image/png",
      name: "ada.png",
    });
    await t.time.pass(100);
    expect(await saved).toMatchObject({ avatar_id: "avt_1" });
    await t.time.pass(100);
    expect(shown().profile).toMatchObject({ avatar_id: "avt_1" });
    const sent = t.api.seen("PUT", "/v1/comma/me/avatar")[0]!;
    const type = sent.headers!.find(([k]) => k === "content-type")![1];
    const boundary = /boundary=(.+)$/.exec(type)![1]!;
    const text = new TextDecoder("latin1").decode(sent.body as Uint8Array);
    expect(text).toContain(`--${boundary}\r\n`);
    expect(text).toContain(
      'Content-Disposition: form-data; name="avatar"; filename="ada.png"'
    );
    expect(text).toContain("Content-Type: image/png\r\n\r\n");
    expect(text).toContain(`PNG\r\n--${boundary}--`);
    expect(text.endsWith(`--${boundary}--\r\n`)).toBe(true);
  });
});

describe("a change to the profile", () => {
  it("shows a new name at once, the saved one once the server has it", async () => {
    const t = setup();
    t.api.on("GET", PATH, ada);
    t.api.on("PATCH", PATH, { ...ada, name: "Ada L." });
    const shown = t.watch({ topic: "profile" });
    await t.time.pass(100);
    const release = t.api.hold("PATCH", PATH);
    const saved = t.client.call("profile.update", { name: "Ada L." });
    await t.time.pass(100);
    expect(shown().profile).toMatchObject({ name: "Ada L." });
    release();
    await t.time.pass(100);
    await saved;
    expect(shown()).toEqual({ status: "ready", profile: { ...ada, name: "Ada L." } });
  });

  it("goes back to the saved name when the server refuses the new one, and the call fails", async () => {
    const t = setup();
    t.api.on("GET", PATH, ada);
    t.api.on("PATCH", PATH, json(422, { error: "invalid" }));
    const shown = t.watch({ topic: "profile" });
    await t.time.pass(100);
    const release = t.api.hold("PATCH", PATH);
    const saved = t.client.call("profile.update", { name: "Ada L." });
    const refused = expect(saved).rejects.toMatchObject({ status: 422 });
    await t.time.pass(100);
    expect(shown().profile).toMatchObject({ name: "Ada L." });
    release();
    await t.time.pass(100);
    await refused;
    expect(shown()).toEqual({ status: "ready", profile: ada });
  });

  it("saves changes one at a time and keeps showing the newest while an older one is answered", async () => {
    const t = setup();
    t.api.on("GET", PATH, ada);
    t.api.on("PATCH", PATH, json(500, { error: "unavailable" }));
    const shown = t.watch({ topic: "profile" });
    await t.time.pass(100);
    const releaseFirst = t.api.hold("PATCH", PATH);
    const first = t.client.call("profile.update", { name: "First" });
    const firstFails = expect(first).rejects.toMatchObject({ status: 500 });
    await t.time.pass(100);
    const releaseSecond = t.api.hold("PATCH", PATH);
    const second = t.client.call("profile.update", { name: "Second" });
    const secondFails = expect(second).rejects.toMatchObject({ status: 500 });
    await t.time.pass(100);
    // One save at a time, in the order asked: the server ends on the last one.
    expect(t.api.seen("PATCH", PATH)).toHaveLength(1);
    releaseFirst();
    await t.time.pass(100);
    await firstFails;
    expect(shown().profile).toMatchObject({ name: "Second" });
    releaseSecond();
    await t.time.pass(100);
    await secondFails;
    expect(shown().profile).toMatchObject({ name: "Ada" });
  });

  it("shows a new avatar from its bytes while it uploads, then the saved one", async () => {
    const t = setup();
    t.api.on("GET", PATH, ada);
    t.api.on("PUT", "/v1/comma/me/avatar", { ...ada, avatar_id: "avt_1" });
    const shown = t.watch({ topic: "profile" });
    await t.time.pass(100);
    const release = t.api.hold("PUT", "/v1/comma/me/avatar");
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47]);
    const saved = t.client.call("profile.uploadAvatar", { bytes, type: "image/png" });
    await t.time.pass(100);
    const revision = shown().profile?.avatar_id;
    expect(revision).toMatch(/^pending-/);
    const read = t.client.call("files.read", { source: "avatar", revision });
    await t.time.pass(100);
    expect(await read).toEqual({ bytes, type: "image/png" });
    expect(t.api.seen("GET", `/v1/comma/me/avatar/${revision}`)).toHaveLength(0);
    release();
    await t.time.pass(100);
    await saved;
    expect(shown().profile).toMatchObject({ avatar_id: "avt_1" });
    // A view that asks for the upload's name after it settled reads nothing from
    // the server: that name was never a saved revision.
    const late = t.client.call("files.read", { source: "avatar", revision });
    const lateFails = expect(late).rejects.toMatchObject({ code: "not_found" });
    await t.time.pass(100);
    await lateFails;
    expect(t.api.seen("GET", `/v1/comma/me/avatar/${revision}`)).toHaveLength(0);
  });

  it("puts the saved avatar back when an upload or a removal is refused", async () => {
    const t = setup();
    t.api.on("GET", PATH, { ...ada, avatar_id: "avt_1" });
    t.api.on("PUT", "/v1/comma/me/avatar", json(413, { error: "too_large" }));
    t.api.on("DELETE", "/v1/comma/me/avatar", json(500, { error: "unavailable" }));
    const shown = t.watch({ topic: "profile" });
    await t.time.pass(100);
    const release = t.api.hold("DELETE", "/v1/comma/me/avatar");
    const removed = t.client.call("profile.removeAvatar", {});
    const removalFails = expect(removed).rejects.toMatchObject({ status: 500 });
    await t.time.pass(100);
    expect(shown().profile).toMatchObject({ avatar_id: null });
    release();
    await t.time.pass(100);
    await removalFails;
    expect(shown().profile).toMatchObject({ avatar_id: "avt_1" });
    const uploaded = t.client.call("profile.uploadAvatar", {
      bytes: new Uint8Array([1]),
      type: "image/png",
    });
    const uploadFails = expect(uploaded).rejects.toMatchObject({ status: 413 });
    await t.time.pass(100);
    await uploadFails;
    await t.time.pass(100);
    expect(shown().profile).toMatchObject({ avatar_id: "avt_1" });
  });
});

describe("the account's avatar", () => {
  it("is removed, and every surface shows the saved profile", async () => {
    const t = setup();
    t.api.on("GET", PATH, { ...ada, avatar_id: "avt_1" });
    t.api.on("DELETE", "/v1/comma/me/avatar", ada);
    const shown = t.watch({ topic: "profile" });
    await t.time.pass(100);
    const removed = t.client.call("profile.removeAvatar", {});
    await t.time.pass(100);
    expect(await removed).toMatchObject({ avatar_id: null });
    await t.time.pass(100);
    expect(shown().profile).toMatchObject({ avatar_id: null });
  });
});

describe("the account's profile, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", PATH, ada);
    t.watch({ topic: "profile" });
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.find(
      (input) => input.kind === "response" && input.request.path === PATH
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replaceAll('"Ada"', '"Grace"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
