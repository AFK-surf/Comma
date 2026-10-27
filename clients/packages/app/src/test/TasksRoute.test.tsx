import type { CoreClient } from "@comma/core-client";
import { CoreProvider } from "@comma/core-client";
import { delegateScriptedCore } from "@comma/test-utils/scripted-core";
import { flush } from "@comma/test-utils/fake-clock";
import { labelCatalog, labelsCore } from "./labelsCore";
import userEvent from "@testing-library/user-event";
import {
  Outlet,
  RouterProvider,
  type AnyRouter,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import type { ProductInboxListResult } from "@comma/core-client";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { controlIntersections } from "@comma/test-utils/intersection";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, within } from "@comma/test-utils/render";
import { taskStatusBucket } from "@comma/ui/components/task-workspace";
import { Toaster, toast } from "@comma/ui/components/toast";
import { afterEach, describe, expect, it, vi } from "vitest";
import { CommaAuthContext } from "../components/auth-context";
import { ChatProvider } from "../components/chat/ChatProvider";
import {
  TaskWorkspacePanel,
  TasksRoute,
  type TaskViewModel,
} from "../components/tasks/TasksRoute";
import { validateTasksSearch } from "../components/tasks/tasksSearch";
import {
  createProductInboxProjectionHarness,
  createTestCommaAuthValue,
  testProductLease,
} from "./productInboxProjectionHarness";

/** A user whose waits run on the fake clock. */
const user = () => userEvent.setup({ advanceTimers: vi.advanceTimersByTime });

const morningLoop = (minute: number) => ({
  state: "active" as const,
  startedAt: 1,
  wakeCount: 0,
  cadence: {
    cron: `${minute} 9 * * *`,
    timezone: "Asia/Singapore",
    pattern: { kind: "daily" as const, hour: 9, minute },
  },
});

