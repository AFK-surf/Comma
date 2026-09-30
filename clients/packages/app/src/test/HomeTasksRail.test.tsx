import userEvent from "@testing-library/user-event";
import { initializeCommaI18n } from "@comma/i18n";
import type { ProductInboxItem, ProductInboxListResult } from "@comma/native-bridge";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, waitFor } from "@comma/test-utils/render";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createCommaApi } from "../api";
import { CommaAuthContext } from "../components/auth-context";
import { ChatProvider } from "../components/chat/ChatProvider";
import { HomeTasksRail } from "../components/home/HomeTasksRail";
import {
  ProductInboxProjectionProvider,
  type ProductInboxProjectionController,
} from "../product-inbox";
import {
  createProductInboxProjectionHarness,
  createTestCommaAuthValue,
} from "./productInboxProjectionHarness";

function body(value: unknown): Response {
  return new Response(JSON.stringify(value), {
    headers: { "content-type": "application/json" },
    status: 200,
  });
}

describe("HomeTasksRail", () => {
  afterEach(() => {
    initializeCommaI18n(["en"]);
    localStorage.clear();
    vi.unstubAllGlobals();
  });

  it("wears the Tasks board's label and platform chips and opens the filtered board", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async (input: RequestInfo | URL) => {
        const url = input instanceof Request ? input.url : String(input);
        if (url.includes("/v1/comma/groups/grp_test/task-labels")) {
          return body({
            colors: [],
            labels: [{ color: "blue", id: "lbl_work", name: "Work" }],
            proposals: [],
          });
        }
        throw new TypeError(`Unexpected fetch: ${url}`);
      })
    );
    const projection = createProductInboxProjectionHarness({
      initial: liveResult([
        { ...taskItem("labeled", 1, "active"), origin: "slack", labels: ["lbl_work"] },
      ]),
    });
    installNativeBridgeMock({ platform: "electron" });
    const { router } = renderHomeTasksRail(projection.controller);
    const card = () => currentCard()!;

    await waitFor(() => {
      expect(card().querySelector('[data-testid="task-card-label"]')).toHaveTextContent(
        "Work"
      );
    });
    expect(
      card().querySelector('[data-testid="task-card-platform"]')
    ).toHaveTextContent("Slack");

    await userEvent.click(card().querySelector('[data-testid="task-card-label"]')!);

    await waitFor(() => {
      expect(router.state.location.pathname).toBe("/tasks");
      expect(router.state.location.search).toEqual({ label: "lbl_work" });
    });
  });

  it.each(["error", "unavailable"] as const)(
    "rebaselines task arrivals after an %s projection",
    async (source) => {
      const firstTask = taskItem("first", 1);
      const projection = createProductInboxProjectionHarness({
        initial: liveResult([firstTask]),
      });
      installNativeBridgeMock({ platform: "electron" });
      renderHomeTasksRail(projection.controller);

      await waitFor(() => {
        expect(
          document.querySelectorAll('[data-testid="home-task-card"]')
        ).toHaveLength(1);
      });

      act(() => {
        projection.emit(failedResult(source));
      });
      await waitFor(() => {
        expect(
          document.querySelector('[data-testid="home-task-card"]')
        ).toHaveTextContent("Task first");
      });

      const secondTask = taskItem("second", 2);
      act(() => {
        projection.emit(liveResult([secondTask, firstTask]));
      });

      await waitFor(() => {
        expect(
          document.querySelectorAll('[data-testid="home-task-card"]')
        ).toHaveLength(2);
      });
      expect(document.querySelector('[data-state="new"]')).toBeNull();

      // Once recovery establishes the new baseline, a later live arrival still
      // gets the intended entrance treatment.
      act(() => {
        projection.emit(liveResult([taskItem("third", 3), secondTask, firstTask]));
      });
      await waitFor(() => {
        const fresh = document.querySelector('[data-state="new"]');
        expect(fresh).toHaveTextContent("Task third");
      });
    }
  );

  // The first list a rail receives is a baseline, not an arrival, so nothing
  // follows it. Home opens on a status that holds work rather than the empty
  // default bucket, and the freshest Task is often the one that just finished:
  // opening on "done" would hide the one still running.
  it.each([
    {
      name: "opens on a status that holds tasks instead of the default bucket",
      items: () => [taskItem("running", 1, "active")],
    },
    {
      name: "prefers a bucket that is still working over the archive",
      items: () => [
        taskItem("finished", 9, "completed"),
        taskItem("running", 2, "active"),
      ],
    },
  ])("$name", async ({ items }) => {
    const projection = createProductInboxProjectionHarness({
      initial: liveResult(items()),
    });
    installNativeBridgeMock({ platform: "electron" });
    renderHomeTasksRail(projection.controller);

    await waitFor(() => {
      expect(currentCard()).toHaveTextContent("Task running");
    });
  });

  it("keeps a status the user picked, and takes the rail back on the next arrival", async () => {
    const now = vi.spyOn(Date, "now");
    now.mockReturnValue(1_700_000_000_000);
    const backlog = taskItem("backlog", 1);
    const projection = createProductInboxProjectionHarness({
      initial: liveResult([backlog]),
    });
    installNativeBridgeMock({ platform: "electron" });
    renderHomeTasksRail(projection.controller);

    await waitFor(() => {
      expect(currentCard()).toHaveTextContent("Task backlog");
    });

    const indicator = await waitFor(() => {
      const element = document.querySelector("status-indicator");
      expect(element).not.toBeNull();
      return element!;
    });
    act(() => {
      indicator.dispatchEvent(
        new CustomEvent("change", { detail: { value: "cancel" } })
      );
    });

    // The user asked for an empty bucket. The rail says so and stays put, even
    // as the list underneath it changes.
    await waitFor(() => {
      expect(document.body).toHaveTextContent("No tasks in this status");
    });
    act(() => {
      projection.emit(liveResult([taskItem("backlog", 4)]));
    });
    await waitFor(() => {
      expect(currentCard()).toBeNull();
    });

    // Past the manual hold, a live arrival is the rail's own signal again — and
    // hands the empty-bucket follow back with it.
    now.mockReturnValue(1_700_000_009_000);
    act(() => {
      projection.emit(liveResult([taskItem("created", 5, "active"), backlog]));
    });
    await waitFor(() => {
      expect(currentCard()).toHaveTextContent("Task created");
    });

    act(() => {
      projection.emit(
        liveResult([taskItem("created", 6, "ready_for_review"), backlog])
      );
    });
    await waitFor(() => {
      expect(
        document.querySelectorAll('[data-role="current"] [data-state="leaving"]')
      ).toHaveLength(0);
      expect(currentCard()).toHaveTextContent("Task created");
    });
    now.mockRestore();
  });

  it("follows a task whose status leaves the visible bucket", async () => {
    const backlog = taskItem("backlog", 1);
    const projection = createProductInboxProjectionHarness({
      initial: liveResult([backlog]),
    });
    installNativeBridgeMock({ platform: "electron" });
    renderHomeTasksRail(projection.controller);

    await waitFor(() => {
      expect(currentCard()).toHaveTextContent("Task backlog");
    });

    // A Task created from the Comma assistant arrives active; the rail follows it.
    act(() => {
      projection.emit(liveResult([taskItem("created", 2, "active"), backlog]));
    });
    await waitFor(() => {
      expect(currentCard()).toHaveTextContent("Task created");
    });

    // Minutes later the same Task moves on. Its id is not new, so nothing
    // follows it, and the bucket it left is empty. Wait past the leaving
    // card's fade, or the assertion passes on a card that is on its way out.
    act(() => {
      projection.emit(
        liveResult([taskItem("created", 3, "ready_for_review"), backlog])
      );
    });
    await waitFor(() => {
      expect(
        document.querySelectorAll('[data-role="current"] [data-state="leaving"]')
      ).toHaveLength(0);
      expect(currentCard()).toHaveTextContent("Task created");
    });
  });
});

