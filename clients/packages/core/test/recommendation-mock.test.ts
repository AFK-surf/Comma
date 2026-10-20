import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { RecommendationMockValue } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const PATH = "/v1/debug/recommendation-mock";

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  host.api.on("GET", "/v1/comma/workspaces", {
    data: [
      { id: "wsp_1", group_id: "grp_1", name: "Main" },
      { id: "wsp_2", group_id: "grp_2", name: "Other" },
    ],
  });
  let value: RecommendationMockValue | undefined;
  client.subscribe(
    { topic: "recommendationMock" },
    (v) => (value = v as RecommendationMockValue),
    () => undefined
  );
  core.observeSession(signedIn());
  return { client, time: host.time!, api: host.api, shown: () => value };
}

describe("the dev app's recommendation mock", () => {
  it("is read when shown, and is set for the account's first workspace as read now", async () => {
    const t = setup();
    t.api.on("GET", PATH, { available: true, enabled: false });
    await t.time.pass(100);
    expect(t.shown()).toEqual({ status: "ready", available: true, enabled: false });

    t.api.on("PATCH", PATH, { available: true, enabled: true, syncError: true });
    const set = t.client.call("recommendationMock.set", { enabled: true });
    await t.time.pass(100);
    expect(await set).toEqual({ available: true, enabled: true, syncError: true });
    expect(t.api.seen("GET", "/v1/comma/workspaces").length).toBeGreaterThanOrEqual(1);
    expect(t.api.seen("PATCH", PATH).map((r) => r.body)).toEqual([
      { enabled: true, workspaceId: "wsp_1" },
    ]);
    expect(t.shown()).toEqual({
      status: "ready",
      available: true,
      enabled: true,
      syncError: true,
    });
  });

  it("says when it cannot be read, and refreshes the first workspace's recommendations", async () => {
    const t = setup();
    t.api.on("GET", PATH, offline());
    await t.time.pass(100);
    expect(t.shown()).toEqual({ status: "failed" });

    t.api.on(
      "POST",
      "/v1/comma/workspaces/wsp_1/recommendations/refresh",
      json(429, { error: "rate_limited" })
    );
    const refresh = t.client.call("recommendationMock.refresh", {});
    await t.time.pass(100);
    expect(await refresh).toBeNull();
    expect(
      t.api.seen("POST", "/v1/comma/workspaces/wsp_1/recommendations/refresh")
    ).toHaveLength(1);
  });
});
