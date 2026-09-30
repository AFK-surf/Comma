import { render, screen } from "@comma/test-utils/render";
import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
} from "@tanstack/react-router";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { HomeConversationTargetBootstrap } from "../HomeConversationTargetBootstrap";

const harness = vi.hoisted(() => ({
  chatState: { status: "loading" } as
    | { status: "loading" }
    | { status: "hidden" }
    | {
        groupId: string;
        status: "provisioning";
        workspaceId: string;
        retryAfterSeconds: number;
      }
    | {
        groupId: string;
        status: "ready";
        workspaceId: string;
        conversation: {
          group_id: string;
          id: string;
          kind: "user_chat";
          status: string;
          title: string;
        };
      },
  homeConversationTarget: undefined as
    | { conversationId: string; groupId: string; workspaceId: string }
    | undefined,
  rememberHomeConversationTarget: vi.fn(),
  useWorkspaceChat: vi.fn(),
}));

vi.mock("../ChatProvider", () => ({
  useChatApi: () => ({}),
  useChatRegistry: () => ({
    rememberHomeConversationTarget: harness.rememberHomeConversationTarget,
  }),
  useHomeConversationTarget: () => harness.homeConversationTarget,
}));

vi.mock("../useWorkspaceChat", () => ({
  useWorkspaceChat: (...args: unknown[]) => {
    harness.useWorkspaceChat(...args);
    return { retry: vi.fn(), state: harness.chatState };
  },
}));

const routeProbe = () => <div data-testid="route-probe" />;

async function renderBootstrapAt(initialEntry: string) {
  const rootRoute = createRootRoute({
    component: () => (
      <>
        <HomeConversationTargetBootstrap />
        <Outlet />
      </>
    ),
  });
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    component: routeProbe,
  });
  const pluginsRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "plugins",
    component: routeProbe,
  });
  const settingsRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "settings",
    component: routeProbe,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([indexRoute, pluginsRoute, settingsRoute]),
    history: createMemoryHistory({ initialEntries: [initialEntry] }),
  });

  render(<RouterProvider router={router} />);
  await screen.findByTestId("route-probe");
}

describe("HomeConversationTargetBootstrap", () => {
  beforeEach(() => {
    harness.chatState = { status: "loading" };
    harness.homeConversationTarget = undefined;
    harness.rememberHomeConversationTarget.mockReset();
    harness.useWorkspaceChat.mockReset();
  });

  it("resolves and remembers the Home conversation target on a non-Home product route", async () => {
    harness.chatState = {
      conversation: {
        group_id: "grp_boot",
        id: "cnv_boot",
        kind: "user_chat",
        status: "active",
        title: "Workspace Chat",
      },
      groupId: "grp_boot",
      status: "ready",
      workspaceId: "wsp_boot",
    };

    await renderBootstrapAt("/plugins");

    expect(harness.useWorkspaceChat).toHaveBeenCalledWith(
      expect.objectContaining({ activateWorkspace: false })
    );
    expect(harness.rememberHomeConversationTarget).toHaveBeenCalledWith(
      "wsp_boot",
      "grp_boot",
      "cnv_boot",
      harness.chatState.conversation
    );
  });

  it("does not remember a target before the Workspace resolves ready", async () => {
    harness.chatState = {
      groupId: "grp_boot",
      retryAfterSeconds: 2,
      status: "provisioning",
      workspaceId: "wsp_boot",
    };

    await renderBootstrapAt("/plugins");

    expect(harness.useWorkspaceChat).toHaveBeenCalled();
    expect(harness.rememberHomeConversationTarget).not.toHaveBeenCalled();
  });

  it("stands down while Home is on screen", async () => {
    await renderBootstrapAt("/");

    expect(harness.useWorkspaceChat).not.toHaveBeenCalled();
    expect(harness.rememberHomeConversationTarget).not.toHaveBeenCalled();
  });

  it("stands down under the Settings overlay", async () => {
    await renderBootstrapAt("/settings");

    expect(harness.useWorkspaceChat).not.toHaveBeenCalled();
    expect(harness.rememberHomeConversationTarget).not.toHaveBeenCalled();
  });

  it("stands down once a target is already remembered", async () => {
    harness.homeConversationTarget = {
      conversationId: "cnv_kept",
      groupId: "grp_test",
      workspaceId: "wsp_kept",
    };

    await renderBootstrapAt("/plugins");

    expect(harness.useWorkspaceChat).not.toHaveBeenCalled();
    expect(harness.rememberHomeConversationTarget).not.toHaveBeenCalled();
  });
});
