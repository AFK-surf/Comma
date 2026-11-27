import { CoreClient, topicKey, type Topic } from "@comma/core-kernel/client";
import type { ChatTaskActivity } from "@comma/chat-contract";
import { describe, expect, it } from "vitest";
import type { TaskFeedSnapshot } from "../src/contract.ts";
import {
  FakeHost,
  inProcessOpener,
  json,
  offline,
  signedIn,
  startTestCore,
} from "../src/testing/index.ts";

const workspaceA = { group_id: "grp_a", id: "wsp_a", name: "Alpha", status: "ready" };
const workspaceB = { group_id: "grp_b", id: "wsp_b", name: "Beta", status: "ready" };
const feedA = "/v1/comma/groups/grp_a/task-feed";
const feedB = "/v1/comma/groups/grp_b/task-feed";
const eventsA = "/v1/comma/groups/grp_a/conversations/events";
const eventsB = "/v1/comma/groups/grp_b/conversations/events";

function rawEntry(id: string, extra: Record<string, unknown> = {}) {
  return {
    id,
    conversation_id: `cnv_${id}`,
    group_id: "grp_a",
    cluster_key: "brief",
    trigger_kind: "brief",
    trigger_text: null,
    task_title: `Task ${id}`,
    task_status: "ready_for_review",
    task_updated_at: 1_795_195_000,
    review_version: 1_795_195_000,
    origin: "comma",
    is_loop: false,
    loop_kind: null,
    occurred_at: 1_795_195_000_000,
    milestones: [
      { title: `Milestone ${id}`, at: 1_795_194_800_000, message_id: `msg_${id}_m1` },
    ],
    milestone_count: 1,
    outcome_message_id: `msg_${id}_out`,
    outcome_text: `Outcome for ${id}`,
    media: [
      {
        attachment_id: `att_${id}`,
        mime_type: "image/png",
        width: 1200,
        height: 800,
        filename: `${id}.png`,
      },
    ],
    files: [{ name: `${id}.md`, mime_type: "text/markdown" }],
    pull_request: null,
    ...extra,
  };
}

const invalidated = (version: string, group = "grp_a") => ({
  type: "conversation_list_invalidated",
  group_id: group,
  kind: "agent_task",
  version,
});

const resyncRequired = (version: string, group = "grp_a") => ({
  type: "conversation_list_resync_required",
  group_id: group,
  kind: "agent_task",
  version,
});

function setup(host = new FakeHost()) {
  host.api.on("GET", "/v1/comma/workspaces", { data: [workspaceA, workspaceB] });
  host.api.onStream(eventsA).onStream(eventsB);
  const core = startTestCore(host);
  const open = inProcessOpener(core, host);
  const client = new CoreClient(open, { schedule: () => undefined });
  const values = new Map<string, unknown>();
  const watch = (topic: Topic) => {
    const key = topicKey(topic);
    const unsub = client.subscribe(
      topic,
      (v) => values.set(key, v),
      (e) => values.set(key, { error: e.code })
    );
    return {
      get: () => values.get(key) as TaskFeedSnapshot,
      unsub,
    };
  };
  return { host, core, client, time: host.time!, api: host.api, watch };
}