describe("TasksRoute", () => {
  it("hides archived owner items without adding a board column or filter", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          taskInboxItem("visible", "Visible task"),
          { ...taskInboxItem("archived", "Archived task title"), status: "archived" },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller);
    await flush();
    expect(screen.getByText("Visible task")).toBeInTheDocument();
    expect(screen.queryByText("Archived task title")).toBeNull();
    expect(screen.queryByText("Archived", { exact: true })).toBeNull();
  });
  afterEach(() => {
    initializeCommaI18n(["en"]);
    localStorage.clear();
    vi.unstubAllGlobals();
  });

  it.each([
    ["terminal", "done"],
    ["escalated", "needs_review"],
    ["ready_for_review", "needs_review"],
  ])("maps status %s to the %s display bucket", (status, bucket) => {
    expect(taskStatusBucket(status)).toBe(bucket);
  });

  it("localizes task activity instead of exposing its raw status enum", () => {
    render(
      <CommaI18nProvider locale="zh-CN">
        <TaskWorkspacePanel
          tasks={[
            {
              ...taskFixture(),
              activityStatus: "running_tests",
              lastMessage: undefined,
              messages: [],
            },
          ]}
        />
      </CommaI18nProvider>
    );

    expect(screen.getByText("正在运行测试")).toBeInTheDocument();
    expect(screen.queryByText("running_tests")).not.toBeInTheDocument();
  });

  it("disables unimplemented task detail actions", async () => {
    render(<TaskWorkspacePanel tasks={[taskFixture()]} />);

    await user().click(screen.getByRole("button", { name: "Review task UI" }));

    expect(screen.getByRole("button", { name: "Open task chat" })).toBeDisabled();
    expect(screen.getByRole("button", { name: "Copy task link" })).toBeDisabled();
    expect(screen.getByLabelText("Continue task")).toBeDisabled();
  });

  it("loads only agent_task projections and opens their public detail route", async () => {
    const result: ProductInboxListResult = {
      activeWorkspaceId: "w1",
      lastSyncedAt: 1_000,
      source: "live-sync",
      items: [
        {
          conversationId: "chat-1",
          id: "w1:chat-1",
          kind: "user_chat",
          source: "salix.conversation",
          status: "active",
          title: "Personal Chat",
          updatedAt: 1_000,
          workspaceId: "w1",
          workspaceName: "My Workspace",
          groupId: "grp_test",
        },
        {
          conversationId: "task-1",
          id: "w1:task-1",
          kind: "agent_task",
          source: "salix.conversation",
          status: "completed",
          title: "Comma 本地聊天验收清单",
          updatedAt: 2_000,
          workspaceId: "w1",
          workspaceName: "My Workspace",
          groupId: "grp_test",
        },
      ],
    };
    const projection = createProductInboxProjectionHarness({ initial: result });
    installNativeBridgeMock({ platform: "electron" });
    const { router } = renderTasksRoute(projection.controller);

    await flush();
    expect(screen.getByText("Comma 本地聊天验收清单")).toBeInTheDocument();
    expect(screen.queryByText("Personal Chat")).toBeNull();
    expect(projection.retain).toHaveBeenCalledWith({ session: testProductLease });

    await user().click(screen.getByRole("button", { name: "Comma 本地聊天验收清单" }));
    await flush();
    expect(router.state.location.pathname).toBe("/tasks/w1/grp_test/task-1");
  });

  it("lists the Tasks the workspace's stations host, where each runs, and opens one as any Task", async () => {
    const station = "a".repeat(64);
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        lastSyncedAt: 1_000,
        source: "live-sync",
        // The core's list asked with the Tasks the stations host (`hosted`): one is among the items.
        items: [
          taskInboxItem("salix", "Kept by Salix"),
          {
            id: `station:${station}:7`,
            source: "station.chat",
            groupId: "grp_test",
            workspaceId: "w1",
            workspaceName: "My Workspace",
            conversationId: `station:${station}:7`,
            kind: "agent_task",
            labels: [],
            title: "Fix the build on Studio",
            status: "in_progress",
            updatedAt: 3_000,
            host: {
              station,
              thread: "7",
              machine: { name: "Studio", online: false },
              model: "gpt-5.5",
              runtime: "codex",
            },
          },
        ],
        workspaces: [{ id: "w1", name: "My Workspace", group_id: "grp_test" }],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    const { router } = renderTasksRoute(projection.controller);
    await flush();
    expect(screen.getByText("Kept by Salix")).toBeInTheDocument();
    const card = screen.getByRole("button", { name: "Fix the build on Studio" });
    expect(screen.getByTestId("task-card-host")).toHaveTextContent(
      "On Studio · gpt-5.5 · Offline"
    );
    await user().click(card);
    await flush();
    expect(decodeURIComponent(router.state.location.pathname)).toBe(
      `/tasks/w1/grp_test/station:${station}:7`
    );
  });

  it("offers New task and Chat with Comma when the workspace's Tasks are empty, with no machine reached", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        items: [],
        source: "live-sync",
      },
    });
    installNativeBridgeMock({ platform: "electron" });

    const { unmount } = renderTasksRoute(projection.controller);

    await flush();
    expect(screen.getByText("No tasks")).toBeVisible();
    // Comma's cloud and a cloud sandbox need no machine.
    expect(screen.getByRole("button", { name: "New task" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Chat with Comma" })).toBeVisible();

    unmount();
  });

  it("offers New task beside Chat with Comma when the workspace's Tasks are empty and it has a station", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        items: [],
        source: "live-sync",
      },
      stations: {
        workspace: "w1",
        loading: false,
        stations: [
          {
            id: "st_mac",
            name: "MacBook",
            version: "1",
            present: true,
            enrolledAt: null,
            enrolledBy: null,
            link: { state: "online" },
          },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });

    const { unmount } = renderTasksRoute(projection.controller);

    await flush();
    expect(screen.getByText("No tasks")).toBeVisible();
    expect(screen.getByRole("button", { name: "New task" })).toBeVisible();
    expect(screen.getByRole("button", { name: "Chat with Comma" })).toBeVisible();

    unmount();
  });

  it("shows a list the core cannot keep as unavailable, without a retry", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        items: [],
        source: "live-sync",
      },
      retain: async () => {
        throw new Error("retain unavailable");
      },
    });
    installNativeBridgeMock({ platform: "electron" });

    const { unmount } = renderTasksRoute(projection.controller);

    await flush();
    expect(screen.getByRole("heading", { name: "Error" })).toBeVisible();
    expect(screen.getByText("Task list unavailable")).toBeVisible();
    expect(
      screen.queryByText("Task could not be refreshed. Try again in a moment.")
    ).toBeNull();
    expect(screen.queryByRole("button", { name: "Try again" })).toBeNull();
    expect(projection.retain).toHaveBeenCalledOnce();
    expect(projection.retain).toHaveBeenCalledWith({ session: testProductLease });
    expect(projection.refresh).not.toHaveBeenCalled();

    // A topic the core failed holds nothing to let go; nothing reads again.
    unmount();
    await flush();
    expect(projection.retain).toHaveBeenCalledOnce();
    expect(projection.refresh).not.toHaveBeenCalled();
  });

  it("says once for the list that its last read failed", async () => {
    const result: ProductInboxListResult = {
      activeWorkspaceId: "w1",
      errorCode: "network_unavailable",
      source: "cache",
      items: [
        {
          conversationId: "task-stale",
          id: "w1:task-stale",
          kind: "agent_task",
          source: "salix.conversation",
          status: "running",
          title: "Cached running task",
          updatedAt: 2_000,
          workspaceId: "w1",
          workspaceName: "My Workspace",
          groupId: "grp_test",
        },
      ],
    };
    const projection = createProductInboxProjectionHarness({ initial: result });
    installNativeBridgeMock({ platform: "electron" });

    render(<Toaster />);
    renderTasksRoute(projection.controller);

    await flush();
    expect(
      screen.getByRole("button", { name: "Cached running task" })
    ).toBeInTheDocument();
    expect(await screen.findByTestId("tasks-sync-error")).toHaveTextContent(
      "Comma could not reach the ProductInbox authority."
    );
    act(() => toast.dismissAll());
  });

  it("loads the next task page when a scrolling column reaches its end, not before", async () => {
    const firstPage = {
      activeWorkspaceId: "w1",
      hasMore: true,
      items: [taskInboxItem("task-1", "First task")],
      nextCursor: "cursor-2",
      source: "live-sync",
    } satisfies ProductInboxListResult;
    const secondPage = {
      activeWorkspaceId: "w1",
      hasMore: false,
      items: [taskInboxItem("task-2", "Second task")],
      source: "live-sync",
    } satisfies ProductInboxListResult;
    const projection = createProductInboxProjectionHarness({
      initial: firstPage,
      refresh: (input) => (input.cursor ? secondPage : firstPage),
    });
    installNativeBridgeMock({ platform: "electron" });
    // jsdom has no layout: give every scroll viewport more content than room,
    // so the column scrolls and only reaching its end asks for more.
    const scrollHeight = vi
      .spyOn(HTMLElement.prototype, "scrollHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        return this.dataset.slot === "scroll-area-viewport" ? 1_000 : 0;
      });
    const clientHeight = vi
      .spyOn(HTMLElement.prototype, "clientHeight", "get")
      .mockImplementation(function (this: HTMLElement) {
        return this.dataset.slot === "scroll-area-viewport" ? 400 : 0;
      });
    const intersections = controlIntersections();
    try {
      renderTasksRoute(projection.controller);

      await flush();
      expect(screen.getByText("First task")).toBeInTheDocument();
      const columnEnd = document.querySelector<HTMLElement>(
        '[data-slot="task-board-column"] [data-slot="scroll-area-load-more"]'
      );
      expect(columnEnd).not.toBeNull();
      await flush();
      expect(projection.refresh.mock.calls.some(([input]) => input.cursor)).toBe(false);

      act(() => intersections.reveal(columnEnd!));
      await flush();

      expect(screen.getByText("Second task")).toBeInTheDocument();
      expect(projection.refresh).toHaveBeenCalledWith({
        cursor: "cursor-2",
        session: testProductLease,
        workspaceId: "w1",
      });
      expect(
        projection.refresh.mock.calls.filter(([input]) => input.cursor)
      ).toHaveLength(1);
    } finally {
      intersections.restore();
      scrollHeight.mockRestore();
      clientHeight.mockRestore();
    }
  });

  it("stops task pagination after a cache fallback and retries the same cursor", async () => {
    const firstPage: ProductInboxListResult = {
      activeWorkspaceId: "w1",
      hasMore: true,
      items: [taskInboxItem("task-1", "First task")],
      nextCursor: "cursor-2",
      source: "live-sync",
    };
    const failedPage = Promise.withResolvers<ProductInboxListResult>();
    let attempts = 0;
    const projection = createProductInboxProjectionHarness({
      initial: firstPage,
      refresh: (input) => {
        if (!input.cursor) return firstPage;
        attempts += 1;
        return attempts === 1
          ? failedPage.promise
          : {
              activeWorkspaceId: "w1",
              hasMore: false,
              items: [taskInboxItem("task-2", "Last task")],
              source: "live-sync",
            };
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller);
    await flush();
    expect(screen.getByText("First task")).toBeInTheDocument();
    expect(attempts).toBe(1);
    await act(async () => {
      failedPage.resolve({
        activeWorkspaceId: "w1",
        source: "cache",
        errorCode: "network_unavailable",
        items: [],
      });
    });
    await flush();
    expect(attempts).toBe(1);
    await user().click(screen.getByRole("button", { name: "Retry" }));
    await flush();
    expect(screen.getByText("Last task")).toBeInTheDocument();
    expect(screen.getByText("First task")).toBeInTheDocument();
    expect(attempts).toBe(2);
    expect(projection.refresh).toHaveBeenLastCalledWith({
      cursor: "cursor-2",
      workspaceId: "w1",
      session: testProductLease,
    });
  });

  it("keeps showing a loaded task page when the core reads the first page again", async () => {
    const firstPage: ProductInboxListResult = {
      activeWorkspaceId: "w1",
      hasMore: true,
      items: [taskInboxItem("task-1", "Initial first task")],
      nextCursor: "cursor-2",
      source: "live-sync",
    };
    const projection = createProductInboxProjectionHarness({
      initial: firstPage,
      refresh: (input) => {
        if (input.cursor) {
          return {
            activeWorkspaceId: "w1",
            hasMore: false,
            items: [taskInboxItem("task-2", "Loaded second task")],
            source: "live-sync",
          };
        }
        return firstPage;
      },
    });
    installNativeBridgeMock({ platform: "electron" });

    renderTasksRoute(projection.controller);
    await flush();
    expect(screen.getByText("Initial first task")).toBeInTheDocument();
    // No column scrolls (jsdom lays nothing out), so there is no end for the
    // reader to reach and the board pages on by itself.
    await flush();
    expect(screen.getByText("Loaded second task")).toBeInTheDocument();

    // The core reads the first page again and keeps the loaded tail.
    act(() =>
      projection.emit({
        activeWorkspaceId: "w1",
        hasMore: false,
        items: [
          taskInboxItem("task-1", "Refreshed first task"),
          taskInboxItem("task-2", "Loaded second task"),
        ],
        source: "live-sync",
      })
    );
    await flush();

    expect(screen.getByText("Refreshed first task")).toBeInTheDocument();
    expect(screen.getByText("Loaded second task")).toBeInTheDocument();
    // The refreshed first page does not bring back a page past the last one.
    expect(
      projection.refresh.mock.calls.filter(([input]) => input.cursor)
    ).toHaveLength(1);
  });

  it("filters every loaded Task from its projected labels without another metadata read", async () => {
    // The UI's own Comma API answers nothing: a direct metadata read would show here.
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => {
        throw new TypeError("Unexpected fetch");
      })
    );
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          { ...taskInboxItem("task-first", "First task"), labels: ["lbl_work"] },
          { ...taskInboxItem("task-deep", "Deep task"), labels: ["lbl_work"] },
          taskInboxItem("task-bare", "Bare task"),
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller, "/tasks?label=lbl_work", workLabels());
    await flush();

    expect(screen.getByText("Deep task")).toBeInTheDocument();
    expect(screen.getByText("First task")).toBeInTheDocument();
    expect(screen.queryByText("Bare task")).toBeNull();
    const summaryReads = (fetch as unknown as ReturnType<typeof vi.fn>).mock.calls
      .map(([input]) => (input instanceof Request ? input.url : String(input)))
      .filter((url) => url.includes("/task-summaries"));
    expect(summaryReads).toHaveLength(0);

    // Membership is a projected fact, even when the timestamp is unchanged.
    act(() =>
      projection.emit({
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          { ...taskInboxItem("task-first", "First task"), labels: ["lbl_work"] },
          taskInboxItem("task-deep", "Deep task"),
        ],
      })
    );
    await flush();
    expect(screen.queryByText("Deep task")).toBeNull();
    expect(screen.getByText("First task")).toBeInTheDocument();
  });

  it("does not count a deleted label's lingering id as a label", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [{ ...taskInboxItem("task-stale", "Stale task"), labels: ["lbl_gone"] }],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(
      projection.controller,
      "/tasks?label=comma:no-label",
      workLabels()
    );
    await flush();

    // Only the deleted label's id is on it, so it is a Task with no label.
    expect(screen.getByText("Stale task")).toBeInTheDocument();
  });

  it.each([
    ["status=done", "Done Mac task", "Active Windows task"],
    ["clientPlatform=macos", "Done Mac task", "Active Windows task"],
  ])(
    "narrows Tasks for %s and restores the list when cleared",
    async (query, shown, hidden) => {
      const projection = createProductInboxProjectionHarness({
        initial: {
          activeWorkspaceId: "w1",
          source: "live-sync",
          items: [
            {
              ...taskInboxItem("mac", "Done Mac task"),
              status: "completed",
              clientPlatform: "macos",
            },
            {
              ...taskInboxItem("win", "Active Windows task"),
              status: "active",
              clientPlatform: "windows",
            },
          ],
        },
      });
      installNativeBridgeMock({ platform: "electron" });
      const { router } = renderTasksRoute(
        projection.controller,
        `/tasks?${query}`,
        labelsCore({ catalog: labelCatalog() })
      );
      await flush();
      expect(screen.getByText(shown)).toBeInTheDocument();
      expect(screen.queryByText(hidden)).not.toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
        "data-filtered",
        "true"
      );
      await act(() => router.navigate({ search: {}, to: "/tasks" }));
      await flush();
      expect(screen.getByText(hidden)).toBeInTheDocument();
    }
  );

  it("narrows to a platform deep link and shows label and platform chips on cards", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("task-slack", "Slack task"),
            origin: "slack",
            labels: ["lbl_work"],
          },
          { ...taskInboxItem("task-comma", "Comma task"), origin: "comma" },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    const { router } = renderTasksRoute(
      projection.controller,
      "/tasks?platform=slack",
      workLabels()
    );
    await flush();

    expect(screen.getByText("Slack task")).toBeInTheDocument();
    expect(screen.queryByText("Comma task")).toBeNull();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "true"
    );
    const card = screen.getByRole("button", { name: /Slack task/ });
    expect(within(card).getByTestId("task-card-label")).toHaveTextContent("Work");
    expect(within(card).getByTestId("task-card-platform")).toHaveTextContent("Slack");

    // Leaving the deep link behind restores the whole list.
    await act(() => router.navigate({ search: {}, to: "/tasks" }));
    await flush();

    expect(screen.getByText("Comma task")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "false"
    );
  });

  it("opens the Tasks page narrowed to a label from a card chip", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          { ...taskInboxItem("task-work", "Labeled task"), labels: ["lbl_work"] },
          taskInboxItem("task-plain", "Plain task"),
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    const { router } = renderTasksRoute(projection.controller, "/tasks", workLabels());
    await flush();

    expect(screen.getByText("Plain task")).toBeInTheDocument();
    await user().click(screen.getByTestId("task-card-label"));
    await flush();

    expect(router.state.location.search).toEqual({ label: "lbl_work" });
    expect(router.state.location.pathname).toBe("/tasks");
    expect(screen.queryByText("Plain task")).toBeNull();
    expect(screen.getByText("Labeled task")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "true"
    );
  });

  it("opens, changes, searches and clears a specific rule without refreshing the list", async () => {
    const key = '["cron","0 9 * * *","Asia/Singapore"]';
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          { ...taskInboxItem("nine", "Nine o'clock"), loop: morningLoop(0) },
          {
            ...taskInboxItem("same", "Same trigger"),
            loop: { ...morningLoop(0), wakeCount: 8, maxRuns: 10 },
          },
          { ...taskInboxItem("next", "One minute later"), loop: morningLoop(1) },
          {
            ...taskInboxItem("ended", "Ended task"),
            loop: { ...morningLoop(0), state: "ended" },
          },
          taskInboxItem("once", "One-off task"),
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    const { router } = renderTasksRoute(
      projection.controller,
      `/tasks?loopRule=${encodeURIComponent(JSON.stringify(key))}`
    );
    await flush();
    expect(screen.getByText("Nine o'clock")).toBeInTheDocument();
    expect(screen.getByText("Same trigger")).toBeInTheDocument();
    expect(screen.queryByText("One minute later")).toBeNull();
    expect(screen.queryByText("Ended task")).toBeNull();
    const reads = projection.refresh.mock.calls.length;
    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    await user().click(screen.getByRole("menuitem", { name: "Trigger rule" }));
    const panel = screen.getByRole("dialog", { name: "Trigger rule" });
    expect(
      within(panel).getByRole("menuitemradio", { name: /9:00 AM/ })
    ).toHaveAttribute("aria-checked", "true");
    await user().type(within(panel).getByRole("textbox"), "9:01");
    await user().click(within(panel).getByRole("menuitemradio", { name: /9:01 AM/ }));
    await flush();
    expect(screen.getByText("One minute later")).toBeInTheDocument();
    expect(screen.queryByText("Nine o'clock")).toBeNull();
    expect(router.state.location.search).toEqual({});
    await user().clear(within(panel).getByRole("textbox"));
    await user().click(within(panel).getByRole("menuitemradio", { name: /All tasks/ }));
    await flush();
    expect(screen.getByText("Ended task")).toBeInTheDocument();
    expect(screen.getByText("One-off task")).toBeInTheDocument();
    expect(projection.refresh.mock.calls.length).toBe(reads);
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "false"
    );
  });

  it("keeps a linked rule that no loaded Task has checked at zero until All tasks clears it", async () => {
    const key = '["cron","5 9 * * *","Asia/Singapore"]';
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          { ...taskInboxItem("next", "One minute later"), loop: morningLoop(1) },
          taskInboxItem("once", "One-off task"),
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(
      projection.controller,
      `/tasks?loopRule=${encodeURIComponent(JSON.stringify(key))}`
    );
    await flush();
    expect(screen.queryByText("One minute later")).toBeNull();
    expect(screen.queryByText("One-off task")).toBeNull();
    const filter = screen.getByRole("button", { name: "Filter tasks" });
    expect(filter).toHaveAttribute("data-filtered", "true");
    await user().click(filter);
    await user().click(screen.getByRole("menuitem", { name: "Trigger rule" }));
    const panel = screen.getByRole("dialog", { name: "Trigger rule" });
    const linked = within(panel).getByRole("menuitemradio", { name: /9:05\sAM/ });
    expect(linked).toHaveAttribute("aria-checked", "true");
    expect(within(linked).getByText("0")).toBeInTheDocument();
    await user().click(within(panel).getByRole("menuitemradio", { name: /All tasks/ }));
    await flush();
    expect(screen.getByText("One minute later")).toBeInTheDocument();
    expect(screen.getByText("One-off task")).toBeInTheDocument();
    expect(filter).toHaveAttribute("data-filtered", "false");
  });

  it("orders trigger rules by label through list updates, names a zone only where two rules read the same, and merges spellings of one cron", async () => {
    const daily = (timezone: string) => ({
      ...morningLoop(0),
      cadence: { ...morningLoop(0).cadence, timezone },
    });
    const weekdays = (cron: string) => ({
      ...morningLoop(0),
      cadence: {
        cron,
        timezone: "Asia/Singapore",
        pattern: { kind: "weekdays" as const, hour: 9, minute: 0 },
      },
    });
    const every = (minutes: number) => ({
      ...morningLoop(0),
      cadence: {
        everyMinutes: minutes,
        pattern: { kind: "interval" as const, minutes },
      },
    });
    const items = [
      {
        ...taskInboxItem("shanghai", "Shanghai morning"),
        loop: daily("Asia/Shanghai"),
      },
      {
        ...taskInboxItem("singapore", "Singapore morning"),
        loop: daily("Asia/Singapore"),
      },
      { ...taskInboxItem("ten", "Every ten minutes"), loop: every(10) },
      { ...taskInboxItem("five", "Every five minutes"), loop: every(5) },
      { ...taskInboxItem("numbers", "Weekday numbers"), loop: weekdays("0 9 * * 1-5") },
      { ...taskInboxItem("names", "Weekday names"), loop: weekdays("0 9 * * MON-FRI") },
    ];
    const projection = createProductInboxProjectionHarness({
      initial: { activeWorkspaceId: "w1", source: "live-sync", items },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller);
    await flush();
    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    await user().click(screen.getByRole("menuitem", { name: "Trigger rule" }));
    const panel = screen.getByRole("dialog", { name: "Trigger rule" });
    const labels = () =>
      within(panel)
        .getAllByRole("menuitemradio")
        .map((row) => row.querySelector('[data-slot="menu-item-label"]')?.textContent);
    // The reader's zone decides whether "GMT+8" shows; the IANA ids show either way.
    const expected = [
      "All tasks",
      "Every 5 minutes",
      "Every 10 minutes",
      expect.stringMatching(/^Every day at 9:00\sAM( · GMT\+8)? · Asia\/Shanghai$/),
      expect.stringMatching(/^Every day at 9:00\sAM( · GMT\+8)? · Asia\/Singapore$/),
      expect.stringMatching(/^Every weekday at 9:00\sAM( · GMT\+8)?$/),
    ];
    expect(labels()).toEqual(expected);
    expect(
      within(
        within(panel).getByRole("menuitemradio", { name: /Every weekday/ })
      ).getByText("2")
    ).toBeInTheDocument();
    act(() =>
      projection.emit({
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: items.toReversed(),
      })
    );
    await flush();
    expect(labels()).toEqual(expected);
  });

  it("lands a link with another spelling of a cron on the rule of the loaded Tasks", async () => {
    const weekdays = {
      ...morningLoop(0),
      cadence: {
        cron: "0 9 * * 1-5",
        timezone: "Asia/Singapore",
        pattern: { kind: "weekdays" as const, hour: 9, minute: 0 },
      },
    };
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          { ...taskInboxItem("weekdays", "Weekday standup"), loop: weekdays },
          { ...taskInboxItem("daily", "Daily digest"), loop: morningLoop(0) },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    const key = '["cron","0 9 * * MON-FRI","Asia/Singapore"]';
    renderTasksRoute(
      projection.controller,
      `/tasks?loopRule=${encodeURIComponent(JSON.stringify(key))}`
    );
    await flush();
    expect(screen.getByText("Weekday standup")).toBeInTheDocument();
    expect(screen.queryByText("Daily digest")).toBeNull();
    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    await user().click(screen.getByRole("menuitem", { name: "Trigger rule" }));
    const panel = screen.getByRole("dialog", { name: "Trigger rule" });
    // All tasks and one row for each loaded rule: the link adds no empty row.
    expect(within(panel).getAllByRole("menuitemradio")).toHaveLength(3);
    const linked = within(panel).getByRole("menuitemradio", { name: /Every weekday/ });
    expect(linked).toHaveAttribute("aria-checked", "true");
    expect(within(linked).getByText("1")).toBeInTheDocument();
  });

  it("names the trigger type where an event rule reads like a schedule", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("interval", "Five-minute check"),
            loop: {
              ...morningLoop(0),
              cadence: {
                everyMinutes: 5,
                pattern: { kind: "interval" as const, minutes: 5 },
              },
            },
          },
          {
            ...taskInboxItem("events", "Watch the feed"),
            loop: { ...morningLoop(0), cadence: { events: "Every 5 minutes" } },
          },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller);
    await flush();
    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    await user().click(screen.getByRole("menuitem", { name: "Trigger rule" }));
    const panel = screen.getByRole("dialog", { name: "Trigger rule" });
    expect(
      within(panel)
        .getAllByRole("menuitemradio")
        .map((row) => row.querySelector('[data-slot="menu-item-label"]')?.textContent)
    ).toEqual([
      "All tasks",
      "Every 5 minutes · On updates",
      "Every 5 minutes · Scheduled",
    ]);
  });

  it("names a foreign zone in full in a trigger rule's hover text", async () => {
    // No other zone has Chatham's offset (+13:45 in January, the test clock's
    // month). A runner in Chatham gets Kathmandu (+5:45).
    const zone =
      new Intl.DateTimeFormat().resolvedOptions().timeZone === "Pacific/Chatham"
        ? { id: "Asia/Kathmandu", offset: "GMT+5:45", name: "Nepal Time" }
        : { id: "Pacific/Chatham", offset: "GMT+13:45", name: "Chatham Time" };
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("far", "Far morning"),
            loop: {
              ...morningLoop(0),
              cadence: { ...morningLoop(0).cadence, timezone: zone.id },
            },
          },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller);
    await flush();
    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    await user().click(screen.getByRole("menuitem", { name: "Trigger rule" }));
    const panel = screen.getByRole("dialog", { name: "Trigger rule" });
    expect(
      within(panel).getByTitle(new RegExp(`^Every day at 9:00\\sAM · ${zone.name}$`))
    ).toHaveTextContent(`Every day at 9:00 AM · ${zone.offset}`);
  });

  it("keeps an older Loop link narrowed to every Loop type", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("task-loop", "Morning digest"),
            loop: {
              state: "active",
              startedAt: 1,
              wakeCount: 0,
              cadence: { everyMinutes: 60 },
            },
          },
          {
            ...taskInboxItem("task-event", "PR updates"),
            loop: {
              state: "active",
              startedAt: 1,
              wakeCount: 0,
              cadence: { events: "new comments" },
            },
          },
          taskInboxItem("task-once", "One-off task"),
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller, "/tasks?schedule=loop");
    await flush();
    expect(screen.getByText("Morning digest")).toBeInTheDocument();
    expect(screen.getByText("PR updates")).toBeInTheDocument();
    expect(screen.queryByText("One-off task")).toBeNull();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "true"
    );
  });

  it("filters Scheduled and On updates cards separately through chips and the menu", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("task-loop", "Morning digest"),
            labels: ["lbl_work"],
            loop: {
              state: "active",
              startedAt: 1,
              wakeCount: 3,
              cadence: { everyMinutes: 60 },
            },
          },
          {
            ...taskInboxItem("task-event", "PR updates"),
            loop: {
              state: "paused",
              startedAt: 1,
              wakeCount: 2,
              cadence: { events: "new comments" },
            },
          },
          taskInboxItem("task-once", "One-off task"),
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    const { router } = renderTasksRoute(projection.controller, "/tasks", workLabels());
    await flush();
    const card = screen.getByRole("button", { name: /Morning digest/ });
    expect(
      [...card.querySelectorAll("[data-chip]")].map((chip) => chip.textContent)
    ).toEqual(["Scheduled", "Work"]);
    expect(
      within(screen.getByRole("button", { name: /PR updates/ })).getByTestId(
        "task-card-schedule"
      )
    ).toHaveTextContent("On updates");
    await user().click(within(card).getByTestId("task-card-schedule"));
    await flush();
    expect(router.state.location.search).toEqual({ schedule: "scheduled" });
    expect(screen.queryByText("One-off task")).toBeNull();
    expect(screen.queryByText("PR updates")).toBeNull();
    const filter = screen.getByRole("button", { name: "Filter tasks" });
    await user().click(filter);
    await user().click(
      within(screen.getByRole("menu", { name: "Filter tasks" })).getByRole("menuitem", {
        name: "Loops",
      })
    );
    const panel = await screen.findByRole("dialog", { name: "Loops" });
    const scheduled = within(panel).getByRole("menuitemcheckbox", {
      name: /^Scheduled/,
    });
    const event = within(panel).getByRole("menuitemcheckbox", {
      name: /^On updates/,
    });
    const noLoop = within(panel).getByRole("menuitemcheckbox", { name: /No loop/ });
    expect(event).toHaveTextContent("1 task");
    expect(event).toHaveAttribute("aria-checked", "false");
    await user().click(scheduled);
    await user().click(event);
    await flush();
    expect(router.state.location.search).toEqual({});
    expect(screen.queryByText("Morning digest")).toBeNull();
    expect(screen.getByText("PR updates")).toBeInTheDocument();
    expect(screen.queryByText("One-off task")).toBeNull();
    await user().click(scheduled);
    await user().click(noLoop);
    await flush();
    expect(screen.getByText("One-off task")).toBeInTheDocument();
    expect(screen.getByText("Morning digest")).toBeInTheDocument();
    expect(filter).toHaveAttribute("data-filtered", "false");
    await user().keyboard("{Escape}{Escape}");
    await user().click(
      within(screen.getByRole("button", { name: /PR updates/ })).getByTestId(
        "task-card-schedule"
      )
    );
    await flush();
    expect(router.state.location.search).toEqual({ schedule: "event_triggered" });
    expect(screen.queryByText("Morning digest")).toBeNull();
    expect(screen.getByText("PR updates")).toBeInTheDocument();
  });
});

