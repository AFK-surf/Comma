import { COALESCE_MS } from "@comma/core-kernel";
import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { DriveSearchValue } from "../src/contract.ts";
import { comparable, replay } from "../src/testing/replay.ts";
import {
  FakeHost,
  FakeLocalDrive,
  flush,
  inProcessOpener,
  startTestCore,
} from "../src/testing/index.ts";

const file = FakeLocalDrive.file;

function setup(drive: FakeLocalDrive | null = new FakeLocalDrive()) {
  const host = new FakeHost();
  if (drive) host.localDrive = drive;
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  const values = new Map<string, DriveSearchValue>();
  const stops = new Map<string, () => void>();
  const search = (query: string, limit: number) => {
    const topic: Topic = { topic: "driveSearch", query, limit: String(limit) };
    const key = topicKey(topic);
    stops.set(
      key,
      client.subscribe(
        topic,
        (v) => values.set(key, v as DriveSearchValue),
        () => undefined
      )
    );
    return {
      value: () => values.get(key),
      paths: () => values.get(key)?.items.map((i) => `${i.spaceName}:${i.entry.path}`),
      stop: () => stops.get(key)!(),
    };
  };
  // Past the store's coalescing window, so what changed has gone out.
  const settle = (ms = 0) =>
    host.time!.pass(ms + COALESCE_MS + 10, ms >= 10_000 ? 1_000 : 10);
  return { host, core, client, drive: drive!, search, settle };
}

