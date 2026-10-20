import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import type { ComponentProps } from "react";
import { initializeCommaI18n, type CommaLocale } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { fireEvent, render, screen, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { ProductInboxItem, ProductInboxListResult } from "@comma/core-client";
import { Toaster, toast } from "@comma/ui/components/toast";
import { InboxView } from "../components/inbox/InboxView";
import type { MarkKind } from "@comma/core/contract";
import { flush } from "@comma/test-utils/fake-clock";
import { createScriptedCore } from "@comma/test-utils/scripted-core";

const item = (over: Partial<ProductInboxItem> = {}): ProductInboxItem => ({
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

/**
 * A core that keeps the reader's deleted, unread and seen marks as the UI asks: each `marks.mark` / `marks.unmark`
 * it sends changes the `marks` the core then says. (How the core itself keeps marks is core/test/marks.test.ts.)
 */
function marksCore() {
  const kept: Partial<Record<MarkKind, Record<string, number>>> = {};
  const scripted = createScriptedCore({
    values: (topic) =>
      topic.topic === "marks"
        ? { marks: kept[topic.kind as MarkKind] ?? {} }
        : undefined,
    calls: (name, params) => {
      const {
        kind,
        entries = [],
        ids = [],
      } = params as { kind: MarkKind; entries?: [string, number][]; ids?: string[] };
      const next = { ...kept[kind] };
      if (name === "marks.mark") for (const [id, at] of entries) next[id] = at;
      if (name === "marks.unmark") for (const id of ids) delete next[id];
      kept[kind] = next;
      scripted.changed("marks");
      return null;
    },
  });
  return scripted;
}

// One core per test, across its renders.
let core = marksCore();
let user = userEvent.setup();
/** Clicks like a pointer, then lets what the click started finish. */
const click = async (element: Element) => {
  await user.click(element);
  await flush();
};
const press = async (keys: string) => {
  await user.keyboard(keys);
  await flush();
};

const eventLoop = (events: string) => ({
  state: "active" as const,
  startedAt: 1,
  wakeCount: 0,
  cadence: { events },
});

describe("InboxView", () => {
  beforeEach(() => {
    user = userEvent.setup({ advanceTimers: vi.advanceTimersByTime });
    core = marksCore();
  });
  afterEach(() => {
    toast.dismissAll();
    initializeCommaI18n(["en"]);
    window.localStorage.clear();
  });

  it("renders loading when the host has not projected a list", async () => {
    renderInbox(null);
    await flush();

    expect(screen.getByRole("status", { name: "Loading…" })).toBeInTheDocument();
    expect(screen.queryByTestId("inbox-source")).toBeNull();
    expect(screen.queryByTestId("inbox-list")).toBeNull();
  });

  it("renders synced conversation titles in the compact rail", async () => {
    renderInbox({
      source: "live-sync",
      lastSyncedAt: 500,
      items: [item(), item({ id: "w2:c9", workspaceName: "Globex", title: "Ship it" })],
    });
    await flush();

    const rows = screen.getAllByTestId("inbox-item");
    expect(rows).toHaveLength(2);
    expect(screen.getByTestId("inbox-conversation-rail")).toHaveStyle({
      flexBasis: "320px",
      width: "320px",
    });
    expect(within(rows[0]!).getByText("Kickoff sync")).toBeInTheDocument();
    expect(rows[0]).toHaveAccessibleName("Kickoff sync");
    expect(within(rows[1]!).getByText("Ship it")).toBeInTheDocument();
  });

  it("visibly and accessibly qualifies stale and unknown conversation rows", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ freshness: "stale", id: "w1:stale", title: "Stale task" }),
        item({ freshness: "unknown", id: "w1:unknown", title: "Unknown task" }),
      ],
    });
    await flush();

    const staleRow = screen.getByRole("link", { name: /Stale task.*Stale/i });
    const unknownRow = screen.getByRole("link", {
      name: /Unknown task.*Status unknown/i,
    });

    expect(staleRow).toHaveAttribute("data-freshness", "stale");
    expect(staleRow).toHaveTextContent("Stale");
    expect(unknownRow).toHaveAttribute("data-freshness", "unknown");
    expect(unknownRow).toHaveTextContent("Status unknown");
  });

  it("shows cached rows without a premature stale warning", async () => {
    renderInbox({
      source: "cache",
      items: [
        item({ freshness: "fresh", title: "Cached task" }),
        item({ freshness: "stale", id: "w1:old", title: "Earlier result" }),
      ],
    });
    await flush();

    const row = screen.getByRole("link", { name: "Cached task" });
    expect(row).toHaveAttribute("data-freshness", "fresh");
    expect(row).not.toHaveTextContent("Stale");
    expect(
      screen.getByRole("link", { name: "Earlier result, Stale" })
    ).toHaveTextContent("Stale");
  });

  it("reports sync failure once while keeping cached rows readable", async () => {
    renderInbox(
      {
        source: "error",
        errorCode: "network_unavailable",
        items: [item({ freshness: "fresh", title: "Cached during error" })],
      },
      {},
      undefined,
      { toasts: true }
    );
    await flush();

    const row = screen.getByRole("link", {
      name: "Cached during error",
    });
    expect(row).toHaveAttribute("data-freshness", "fresh");
    expect(row).not.toHaveTextContent("Stale");
    expect(screen.getByTestId("inbox-banner")).toHaveTextContent("Sync failed");
  });

  it("formats Comma epoch-second timestamps as current relative time", async () => {
    const oneMinuteAgoInSeconds = Math.floor((Date.now() - 70_000) / 1000);

    renderInbox({
      source: "live-sync",
      lastSyncedAt: oneMinuteAgoInSeconds,
      items: [item({ updatedAt: oneMinuteAgoInSeconds })],
    });
    await flush();

    expect(screen.getByTestId("inbox-source")).toHaveTextContent("1m");
    expect(screen.getByRole("link", { name: /Kickoff sync/ })).toHaveTextContent("1m");
  });

  it("links each conversation row to the conversation detail route", async () => {
    const { router } = renderInbox({ source: "live-sync", items: [item()] });
    await flush();
    const row = screen.getByRole("link", { name: /Kickoff sync/ });

    expect(row).toHaveAttribute("href", "/inbox/w1/grp_test/c1");
    fireEvent.click(row);
    await flush();
    expect(router.state.location.pathname).toBe("/inbox/w1/grp_test/c1");
  });

  it("shows an offline banner but still lists items on cache + error", async () => {
    renderInbox(
      {
        source: "cache",
        errorCode: "network_unavailable",
        items: [item()],
      },
      {},
      undefined,
      { toasts: true }
    );
    await flush();

    const banner = screen.getByTestId("inbox-banner");
    expect(banner).toHaveTextContent("Showing local cache");
    expect(banner).toHaveTextContent(
      "Comma could not reach the ProductInbox authority."
    );
    expect(screen.getByTestId("inbox-list")).toBeInTheDocument();
  });

  it("surfaces the error on the error state", async () => {
    renderInbox(
      {
        source: "error",
        errorCode: "utility_unavailable",
        items: [],
      },
      {},
      undefined,
      { toasts: true }
    );
    await flush();

    expect(screen.getByTestId("inbox-banner")).toHaveTextContent("Sync failed");
    expect(screen.getByTestId("inbox-banner")).toHaveTextContent(
      "The Main ProductInbox scheduler is unavailable."
    );
  });

  it("shows an empty state when synced with no conversations", async () => {
    renderInbox({ source: "live-sync", lastSyncedAt: 1, items: [] });
    await flush();

    expect(
      within(screen.getByTestId("inbox-empty")).getByText("No notifications")
    ).toBeInTheDocument();
  });

  it("filters the rail by task status and reports what the filters hide", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ kind: "user_chat", title: "Kickoff sync" }),
        item({
          id: "w1:c2",
          conversationId: "c2",
          kind: "agent_task",
          status: "completed",
          title: "Nightly run",
        }),
        item({
          id: "w1:c3",
          conversationId: "c3",
          kind: "agent_task",
          status: "running",
          title: "Deploy",
        }),
      ],
    });
    await flush();

    expect(screen.getAllByTestId("inbox-item")).toHaveLength(3);
    expect(screen.queryByTestId("inbox-filter-footer")).toBeNull();

    // The first level lists filter dimensions; each dimension's options live
    // one level deeper, as in the Tasks filter.
    // A pointer click, not fireEvent: React Aria's submenu trigger opens on the
    // full pointer sequence.
    await click(screen.getByTestId("inbox-filter-trigger"));
    expect(screen.queryByTestId("inbox-status-filter")).toBeNull();
    await click(screen.getByRole("menuitem", { name: /Task status/ }));

    // Queried from `screen`, not through a captured panel node: React Aria
    // remounts the popover subtree when it repositions, which detaches any
    // element reference taken before the options render.
    expect(screen.getByTestId("inbox-status-filter")).toBeInTheDocument();
    const done = screen.getByRole("menuitemcheckbox", { name: /Done/ });
    // The count beside a status is the Inbox's notification count, not the
    // Tasks board's task count.
    expect(done).toHaveTextContent("1 notification");
    await click(done);

    expect(screen.getAllByTestId("inbox-item")).toHaveLength(2);
    expect(screen.queryByText("Nightly run")).toBeNull();
    expect(screen.getByTestId("inbox-filter-footer")).toHaveTextContent(
      "1 notification hidden by filters"
    );

    // The menu is modal, so close it before reaching the footer under it.
    await press("{Escape}");
    expect(screen.queryByRole("menuitemcheckbox", { name: /Done/ })).toBeNull();
    if (screen.queryByRole("menuitem", { name: /Task status/ })) {
      await press("{Escape}");
    }
    expect(screen.queryByRole("menuitem", { name: /Task status/ })).toBeNull();
    await click(screen.getByRole("button", { name: /Clear Filters/ }));

    expect(screen.getAllByTestId("inbox-item")).toHaveLength(3);
    expect(screen.queryByTestId("inbox-filter-footer")).toBeNull();
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "false"
    );
  });

  it("searches localized platforms without losing other selections and restores all origins", async () => {
    renderInbox(
      {
        source: "live-sync",
        items: [
          item({ origin: "slack", title: "Slack chat" }),
          item({ id: "w1:feishu", origin: "feishu", title: "Feishu chat" }),
          item({ id: "w1:comma", origin: "comma", title: "Comma chat" }),
          item({ id: "w1:legacy", title: "Legacy chat" }),
          item({ id: "w1:future", origin: "future-provider", title: "Future chat" }),
        ],
      },
      {},
      "zh-CN"
    );
    await flush();

    expect(screen.getAllByTestId("inbox-item")).toHaveLength(5);
    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "平台" }));
    expect(screen.getByRole("menuitemcheckbox", { name: /飞书/ })).toHaveTextContent(
      "1 条通知"
    );
    expect(screen.getByRole("menuitemcheckbox", { name: /未指定/ })).toHaveTextContent(
      "2 条通知"
    );

    await click(screen.getByRole("menuitemcheckbox", { name: /未指定/ }));
    await click(screen.getByRole("menuitemcheckbox", { name: /Slack/ }));
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(2);
    expect(screen.queryByText("Legacy chat")).toBeNull();
    expect(screen.queryByText("Future chat")).toBeNull();

    await user.type(screen.getByRole("textbox", { name: "筛选…" }), "飞书");
    await flush();
    expect(screen.queryByRole("menuitemcheckbox", { name: /Comma/ })).toBeNull();
    await click(screen.getByRole("menuitemcheckbox", { name: /飞书/ }));
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(1);
    expect(screen.getByText("Comma chat")).toBeInTheDocument();

    await user.clear(screen.getByRole("textbox", { name: "筛选…" }));
    await flush();
    expect(screen.getByRole("menuitemcheckbox", { name: /Comma/ })).toHaveAttribute(
      "aria-checked",
      "true"
    );
    expect(screen.getByRole("menuitemcheckbox", { name: /Slack/ })).toHaveAttribute(
      "aria-checked",
      "false"
    );
    await click(screen.getByRole("menuitemcheckbox", { name: /Slack/ }));
    await click(screen.getByRole("menuitemcheckbox", { name: /飞书/ }));
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(3);
    await click(screen.getByRole("menuitemcheckbox", { name: /未指定/ }));

    expect(screen.getAllByTestId("inbox-item")).toHaveLength(5);
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "false"
    );
    expect(screen.queryByTestId("inbox-filter-footer")).toBeNull();
  });

  it("combines platform and status filters and clears both from the footer", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ origin: "slack", title: "Slack chat" }),
        item({ id: "w1:comma", origin: "comma", title: "Comma chat" }),
        item({
          id: "w1:done",
          kind: "agent_task",
          origin: "slack",
          status: "completed",
          title: "Slack done",
        }),
        item({
          id: "w1:running",
          kind: "agent_task",
          origin: "slack",
          status: "running",
          title: "Slack running",
        }),
      ],
    });
    await flush();

    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "Task status" }));
    await click(screen.getByRole("menuitemcheckbox", { name: /Done/ }));
    await closeInboxFilterMenu();
    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "Platform" }));

    // Counts describe all undeleted notifications, including the task hidden by status.
    expect(screen.getByRole("menuitemcheckbox", { name: /Slack/ })).toHaveTextContent(
      "3 notifications"
    );
    await click(screen.getByRole("menuitemcheckbox", { name: /Comma/ }));
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(2);
    expect(screen.getByText("Slack chat")).toBeInTheDocument();
    expect(screen.getByText("Slack running")).toBeInTheDocument();
    expect(screen.getByTestId("inbox-filter-footer")).toHaveTextContent(
      "2 notifications hidden by filters"
    );
    await closeInboxFilterMenu();
    await click(screen.getByRole("button", { name: "Clear Filters" }));
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(4);
    expect(screen.queryByTestId("inbox-filter-footer")).toBeNull();
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "false"
    );
  });

  it("keeps selected platforms at zero after deletion and excludes archived notifications", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ origin: "slack", title: "Read Slack chat" }),
        item({
          id: "w1:archived",
          origin: "slack",
          status: "archived",
          title: "Archived Slack chat",
        }),
        item({
          id: "w1:comma",
          kind: "agent_task",
          origin: "comma",
          status: "needs_review",
          title: "Unread Comma task",
        }),
        item({ id: "w1:telegram", origin: "telegram", title: "Telegram chat" }),
      ],
    });
    await flush();

    expect(screen.getAllByTestId("inbox-item")).toHaveLength(3);
    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "Platform" }));
    expect(screen.getByRole("menuitemcheckbox", { name: /Slack/ })).toHaveTextContent(
      "1 notification"
    );
    await click(screen.getByRole("menuitemcheckbox", { name: /Telegram/ }));
    await closeInboxFilterMenu();
    await click(screen.getByTestId("inbox-actions-trigger"));
    await click(screen.getByRole("menuitem", { name: "Delete all read" }));
    expect(core.sentTo("marks.mark")).toEqual([
      { kind: "inboxDeleted", entries: [["w1:c1", 1_000]] },
    ]);
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(1);
    expect(screen.getByText("Unread Comma task")).toBeInTheDocument();

    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "Platform" }));
    const slack = screen.getByRole("menuitemcheckbox", { name: /Slack/ });
    expect(slack).toHaveAttribute("aria-checked", "true");
    expect(slack).toHaveTextContent("0 notifications");
    const telegram = screen.getByRole("menuitemcheckbox", { name: /Telegram/ });
    expect(telegram).toHaveAttribute("aria-checked", "false");
    expect(telegram).toHaveTextContent("1 notification");
    await closeInboxFilterMenu();
    await click(screen.getByRole("button", { name: "Clear Filters" }));
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(2);
    expect(screen.getByText("Telegram chat")).toBeInTheDocument();
    expect(screen.queryByText("Read Slack chat")).toBeNull();
    expect(screen.queryByText("Archived Slack chat")).toBeNull();
  });

  it("filters notifications by their exact event rule and clears it without hiding chats", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ title: "Team chat" }),
        item({
          id: "w1:pr1",
          kind: "agent_task",
          status: "active",
          title: "Watch first PR",
          loop: eventLoop("PR #1 updated"),
        }),
        item({
          id: "w1:pr2",
          kind: "agent_task",
          status: "active",
          title: "Watch second PR",
          loop: eventLoop("PR #2 updated"),
        }),
        item({
          id: "w1:ended",
          kind: "agent_task",
          status: "completed",
          title: "Ended watch",
          loop: { ...eventLoop("PR #1 updated"), state: "ended" },
        }),
      ],
    });
    await flush();
    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "Trigger rule" }));
    const panel = screen.getByRole("dialog", { name: "Trigger rule" });
    await click(within(panel).getByRole("menuitemradio", { name: /PR #1 updated/ }));
    await closeInboxFilterMenu();
    expect(screen.getByText("Team chat")).toBeInTheDocument();
    expect(screen.getByText("Watch first PR")).toBeInTheDocument();
    expect(screen.queryByText("Watch second PR")).toBeNull();
    expect(screen.queryByText("Ended watch")).toBeNull();
    await click(screen.getByRole("button", { name: "Clear Filters" }));
    expect(screen.getByText("Watch second PR")).toBeInTheDocument();
    expect(screen.getByText("Ended watch")).toBeInTheDocument();
  });

  it("keeps a selected rule checked at zero after its last notification is deleted", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ title: "Team chat" }),
        item({
          id: "w1:pr1",
          kind: "agent_task",
          status: "active",
          title: "Watch first PR",
          loop: eventLoop("PR #1 updated"),
        }),
        item({
          id: "w1:pr2",
          kind: "agent_task",
          status: "active",
          title: "Watch second PR",
          loop: eventLoop("PR #2 updated"),
        }),
      ],
    });
    await flush();
    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "Trigger rule" }));
    await click(
      within(screen.getByRole("dialog", { name: "Trigger rule" })).getByRole(
        "menuitemradio",
        { name: /PR #1 updated/ }
      )
    );
    await closeInboxFilterMenu();
    const row = screen
      .getByText("Watch first PR")
      .closest("[data-testid='inbox-item']");
    await openInboxItemMenu(row as HTMLElement);
    await click(screen.getByRole("menuitem", { name: "Delete notification" }));
    expect(screen.getByText("Team chat")).toBeInTheDocument();
    expect(screen.queryByText("Watch first PR")).toBeNull();
    expect(screen.queryByText("Watch second PR")).toBeNull();

    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "Trigger rule" }));
    const panel = screen.getByRole("dialog", { name: "Trigger rule" });
    const selected = within(panel).getByRole("menuitemradio", {
      name: /PR #1 updated/,
    });
    expect(selected).toHaveAttribute("aria-checked", "true");
    expect(within(selected).getByText(/^0(\s|$)/)).toBeInTheDocument();
    await click(within(panel).getByRole("menuitemradio", { name: /All tasks/ }));
    expect(screen.getByText("Watch second PR")).toBeInTheDocument();
    expect(
      within(panel).queryByRole("menuitemradio", { name: /PR #1 updated/ })
    ).toBeNull();
  });

  it("filters Scheduled and On updates notifications separately", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ title: "Team chat" }),
        item({
          id: "w1:loop",
          kind: "agent_task",
          status: "escalated",
          title: "Morning digest",
          loop: {
            state: "paused",
            startedAt: 1,
            wakeCount: 2,
            cadence: { everyMinutes: 60 },
          },
        }),
        item({
          id: "w1:event",
          kind: "agent_task",
          status: "active",
          title: "PR updates",
          loop: {
            state: "active",
            startedAt: 1,
            wakeCount: 2,
            cadence: { events: "new comments" },
          },
        }),
        item({
          id: "w1:once",
          kind: "agent_task",
          status: "running",
          title: "One-off task",
        }),
      ],
    });
    await flush();
    expect(
      screen.getByRole("link", { name: "Morning digest, Scheduled" })
    ).toBeVisible();
    expect(screen.getByRole("link", { name: "PR updates, On updates" })).toBeVisible();
    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "Loops" }));
    let panel = screen.getByTestId("inbox-schedule-filter");
    expect(
      within(panel).getByRole("menuitemcheckbox", { name: /^Scheduled/ })
    ).toHaveTextContent("1 notification");
    expect(
      within(panel).getByRole("menuitemcheckbox", { name: /^On updates/ })
    ).toHaveTextContent("1 notification");
    await click(within(panel).getByRole("menuitemcheckbox", { name: /No loop/ }));
    await click(within(panel).getByRole("menuitemcheckbox", { name: /^On updates/ }));
    await closeInboxFilterMenu();
    expect(screen.getAllByTestId("inbox-item").map((row) => row.textContent)).toEqual([
      expect.stringContaining("Team chat"),
      expect.stringContaining("Morning digest"),
    ]);
    expect(screen.getByTestId("inbox-filter-footer")).toHaveTextContent(
      "2 notifications hidden by filters"
    );
    await click(screen.getByTestId("inbox-filter-trigger"));
    await click(screen.getByRole("menuitem", { name: "Loops" }));
    panel = screen.getByTestId("inbox-schedule-filter");
    await click(within(panel).getByRole("menuitemcheckbox", { name: /^Scheduled/ }));
    await click(within(panel).getByRole("menuitemcheckbox", { name: /^On updates/ }));
    await closeInboxFilterMenu();
    expect(screen.getAllByTestId("inbox-item").map((row) => row.textContent)).toEqual([
      expect.stringContaining("Team chat"),
      expect.stringContaining("PR updates"),
    ]);
  });

  it("keeps the Platform submenu available when the Inbox is empty", async () => {
    renderInbox({ source: "live-sync", items: [] });
    await flush();

    await click(screen.getByTestId("inbox-filter-trigger"));
    // No Task is a Loop, so there is nothing to narrow by schedule.
    expect(screen.queryByRole("menuitem", { name: "Loops" })).toBeNull();
    await click(screen.getByRole("menuitem", { name: "Platform" }));
    expect(screen.getByText("No filters found")).toBeInTheDocument();
    expect(screen.queryByRole("menuitemcheckbox")).toBeNull();
    expect(screen.getByText("No notifications")).toBeInTheDocument();
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "false"
    );
  });

  it("dismisses the actions menu on a blank-area click without deleting notifications", async () => {
    renderInbox({ source: "live-sync", items: [item()] });
    await flush();
    await click(screen.getByTestId("inbox-actions-trigger"));
    expect(screen.getByRole("menuitem", { name: "Delete all" })).toBeInTheDocument();
    await click(screen.getByTestId("inbox-conversation-rail"));
    expect(screen.queryByRole("menuitem", { name: "Delete all" })).toBeNull();
    expect(screen.getByText("Kickoff sync")).toBeInTheDocument();
    expect(core.sentTo("marks.mark")).toEqual([]);
  });

  it("deletes every listed notification from the actions menu", async () => {
    renderInbox(
      {
        source: "live-sync",
        items: [
          item({ title: "Kickoff sync" }),
          item({
            id: "w1:c2",
            conversationId: "c2",
            kind: "agent_task",
            status: "completed",
            title: "Nightly run",
          }),
        ],
      },
      {},
      undefined,
      { toasts: true }
    );
    await flush();
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(2);

    await click(screen.getByTestId("inbox-actions-trigger"));
    await click(screen.getByRole("menuitem", { name: "Delete all" }));

    expect(core.sentTo("marks.mark")).toEqual([
      {
        kind: "inboxDeleted",
        entries: [
          ["w1:c1", 1_000],
          ["w1:c2", 1_000],
        ],
      },
    ]);
    expect(screen.queryAllByTestId("inbox-item")).toHaveLength(0);
    expect(
      within(screen.getByTestId("inbox-empty")).getByText("No notifications")
    ).toBeInTheDocument();
    expect(screen.getByText("2 notifications deleted")).toBeInTheDocument();
  });

  it("keeps unread needs-review tasks when deleting read notifications", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ title: "Kickoff sync" }),
        item({
          id: "w1:c2",
          conversationId: "c2",
          kind: "agent_task",
          status: "needs_review",
          title: "Review me",
        }),
      ],
    });
    await flush();
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(2);

    await click(screen.getByTestId("inbox-actions-trigger"));
    await click(screen.getByRole("menuitem", { name: "Delete all read" }));

    expect(core.sentTo("marks.mark")).toEqual([
      { kind: "inboxDeleted", entries: [["w1:c1", 1_000]] },
    ]);
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(1);
    expect(screen.getByText("Review me")).toBeInTheDocument();
    expect(screen.queryByText("Kickoff sync")).toBeNull();

    // Nothing read is left, so the row is disabled rather than a no-op.
    await click(screen.getByTestId("inbox-actions-trigger"));
    expect(screen.getByRole("menuitem", { name: "Delete all read" })).toHaveAttribute(
      "aria-disabled",
      "true"
    );
  });

  it("deletes one notification from the row context menu", async () => {
    renderInbox(
      {
        source: "live-sync",
        items: [
          item({ title: "Kickoff sync" }),
          item({
            id: "w1:c2",
            conversationId: "c2",
            title: "Ship it",
          }),
        ],
      },
      {},
      undefined,
      { toasts: true }
    );
    await flush();
    const rows = screen.getAllByTestId("inbox-item");
    expect(rows).toHaveLength(2);

    await openInboxItemMenu(rows[0]!);
    await click(screen.getByRole("menuitem", { name: "Delete notification" }));

    expect(core.sentTo("marks.mark")).toEqual([
      { kind: "inboxDeleted", entries: [["w1:c1", 1_000]] },
    ]);
    expect(screen.getAllByTestId("inbox-item")).toHaveLength(1);
    expect(screen.getByText("Ship it")).toBeInTheDocument();
    expect(screen.queryByText("Kickoff sync")).toBeNull();
    expect(screen.getByText("1 notification deleted")).toBeInTheDocument();
  });

  it("toggles a row between unread and read from the context menu", async () => {
    renderInbox({ source: "live-sync", items: [item()] });
    await flush();
    const row = screen.getByTestId("inbox-item");
    expect(row.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
      "data-state",
      "hidden"
    );

    await openInboxItemMenu(row);
    await click(screen.getByRole("menuitem", { name: "Mark as unread" }));

    expect(core.sentTo("marks.mark")).toEqual([
      { kind: "inboxUnread", entries: [["w1:c1", 1_000]] },
    ]);
    expect(row.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
      "data-state",
      "visible"
    );

    await openInboxItemMenu(row);
    expect(screen.queryByRole("menuitem", { name: "Mark as unread" })).toBeNull();
    await click(screen.getByRole("menuitem", { name: "Mark as read" }));
    expect(core.sentTo("marks.unmark")).toEqual([
      { kind: "inboxUnread", ids: ["w1:c1"] },
    ]);
    expect(row.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
      "data-state",
      "hidden"
    );

    await click(row);
    expect(row.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
      "data-state",
      "hidden"
    );
  });
});

