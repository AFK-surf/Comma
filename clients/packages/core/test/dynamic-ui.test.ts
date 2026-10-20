import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { DynamicUiValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const path = "/v1/comma/groups/g/conversations/c/messages/m/attachments/0";
const ui = { version: 1, html: "<p>Weather</p>", script: "", data: {} };
const widget = (read = 0): Topic => ({
  topic: "dynamicUi",
  group: "g",
  conversation: "c",
  message: "m",
  index: "0",
  read: String(read),
});

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const stops = new Map<string, () => void>();
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    stops.set(
      key,
      client.subscribe(
        topic,
        (v) => values.set(key, v),
        () => undefined
      )
    );
    return () => values.get(key) as DynamicUiValue | undefined;
  };
  const unwatch = (topic: Topic) => stops.get(topicKey(topic))?.();
  core.observeSession(signedIn());
  return { time: host.time!, api: host.api, watch, unwatch };
}

describe("a message's generated UI", () => {
  it("is read once, and kept for a later showing", async () => {
    const t = setup();
    t.api.on("GET", path, ui);
    const value = t.watch(widget());
    await t.time.pass(100);
    expect(value()).toEqual({ status: "ready", ui });

    t.unwatch(widget());
    await t.time.pass(120_000, 10_000);
    const again = t.watch(widget(1));
    await t.time.pass(100);
    expect(again()).toEqual({ status: "ready", ui });
    expect(t.api.seen("GET", path)).toHaveLength(1);
  });

  it("reads a failure that time can fix once more 2 seconds later, without saying it failed", async () => {
    const t = setup();
    let reads = 0;
    t.api.on("GET", path, () =>
      ++reads === 1 ? json(502, { error: "upstream_unavailable" }) : json(200, ui)
    );
    const value = t.watch(widget());
    await t.time.pass(1_900, 100);
    expect(value()).toEqual({ status: "loading" });
    expect(reads).toBe(1);
    await t.time.pass(200, 100);
    expect(value()).toEqual({ status: "ready", ui });
    expect(reads).toBe(2);
  });

  it("says it cannot load after a second failure, or at once for one time cannot fix, and reads again on a new read", async () => {
    const t = setup();
    t.api.on("GET", path, offline());
    const value = t.watch(widget());
    await t.time.pass(2_100, 100);
    expect(value()).toMatchObject({ status: "failed", kind: "load" });
    expect(t.api.seen("GET", path)).toHaveLength(2);

    t.api.on("GET", path, json(404, { error: "not_found" }));
    const retried = t.watch(widget(1));
    await t.time.pass(100);
    expect(retried()).toMatchObject({ status: "failed", kind: "load" });
    await t.time.pass(5_000, 1_000);
    expect(t.api.seen("GET", path)).toHaveLength(3);
  });

  it("says a widget over 256 KiB or that is no JSON cannot display", async () => {
    const t = setup();
    t.api.on("GET", path, () => ({
      status: 200,
      headers: [],
      body: new TextEncoder().encode("not json"),
    }));
    const value = t.watch(widget());
    await t.time.pass(100);
    expect(value()).toMatchObject({ status: "failed", kind: "display" });

    t.api.on("GET", path, () => ({
      status: 200,
      headers: [],
      body: new Uint8Array(262_145),
    }));
    const large = t.watch(widget(1));
    await t.time.pass(100);
    expect(large()).toEqual({
      status: "failed",
      kind: "display",
      reason: "UI exceeds 256 KiB",
    });
  });
});
