import { CoreClient } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import {
  FakeHost,
  inProcessOpener,
  json,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

function setup() {
  const host = new FakeHost();
  const core = startTestCore(host);
  const client = new CoreClient(inProcessOpener(core, host), {
    schedule: () => undefined,
  });
  core.observeSession(signedIn("user-1", { sessionId: "session-1" }));
  host.api.on("GET", "/v1/comma/auth/session", { session_id: "session-1" });
  return { host, client, time: host.time!, api: host.api };
}

const device = {
  token: "apns-token",
  environment: "production",
  workspace: "w1",
  group: "g1",
  bundleId: "surf.comma.ios",
  locale: "en-US",
};

describe("the iPhone's push registrations", () => {
  it("registers the device for the session signed in, as the server takes it", async () => {
    const t = setup();
    t.api.on(
      "POST",
      "/v1/comma/notifications/devices",
      json(200, { id: "reg-1", status: "active" })
    );
    const registered = t.client.call("notifications.registerDevice", {
      ...device,
      session: "session-1",
    });
    await t.time.pass(100);
    await expect(registered).resolves.toEqual({ id: "reg-1" });
    expect(t.api.seen("POST", "/v1/comma/notifications/devices")[0]!.body).toEqual({
      token: "apns-token",
      environment: "production",
      workspace_id: "w1",
      group_id: "g1",
      bundle_id: "surf.comma.ios",
      locale: "en-US",
    });
  });

  it("refuses a registration for a session that is no longer the one signed in, asking nothing", async () => {
    const t = setup();
    const refused = expect(
      t.client.call("notifications.registerDevice", { ...device, session: "session-0" })
    ).rejects.toMatchObject({ code: "session_changed" });
    await t.time.pass(100);
    await refused;
    expect(t.api.seen("POST", "/v1/comma/notifications/devices")).toEqual([]);
  });

  it("registers a Live Activity's token, or the push-to-start token when it names no activity", async () => {
    const t = setup();
    for (const path of ["live-activities", "push-to-start"])
      t.api.on("POST", `/v1/comma/notifications/${path}`, (request) =>
        json(200, {
          id: (request.body as { registration_id: string }).registration_id,
          status: "active",
        })
      );
    const live = t.client.call("notifications.registerActivity", {
      ...device,
      session: "session-1",
      registration: "reg-live",
      activity: "activity-1",
    });
    const start = t.client.call("notifications.registerActivity", {
      ...device,
      session: "session-1",
      registration: "reg-start",
    });
    await t.time.pass(100);
    await expect(live).resolves.toEqual({ id: "reg-live" });
    await expect(start).resolves.toEqual({ id: "reg-start" });
    expect(
      t.api.seen("POST", "/v1/comma/notifications/live-activities")[0]!.body
    ).toMatchObject({
      registration_id: "reg-live",
      activity_id: "activity-1",
      activity_schema: "tasks_v1",
    });
    expect(
      t.api.seen("POST", "/v1/comma/notifications/push-to-start")[0]!.body
    ).toMatchObject({
      registration_id: "reg-start",
      activity_schema: "tasks_v1",
      group_id: "g1",
    });
  });

  it("fails a registration the server did not make active", async () => {
    const t = setup();
    t.api.on(
      "POST",
      "/v1/comma/notifications/devices",
      json(200, { id: "reg-1", status: "pending" })
    );
    const refused = expect(
      t.client.call("notifications.registerDevice", { ...device, session: "session-1" })
    ).rejects.toMatchObject({ code: "bad_response" });
    await t.time.pass(100);
    await refused;
  });

  it("registers generalized live status push-to-start and per-key tokens with live_status_v1 schema", async () => {
    const t = setup();
    for (const path of ["live-statuses/push-to-start", "live-statuses/tokens"])
      t.api.on("POST", `/v1/comma/notifications/${path}`, (request) =>
        json(200, {
          id: (request.body as { registration_id: string }).registration_id,
          status: "active",
        })
      );
    const start = t.client.call("notifications.registerLiveStatus", {
      ...device,
      session: "session-1",
      registration: "reg-ls-start",
    });
    const token = t.client.call("notifications.registerLiveStatus", {
      ...device,
      session: "session-1",
      registration: "reg-ls-key",
      activity: "activity-car-1",
      liveKey: "didi:order-123",
    });
    await t.time.pass(100);
    await expect(start).resolves.toEqual({ id: "reg-ls-start" });
    await expect(token).resolves.toEqual({ id: "reg-ls-key" });
    expect(
      t.api.seen("POST", "/v1/comma/notifications/live-statuses/push-to-start")[0]!.body
    ).toMatchObject({
      registration_id: "reg-ls-start",
      activity_schema: "live_status_v1",
      group_id: "g1",
    });
    expect(
      t.api.seen("POST", "/v1/comma/notifications/live-statuses/tokens")[0]!.body
    ).toMatchObject({
      registration_id: "reg-ls-key",
      activity_id: "activity-car-1",
      live_key: "didi:order-123",
      activity_schema: "live_status_v1",
    });
  });

  it("rejects generalized live status token registration when only one of activity or liveKey is set", async () => {
    const t = setup();
    const refused = expect(
      t.client.call("notifications.registerLiveStatus", {
        ...device,
        session: "session-1",
        registration: "reg-ls-bad",
        liveKey: "didi:order-123",
      })
    ).rejects.toMatchObject({ code: "invalid_params" });
    await t.time.pass(100);
    await refused;
  });

  it("unregisters a generalized live status registration with reason and lists active live statuses", async () => {
    const t = setup();
    t.api.on(
      "DELETE",
      "/v1/comma/notifications/live-statuses/registrations/reg-ls-1",
      json(204, null)
    );
    t.api.on(
      "GET",
      "/v1/comma/groups/g1/live-activities",
      json(200, {
        data: [
          {
            key: "didi:order-123",
            workspace_id: "w1",
            group_id: "g1",
            conversation_id: "conv-1",
            category: "car",
            status: "active",
            accent: "green",
            title: "沪A·D8821 白色比亚迪汉",
            subtitle: "距您 1.2 km · 预计 3 分钟到达",
            compact_label: "3分钟",
            eta_epoch_seconds: 1_800_000_180,
            progress: 0.65,
            step_current: 2,
            step_total: 4,
            step_label: "接驾中",
            detail_left: "张师傅 · 4.9★",
            detail_right: "沪A·D8821",
            stale_epoch_seconds: 1_800_000_300,
            expires_epoch_seconds: 1_800_003_600,
            started_at_epoch_seconds: 1_799_999_900,
            dismiss_at_epoch_seconds: null,
            updated_at_epoch_seconds: 1_800_000_000,
          },
          {
            key: "other-group:item",
            workspace_id: "w2",
            group_id: "g-other",
            category: "order",
            status: "active",
            accent: "auto",
            title: "Ignored",
            updated_at_epoch_seconds: 1_800_000_000,
          },
        ],
      })
    );
    const removed = t.client.call("notifications.unregisterLiveStatus", {
      id: "reg-ls-1",
      reason: "dismissed",
    });
    const list = t.client.call("notifications.liveStatuses", { group: "g1" });
    await t.time.pass(100);
    await expect(removed).resolves.toBeNull();
    await expect(list).resolves.toEqual({
      items: [
        {
          key: "didi:order-123",
          workspaceId: "w1",
          groupId: "g1",
          conversationId: "conv-1",
          category: "car",
          status: "active",
          accent: "green",
          title: "沪A·D8821 白色比亚迪汉",
          subtitle: "距您 1.2 km · 预计 3 分钟到达",
          compactLabel: "3分钟",
          etaEpochSeconds: 1_800_000_180,
          progress: 0.65,
          stepCurrent: 2,
          stepTotal: 4,
          stepLabel: "接驾中",
          detailLeft: "张师傅 · 4.9★",
          detailRight: "沪A·D8821",
          staleEpochSeconds: 1_800_000_300,
          expiresEpochSeconds: 1_800_003_600,
          startedAtEpochSeconds: 1_799_999_900,
          dismissAtEpochSeconds: null,
          updatedAtEpochSeconds: 1_800_000_000,
        },
      ],
    });
    expect(
      t.api.seen(
        "DELETE",
        "/v1/comma/notifications/live-statuses/registrations/reg-ls-1"
      )[0]!.path
    ).toContain("reason=dismissed");
  });

  it("skips unknown live status categories and decodes started_at_epoch_seconds and dismiss_at_epoch_seconds", async () => {
    const t = setup();
    t.api.on(
      "GET",
      "/v1/comma/groups/g1/live-activities",
      json(200, {
        data: [
          {
            key: "future:widget-1",
            workspace_id: "w1",
            group_id: "g1",
            category: "future_widget",
            status: "active",
            accent: "auto",
            title: "Future Category",
            updated_at_epoch_seconds: 1_800_000_050,
          },
          {
            key: "order:luckin-42",
            workspace_id: "w1",
            group_id: "g1",
            category: "order",
            status: "done",
            accent: "amber",
            title: "瑞幸咖啡 已完成",
            started_at_epoch_seconds: 1_800_000_000,
            dismiss_at_epoch_seconds: 1_800_000_600,
            updated_at_epoch_seconds: 1_800_000_300,
          },
        ],
      })
    );
    const list = t.client.call("notifications.liveStatuses", { group: "g1" });
    await t.time.pass(100);
    await expect(list).resolves.toEqual({
      items: [
        {
          key: "order:luckin-42",
          workspaceId: "w1",
          groupId: "g1",
          conversationId: null,
          category: "order",
          status: "done",
          accent: "amber",
          title: "瑞幸咖啡 已完成",
          subtitle: null,
          compactLabel: null,
          etaEpochSeconds: null,
          progress: null,
          stepCurrent: null,
          stepTotal: null,
          stepLabel: null,
          detailLeft: null,
          detailRight: null,
          staleEpochSeconds: null,
          expiresEpochSeconds: null,
          startedAtEpochSeconds: 1_800_000_000,
          dismissAtEpochSeconds: 1_800_000_600,
          updatedAtEpochSeconds: 1_800_000_300,
        },
      ],
    });
  });
});