/** The core's catalog of the test Group: one label, Work. */
function workLabels() {
  return labelsCore({
    catalog: labelCatalog({
      labels: [{ color: "blue", id: "lbl_work", name: "Work" }],
    }),
  });
}

function renderTasksRoute(
  productInboxController: CoreClient = createProductInboxProjectionHarness({
    initial: {
      errorCode: "utility_unavailable",
      items: [],
      source: "unavailable",
    },
  }).controller,
  initialEntry = "/tasks",
  // By default the core has not read the Group's label catalog.
  labels = labelsCore()
): { router: AnyRouter; unmount: () => void } {
  delegateScriptedCore(productInboxController, labels.client);
  const auth = createTestCommaAuthValue();
  const rootRoute = createRootRoute({
    component: () => (
      <CommaAuthContext.Provider value={auth}>
        <CoreProvider client={productInboxController}>
          <ChatProvider productLease={auth.productLease}>
            <Outlet />
          </ChatProvider>
        </CoreProvider>
      </CommaAuthContext.Provider>
    ),
  });
  const tasksRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks",
    component: TasksRoute,
    validateSearch: validateTasksSearch,
  });
  const taskDetailRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([tasksRoute, taskDetailRoute]),
    history: createMemoryHistory({ initialEntries: [initialEntry] }),
  });

  const { unmount } = render(<RouterProvider router={router} />);
  return { router, unmount };
}

function taskFixture(): TaskViewModel {
  return {
    activityStatus: "running",
    conversationId: "cnv_task_1",
    groupId: "grp_test",
    updatedAt: 1_700_000_000,
    id: "task_1",
    lastMessage: {
      content: "I am checking it now.",
      id: "msg_1",
      role: "assistant",
      roleLabel: "Comma",
    },
    messages: [
      {
        content: "I am checking it now.",
        id: "msg_1",
        role: "assistant",
        roleLabel: "Comma",
      },
    ],
    statusBucket: "in_progress",
    title: "Review task UI",
    workspaceId: "wsp_1",
  };
}

function taskInboxItem(conversationId: string, title: string) {
  return {
    conversationId,
    labels: [] as string[],
    id: `w1:${conversationId}`,
    kind: "agent_task" as const,
    source: "salix.conversation" as const,
    status: "running",
    title,
    updatedAt: 2_000,
    workspaceId: "w1",
    workspaceName: "My Workspace",
    groupId: "grp_test",
  };
}