describe("Drive search", () => {
  it("finds files of every space newest first, by path or space, and says when there are more", async () => {
    const t = setup();
    t.drive.put("drive", [
      file("notes/plan.md", 3),
      file("photos/东京.jpg", 5),
      file("a", 1),
    ]);
    t.drive.put(
      "team",
      [file("plan-b.md", 4), file("logs", 2, { kind: "dir" })],
      "Team"
    );
    const all = t.search("", 3);
    const plan = t.search("plan", 10);
    const tokyo = t.search("东京", 10);
    const team = t.search("team / plan", 10);
    await t.settle();
    expect(all.value()).toMatchObject({ status: "ready", revision: 1, more: true });
    expect(all.paths()).toEqual([
      "Drive:photos/东京.jpg",
      "Team:plan-b.md",
      "Drive:notes/plan.md",
    ]);
    expect(plan.paths()).toEqual(["Team:plan-b.md", "Drive:notes/plan.md"]);
    expect(plan.value()?.more).toBe(false);
    expect(tokyo.paths()).toEqual(["Drive:photos/东京.jpg"]);
    expect(team.paths()).toEqual(["Team:plan-b.md"]);
    // One build served them all: one state read, one page per space.
    expect(t.drive.reads).toBe(1);
    expect(t.drive.pages).toBe(2);
  });

  it("reads a large space page by page", async () => {
    const t = setup();
    t.drive.pageSize = 2;
    t.drive.put("drive", [
      file("1", 1),
      file("2", 2),
      file("3", 3),
      file("4", 4),
      file("5", 5),
    ]);
    const all = t.search("", 10);
    await t.settle();
    expect(all.paths()).toEqual([
      "Drive:5",
      "Drive:4",
      "Drive:3",
      "Drive:2",
      "Drive:1",
    ]);
    expect(t.drive.pages).toBe(3);
  });

  it("reads again every 20 s while shown, and not once nothing shows it", async () => {
    const t = setup();
    t.drive.put("drive", [file("a", 1)]);
    const shown = t.search("", 5);
    await t.settle();
    expect(t.drive.reads).toBe(1);
    await t.settle(20_000);
    expect(t.drive.reads).toBe(2);
    shown.stop();
    // Past the topic's grace and two more periods: nothing reads the node.
    await t.host.time!.pass(120_000, 5_000);
    const reads = t.drive.reads;
    await t.host.time!.pass(60_000, 5_000);
    expect(t.drive.reads).toBe(reads);
  });

  it("reads once 150 ms after a burst of changes, and keeps the revision when nothing differs", async () => {
    const t = setup();
    t.drive.put("drive", [file("a", 1)]);
    const all = t.search("", 5);
    await t.settle();
    expect(all.value()?.revision).toBe(1);
    for (let i = 0; i < 5; i++) {
      t.drive.change();
      await t.host.time!.pass(100, 10);
    }
    expect(t.drive.reads).toBe(1);
    await t.host.time!.pass(150, 10);
    expect(t.drive.reads).toBe(2);
    await t.settle();
    expect(all.value()?.revision).toBe(1);

    t.drive.put("drive", [file("a", 1), file("b", 2)]);
    t.drive.change();
    await t.settle(150);
    expect(all.value()).toMatchObject({ revision: 2 });
    expect(all.paths()).toEqual(["Drive:b", "Drive:a"]);
  });

  it("says a deletion, and reads once more for a commit made during a read", async () => {
    const t = setup();
    t.drive.put("drive", [file("a", 1), file("b", 2)]);
    const all = t.search("", 5);
    await t.settle();
    t.drive.put("drive", [file("a", 1)]);
    t.drive.change();
    await t.settle(150);
    expect(all.paths()).toEqual(["Drive:a"]);
    const reads = t.drive.reads;

    t.drive.hold();
    t.drive.change();
    await t.host.time!.pass(150, 10);
    // During that read: another commit.
    t.drive.put("drive", [file("a", 1), file("c", 3)]);
    t.drive.change();
    t.drive.release();
    await t.settle(150);
    expect(t.drive.reads).toBe(reads + 2);
    expect(all.paths()).toEqual(["Drive:c", "Drive:a"]);
  });

  it("says there are more instead of nothing when a sparse query runs past its scan, and scans on for a larger limit", async () => {
    const t = setup();
    t.drive.put(
      "drive",
      Array.from({ length: 2100 }, (_, i) => file(`${i}-abc_bcz_cza_zab.txt`, i))
    );
    const few = t.search("abczabc", 5);
    const many = t.search("abczabc", 15);
    await t.settle();
    // The build yields as it sorts and indexes: it goes on turn by turn, with no time passing.
    for (let turn = 0; turn < 500 && few.value()?.status !== "ready"; turn++) {
      await flush();
      await t.settle();
    }
    expect(few.value()?.status).toBe("ready");
    expect(few.value()).toMatchObject({ items: [], more: true });
    expect(many.value()).toMatchObject({ items: [], more: false });
  });

  it("keeps the last index through a failure, says why, and reads again on retry", async () => {
    const t = setup();
    t.drive.put("drive", [file("a", 1)]);
    const all = t.search("", 5);
    await t.settle();
    t.drive.status = "error";
    t.drive.reason = "The Drive daemon stopped.";
    t.drive.change();
    await t.settle(150);
    expect(all.value()).toMatchObject({
      status: "error",
      reason: "The Drive daemon stopped.",
      revision: 1,
    });
    expect(all.paths()).toEqual(["Drive:a"]);
    // Not read again on the 20 s timer while it fails.
    const reads = t.drive.reads;
    await t.settle(40_000);
    expect(t.drive.reads).toBe(reads);

    t.drive.status = "ready";
    t.drive.reason = undefined;
    await t.client.call("driveSearch.retry", {});
    await t.settle();
    expect(all.value()).toMatchObject({ status: "ready", revision: 1 });
  });

  it("waits for a starting node, and gives a build up after 60 s", async () => {
    const t = setup();
    t.drive.put("drive", [file("a", 1)]);
    t.drive.status = "starting";
    const all = t.search("", 5);
    await t.settle(1_000);
    expect(all.value()?.status).toBe("loading");
    expect(t.drive.reads).toBe(3);
    t.drive.status = "ready";
    await t.settle(500);
    expect(all.value()?.status).toBe("ready");

    // A build held past 60 s is given up (the periodic ones wait while it runs).
    t.drive.hold();
    await t.client.call("driveSearch.retry", {});
    await t.host.time!.pass(59_000, 1_000);
    expect(all.value()?.status).toBe("ready");
    await t.settle(1_000);
    expect(all.value()).toMatchObject({
      status: "error",
      reason: "Drive file loading timed out. Try again.",
      revision: 1,
    });
    expect(all.paths()).toEqual(["Drive:a"]);
  });

  it("says Drive search is unavailable where the host has no Drive node (the web)", async () => {
    const t = setup(null);
    const all = t.search("", 5);
    await t.settle();
    expect(all.value()).toEqual({
      status: "unavailable",
      revision: 0,
      items: [],
      more: false,
    });
  });
});

describe("Drive search, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    t.drive.put("drive", [file("a", 1), file("b", 2)]);
    t.search("", 5);
    await t.settle();
    t.drive.put("drive", [file("a", 1), file("b", 2), file("c", 3)]);
    t.drive.change();
    await t.settle(150);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.host.time!.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));
  });
});
