import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { MarksValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

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
    return () => (values.get(k) as MarksValue).marks;
  };
  core.observeSession(signedIn());
  return { core, client, time: host.time!, watch };
}

describe("the reader's marks", () => {
  it("never move a mark backwards, and drop marks on request", async () => {
    const t = setup();
    const seen = t.watch({ topic: "marks", kind: "taskReviewSeen" });
    await t.client.call("marks.mark", {
      kind: "taskReviewSeen",
      entries: [["cnv-1", 200]],
    });
    await t.client.call("marks.mark", {
      kind: "taskReviewSeen",
      entries: [
        ["cnv-1", 150],
        ["cnv-2", 5],
      ],
    });
    await t.time.pass(100);
    expect(seen()).toEqual({ "cnv-1": 200, "cnv-2": 5 });
    await t.client.call("marks.unmark", {
      kind: "taskReviewSeen",
      ids: ["cnv-2", "missing"],
    });
    await t.time.pass(100);
    expect(seen()).toEqual({ "cnv-1": 200 });
  });

  it("keep each kind apart, and evict the oldest past the kind's cap", async () => {
    const t = setup();
    const seen = t.watch({ topic: "marks", kind: "taskReviewSeen" });
    const deleted = t.watch({ topic: "marks", kind: "inboxDeleted" });
    await t.client.call("marks.mark", {
      kind: "taskReviewSeen",
      entries: Array.from({ length: 301 }, (_, i) => [`cnv-${i}`, i + 1]),
    });
    await t.time.pass(100);
    expect(Object.keys(seen())).toHaveLength(300);
    expect(seen()["cnv-0"]).toBeUndefined();
    expect(seen()["cnv-300"]).toBe(301);
    expect(deleted()).toEqual({});
    await expect(
      t.client.call("marks.mark", { kind: "other" as "inboxDeleted", entries: [] })
    ).rejects.toMatchObject({ code: "invalid_params" });
  });

  it("mark ids at the core's time and an acknowledgement at no known run, and drop the oldest acknowledgements past the cap", async () => {
    const t = setup();
    const deleted = t.watch({ topic: "marks", kind: "inboxDeleted" });
    const dismissed = t.watch({ topic: "marks", kind: "chatTaskDismissed" });
    await t.client.call("marks.mark", { kind: "inboxDeleted", ids: ["w1:n1"] });
    const at = t.time.now();
    // An acknowledgement of no known run is at 0, never at the device's time.
    await t.client.call("marks.mark", { kind: "chatTaskDismissed", ids: ["cnv-0"] });
    await t.time.pass(100);
    expect(deleted()).toEqual({ "w1:n1": at });
    expect(dismissed()).toEqual({ "cnv-0": 0 });
    await t.client.call("marks.mark", {
      kind: "chatTaskDismissed",
      entries: Array.from({ length: 300 }, (_, index) => [
        `cnv-${index + 1}`,
        index + 1,
      ]),
    });
    await t.time.pass(100);
    expect(Object.keys(dismissed())).toHaveLength(300);
    expect(dismissed()["cnv-0"]).toBeUndefined();
    expect(dismissed()["cnv-300"]).toBe(300);
  });

  it("belong to the account: another account starts without them", async () => {
    const t = setup();
    const seen = t.watch({ topic: "marks", kind: "inboxUnread" });
    await t.client.call("marks.mark", { kind: "inboxUnread", entries: [["w1:c1", 1]] });
    await t.time.pass(100);
    expect(seen()).toEqual({ "w1:c1": 1 });
    t.core.observeSession(
      signedIn("user-2", { sessionId: "session-2", generation: 2 })
    );
    await t.time.pass(100);
    expect(seen()).toEqual({});
  });
});

describe("the reader's marks, recorded", () => {
  it("play again to the same outputs", async () => {
    const t = setup();
    t.watch({ topic: "marks", kind: "inboxDeleted" });
    await t.time.pass(100);
    await t.client.call("marks.mark", {
      kind: "inboxDeleted",
      entries: [["w1:c1", 3]],
    });
    await t.time.pass(100);
    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