async function openInboxItemMenu(row: HTMLElement) {
  vi.spyOn(row, "getBoundingClientRect").mockReturnValue({
    x: 100,
    y: 200,
    top: 200,
    right: 420,
    bottom: 236,
    left: 100,
    width: 320,
    height: 36,
    toJSON: () => ({}),
  });
  fireEvent.pointerDown(row, {
    button: 2,
    isPrimary: true,
    pointerId: 1,
    pointerType: "mouse",
  });
  fireEvent(
    row,
    new MouseEvent("contextmenu", {
      bubbles: true,
      cancelable: true,
      clientX: 140,
      clientY: 218,
    })
  );
  await flush();
}

async function closeInboxFilterMenu() {
  await press("{Escape}");
  expect(screen.queryByTestId("inbox-status-filter")).toBeNull();
  expect(screen.queryByTestId("inbox-platform-filter")).toBeNull();
  expect(screen.queryByTestId("inbox-schedule-filter")).toBeNull();
  if (screen.queryAllByRole("menuitem").length > 0) {
    await press("{Escape}");
  }
  expect(screen.queryAllByRole("menuitem")).toHaveLength(0);
}

/** Renders the Inbox; `toasts` adds the Toaster, for the tests that read a toast. */
function renderInbox(
  result: ProductInboxListResult | null,
  props: Partial<ComponentProps<typeof InboxView>> = {},
  locale?: CommaLocale,
  { toasts = false }: { toasts?: boolean } = {}
) {
  const rootRoute = createRootRoute({
    component: Outlet,
  });
  const inboxRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    component: () => <InboxView result={result} {...props} />,
  });
  const conversationRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/inbox/$workspaceId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([inboxRoute, conversationRoute]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });

  const content = (
    <>
      <RouterProvider router={router} />
      {toasts ? <Toaster /> : null}
    </>
  );
  return {
    ...render(
      core.wrap(
        locale ? (
          <CommaI18nProvider locale={locale}>{content}</CommaI18nProvider>
        ) : (
          content
        )
      )
    ),
    router,
  };
}