/** The card in the live panel; null while the rail shows an empty state. */
function currentCard() {
  return document.querySelector('[data-role="current"] [data-testid="home-task-card"]');
}

function renderHomeTasksRail(controller: ProductInboxProjectionController) {
  const api = createCommaApi({ baseUrl: "", token: "" });
  const auth = createTestCommaAuthValue();
  const rootRoute = createRootRoute({
    component: () => (
      <CommaAuthContext.Provider value={auth}>
        <ProductInboxProjectionProvider controller={controller}>
          <ChatProvider api={api} productLease={auth.productLease}>
            <Outlet />
          </ChatProvider>
        </ProductInboxProjectionProvider>
      </CommaAuthContext.Provider>
    ),
  });
  const homeRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    component: HomeTasksRail,
  });
  const tasksRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks",
    component: () => null,
  });
  const taskDetailRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([homeRoute, tasksRoute, taskDetailRoute]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });

  return { ...render(<RouterProvider router={router} />), router };
}

function liveResult(items: ProductInboxItem[]): ProductInboxListResult {
  return {
    activeWorkspaceId: "workspace-1",
    items,
    source: "live-sync",
  };
}

function failedResult(source: "error" | "unavailable"): ProductInboxListResult {
  return {
    activeWorkspaceId: "workspace-1",
    errorCode: source === "error" ? "network_unavailable" : "utility_unavailable",
    items: [],
    source,
  };
}

function taskItem(id: string, updatedAt: number, status = "queued"): ProductInboxItem {
  return {
    conversationId: `conversation-${id}`,
    freshness: "fresh",
    id,
    kind: "agent_task",
    source: "salix.conversation",
    status,
    title: `Task ${id}`,
    updatedAt,
    workspaceId: "workspace-1",
    workspaceName: "Workspace",
    groupId: "grp_test",
  };
}
