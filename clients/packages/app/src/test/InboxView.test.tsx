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
import { fireEvent, render, screen, waitFor, within } from "@comma/test-utils/render";
import userEvent from "@testing-library/user-event";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ProductInboxItem, ProductInboxListResult } from "@comma/native-bridge";
import { Toaster, toast } from "@comma/ui";
import { InboxView } from "../components/inbox/InboxView";
import { readInboxUnreadMarks } from "../components/inbox/inboxDeletion";

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

describe("InboxView", () => {
  afterEach(() => {
    toast.dismissAll();
    initializeCommaI18n(["en"]);
    // Deleted and unread marks persist in storage across renders.
    window.localStorage.clear();
  });

  it("renders loading when the host has not projected a list", async () => {
    renderInbox(null);

    expect(await screen.findByRole("status", { name: "Loading…" })).toBeInTheDocument();
    expect(screen.queryByTestId("inbox-source")).toBeNull();
    expect(screen.queryByTestId("inbox-list")).toBeNull();
  });

  it("renders synced conversation titles in the compact rail", async () => {
    renderInbox({
      source: "live-sync",
      lastSyncedAt: 500,
      items: [item(), item({ id: "w2:c9", workspaceName: "Globex", title: "Ship it" })],
    });

    const rows = await screen.findAllByTestId("inbox-item");
    expect(rows).toHaveLength(2);
    expect(screen.getByTestId("inbox-conversation-rail")).toHaveStyle({
      flexBasis: "320px",
      width: "320px",
    });
    expect(within(rows[0]!).getByText("Kickoff sync")).toBeInTheDocument();
    expect(rows[0]).toHaveAccessibleName("Kickoff sync");
    expect(within(rows[1]!).getByText("Ship it")).toBeInTheDocument();
  });

  it("localizes the Inbox chrome while preserving conversation titles", async () => {
    renderInbox({ source: "live-sync", items: [item()] }, {}, "zh-CN");

    expect(await screen.findByRole("heading", { name: "收件箱" })).toBeInTheDocument();
    expect(screen.getByText("Kickoff sync")).toBeInTheDocument();
    expect(screen.queryByRole("heading", { name: "Inbox" })).not.toBeInTheDocument();
  });

  it("visibly and accessibly qualifies stale and unknown conversation rows", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ freshness: "stale", id: "w1:stale", title: "Stale task" }),
        item({ freshness: "unknown", id: "w1:unknown", title: "Unknown task" }),
      ],
    });

    const staleRow = await screen.findByRole("link", { name: /Stale task.*Stale/i });
    const unknownRow = await screen.findByRole("link", {
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

    const row = await screen.findByRole("link", { name: "Cached task" });
    expect(row).toHaveAttribute("data-freshness", "fresh");
    expect(row).not.toHaveTextContent("Stale");
    expect(
      screen.getByRole("link", { name: "Earlier result, Stale" })
    ).toHaveTextContent("Stale");
  });

  it("reports sync failure once while keeping cached rows readable", async () => {
    renderInbox({
      source: "error",
      errorCode: "network_unavailable",
      items: [item({ freshness: "fresh", title: "Cached during error" })],
    });

    const row = await screen.findByRole("link", {
      name: "Cached during error",
    });
    expect(row).toHaveAttribute("data-freshness", "fresh");
    expect(row).not.toHaveTextContent("Stale");
    expect(await screen.findByTestId("inbox-banner")).toHaveTextContent("Sync failed");
  });

  it("formats Comma epoch-second timestamps as current relative time", async () => {
    const oneMinuteAgoInSeconds = Math.floor((Date.now() - 70_000) / 1000);

    renderInbox({
      source: "live-sync",
      lastSyncedAt: oneMinuteAgoInSeconds,
      items: [item({ updatedAt: oneMinuteAgoInSeconds })],
    });

    expect(await screen.findByTestId("inbox-source")).toHaveTextContent("1m");
    expect(await screen.findByRole("link", { name: /Kickoff sync/ })).toHaveTextContent(
      "1m"
    );
  });

  it("links each conversation row to the conversation detail route", async () => {
    const { router } = renderInbox({ source: "live-sync", items: [item()] });
    const row = await screen.findByRole("link", { name: /Kickoff sync/ });

    expect(row).toHaveAttribute("href", "/inbox/w1/grp_test/c1");
    fireEvent.click(row);
    await waitFor(() =>
      expect(router.state.location.pathname).toBe("/inbox/w1/grp_test/c1")
    );
  });

  it("shows an offline banner but still lists items on cache + error", async () => {
    renderInbox({
      source: "cache",
      errorCode: "network_unavailable",
      items: [item()],
    });

    const banner = await screen.findByTestId("inbox-banner");
    expect(banner).toHaveTextContent("Showing local cache");
    expect(banner).toHaveTextContent(
      "Comma could not reach the ProductInbox authority."
    );
    expect(screen.getByTestId("inbox-list")).toBeInTheDocument();
  });

  it.each([
    {
      name: "surfaces the error on the error state",
      locale: undefined,
      title: "Sync failed",
      detail: "The Main ProductInbox scheduler is unavailable.",
    },
    {
      name: "localizes ProductInbox error details",
      locale: "zh-CN" as const,
      title: "同步失败",
      detail: "主进程的 ProductInbox 调度器不可用。",
    },
  ])("$name", async ({ detail, locale, title }) => {
    renderInbox(
      {
        source: "error",
        errorCode: "utility_unavailable",
        items: [],
      },
      {},
      locale
    );

    expect(await screen.findByTestId("inbox-banner")).toHaveTextContent(title);
    expect(screen.getByTestId("inbox-banner")).toHaveTextContent(detail);
  });

  it("shows an empty state when synced with no conversations", async () => {
    renderInbox({ source: "live-sync", lastSyncedAt: 1, items: [] });

    expect(
      within(await screen.findByTestId("inbox-empty")).getByText("No notifications")
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

    expect(
      await screen.findAllByTestId("inbox-item", undefined, { timeout: 5_000 })
    ).toHaveLength(3);
    expect(screen.queryByTestId("inbox-filter-footer")).toBeNull();

    // The first level lists filter dimensions; each dimension's options live
    // one level deeper, as in the Tasks filter.
    // userEvent, not fireEvent: React Aria's submenu trigger opens on the full
    // pointer sequence, and a bare click event leaves it closed under load.
    await userEvent.click(await screen.findByTestId("inbox-filter-trigger"));
    expect(screen.queryByTestId("inbox-status-filter")).toBeNull();
    await userEvent.click(
      await screen.findByRole("menuitem", { name: /Task status/ }, { timeout: 5_000 })
    );

    // Queried from `screen`, not through a captured panel node: React Aria
    // remounts the popover subtree when it repositions, which detaches any
    // element reference taken before the options render.
    await screen.findByTestId("inbox-status-filter", undefined, { timeout: 5_000 });
    const done = await screen.findByRole(
      "menuitemcheckbox",
      { name: /Done/ },
      { timeout: 5_000 }
    );
    // The count beside a status is the Inbox's notification count, not the
    // Tasks board's task count.
    expect(done).toHaveTextContent("1 notification");
    await userEvent.click(done);

    await waitFor(
      () => {
        expect(screen.getAllByTestId("inbox-item")).toHaveLength(2);
      },
      { timeout: 5_000 }
    );
    expect(screen.queryByText("Nightly run")).toBeNull();
    expect(screen.getByTestId("inbox-filter-footer")).toHaveTextContent(
      "1 notification hidden by filters"
    );

    // The menu is modal, so close it before reaching the footer under it.
    await userEvent.keyboard("{Escape}");
    await waitFor(() => {
      expect(screen.queryByRole("menuitemcheckbox", { name: /Done/ })).toBeNull();
    });
    if (screen.queryByRole("menuitem", { name: /Task status/ })) {
      await userEvent.keyboard("{Escape}");
    }
    await waitFor(() => {
      expect(screen.queryByRole("menuitem", { name: /Task status/ })).toBeNull();
    });
    await userEvent.click(screen.getByRole("button", { name: /Clear Filters/ }));

    await waitFor(() => {
      expect(screen.getAllByTestId("inbox-item")).toHaveLength(3);
    });
    expect(screen.queryByTestId("inbox-filter-footer")).toBeNull();
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "false"
    );
  }, 20_000);

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

    expect(await screen.findAllByTestId("inbox-item")).toHaveLength(5);
    await userEvent.click(screen.getByTestId("inbox-filter-trigger"));
    await userEvent.click(await screen.findByRole("menuitem", { name: "平台" }));
    expect(
      await screen.findByRole("menuitemcheckbox", { name: /飞书/ })
    ).toHaveTextContent("1 条通知");
    expect(screen.getByRole("menuitemcheckbox", { name: /未指定/ })).toHaveTextContent(
      "2 条通知"
    );

    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /未指定/ }));
    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /Slack/ }));
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(2));
    expect(screen.queryByText("Legacy chat")).toBeNull();
    expect(screen.queryByText("Future chat")).toBeNull();

    await userEvent.type(screen.getByRole("textbox", { name: "筛选…" }), "飞书");
    expect(screen.queryByRole("menuitemcheckbox", { name: /Comma/ })).toBeNull();
    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /飞书/ }));
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(1));
    expect(screen.getByText("Comma chat")).toBeInTheDocument();

    await userEvent.clear(screen.getByRole("textbox", { name: "筛选…" }));
    expect(screen.getByRole("menuitemcheckbox", { name: /Comma/ })).toHaveAttribute(
      "aria-checked",
      "true"
    );
    expect(screen.getByRole("menuitemcheckbox", { name: /Slack/ })).toHaveAttribute(
      "aria-checked",
      "false"
    );
    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /Slack/ }));
    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /飞书/ }));
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(3));
    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /未指定/ }));

    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(5));
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "false"
    );
    expect(screen.queryByTestId("inbox-filter-footer")).toBeNull();
  }, 20_000);

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

    await userEvent.click(await screen.findByTestId("inbox-filter-trigger"));
    await userEvent.click(await screen.findByRole("menuitem", { name: "Task status" }));
    await userEvent.click(
      await screen.findByRole("menuitemcheckbox", { name: /Done/ })
    );
    await closeInboxFilterMenu();
    await userEvent.click(screen.getByTestId("inbox-filter-trigger"));
    await userEvent.click(await screen.findByRole("menuitem", { name: "Platform" }));

    // Counts describe all undeleted notifications, including the task hidden by status.
    expect(
      await screen.findByRole("menuitemcheckbox", { name: /Slack/ })
    ).toHaveTextContent("3 notifications");
    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /Comma/ }));
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(2));
    expect(screen.getByText("Slack chat")).toBeInTheDocument();
    expect(screen.getByText("Slack running")).toBeInTheDocument();
    expect(screen.getByTestId("inbox-filter-footer")).toHaveTextContent(
      "2 notifications hidden by filters"
    );
    await closeInboxFilterMenu();
    await userEvent.click(screen.getByRole("button", { name: "Clear Filters" }));
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(4));
    expect(screen.queryByTestId("inbox-filter-footer")).toBeNull();
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "false"
    );
  }, 20_000);

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

    expect(await screen.findAllByTestId("inbox-item")).toHaveLength(3);
    await userEvent.click(screen.getByTestId("inbox-filter-trigger"));
    await userEvent.click(await screen.findByRole("menuitem", { name: "Platform" }));
    expect(
      await screen.findByRole("menuitemcheckbox", { name: /Slack/ })
    ).toHaveTextContent("1 notification");
    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /Telegram/ }));
    await closeInboxFilterMenu();
    await userEvent.click(screen.getByTestId("inbox-actions-trigger"));
    await userEvent.click(
      await screen.findByRole("menuitem", { name: "Delete all read" })
    );
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(1));
    expect(screen.getByText("Unread Comma task")).toBeInTheDocument();

    await userEvent.click(screen.getByTestId("inbox-filter-trigger"));
    await userEvent.click(await screen.findByRole("menuitem", { name: "Platform" }));
    const slack = await screen.findByRole("menuitemcheckbox", { name: /Slack/ });
    expect(slack).toHaveAttribute("aria-checked", "true");
    expect(slack).toHaveTextContent("0 notifications");
    const telegram = screen.getByRole("menuitemcheckbox", { name: /Telegram/ });
    expect(telegram).toHaveAttribute("aria-checked", "false");
    expect(telegram).toHaveTextContent("1 notification");
    await closeInboxFilterMenu();
    await userEvent.click(screen.getByRole("button", { name: "Clear Filters" }));
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(2));
    expect(screen.getByText("Telegram chat")).toBeInTheDocument();
    expect(screen.queryByText("Read Slack chat")).toBeNull();
    expect(screen.queryByText("Archived Slack chat")).toBeNull();
  }, 20_000);

  it("can select only Slack when the other notification has no platform", async () => {
    renderInbox({
      source: "live-sync",
      items: [
        item({ origin: "slack", title: "Slack chat" }),
        item({ id: "w1:legacy", title: "Legacy chat" }),
      ],
    });

    expect(await screen.findAllByTestId("inbox-item")).toHaveLength(2);
    await userEvent.click(screen.getByTestId("inbox-filter-trigger"));
    await userEvent.click(await screen.findByRole("menuitem", { name: "Platform" }));
    await userEvent.click(
      await screen.findByRole("menuitemcheckbox", { name: /Unspecified/ })
    );
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(1));
    expect(screen.getByText("Slack chat")).toBeInTheDocument();
    expect(screen.queryByText("Legacy chat")).toBeNull();
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "true"
    );

    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /Slack/ }));
    await waitFor(() => expect(screen.queryAllByTestId("inbox-item")).toHaveLength(0));
    await userEvent.click(screen.getByRole("menuitemcheckbox", { name: /Slack/ }));
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(1));
    expect(screen.queryByText("Legacy chat")).toBeNull();
    await userEvent.click(
      screen.getByRole("menuitemcheckbox", { name: /Unspecified/ })
    );
    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(2));
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "false"
    );
  }, 20_000);

  it("keeps the Platform submenu available when the Inbox is empty", async () => {
    renderInbox({ source: "live-sync", items: [] });

    await userEvent.click(await screen.findByTestId("inbox-filter-trigger"));
    await userEvent.click(await screen.findByRole("menuitem", { name: "Platform" }));
    expect(await screen.findByText("No filters found")).toBeInTheDocument();
    expect(screen.queryByRole("menuitemcheckbox")).toBeNull();
    expect(screen.getByText("No notifications")).toBeInTheDocument();
    expect(screen.getByTestId("inbox-filter-trigger")).toHaveAttribute(
      "data-filtered",
      "false"
    );
  });

  it("dismisses the actions menu on a blank-area click without deleting notifications", async () => {
    renderInbox({ source: "live-sync", items: [item()] });
    const user = userEvent.setup();
    await user.click(await screen.findByTestId("inbox-actions-trigger"));
    expect(
      await screen.findByRole("menuitem", { name: "Delete all" })
    ).toBeInTheDocument();
    await user.click(screen.getByTestId("inbox-conversation-rail"));
    await waitFor(() =>
      expect(screen.queryByRole("menuitem", { name: "Delete all" })).toBeNull()
    );
    expect(screen.getByText("Kickoff sync")).toBeInTheDocument();
  });

  it("deletes every listed notification from the actions menu", async () => {
    renderInbox({
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
    });
    expect(
      await screen.findAllByTestId("inbox-item", undefined, { timeout: 5_000 })
    ).toHaveLength(2);

    await userEvent.click(await screen.findByTestId("inbox-actions-trigger"));
    await userEvent.click(
      await screen.findByRole("menuitem", { name: "Delete all" }, { timeout: 5_000 })
    );

    await waitFor(
      () => {
        expect(screen.queryAllByTestId("inbox-item")).toHaveLength(0);
      },
      { timeout: 5_000 }
    );
    expect(
      within(screen.getByTestId("inbox-empty")).getByText("No notifications")
    ).toBeInTheDocument();
    expect(await screen.findByText("2 notifications deleted")).toBeInTheDocument();
  }, 20_000);

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
    expect(
      await screen.findAllByTestId("inbox-item", undefined, { timeout: 5_000 })
    ).toHaveLength(2);

    await userEvent.click(await screen.findByTestId("inbox-actions-trigger"));
    await userEvent.click(
      await screen.findByRole(
        "menuitem",
        { name: "Delete all read" },
        { timeout: 5_000 }
      )
    );

    await waitFor(
      () => {
        expect(screen.getAllByTestId("inbox-item")).toHaveLength(1);
      },
      { timeout: 5_000 }
    );
    expect(screen.getByText("Review me")).toBeInTheDocument();
    expect(screen.queryByText("Kickoff sync")).toBeNull();

    // Nothing read is left, so the row is disabled rather than a no-op.
    await userEvent.click(await screen.findByTestId("inbox-actions-trigger"));
    expect(
      await screen.findByRole(
        "menuitem",
        { name: "Delete all read" },
        { timeout: 5_000 }
      )
    ).toHaveAttribute("aria-disabled", "true");
  }, 20_000);

  it("deletes one notification from the row context menu", async () => {
    const user = userEvent.setup();
    renderInbox({
      source: "live-sync",
      items: [
        item({ title: "Kickoff sync" }),
        item({
          id: "w1:c2",
          conversationId: "c2",
          title: "Ship it",
        }),
      ],
    });
    const rows = await screen.findAllByTestId("inbox-item");
    expect(rows).toHaveLength(2);

    openInboxItemMenu(rows[0]!);
    await user.click(
      await screen.findByRole("menuitem", { name: "Delete notification" })
    );

    await waitFor(() => expect(screen.getAllByTestId("inbox-item")).toHaveLength(1));
    expect(screen.getByText("Ship it")).toBeInTheDocument();
    expect(screen.queryByText("Kickoff sync")).toBeNull();
    expect(await screen.findByText("1 notification deleted")).toBeInTheDocument();
  }, 20_000);

  it("toggles a row between unread and read from the context menu", async () => {
    const user = userEvent.setup();
    renderInbox({ source: "live-sync", items: [item()] });
    const row = await screen.findByTestId("inbox-item");
    expect(row.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
      "data-state",
      "hidden"
    );

    openInboxItemMenu(row);
    await user.click(await screen.findByRole("menuitem", { name: "Mark as unread" }));

    await waitFor(() =>
      expect(row.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
        "data-state",
        "visible"
      )
    );
    expect(readInboxUnreadMarks().has("w1:c1")).toBe(true);

    openInboxItemMenu(row);
    expect(screen.queryByRole("menuitem", { name: "Mark as unread" })).toBeNull();
    await user.click(await screen.findByRole("menuitem", { name: "Mark as read" }));
    await waitFor(() =>
      expect(row.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
        "data-state",
        "hidden"
      )
    );
    expect(readInboxUnreadMarks().has("w1:c1")).toBe(false);

    await user.click(row);
    expect(readInboxUnreadMarks().has("w1:c1")).toBe(false);
  }, 20_000);

  it("marks an unread needs-review row read from the context menu", async () => {
    const user = userEvent.setup();
    renderInbox({
      source: "live-sync",
      items: [
        item({
          kind: "agent_task",
          status: "needs_review",
          title: "Review me",
        }),
      ],
    });
    const row = await screen.findByTestId("inbox-item");
    expect(row.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
      "data-state",
      "visible"
    );

    openInboxItemMenu(row);
    expect(screen.queryByRole("menuitem", { name: "Mark as unread" })).toBeNull();
    await user.click(await screen.findByRole("menuitem", { name: "Mark as read" }));
    await waitFor(() =>
      expect(row.querySelector('[data-slot="task-list-item-dot"]')).toHaveAttribute(
        "data-state",
        "hidden"
      )
    );
  }, 20_000);
});

function openInboxItemMenu(row: HTMLElement) {
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
}

async function closeInboxFilterMenu() {
  await userEvent.keyboard("{Escape}");
  await waitFor(() => {
    expect(screen.queryByTestId("inbox-status-filter")).toBeNull();
    expect(screen.queryByTestId("inbox-platform-filter")).toBeNull();
  });
  if (screen.queryAllByRole("menuitem").length > 0) {
    await userEvent.keyboard("{Escape}");
  }
  await waitFor(() => expect(screen.queryAllByRole("menuitem")).toHaveLength(0));
}

function renderInbox(
  result: ProductInboxListResult | null,
  props: Partial<ComponentProps<typeof InboxView>> = {},
  locale?: CommaLocale
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
      <Toaster />
    </>
  );
  return {
    ...render(
      locale ? (
        <CommaI18nProvider locale={locale}>{content}</CommaI18nProvider>
      ) : (
        content
      )
    ),
    router,
  };
}
