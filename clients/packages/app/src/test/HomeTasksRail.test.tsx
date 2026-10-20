import type { CoreClient } from "@comma/core-client";
import { CoreProvider } from "@comma/core-client";
import { delegateScriptedCore } from "@comma/test-utils/scripted-core";
import { advance, flush } from "@comma/test-utils/fake-clock";
import { labelCatalog, labelsCore } from "./labelsCore";
import userEvent from "@testing-library/user-event";
import { initializeCommaI18n } from "@comma/i18n";
import type { ProductInboxItem, ProductInboxListResult } from "@comma/core-client";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render } from "@comma/test-utils/render";
import { loadStatusIndicatorElement } from "@comma/ui/components/status-indicator";
import { motionDuration } from "@comma/ui/tokens";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { CommaAuthContext } from "../components/auth-context";
import { ChatProvider } from "../components/chat/ChatProvider";
import { HomeTasksRail } from "../components/home/HomeTasksRail";
import {
  createProductInboxProjectionHarness,
  createTestCommaAuthValue,
} from "./productInboxProjectionHarness";

// The status indicator registers its element on a dynamic import: real I/O
// that the test clock does not move. The tests load it first, as the stories do.
beforeAll(() => loadStatusIndicatorElement());

describe("HomeTasksRail", () => {
  afterEach(() => {
    initializeCommaI18n(["en"]);
    localStorage.clear();
  });

  it("wears the Tasks board's label and platform chips and opens the filtered board", async () => {
    const labels = labelsCore({
      catalog: labelCatalog({
        labels: [{ color: "blue", id: "lbl_work", name: "Work" }],
      }),
    });
    const projection = createProductInboxProjectionHarness({
      initial: liveResult([
        { ...taskItem("labeled", 1, "active"), origin: "slack", labels: ["lbl_work"] },
      ]),
    });
    installNativeBridgeMock({ platform: "electron" });
    const { router } = renderHomeTasksRail(projection.controller, labels);
    const card = () => currentCard()!;

    await flush();
    expect(card().querySelector('[data-testid="task-card-label"]')).toHaveTextContent(
      "Work"
    );
    expect(
      card().querySelector('[data-testid="task-card-platform"]')
    ).toHaveTextContent("Slack");

    await userEvent
      .setup({ advanceTimers: vi.advanceTimersByTime })
      .click(card().querySelector('[data-testid="task-card-label"]')!);
    await flush();

    expect(router.state.location.pathname).toBe("/tasks");
    expect(router.state.location.search).toEqual({ label: "lbl_work" });
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

      await flush();
      expect(document.querySelectorAll('[data-testid="home-task-card"]')).toHaveLength(
        1
      );

      act(() => {
        projection.emit(failedResult(source));
      });
      // The old check ran before the failed list reached the rail (it passed on the card still shown); once it
      // arrives, the rail shows no card until the list recovers.
      expect(
        document.querySelector('[data-testid="home-task-card"]')
      ).toHaveTextContent("Task first");
      await flush();
      expect(document.querySelectorAll('[data-testid="home-task-card"]')).toHaveLength(
        0
      );

      const secondTask = taskItem("second", 2);
      act(() => {
        projection.emit(liveResult([secondTask, firstTask]));
      });
      await flush();

      expect(document.querySelectorAll('[data-testid="home-task-card"]')).toHaveLength(
        2
      );
      expect(document.querySelector('[data-state="new"]')).toBeNull();

      // Once recovery establishes the new baseline, a later live arrival still
      // gets the intended entrance treatment.
      act(() => {
        projection.emit(liveResult([taskItem("third", 3), secondTask, firstTask]));
      });
      await flush();
      const fresh = document.querySelector('[data-state="new"]');
      expect(fresh).toHaveTextContent("Task third");
    }
  );

  // The first list a rail receives is a baseline, not an arrival, so nothing
  // follows it. Home opens on a status that holds work rather than the empty
  // default bucket (In progress), and the freshest Task is often the one that
  // just finished: opening on "done" would hide the one still waiting.
  it.each([
    {
      name: "opens on a status that holds tasks instead of the default bucket",
      items: () => [taskItem("review", 1, "ready_for_review")],
    },
    {
      name: "prefers a bucket that is still working over the archive",
      items: () => [
        taskItem("finished", 9, "completed"),
        taskItem("review", 2, "ready_for_review"),
      ],
    },
  ])("$name", async ({ items }) => {
    const projection = createProductInboxProjectionHarness({
      initial: liveResult(items()),
    });
    installNativeBridgeMock({ platform: "electron" });
    renderHomeTasksRail(projection.controller);

    await flush();
    expect(currentCard()).toHaveTextContent("Task review");
  });

  it("keeps a status the user picked, and takes the rail back on the next arrival", async () => {
    vi.setSystemTime(1_700_000_000_000);
    const finished = taskItem("finished", 1, "completed");
    const projection = createProductInboxProjectionHarness({
      initial: liveResult([finished]),
    });
    installNativeBridgeMock({ platform: "electron" });
    renderHomeTasksRail(projection.controller);

    await flush();
    expect(currentCard()).toHaveTextContent("Task finished");

    const indicator = document.querySelector("status-indicator");
    expect(indicator).not.toBeNull();
    act(() => {
      indicator!.dispatchEvent(
        new CustomEvent("change", { detail: { value: "cancel" } })
      );
    });
    await flush();

    // The user asked for an empty bucket. The rail says so and stays put, even
    // as the list underneath it changes.
    expect(document.body).toHaveTextContent("No tasks in this status");
    act(() => {
      projection.emit(liveResult([taskItem("finished", 4, "completed")]));
    });
    await flush();
    expect(currentCard()).toBeNull();

    // Past the manual hold, a live arrival is the rail's own signal again — and
    // hands the empty-bucket follow back with it.
    vi.setSystemTime(1_700_000_009_000);
    act(() => {
      projection.emit(liveResult([taskItem("created", 5, "active"), finished]));
    });
    await flush();
    expect(currentCard()).toHaveTextContent("Task created");

    act(() => {
      projection.emit(
        liveResult([taskItem("created", 6, "ready_for_review"), finished])
      );
    });
    // Past the leaving card's fade.
    await advance(motionDuration.feedbackOut);
    expect(
      document.querySelectorAll('[data-role="current"] [data-state="leaving"]')
    ).toHaveLength(0);
    expect(currentCard()).toHaveTextContent("Task created");
  });

  it("follows a task whose status leaves the visible bucket", async () => {
    const finished = taskItem("finished", 1, "completed");
    const projection = createProductInboxProjectionHarness({
      initial: liveResult([finished]),
    });
    installNativeBridgeMock({ platform: "electron" });
    renderHomeTasksRail(projection.controller);

    await flush();
    expect(currentCard()).toHaveTextContent("Task finished");

    // A Task created from the Comma assistant arrives active; the rail follows it.
    act(() => {
      projection.emit(liveResult([taskItem("created", 2, "active"), finished]));
    });
    await flush();
    expect(currentCard()).toHaveTextContent("Task created");

    // Minutes later the same Task moves on. Its id is not new, so nothing
    // follows it, and the bucket it left is empty. Wait past the leaving
    // card's fade, or the assertion passes on a card that is on its way out.
    act(() => {
      projection.emit(
        liveResult([taskItem("created", 3, "ready_for_review"), finished])
      );
    });
    await advance(motionDuration.feedbackOut);
    expect(
      document.querySelectorAll('[data-role="current"] [data-state="leaving"]')
    ).toHaveLength(0);
    expect(currentCard()).toHaveTextContent("Task created");
  });
});

/** The card in the live panel; null while the rail shows an empty state. */
function currentCard() {
  return document.querySelector('[data-role="current"] [data-testid="home-task-card"]');
}

/** The rail over the scripted task list, its labels from `labels` (by default a catalog the core has not read). */
function renderHomeTasksRail(controller: CoreClient, labels = labelsCore()) {
  delegateScriptedCore(controller, labels.client);
  const auth = createTestCommaAuthValue();
  const rootRoute = createRootRoute({
    component: () => (
      <CommaAuthContext.Provider value={auth}>
        <CoreProvider client={controller}>
          <ChatProvider productLease={auth.productLease}>
            <Outlet />
          </ChatProvider>
        </CoreProvider>
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
