import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import { describe, expect, it } from "vitest";
import type { ProductInboxListResult } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";
import { base64, fromBase64 } from "../src/record.ts";
import { comparable, replay } from "../src/testing/replay.ts";

const workspaceA = { group_id: "grp_a", id: "wsp_a", name: "Alpha", status: "ready" };
const workspaceB = { group_id: "grp_b", id: "wsp_b", name: "Beta", status: "ready" };
const listA = "/v1/comma/groups/grp_a/conversations";
const listB = "/v1/comma/groups/grp_b/conversations";
const eventsA = "/v1/comma/groups/grp_a/conversations/events";
const eventsB = "/v1/comma/groups/grp_b/conversations/events";

const conversation = (id: string, extra: Record<string, unknown> = {}) => ({
  group_id: "grp_a",
  id,
  kind: "agent_task",
  status: "running",
  title: `Task ${id}`,
  updated_at: 1_700_000_000,
  ...extra,
});
const invalidated = (version: string, group = "grp_a") => ({
  type: "conversation_list_invalidated",
  group_id: group,
  kind: "agent_task",
  version,
});

function setup(host = new FakeHost()) {
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspaceA, workspaceB] });
  host.api.onStream(eventsA).onStream(eventsB);
  const core = startTestCore(host);
  // What the core sent the UI, as it went on the wire.
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
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    client.subscribe(
      topic,
      (v) => values.set(key, v),
      (e) => values.set(key, { error: e.code })
    );
    return () => values.get(key) as ProductInboxListResult;
  };
  return { host, core, client, time: host.time!, api: host.api, watch, sent };
}

