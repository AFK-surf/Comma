import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ProactiveValue, RecommendationsValue } from "../src/contract.ts";
import type { CoreLimits } from "../src/limits.ts";
import { DELIVERY_GRACE_MS, msUntilDailyDelivery } from "../src/recommendations.ts";
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

const path = "/v1/comma/workspaces/wsp_1/recommendations";
const schedule = { enabled: true, hour: 8, minute: 0, timezone: "Asia/Singapore" };
const source = {
  appId: "github",
  appName: "GitHub",
  connectionId: "github-account",
  enabled: true,
  kind: "native_mcp_oauth" as const,
  label: "github",
};
const envelope = ({
  state = "empty",
  checked = true,
  sources = [],
  enabled = true,
}: {
  state?: "empty" | "fresh" | "refreshing" | "stale" | "error";
  checked?: boolean;
  sources?: (typeof source)[];
  enabled?: boolean;
} = {}) => ({
  settings: {
    autoEnableNewSources: true,
    sourcesCheckedAt: checked ? "2026-08-14T00:00:00Z" : null,
    schedule: { ...schedule, enabled },
    sourceRevision: 1,
    sources,
  },
  snapshot: null,
  state,
});

function setup(host = new FakeHost(), limits?: Partial<CoreLimits>) {
  const core = startTestCore(host, limits ? { limits } : {});
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [{ id: "wsp_1", group_id: "grp_1", name: "Main" }],
  });
  const values = new Map<string, unknown>();
  const stops = new Map<string, () => void>();
  const watch = <T>(topic: Topic) => {
    const k = topicKey(topic);
    stops.set(
      k,
      client.subscribe(
        topic,
        (v) => values.set(k, v),
        () => undefined
      )
    );
    return () => values.get(k) as T;
  };
  core.observeSession(signedIn());
  const reads = () => host.api.seen("GET", path).length;
  return { host, core, client, time: host.time!, api: host.api, watch, reads };
}

const rail = { topic: "recommendations", workspace: "wsp_1", timezone: "UTC" };

