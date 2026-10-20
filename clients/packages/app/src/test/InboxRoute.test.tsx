import type { CoreClient } from "@comma/core-client";
import { CoreProvider } from "@comma/core-client";
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
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { Toaster, toast } from "@comma/ui/components/toast";
import userEvent from "@testing-library/user-event";
import { useEffect } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { CommaConversation } from "@comma/core/api-schemas";
import { CommaAuthContext } from "../components/auth-context";
import {
  ChatProvider,
  type ChatRegistry,
  useChatRegistry,
} from "../components/chat/ChatProvider";
import { InboxRoute } from "../components/inbox/InboxRoute";
import {
  createProductInboxProjectionHarness,
  createTestCommaAuthValue,
} from "./productInboxProjectionHarness";

describe("InboxRoute (product inbox tracer bullet)", () => {
  afterEach(() => {
    toast.dismissAll();
    localStorage.clear();
    vi.unstubAllGlobals();
  });

  it("renders inbox items from the productInbox query leaf", async () => {
    const result: ProductInboxListResult = {
      source: "live-sync",
      lastSyncedAt: 1_000,
      items: [
        {
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
        },
      ],
    };
    const projection = createProductInboxProjectionHarness({
      initial: result,
    });
    installNativeBridgeMock({ platform: "electron" });

    renderInboxRoute(projection.controller);

    expect(await screen.findByText("Kickoff sync")).toBeInTheDocument();
    expect(screen.getByTestId("inbox-source")).toHaveAttribute(
      "data-source",
      "live-sync"
    );
  });

  it("keeps cached notifications interactive through sync recovery", async () => {
    const initial: ProductInboxListResult = {
      ...webInboxResult(),
      source: "cache",
      errorCode: "network_unavailable",
    };
    const projection = createProductInboxProjectionHarness({ initial });
    renderInboxRoute(projection.controller);

    const row = await screen.findByRole("link", { name: "Web kickoff" });
    const href = row.getAttribute("href");
    act(() => row.focus());
    expect(await screen.findByTestId("inbox-banner")).toHaveTextContent(
      "Showing local cache"
    );
    const refreshCount = projection.refresh.mock.calls.length;

    act(() => projection.emit(webInboxResult()));

    expect(screen.getByRole("link", { name: "Web kickoff" })).toBe(row);
    expect(row).toHaveFocus();
    expect(row).toHaveAttribute("href", href);
    await waitFor(() => expect(screen.queryByTestId("inbox-banner")).toBeNull());
    expect(projection.refresh).toHaveBeenCalledTimes(refreshCount);
  });

  it("shows a loaded page the core kept stale when it read the first page again", async () => {
    const firstPage: ProductInboxListResult = {
      activeWorkspaceId: "w1",
      hasMore: true,
      items: [productInboxItem("c1", "Initial first page")],
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
            items: [productInboxItem("c2", "Loaded second page")],
            source: "live-sync",
          };
        }
        return firstPage;
      },
    });
    installNativeBridgeMock({ platform: "electron" });

    renderInboxRoute(projection.controller);
    await screen.findByText("Initial first page");
    // The list end is in view (the shared jsdom observer reports every node
    // visible), so the next page loads without a request from the reader.
    await screen.findByText("Loaded second page");

    // The core reads the first page again and keeps the loaded tail, stale.
    projection.emit({
      activeWorkspaceId: "w1",
      hasMore: false,
      items: [
        productInboxItem("c1", "Refreshed first page"),
        { ...productInboxItem("c2", "Loaded second page"), freshness: "stale" },
      ],
      source: "live-sync",
    });

    await screen.findByText("Refreshed first page");
    expect(screen.getByText("Loaded second page")).toBeInTheDocument();
    expect(
      screen.getByRole("link", { name: /Loaded second page.*Stale/i })
    ).toHaveAttribute("data-freshness", "stale");
    // The refreshed first page does not bring back a page past the last one.
    expect(listLoadTrigger()).toBeNull();
  });

  it("surfaces the typed ProductInbox error semantics", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: {
        errorCode: "network_unavailable",
        items: [],
        source: "error",
      },
    });
    installNativeBridgeMock({ platform: "electron" });

    renderInboxRoute(projection.controller);

    expect(await screen.findByTestId("inbox-banner")).toHaveTextContent(
      "could not reach the ProductInbox authority"
    );
  });

  it("renders web inbox rows through the shared client projection", async () => {
    installNativeBridgeMock({ platform: "web" });
    const projection = createProductInboxProjectionHarness({
      initial: webInboxResult(),
    });

    renderInboxRoute(projection.controller);

    expect(await screen.findByText("Web kickoff")).toBeInTheDocument();
    expect(screen.getByTestId("inbox-source")).toHaveAttribute(
      "data-source",
      "live-sync"
    );
    expect(projection.retain).toHaveBeenCalledOnce();
  });

  it("keeps notifications sourced from the host when the home Chat initializes", async () => {
    const projection = createProductInboxProjectionHarness({
      initial: { ...webInboxResult(), items: [] },
    });
    const conversation = workspaceChatConversation();
    let registry: ChatRegistry | undefined;

    renderInboxRoute(projection.controller, (value) => {
      registry = value;
    });

    expect(await screen.findByText("No notifications")).toBeInTheDocument();
    const refreshCount = projection.refresh.mock.calls.length;
    act(() => {
      registry?.rememberHomeConversationTarget(
        "ws-web",
        conversation.group_id,
        conversation.id,
        conversation
      );
    });

    expect(screen.getByText("No notifications")).toBeInTheDocument();
    expect(screen.queryByTestId("inbox-item")).toBeNull();
    expect(projection.refresh).toHaveBeenCalledTimes(refreshCount);
  });

  it("lists the selected web workspace chosen from the filter menu", async () => {
    const initial = {
      ...webInboxResult(),
      workspaces: [
        { group_id: "grp-web", id: "ws-web", name: "Web Workspace" },
        { group_id: "grp-other", id: "ws-other", name: "Other Workspace" },
      ],
    } satisfies ProductInboxListResult;
    const projection = createProductInboxProjectionHarness({
      initial,
      refresh: (input) =>
        input.workspaceId === "ws-other"
          ? {
              activeWorkspaceId: "ws-other",
              items: [
                {
                  ...productInboxItem("conv-other-1", "Other kickoff"),
                  groupId: "grp-other",
                  id: "ws-other:conv-other-1",
                  workspaceId: "ws-other",
                  workspaceName: "Other Workspace",
                },
              ],
              source: "live-sync",
            }
          : initial,
    });
    installNativeBridgeMock({ platform: "web" });

    renderInboxRoute(projection.controller);

    expect(await screen.findByText("Web kickoff")).toBeInTheDocument();
    // userEvent, not fireEvent: React Aria's submenu trigger opens on the full
    // pointer sequence, and a bare click event leaves it closed under load.
    await userEvent.click(await screen.findByTestId("inbox-filter-trigger"));
    await userEvent.click(await screen.findByRole("menuitem", { name: /Workspace/ }));
    await userEvent.click(
      await screen.findByRole("menuitemradio", { name: "Other Workspace" })
    );

    expect(
      await screen.findByText("Other kickoff", undefined, { timeout: 5_000 })
    ).toBeInTheDocument();
    expect(projection.refresh).toHaveBeenCalledWith(
      expect.objectContaining({ workspaceId: "ws-other" })
    );
  }, 20_000);
});

