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
import { controlIntersections } from "@comma/test-utils/intersection";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, render, screen, waitFor } from "@comma/test-utils/render";
import { Toaster, toast } from "@comma/ui";
import userEvent from "@testing-library/user-event";
import { useEffect } from "react";
import { afterEach, describe, expect, it, vi } from "vitest";
import { createCommaApi, type CommaConversation } from "../api";
import { CommaAuthContext } from "../components/auth-context";
import {
  ChatProvider,
  type ChatRegistry,
  useChatRegistry,
} from "../components/chat/ChatProvider";
import { InboxRoute } from "../components/inbox/InboxRoute";
import {
  appendProductInboxPages as appendInboxPages,
  combineProductInboxPages as combineInboxPages,
  ProductInboxProjectionProvider,
  refreshProductInboxPages as refreshInboxPages,
  type ProductInboxProjectionController,
} from "../product-inbox";
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

  it("loads the next inbox page when the end of the list comes into view, not before", async () => {
    const firstPage = {
      activeWorkspaceId: "w1",
      hasMore: true,
      items: [productInboxItem("c1", "First page")],
      nextCursor: "cursor-2",
      source: "live-sync",
    } satisfies ProductInboxListResult;
    const secondPage = {
      activeWorkspaceId: "w1",
      hasMore: false,
      items: [productInboxItem("c2", "Second page")],
      source: "live-sync",
    } satisfies ProductInboxListResult;
    const projection = createProductInboxProjectionHarness({
      initial: firstPage,
      refresh: (input) => (input.cursor ? secondPage : firstPage),
    });
    installNativeBridgeMock({ platform: "electron" });
    const intersections = controlIntersections();
    try {
      renderInboxRoute(projection.controller);

      expect(await screen.findByText("First page")).toBeInTheDocument();
      const listEnd = await waitFor(() => {
        const end = listLoadTrigger();
        expect(end).not.toBeNull();
        return end!;
      });
      await act(async () => {});
      expect(projection.refresh.mock.calls.some(([input]) => input.cursor)).toBe(false);

      act(() => intersections.reveal(listEnd));

      expect(await screen.findByText("Second page")).toBeInTheDocument();
      expect(projection.refresh).toHaveBeenCalledWith({
        cursor: "cursor-2",
        limit: 50,
        session: expect.any(Object),
        workspaceId: "w1",
      });
      expect(
        projection.refresh.mock.calls.filter(([input]) => input.cursor)
      ).toHaveLength(1);
      expect(listLoadTrigger()).toBeNull();
    } finally {
      intersections.restore();
    }
  });

  it("keeps loaded rows and retries the same page after a cache fallback", async () => {
    const firstPage: ProductInboxListResult = {
      activeWorkspaceId: "w1",
      hasMore: true,
      items: [productInboxItem("c1", "First page")],
      nextCursor: "cursor-2",
      source: "live-sync",
    };
    const page = Promise.withResolvers<ProductInboxListResult>();
    let attempts = 0;
    const projection = createProductInboxProjectionHarness({
      initial: firstPage,
      refresh: (input) => {
        if (!input.cursor) return firstPage;
        attempts += 1;
        return attempts === 1
          ? page.promise
          : {
              activeWorkspaceId: "w1",
              hasMore: false,
              items: [productInboxItem("c2", "Last page")],
              source: "live-sync",
            };
      },
    });
    installNativeBridgeMock({ platform: "electron" });
    const intersections = controlIntersections();
    try {
      renderInboxRoute(projection.controller);
      await screen.findByText("First page");
      act(() => intersections.reveal(listLoadTrigger()!));
      await waitFor(() => expect(attempts).toBe(1));
      expect(screen.queryByRole("status", { name: "Loading…" })).toBeNull();
      expect(screen.getByRole("link", { name: /First page/ })).toBeEnabled();
      await act(async () => {
        page.resolve({
          activeWorkspaceId: "w1",
          errorCode: "network_unavailable",
          items: [],
          source: "cache",
        });
      });
      const retry = await screen.findByRole("button", { name: "Retry" });
      expect(screen.getByText("First page")).toBeInTheDocument();
      act(() => intersections.reveal(listLoadTrigger()!));
      expect(attempts).toBe(1);
      await userEvent.click(retry);
      await screen.findByText("Last page");
      expect(screen.getByText("First page")).toBeInTheDocument();
      expect(attempts).toBe(2);
      expect(listLoadTrigger()).toBeNull();
      await waitFor(() =>
        expect(screen.queryByTestId("inbox-load-more-error")).toBeNull()
      );
    } finally {
      intersections.restore();
    }
  });

  it("preserves loaded desktop pages across a Main-owned projection refresh", async () => {
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

    projection.emit({
      ...firstPage,
      items: [productInboxItem("c1", "Refreshed first page")],
    });

    await screen.findByText("Refreshed first page");
    expect(screen.getByText("Loaded second page")).toBeInTheDocument();
    expect(
      screen.getByRole("link", { name: /Loaded second page.*Stale/i })
    ).toHaveAttribute("data-freshness", "stale");
    // The refreshed first page does not bring back a page past the last one.
    expect(listLoadTrigger()).toBeNull();
  });

  it("clears terminal cursor metadata when appending the last page", () => {
    const firstPage = {
      activeWorkspaceId: "w1",
      hasMore: true,
      items: [productInboxItem("c1", "First page")],
      nextCursor: "cursor-2",
      source: "live-sync",
    } satisfies ProductInboxListResult;
    const lastPage = {
      activeWorkspaceId: "w1",
      hasMore: false,
      items: [productInboxItem("c2", "Last page")],
      source: "live-sync",
    } satisfies ProductInboxListResult;

    const combined = combineInboxPages(appendInboxPages([firstPage], lastPage));
    expect(combined).toMatchObject({
      hasMore: false,
      items: [firstPage.items[0], lastPage.items[0]],
    });
    expect(combined).not.toHaveProperty("nextCursor");
  });

  it("retains the loaded tail cursor on refresh and resets all pages for another workspace", () => {
    const firstPage = {
      activeWorkspaceId: "w1",
      hasMore: true,
      items: [productInboxItem("c1", "First page")],
      nextCursor: "cursor-2",
      source: "live-sync",
    } satisfies ProductInboxListResult;
    const secondPage = {
      activeWorkspaceId: "w1",
      hasMore: true,
      items: [productInboxItem("c2", "Second page")],
      nextCursor: "cursor-3",
      source: "live-sync",
    } satisfies ProductInboxListResult;
    const refreshedFirstPage = {
      ...firstPage,
      items: [productInboxItem("c1", "Refreshed first page")],
      nextCursor: "new-first-page-cursor",
    };

    const refreshed = refreshInboxPages(
      appendInboxPages([firstPage], secondPage),
      refreshedFirstPage
    );
    expect(combineInboxPages(refreshed)).toMatchObject({
      hasMore: true,
      nextCursor: "cursor-3",
      items: [
        expect.objectContaining({ title: "Refreshed first page" }),
        expect.objectContaining({ freshness: "stale", title: "Second page" }),
      ],
    });

    const otherWorkspace = {
      activeWorkspaceId: "w2",
      hasMore: false,
      items: [
        {
          ...productInboxItem("c9", "Other workspace"),
          id: "w2:c9",
          workspaceId: "w2",
        },
      ],
      source: "live-sync",
    } satisfies ProductInboxListResult;
    expect(refreshInboxPages(refreshed, otherWorkspace)).toEqual([otherWorkspace]);
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
  productInboxController: ProductInboxProjectionController = createProductInboxProjectionHarness(
    {
      initial: {
        errorCode: "utility_unavailable",
        items: [],
        source: "unavailable",
      },
    }
  ).controller,
  captureChatRegistry?: (registry: ChatRegistry) => void
): AnyRouter {
  const api = createCommaApi({ baseUrl: "", token: "" });
  const auth = createTestCommaAuthValue();
  const rootRoute = createRootRoute({
    component: () => (
      <CommaAuthContext.Provider value={auth}>
        <ProductInboxProjectionProvider controller={productInboxController}>
          <ChatProvider api={api} productLease={auth.productLease}>
            {captureChatRegistry ? (
              <ChatRegistryCapture capture={captureChatRegistry} />
            ) : null}
            <Outlet />
          </ChatProvider>
        </ProductInboxProjectionProvider>
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