describe("Home's briefing", () => {
  it("follows a server-owned run every 2 seconds until it ends, then waits for the delivery", async () => {
    const t = setup();
    let state: "refreshing" | "fresh" = "refreshing";
    t.api.on("GET", path, () => json(200, envelope({ state, enabled: false })));
    const shown = t.watch<RecommendationsValue>(rail);
    await t.time.pass(100);
    expect(shown().envelope?.state).toBe("refreshing");
    expect(t.api.seen("GET", path)[0]!.path).toContain("timezone=UTC");
    await t.time.pass(4_000, 500);
    expect(t.reads()).toBe(3);
    state = "fresh";
    await t.time.pass(2_000, 500);
    expect(shown().envelope?.state).toBe("fresh");
    await t.time.pass(60_000, 10_000);
    expect(t.reads()).toBe(4);
  });

  it("calls a run unavailable only when more reads failed than its limit, and stops there", async () => {
    // The limit is 45 failed reads (limits.test.ts); 3 reach it the same way.
    const t = setup(undefined, { briefingReadFailures: 3 });
    let up = true;
    t.api.on("GET", path, () =>
      up ? json(200, envelope({ state: "refreshing", enabled: false })) : offline()
    );
    const shown = t.watch<RecommendationsValue>(rail);
    await t.time.pass(100);
    up = false;
    await t.time.pass(3 * 2_000, 1_000);
    expect(shown().failure).toBeNull();
    await t.time.pass(2_000, 1_000);
    expect(shown().failure).toBe("unavailable");
    const reads = t.reads();
    await t.time.pass(60_000, 10_000);
    expect(t.reads()).toBe(reads);
  });

  it("checks for connected apps at most 10 times, and again from the start on a new visit", async () => {
    const t = setup();
    t.api.on(
      "GET",
      path,
      envelope({ checked: false, sources: [source], enabled: false })
    );
    const shown = t.watch<RecommendationsValue>(rail);
    await t.time.pass(100);
    expect(shown().discovering).toBe(true);
    await t.time.pass(60_000, 500);
    expect(t.reads()).toBe(11);
    expect(shown().discovering).toBe(false);
    await t.client.call("recommendations.visit", { workspace: "wsp_1" });
    await t.time.pass(60_000, 500);
    expect(t.reads()).toBe(22);
  });

  it("reads again shortly after the daily delivery instant", async () => {
    const t = setup();
    t.api.on("GET", path, envelope({ state: "fresh" }));
    t.watch<RecommendationsValue>(rail);
    await t.time.pass(100);
    const until = msUntilDailyDelivery(schedule, t.time.now())!;
    const quiet = until + DELIVERY_GRACE_MS - 1_000;
    await t.time.pass(quiet, quiet);
    expect(t.reads()).toBe(1);
    await t.time.pass(2_000);
    expect(t.reads()).toBe(2);
  });

  it("reads again when a window comes back after a minute, not sooner", async () => {
    const t = setup();
    t.api.on("GET", path, envelope({ state: "fresh", enabled: false }));
    t.watch<RecommendationsValue>(rail);
    await t.time.pass(100);
    await t.client.call("recommendations.revisit", {});
    await t.time.pass(100);
    expect(t.reads()).toBe(1);
    await t.time.pass(60_000, 10_000);
    await t.client.call("recommendations.revisit", {});
    await t.time.pass(100);
    expect(t.reads()).toBe(2);
  });

  it("explains a refused refresh until a new briefing arrives, and follows an accepted one", async () => {
    const t = setup();
    let state: "fresh" | "refreshing" = "fresh";
    t.api.on("GET", path, () => json(200, envelope({ state, enabled: false })));
    const shown = t.watch<RecommendationsValue>(rail);
    await t.time.pass(100);
    t.api.on("POST", `${path}/refresh`, json(429, { error: "rate_limited" }));
    const refused = t.client.call("recommendations.refresh", { workspace: "wsp_1" });
    await t.time.pass(100);
    expect(await refused).toEqual({ rateLimited: true });
    expect(shown().failure).toBe("rate_limited");

    state = "refreshing";
    t.api.on("POST", `${path}/refresh`, {
      envelope: envelope({ state: "refreshing", enabled: false }),
      run: { generation: 2 },
    });
    const accepted = t.client.call("recommendations.refresh", { workspace: "wsp_1" });
    await t.time.pass(100);
    expect(await accepted).toEqual({ rateLimited: false });
    expect(shown()).toMatchObject({ failure: null, refreshing: false });
    const reads = t.reads();
    await t.time.pass(2_000, 500);
    expect(t.reads()).toBe(reads + 1);
  });

  it("reads again at once in another language, and never sends the language", async () => {
    const t = setup();
    t.api.on("GET", path, envelope({ state: "fresh", enabled: false }));
    t.watch<RecommendationsValue>({ ...rail, locale: "en" });
    await t.time.pass(100);
    expect(t.reads()).toBe(1);
    t.watch<RecommendationsValue>({ ...rail, locale: "zh-CN" });
    await t.time.pass(100);
    expect(t.reads()).toBe(2);
    for (const read of t.api.seen("GET", path))
      expect(read.path).toBe(`${path}?timezone=UTC`);
  });

  it("calls the briefing unavailable when it cannot be read, and when a refresh fails", async () => {
    const t = setup();
    t.api.on("GET", path, offline());
    const shown = t.watch<RecommendationsValue>(rail);
    await t.time.pass(100);
    expect(shown()).toMatchObject({ envelope: null, failure: "unavailable" });

    t.api.on(
      "GET",
      path,
      envelope({ state: "error", sources: [source], enabled: false })
    );
    await t.client.call("recommendations.visit", { workspace: "wsp_1" });
    await t.time.pass(100);
    expect(shown().failure).toBeNull();
    t.api.on("GET", path, offline());
    t.api.on("POST", `${path}/refresh`, offline());
    const refreshed = t.client.call("recommendations.refresh", { workspace: "wsp_1" });
    await t.time.pass(100);
    expect(await refreshed).toEqual({ rateLimited: false });
    expect(shown()).toMatchObject({ failure: "unavailable", refreshing: false });
    expect(t.api.seen("POST", `${path}/refresh`)).toHaveLength(1);
  });

  it("says a refresh is under way until the server answers", async () => {
    const t = setup();
    t.api.on(
      "GET",
      path,
      envelope({ state: "error", sources: [source], enabled: false })
    );
    const shown = t.watch<RecommendationsValue>(rail);
    await t.time.pass(100);
    expect(shown().refreshing).toBe(false);
    const release = t.api.hold("POST", `${path}/refresh`);
    t.api.on("POST", `${path}/refresh`, {
      envelope: envelope({ state: "refreshing", sources: [source], enabled: false }),
      run: { generation: 2 },
    });
    const refreshed = t.client.call("recommendations.refresh", { workspace: "wsp_1" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ refreshing: true, failure: null });
    release();
    await t.time.pass(100);
    expect(await refreshed).toEqual({ rateLimited: false });
    expect(shown()).toMatchObject({ refreshing: false, failure: null });
    expect(shown().envelope?.state).toBe("refreshing");
  });

  it("reads the workspace asked for, and saves a settings change to it as given", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/workspaces", {
      data: [
        { id: "wsp_1", group_id: "grp_1", name: "Main" },
        { id: "wsp_2", group_id: "grp_2", name: "Second" },
      ],
    });
    const second = "/v1/comma/workspaces/wsp_2/recommendations";
    t.api.on("GET", second, envelope({ sources: [source] }));
    t.api.on(
      "PATCH",
      `${second}/settings`,
      envelope({ sources: [{ ...source, enabled: false }] })
    );
    const shown = t.watch<RecommendationsValue>({ ...rail, workspace: "wsp_2" });
    await t.time.pass(100);
    expect(shown().workspace).toBe("wsp_2");
    expect(t.api.seen("GET", second)).toHaveLength(1);
    expect(t.reads()).toBe(0);
    const patch = {
      autoEnableNewSources: true,
      schedule,
      sources: [{ connectionId: source.connectionId, enabled: false }],
    };
    const saved = t.client.call("recommendations.updateSettings", {
      workspace: "wsp_2",
      patch,
    });
    await t.time.pass(100);
    expect(await saved).toBeNull();
    expect(t.api.seen("PATCH", `${second}/settings`).map((r) => r.body)).toEqual([
      patch,
    ]);
    expect(shown().envelope?.settings.sources[0]?.enabled).toBe(false);
  });
});

