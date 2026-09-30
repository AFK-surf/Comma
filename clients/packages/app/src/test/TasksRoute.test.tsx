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
import type { ProductInboxListResult } from "@comma/native-bridge";
import { initializeCommaI18n } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import { controlIntersections } from "@comma/test-utils/intersection";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, waitFor, within } from "@comma/test-utils/render";
import { Toaster } from "@comma/ui";
import { taskStatusBucket } from "@comma/ui";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createCommaApi } from "../api";
import { CommaAuthContext } from "../components/auth-context";
import { ChatProvider } from "../components/chat/ChatProvider";
import {
  TaskWorkspacePanel,
  TasksRoute,
  type TaskViewModel,
} from "../components/tasks/TasksRoute";
import {
  ProductInboxProjectionProvider,
  type ProductInboxProjectionController,
} from "../product-inbox";
import {
  createProductInboxProjectionHarness,
  createTestCommaAuthValue,
  testProductLease,
} from "./productInboxProjectionHarness";

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
    await screen.findByText("Visible task");
    expect(screen.queryByText("Archived task title")).toBeNull();
    expect(screen.queryByText("Archived", { exact: true })).toBeNull();
  });
  afterEach(() => {
    initializeCommaI18n(["en"]);
    localStorage.clear();
    vi.unstubAllGlobals();
  });

  it("renders the empty task state without fabricating status sections", async () => {
    const { container } = render(
      <>
        <Toaster />
        <TaskWorkspacePanel capabilityState="planned" />
      </>
    );

    expect(screen.getByText("All tasks")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "List view" })).toBeInTheDocument();
    expect(container.querySelector('[data-slot="task-board-column"]')).toBeNull();
    expect(
      screen.getByText(
        "You can create tasks directly through the worker or use the Comma assistant to intelligently create and assign tasks."
      )
    ).toBeInTheDocument();
    expect(await screen.findByTestId("tasks-not-connected")).toHaveTextContent(
      "Task data is not connected yet. The board UI is ready."
    );
  });

  it.each([
    ["terminal", "done"],
    ["escalated", "needs_review"],
    ["ready_for_review", "needs_review"],
  ])("maps status %s to the %s display bucket", (status, bucket) => {
    expect(taskStatusBucket(status)).toBe(bucket);
  });

  it("switches to the complete task status list from the view panel", async () => {
    const user = userEvent.setup();
    render(<TaskWorkspacePanel tasks={[taskFixture()]} />);

    await user.click(screen.getByRole("button", { name: "List view" }));
    await user.click(screen.getByRole("menuitemradio", { name: "List" }));

    const list = screen.getByTestId("tasks-list");
    expect(within(list).getByText("In progress")).toBeInTheDocument();
    expect(within(list).getByText("Review task UI")).toBeInTheDocument();
    // Statuses holding no tasks get no group of their own.
    expect(within(list).queryByText("Backlog")).toBeNull();
    expect(within(list).queryByText("Needs Review")).toBeNull();
    expect(within(list).queryByText("No tasks")).toBeNull();
    expect(
      within(list).getByRole("button", { name: "Review task UI" })
    ).toHaveAttribute("data-slot", "task-list-item");
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

  it("keeps card selection and task chat as presentation interactions", async () => {
    const onCopyLink = vi.fn();
    const onExpand = vi.fn();
    const onSendMessage = vi.fn();
    const task = taskFixture();
    render(
      <TaskWorkspacePanel
        onCopyLink={onCopyLink}
        onExpand={onExpand}
        onSendMessage={onSendMessage}
        tasks={[task]}
      />
    );

    await userEvent.click(screen.getByRole("button", { name: task.title }));

    const taskChat = screen.getByRole("complementary", { name: "Task chat" });
    expect(taskChat).toBeVisible();
    expect(within(taskChat).getByText("I am checking it now.")).toBeVisible();
    await userEvent.click(screen.getByRole("button", { name: "Open task chat" }));
    await userEvent.click(screen.getByRole("button", { name: "Copy task link" }));
    await userEvent.type(screen.getByLabelText("Continue task"), "Looks good");
    await userEvent.click(screen.getByRole("button", { name: "Send message" }));

    expect(onExpand).toHaveBeenCalledWith(task);
    expect(onCopyLink).toHaveBeenCalledWith(task);
    expect(onSendMessage).toHaveBeenCalledWith(task, "Looks good");
  });

  it("disables unimplemented task detail actions", async () => {
    render(<TaskWorkspacePanel tasks={[taskFixture()]} />);

    await userEvent.click(screen.getByRole("button", { name: "Review task UI" }));

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
          freshness: "fresh",
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

    expect(await screen.findByText("Comma 本地聊天验收清单")).toBeInTheDocument();
    expect(screen.queryByText("Personal Chat")).toBeNull();
    expect(projection.retain).toHaveBeenCalledWith({ session: testProductLease });

    await userEvent.click(
      screen.getByRole("button", { name: "Comma 本地聊天验收清单" })
    );
    await expect
      .poll(() => router.state.location.pathname)
      .toBe("/tasks/w1/grp_test/task-1");
  });

  it("only exposes implemented production empty-state actions", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        items: [],
        source: "live-sync",
      },
    });
    installNativeBridgeMock({ platform: "electron" });

    const { unmount } = renderTasksRoute(projection.controller);

    expect(await screen.findByText("No tasks")).toBeVisible();
    expect(screen.queryByRole("button", { name: "Create new task" })).toBeNull();
    expect(screen.getByRole("button", { name: "Chat with Comma" })).toBeVisible();

    unmount();
  });

  it("keeps an initial desktop retention failure non-retryable until normal cleanup", async () => {
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

    expect(await screen.findByRole("heading", { name: "Error" })).toBeVisible();
    expect(screen.getByText("Task list unavailable")).toBeVisible();
    expect(
      screen.queryByText("Task could not be refreshed. Try again in a moment.")
    ).toBeNull();
    expect(screen.queryByRole("button", { name: "Try again" })).toBeNull();
    expect(projection.retain).toHaveBeenCalledOnce();
    expect(projection.retain).toHaveBeenCalledWith({ session: testProductLease });
    expect(projection.refresh).not.toHaveBeenCalled();
    expect(projection.release).not.toHaveBeenCalled();

    unmount();

    await vi.waitFor(() => {
      expect(projection.release).toHaveBeenCalledOnce();
    });
    expect(projection.release).toHaveBeenCalledWith({ session: testProductLease });
    expect(projection.retain).toHaveBeenCalledOnce();
    expect(projection.refresh).not.toHaveBeenCalled();
  });

  it("qualifies stale task status and treats cache-source tasks as stale", async () => {
    const result: ProductInboxListResult = {
      activeWorkspaceId: "w1",
      source: "cache",
      items: [
        {
          conversationId: "task-stale",
          freshness: "fresh",
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

    renderTasksRoute(projection.controller);

    const taskButton = await screen.findByRole("button", {
      name: /Cached running task.*Stale/i,
    });
    expect(taskButton).toHaveAttribute("data-freshness", "stale");
    expect(taskButton).toHaveTextContent("Stale");
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

      expect(await screen.findByText("First task")).toBeInTheDocument();
      const columnEnd = await waitFor(() => {
        const end = document.querySelector<HTMLElement>(
          '[data-slot="task-board-column"] [data-slot="scroll-area-load-more"]'
        );
        expect(end).not.toBeNull();
        return end!;
      });
      await act(async () => {});
      expect(projection.refresh.mock.calls.some(([input]) => input.cursor)).toBe(false);

      act(() => intersections.reveal(columnEnd));

      expect(await screen.findByText("Second task")).toBeInTheDocument();
      expect(projection.refresh).toHaveBeenCalledWith({
        cursor: "cursor-2",
        limit: 50,
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
    await screen.findByText("First task");
    await waitFor(() => expect(attempts).toBe(1));
    await act(async () => {
      failedPage.resolve({
        activeWorkspaceId: "w1",
        source: "cache",
        errorCode: "network_unavailable",
        items: [],
      });
    });
    expect(attempts).toBe(1);
    await userEvent.click(await screen.findByRole("button", { name: "Retry" }));
    await screen.findByText("Last task");
    expect(screen.getByText("First task")).toBeInTheDocument();
    expect(attempts).toBe(2);
    expect(projection.refresh).toHaveBeenLastCalledWith({
      cursor: "cursor-2",
      limit: 50,
      workspaceId: "w1",
      session: testProductLease,
    });
  });

  it("preserves loaded task pages across a Main-owned projection refresh", async () => {
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
    await screen.findByText("Initial first task");
    // No column scrolls (jsdom lays nothing out), so there is no end for the
    // reader to reach and the board pages on by itself.
    await screen.findByText("Loaded second task");

    projection.emit({
      ...firstPage,
      items: [taskInboxItem("task-1", "Refreshed first task")],
    });

    await screen.findByText("Refreshed first task");
    expect(screen.getByText("Loaded second task")).toBeInTheDocument();
    expect(
      screen.getByRole("button", { name: /Loaded second task.*Stale/i })
    ).toHaveAttribute("data-freshness", "stale");
    // The refreshed first page does not bring back a page past the last one.
    expect(
      projection.refresh.mock.calls.filter(([input]) => input.cursor)
    ).toHaveLength(1);
  });

  it("filters every loaded Task from its projected labels without another metadata read", async () => {
    stubGroupApi({
      labels: [{ color: "blue", id: "lbl_work", name: "Work" }],
    });
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
    renderTasksRoute(projection.controller, "/tasks?label=lbl_work");

    expect(await screen.findByText("Deep task")).toBeInTheDocument();
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
    await waitFor(() => expect(screen.queryByText("Deep task")).toBeNull());
    expect(screen.getByText("First task")).toBeInTheDocument();
  });

  it("does not count a deleted label's lingering id as a label", async () => {
    stubGroupApi({
      labels: [{ color: "blue", id: "lbl_work", name: "Work" }],
    });
    const projection = createProductInboxProjectionHarness({
      initial: {
        activeWorkspaceId: "w1",
        source: "live-sync",
        items: [{ ...taskInboxItem("task-stale", "Stale task"), labels: ["lbl_gone"] }],
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    renderTasksRoute(projection.controller, "/tasks?label=comma:no-label");

    // Only the deleted label's id is on it, so it is a Task with no label.
    expect(await screen.findByText("Stale task")).toBeInTheDocument();
  });

  it.each([
    ["status=done", "Done Mac task", "Active Windows task"],
    ["clientPlatform=macos", "Done Mac task", "Active Windows task"],
  ])(
    "narrows Tasks for %s and restores the list when cleared",
    async (query, shown, hidden) => {
      stubGroupApi({
        labels: [],
      });
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
      const { router } = renderTasksRoute(projection.controller, `/tasks?${query}`);
      expect(await screen.findByText(shown)).toBeInTheDocument();
      expect(screen.queryByText(hidden)).not.toBeInTheDocument();
      expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
        "data-filtered",
        "true"
      );
      await router.navigate({ search: {}, to: "/tasks" });
      expect(await screen.findByText(hidden)).toBeInTheDocument();
    }
  );

  it("narrows to a platform deep link and shows label and platform chips on cards", async () => {
    stubGroupApi({
      labels: [{ color: "blue", id: "lbl_work", name: "Work" }],
    });
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
    const { router } = renderTasksRoute(projection.controller, "/tasks?platform=slack");

    expect(await screen.findByText("Slack task")).toBeInTheDocument();
    expect(screen.queryByText("Comma task")).toBeNull();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "true"
    );
    const card = screen.getByRole("button", { name: /Slack task/ });
    expect(within(card).getByTestId("task-card-label")).toHaveTextContent("Work");
    expect(within(card).getByTestId("task-card-platform")).toHaveTextContent("Slack");

    // Leaving the deep link behind restores the whole list.
    await router.navigate({ search: {}, to: "/tasks" });

    expect(await screen.findByText("Comma task")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "false"
    );
  });

  it("opens the Tasks page narrowed to a label from a card chip", async () => {
    stubGroupApi({
      labels: [{ color: "blue", id: "lbl_work", name: "Work" }],
    });
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
    const { router } = renderTasksRoute(projection.controller);

    await screen.findByText("Plain task");
    await userEvent.click(await screen.findByTestId("task-card-label"));

    await expect
      .poll(() => router.state.location.search)
      .toEqual({ label: "lbl_work" });
    expect(router.state.location.pathname).toBe("/tasks");
    await vi.waitFor(() => expect(screen.queryByText("Plain task")).toBeNull());
    expect(screen.getByText("Labeled task")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Filter tasks" })).toHaveAttribute(
      "data-filtered",
      "true"
    );
  });
});

function json(body: unknown): Response {
  return new Response(JSON.stringify(body), {
    headers: { "content-type": "application/json" },
    status: 200,
  });
}

/** Label names and colors remain Group-owned. */
function stubGroupApi({
  labels,
}: {
  labels: { color: string; id: string; name: string }[];
}) {
  vi.stubGlobal(
    "fetch",
    vi.fn(async (input: RequestInfo | URL) => {
      const url = input instanceof Request ? input.url : String(input);
      if (url.includes("/v1/comma/groups/grp_test/task-labels")) {
        return json({ colors: [], labels, proposals: [] });
      }
      throw new TypeError(`Unexpected fetch: ${url}`);
    })
  );
}

function renderTasksRoute(
  productInboxController: ProductInboxProjectionController = createProductInboxProjectionHarness(
    {
      initial: {
        errorCode: "utility_unavailable",
        items: [],
        source: "unavailable",
      },
    }
  ).controller,
  initialEntry = "/tasks"
): { router: AnyRouter; unmount: () => void } {
  const api = createCommaApi({ baseUrl: "", token: "" });
  const auth = createTestCommaAuthValue();
  const rootRoute = createRootRoute({
    component: () => (
      <CommaAuthContext.Provider value={auth}>
        <ProductInboxProjectionProvider controller={productInboxController}>
          <ChatProvider api={api} productLease={auth.productLease}>
            <Outlet />
          </ChatProvider>
        </ProductInboxProjectionProvider>
      </CommaAuthContext.Provider>
    ),
  });
  const tasksRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks",
    component: TasksRoute,
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
    freshness: "fresh",
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
    freshness: "fresh" as const,
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