describe("a workspace's task list", () => {
  it("is loading, not empty, until its first read when the device kept nothing", async () => {
    const t = setup();
    t.api.on("GET", listA, { data: [conversation("c1")] });
    const release = t.api.hold("GET", listA);
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    expect(shown()).toBeNull();
    release();
    await t.time.pass(100);
    expect(shown()).toMatchObject({ source: "live-sync", items: [{ id: "grp_a:c1" }] });
  });

  it("shows what the device kept, offline, with each task's labels, platform and archive facts", async () => {
    const host = new FakeHost();
    host.api.on("GET", listA, {
      data: [
        conversation("c1", {
          labels: ["urgent"],
          client_platform: "ios",
          origin: "telegram",
          archive_availability: { allowed: false, reason: "not_finished" },
          secret_internal_field: "dropped",
        }),
      ],
    });
    const first = setup(host);
    first.core.observeSession(signedIn());
    const shown = first.watch({ topic: "tasks", workspace: "wsp_a" });
    await first.time.pass(100);
    expect(shown()).toMatchObject({ source: "live-sync", activeWorkspaceId: "wsp_a" });
    first.core.close();

    host.api.on("GET", listA, offline());
    host.api.on("GET", "/v1/comma/workspaces", offline());
    const again = setup(host);
    host.api.on("GET", "/v1/comma/workspaces", offline());
    again.core.observeSession(signedIn());
    const cached = again.watch({ topic: "tasks", workspace: "wsp_a" });
    await again.time.pass(100);
    expect(cached()).toMatchObject({
      source: "cache",
      errorCode: "network_unavailable",
      items: [
        {
          id: "grp_a:c1",
          labels: ["urgent"],
          clientPlatform: "ios",
          origin: "telegram",
          archiveAvailability: { allowed: false, reason: "not_finished" },
          archiveVersion: 1_700_000_000,
          updatedAt: 1_700_000_000_000,
          workspaceName: "Alpha",
          // Every client shows it in the same section.
          statusBucket: "in_progress",
          statusFailed: false,
        },
      ],
    });
    expect(JSON.stringify(cached())).not.toContain("secret_internal_field");
  });

  it("carries a coding task's pull request, and drops one it cannot read instead of failing the list", async () => {
    const t = setup();
    const url = "https://github.com/acme/api/pull/12";
    t.api.on("GET", listA, {
      data: [
        conversation("c1", {
          pull_request: { number: 12, state: "merged", url, extra: "dropped" },
        }),
        conversation("c2", { pull_request: { number: 12, state: "unknown", url } }),
        conversation("c3"),
        conversation("c4", {
          pull_request: { number: 12, state: "open", url: "not a url" },
        }),
        // It opens outside the app: a page of the web only.
        conversation("c5", {
          pull_request: { number: 12, state: "open", url: "file:///etc/passwd" },
        }),
      ],
    });
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    const byId = new Map(shown().items.map((item) => [item.id, item]));
    expect(byId.get("grp_a:c1")?.pullRequest).toEqual({
      number: 12,
      state: "merged",
      url,
    });
    for (const id of ["c2", "c3", "c4", "c5"])
      expect(byId.get(`grp_a:${id}`)).not.toHaveProperty("pullRequest");
    expect(byId.size).toBe(5);
  });

  it("says which tasks are Loops, and that only a Loop not ended is scheduled", async () => {
    const t = setup();
    t.api.on("GET", listA, {
      data: [
        // An older server's schedule on a one-off Task is no Loop.
        conversation("one-off", { schedule: { command: "Summarize the week" } }),
        conversation("loop", {
          loop: {
            state: "paused",
            reason: "waiting",
            cadence: { cron: "0 9 * * 1-5", timezone: "Asia/Shanghai" },
            started_at: 1_700_000_000_000,
            wake_count: 2,
            last_wake_at: 1_700_000_050_000,
          },
        }),
        conversation("pending", {
          loop: {
            state: "pending",
            cadence: { events: "new comments on PR #12" },
            started_at: 1_700_000_000_000,
            wake_count: 0,
          },
        }),
        conversation("ended", {
          loop: {
            state: "ended",
            reason: "max_runs",
            cadence: { every_minutes: 360 },
            max_runs: 4,
            started_at: 1_700_000_000_000,
            wake_count: 4,
            ended_at: 1_700_000_100_000,
          },
        }),
      ],
    });
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    const [oneOff, loop, pending, ended] = shown().items;
    expect(oneOff).not.toHaveProperty("loop");
    expect(oneOff).not.toHaveProperty("scheduled");
    expect(loop).toMatchObject({
      scheduled: true,
      loop: {
        state: "paused",
        reason: "waiting",
        cadence: {
          pattern: { kind: "weekdays", hour: 9, minute: 0 },
          cron: "0 9 * * 1-5",
          timezone: "Asia/Shanghai",
        },
        wakeCount: 2,
        lastWakeAt: 1_700_000_050_000,
      },
    });
    expect(pending).toMatchObject({
      scheduled: true,
      loop: { state: "pending", cadence: { events: "new comments on PR #12" } },
    });
    expect(ended).toMatchObject({
      loop: {
        state: "ended",
        reason: "max_runs",
        cadence: { pattern: { kind: "interval", minutes: 360 } },
        maxRuns: 4,
        wakeCount: 4,
      },
    });
    expect(ended).not.toHaveProperty("scheduled");
  });

  it("reads the list again when its group's stream says it changed, and only then", async () => {
    const t = setup();
    let version = 1;
    t.api.on("GET", listA, () =>
      json(200, { data: [conversation("c1", { title: `v${version}` })] })
    );
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    expect(t.api.seen("GET", listA)).toHaveLength(1);
    await t.time.pass(60_000, 1_000);
    expect(t.api.seen("GET", listA)).toHaveLength(1);

    version = 2;
    t.api.open(eventsA)!.event(invalidated("2"));
    await t.time.pass(100);
    expect(shown()).toMatchObject({ items: [{ title: "v2" }] });
    // The same version said again reads nothing.
    t.api.open(eventsA)!.event(invalidated("2"));
    await t.time.pass(100);
    expect(t.api.seen("GET", listA)).toHaveLength(2);
  });

  it("sends a change to one task of a long list as one op on that task", async () => {
    const t = setup();
    let title = "Before";
    t.api.on("GET", listA, () =>
      json(200, {
        data: Array.from({ length: 30 }, (_, i) =>
          conversation(`c${i}`, { title: i === 7 ? title : `Task c${i}` })
        ),
      })
    );
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    expect(shown().items).toHaveLength(30);
    const before = t.sent.length;

    title = "After";
    t.api.open(eventsA)!.event(invalidated("2"));
    await t.time.pass(100);
    expect(shown().items[7]).toMatchObject({ title: "After" });
    const ops = t.sent
      .slice(before)
      .flatMap((m) => (m as { delta?: { path: unknown[] }[] }).delta ?? []);
    expect(ops.filter((op) => op.path[0] === "items")).toEqual([
      expect.objectContaining({ key: ["id"], patch: "grp_a:c7" }),
    ]);
  });

  it("starts the stream again when a change it said could not be read, and reads it then", async () => {
    const t = setup();
    let failing = false;
    t.api.on("GET", listA, () =>
      failing ? offline() : json(200, { data: [conversation("c1")] })
    );
    t.core.observeSession(signedIn());
    t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    failing = true;
    t.api.open(eventsA)!.event(invalidated("2"));
    await t.time.pass(100);
    expect(t.api.streams.filter((s) => s.path === eventsA)).toHaveLength(1);
    failing = false;
    await t.time.pass(1_100, 100);
    // A new stream, whose resync replays the change.
    expect(t.api.streams.filter((s) => s.path === eventsA)).toHaveLength(2);
    t.api
      .open(eventsA)!
      .event({ ...invalidated("2"), type: "conversation_list_resync_required" });
    await t.time.pass(100);
    expect(t.api.seen("GET", listA).length).toBeGreaterThanOrEqual(3);
  });

  it("tries a failed first read again after 1, 2, 4 s while no stream can wake it", async () => {
    const t = setup();
    t.api.on("GET", listA, offline());
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({
      source: "error",
      errorCode: "network_unavailable",
    });
    const reads = () => t.api.seen("GET", listA).length;
    expect(reads()).toBe(1);
    await t.time.pass(1_000, 100);
    expect(reads()).toBe(2);
    await t.time.pass(2_000, 100);
    expect(reads()).toBe(3);
    await t.time.pass(3_000, 100);
    expect(reads()).toBe(3);
    t.api.on("GET", listA, { data: [conversation("c1")] });
    await t.time.pass(1_100, 100);
    expect(shown()).toMatchObject({ source: "live-sync", items: [{ id: "grp_a:c1" }] });
  });

  it("follows the focused workspace, and retries its read though another group's stream is open", async () => {
    const t = setup();
    t.api.on("GET", listA, { data: [conversation("c1")] });
    t.api.on("GET", listB, offline());
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ activeWorkspaceId: "wsp_a" });
    await t.client.call("tasks.focus", { workspace: "wsp_b" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ activeWorkspaceId: "wsp_b", source: "error" });
    t.api.on("GET", listB, { data: [conversation("c9", { group_id: "grp_b" })] });
    await t.time.pass(1_100, 100);
    expect(shown()).toMatchObject({
      activeWorkspaceId: "wsp_b",
      items: [{ id: "grp_b:c9", workspaceName: "Beta" }],
    });
  });

  it("gives up a read after 5 s, and a later read can go", async () => {
    const t = setup();
    t.api.hold("GET", listA);
    t.api.on("GET", listA, { data: [conversation("c1")] });
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(5_100, 100);
    expect(shown()).toMatchObject({
      source: "error",
      errorCode: "network_unavailable",
    });
    await t.time.pass(1_100, 100);
    expect(shown()).toMatchObject({ source: "live-sync" });
  });

  it("answers a 304 with the list it read before", async () => {
    const t = setup();
    let etagged = false;
    t.api.on("GET", listA, () =>
      etagged
        ? { status: 304, headers: [], body: new Uint8Array() }
        : {
            status: 200,
            headers: [["etag", '"v1"']],
            body: new TextEncoder().encode(
              JSON.stringify({ data: [conversation("c1")] })
            ),
          }
    );
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    etagged = true;
    await t.client.call("tasks.refresh", { workspace: "wsp_a" });
    await t.time.pass(100);
    expect(t.api.seen("GET", listA)).toHaveLength(2);
    expect(shown()).toMatchObject({ source: "live-sync", items: [{ id: "grp_a:c1" }] });
  });

  it("loads the next page after what is shown, keeps the tail as read and its cursor when the first page is read again", async () => {
    const t = setup();
    let reads = 0;
    t.api.on("GET", listA, (request) => {
      if (request.path.includes("cursor=page-3"))
        return json(200, { data: [conversation("c3")], has_more: false });
      if (request.path.includes("cursor="))
        return json(200, {
          data: [conversation("c2")],
          has_more: true,
          next_cursor: "page-3",
        });
      reads += 1;
      return json(200, {
        data: [conversation("c1")],
        has_more: true,
        next_cursor: `first-${reads}`,
      });
    });
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ hasMore: true, nextCursor: "first-1" });
    await t.client.call("tasks.more", { workspace: "wsp_a" });
    await t.time.pass(100);
    expect(shown().items.map((item) => item.id)).toEqual(["grp_a:c1", "grp_a:c2"]);
    expect(shown()).toMatchObject({ hasMore: true, nextCursor: "page-3" });
    await t.client.call("tasks.refresh", { workspace: "wsp_a" });
    await t.time.pass(100);
    expect(shown().items.map((item) => item.id)).toEqual(["grp_a:c1", "grp_a:c2"]);
    expect(shown()).toMatchObject({ hasMore: true, nextCursor: "page-3" });
    await t.client.call("tasks.more", { workspace: "wsp_a" });
    await t.time.pass(100);
    expect(shown().items.map((item) => item.id)).toEqual([
      "grp_a:c1",
      "grp_a:c2",
      "grp_a:c3",
    ]);
    expect(t.api.seen("GET", listA).map((r) => r.path.split("?")[1])).toEqual([
      "archive=include&limit=50",
      "archive=include&limit=50&cursor=first-1",
      "archive=include&limit=50",
      "archive=include&limit=50&cursor=page-3",
    ]);
    expect(shown()).toMatchObject({ hasMore: false });
    expect(shown()).not.toHaveProperty("nextCursor");
  });

  it("tells the session a 401, and shows nothing of an account another took the place of", async () => {
    const t = setup();
    t.api.on("GET", listA, json(401, { error: "unauthorized" }));
    t.core.observeSession(signedIn("alice"));
    const session = t.watch({ topic: "session" }) as unknown as () => {
      rejected?: unknown;
    };
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    expect(session()).toMatchObject({ rejected: { status: 401 } });
    expect(shown()).toMatchObject({ errorCode: "session_product_lease_unavailable" });
  });

  it("keeps nothing of one account's late answer for the account that took its place", async () => {
    const t = setup();
    t.api.on("GET", listA, (request) =>
      json(200, {
        data: [
          conversation(request.lease.sessionId === "session-alice" ? "alices" : "bobs"),
        ],
      })
    );
    const release = t.api.hold("GET", listA);
    t.core.observeSession(signedIn("alice"));
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    t.core.observeSession(signedIn("bob"));
    await t.time.pass(100);
    release();
    await t.time.pass(100);
    expect(shown().items.map((item) => item.conversationId)).toEqual(["bobs"]);
  });
});

