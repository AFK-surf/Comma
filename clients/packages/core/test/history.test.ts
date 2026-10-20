import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { SessionHistoryValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const base = "/v1/comma/groups/g/conversations/c/participants/p/history";
const events = `${base}/events`;
const target = { group: "g", conversation: "c", participant: "p" };
const topic: Topic = { topic: "history", ...target };

const now = 1_767_225_600_000;
const record = (id: number | string, content: unknown = `Record ${id}`) => ({
  id: String(id),
  kind: "assistant",
  content,
  timestamp_ms: now,
});
const page = (ids: number[], hasMore = false) => ({
  conversation_id: "c",
  participant_id: "p",
  records: ids.map((id) => record(id)),
  has_more: hasMore,
  next_before: hasMore ? String(ids[0]) : null,
});
const frame = (
  phase: "recent" | "update" | "checkpoint",
  ids: number[],
  extra: Record<string, unknown> = {}
) => ({
  conversation_id: "c",
  participant_id: "p",
  records: ids.map((id) => record(id)),
  live_records: [],
  server_time_ms: now,
  phase,
  checkpoint: null,
  ...extra,
});
const query = (path: string) => new URLSearchParams(path.split("?")[1] ?? "");

function setup(host = new FakeHost()) {
  host.api.onStream(events);
  const core = startTestCore(host);
  const sent: unknown[] = [];
  const open = inProcessOpener(core, host);
  const client = new CoreClient(
    (onMessage) =>
      open((message) => {
        sent.push(message);
        onMessage(message);
      }),
    { schedule: () => undefined }
  );
  const values = new Map<string, unknown>();
  const watch = (t: Topic = topic) => {
    const key = topicKey(t);
    const stop = client.subscribe(
      t,
      (v) => values.set(key, v),
      (e) => values.set(key, { error: e.code })
    );
    return Object.assign(() => values.get(key) as SessionHistoryValue, { stop });
  };
  const load = (mode: "preview" | "latest" | "older") =>
    client.call("history.load", { ...target, mode });
  core.observeSession(signedIn());
  return { host, core, client, time: host.time!, api: host.api, watch, load, sent };
}
const ids = (value: SessionHistoryValue) => value.records.map((r) => r.id);

describe("a session history's pages", () => {
  it("reads a detail page asked for while the preview loads once the preview has come", async () => {
    const t = setup();
    t.api.on("GET", base, (request) =>
      json(
        200,
        query(request.path).get("limit") === "3"
          ? page([3, 4, 5], true)
          : page([1, 2, 3, 4, 5])
      )
    );
    const release = t.api.hold("GET", base);
    const shown = t.watch();
    const asked = [t.load("preview"), t.load("latest"), t.load("latest")];
    await t.time.pass(100);
    release();
    await t.time.pass(100);
    await Promise.all(asked);
    expect(t.api.seen("GET", base).map((r) => query(r.path).get("limit"))).toEqual([
      "3",
      "50",
    ]);
    expect(ids(shown())).toEqual(["1", "2", "3", "4", "5"]);
  });

  it("reads each older page once, before what is shown, and shows the records oldest first", async () => {
    const t = setup();
    t.api.on("GET", base, (request) => {
      const q = query(request.path);
      if (q.get("before") === "3") return json(200, page([1, 2]));
      return json(200, page([3, 4, 5], true));
    });
    const shown = t.watch();
    await Promise.all([t.load("preview"), t.load("preview")]);
    await t.load("latest");
    await Promise.all([t.load("older"), t.load("older")]);
    await t.time.pass(100);
    expect(t.api.seen("GET", base).map((r) => query(r.path).toString())).toEqual([
      "limit=3",
      "limit=50",
      "limit=50&before=3",
    ]);
    expect(ids(shown())).toEqual(["1", "2", "3", "4", "5"]);
    expect(shown()).toMatchObject({
      hasMore: false,
      loaded: "detail",
      status: "ready",
    });
  });

  it("pages through a long history 50 records at a time, before the oldest shown, losing and repeating none", async () => {
    const t = setup();
    const total = 153;
    t.api.on("GET", base, (request) => {
      const before = Number(query(request.path).get("before") ?? total + 1);
      const first = Math.max(1, before - 50);
      const range = Array.from({ length: before - first }, (_, i) => first + i);
      return json(200, {
        ...page(range),
        has_more: first > 1,
        next_before: first > 1 ? String(first) : null,
      });
    });
    const shown = t.watch();
    await t.load("latest");
    await t.time.pass(100);
    for (let pages = 1; shown().hasMore; pages++) {
      expect(pages).toBeLessThan(4);
      await t.load("older");
      await t.time.pass(100);
    }
    await t.time.pass(100);
    const asked = t.api.seen("GET", base).map((r) => query(r.path));
    expect(asked).toHaveLength(4);
    expect(asked.every((q) => q.get("limit") === "50")).toBe(true);
    expect(asked.slice(1).map((q) => Number(q.get("before")))).toEqual(
      Array.from({ length: 3 }, (_, index) => 104 - index * 50)
    );
    expect(ids(shown())).toEqual(
      Array.from({ length: total }, (_, i) => String(i + 1))
    );
  });

  it("keeps what is shown when a page fails, and reads the same cursor again", async () => {
    const t = setup();
    let online = true;
    t.api.on("GET", base, (request) => {
      if (!online) return offline();
      return json(
        200,
        query(request.path).get("before") ? page([1, 2]) : page([3, 4], true)
      );
    });
    const shown = t.watch();
    await t.load("latest");
    online = false;
    await t.load("older");
    await t.time.pass(100);
    expect(shown()).toMatchObject({ status: "error", error: "unavailable" });
    expect(ids(shown())).toEqual(["3", "4"]);
    online = true;
    await t.load("older");
    await t.time.pass(100);
    expect(ids(shown())).toEqual(["1", "2", "3", "4"]);
    const asked = t.api.seen("GET", base).map((r) => query(r.path).toString());
    expect(asked.slice(1)).toEqual(["limit=50&before=3", "limit=50&before=3"]);
  });

  it("says forbidden when the server refuses the history", async () => {
    const t = setup();
    t.api.on("GET", base, json(403, { error: "forbidden" }));
    const shown = t.watch();
    await t.load("latest");
    await t.time.pass(100);
    expect(shown()).toMatchObject({ status: "error", error: "forbidden", records: [] });
  });

  it("shows nothing of one account's late page for the account that took its place", async () => {
    const t = setup();
    t.api.on("GET", base, (request) =>
      json(200, page(request.lease.sessionId === "session-user-1" ? [1] : [9]))
    );
    const release = t.api.hold("GET", base);
    const shown = t.watch();
    const old = t.load("latest");
    await t.time.pass(100);
    t.core.observeSession(signedIn("user-2"));
    await t.time.pass(100);
    await t.load("latest");
    release();
    await old.catch(() => undefined);
    await t.time.pass(100);
    expect(ids(shown())).toEqual(["9"]);
  });
});

describe("a session history's live stream", () => {
  it("opens one stream while shown, adds what is newer than the pages, and replays from its last checkpoint", async () => {
    const t = setup();
    const release = t.api.hold("GET", base);
    t.api.on("GET", base, (request) =>
      json(
        200,
        query(request.path).get("before") === "2"
          ? page([1])
          : { ...page([2, 3], true), next_before: "2" }
      )
    );
    const shown = t.watch();
    const second = t.watch();
    await t.time.pass(100);
    expect(t.api.streams).toHaveLength(1);
    const first = t.api.open(events)!;
    const initial = t.load("latest");
    first.named("history", frame("recent", [1, 2, 3, 4]));
    await t.time.pass(10);
    release();
    await initial;
    await t.time.pass(100);
    // The recent record before the page is no older page of its own; the one after it is not lost.
    expect(ids(shown())).toEqual(["2", "3", "4"]);
    first.named("history", frame("checkpoint", [], { checkpoint: "4" }));
    first.named("history", frame("update", [5]));
    await t.load("older");
    await t.time.pass(100);
    expect(ids(shown())).toEqual(["1", "2", "3", "4", "5"]);
    expect(shown()).toMatchObject({ streamStatus: "live" });

    first.end();
    await t.time.pass(100);
    expect(shown()).toMatchObject({ streamStatus: "reconnecting" });
    await t.time.pass(1_000);
    const next = t.api.open(events)!;
    expect(t.api.seen("GET", events).map((r) => query(r.path).get("after"))).toEqual([
      null,
      "4",
    ]);
    next.named("history", frame("update", [5, 6]));
    await t.time.pass(100);
    expect(ids(shown())).toEqual(["1", "2", "3", "4", "5", "6"]);

    // Every view let go: the stream closes a second later, not a minute (a view back within it keeps it).
    shown.stop();
    second.stop();
    await t.time.pass(500);
    expect(next.closed).toBe(false);
    await t.time.pass(600);
    expect(next.closed).toBe(true);
  });

  it("waits 1, 2, 4, 8 then 10 s between connections that fail, and 1 s again after one that gave a frame", async () => {
    const t = setup();
    t.api.onStream(events, 503);
    t.watch();
    const opened = () => t.api.seen("GET", events).length;
    const counts: number[] = [];
    // Each mark is 10 ms after a connection is due: 0, 1, 3, 7, 15, 25 and 35 s.
    let passed = 0;
    for (const at of [10, 990, 1_010, 2_990, 3_010, 7_010, 15_010, 25_010, 35_010]) {
      await t.time.pass(at - passed, 10);
      passed = at;
      counts.push(opened());
    }
    expect(counts).toEqual([1, 1, 2, 2, 3, 4, 5, 6, 7]);

    t.api.onStream(events);
    await t.time.pass(10_000, 10);
    const stream = t.api.open(events)!;
    stream.named("history", frame("update", [1]));
    stream.end();
    const before = opened();
    await t.time.pass(1_010, 10);
    expect(opened()).toBe(before + 1);
  });

  it("sends nothing for a heartbeat that changes nothing", async () => {
    const t = setup();
    t.api.on("GET", base, page([1, 2]));
    const shown = t.watch();
    await t.load("latest");
    await t.time.pass(100);
    const stream = t.api.open(events)!;
    stream.named("history", frame("update", [], { checkpoint: "2" }));
    await t.time.pass(100);
    const sent = t.sent.length;
    stream.named("history", frame("checkpoint", [], { checkpoint: "2" }));
    stream.named("history", frame("checkpoint", [], { checkpoint: "2" }));
    await t.time.pass(100);
    expect(t.sent.length).toBe(sent);
    stream.named(
      "history",
      frame("update", [], { records: [record(2, "Record 2, revised")] })
    );
    await t.time.pass(100);
    expect(shown().records.map((r) => r.content)).toEqual([
      "Record 1",
      "Record 2, revised",
    ]);
  });

  it("refuses a frame of another history, and reconnects", async () => {
    const t = setup();
    const shown = t.watch();
    await t.time.pass(100);
    t.api
      .open(events)!
      .named("history", { ...frame("update", [1]), participant_id: "other" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ records: [], streamStatus: "reconnecting" });
    await t.time.pass(1_000);
    expect(t.api.seen("GET", events)).toHaveLength(2);
  });
});

describe("a run of a session history, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.api.on("GET", base, (request) =>
      json(200, query(request.path).get("before") ? page([1]) : page([2, 3], true))
    );
    // Each step settles before the next, as a person's would.
    t.watch();
    await t.time.pass(100);
    await t.load("preview");
    await t.time.pass(100);
    await t.load("latest");
    await t.time.pass(100);
    const stream = t.api.open(events)!;
    stream.named("history", frame("update", [4]));
    stream.named("history", frame("checkpoint", [], { checkpoint: "4" }));
    await t.time.pass(100);
    await t.load("older");
    await t.time.pass(100);
    stream.end();
    await t.time.pass(1_500);
    t.api.open(events)!.named("history", frame("update", [5]));
    await t.time.pass(100);

    const recorded = t.core.recorder!;
    const kinds = new Set(recorded.inputs.map((input) => input.kind));
    expect([...kinds]).toEqual(
      expect.arrayContaining(["tick", "stream", "piece", "end", "response", "ui"])
    );
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
