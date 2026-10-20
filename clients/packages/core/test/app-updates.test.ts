import { HostError } from "@comma/core-kernel";
import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import { APP_UPDATE_INTERVAL_MS } from "../src/app-updates.ts";
import type { AppUpdateValue } from "../src/contract.ts";
import type { AppRelease } from "../src/host.ts";
import { FakeDesktop, FakeUpdates } from "../src/testing/fake-desktop.ts";
import { FakeHost, inProcessOpener, startTestCore } from "../src/testing/index.ts";

const release = (version: string): AppRelease => ({
  version,
  release: { TargetFullRelease: { Version: version } },
});

function setup(options: { replays?: boolean } = {}) {
  const host = new FakeHost();
  const updates = new FakeUpdates();
  const desktop = new FakeDesktop();
  desktop.updates = updates;
  host.desktop = desktop;
  const core = startTestCore(host, options);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  let value: AppUpdateValue | undefined;
  client.subscribe(
    { topic: "appUpdate" },
    (next) => (value = next as AppUpdateValue),
    () => undefined
  );
  return {
    time: host.time!,
    updates,
    value: () => value,
    call: (name: string) => client.call(name, {}),
  };
}

describe("the app's update", () => {
  it("is checked at start and each hour; a release found is downloaded, offered, and no more is checked", async () => {
    const t = setup();
    await t.time.pass(10);
    expect(t.updates.count("check")).toBe(1);
    expect(t.value()).toEqual({ downloading: false, ready: null });

    t.updates.script.check = () => release("0.0.2");
    let finishDownload!: (downloaded: boolean) => void;
    t.updates.script.download = () =>
      new Promise((resolve) => (finishDownload = resolve));
    await t.time.pass(APP_UPDATE_INTERVAL_MS - 1_000);
    expect(t.updates.count("check")).toBe(1);
    await t.time.pass(1_000);
    expect(t.updates.asked).toContainEqual(["download", release("0.0.2")]);
    // Topic changes go out together, 50 ms after.
    await t.time.pass(100);
    expect(t.value()).toEqual({ downloading: true, ready: null });
    expect(t.updates.count("apply")).toBe(0);
    finishDownload(true);
    await t.time.pass(100);
    expect(t.value()).toEqual({
      downloading: false,
      ready: { productName: "Comma Test", version: "0.0.2" },
    });

    await t.time.pass(3 * APP_UPDATE_INTERVAL_MS);
    expect(t.updates.count("status")).toBe(2);
    expect(t.updates.count("check")).toBe(2);
    expect(t.updates.count("download")).toBe(1);
    expect(t.updates.count("apply")).toBe(0);
    expect(t.value()?.ready?.version).toBe("0.0.2");

    // Restart now: the release the core downloaded.
    expect(await t.call("appUpdate.apply")).toEqual({ applied: true });
    expect(t.updates.asked.at(-1)).toEqual(["apply", release("0.0.2")]);
  });

  it("offers a release downloaded before at once, without checking the feed", async () => {
    const t = setup();
    t.updates.script.status = () => ({
      configured: true,
      productName: "Comma Staging",
      pendingRestart: release("0.0.3"),
    });
    t.updates.script.apply = () => false;
    await t.time.pass(10);
    expect(t.value()?.ready).toEqual({
      productName: "Comma Staging",
      version: "0.0.3",
    });
    expect(t.updates.count("check")).toBe(0);
    expect(t.updates.count("download")).toBe(0);
    // The platform could not start it: the window says so, and may ask again.
    expect(await t.call("appUpdate.apply")).toEqual({ applied: false });
  });

  it("tries a failed check again after 5 and 30 seconds, then after the hour", async () => {
    const t = setup();
    // A failure each way: the feed unreachable, the feed broken, a download not confirmed.
    const failures = [
      () => new HostError("temporary network failure"),
      () => ({ configured: true, error: "the feed is broken" }),
    ];
    t.updates.script.status = () =>
      failures.shift()?.() ?? { configured: true, productName: "Comma Test" };
    t.updates.script.check = () => release("0.0.2");
    t.updates.script.download = () => false;
    await t.time.pass(10);
    expect(t.updates.count("status")).toBe(1);
    await t.time.pass(5_000);
    expect(t.updates.count("status")).toBe(2);
    await t.time.pass(30_000);
    expect(t.updates.count("status")).toBe(3);
    expect(t.updates.count("download")).toBe(1);
    expect(t.value()).toEqual({ downloading: false, ready: null });

    await t.time.pass(APP_UPDATE_INTERVAL_MS - 1_000);
    expect(t.updates.count("status")).toBe(3);
    t.updates.script.download = () => true;
    await t.time.pass(1_000);
    expect(t.updates.count("status")).toBe(4);
    await t.time.pass(100);
    expect(t.value()?.ready?.version).toBe("0.0.2");
  });

  it("lets Check for Updates join the check under way and share its download", async () => {
    const t = setup();
    let finish!: (downloaded: boolean) => void;
    t.updates.script.check = () => release("0.0.2");
    t.updates.script.download = () => new Promise((resolve) => (finish = resolve));
    await t.time.pass(10);
    expect(t.value()).toEqual({ downloading: true, ready: null });

    const manual = t.call("appUpdate.check");
    await t.time.pass(10);
    finish(true);
    expect(await manual).toEqual({ outcome: "ready" });
    expect(t.updates.count("check")).toBe(1);
    expect(t.updates.count("download")).toBe(1);

    // Once on disk, a check answers at once.
    expect(await t.call("appUpdate.check")).toEqual({ outcome: "ready" });
    expect(t.updates.asked).toHaveLength(3);
  });

  it("answers Check for Updates with what the feed said, and moves the schedule as any check", async () => {
    const t = setup();
    await t.time.pass(APP_UPDATE_INTERVAL_MS / 2);
    expect(await t.call("appUpdate.check")).toEqual({ outcome: "current" });
    expect(t.updates.count("check")).toBe(2);
    // The next is an hour after that check, not the first.
    await t.time.pass(APP_UPDATE_INTERVAL_MS / 2);
    expect(t.updates.count("check")).toBe(2);
    await t.time.pass(APP_UPDATE_INTERVAL_MS / 2);
    expect(t.updates.count("check")).toBe(3);

    t.updates.script.status = () => new HostError("offline");
    await expect(t.call("appUpdate.check")).rejects.toMatchObject({ code: "host" });
    t.updates.script.status = () => ({ configured: false });
    expect(await t.call("appUpdate.check")).toEqual({ outcome: "unconfigured" });
  });

  it("catches up a check the computer slept through when the window comes back", async () => {
    // The wall clock jumps while no timer runs: a replay's clock cannot sleep through it.
    const t = setup({ replays: false });
    await t.time.pass(10);
    await t.call("appUpdate.wake");
    await t.time.pass(10);
    expect(t.updates.count("check")).toBe(1);

    t.time.sleepThrough(APP_UPDATE_INTERVAL_MS);
    await t.call("appUpdate.wake");
    await t.time.pass(10);
    expect(t.updates.count("check")).toBe(2);
  });
});