describe("a change a person made", () => {
  it("shows an archive at once and ends it once the server reports it", async () => {
    const t = setup();
    let status = "completed";
    t.api.on("GET", listA, () => json(200, { data: [conversation("c1", { status })] }));
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    const { stage } = (await t.client.call("tasks.stage", {
      groupId: "grp_a",
      conversationId: "c1",
      status: "archived",
      version: 1_700_000_000,
    })) as { stage: number };
    await t.time.pass(100);
    expect(shown()).toMatchObject({ items: [{ status: "archived" }] });
    await t.client.call("tasks.stage.settle", { stage, accepted: true });
    // A read before the server has it keeps showing the decision.
    await t.client.call("tasks.refresh", { workspace: "wsp_a" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ items: [{ status: "archived" }] });
    status = "archived";
    await t.client.call("tasks.refresh", { workspace: "wsp_a" });
    await t.time.pass(100);
    status = "completed";
    await t.client.call("tasks.refresh", { workspace: "wsp_a" });
    await t.time.pass(100);
    // Ended: a later restore elsewhere shows.
    expect(shown()).toMatchObject({ items: [{ status: "completed" }] });
  });

  it("gives the task back when the change is refused, or the server has a later version", async () => {
    const t = setup();
    let updated = 1_700_000_000;
    t.api.on("GET", listA, () =>
      json(200, {
        data: [conversation("c1", { status: "completed", updated_at: updated })],
      })
    );
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    const refused = (await t.client.call("tasks.stage", {
      groupId: "grp_a",
      conversationId: "c1",
      status: "archived",
      version: updated,
    })) as { stage: number };
    await t.client.call("tasks.stage.settle", {
      stage: refused.stage,
      accepted: false,
    });
    await t.time.pass(10);
    expect(shown()).toMatchObject({ items: [{ status: "completed" }] });

    await t.client.call("tasks.stage", {
      groupId: "grp_a",
      conversationId: "c1",
      status: "archived",
      version: updated,
    });
    updated += 10;
    await t.client.call("tasks.refresh", { workspace: "wsp_a" });
    await t.time.pass(100);
    expect(shown()).toMatchObject({ items: [{ status: "completed" }] });
  });
});