describe("automatic messages", () => {
  it("reads the workspace's Group setting and saves a change once", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/groups/grp_1/proactive", { enabled: false });
    t.api.on("PUT", "/v1/comma/groups/grp_1/proactive", { enabled: true });
    const shown = t.watch<ProactiveValue>({ topic: "proactive", prefer: "wsp_1" });
    await t.time.pass(100);
    expect(shown()).toEqual({ kind: "ready", groupId: "grp_1", enabled: false });
    const saved = t.client.call("proactive.set", { prefer: "wsp_1", enabled: true });
    await t.time.pass(100);
    await saved;
    expect(shown()).toMatchObject({ kind: "ready", enabled: true });
    const put = t.api.seen("PUT", "/v1/comma/groups/grp_1/proactive");
    expect(put).toHaveLength(1);
    expect(put[0]!.body).toMatchObject({
      enabled: true,
      request_id: expect.any(String),
    });
  });
});

describe("Home's briefing, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    let state: "refreshing" | "fresh" = "refreshing";
    t.api.on("GET", path, () => json(200, envelope({ state, enabled: false })));
    t.watch(rail);
    await t.time.pass(2_100, 500);
    state = "fresh";
    await t.time.pass(2_000, 500);

    const recorded = t.core.recorder!;
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    const told = structuredClone(recorded.inputs);
    const read = told.findLast(
      (input) => input.kind === "response" && input.request.path.startsWith(path)
    )!;
    if (read.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(read.body));
    read.body = base64(new TextEncoder().encode(body.replaceAll('"fresh"', '"stale"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});

describe("the daily delivery instant", () => {
  it("is the next schedule time on the schedule's clock", () => {
    const at = Date.parse("2026-08-14T23:00:00Z"); // 07:00 in Singapore
    expect(msUntilDailyDelivery(schedule, at)).toBe(3_600_000);
  });

  it("is tomorrow's once today's has passed, and unknown in an unknown timezone", () => {
    // 07:30 Singapore time.
    expect(msUntilDailyDelivery(schedule, Date.parse("2026-09-11T23:30:00Z"))).toBe(
      30 * 60_000
    );
    // 08:00:30 Singapore time: the next delivery is tomorrow.
    expect(msUntilDailyDelivery(schedule, Date.parse("2026-09-11T00:00:30Z"))).toBe(
      86_400_000 - 30_000
    );
    expect(
      msUntilDailyDelivery({ ...schedule, timezone: "Mars/Phobos" }, Date.now())
    ).toBeUndefined();
  });

  it.each([
    ["2026-11-01T04:30:00Z", 8, "2026-11-01T13:00:00Z"],
    ["2026-03-08T05:30:00Z", 8, "2026-03-08T12:00:00Z"],
    // Today's target passed and tomorrow's 02:00 does not exist.
    ["2026-03-07T08:00:00Z", 2, "2026-03-09T06:00:00Z"],
    // There is no 02:00 on the spring-forward day.
    ["2026-03-08T05:30:00Z", 2, "2026-03-09T06:00:00Z"],
    // The second 01:00 is still in the future after the first 01:30.
    ["2026-11-01T05:30:00Z", 1, "2026-11-01T06:00:00Z"],
  ])("is the next real delivery instant across DST from %s", (now, hour, next) => {
    expect(
      msUntilDailyDelivery(
        { hour, minute: 0, timezone: "America/New_York" },
        Date.parse(now)
      )
    ).toBe(Date.parse(next) - Date.parse(now));
  });
});
