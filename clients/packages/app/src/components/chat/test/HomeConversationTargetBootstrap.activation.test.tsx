import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { render, screen, waitFor } from "@comma/test-utils/render";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { CommaApiClient } from "../../../api";
import { testProductLease } from "../../../test/productInboxProjectionHarness";
import {
  readActiveWorkspaceId,
  subscribeActiveWorkspace,
  writeActiveWorkspaceId,
} from "../../activeWorkspace";
import { ChatProvider, useHomeConversationTarget } from "../ChatProvider";
import { HomeConversationTargetBootstrap } from "../HomeConversationTargetBootstrap";

// Integrated regression for the multi-Workspace reload scope bug: the
// route-independent bootstrap resolves the server's default Workspace, and an
// unguarded resolution used to call writeActiveWorkspaceId — flipping a
// multi-Workspace user's selected Workspace (and every active-Workspace
// subscriber, e.g. /tasks) to the default one after a renderer reload on a
// non-Home route. Real ChatProvider, bootstrap, useWorkspaceChat,
// localStorage, and subscriber; only the network api is faked.

function createApi(): CommaApiClient {
  return {
    bootstrapWorkspace: vi.fn(async () => ({
      status: "ready",
      workspace: {
        group_id: "grp_default",
        id: "wsp_default",
        name: "Default Workspace",
      },
    })),
    ensureGroupChat: vi.fn(async () => ({
      group_id: "grp_default",
      id: "cnv_default",
      kind: "user_chat",
      messages: [],
      status: "open",
      title: "Chat",
    })),
  } as unknown as CommaApiClient;
}

function TargetProbe() {
  const target = useHomeConversationTarget();
  return (
    <output aria-label="home-target">
      {target ? `${target.workspaceId}:${target.conversationId}` : "none"}
    </output>
  );
}

function renderBootstrapOnTasksRoute(api: CommaApiClient) {
  const rootRoute = createRootRoute({
    component: () => (
      <>
        <HomeConversationTargetBootstrap />
        <TargetProbe />
        <Outlet />
      </>
    ),
  });
  const tasksRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "tasks",
    component: () => <div data-testid="tasks-route" />,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([tasksRoute]),
    history: createMemoryHistory({ initialEntries: ["/tasks"] }),
  });

  render(
    <ChatProvider api={api} productLease={testProductLease} releaseDelayMs={0}>
      <RouterProvider router={router} />
    </ChatProvider>
  );
}

describe("HomeConversationTargetBootstrap Workspace activation", () => {
  beforeEach(() => {
    installNativeBridgeMock({ platform: "web" });
    localStorage.clear();
  });

  afterEach(() => {
    localStorage.clear();
  });

  it("remembers the Home conversation target without activating its Workspace", async () => {
    writeActiveWorkspaceId("wsp_selected");
    const activeWorkspaceChanges: (string | undefined)[] = [];
    const unsubscribe = subscribeActiveWorkspace((workspaceId) =>
      activeWorkspaceChanges.push(workspaceId)
    );

    try {
      renderBootstrapOnTasksRoute(createApi());

      await waitFor(() =>
        expect(screen.getByRole("status", { name: "home-target" })).toHaveTextContent(
          "wsp_default:cnv_default"
        )
      );
      expect(readActiveWorkspaceId()).toBe("wsp_selected");
      expect(activeWorkspaceChanges).toEqual([]);
    } finally {
      unsubscribe();
    }
  });
});