function renderInboxRoute(
  productInboxController: CoreClient = createProductInboxProjectionHarness({
    initial: {
      errorCode: "utility_unavailable",
      items: [],
      source: "unavailable",
    },
  }).controller,
  captureChatRegistry?: (registry: ChatRegistry) => void
): AnyRouter {
  const auth = createTestCommaAuthValue();
  const rootRoute = createRootRoute({
    component: () => (
      <CommaAuthContext.Provider value={auth}>
        <CoreProvider client={productInboxController}>
          <ChatProvider productLease={auth.productLease}>
            {captureChatRegistry ? (
              <ChatRegistryCapture capture={captureChatRegistry} />
            ) : null}
            <Outlet />
          </ChatProvider>
        </CoreProvider>
      </CommaAuthContext.Provider>
    ),
  });
  const inboxRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    component: InboxRoute,
  });
  const conversationRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/inbox/$workspaceId/$groupId/$conversationId",
    component: () => null,
  });
  const router = createRouter({
    routeTree: rootRoute.addChildren([inboxRoute, conversationRoute]),
    history: createMemoryHistory({ initialEntries: ["/"] }),
  });

  render(
    <>
      <RouterProvider router={router} />
      <Toaster />
    </>
  );
  return router;
}

function ChatRegistryCapture({
  capture,
}: {
  capture: (registry: ChatRegistry) => void;
}) {
  const registry = useChatRegistry();
  useEffect(() => {
    capture(registry);
  }, [capture, registry]);
  return null;
}

/** The end of the rail, which loads the next page as it comes into view. */
function listLoadTrigger() {
  return document.querySelector<HTMLElement>('[data-slot="scroll-area-load-more"]');
}

function productInboxItem(conversationId: string, title: string) {
  return {
    conversationId,
    freshness: "fresh" as const,
    id: `w1:${conversationId}`,
    kind: "user_chat" as const,
    source: "salix.conversation" as const,
    status: "open",
    title,
    updatedAt: 1_000,
    workspaceId: "w1",
    workspaceName: "Acme",
    groupId: "grp_test",
  };
}

function webInboxResult(): ProductInboxListResult {
  return {
    activeWorkspaceId: "ws-web",
    items: [
      {
        conversationId: "conv-web-1",
        groupId: "grp-web",
        id: "ws-web:conv-web-1",
        kind: "user_chat",
        source: "salix.conversation",
        status: "open",
        title: "Web kickoff",
        updatedAt: 1_000,
        workspaceId: "ws-web",
        workspaceName: "Web Workspace",
      },
    ],
    source: "live-sync",
    workspaces: [{ group_id: "grp-web", id: "ws-web", name: "Web Workspace" }],
  };
}

function workspaceChatConversation(): CommaConversation {
  return {
    group_id: "grp-web",
    id: "chat-web",
    kind: "user_chat",
    status: "active",
    title: "Workspace Chat",
    updated_at: 2_000,
  };
}