describe("taskFeed topic and calls", () => {
  it("loads first page, normalizes fields, and serves SQLite cache immediately offline", async () => {
    const host = new FakeHost();
    host.api.on("GET", feedA, {
      entries: [
        rawEntry("tfe_1", {
          pull_request: {
            number: 42,
            state: "open",
            url: "https://github.com/AFK-surf/Cue/pull/42",
          },
          future_server_field: "ignored",
        }),
      ],
      has_more: true,
      next_cursor: "cur_2",
      future_page_field: 123,
    });
    const first = setup(host);
    const release = first.api.hold("GET", feedA);
    first.core.observeSession(signedIn());
    const feed = first.watch({ topic: "taskFeed", workspace: "wsp_a" });
    await first.time.pass(50);
    expect(feed.get()).toMatchObject({
      workspaceId: "wsp_a",
      loaded: false,
      source: "cache",
      entries: [],
    });

    release();
    await first.time.pass(100);
    expect(feed.get()).toMatchObject({
      workspaceId: "wsp_a",
      groupId: "grp_a",
      loaded: true,
      source: "live",
      hasMore: true,
      nextCursor: "cur_2",
      entries: [
        {
          id: "tfe_1",
          conversationId: "cnv_tfe_1",
          groupId: "grp_a",
          clusterKey: "brief",
          triggerKind: "brief",
          taskTitle: "Task tfe_1",
          taskStatus: "ready_for_review",
          statusBucket: "needs_review",
          taskUpdatedAt: 1_795_195_000_000,
          reviewVersion: 1_795_195_000,
          origin: "comma",
          isLoop: false,
          occurredAt: 1_795_195_000_000,
          milestoneCount: 1,
          outcomeMessageId: "msg_tfe_1_out",
          outcomeText: "Outcome for tfe_1",
          milestones: [
            {
              title: "Milestone tfe_1",
              at: 1_795_194_800_000,
              messageId: "msg_tfe_1_m1",
            },
          ],
          media: [
            {
              attachmentId: "att_tfe_1",
              mimeType: "image/png",
              width: 1200,
              height: 800,
              filename: "tfe_1.png",
            },
          ],
          files: [{ name: "tfe_1.md", mimeType: "text/markdown" }],
          pullRequest: {
            number: 42,
            state: "open",
            url: "https://github.com/AFK-surf/Cue/pull/42",
          },
        },
      ],
    });
    expect(JSON.stringify(feed.get())).not.toContain("future_server_field");
    first.core.close();

    // Restart offline: cached entries appear immediately with zero flicker.
    host.api.on("GET", feedA, offline());
    host.api.on("GET", "/v1/comma/workspaces", offline());
    const second = setup(host);
    host.api.on("GET", "/v1/comma/workspaces", offline());
    second.core.observeSession(signedIn());
    const cached = second.watch({ topic: "taskFeed", workspace: "wsp_a" });
    await second.time.pass(100);
    expect(cached.get()).toMatchObject({
      workspaceId: "wsp_a",
      groupId: "grp_a",
      loaded: true,
      source: "cache",
      errorCode: "network_unavailable",
      hasMore: true,
      nextCursor: "cur_2",
      entries: [{ id: "tfe_1", taskTitle: "Task tfe_1" }],
    });
  });

  it("defensively handles unknown trigger_kind, extra fields, and malformed single entries", async () => {
    const t = setup();
    t.api.on("GET", feedA, {
      entries: [
        rawEntry("tfe_ok", {
          trigger_kind: "brand_new_future_trigger",
          pull_request: { number: 1, state: "open", url: "javascript:alert(1)" },
          milestones: [{ title: "Valid step", at: 1_795_194_800 }, { broken: true }],
          media: [
            { attachment_id: "att_no_mime", filename: "shot.png" },
            { attachment_id: "att_null_mime", mime_type: null },
          ],
        }),
        { id: "", broken_entry: true },
        "not_an_object",
      ],
      has_more: false,
      next_cursor: null,
    });
    t.core.observeSession(signedIn());
    const feed = t.watch({ topic: "taskFeed", workspace: "wsp_a" });
    await t.time.pass(100);
    expect(feed.get().entries).toHaveLength(1);
    expect(feed.get().entries[0]).toMatchObject({
      id: "tfe_ok",
      triggerKind: "unknown",
      milestones: [{ title: "Valid step", at: 1_795_194_800_000 }],
      media: [
        { attachmentId: "att_no_mime", filename: "shot.png" },
        { attachmentId: "att_null_mime" },
      ],
    });
    expect(feed.get().entries[0]?.media[0]).not.toHaveProperty("mimeType");
    expect(feed.get().entries[0]?.media[1]).not.toHaveProperty("mimeType");
    expect(feed.get().entries[0]).not.toHaveProperty("pullRequest");
  });

  it("supports attention filter separately and paginates with cursor deduplication", async () => {
    const t = setup();
    t.api.on("GET", feedA, (req) => {
      const url = new URL(`https://api.comma.test${req.path}`);
      const attention = url.searchParams.get("attention");
      const cursor = url.searchParams.get("cursor");
      if (attention === "1") {
        return json(200, {
          entries: [rawEntry("tfe_att_1")],
          has_more: false,
          next_cursor: null,
        });
      }
      if (cursor === "cur_p2") {
        return json(200, {
          // tfe_2 duplicates page 1 and must be deduplicated while tfe_3 is appended.
          entries: [rawEntry("tfe_2"), rawEntry("tfe_3")],
          has_more: false,
          next_cursor: null,
        });
      }
      return json(200, {
        entries: [rawEntry("tfe_1"), rawEntry("tfe_2")],
        has_more: true,
        next_cursor: "cur_p2",
      });
    });

    t.core.observeSession(signedIn());
    const allFeed = t.watch({ topic: "taskFeed", workspace: "wsp_a" });
    const attFeed = t.watch({ topic: "taskFeed", workspace: "wsp_a", attention: "1" });
    await t.time.pass(100);

    expect(allFeed.get().entries.map((e) => e.id)).toEqual(["tfe_1", "tfe_2"]);
    expect(allFeed.get().hasMore).toBe(true);
    expect(allFeed.get().nextCursor).toBe("cur_p2");
    expect(attFeed.get().entries.map((e) => e.id)).toEqual(["tfe_att_1"]);
    // Only one group SSE stream is opened even when both filters are subscribed.
    expect(t.api.streams.filter((s) => s.path === eventsA)).toHaveLength(1);

    const loadMorePromise = t.client.call("taskFeed.loadMore", {
      workspace: "wsp_a",
      cursor: "cur_p2",
    });
    await t.time.pass(100);
    await loadMorePromise;

    expect(allFeed.get().entries.map((e) => e.id)).toEqual(["tfe_1", "tfe_2", "tfe_3"]);
    expect(allFeed.get().hasMore).toBe(false);
    expect(allFeed.get().nextCursor).toBeUndefined();
  });

  it("deduplicates entries by conversationId across loadMore and refresh when a task bubbles to page 1", async () => {
    const t = setup();
    let refreshedFirstPage = false;
    t.api.on("GET", feedA, (req) => {
      const url = new URL(`https://api.comma.test${req.path}`);
      const cursor = url.searchParams.get("cursor");
      if (cursor === "cur_p2") {
        return json(200, {
          entries: [
            // Same conversation_id as tfe_1_run2 on page 1, with an older cluster entry id.
            rawEntry("tfe_1_run1", {
              conversation_id: "cnv_loop_1",
              cluster_key: "run:1",
            }),
            rawEntry("tfe_3_run1", {
              conversation_id: "cnv_loop_3",
              cluster_key: "run:1",
            }),
          ],
          has_more: false,
          next_cursor: null,
        });
      }
      if (refreshedFirstPage) {
        return json(200, {
          entries: [
            // cnv_loop_3 bubbled up to page 1 with a newer entry id while still present on page 2.
            rawEntry("tfe_3_run2", {
              conversation_id: "cnv_loop_3",
              cluster_key: "run:2",
            }),
            rawEntry("tfe_1_run2", {
              conversation_id: "cnv_loop_1",
              cluster_key: "run:2",
            }),
          ],
          has_more: true,
          next_cursor: "cur_p2",
        });
      }
      return json(200, {
        entries: [
          rawEntry("tfe_1_run2", {
            conversation_id: "cnv_loop_1",
            cluster_key: "run:2",
          }),
          rawEntry("tfe_2_run1", {
            conversation_id: "cnv_loop_2",
            cluster_key: "run:1",
          }),
        ],
        has_more: true,
        next_cursor: "cur_p2",
      });
    });

    t.core.observeSession(signedIn());
    const feed = t.watch({ topic: "taskFeed", workspace: "wsp_a" });
    await t.time.pass(100);
    expect(feed.get().entries.map((e) => e.id)).toEqual(["tfe_1_run2", "tfe_2_run1"]);

    // Page 2 contains an older cluster for cnv_loop_1; appended() must drop it by conversationId.
    const loadMorePromise = t.client.call("taskFeed.loadMore", {
      workspace: "wsp_a",
      cursor: "cur_p2",
    });
    await t.time.pass(100);
    await loadMorePromise;
    expect(feed.get().entries.map((e) => e.id)).toEqual([
      "tfe_1_run2",
      "tfe_2_run1",
      "tfe_3_run1",
    ]);

    // Refresh brings a newer cluster for cnv_loop_3 to page 1; refreshed() must drop the stale page 2 copy.
    refreshedFirstPage = true;
    const refreshPromise = t.client.call("taskFeed.refresh", { workspace: "wsp_a" });
    await t.time.pass(100);
    await refreshPromise;
    expect(feed.get().entries.map((e) => e.id)).toEqual(["tfe_3_run2", "tfe_1_run2"]);
    expect(feed.get().entries.map((e) => e.conversationId)).toEqual([
      "cnv_loop_3",
      "cnv_loop_1",
    ]);
  });

  it("advances lastSeenAt monotonically via taskFeed.markSeen and persists in SQLite", async () => {
    const host = new FakeHost();
    host.api.on("GET", feedA, {
      entries: [rawEntry("tfe_1"), rawEntry("tfe_2")],
      has_more: false,
      next_cursor: null,
    });
    const first = setup(host);
    first.core.observeSession(signedIn());
    const feed = first.watch({ topic: "taskFeed", workspace: "wsp_a" });
    await first.time.pass(100);
    expect(feed.get().lastSeenAt).toBeUndefined();

    const p1 = first.client.call("taskFeed.markSeen", {
      workspace: "wsp_a",
      at: 1_795_195_000_000,
    });
    await first.time.pass(50);
    expect(await p1).toEqual({ lastSeenAt: 1_795_195_000_000 });
    expect(feed.get().lastSeenAt).toBe(1_795_195_000_000);

    // Older timestamp does not move watermark backwards or rewrite SQLite.
    const p2 = first.client.call("taskFeed.markSeen", {
      workspace: "wsp_a",
      at: 1_795_194_000_000,
    });
    await first.time.pass(50);
    expect(await p2).toEqual({ lastSeenAt: 1_795_195_000_000 });
    expect(feed.get().lastSeenAt).toBe(1_795_195_000_000);

    // Newer timestamp advances watermark.
    const p3 = first.client.call("taskFeed.markSeen", {
      workspace: "wsp_a",
      at: 1_795_196_000_000,
    });
    await first.time.pass(50);
    expect(await p3).toEqual({ lastSeenAt: 1_795_196_000_000 });
    expect(feed.get().lastSeenAt).toBe(1_795_196_000_000);
    first.core.close();

    // Persisted across restart in SQLite doc("task-feed-seen:wsp_a").
    const second = setup(host);
    second.core.observeSession(signedIn());
    const restored = second.watch({ topic: "taskFeed", workspace: "wsp_a" });
    await second.time.pass(100);
    expect(restored.get().lastSeenAt).toBe(1_795_196_000_000);
  });

  it("refreshes silently on group SSE invalidation without polling and keeps unchanged entry references", async () => {
    const t = setup();
    let entries = [rawEntry("tfe_3"), rawEntry("tfe_2"), rawEntry("tfe_1")];
    t.api.on("GET", feedA, () =>
      json(200, { entries, has_more: false, next_cursor: null })
    );
    t.core.observeSession(signedIn());
    const topic: Topic = { topic: "taskFeed", workspace: "wsp_a", attention: "" };
    const feed = t.watch(topic);
    await t.time.pass(100);
    expect(t.api.seen("GET", feedA)).toHaveLength(1);

    // Verify no polling over 60 seconds.
    await t.time.pass(60_000, 1_000);
    expect(t.api.seen("GET", feedA)).toHaveLength(1);

    // Capture the core's computed snapshot entry references before refresh.
    const before = t.core.kernel.store.value(topic);
    const beforeEntries =
      before && "ok" in before ? (before.ok as TaskFeedSnapshot).entries : [];
    expect(beforeEntries).toHaveLength(3);

    // Prepend a new entry and emit an SSE invalidation event.
    entries = [
      rawEntry("tfe_4"),
      rawEntry("tfe_3"),
      rawEntry("tfe_2"),
      rawEntry("tfe_1"),
    ];
    const stream = t.api.open(eventsA)!;
    expect(stream).toBeDefined();
    stream.event(invalidated("v2"));
    await t.time.pass(100);

    expect(t.api.seen("GET", feedA)).toHaveLength(2);
    expect(feed.get().entries.map((e) => e.id)).toEqual([
      "tfe_4",
      "tfe_3",
      "tfe_2",
      "tfe_1",
    ]);

    // All 3 unchanged entries keep exact object references via LastMade + TOPIC_SPECS.taskFeed.
    const after = t.core.kernel.store.value(topic);
    const afterEntries =
      after && "ok" in after ? (after.ok as TaskFeedSnapshot).entries : [];
    expect(afterEntries[1]).toBe(beforeEntries[0]);
    expect(afterEntries[2]).toBe(beforeEntries[1]);
    expect(afterEntries[3]).toBe(beforeEntries[2]);

    // Duplicate version does not trigger another read; resync does.
    stream.event(invalidated("v2"));
    await t.time.pass(100);
    expect(t.api.seen("GET", feedA)).toHaveLength(2);

    stream.event(resyncRequired("v2"));
    await t.time.pass(100);
    expect(t.api.seen("GET", feedA)).toHaveLength(3);

    // Unsubscribing closes the SSE stream once the topic's grace period expires.
    feed.unsub();
    await t.time.pass(61_000, 1_000);
    expect(stream.closed).toBe(true);
  });

  it("follows focused workspace when workspace param is omitted", async () => {
    const t = setup();
    t.api.on("GET", feedA, { entries: [rawEntry("tfe_a")], has_more: false });
    t.api.on("GET", feedB, {
      entries: [rawEntry("tfe_b", { group_id: "grp_b" })],
      has_more: false,
    });
    t.core.observeSession(signedIn());
    const feed = t.watch({ topic: "taskFeed" });
    await t.time.pass(100);
    expect(feed.get()).toMatchObject({
      workspaceId: "wsp_a",
      groupId: "grp_a",
      entries: [{ id: "tfe_a" }],
    });

    const focusPromise = t.client.call("tasks.focus", { workspace: "wsp_b" });
    await t.time.pass(100);
    await focusPromise;
    expect(feed.get()).toMatchObject({
      workspaceId: "wsp_b",
      groupId: "grp_b",
      entries: [{ id: "tfe_b" }],
    });
  });

  it("assembles multi-page view=activity messages into ChatTaskActivity via taskFeed.activity", async () => {
    const t = setup();
    const messagesPath = "/v1/comma/groups/grp_a/conversations/cnv_42/messages";
    t.api.on("GET", messagesPath, (req) => {
      const url = new URL(`https://api.comma.test${req.path}`);
      expect(url.searchParams.get("view")).toBe("activity");
      const before = url.searchParams.get("before");
      if (before === "4") {
        // Older page: brief + milestone 1 + agent result 1
        return json(200, {
          data: [
            {
              message_id: "msg_1",
              seq: 1,
              kind: "message",
              actor_type: "user",
              client_request_id: "delegate-task-cnv_42",
              content: [{ type: "text", text: "Research competitor pricing" }],
              created_at: 1_795_194_000_000,
            },
            {
              message_id: "msg_2",
              seq: 2,
              kind: "message",
              actor_type: "agent",
              agent_id: "agt_1",
              content: [{ type: "milestone", title: "Collected pricing pages" }],
              created_at: 1_795_194_100_000,
            },
            {
              message_id: "msg_3",
              seq: 3,
              kind: "message",
              actor_type: "agent",
              agent_id: "agt_1",
              content: [{ type: "text", text: "Initial pricing table ready" }],
              created_at: 1_795_194_200_000,
            },
          ],
          covered: { first: 1, last: 3 },
          bounds: { first: 1, last: 6 },
          has_older: false,
        });
      }
      // First (newest) page: follow-up + milestone 2 + agent result 2
      return json(200, {
        data: [
          {
            message_id: "msg_4",
            seq: 4,
            kind: "message",
            actor_type: "user",
            content: [{ type: "text", text: "Add enterprise tier" }],
            created_at: 1_795_194_500_000,
          },
          {
            message_id: "msg_5",
            seq: 5,
            kind: "message",
            actor_type: "agent",
            agent_id: "agt_1",
            content: [{ type: "milestone", title: "Added enterprise comparison" }],
            created_at: 1_795_194_600_000,
          },
          {
            message_id: "msg_6",
            seq: 6,
            kind: "message",
            actor_type: "agent",
            agent_id: "agt_1",
            content: [{ type: "text", text: "Enterprise tier added" }],
            created_at: 1_795_194_700_000,
          },
        ],
        covered: { first: 4, last: 6 },
        bounds: { first: 1, last: 6 },
        has_older: true,
      });
    });

    t.core.observeSession(signedIn());
    await t.time.pass(50);

    const callPromise = t.client.call("taskFeed.activity", {
      groupId: "grp_a",
      conversationId: "cnv_42",
    });
    await t.time.pass(100);
    const activity = (await callPromise) as ChatTaskActivity | null;

    expect(t.api.seen("GET", messagesPath)).toHaveLength(2);
    expect(activity).not.toBeNull();
    expect(activity!.groups).toHaveLength(2);
    expect(activity!.groups[0]).toMatchObject({
      request: { kind: "brief", messageId: "msg_1" },
      entries: [
        {
          title: "Collected pricing pages",
          at: 1_795_194_100_000,
          messageId: "msg_3",
        },
      ],
    });
    expect(activity!.groups[1]).toMatchObject({
      request: {
        kind: "follow_up",
        messageId: "msg_4",
        text: "Add enterprise tier",
      },
      entries: [
        {
          title: "Added enterprise comparison",
          at: 1_795_194_600_000,
          messageId: "msg_6",
        },
      ],
    });
  });

  it("returns null from taskFeed.activity when the task has no milestones", async () => {
    const t = setup();
    t.api.on("GET", "/v1/comma/groups/grp_a/conversations/cnv_empty/messages", {
      data: [
        {
          message_id: "msg_1",
          seq: 1,
          kind: "message",
          actor_type: "user",
          content: [{ type: "text", text: "Hello" }],
          created_at: 1_795_194_000_000,
        },
      ],
      covered: { first: 1, last: 1 },
      has_older: false,
    });
    t.core.observeSession(signedIn());
    await t.time.pass(50);

    const callPromise = t.client.call("taskFeed.activity", {
      groupId: "grp_a",
      conversationId: "cnv_empty",
    });
    await t.time.pass(100);
    expect(await callPromise).toBeNull();
  });

  it("surfaces error state immediately and stops retrying when default workspace task-feed returns 404", async () => {
    const t = setup();
    t.api.on("GET", feedA, () => json(404, { error: "not_found" }));

    const feed = t.watch({ topic: "taskFeed", workspace: "", attention: "all" });
    t.core.observeSession(signedIn());
    await t.time.pass(200);

    expect(feed.get()).toMatchObject({
      workspaceId: "wsp_a",
      source: "error",
      loaded: false,
      errorCode: "unknown",
      entries: [],
    });
    const callsBefore = t.api.seen("GET", feedA).length;
    expect(callsBefore).toBe(1);

    await t.time.pass(60_000);
    expect(t.api.seen("GET", feedA)).toHaveLength(callsBefore);
  });

  it("reuses a fresh taskFeed.refresh within 15s on subscribe without a second GET and closes SSE within 6s after unsubscribe", async () => {
    const t = setup();
    t.api.on("GET", feedA, {
      entries: [rawEntry("tfe_warm_1")],
      has_more: false,
      next_cursor: null,
    });
    t.core.observeSession(signedIn());
    await t.time.pass(50);

    await t.client.call("taskFeed.refresh", { workspace: "wsp_a", attention: false });
    await t.time.pass(50);
    expect(t.api.seen("GET", feedA)).toHaveLength(1);
    expect(t.api.open(eventsA)).toBeUndefined();

    // Subscribing within 15s opens the SSE stream without issuing a second GET.
    const feed = t.watch({ topic: "taskFeed", workspace: "wsp_a", attention: "" });
    await t.time.pass(100);
    expect(feed.get().entries.map((e) => e.id)).toEqual(["tfe_warm_1"]);
    expect(t.api.seen("GET", feedA)).toHaveLength(1);
    const stream = t.api.open(eventsA);
    expect(stream).toBeDefined();

    // Unsubscribing evicts the topic and closes the SSE stream within 6s (evictAfterMs: 5_000).
    feed.unsub();
    await t.time.pass(6_000, 1_000);
    expect(stream!.closed).toBe(true);
  });
});
