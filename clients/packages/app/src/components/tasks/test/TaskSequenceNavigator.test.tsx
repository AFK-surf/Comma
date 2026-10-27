import { act, render, screen } from "@comma/test-utils/render";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  useParams,
} from "@tanstack/react-router";
import userEvent from "@testing-library/user-event";
import { useMemo, type ReactNode } from "react";
import { describe, expect, it, vi } from "vitest";
import type { ChatContextValue } from "../../chat/ChatProvider";
import { TaskSequenceNavigator } from "../TaskSequenceNavigator";
import {
  TaskSequenceSourceProvider,
  usePublishTaskSequence,
  type TaskSequenceEntry,
} from "../taskSequence";
import { openTaskTarget } from "../openTaskTarget";

// The core's read-ahead (chat.prepare) answers nothing; tests see what was asked for.
const prepare = vi.fn((..._args: unknown[]) => Promise.resolve(null));
const registry = {
  getRetainedSnapshot: () => undefined,
  productLease: { audience: "https://api.test", sessionId: "session-1" },
  rememberConversationSnapshot: vi.fn(),
  beginAttempt: () => ({
    run: (work: (signal: AbortSignal) => unknown) =>
      Promise.resolve(work(new AbortController().signal)),
    isCurrent: () => true,
    release: vi.fn(),
  }),
} as unknown as ChatContextValue;
let withRegistry = false;
vi.mock("../../chat/ChatProvider", async (original) => ({
  ...(await original<object>()),
  useOptionalChatRegistry: () => (withRegistry ? registry : null),
}));
vi.mock("@comma/core-client", async (original) => ({
  ...(await original<object>()),
  useCall: () => prepare,
}));
const prepared = () =>
  prepare.mock.calls.map(
    ([, params]) => (params as { conversationId: string }).conversationId
  );

const entries: TaskSequenceEntry[] = ["cnv_1", "cnv_2", "cnv_3"].map(
  (conversationId) => ({ conversationId, groupId: "grp_1", workspaceId: "wsp_1" })
);

function DetailPage() {
  const { conversationId } = useParams({ strict: false }) as {
    conversationId: string;
  };
  return <TaskSequenceNavigator conversationId={conversationId} />;
}

async function renderDetail(
  conversationId: string,
  { shell = (page: ReactNode) => page, fromList = true } = {}
) {
  const rootRoute = createRootRoute({ component: () => shell(<Outlet />) });
  const tasksRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks",
    component: () => null,
  });
  const detailRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: DetailPage,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([tasksRoute, detailRoute]),
    history: createMemoryHistory({ initialEntries: ["/tasks"] }),
  });
  render(<RouterProvider router={router} />);
  await act(() =>
    router.navigate({
      ...openTaskTarget({ conversationId, groupId: "grp_1", workspaceId: "wsp_1" }),
      ...(fromList ? { state: { taskSequence: entries } } : {}),
    })
  );
  return router;
}

describe("TaskSequenceNavigator", () => {
  it("steps through the Tasks page order it was opened from", async () => {
    const router = await renderDetail("cnv_2");

    expect(screen.getByTestId("task-sequence-position")).toHaveTextContent("2 / 3");

    await userEvent.click(screen.getByTestId("task-sequence-next"));
    expect(router.state.location.pathname).toBe("/tasks/wsp_1/grp_1/cnv_3");
    expect(screen.getByTestId("task-sequence-position")).toHaveTextContent("3 / 3");
    expect(screen.getByTestId("task-sequence-next")).toBeDisabled();

    await userEvent.keyboard("k");
    await userEvent.keyboard("k");
    expect(router.state.location.pathname).toBe("/tasks/wsp_1/grp_1/cnv_1");
    expect(screen.getByTestId("task-sequence-previous")).toBeDisabled();

    // Steps replace the entry: Back returns to the list, not the last Task.
    await act(async () => router.history.back());
    expect(router.state.location.pathname).toBe("/tasks");
  });

  it("leaves K and M to a text field", async () => {
    const router = await renderDetail("cnv_1", {
      shell: (page) => (
        <>
          <input aria-label="Draft" />
          {page}
        </>
      ),
    });

    await userEvent.type(screen.getByLabelText("Draft"), "mk");

    expect(screen.getByLabelText("Draft")).toHaveValue("mk");
    expect(router.state.location.pathname).toBe("/tasks/wsp_1/grp_1/cnv_1");
  });

  it("leaves K and M to an open menu or dialog", async () => {
    const router = await renderDetail("cnv_1", {
      shell: (page) => (
        <>
          <div role="menu">
            <button role="menuitem">Jump</button>
          </div>
          <dialog open>
            <button>Keep</button>
          </dialog>
          {page}
        </>
      ),
    });

    screen.getByRole("menuitem", { name: "Jump" }).focus();
    await userEvent.keyboard("m");
    screen.getByRole("button", { name: "Keep" }).focus();
    await userEvent.keyboard("m");

    expect(router.state.location.pathname).toBe("/tasks/wsp_1/grp_1/cnv_1");
  });

  it("shows nothing for a Task opened outside a list", async () => {
    await renderDetail("cnv_1", { fromList: false });

    expect(screen.queryByTestId("task-sequence")).toBeNull();
  });

  it("follows the live list beside it over the order it was opened from", async () => {
    const open = vi.fn();
    function Rail() {
      usePublishTaskSequence(
        useMemo(() => ({ entries: entries.toReversed(), open }), [])
      );
      return null;
    }
    await renderDetail("cnv_3", {
      shell: (page) => (
        <TaskSequenceSourceProvider>
          <Rail />
          {page}
        </TaskSequenceSourceProvider>
      ),
    });

    expect(screen.getByTestId("task-sequence-position")).toHaveTextContent("1 / 3");
    await userEvent.keyboard("m");
    expect(open).toHaveBeenCalledWith(1);
  });

  it("reads the next and previous Tasks ahead, so a step paints at once", async () => {
    withRegistry = true;
    prepare.mockClear();
    try {
      await renderDetail("cnv_1");
      await vi.waitFor(() => expect(prepared()).toEqual(["cnv_2"]));

      await userEvent.keyboard("m");
      await vi.waitFor(() => expect(prepared()).toContain("cnv_3"));
    } finally {
      withRegistry = false;
    }
  });
});
