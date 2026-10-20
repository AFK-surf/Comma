import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { createScriptedCore } from "@comma/test-utils/scripted-core";
import { render, screen, waitFor } from "@comma/test-utils/render";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { beforeEach, describe, expect, it } from "vitest";
import { testProductLease } from "../../../test/productInboxProjectionHarness";
import { ChatProvider, useHomeConversationTarget } from "../ChatProvider";
import { HomeConversationTargetBootstrap } from "../HomeConversationTargetBootstrap";

// Integrated regression for the multi-Workspace reload scope bug: the
// route-independent bootstrap resolves the server's default Workspace, and an
// unguarded resolution used to select its Workspace (`workspace.select`) —
// flipping a multi-Workspace user's selected Workspace (and every surface that
// follows it, e.g. /tasks) to the default one after a renderer reload on a
// non-Home route. Real ChatProvider, bootstrap and useWorkspaceChat; only the
// core is scripted.

function TargetProbe() {
  const target = useHomeConversationTarget();
  return (
    <output aria-label="home-target">
      {target ? `${target.workspaceId}:${target.conversationId}` : "none"}
    </output>
  );
}

function renderBootstrapOnTasksRoute() {
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

  // The core resolves the account's default Workspace Chat.
  const core = createScriptedCore({
    values: (topic) =>
      topic.topic === "workspaceChat"
        ? {
            status: "ready",
            chat: {
              conversationId: "cnv_default",
              groupId: "grp_default",
              workspaceId: "wsp_default",
            },
            kept: false,
          }
        : undefined,
  });
  render(
    core.wrap(
      <ChatProvider productLease={testProductLease}>
        <RouterProvider router={router} />
      </ChatProvider>
    )
  );
  return core;
}

describe("HomeConversationTargetBootstrap Workspace activation", () => {
  beforeEach(() => {
    installNativeBridgeMock({ platform: "web" });
  });

  it("remembers the Home conversation target without activating its Workspace", async () => {
    const core = renderBootstrapOnTasksRoute();

    await waitFor(() =>
      expect(screen.getByRole("status", { name: "home-target" })).toHaveTextContent(
        "wsp_default:cnv_default"
      )
    );
    expect(core.sentTo("workspace.select")).toEqual([]);
  });
});
