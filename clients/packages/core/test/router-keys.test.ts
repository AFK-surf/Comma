import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { RouterKeysValue } from "../src/contract.ts";
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

const keysPath = (ws: string) => `/v1/comma/workspaces/${ws}/router-api-keys`;
const key = (name: string, status = "active") => ({
  key_id: `gak_${name}`,
  name,
  prefix: "salix_gk_abc",
  status,
});

function setup() {
  const host = new FakeHost();
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [
      { id: "ws-1", group_id: "g-1", name: "One" },
      { id: "ws-2", group_id: "g-2", name: "Two" },
    ],
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

describe("inbound API keys", () => {
  it("lists the preferred workspace's keys, and the first workspace's without one", async () => {
    const t = setup();
    t.api.on("GET", keysPath("ws-1"), [key("first")]);
    t.api.on("GET", keysPath("ws-2"), [key("second")]);
    const preferred = t.watch<RouterKeysValue>({ topic: "routerKeys", prefer: "ws-2" });
    const fallback = t.watch<RouterKeysValue>({ topic: "routerKeys", prefer: "gone" });
    await t.time.pass(100);
    expect(preferred()).toMatchObject({
      workspace: "ws-2",
      keys: [{ name: "second" }],
      error: false,
    });
    expect(fallback()).toMatchObject({ workspace: "ws-1", keys: [{ name: "first" }] });
  });

  it("answers a new key's plaintext to its caller only, and reads the list again after each change", async () => {
    const t = setup();
    let keys = [key("old")];
    t.api.on("GET", keysPath("ws-1"), () => json(200, keys));
    t.api.on("POST", keysPath("ws-1"), (request) => {
      const created = key((request.body as { name: string }).name);
      keys = [...keys, created];
      return json(201, {
        ...created,
        key: "salix_gk_plaintext",
        post_message_url: "https://x.test/post",
      });
    });
    t.api.on("PATCH", `${keysPath("ws-1")}/gak_old`, () => {
      keys = [key("old", "disabled"), ...keys.slice(1)];
      return json(200, keys[0]);
    });
    const shown = t.watch<RouterKeysValue>({ topic: "routerKeys", prefer: "ws-1" });
    await t.time.pass(100);
    const created = t.client.call("routerKeys.create", {
      workspace: "ws-1",
      name: " Zendesk ",
    });
    await t.time.pass(100);
    expect(await created).toMatchObject({ key: "salix_gk_plaintext", name: "Zendesk" });
    expect(t.api.seen("POST", keysPath("ws-1"))[0]!.body).toEqual({ name: "Zendesk" });
    expect(shown().keys?.map((k) => k.name)).toEqual(["old", "Zendesk"]);
    expect(JSON.stringify(shown())).not.toContain("plaintext");
    const disabled = t.client.call("routerKeys.setStatus", {
      workspace: "ws-1",
      key: "gak_old",
      status: "disabled",
    });
    await t.time.pass(100);
    await disabled;
    expect(t.api.seen("PATCH", `${keysPath("ws-1")}/gak_old`)[0]!.body).toEqual({
      status: "disabled",
    });
    expect(shown().keys?.[0]).toMatchObject({ status: "disabled" });
  });

  it("keeps the last list when a read fails, says so, and reads again on refresh", async () => {
    const t = setup();
    let up = true;
    t.api.on("GET", keysPath("ws-1"), () => (up ? json(200, [key("old")]) : offline()));
    const shown = t.watch<RouterKeysValue>({ topic: "routerKeys", prefer: "ws-1" });
    await t.time.pass(100);
    up = false;
    await t.client.call("routerKeys.refresh", {});
    await t.time.pass(100);
    expect(shown()).toMatchObject({ keys: [{ name: "old" }], error: true });
    up = true;
    await t.client.call("routerKeys.refresh", {});
    await t.time.pass(100);
    expect(shown()).toMatchObject({ error: false });
  });
});

describe("inbound API keys, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    let keys = [key("old")];
    t.api.on("GET", keysPath("ws-1"), () => json(200, keys));
    t.api.on("DELETE", `${keysPath("ws-1")}/gak_old`, () => {
      keys = [];
      return json(200, { deleted: true });
    });
    t.watch({ topic: "routerKeys", prefer: "ws-1" });
    await t.time.pass(100);
    const deleted = t.client.call("routerKeys.delete", {
      workspace: "ws-1",
      key: "gak_old",
    });
    await t.time.pass(100);
    await deleted;

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const first = told.find(
      (input) => input.kind === "response" && input.request.path === keysPath("ws-1")
    )!;
    if (first.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(first.body));
    first.body = base64(new TextEncoder().encode(body.replace('"old"', '"other"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
