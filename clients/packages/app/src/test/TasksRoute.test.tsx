import type { CoreClient } from "@comma/core-client";
import { CoreProvider } from "@comma/core-client";
import {
  createScriptedCore,
  delegateScriptedCore,
} from "@comma/test-utils/scripted-core";
import { advance, flush } from "@comma/test-utils/fake-clock";
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
import {
  ChatSidebarProvider,
  tasksSidebarHost,
  useChatSidebar,
} from "../components/chat-sidebar/ChatSidebarContext";
import { ChatProvider } from "../components/chat/ChatProvider";
import {
  TaskWorkspacePanel,
  TasksRoute,
  type TaskViewModel,
} from "../components/tasks/TasksRoute";
import { NewTaskDialogProvider } from "../components/tasks/station/NewTaskDialogContext";
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

  it("opens a still.fail chat at its page in still.fail, not inside the app", async () => {
    const id = "station:stillfail-dev_sf:12@st_b";
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        lastSyncedAt: 1_000,
        source: "live-sync",
        items: [
          {
            id,
            source: "station.chat",
            groupId: "grp_test",
            workspaceId: "w1",
            workspaceName: "My Workspace",
            conversationId: id,
            kind: "agent_task",
            labels: [],
            title: "Review the launch copy",
            status: "in_progress",
            updatedAt: 3_000,
            url: "https://still.fail/c/12",
            host: {
              station: "stillfail-dev_sf",
              thread: "12@st_b",
              machine: null,
              model: null,
              runtime: null,
            },
          },
        ],
        workspaces: [{ id: "w1", name: "My Workspace", group_id: "grp_test" }],
      },
    });
    const windowOpen = vi.spyOn(window, "open").mockImplementation(() => null);
    installNativeBridgeMock({ platform: "web" });
    const { router } = renderTasksRoute(projection.controller);
    await flush();
    const before = router.state.location.pathname;
    await user().click(screen.getByRole("button", { name: "Review the launch copy" }));
    await flush();
    expect(windowOpen).toHaveBeenCalledWith(
      "https://still.fail/c/12",
      "_blank",
      "noopener,noreferrer"
    );
    expect(router.state.location.pathname).toBe(before);
    windowOpen.mockRestore();
  });

  it("opens Monoid tasks in the right embedded browser on Electron desktop and exposes Open in browser in card menu", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("station:sf-1", "Review the launch copy"),
            status: "in_progress",
            updatedAt: 3_000,
            url: "https://app.monoid.zone/chats/sf-1",
            host: {
              station: "stillfail-dev_sf",
              thread: "12@st_b",
              machine: { name: "tokyo-mac-studio-0", online: true },
              model: "claude-opus-5-5",
              runtime: "claude",
            },
          },
        ],
        workspaces: [{ id: "w1", name: "My Workspace", group_id: "grp_test" }],
      },
    });
    const openExternal = vi.fn(async () => ({ ok: true as const }));
    installNativeBridgeMock({ platform: "electron", shell: { openExternal } });

    let latestSidebar: ReturnType<typeof useChatSidebar> | undefined;
    function SidebarProbe() {
      latestSidebar = useChatSidebar();
      return null;
    }

    delegateScriptedCore(projection.controller, labelsCore().client);
    const auth = createTestCommaAuthValue();
    const rootRoute = createRootRoute({
      component: () => (
        <CommaAuthContext.Provider value={auth}>
          <CoreProvider client={projection.controller}>
            <ChatProvider productLease={auth.productLease}>
              <ChatSidebarProvider>
                <NewTaskDialogProvider>
                  <SidebarProbe />
                  <Outlet />
                </NewTaskDialogProvider>
              </ChatSidebarProvider>
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
    const router = createRouter({
      routeTree: rootRoute.addChildren([tasksRoute]),
      history: createMemoryHistory({ initialEntries: ["/tasks"] }),
    });

    render(<RouterProvider router={router} />);
    await flush();

    // Clicking the Monoid card opens it in the right embedded browser (not external shell).
    const card = screen.getByRole("button", { name: "Review the launch copy" });
    await user().click(card);
    await flush();
    expect(openExternal).not.toHaveBeenCalled();
    expect(latestSidebar?.isOpen).toBe(true);
    expect(latestSidebar?.activeHost).toEqual(tasksSidebarHost);
    expect(latestSidebar?.activeSession?.activeSurface).toBe("browser");
    expect(latestSidebar?.activeSession?.browserPages[0]).toMatchObject({
      title: "Review the launch copy",
      url: "https://app.monoid.zone/chats/sf-1",
    });

    // Opening the card's context/more menu offers "Open in browser" to open externally.
    await user().click(screen.getByRole("button", { name: "Open in browser" }));
    await flush();
    await user().click(screen.getByRole("menuitem", { name: "Open in browser" }));
    await flush();
    expect(openExternal).toHaveBeenCalledWith({
      url: "https://app.monoid.zone/chats/sf-1",
    });
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

  it("narrows to Tasks from requests through a Request filter of their own", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          { ...taskInboxItem("task-asked", "Asked task"), origin: "task_request" },
          { ...taskInboxItem("task-comma", "Comma task"), origin: "comma" },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    // An older platform link to requests selects the Request filter.
    renderTasksRoute(
      projection.controller,
      "/tasks?platform=task_request",
      workLabels()
    );
    await flush();
    expect(screen.getByText("Asked task")).toBeInTheDocument();
    expect(screen.queryByText("Comma task")).toBeNull();

    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    expect(screen.getByRole("menuitem", { name: /Request/ })).toBeInTheDocument();
    await user().click(screen.getByRole("menuitem", { name: /Platform/ }));
    // Requests are no Platform of their own any more.
    expect(screen.queryByRole("checkbox", { name: /Request/ })).toBeNull();
  });

  it("lists each person whose request a Task came from in the Request filter", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("task-sam", "Sam task"),
            origin: "task_request",
            requestedBy: { id: "u_sam", name: "Sam" },
          },
          {
            ...taskInboxItem("task-sam-2", "Sam second task"),
            origin: "task_request",
            requestedBy: { id: "u_sam", name: "Sam" },
          },
          {
            ...taskInboxItem("task-rex", "Rex task"),
            origin: "task_request",
            requestedBy: { id: "u_rex", name: "Rex" },
          },
          { ...taskInboxItem("task-comma", "Comma task"), origin: "comma" },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    const { router } = renderTasksRoute(projection.controller, "/tasks", workLabels());
    await flush();
    // A card names whom its request came from by avatar and name, in place of the Request chip.
    const rexCard = screen.getByRole("button", { name: /Rex task/ });
    expect(within(rexCard).getByTestId("task-card-request")).toHaveTextContent(
      "From Rex"
    );
    expect(within(rexCard).queryByTestId("task-card-platform")).toBeNull();

    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    await user().click(screen.getByRole("menuitem", { name: /Request/ }));
    await flush();
    const people = screen
      .getAllByRole("menuitemcheckbox")
      .map((row) => row.textContent ?? "");
    // The senders by name under one heading, each with an avatar's initials, then the rest.
    expect(people).toEqual([
      expect.stringMatching(/^R.*Rex.*1/),
      expect.stringMatching(/^S.*Sam.*2/),
      expect.stringMatching(/Not from a request.*1/),
    ]);
    expect(screen.getByText("From a request")).toBeInTheDocument();

    await user().click(screen.getByRole("menuitemcheckbox", { name: /Rex/ }));
    await flush();
    expect(screen.queryByText("Rex task")).toBeNull();
    expect(screen.getByText("Sam task")).toBeInTheDocument();
    expect(screen.getByText("Comma task")).toBeInTheDocument();

    // A card's chip links to the Tasks its sender asked for.
    await act(() =>
      router.navigate({ search: { request: "from:u_rex" }, to: "/tasks" })
    );
    await flush();
    expect(screen.getByText("Rex task")).toBeInTheDocument();
    expect(screen.queryByText("Sam task")).toBeNull();
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

  it("filters Monoid station tasks via the Platform menu and ?platform=monoid deep link", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("monoid-1", "Deploy staging image"),
            url: "https://app.monoid.zone/chats/monoid-1",
            host: {
              station: "stn_1",
              thread: "CHAT/monoid-1",
              machine: { name: "tokyo-mac-studio-0", online: true },
              runtime: "claude",
              model: "claude-opus-5-5",
            },
          },
          {
            ...taskInboxItem("monoid-2", "Review PR #5655"),
            url: "https://app.monoid.zone/chats/monoid-2",
            host: {
              station: "stn_1",
              thread: "CHAT/monoid-2",
              machine: { name: "tokyo-mac-studio-0", online: true },
              runtime: "agy",
              model: "gemini-4-neon",
            },
          },
          {
            ...taskInboxItem("comma-1", "Draft weekly update"),
            origin: "comma",
          },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller, "/tasks?platform=monoid");
    await flush();

    // Deep link ?platform=monoid shows only Monoid tasks and keeps Monoid host chip.
    expect(screen.getByText("Deploy staging image")).toBeInTheDocument();
    expect(screen.getByText("Review PR #5655")).toBeInTheDocument();
    expect(screen.queryByText("Draft weekly update")).toBeNull();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "true"
    );

    // Platform filter submenu shows Monoid with count 2 and StillfailProviderLogo.
    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    await user().click(
      within(screen.getByRole("menu", { name: "Filter tasks" })).getByRole("menuitem", {
        name: "Platform",
      })
    );
    const panel = await screen.findByRole("dialog", { name: "Platform" });
    const monoidOption = within(panel).getByRole("menuitemcheckbox", {
      name: /^Monoid/,
    });
    expect(monoidOption).toHaveAttribute("aria-checked", "true");
    expect(monoidOption).toHaveTextContent("2");
    expect(
      monoidOption.querySelector('[data-provider-logo="stillfail"]')
    ).not.toBeNull();
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

  it("narrows by how recently Tasks were created and updated through the Dates menu", async () => {
    const day = 24 * 60 * 60 * 1_000;
    const now = Date.UTC(2026, 0, 15, 12);
    vi.setSystemTime(now);
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("fresh", "Fresh task"),
            createdAt: now - 2 * day,
            updatedAt: now - 2 * 60 * 60 * 1_000,
          },
          {
            ...taskInboxItem("week", "Last week's task"),
            createdAt: now - 40 * day,
            updatedAt: now - 5 * day,
          },
          // From a server that did not say when it was created.
          { ...taskInboxItem("old", "Old task"), updatedAt: now - 100 * day },
        ],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller);
    await flush();
    const reads = projection.refresh.mock.calls.length;

    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    await user().click(screen.getByRole("menuitem", { name: "Dates" }));
    await user().click(screen.getByRole("menuitem", { name: "Updated date" }));
    const updated = screen.getByRole("dialog", { name: "Updated date" });
    expect(
      within(updated)
        .getAllByRole("menuitemradio")
        .map((option) => option.textContent)
    ).toEqual([
      "All tasks3",
      "1 day ago1",
      "3 days ago1",
      "1 week ago2",
      "1 month ago2",
      "3 months ago2",
      "6 months ago3",
      "1 year ago3",
    ]);
    await user().click(
      within(updated).getByRole("menuitemradio", { name: /1 week ago/ })
    );
    await flush();
    expect(screen.getByText("Fresh task")).toBeInTheDocument();
    expect(screen.getByText("Last week's task")).toBeInTheDocument();
    expect(screen.queryByText("Old task")).toBeNull();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "true"
    );

    // Both dates must hold; a Task with no creation date is outside every window.
    await user().click(screen.getByRole("menuitem", { name: "Created date" }));
    const created = screen.getByRole("dialog", { name: "Created date" });
    await user().click(
      within(created).getByRole("menuitemradio", { name: /1 month ago/ })
    );
    await flush();
    expect(screen.getByText("Fresh task")).toBeInTheDocument();
    expect(screen.queryByText("Last week's task")).toBeNull();
    await user().click(
      within(created).getByRole("menuitemradio", { name: /All tasks/ })
    );
    // The pointer rests: React Aria stops guarding the way into the Created date panel.
    await advance(1_000);
    await user().click(screen.getByRole("menuitem", { name: "Updated date" }));
    await user().click(
      within(screen.getByRole("dialog", { name: "Updated date" })).getByRole(
        "menuitemradio",
        { name: /All tasks/ }
      )
    );
    await flush();
    expect(screen.getByText("Old task")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "false"
    );
    expect(projection.refresh.mock.calls.length).toBe(reads);
  });

  it("renders inline feed media via fileStream without eager taskFiles.list calls", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [taskInboxItem("conv-media-1", "Feed pagination latency benchmark")],
      },
    });
    const taskFilesList = vi.fn(async () => ({ status: "ready" as const, files: [] }));
    const feedCore = createScriptedCore({
      owns: (name) =>
        name === "taskFeed" ||
        name.startsWith("taskFeed.") ||
        name === "fileStream" ||
        name === "taskFiles.list",
      values: (topic) => {
        if (topic.topic === "taskFeed") {
          return {
            workspaceId: "w1",
            groupId: "grp_test",
            loaded: true,
            hasMore: false,
            source: "live-sync",
            entries: [
              {
                id: "entry-media-1",
                conversationId: "conv-media-1",
                groupId: "grp_test",
                clusterKey: "cluster-media-1",
                triggerKind: "brief",
                taskTitle: "Feed pagination latency benchmark",
                taskStatus: "ready_for_review",
                statusBucket: "needs_review",
                taskUpdatedAt: 1_700_000_000_000,
                occurredAt: 1_700_000_000_000,
                isLoop: false,
                milestones: [],
                milestoneCount: 0,
                outcomeText: "Cut p95 feed hydration latency by 57%.",
                media: [
                  {
                    attachmentId: "msg-rev-6:2",
                    mimeType: "image/png",
                    filename: "latency-flamegraph.png",
                  },
                ],
                files: [],
              },
              {
                id: "entry-plain-2",
                conversationId: "conv-plain-2",
                groupId: "grp_test",
                clusterKey: "cluster-plain-2",
                triggerKind: "brief",
                taskTitle: "Compact sidebar density",
                taskStatus: "completed",
                statusBucket: "done",
                taskUpdatedAt: 1_700_000_000_000,
                occurredAt: 1_700_000_000_000,
                isLoop: false,
                milestones: [],
                milestoneCount: 0,
                outcomeText: "Tightened collapsed sidebar spacing.",
                media: [],
                files: [],
              },
            ],
          };
        }
        if (topic.topic === "fileStream") {
          return { status: "ready", url: "blob:test-flamegraph" };
        }
        return undefined;
      },
      calls: async (name) => {
        if (name === "taskFiles.list") return taskFilesList();
        return undefined;
      },
    });
    const labels = labelsCore();
    delegateScriptedCore(feedCore.client, labels.client);
    installNativeBridgeMock({ platform: "electron" });

    renderTasksRoute(projection.controller, "/tasks?view=feed", {
      ...labels,
      client: feedCore.client,
    });
    await flush();

    const img = screen.getByRole("img", { name: "latency-flamegraph.png" });
    expect(img).toHaveAttribute("src", "blob:test-flamegraph");
    expect(taskFilesList).not.toHaveBeenCalled();
  });

  it("keeps the chosen view after the user opens a Task and returns to Tasks", async () => {
    const { router } = renderTasksRoute();
    await flush();
    expect(currentView()).toBe("board");

    await user().click(
      document.querySelector<HTMLElement>('[data-slot="task-view-action"]')!
    );
    await user().click(await screen.findByRole("menuitemradio", { name: "Feed" }));
    await flush();
    expect(currentView()).toBe("feed");

    await router.navigate({
      params: { conversationId: "cnv_1", groupId: "grp_test", workspaceId: "w1" },
      to: "/tasks/$workspaceId/$groupId/$conversationId",
    });
    await flush();
    expect(currentView()).toBeUndefined();

    await router.navigate({ to: "/tasks" });
    await flush();
    expect(currentView()).toBe("feed");
  });

  it("stays on Task Feed and refreshes feed after creating a new task via + New task", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [taskInboxItem("conv-existing", "Existing feed task")],
      },
    });
    const feedRefresh = vi.fn(async () => true);
    const startTask = vi.fn(async () => ({
      conversationId: "conv-new-ipo",
      groupId: "grp_test",
    }));
    const feedCore = createScriptedCore({
      owns: (name) =>
        name === "taskFeed" ||
        name.startsWith("taskFeed.") ||
        name === "chat.startTask" ||
        name === "stations" ||
        name === "models" ||
        name === "workspaces" ||
        name === "taskRequests.targets",
      values: (topic) => {
        if (topic.topic === "taskFeed") {
          return {
            workspaceId: "w1",
            groupId: "grp_test",
            loaded: true,
            hasMore: false,
            source: "live-sync",
            entries: [],
          };
        }
        if (topic.topic === "stations") return { loading: false, stations: [] };
        if (topic.topic === "models")
          return {
            models: [],
            profiles: [],
            agents: {
              task_model: { selection: { kind: "builtin" } },
              task_place: { sandboxes: false },
            },
          };
        if (topic.topic === "workspaces")
          return {
            workspaces: [{ id: "w1", group_id: "grp_test", name: "My Workspace" }],
          };
        if (topic.topic === "taskRequests.targets") return { targets: [] };
        return undefined;
      },
      calls: async (name) => {
        if (name === "taskFeed.refresh") return feedRefresh();
        if (name === "chat.startTask") return startTask();
        return undefined;
      },
    });
    const labels = labelsCore();
    delegateScriptedCore(feedCore.client, labels.client);
    installNativeBridgeMock({ platform: "electron" });

    const { router } = renderTasksRoute(projection.controller, "/tasks?view=feed", {
      ...labels,
      client: feedCore.client,
    });
    await flush();

    await user().click(screen.getByRole("button", { name: "New task" }));
    await flush();

    const textbox = screen.getByRole("textbox");
    await user().type(textbox, "查一下 anthropic 上市的新闻");
    await user().click(screen.getByRole("button", { name: "Create task" }));
    await flush();

    expect(startTask).toHaveBeenCalledOnce();
    expect(feedRefresh).toHaveBeenCalled();
    expect(router.state.location.pathname).toBe("/tasks");
  });

  it("applies section filters (Label) to Task Feed entries, updates Filtered pill, and preserves view=feed on deep-link edit", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [
          {
            ...taskInboxItem("conv-work", "Work feed task"),
            labels: ["lbl_work"],
          },
          taskInboxItem("conv-unlabeled", "Unlabeled feed task"),
        ],
      },
    });
    const feedCore = createScriptedCore({
      owns: (name) => name === "taskFeed" || name.startsWith("taskFeed."),
      values: (topic) => {
        if (topic.topic === "taskFeed") {
          return {
            workspaceId: "w1",
            groupId: "grp_test",
            loaded: true,
            hasMore: false,
            source: "live-sync",
            entries: [
              {
                id: "entry-work",
                conversationId: "conv-work",
                groupId: "grp_test",
                clusterKey: "cluster-work",
                triggerKind: "brief",
                taskTitle: "Work feed task",
                taskStatus: "ready_for_review",
                statusBucket: "needs_review",
                taskUpdatedAt: 1_700_000_000_000,
                occurredAt: 1_700_000_000_000,
                isLoop: false,
                milestones: [],
                milestoneCount: 0,
                outcomeText: "Labeled work outcome.",
                media: [],
                files: [],
              },
              {
                id: "entry-unlabeled",
                conversationId: "conv-unlabeled",
                groupId: "grp_test",
                clusterKey: "cluster-unlabeled",
                triggerKind: "brief",
                taskTitle: "Unlabeled feed task",
                taskStatus: "running",
                statusBucket: "in_progress",
                taskUpdatedAt: 1_700_000_000_000,
                occurredAt: 1_700_000_000_000,
                isLoop: false,
                milestones: [],
                milestoneCount: 0,
                outcomeText: "Unlabeled outcome.",
                media: [],
                files: [],
              },
            ],
          };
        }
        return undefined;
      },
    });
    const labels = workLabels();
    delegateScriptedCore(feedCore.client, labels.client);
    installNativeBridgeMock({ platform: "electron" });

    const { router } = renderTasksRoute(
      projection.controller,
      "/tasks?view=feed&label=lbl_work",
      {
        ...labels,
        client: feedCore.client,
      }
    );
    await flush();

    // Deep-linked label filter narrows Feed and displays Filtered tasks pill + active filter trigger.
    expect(screen.getByText("Filtered tasks")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "true"
    );
    expect(screen.getByText("Work feed task")).toBeInTheDocument();
    expect(screen.queryByText("Unlabeled feed task")).toBeNull();

    // Editing the filter clears label param while preserving view=feed.
    await user().click(screen.getByRole("button", { name: "Filter tasks" }));
    await user().click(
      within(screen.getByRole("menu", { name: "Filter tasks" })).getByRole("menuitem", {
        name: "Label",
      })
    );
    const labelDialog = await screen.findByRole("dialog", { name: "Label" });
    await user().click(
      within(labelDialog).getByRole("menuitemcheckbox", { name: /No label/ })
    );
    await flush();

    expect(router.state.location.search).toEqual({ view: "feed" });
    expect(screen.getByText("All tasks")).toBeInTheDocument();
    expect(screen.getByText("Work feed task")).toBeInTheDocument();
    expect(screen.getByText("Unlabeled feed task")).toBeInTheDocument();
  });

  it("exits skeleton and renders error state with retry button when taskFeed returns an error", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [],
      },
    });
    const feedRefresh = vi.fn(async () => {
      throw new Error("not_found");
    });
    const feedCore = createScriptedCore({
      owns: (name) => name === "taskFeed" || name.startsWith("taskFeed."),
      values: (topic) => {
        if (topic.topic === "taskFeed") {
          return {
            workspaceId: "w1",
            groupId: "grp_test",
            loaded: false,
            hasMore: false,
            source: "error",
            errorCode: "unknown",
            entries: [],
          };
        }
        return undefined;
      },
      calls: async (name) => {
        if (name === "taskFeed.refresh") return feedRefresh();
        return undefined;
      },
    });
    const labels = labelsCore();
    delegateScriptedCore(feedCore.client, labels.client);
    installNativeBridgeMock({ platform: "electron" });

    renderTasksRoute(projection.controller, "/tasks?view=feed", {
      ...labels,
      client: feedCore.client,
    });
    await flush();

    expect(document.querySelector('[data-slot="task-feed-loading"]')).toBeNull();
    const errorEl = document.querySelector('[data-slot="task-feed-error"]');
    expect(errorEl).not.toBeNull();
    expect(errorEl).toHaveTextContent(
      "Task updates could not be refreshed. Try again in a moment."
    );
    expect(errorEl?.textContent).not.toContain("ProductInbox");
    const retryButton = screen.getByRole("button", { name: "Retry" });
    expect(retryButton).toBeInTheDocument();
    await user().click(retryButton);
    await flush();
    expect(feedRefresh).toHaveBeenCalledOnce();
  });

  it("exits skeleton and renders error state when taskFeed topic subscription fails", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [],
      },
    });
    const feedCore = createScriptedCore({
      owns: (name) => name === "taskFeed" || name.startsWith("taskFeed."),
      values: (topic) => {
        if (topic.topic === "taskFeed") {
          return new Error("core utility unavailable");
        }
        return undefined;
      },
    });
    const labels = labelsCore();
    delegateScriptedCore(feedCore.client, labels.client);
    installNativeBridgeMock({ platform: "electron" });

    renderTasksRoute(projection.controller, "/tasks?view=feed", {
      ...labels,
      client: feedCore.client,
    });
    await flush();

    expect(document.querySelector('[data-slot="task-feed-loading"]')).toBeNull();
    const errorEl = document.querySelector('[data-slot="task-feed-error"]');
    expect(errorEl).not.toBeNull();
    expect(errorEl).toHaveTextContent(
      "Task updates could not be refreshed. Try again in a moment."
    );
    expect(errorEl?.textContent).not.toContain("ProductInbox");
  });

  it("warms taskFeed topic once on View menu open, throttles repeats, and renders Feed without skeleton", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [taskInboxItem("task-board-1", "Board task")],
      },
    });
    const feedSubscribes = vi.fn();
    const feedCore = createScriptedCore({
      owns: (name) => name === "taskFeed" || name.startsWith("taskFeed."),
      values: (topic) => {
        if (topic.topic === "taskFeed") {
          feedSubscribes(topic);
          return {
            workspaceId: "w1",
            groupId: "grp_test",
            loaded: true,
            hasMore: false,
            source: "live",
            entries: [
              {
                id: "tfe_warm",
                conversationId: "cnv_warm",
                groupId: "grp_test",
                clusterKey: "brief",
                triggerKind: "brief",
                taskTitle: "Warmed feed task",
                taskStatus: "ready_for_review",
                statusBucket: "needs_review",
                taskUpdatedAt: 2_000,
                origin: "comma",
                isLoop: false,
                occurredAt: 2_000,
                milestones: [],
                milestoneCount: 0,
                outcomeText: "Ready immediately from warm cache.",
                media: [],
                files: [],
              },
            ],
          };
        }
        return undefined;
      },
    });
    const labels = labelsCore();
    delegateScriptedCore(feedCore.client, labels.client);
    installNativeBridgeMock({ platform: "electron" });

    renderTasksRoute(projection.controller, "/tasks?view=board", {
      ...labels,
      client: feedCore.client,
    });
    await flush();

    expect(currentView()).toBe("board");
    expect(feedSubscribes).not.toHaveBeenCalled();

    const viewButton = document.querySelector<HTMLButtonElement>(
      '[data-slot="task-view-action"]'
    )!;
    await user().click(viewButton);
    await flush();
    expect(feedSubscribes).toHaveBeenCalledTimes(1);

    // Closing and reopening within 15s throttle window does not re-subscribe.
    await user().click(viewButton);
    await flush();
    await user().click(viewButton);
    await flush();
    expect(feedSubscribes).toHaveBeenCalledTimes(1);

    // Clicking Feed immediately hits the warmed client cache with no skeleton.
    let skeletonSeen = false;
    const observer = new MutationObserver(() => {
      if (document.querySelector('[data-slot="task-feed-loading"]')) {
        skeletonSeen = true;
      }
    });
    observer.observe(document.body, { childList: true, subtree: true });
    try {
      await user().click(screen.getByRole("menuitemradio", { name: "Feed" }));
      await flush();
    } finally {
      observer.disconnect();
    }

    expect(skeletonSeen).toBe(false);
    expect(document.querySelector('[data-slot="task-feed-loading"]')).toBeNull();
    expect(screen.getByText("Warmed feed task")).toBeInTheDocument();
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

function currentView() {
  return document
    .querySelector('[data-slot="task-view-action"]')
    ?.getAttribute("data-current-view");
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
            <NewTaskDialogProvider>
              <Outlet />
            </NewTaskDialogProvider>
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
