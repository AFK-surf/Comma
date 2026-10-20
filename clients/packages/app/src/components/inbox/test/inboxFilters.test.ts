import type { ProductInboxItem } from "@comma/core-client";
import { describe, expect, it } from "vitest";
import {
  applyInboxFilters,
  countInboxItemsByPlatform,
  countInboxTasksBySchedule,
  countInboxTasksByStatus,
  isInboxFiltered,
  unfilteredInbox,
} from "../filters/inboxFilters";

const item = (over: Partial<ProductInboxItem>): ProductInboxItem => ({
  id: "w1:c1",
  kind: "user_chat",
  source: "salix.conversation",
  workspaceId: "w1",
  workspaceName: "Acme",
  groupId: "grp_test",
  conversationId: "c1",
  title: "Kickoff sync",
  status: "open",
  updatedAt: 1_000,
  ...over,
});

const filter = (keys: string[]) => ({
  ...unfilteredInbox(),
  schedules: new Set(keys),
});

describe("inboxFilters", () => {
  const chat = item({});
  const doneTask = item({
    conversationId: "c2",
    id: "w1:c2",
    kind: "agent_task",
    status: "completed",
  });
  const runningTask = item({
    conversationId: "c3",
    id: "w1:c3",
    kind: "agent_task",
    status: "running",
  });
  const items = [chat, doneTask, runningTask];

  it("starts unfiltered and lists everything", () => {
    const filters = unfilteredInbox();
    expect(isInboxFiltered(filters)).toBe(false);
    expect(applyInboxFilters(items, filters)).toEqual(items);
  });

  it("applies the task status filter to tasks only", () => {
    const filters = { statuses: new Set(["in_progress" as const]) };
    expect(isInboxFiltered(filters)).toBe(true);
    expect(applyInboxFilters(items, filters)).toEqual([chat, runningTask]);
  });

  it("counts tasks per status bucket, ignoring chats", () => {
    expect(countInboxTasksByStatus(items)).toMatchObject({
      needs_review: 0,
      done: 1,
      in_progress: 1,
    });
  });

  it("filters each trigger type, preserves chats, and keeps unknown cadences separate", () => {
    const scheduled = {
      ...runningTask,
      id: "w1:scheduled",
      loop: {
        state: "ended" as const,
        startedAt: 1,
        wakeCount: 4,
        cadence: { everyMinutes: 60 },
      },
    };
    const event = {
      ...runningTask,
      id: "w1:event",
      loop: {
        state: "paused" as const,
        startedAt: 1,
        wakeCount: 2,
        cadence: { events: "new comments" },
      },
    };
    const unknown = {
      ...runningTask,
      id: "w1:unknown",
      loop: { state: "pending" as const, startedAt: 1, wakeCount: 0 },
    };
    const mixed = [chat, doneTask, scheduled, event, unknown];
    expect(countInboxTasksBySchedule(mixed)).toEqual({
      scheduled: 1,
      event_triggered: 1,
      unknown: 1,
      not_scheduled: 1,
    });
    expect(applyInboxFilters(mixed, filter(["scheduled"]))).toEqual([chat, scheduled]);
    expect(applyInboxFilters(mixed, filter(["event_triggered"]))).toEqual([
      chat,
      event,
    ]);
    expect(applyInboxFilters(mixed, filter(["scheduled", "event_triggered"]))).toEqual([
      chat,
      scheduled,
      event,
    ]);
    expect(applyInboxFilters(mixed, filter(["not_scheduled"]))).toEqual([
      chat,
      doneTask,
    ]);
    expect(applyInboxFilters(mixed, filter(["unknown"]))).toEqual([chat, unknown]);
    expect(
      applyInboxFilters(mixed, {
        ...filter(["scheduled"]),
        statuses: new Set(["done" as const]),
      })
    ).toEqual([chat]);
  });

  it("keeps unknown and missing origins until a platform is selected", () => {
    const slack = item({ origin: "slack" });
    const unknown = item({ id: "w1:future", origin: "future-provider" });
    const mixedItems = [slack, chat, unknown];

    expect(applyInboxFilters(mixedItems, unfilteredInbox())).toEqual(mixedItems);
    const filters = { ...unfilteredInbox(), platforms: new Set(["slack"]) };
    expect(isInboxFiltered(filters)).toBe(true);
    expect(applyInboxFilters(mixedItems, filters)).toEqual([slack]);
  });

  it("combines platforms with task statuses while allowing matching chats", () => {
    const slackChat = item({ origin: "slack" });
    const slackDone = { ...doneTask, origin: "slack" };
    const slackRunning = { ...runningTask, origin: "slack" };
    const commaRunning = { ...runningTask, id: "w1:comma", origin: "comma" };

    expect(
      applyInboxFilters([slackChat, slackDone, slackRunning, commaRunning], {
        platforms: new Set(["slack"]),
        statuses: new Set(["in_progress"]),
      })
    ).toEqual([slackChat, slackRunning]);
  });

  it("supports multiple selected platforms and an explicitly empty selection", () => {
    const slack = item({ origin: "slack" });
    const comma = item({ id: "w1:comma", origin: "comma" });
    const telegram = item({ id: "w1:telegram", origin: "telegram" });
    const mixedItems = [slack, comma, telegram, chat];

    expect(
      applyInboxFilters(mixedItems, {
        ...unfilteredInbox(),
        platforms: new Set(["slack", "comma"]),
      })
    ).toEqual([slack, comma]);
    const empty = { ...unfilteredInbox(), platforms: new Set<string>() };
    expect(isInboxFiltered(empty)).toBe(true);
    expect(applyInboxFilters(mixedItems, empty)).toEqual([]);
  });

  it("groups absent and unrecognized origins under the Unspecified selection", () => {
    const slack = item({ origin: "slack" });
    const unknown = item({ id: "w1:future", origin: "future-provider" });

    expect(
      applyInboxFilters([slack, chat, unknown], {
        ...unfilteredInbox(),
        platforms: new Set(["unspecified"]),
      })
    ).toEqual([chat, unknown]);
  });

  it("counts known and unspecified origins across chats and tasks", () => {
    expect(
      countInboxItemsByPlatform([
        item({ origin: "slack" }),
        { ...doneTask, origin: "slack" },
        { ...runningTask, origin: "comma" },
        item({ id: "w1:future", origin: "future-provider" }),
        chat,
      ])
    ).toEqual(
      new Map([
        ["slack", 2],
        ["comma", 1],
        ["unspecified", 2],
      ])
    );
    expect(countInboxItemsByPlatform([]).size).toBe(0);
  });
});