describe("a run of the task list, recorded", () => {
  it("plays again to the same outputs, at the same times", async () => {
    const t = setup();
    let title = "First";
    t.api.on("GET", listA, (request) =>
      request.path.includes("cursor=")
        ? json(200, { data: [conversation("c2")], has_more: false })
        : json(200, {
            data: [conversation("c1", { title, status: "completed" })],
            has_more: true,
            next_cursor: "page-2",
          })
    );
    t.core.observeSession(signedIn());
    const shown = t.watch({ topic: "tasks", workspace: "wsp_a" });
    await t.time.pass(100);
    title = "Second";
    t.api.open(eventsA)!.event(invalidated("2"));
    await t.time.pass(100);
    await t.client.call("tasks.more", { workspace: "wsp_a" });
    await t.time.pass(100);
    const { stage } = (await t.client.call("tasks.stage", {
      groupId: "grp_a",
      conversationId: "c1",
      status: "archived",
      version: 1_700_000_000,
    })) as { stage: number };
    await t.time.pass(100);
    await t.client.call("tasks.stage.settle", { stage, accepted: true });
    t.api.on("GET", listA, offline());
    await t.client.call("tasks.refresh", { workspace: "wsp_a" }).catch(() => undefined);
    await t.time.pass(3_000);
    expect(shown().items.map((item) => item.id)).toEqual(["grp_a:c1", "grp_a:c2"]);

    const recorded = t.core.recorder!;
    // The run had timers fire, a stream, and a request that failed: each is an input the replay must give again.
    const kinds = new Set(recorded.inputs.map((input) => input.kind));
    expect([...kinds]).toEqual(
      expect.arrayContaining(["tick", "stream", "piece", "failure", "ui"])
    );
    const again = await replay(recorded, { until: t.time.now() });
    expect(comparable(again.outputs)).toEqual(comparable(recorded.outputs));

    // A log told differently plays to different outputs: the comparison sees what the core showed.
    const told = structuredClone(recorded.inputs);
    const first = told.find(
      (input) => input.kind === "response" && input.request.path.startsWith(`${listA}?`)
    )!;
    if (first.kind !== "response") throw new Error("no response");
    const body = new TextDecoder().decode(fromBase64(first.body));
    expect(body).toContain('"First"');
    first.body = base64(new TextEncoder().encode(body.replace('"First"', '"Other"')));
    const changed = await replay(
      { inputs: told, outputs: recorded.outputs },
      { until: t.time.now() }
    );
    expect(comparable(changed.outputs)).not.toEqual(comparable(recorded.outputs));
  });
});
