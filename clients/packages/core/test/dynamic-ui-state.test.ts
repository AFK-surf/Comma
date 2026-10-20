import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { DynamicUiStateValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  signedOut,
  startTestCore,
} from "../src/testing/index.ts";

function setup(host = new FakeHost()) {
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, unknown>();
  const watch = (topic: Topic) => {
    const k = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(k, v),
      () => undefined
    );
    return () => values.get(k) as DynamicUiStateValue;
  };
  core.observeSession(signedIn());
  return { core, client, time: host.time!, watch };
}

describe("a generated UI's saved state", () => {
  it("is what the widget saved last, for every surface that shows it, until the account signs out", async () => {
    const t = setup();
    const shown = t.watch({ topic: "dynamicUiState", key: "widget-a" });
    const other = t.watch({ topic: "dynamicUiState", key: "widget-b" });
    await t.time.pass(100);
    expect(shown()).toEqual({ state: null, cards: null });

    await t.client.call("dynamicUiState.save", {
      key: "widget-a",
      kind: "state",
      text: '{"step":1}',
    });
    await t.client.call("dynamicUiState.save", {
      key: "widget-a",
      kind: "cards",
      text: '{"done":["a"]}',
    });
    await t.time.pass(100);
    expect(shown()).toEqual({ state: '{"step":1}', cards: '{"done":["a"]}' });
    expect(other()).toEqual({ state: null, cards: null });

    t.core.observeSession(signedOut());
    await t.time.pass(100);
    t.core.observeSession(signedIn("user-1", { generation: 3 }));
    await t.time.pass(100);
    expect(shown()).toEqual({ state: null, cards: null });
  });

  it("keeps the 256 widgets saved most recently", async () => {
    const t = setup();
    const first = t.watch({ topic: "dynamicUiState", key: "widget-0" });
    for (let i = 0; i <= 256; i += 1) {
      await t.client.call("dynamicUiState.save", {
        key: `widget-${i}`,
        kind: "state",
        text: String(i),
      });
      await t.time.pass(1);
    }
    const last = t.watch({ topic: "dynamicUiState", key: "widget-256" });
    await t.time.pass(100);
    expect(first()).toEqual({ state: null, cards: null });
    expect(last()).toEqual({ state: "256", cards: null });
  });

  it("refuses text that is no JSON or over 32 KiB", async () => {
    const t = setup();
    for (const text of ["{", JSON.stringify("x".repeat(32_768))])
      await expect(
        t.client.call("dynamicUiState.save", { key: "widget-a", kind: "state", text })
      ).rejects.toMatchObject({ code: "invalid_params" });
  });
});
