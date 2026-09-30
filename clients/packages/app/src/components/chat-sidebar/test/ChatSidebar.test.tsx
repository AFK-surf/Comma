import {
  Outlet,
  RouterProvider,
  createMemoryHistory,
  createRootRoute,
  createRoute,
  createRouter,
  useParams,
} from "@tanstack/react-router";
import { fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import {
  Toaster,
  claimNativeSurfaceSuppression,
  registerToastObstructionTarget,
  releaseNativeSurfaceSuppression,
  toast,
  toastObstructionRightProperty,
} from "@comma/ui";
import {
  maxBrowserSidebarSessionsPerOwner,
  type BrowserSidebarState,
  type CommaNativeBridge,
} from "@comma/native-bridge";
import { StrictMode, act, useEffect, useState } from "react";
import { describe, expect, it, vi } from "vitest";
import { CommaAppShortcutsProvider } from "../../shortcuts/commaAppShortcuts";
import { CommaWebClientSettingsProvider } from "../../commaClientSettings";
import { ChatSidebar, ChatSidebarToggle } from "../ChatSidebar";
import {
  ChatSidebarProvider,
  activeSidebarChat,
  chatSidebarHostKey,
  useChatSidebar,
  useRegisterChatSidebarHost,
  type ChatSidebarHost,
} from "../ChatSidebarContext";

type BrowserSidebarBridge = CommaNativeBridge["browserSidebar"];

const { nativeBridge, noop, sendMessage } = vi.hoisted(() => ({
  nativeBridge: {
    applicationMenu: {
      onCommand: vi.fn<CommaNativeBridge["applicationMenu"]["onCommand"]>(
        () => () => {}
      ),
      update: vi.fn<CommaNativeBridge["applicationMenu"]["update"]>(async () => {}),
    },
    browserSidebar: {
      capture: vi.fn<BrowserSidebarBridge["capture"]>(async () => ({
        status: "unavailable",
      })),
      close: vi.fn<BrowserSidebarBridge["close"]>(async () => ({
        active: false,
        available: true,
      })),
      inspect: vi.fn<BrowserSidebarBridge["inspect"]>(async () => ({
        status: "cancelled",
      })),
      open: vi.fn<BrowserSidebarBridge["open"]>(async ({ sessionId, url }) => ({
        active: true,
        available: true,
        canGoBack: false,
        canGoForward: false,
        loading: false,
        sessionId,
        url,
        visible: true,
      })),
      navigate: vi.fn<BrowserSidebarBridge["navigate"]>(async () => ({
        active: true,
        available: true,
        canGoBack: false,
        canGoForward: false,
        loading: false,
        url: "https://example.com/docs",
        visible: true,
      })),
      onChanged: vi.fn<BrowserSidebarBridge["onChanged"]>(() => () => {}),
      onOpenTabRequested: vi.fn<BrowserSidebarBridge["onOpenTabRequested"]>(
        () => () => {}
      ),
      update: vi.fn<BrowserSidebarBridge["update"]>(async (_input) => ({
        active: true,
        available: true,
        sessionId: _input.sessionId,
        visible: true,
      })),
    },
    platform: "web",
  },
  noop: () => {},
  sendMessage: vi.fn(),
}));

vi.mock("@comma/native-bridge", async (importOriginal) => ({
  ...(await importOriginal<typeof import("@comma/native-bridge")>()),
  getNativeBridge: () => nativeBridge,
}));

vi.mock("../../chat/ChatProvider", () => ({
  useChatApi: () => ({}),
  useChatRegistry: () => ({ beginAttempt: vi.fn() }),
}));

vi.mock("../../chat/useWorkspaceSkills", () => ({
  useWorkspaceSkills: () => [],
}));

vi.mock("../../chat/conversation/useConversation", () => {
  return {
    useConversation: (
      _workspaceId: string,
      _groupId: string,
      conversationId: string
    ) => ({
      attachFiles: noop,
      discard: noop,
      refresh: noop,
      removeAttachment: noop,
      retry: noop,
      retryAttachment: noop,
      channel: {},
      send: sendMessage,
      setDraft: noop,
      state: {
        conversation: {
          title: `Task ${conversationId}`,
        },
        testConversationId: conversationId,
      },
    }),
  };
});

vi.mock("../../chat/conversation/ConversationView", () => ({
  ConversationView: ({
    onOpenConversationRef,
    state,
  }: {
    onOpenConversationRef?: (conversationRef: {
      conversationId: string;
      kind: "agent_task";
      title: string;
    }) => void;
    state: { testConversationId: string };
  }) => (
    <div data-testid={`mock-conversation-${state.testConversationId}`}>
      <span>Sidebar task {state.testConversationId}</span>
      {state.testConversationId === "task-a" ? (
        <button
          onClick={() =>
            onOpenConversationRef?.({
              conversationId: "task-b",
              kind: "agent_task",
              title: "Task B",
            })
          }
          type="button"
        >
          Open nested task B
        </button>
      ) : null}
    </div>
  ),
}));

const commaCenterHost: ChatSidebarHost = {
  conversationId: "comma-center",
  groupId: "grp_test",
  workspaceId: "workspace-1",
};
const commaCenterSessionId = JSON.stringify(["grp_test", "comma-center"]);
// No Toaster is mounted here; the body stands in as the registered reader.
const toastObstruction = () =>
  document.body.style.getPropertyValue(toastObstructionRightProperty);
const taskA = {
  conversationId: "task-a",
  groupId: "grp_test",
  kind: "agent_task" as const,
  title: "Task A",
  workspaceId: "workspace-1",
};
const taskB = {
  conversationId: "task-b",
  groupId: "grp_test",
  kind: "agent_task" as const,
  title: "Task B",
  workspaceId: "workspace-1",
};
const unrelatedHost: ChatSidebarHost = {
  conversationId: "unrelated",
  groupId: "grp_test",
  workspaceId: "workspace-1",
};
const pageEvictionHost: ChatSidebarHost = {
  conversationId: "browser-pages",
  groupId: "grp_test",
  workspaceId: "workspace-1",
};
const protectedCapacityHost: ChatSidebarHost = {
  conversationId: "protected-browser-page",
  groupId: "grp_test",
  workspaceId: "workspace-1",
};
const admittingCapacityHost: ChatSidebarHost = {
  conversationId: "admitting-browser-pages",
  groupId: "grp_test",
  workspaceId: "workspace-1",
};

describe("ChatSidebarContext", () => {
  it("creates and selects the exact tab id requested by Main", async () => {
    let onOpenTabRequested:
      | ((request: { tabId: string; url: string }) => void)
      | undefined;
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.onOpenTabRequested.mockImplementation((listener) => {
      onOpenTabRequested = listener;
      return () => undefined;
    });
    const rendered = render(
      <ChatSidebarProvider>
        <SidebarRegistryHarness />
      </ChatSidebarProvider>
    );

    try {
      await waitFor(() => expect(onOpenTabRequested).toBeTypeOf("function"));
      act(() => {
        onOpenTabRequested?.({
          tabId: "tab-from-main",
          url: "https://example.com/from-main",
        });
      });
      expect(screen.getByTestId("active-browser-id")).toHaveTextContent(
        "tab-from-main"
      );
      expect(screen.getByTestId("active-browser-url")).toHaveTextContent(
        "https://example.com/from-main"
      );
      expect(screen.getByTestId("active-sidebar-tab")).toHaveTextContent("browser");
    } finally {
      rendered.unmount();
      resetBrowserSidebarMocks();
    }
  });

  it("selects Browser without replacing Chat and can switch back to Chat", async () => {
    render(
      <ChatSidebarProvider>
        <SidebarRegistryHarness />
      </ChatSidebarProvider>
    );

    fireEvent.click(screen.getByRole("button", { name: "Open task A" }));
    expect(await screen.findByTestId("active-sidebar-chat")).toHaveTextContent(
      "task-a"
    );
    expect(screen.getByTestId("active-sidebar-tab")).toHaveTextContent("chat");

    fireEvent.click(screen.getByRole("button", { name: "Open browser" }));
    expect(screen.getByTestId("active-sidebar-tab")).toHaveTextContent("browser");
    expect(screen.getByTestId("active-browser-url")).toHaveTextContent(
      "https://example.com/docs"
    );
    expect(screen.getByTestId("active-sidebar-chat")).toHaveTextContent("task-a");

    fireEvent.click(screen.getByRole("button", { name: "Select Chat tab" }));
    expect(screen.getByTestId("active-sidebar-tab")).toHaveTextContent("chat");
    expect(screen.getByTestId("active-sidebar-chat")).toHaveTextContent("task-a");
    expect(screen.getByTestId("active-browser-url")).toHaveTextContent(
      "https://example.com/docs"
    );
  });

  it("keeps a sidebar session per main chat across Comma task promotion", async () => {
    render(
      <ChatSidebarProvider>
        <SidebarRegistryHarness />
      </ChatSidebarProvider>
    );

    expect(await screen.findByTestId("active-host")).toHaveTextContent("comma-center");
    expect(screen.getByTestId("comma-lineage")).toHaveTextContent("true");
    expect(screen.getByTestId("unrelated-lineage")).toHaveTextContent("false");

    fireEvent.click(screen.getByRole("button", { name: "Open task A" }));
    expect(await screen.findByTestId("active-sidebar-chat")).toHaveTextContent(
      "task-a"
    );
    expect(screen.getByTestId("task-a-lineage")).toHaveTextContent("true");

    fireEvent.click(screen.getByRole("button", { name: "Promote A and open task B" }));
    await waitFor(() =>
      expect(screen.getByTestId("active-host")).toHaveTextContent("task-a")
    );
    expect(screen.getByTestId("active-sidebar-chat")).toHaveTextContent("task-b");
    expect(screen.getByTestId("task-b-lineage")).toHaveTextContent("true");

    fireEvent.click(screen.getByRole("button", { name: "Return to Comma assistant" }));
    await waitFor(() =>
      expect(screen.getByTestId("active-host")).toHaveTextContent("comma-center")
    );
    expect(screen.getByTestId("active-sidebar-chat")).toHaveTextContent("task-a");

    fireEvent.click(screen.getByRole("button", { name: "Return to task A" }));
    await waitFor(() =>
      expect(screen.getByTestId("active-host")).toHaveTextContent("task-a")
    );
    expect(screen.getByTestId("active-sidebar-chat")).toHaveTextContent("task-b");
  });

  it("releases a native browser session when the renderer LRU forgets it", async () => {
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.close.mockClear();
    const rendered = render(
      <ChatSidebarProvider>
        <SidebarEvictionHarness />
      </ChatSidebarProvider>
    );

    try {
      const openNext = screen.getByRole("button", {
        name: "Open next browser host",
      });
      for (let index = 0; index <= maxBrowserSidebarSessionsPerOwner; index += 1) {
        fireEvent.click(openNext);
        await waitFor(() =>
          expect(screen.getByTestId("opened-browser-hosts")).toHaveTextContent(
            String(index + 1)
          )
        );
      }

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.close).toHaveBeenCalledWith({
          sessionId: expect.stringContaining(
            `${JSON.stringify(["grp_test", "browser-host-0"])}::`
          ),
        })
      );
    } finally {
      rendered.unmount();
      nativeBridge.browserSidebar.close.mockClear();
      nativeBridge.platform = "web";
    }
  });

  it("touches a mutated host before fencing the next-oldest LRU eviction", async () => {
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.close.mockClear();
    const rendered = render(
      <ChatSidebarProvider>
        <SidebarEvictionHarness />
      </ChatSidebarProvider>
    );

    try {
      const openNext = screen.getByRole("button", {
        name: "Open next browser host",
      });
      for (let index = 0; index < maxBrowserSidebarSessionsPerOwner; index += 1) {
        fireEvent.click(openNext);
        await waitFor(() =>
          expect(screen.getByTestId("opened-browser-hosts")).toHaveTextContent(
            String(index + 1)
          )
        );
      }

      fireEvent.click(screen.getByRole("button", { name: "Touch oldest host" }));
      await waitFor(() =>
        expect(screen.getByTestId("inspected-browser-title")).toHaveTextContent(
          "Touched oldest"
        )
      );
      nativeBridge.browserSidebar.close.mockClear();

      fireEvent.click(openNext);
      await waitFor(() =>
        expect(screen.getByTestId("opened-browser-hosts")).toHaveTextContent(
          String(maxBrowserSidebarSessionsPerOwner + 1)
        )
      );

      const touchedHostPrefix = `${chatSidebarHostKey(browserEvictionHost(0))}::`;
      const evictedHostPrefix = `${chatSidebarHostKey(browserEvictionHost(1))}::`;
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.close).toHaveBeenCalledWith({
          sessionId: expect.stringContaining(evictedHostPrefix),
        })
      );
      expect(nativeBridge.browserSidebar.close).not.toHaveBeenCalledWith({
        sessionId: expect.stringContaining(touchedHostPrefix),
      });

      fireEvent.click(screen.getByRole("button", { name: "Inspect next-oldest host" }));
      await waitFor(() =>
        expect(screen.getByTestId("inspected-browser-host")).toHaveTextContent(
          "browser-host-1"
        )
      );
      expect(screen.getByTestId("inspected-browser-status")).toHaveTextContent(
        "missing"
      );

      fireEvent.click(screen.getByRole("button", { name: "Inspect oldest host" }));
      await waitFor(() =>
        expect(screen.getByTestId("inspected-browser-host")).toHaveTextContent(
          "browser-host-0"
        )
      );
      expect(screen.getByTestId("inspected-browser-status")).toHaveTextContent(
        "retained"
      );
      expect(screen.getByTestId("inspected-browser-title")).toHaveTextContent(
        "Touched oldest"
      );

      fireEvent.click(screen.getByRole("button", { name: "Inspect newest host" }));
      await waitFor(() =>
        expect(screen.getByTestId("inspected-browser-host")).toHaveTextContent(
          `browser-host-${maxBrowserSidebarSessionsPerOwner}`
        )
      );
      expect(screen.getByTestId("inspected-browser-fence")).toHaveTextContent(
        evictedHostPrefix
      );
      expect(screen.getByTestId("inspected-browser-fence")).not.toHaveTextContent(
        touchedHostPrefix
      );
    } finally {
      rendered.unmount();
      nativeBridge.browserSidebar.close.mockClear();
      nativeBridge.platform = "web";
    }
  });

  it("caps native browser page sessions across multiple pages in one host", async () => {
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.close.mockClear();
    const rendered = render(
      <ChatSidebarProvider>
        <SidebarPageEvictionHarness />
      </ChatSidebarProvider>
    );

    try {
      fireEvent.click(screen.getByRole("button", { name: "Add blank browser page" }));
      await waitFor(() =>
        expect(screen.getByTestId("browser-page-count")).toHaveTextContent("1")
      );
      const blankPageId = screen.getByTestId("first-browser-page-id").textContent;
      expect(blankPageId).toBeTruthy();

      const openNext = screen.getByRole("button", {
        name: "Open next browser page",
      });
      for (let index = 0; index < maxBrowserSidebarSessionsPerOwner; index += 1) {
        fireEvent.click(openNext);
        await waitFor(() =>
          expect(screen.getByTestId("opened-browser-pages")).toHaveTextContent(
            String(index + 1)
          )
        );
      }
      const firstUrlPageId = screen.getByTestId("first-url-page-id").textContent;
      expect(firstUrlPageId).toBeTruthy();
      expect(screen.getByTestId("browser-page-count")).toHaveTextContent(
        String(maxBrowserSidebarSessionsPerOwner + 1)
      );

      fireEvent.click(
        screen.getByRole("button", { name: "Select first browser page" })
      );
      expect(screen.getByTestId("active-browser-page-id")).toHaveTextContent(
        blankPageId ?? "missing"
      );
      fireEvent.click(screen.getByRole("button", { name: "Fill active browser page" }));

      await waitFor(() =>
        expect(screen.getByTestId("browser-page-count")).toHaveTextContent(
          String(maxBrowserSidebarSessionsPerOwner)
        )
      );
      expect(screen.getByTestId("active-browser-page-id")).toHaveTextContent(
        blankPageId ?? "missing"
      );
      expect(screen.getByTestId("active-browser-page-url")).toHaveTextContent(
        "https://example.com/active"
      );
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.close).toHaveBeenCalledWith({
          sessionId: `${chatSidebarHostKey(pageEvictionHost)}::${firstUrlPageId}`,
        })
      );
    } finally {
      rendered.unmount();
      nativeBridge.browserSidebar.close.mockClear();
      nativeBridge.platform = "web";
    }
  });
});

describe("ChatSidebar", () => {
  it("keeps each browser error until recovery or unmount across queued animation frames", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    const bounds = mockBrowserSidebarBounds();
    const toaster = render(<Toaster />);
    const view = renderSidebarRouter();
    await screen.findByRole("button", { name: "Open browser" });
    const frames = new Map<number, FrameRequestCallback>();
    let nextFrame = 0;
    vi.spyOn(window, "requestAnimationFrame").mockImplementation((callback) => {
      frames.set(++nextFrame, callback);
      return nextFrame;
    });
    vi.spyOn(window, "cancelAnimationFrame").mockImplementation((id) => {
      frames.delete(id);
    });
    const advanceFrame = async () => {
      const pending = [...frames.values()];
      frames.clear();
      await act(async () => {
        for (const callback of pending) callback(performance.now());
      });
    };

    try {
      fireEvent.click(screen.getByRole("button", { name: "Open browser" }));
      const address = await screen.findByRole("textbox", { name: "Address" });
      fireEvent.change(address, { target: { value: "ftp://example.com" } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));
      const error = await screen.findByTestId("browser-error");

      // Sonner delivers dismissals over two frames. A dismissal queued while
      // this panel had no error must not remove the error raised in between.
      await advanceFrame();
      await advanceFrame();
      expect(screen.getByRole("textbox", { name: "Address" })).toBe(address);
      expect(address).toHaveValue("ftp://example.com");
      expect(address).toHaveAttribute("aria-invalid", "true");
      expect(error).toBeVisible();
      expect(error.closest("[data-sonner-toast]")).toHaveAttribute(
        "data-removed",
        "false"
      );

      fireEvent.change(address, { target: { value: "https://example.com" } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));
      await waitFor(() => expect(address).not.toHaveAttribute("aria-invalid"));
      fireEvent.change(address, { target: { value: "ftp://example.com/again" } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));
      await waitFor(() =>
        expect(screen.getAllByTestId("browser-error")).toHaveLength(2)
      );
      const nextError = screen
        .getAllByTestId("browser-error")
        .find((item) => item !== error)!;

      // The old error's recovery is still queued when the next error arrives.
      await advanceFrame();
      await advanceFrame();
      expect(screen.getByRole("textbox", { name: "Address" })).toBe(address);
      expect(address).toHaveValue("ftp://example.com/again");
      expect(address).toHaveAttribute("aria-invalid", "true");
      expect(error.closest("[data-sonner-toast]")).toHaveAttribute(
        "data-removed",
        "true"
      );
      expect(nextError).toBeVisible();
      expect(nextError.closest("[data-sonner-toast]")).toHaveAttribute(
        "data-removed",
        "false"
      );

      fireEvent.change(address, { target: { value: "https://example.com" } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));
      await waitFor(() => expect(address).not.toHaveAttribute("aria-invalid"));
      await advanceFrame();
      await advanceFrame();
      await waitFor(() =>
        expect(screen.queryByTestId("browser-error")).not.toBeInTheDocument()
      );

      fireEvent.change(address, { target: { value: "ftp://example.com" } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));
      expect(await screen.findByTestId("browser-error")).toBeVisible();
      view.unmount();
      await advanceFrame();
      await advanceFrame();
      await waitFor(() =>
        expect(screen.queryByTestId("browser-error")).not.toBeInTheDocument()
      );
    } finally {
      view.unmount();
      act(() => toast.dismissAll());
      await advanceFrame();
      await advanceFrame();
      toaster.unmount();
      vi.restoreAllMocks();
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("keeps the sidebar shell mounted for open and close transitions", async () => {
    renderSidebarRouter();

    const sidebar = await screen.findByTestId("chat-sidebar");
    const toggle = screen.getByRole("button", { name: "Toggle chat sidebar" });
    expect(sidebar).toHaveAttribute("data-open", "true");
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(toggle).toHaveClass("comma-icon-button", "size-7", "p-xs");
    expect(toggle).not.toHaveClass(
      "size-8",
      "p-xxs",
      "hover:!bg-sidebar-bg-item",
      "hover:bg-button-tertiary-bg-hover",
      "hover:text-button-tertiary-fg-hover"
    );
    expect(toggle).toHaveStyle({
      "--comma-button-hover-bg": "var(--color-sidebar-bg-item)",
      "--comma-button-hover-fg": "var(--color-sidebar-icon-primary)",
    });
    expect(await screen.findByTestId("mock-conversation-task-a")).toBeVisible();

    fireEvent.click(toggle);
    expect(sidebar).toHaveAttribute("data-open", "false");
    expect(toggle).toHaveAttribute("aria-expanded", "false");
    expect(screen.getByTestId("mock-conversation-task-a")).toBeInTheDocument();

    fireEvent.transitionEnd(sidebar, { propertyName: "width" });
    expect(screen.getByTestId("mock-conversation-task-a")).toBeInTheDocument();
    expect(sidebar).toBeInTheDocument();

    fireEvent.click(toggle);
    expect(sidebar).toHaveAttribute("data-open", "true");
    expect(toggle).toHaveAttribute("aria-expanded", "true");
    expect(await screen.findByTestId("mock-conversation-task-a")).toBeVisible();
  });

  it("keeps the global toggle visible and opens a default Browser tab", async () => {
    const { router } = renderSidebarRouter();

    expect(
      await screen.findByRole("button", { name: "Toggle chat sidebar" })
    ).toBeVisible();

    await act(() => router.navigate({ to: "/plugins" }));

    const toggle = screen.getByRole("button", { name: "Toggle chat sidebar" });
    expect(toggle).toBeVisible();
    expect(toggle).toHaveAttribute("aria-expanded", "false");

    fireEvent.click(toggle);
    expect(screen.getByTestId("chat-sidebar")).toHaveAttribute("data-open", "true");
    expect(screen.getByRole("tab", { name: "New tab" })).toBeVisible();
    expect(screen.getByRole("textbox", { name: "Address" })).toBeVisible();

    fireEvent.click(screen.getByRole("button", { name: "Close New tab" }));
    expect(screen.getByTestId("chat-sidebar-empty")).toBeVisible();
    expect(screen.getByTestId("chat-sidebar")).toHaveAttribute("data-open", "true");

    fireEvent.click(screen.getByRole("button", { name: "New browser tab" }));
    expect(screen.getByRole("tab", { name: "New tab" })).toBeVisible();
  });

  it("resynchronizes current bounds after the first blank-tab navigation opens", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    let resolveOpen: ((state: BrowserSidebarState) => void) | undefined;
    const pendingOpen = new Promise<BrowserSidebarState>((resolve) => {
      resolveOpen = resolve;
    });
    nativeBridge.browserSidebar.open.mockImplementationOnce(() => pendingOpen);
    const bounds = vi
      .spyOn(HTMLElement.prototype, "getBoundingClientRect")
      .mockReturnValue({
        bottom: 640,
        height: 600,
        left: 1_040,
        right: 1_240,
        toJSON: () => ({}),
        top: 40,
        width: 200,
        x: 1_040,
        y: 40,
      });

    try {
      const { router } = renderSidebarRouter();
      await act(() => router.navigate({ to: "/plugins" }));
      fireEvent.click(
        await screen.findByRole("button", { name: "Toggle chat sidebar" })
      );
      const address = screen.getByRole("textbox", { name: "Address" });
      fireEvent.change(address, { target: { value: "example.com/first" } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      const sessionId =
        nativeBridge.browserSidebar.open.mock.calls[0]?.[0].sessionId ??
        "missing-first-navigation-session";

      bounds.mockReturnValue({
        bottom: 640,
        height: 600,
        left: 800,
        right: 1_240,
        toJSON: () => ({}),
        top: 40,
        width: 440,
        x: 800,
        y: 40,
      });
      fireEvent(window, new Event("resize"));
      await act(async () => {
        resolveOpen?.(
          browserSidebarState(sessionId, {
            url: "https://example.com/first",
            visible: true,
          })
        );
        await pendingOpen;
      });

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          bounds: { height: 600, width: 440, x: 800, y: 40 },
          sessionId,
        })
      );
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("does not hide the first navigation during a StrictMode remount", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    const bounds = mockBrowserSidebarBounds();

    try {
      const view = renderSidebarRouter({ strictMode: true });
      await act(() => view.router.navigate({ to: "/plugins" }));
      fireEvent.click(
        await screen.findByRole("button", { name: "Toggle chat sidebar" })
      );
      const address = screen.getByRole("textbox", { name: "Address" });
      fireEvent.change(address, { target: { value: "example.com/first" } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open.mock.calls.length).toBeGreaterThan(1)
      );
      const sessionId =
        nativeBridge.browserSidebar.open.mock.calls.at(-1)?.[0].sessionId;
      expect(sessionId).toBeTruthy();
      await act(async () => {
        await Promise.resolve();
      });
      expect(nativeBridge.browserSidebar.update).not.toHaveBeenCalledWith({
        sessionId,
        visible: false,
      });

      view.unmount();
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId,
          visible: false,
        })
      );
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("sends selected browser element details through the active chat channel", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.inspect.mockResolvedValueOnce({
      element: {
        attributes: { "aria-label": "Save", role: "button" },
        outerHTML: '<button aria-label="Save">Save</button>',
        rect: { height: 32, width: 80, x: 20, y: 40 },
        selector: "main > button",
        tagName: "button",
        text: "Save",
      },
      inspectionId: "inspection-1",
      page: { title: "Example", url: "https://example.com/docs" },
      status: "selected",
      userMessage: "Explain this control",
    });
    const bounds = mockBrowserSidebarBounds();

    try {
      renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      const inspectButton = await screen.findByRole("button", {
        name: "Select element",
      });
      await waitFor(() => expect(inspectButton).toBeEnabled());
      fireEvent.click(inspectButton);

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.inspect).toHaveBeenCalledWith({
          action: "start",
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
        })
      );
      await waitFor(() => expect(sendMessage).toHaveBeenCalledOnce());
      expect(sendMessage.mock.calls[0]?.[0]).toContain("Explain this control");
      expect(sendMessage.mock.calls[0]?.[0]).toContain(
        '<browser-element-inspection id="inspection-1" />'
      );
      expect(sendMessage.mock.calls[0]?.[0]).toContain("Selector: main > button");
      expect(sendMessage.mock.calls[0]?.[1]).toEqual({ consumeDraft: false });
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("resizes from the left edge with pointer and keyboard controls", async () => {
    renderSidebarRouter();

    const sidebar = await screen.findByTestId("chat-sidebar");
    const resizeHandle = screen.getByRole("separator", {
      name: "Resize chat sidebar",
    });
    expect(resizeHandle).toHaveAccessibleDescription("Drag to resize");
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "440px" });

    fireEvent.pointerDown(resizeHandle, {
      button: 0,
      clientX: 600,
      pointerId: 1,
    });
    expect(sidebar).toHaveAttribute("data-resizing", "true");
    fireEvent.pointerMove(window, { clientX: 520, pointerId: 1 });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "520px" });
    fireEvent.pointerUp(window, { clientX: 520, pointerId: 1 });
    expect(sidebar).toHaveAttribute("data-resizing", "false");

    fireEvent.keyDown(resizeHandle, { key: "ArrowRight" });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "504px" });
    fireEvent.keyDown(resizeHandle, { key: "Home" });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "320px" });
    fireEvent.keyDown(resizeHandle, { key: "End" });
    expect(sidebar).toHaveStyle({ "--comma-chat-sidebar-width": "720px" });
  });

  it("opens nested tasks in separate tabs and expands the selected task to its detail route", async () => {
    const { router } = renderSidebarRouter();
    expect(await screen.findByTestId("mock-conversation-task-a")).toBeVisible();
    fireEvent.click(screen.getByRole("button", { name: "Open nested task B" }));
    expect(router.state.location.pathname).toBe("/");
    expect(await screen.findByTestId("mock-conversation-task-b")).toBeVisible();
    expect(screen.getByRole("tab", { name: "Task A" })).toBeVisible();
    expect(screen.getByRole("tab", { name: "Task B" })).toBeVisible();
    fireEvent.click(screen.getByRole("tab", { name: "Task A" }));
    fireEvent.click(screen.getByRole("button", { name: "Open nested task B" }));
    expect(screen.getAllByRole("tab", { name: "Task B" })).toHaveLength(1);
    fireEvent.click(screen.getByRole("button", { name: "Close Task B" }));
    expect(await screen.findByTestId("mock-conversation-task-a")).toBeVisible();
    fireEvent.click(screen.getByRole("button", { name: "Open task" }));
    await waitFor(() =>
      expect(router.state.location.pathname).toBe("/tasks/workspace-1/grp_test/task-a")
    );
  });

  it("creates a new page-scoped native session when a retained host receives another link", async () => {
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.open.mockClear();
    const bounds = vi
      .spyOn(HTMLElement.prototype, "getBoundingClientRect")
      .mockReturnValue({
        bottom: 640,
        height: 600,
        left: 0,
        right: 1_240,
        toJSON: () => ({}),
        top: 40,
        width: 1_240,
        x: 0,
        y: 40,
      });
    try {
      renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledWith(
          expect.objectContaining({
            navigationRevision: 1,
            sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
            url: "https://example.com/docs",
          })
        )
      );

      fireEvent.click(screen.getByRole("button", { name: "Open next browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledWith(
          expect.objectContaining({
            navigationRevision: 1,
            sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
            url: "https://example.com/next",
          })
        )
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2);
      expect(nativeBridge.browserSidebar.open.mock.calls[1]?.[0].sessionId).not.toBe(
        nativeBridge.browserSidebar.open.mock.calls[0]?.[0].sessionId
      );
    } finally {
      bounds.mockRestore();
      nativeBridge.browserSidebar.open.mockClear();
      nativeBridge.platform = "web";
    }
  });

  it("stores native URL metadata without replaying it as navigation intent", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    let onChanged: ((state: BrowserSidebarState) => void) | undefined;
    nativeBridge.browserSidebar.onChanged.mockImplementation((listener) => {
      onChanged = listener;
      return () => undefined;
    });
    const bounds = mockBrowserSidebarBounds();

    try {
      renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      const firstOpen = nativeBridge.browserSidebar.open.mock.calls[0]?.[0];
      expect(firstOpen).toEqual(
        expect.objectContaining({
          navigationRevision: 1,
          url: "https://example.com/docs",
        })
      );

      act(() => {
        onChanged?.(
          browserSidebarState(firstOpen?.sessionId ?? "missing-session", {
            canGoBack: true,
            canGoForward: false,
            loading: false,
            title: "Visited page",
            url: "https://example.com/visited",
          })
        );
      });

      await waitFor(() =>
        expect(screen.getByRole("textbox", { name: "Address" })).toHaveValue(
          "https://example.com/visited"
        )
      );
      expect(screen.getByRole("tab", { name: "Visited page" })).toBeVisible();
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce();

      const address = screen.getByRole("textbox", { name: "Address" });
      fireEvent.focus(address);
      fireEvent.change(address, { target: { value: "example.com/requested" } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId: firstOpen?.sessionId,
          url: "https://example.com/requested",
        })
      );
      expect(
        nativeBridge.browserSidebar.update.mock.calls.filter(
          ([input]) => input.url === "https://example.com/requested"
        )
      ).toHaveLength(1);
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce();
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("retains native metadata for a hidden host and recovers its destroyed view at the latest URL", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    let onChanged: ((state: BrowserSidebarState) => void) | undefined;
    nativeBridge.browserSidebar.onChanged.mockImplementation((listener) => {
      onChanged = listener;
      return () => undefined;
    });
    const bounds = mockBrowserSidebarBounds();

    try {
      const { router } = renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open task" }));
      await waitFor(() =>
        expect(router.state.location.pathname).toBe(
          "/tasks/workspace-1/grp_test/task-a"
        )
      );
      await act(async () => {
        await router.navigate({ to: "/" });
      });
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      const firstOpen = nativeBridge.browserSidebar.open.mock.calls[0]?.[0];
      const sessionId = firstOpen?.sessionId ?? "missing-session";

      fireEvent.click(screen.getByRole("tab", { name: "Task A" }));
      fireEvent.click(screen.getByRole("button", { name: "Open task" }));
      await waitFor(() =>
        expect(router.state.location.pathname).toBe(
          "/tasks/workspace-1/grp_test/task-a"
        )
      );

      act(() => {
        onChanged?.(
          browserSidebarState(sessionId, {
            title: "Hidden latest",
            url: "https://example.com/hidden-latest",
            visible: false,
          })
        );
        onChanged?.(
          browserSidebarState(sessionId, {
            active: false,
            visible: false,
          })
        );
      });

      await act(async () => {
        await router.navigate({ to: "/" });
      });
      const retainedTab = await screen.findByRole("tab", {
        name: "Hidden latest",
      });
      fireEvent.click(retainedTab);

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2)
      );
      expect(nativeBridge.browserSidebar.open.mock.calls[1]?.[0]).toEqual(
        expect.objectContaining({
          navigationRevision: firstOpen?.navigationRevision,
          sessionId,
          url: "https://example.com/hidden-latest",
        })
      );
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("does not let a delayed old open hide a remounted same-session view", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    let resolveOldOpen: ((state: BrowserSidebarState) => void) | undefined;
    const pendingOldOpen = new Promise<BrowserSidebarState>((resolve) => {
      resolveOldOpen = resolve;
    });
    const nativeVisibility = new Map<string, boolean>();
    let openCount = 0;
    nativeBridge.browserSidebar.open.mockImplementation(async (input) => {
      openCount += 1;
      if (openCount === 1) return pendingOldOpen;
      nativeVisibility.set(input.sessionId, true);
      return browserSidebarState(input.sessionId, {
        url: input.url,
        visible: true,
      });
    });
    nativeBridge.browserSidebar.update.mockImplementation(async (input) => {
      if (input.visible !== undefined) {
        nativeVisibility.set(input.sessionId, input.visible);
      }
      return browserSidebarState(input.sessionId, {
        visible: nativeVisibility.get(input.sessionId) ?? false,
      });
    });
    const bounds = mockBrowserSidebarBounds();

    try {
      const { router } = renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open task" }));
      await waitFor(() =>
        expect(router.state.location.pathname).toBe(
          "/tasks/workspace-1/grp_test/task-a"
        )
      );
      await act(async () => {
        await router.navigate({ to: "/" });
      });

      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      const sessionId =
        nativeBridge.browserSidebar.open.mock.calls[0]?.[0].sessionId ??
        "missing-remounted-session";

      await act(async () => {
        await router.navigate({
          params: {
            conversationId: "task-a",
            groupId: "grp_test",
            workspaceId: "workspace-1",
          },
          to: "/tasks/$workspaceId/$groupId/$conversationId",
        });
      });
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId,
          visible: false,
        })
      );

      await act(async () => {
        await router.navigate({ to: "/" });
      });
      expect(await screen.findByTestId("mock-conversation-task-a")).toBeVisible();
      fireEvent.click(await screen.findByRole("tab", { name: "Documentation" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2)
      );
      expect(nativeBridge.browserSidebar.open.mock.calls[1]?.[0].sessionId).toBe(
        sessionId
      );
      await waitFor(() => expect(nativeVisibility.get(sessionId)).toBe(true));

      nativeBridge.browserSidebar.update.mockClear();
      await act(async () => {
        resolveOldOpen?.(
          browserSidebarState(sessionId, {
            url: "https://example.com/docs",
            visible: true,
          })
        );
        await pendingOldOpen;
        await Promise.resolve();
      });

      expect(nativeBridge.browserSidebar.update).not.toHaveBeenCalledWith({
        sessionId,
        visible: false,
      });
      expect(nativeVisibility.get(sessionId)).toBe(true);
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it.each([
    { capacity: false, settlement: "successful non-capacity response" },
    { capacity: true, settlement: "capacity response" },
  ])(
    "keeps the newest navigation when an older $settlement settles last",
    async ({ capacity }) => {
      resetBrowserSidebarMocks();
      nativeBridge.platform = "electron";
      const staleUrl = "https://example.com/two";
      const currentUrl = "https://example.com/three";
      let resolveStaleOpen: ((state: BrowserSidebarState) => void) | undefined;
      const pendingStaleOpen = new Promise<BrowserSidebarState>((resolve) => {
        resolveStaleOpen = resolve;
      });
      const nativeUrls = new Map<string, string>();
      let heldStaleOpen = false;
      nativeBridge.browserSidebar.open.mockImplementation(async (input) => {
        nativeUrls.set(input.sessionId, input.url);
        const state = browserSidebarState(input.sessionId, { url: input.url });
        if (input.url === staleUrl && !heldStaleOpen) {
          heldStaleOpen = true;
          return pendingStaleOpen;
        }
        return state;
      });
      nativeBridge.browserSidebar.update.mockImplementation(async (input) => {
        if (input.url) nativeUrls.set(input.sessionId, input.url);
        return browserSidebarState(input.sessionId, {
          url: nativeUrls.get(input.sessionId),
        });
      });
      const bounds = mockBrowserSidebarBounds();

      try {
        renderSidebarRouter();
        fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
        await waitFor(() =>
          expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
        );
        const sessionId =
          nativeBridge.browserSidebar.open.mock.calls[0]?.[0].sessionId ??
          "missing-navigation-session";

        fireEvent.click(
          screen.getByRole("button", { name: "Navigate browser to two" })
        );
        await waitFor(() =>
          expect(
            nativeBridge.browserSidebar.open.mock.calls.some(
              ([input]) => input.sessionId === sessionId && input.url === staleUrl
            )
          ).toBe(true)
        );

        fireEvent.click(
          screen.getByRole("button", { name: "Navigate browser to three" })
        );
        await waitFor(() =>
          expect(
            nativeBridge.browserSidebar.open.mock.calls.some(
              ([input]) => input.sessionId === sessionId && input.url === currentUrl
            )
          ).toBe(true)
        );
        await waitFor(() => expect(nativeUrls.get(sessionId)).toBe(currentUrl));
        const openCountBeforeStaleSettlement =
          nativeBridge.browserSidebar.open.mock.calls.length;

        await act(async () => {
          resolveStaleOpen?.(
            browserSidebarState(
              sessionId,
              capacity
                ? {
                    active: false,
                    reason: "Browser sidebar capacity is temporarily full.",
                    reasonCode: "capacity",
                    url: staleUrl,
                    visible: false,
                  }
                : { url: staleUrl, visible: true }
            )
          );
          await pendingStaleOpen;
          await Promise.resolve();
        });

        expect(screen.getByRole("textbox", { name: "Address" })).toHaveValue(
          currentUrl
        );
        expect(nativeUrls.get(sessionId)).toBe(currentUrl);
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(
          openCountBeforeStaleSettlement
        );
      } finally {
        bounds.mockRestore();
        resetBrowserSidebarMocks();
      }
    }
  );

  it("does not let a delayed navigation settlement overwrite a remounted same-session view", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    const staleUrl = "https://example.com/two";
    const currentUrl = "https://example.com/three";
    let resolveStaleOpen: ((state: BrowserSidebarState) => void) | undefined;
    const pendingStaleOpen = new Promise<BrowserSidebarState>((resolve) => {
      resolveStaleOpen = resolve;
    });
    let onChanged: ((state: BrowserSidebarState) => void) | undefined;
    nativeBridge.browserSidebar.onChanged.mockImplementation((listener) => {
      onChanged = listener;
      return () => undefined;
    });
    const nativeUrls = new Map<string, string>();
    let heldStaleOpen = false;
    nativeBridge.browserSidebar.open.mockImplementation(async (input) => {
      nativeUrls.set(input.sessionId, input.url);
      const state = browserSidebarState(input.sessionId, {
        url: input.url,
        visible: true,
      });
      if (input.url === staleUrl && !heldStaleOpen) {
        heldStaleOpen = true;
        return pendingStaleOpen;
      }
      return state;
    });
    nativeBridge.browserSidebar.update.mockImplementation(async (input) => {
      if (input.url) nativeUrls.set(input.sessionId, input.url);
      return browserSidebarState(input.sessionId, {
        url: nativeUrls.get(input.sessionId),
        visible: input.visible ?? true,
      });
    });
    const bounds = mockBrowserSidebarBounds();

    try {
      const { router } = renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open task" }));
      await waitFor(() =>
        expect(router.state.location.pathname).toBe(
          "/tasks/workspace-1/grp_test/task-a"
        )
      );
      await act(async () => {
        await router.navigate({ to: "/" });
      });
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      const sessionId =
        nativeBridge.browserSidebar.open.mock.calls[0]?.[0].sessionId ??
        "missing-navigation-session";

      const firstAddress = screen.getByRole("textbox", { name: "Address" });
      fireEvent.focus(firstAddress);
      fireEvent.change(firstAddress, { target: { value: staleUrl } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));
      fireEvent.blur(firstAddress);
      await waitFor(() => expect(nativeUrls.get(sessionId)).toBe(staleUrl));
      act(() =>
        onChanged?.(
          browserSidebarState(sessionId, {
            active: false,
            url: staleUrl,
            visible: false,
          })
        )
      );
      await waitFor(() =>
        expect(
          nativeBridge.browserSidebar.open.mock.calls.filter(
            ([input]) => input.sessionId === sessionId && input.url === staleUrl
          )
        ).toHaveLength(1)
      );
      act(() =>
        onChanged?.(
          browserSidebarState(sessionId, {
            url: staleUrl,
            visible: true,
          })
        )
      );

      await act(async () => {
        await router.navigate({
          params: {
            conversationId: "task-a",
            groupId: "grp_test",
            workspaceId: "workspace-1",
          },
          to: "/tasks/$workspaceId/$groupId/$conversationId",
        });
      });
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId,
          visible: false,
        })
      );
      await act(async () => {
        await router.navigate({ to: "/" });
      });
      expect(await screen.findByTestId("mock-conversation-task-a")).toBeVisible();
      fireEvent.click(await screen.findByRole("tab", { name: "Documentation" }));
      await waitFor(() =>
        expect(
          nativeBridge.browserSidebar.open.mock.calls.filter(
            ([input]) => input.sessionId === sessionId && input.url === staleUrl
          )
        ).toHaveLength(2)
      );

      const currentAddress = screen.getByRole("textbox", { name: "Address" });
      fireEvent.focus(currentAddress);
      fireEvent.change(currentAddress, { target: { value: currentUrl } });
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));
      fireEvent.blur(currentAddress);
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId,
          url: currentUrl,
        })
      );
      await waitFor(() => expect(nativeUrls.get(sessionId)).toBe(currentUrl));
      expect(currentAddress).toHaveValue(currentUrl);

      await act(async () => {
        resolveStaleOpen?.(
          browserSidebarState(sessionId, {
            url: staleUrl,
            visible: true,
          })
        );
        await pendingStaleOpen;
        await Promise.resolve();
      });

      expect(screen.getByRole("textbox", { name: "Address" })).toHaveValue(currentUrl);
      expect(nativeUrls.get(sessionId)).toBe(currentUrl);
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("retries a capacity-blocked page once after a native session releases capacity", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    let onChanged: ((state: BrowserSidebarState) => void) | undefined;
    nativeBridge.browserSidebar.onChanged.mockImplementation((listener) => {
      onChanged = listener;
      return () => undefined;
    });
    const bounds = mockBrowserSidebarBounds();

    try {
      renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      fireEvent.click(screen.getByRole("button", { name: "Open next browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2)
      );
      const releasingSessionId = "native-session-forgotten-by-renderer";
      act(() => onChanged?.(browserSidebarState(releasingSessionId)));

      nativeBridge.browserSidebar.open.mockImplementationOnce(async (input) =>
        browserSidebarState(input.sessionId, {
          active: false,
          reason: "Browser sidebar capacity is temporarily full.",
          reasonCode: "capacity",
          visible: false,
        })
      );
      fireEvent.click(screen.getByRole("button", { name: "Open next browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(3)
      );
      const blockedOpen = nativeBridge.browserSidebar.open.mock.calls[2]?.[0];
      await act(
        () =>
          new Promise<void>((resolve) => {
            queueMicrotask(resolve);
          })
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(3);
      const blockedTab = screen
        .getAllByRole("tab", { name: "Next documentation" })
        .find((tab) => tab.getAttribute("aria-selected") === "true");
      expect(blockedTab).toBeTruthy();
      if (!blockedTab) throw new Error("Expected a selected capacity-blocked tab.");
      fireEvent.click(screen.getByRole("tab", { name: "Task A" }));
      fireEvent.click(blockedTab);
      await act(
        () =>
          new Promise<void>((resolve) => {
            queueMicrotask(resolve);
          })
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(3);

      const releasedState = browserSidebarState(releasingSessionId, {
        active: false,
        visible: false,
      });
      act(() => onChanged?.(releasedState));

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(4)
      );
      expect(nativeBridge.browserSidebar.open.mock.calls[3]?.[0]).toEqual(
        expect.objectContaining({
          navigationRevision: blockedOpen?.navigationRevision,
          sessionId: blockedOpen?.sessionId,
          url: blockedOpen?.url,
        })
      );

      act(() => onChanged?.(releasedState));
      await act(
        () =>
          new Promise<void>((resolve) => {
            queueMicrotask(resolve);
          })
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(4);
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("retries after rejected cleanup reconciles an inactive native session", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    const bounds = mockBrowserSidebarBounds();

    try {
      renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      const releasingSessionId =
        nativeBridge.browserSidebar.open.mock.calls[0]?.[0].sessionId ??
        "missing-releasing-session";

      fireEvent.click(screen.getByRole("button", { name: "Open next browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2)
      );

      nativeBridge.browserSidebar.open.mockImplementationOnce(async (input) =>
        browserSidebarState(input.sessionId, {
          active: false,
          reason: "Browser sidebar capacity is temporarily full.",
          reasonCode: "capacity",
          visible: false,
        })
      );
      fireEvent.click(screen.getByRole("button", { name: "Open next browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(3)
      );
      const blockedOpen = nativeBridge.browserSidebar.open.mock.calls[2]?.[0];
      await act(
        () =>
          new Promise<void>((resolve) => {
            queueMicrotask(resolve);
          })
      );

      let cleanupRejected = false;
      nativeBridge.browserSidebar.close.mockImplementationOnce(async () => {
        cleanupRejected = true;
        throw new Error("close acknowledgement lost");
      });
      nativeBridge.browserSidebar.update.mockImplementation(async (input) => {
        if (
          cleanupRejected &&
          input.sessionId === releasingSessionId &&
          input.visible === false
        ) {
          return browserSidebarState(releasingSessionId, {
            active: false,
            visible: false,
          });
        }
        return browserSidebarState(input.sessionId, {
          visible: input.visible ?? true,
        });
      });

      fireEvent.click(screen.getByRole("button", { name: "Close Documentation" }));

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.close).toHaveBeenCalledWith({
          sessionId: releasingSessionId,
        })
      );
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId: releasingSessionId,
          visible: false,
        })
      );
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(4)
      );
      expect(nativeBridge.browserSidebar.open.mock.calls[3]?.[0]).toEqual(
        expect.objectContaining({
          navigationRevision: blockedOpen?.navigationRevision,
          sessionId: blockedOpen?.sessionId,
          url: blockedOpen?.url,
        })
      );

      await act(
        () =>
          new Promise<void>((resolve) => {
            queueMicrotask(resolve);
          })
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(4);
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
      nativeBridge.browserSidebar.close.mockReset();
      nativeBridge.browserSidebar.close.mockImplementation(async () => ({
        active: false,
        available: true,
      }));
    }
  });

  it("retains the opening epoch when a delayed capacity reply unmounts with its host", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    let onChanged: ((state: BrowserSidebarState) => void) | undefined;
    nativeBridge.browserSidebar.onChanged.mockImplementation((listener) => {
      onChanged = listener;
      return () => undefined;
    });
    let resolveCapacity: ((state: BrowserSidebarState) => void) | undefined;
    const delayedCapacity = new Promise<BrowserSidebarState>((resolve) => {
      resolveCapacity = resolve;
    });
    const bounds = mockBrowserSidebarBounds();

    try {
      const { router } = renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open task" }));
      await waitFor(() =>
        expect(router.state.location.pathname).toBe(
          "/tasks/workspace-1/grp_test/task-a"
        )
      );
      await act(async () => {
        await router.navigate({ to: "/" });
      });

      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      const releasingSessionId = "delayed-reply-capacity-holder";
      act(() => onChanged?.(browserSidebarState(releasingSessionId)));

      nativeBridge.browserSidebar.open.mockImplementationOnce(
        async () => delayedCapacity
      );
      fireEvent.click(screen.getByRole("button", { name: "Open next browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2)
      );
      const blockedOpen = nativeBridge.browserSidebar.open.mock.calls[1]?.[0];
      const capacityState = browserSidebarState(
        blockedOpen?.sessionId ?? "missing-blocked-session",
        {
          active: false,
          reason: "Browser sidebar capacity is temporarily full.",
          reasonCode: "capacity",
          visible: false,
        }
      );

      act(() => onChanged?.(capacityState));
      act(() =>
        onChanged?.(
          browserSidebarState(releasingSessionId, {
            active: false,
            visible: false,
          })
        )
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2);

      await act(async () => {
        fireEvent.click(screen.getByRole("tab", { name: "Task A" }));
        resolveCapacity?.(capacityState);
        await delayedCapacity;
        onChanged?.(capacityState);
        await router.navigate({
          params: {
            conversationId: "task-a",
            groupId: "grp_test",
            workspaceId: "workspace-1",
          },
          to: "/tasks/$workspaceId/$groupId/$conversationId",
        });
      });
      expect(screen.getByTestId("main-conversation")).toHaveTextContent("task-a");
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2);

      await act(async () => {
        await router.navigate({ to: "/" });
      });
      expect(await screen.findByTestId("mock-conversation-task-a")).toBeVisible();
      const blockedAttemptsBeforeSelection =
        nativeBridge.browserSidebar.open.mock.calls.filter(
          ([input]) => input.sessionId === blockedOpen?.sessionId
        ).length;
      expect(blockedAttemptsBeforeSelection).toBe(1);
      fireEvent.click(await screen.findByRole("tab", { name: "Next documentation" }));

      await waitFor(() =>
        expect(
          nativeBridge.browserSidebar.open.mock.calls.filter(
            ([input]) => input.sessionId === blockedOpen?.sessionId
          )
        ).toHaveLength(2)
      );
      expect(nativeBridge.browserSidebar.open.mock.calls.at(-1)?.[0]).toEqual(
        expect.objectContaining({
          navigationRevision: blockedOpen?.navigationRevision,
          sessionId: blockedOpen?.sessionId,
          url: blockedOpen?.url,
        })
      );
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("reopens inactive visible pages once without retrying an inactive reopen", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    let onChanged: ((state: BrowserSidebarState) => void) | undefined;
    nativeBridge.browserSidebar.onChanged.mockImplementation((listener) => {
      onChanged = listener;
      return () => undefined;
    });
    let failNextVisibleUpdate = false;
    nativeBridge.browserSidebar.update.mockImplementation(async (input) => {
      if (input.visible === true && failNextVisibleUpdate) {
        failNextVisibleUpdate = false;
        return browserSidebarState(input.sessionId, {
          active: false,
          visible: false,
        });
      }
      return browserSidebarState(input.sessionId, {
        visible: input.visible ?? true,
      });
    });
    const bounds = mockBrowserSidebarBounds();

    try {
      renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      fireEvent.click(screen.getByRole("tab", { name: "Task A" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
          visible: false,
        })
      );

      failNextVisibleUpdate = true;
      fireEvent.click(screen.getByRole("tab", { name: "Documentation" }));

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2)
      );

      const firstOpen = nativeBridge.browserSidebar.open.mock.calls[0]?.[0];
      const sessionId = firstOpen?.sessionId;
      expect(nativeBridge.browserSidebar.open.mock.calls[1]?.[0]).toEqual(
        expect.objectContaining({
          navigationRevision: firstOpen?.navigationRevision,
          sessionId,
          url: firstOpen?.url,
        })
      );
      nativeBridge.browserSidebar.open.mockImplementationOnce(async (input) =>
        browserSidebarState(input.sessionId, { active: false, visible: false })
      );
      const inactiveState = browserSidebarState(sessionId ?? "missing-session", {
        active: false,
        visible: false,
      });
      act(() => onChanged?.(inactiveState));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(3)
      );
      expect(nativeBridge.browserSidebar.open.mock.calls[2]?.[0]).toEqual(
        expect.objectContaining({
          navigationRevision: firstOpen?.navigationRevision,
          sessionId,
          url: firstOpen?.url,
        })
      );

      act(() => onChanged?.(inactiveState));
      await new Promise((resolve) => window.setTimeout(resolve, 0));
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(3);
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("passes the exact renderer-evicted session to Main before a capacity open", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.close.mockClear();
    nativeBridge.browserSidebar.close.mockImplementation(async ({ sessionId }) =>
      browserSidebarState(sessionId, { active: false, visible: false })
    );
    const bounds = mockBrowserSidebarBounds();

    try {
      renderCapacityFenceRouter();
      fireEvent.click(
        await screen.findByRole("button", { name: "Open protected browser page" })
      );
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      const protectedSessionId =
        nativeBridge.browserSidebar.open.mock.calls[0]?.[0].sessionId;
      expect(
        nativeBridge.browserSidebar.open.mock.calls[0]?.[0].closeBeforeOpenSessionIds
      ).toEqual([]);
      expect(protectedSessionId).toContain(
        `${chatSidebarHostKey(protectedCapacityHost)}::`
      );

      fireEvent.click(
        screen.getByRole("button", { name: "Show admitting browser host" })
      );
      await waitFor(() =>
        expect(screen.getByTestId("capacity-active-host")).toHaveTextContent(
          admittingCapacityHost.conversationId
        )
      );

      const openNext = screen.getByRole("button", {
        name: "Open next admitting browser page",
      });
      for (let index = 0; index < maxBrowserSidebarSessionsPerOwner - 1; index += 1) {
        fireEvent.click(openNext);
        await waitFor(() =>
          expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(index + 2)
        );
      }

      const admittingHostPrefix = `${chatSidebarHostKey(admittingCapacityHost)}::`;
      const victimSessionId = nativeBridge.browserSidebar.open.mock.calls
        .map(([input]) => input.sessionId)
        .find((sessionId) => sessionId.startsWith(admittingHostPrefix));
      expect(victimSessionId).toBeTruthy();

      fireEvent.click(screen.getByRole("button", { name: "Add admitting blank page" }));
      await waitFor(() =>
        expect(screen.getByTestId("capacity-page-count")).toHaveTextContent(
          String(maxBrowserSidebarSessionsPerOwner)
        )
      );
      const openCountBeforeAdmission =
        nativeBridge.browserSidebar.open.mock.calls.length;
      nativeBridge.browserSidebar.close.mockClear();

      fireEvent.click(
        screen.getByRole("button", { name: "Fill admitting blank page" })
      );

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(
          openCountBeforeAdmission + 1
        )
      );
      expect(nativeBridge.browserSidebar.open.mock.calls.at(-1)?.[0]).toEqual(
        expect.objectContaining({
          closeBeforeOpenSessionIds: [victimSessionId],
          sessionId: expect.stringMatching(
            new RegExp(`^${escapeRegExp(admittingHostPrefix)}`)
          ),
          url: "https://example.com/admitted",
        })
      );
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.close).toHaveBeenCalledWith({
          sessionId: victimSessionId,
        })
      );
      expect(nativeBridge.browserSidebar.close).not.toHaveBeenCalledWith({
        sessionId: protectedSessionId,
      });
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
      nativeBridge.browserSidebar.close.mockReset();
      nativeBridge.browserSidebar.close.mockImplementation(async () => ({
        active: false,
        available: true,
      }));
    }
  });

  it("waits for usable geometry before latching an inactive-page recovery", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    let onChanged: ((state: BrowserSidebarState) => void) | undefined;
    nativeBridge.browserSidebar.onChanged.mockImplementation((listener) => {
      onChanged = listener;
      return () => undefined;
    });
    const bounds = mockBrowserSidebarBounds();
    const readyBounds = document.createElement("div").getBoundingClientRect();
    let geometryReady = true;
    let zeroBoundsReads = 0;
    bounds.mockImplementation(() => {
      if (geometryReady) return readyBounds;
      zeroBoundsReads += 1;
      return {
        bottom: 0,
        height: 0,
        left: 0,
        right: 0,
        toJSON: () => ({}),
        top: 0,
        width: 0,
        x: 0,
        y: 0,
      };
    });

    try {
      renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      await act(
        () =>
          new Promise<void>((resolve) => {
            window.requestAnimationFrame(() => resolve());
          })
      );

      const firstOpen = nativeBridge.browserSidebar.open.mock.calls[0]?.[0];
      const inactiveState = browserSidebarState(
        firstOpen?.sessionId ?? "missing-session",
        { active: false, visible: false }
      );
      nativeBridge.browserSidebar.open.mockImplementationOnce(async (input) =>
        browserSidebarState(input.sessionId, { active: false, visible: false })
      );
      geometryReady = false;
      act(() => onChanged?.(inactiveState));

      await waitFor(() => expect(zeroBoundsReads).toBeGreaterThan(0));
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce();

      geometryReady = true;
      act(() => window.dispatchEvent(new Event("resize")));

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2)
      );
      expect(nativeBridge.browserSidebar.open.mock.calls[1]?.[0]).toEqual(
        expect.objectContaining({
          navigationRevision: firstOpen?.navigationRevision,
          sessionId: firstOpen?.sessionId,
          url: firstOpen?.url,
        })
      );

      act(() => {
        onChanged?.(inactiveState);
        window.dispatchEvent(new Event("resize"));
      });
      await act(
        () =>
          new Promise<void>((resolve) => {
            window.requestAnimationFrame(() => resolve());
          })
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledTimes(2);
    } finally {
      bounds.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("keeps the native browser view alive while switching between Browser and Chat", async () => {
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.open.mockClear();
    const reloadedState = {
      active: true,
      available: true,
      canGoBack: false,
      canGoForward: false,
      loading: false,
      sessionId: `${commaCenterSessionId}::reload-page`,
      url: "https://example.com/docs",
      visible: true,
    };
    let resolveReload: ((state: typeof reloadedState) => void) | undefined;
    const pendingReload = new Promise<typeof reloadedState>((resolve) => {
      resolveReload = resolve;
    });
    nativeBridge.browserSidebar.navigate.mockImplementationOnce(
      async () => pendingReload
    );
    const bounds = vi
      .spyOn(HTMLElement.prototype, "getBoundingClientRect")
      .mockReturnValue({
        bottom: 640,
        height: 600,
        left: 0,
        right: 1_240,
        toJSON: () => ({}),
        top: 40,
        width: 1_240,
        x: 0,
        y: 40,
      });
    try {
      renderSidebarRouter();

      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      expect(screen.getByRole("textbox", { name: "Address" })).toHaveValue(
        "https://example.com/docs"
      );
      await waitFor(() =>
        expect(screen.getByRole("button", { name: "Reload" })).toBeEnabled()
      );
      const reloadButton = screen.getByRole("button", { name: "Reload" });
      expect(reloadButton.querySelector("svg")).not.toBeNull();
      expect(reloadButton).not.toHaveTextContent("Reload");
      fireEvent.click(reloadButton);
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.navigate).toHaveBeenCalledWith({
          action: "reload",
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
        })
      );

      const addressInput = screen.getByRole("textbox", { name: "Address" });
      fireEvent.focus(addressInput);
      fireEvent.change(addressInput, {
        target: { value: "example.org/next" },
      });
      await act(async () => {
        resolveReload?.(reloadedState);
        await pendingReload;
      });
      expect(addressInput).toHaveValue("example.org/next");
      fireEvent.submit(screen.getByRole("form", { name: "Browser navigation" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
          url: "https://example.org/next",
        })
      );
      bounds.mockReturnValue({
        bottom: 640,
        height: 600,
        left: 40,
        right: 1_280,
        toJSON: () => ({}),
        top: 40,
        width: 1_240,
        x: 40,
        y: 40,
      });
      fireEvent.transitionEnd(screen.getByTestId("chat-sidebar"), {
        propertyName: "width",
      });
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          bounds: {
            height: 600,
            width: 440,
            x: 840,
            y: 40,
          },
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
        })
      );
      bounds.mockReturnValue({
        bottom: 640,
        height: 600,
        left: 0,
        right: 1_240,
        toJSON: () => ({}),
        top: 40,
        width: 1_240,
        x: 0,
        y: 40,
      });
      fireEvent.keyDown(
        screen.getByRole("separator", { name: "Resize chat sidebar" }),
        { key: "ArrowLeft" }
      );
      // JSDOM has no layout/ResizeObserver delivery. Signal completion of the
      // actual sidebar width transition instead of relying on effect remounts.
      fireEvent.transitionEnd(screen.getByTestId("chat-sidebar"), {
        propertyName: "width",
      });
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          bounds: {
            height: 600,
            width: 456,
            x: 784,
            y: 40,
          },
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
        })
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce();
      expect(nativeBridge.browserSidebar.close).not.toHaveBeenCalled();

      fireEvent.click(screen.getByRole("tab", { name: "Task A" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
          visible: false,
        })
      );
      expect(nativeBridge.browserSidebar.close).not.toHaveBeenCalled();

      fireEvent.click(screen.getByRole("tab", { name: "Documentation" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
          visible: true,
        })
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce();
      expect(nativeBridge.browserSidebar.close).not.toHaveBeenCalled();

      const toggle = screen.getByRole("button", { name: "Toggle chat sidebar" });
      fireEvent.click(toggle);
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
          visible: false,
        })
      );
      expect(nativeBridge.browserSidebar.close).not.toHaveBeenCalled();

      fireEvent.click(toggle);
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
          visible: true,
        })
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce();
      expect(nativeBridge.browserSidebar.close).not.toHaveBeenCalled();
    } finally {
      bounds.mockRestore();
      nativeBridge.platform = "web";
    }
  });

  it("keeps the live browser during snapshot decode and cancels a pending decode on unmount", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.capture.mockResolvedValueOnce({
      pngImage: new Uint8Array([137, 80, 78, 71]),
      status: "ready",
    });
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:browser-snapshot");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});
    const bounds = mockBrowserSidebarBounds();
    const suppressionClaim = "installed-snapshot-unmount";
    const decoded = deferred<void>();
    const decode = vi.fn(() => decoded.promise);
    const decodeDescriptor = Object.getOwnPropertyDescriptor(
      HTMLImageElement.prototype,
      "decode"
    );
    Object.defineProperty(HTMLImageElement.prototype, "decode", {
      configurable: true,
      value: decode,
    });

    try {
      const rendered = renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );

      act(() => claimNativeSurfaceSuppression(suppressionClaim));
      await waitFor(() => expect(createObjectURL).toHaveBeenCalledOnce());
      expect(
        rendered.container.querySelector(".comma-chat-sidebar-browser-snapshot")
      ).toHaveAttribute("src", "blob:browser-snapshot");

      await waitFor(() => expect(decode).toHaveBeenCalledOnce());
      await act(() => new Promise((resolve) => window.setTimeout(resolve, 100)));
      expect(
        nativeBridge.browserSidebar.update.mock.calls.filter(
          ([input]) => input.visible === false
        )
      ).toHaveLength(0);
      rendered.unmount();
      await act(async () => undefined);
      const hideCallsAfterUnmount =
        nativeBridge.browserSidebar.update.mock.calls.filter(
          ([input]) => input.visible === false
        ).length;
      await act(async () => {
        decoded.resolve();
        await decoded.promise;
      });
      expect(
        nativeBridge.browserSidebar.update.mock.calls.filter(
          ([input]) => input.visible === false
        )
      ).toHaveLength(hideCallsAfterUnmount);

      expect(revokeObjectURL).toHaveBeenCalledTimes(1);
      expect(revokeObjectURL).toHaveBeenCalledWith("blob:browser-snapshot");
    } finally {
      if (decodeDescriptor) {
        Object.defineProperty(HTMLImageElement.prototype, "decode", decodeDescriptor);
      } else {
        Reflect.deleteProperty(HTMLImageElement.prototype, "decode");
      }
      releaseNativeSurfaceSuppression(suppressionClaim);
      bounds.mockRestore();
      createObjectURL.mockRestore();
      revokeObjectURL.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("ignores a browser suppression capture that resolves after viewport unmount", async () => {
    resetBrowserSidebarMocks();
    nativeBridge.platform = "electron";
    const capture = deferred<Awaited<ReturnType<BrowserSidebarBridge["capture"]>>>();
    nativeBridge.browserSidebar.capture.mockReturnValueOnce(capture.promise);
    const createObjectURL = vi
      .spyOn(URL, "createObjectURL")
      .mockReturnValue("blob:late-browser-snapshot");
    const revokeObjectURL = vi
      .spyOn(URL, "revokeObjectURL")
      .mockImplementation(() => {});
    const bounds = mockBrowserSidebarBounds();
    const suppressionClaim = "pending-snapshot-unmount";

    try {
      const rendered = renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );

      act(() => claimNativeSurfaceSuppression(suppressionClaim));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.capture).toHaveBeenCalledOnce()
      );

      rendered.unmount();
      await act(async () => undefined);
      const hideCallsAfterUnmount =
        nativeBridge.browserSidebar.update.mock.calls.filter(
          ([input]) => input.visible === false
        ).length;

      await act(async () => {
        capture.resolve({
          pngImage: new Uint8Array([137, 80, 78, 71]),
          status: "ready",
        });
        await capture.promise;
        await new Promise((resolve) => window.setTimeout(resolve, 60));
      });

      expect(createObjectURL).not.toHaveBeenCalled();
      expect(revokeObjectURL).not.toHaveBeenCalled();
      expect(
        nativeBridge.browserSidebar.update.mock.calls.filter(
          ([input]) => input.visible === false
        )
      ).toHaveLength(hideCallsAfterUnmount);
    } finally {
      releaseNativeSurfaceSuppression(suppressionClaim);
      bounds.mockRestore();
      createObjectURL.mockRestore();
      revokeObjectURL.mockRestore();
      resetBrowserSidebarMocks();
    }
  });

  it("holds the toast stack clear of the native view while it is showing", async () => {
    // The native view composites above the renderer, so the toast stack has to
    // move rather than layer over it. The claim is the distance from the
    // window's right edge to the view's left edge, and it is surrendered the
    // moment another surface takes the sidebar or the sidebar closes.
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.open.mockClear();
    const bounds = vi
      .spyOn(HTMLElement.prototype, "getBoundingClientRect")
      .mockReturnValue({
        bottom: 640,
        height: 600,
        left: 572,
        right: 1_012,
        toJSON: () => ({}),
        top: 40,
        width: 440,
        x: 572,
        y: 40,
      });
    const unregisterReader = registerToastObstructionTarget(document.body);
    try {
      renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      await waitFor(() =>
        expect(toastObstruction()).toBe(`${window.innerWidth - 572}px`)
      );

      // Another surface takes the sidebar: the native claim goes, and the
      // stack falls back to clearing the sidebar's own (mocked, 440px) box —
      // the corner belongs to the content column while the panel is open.
      fireEvent.click(screen.getByRole("tab", { name: "Task A" }));
      await waitFor(() => expect(toastObstruction()).toBe("440px"));

      fireEvent.click(screen.getByRole("tab", { name: "Documentation" }));
      await waitFor(() =>
        expect(toastObstruction()).toBe(`${window.innerWidth - 572}px`)
      );

      // Closing the sidebar surrenders both claims. jsdom never animates the
      // aside's width down, so let the rect mock go before the close: the
      // sidebar then measures 0 and releases, as it does after the real exit.
      bounds.mockRestore();
      fireEvent.click(screen.getByRole("button", { name: "Toggle chat sidebar" }));
      await waitFor(() => expect(toastObstruction()).toBe("0px"));
    } finally {
      unregisterReader();
      bounds.mockRestore();
      nativeBridge.platform = "web";
    }
  });

  it("caps oversized native bounds and does not reveal the browser after close", async () => {
    nativeBridge.platform = "electron";
    nativeBridge.browserSidebar.open.mockClear();
    nativeBridge.browserSidebar.update.mockClear();
    const openedState = {
      active: true,
      available: true,
      canGoBack: false,
      canGoForward: false,
      loading: false,
      sessionId: `${commaCenterSessionId}::open-page`,
      url: "https://example.com/docs",
      visible: true,
    };
    let resolveOpen: ((state: typeof openedState) => void) | undefined;
    const pendingOpen = new Promise<typeof openedState>((resolve) => {
      resolveOpen = resolve;
    });
    nativeBridge.browserSidebar.open.mockImplementationOnce(async () => pendingOpen);
    const bounds = vi
      .spyOn(HTMLElement.prototype, "getBoundingClientRect")
      .mockReturnValue({
        bottom: 640,
        height: 600,
        left: 0,
        right: 1_240,
        toJSON: () => ({}),
        top: 40,
        width: 1_240,
        x: 0,
        y: 40,
      });

    try {
      renderSidebarRouter();
      fireEvent.click(await screen.findByRole("button", { name: "Open browser" }));
      await waitFor(() =>
        expect(nativeBridge.browserSidebar.open).toHaveBeenCalledOnce()
      );
      expect(nativeBridge.browserSidebar.open).toHaveBeenCalledWith({
        bounds: {
          height: 600,
          width: 440,
          x: 800,
          y: 40,
        },
        closeBeforeOpenSessionIds: [],
        navigationRevision: 1,
        sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
        tabId: expect.any(String),
        url: "https://example.com/docs",
      });

      fireEvent.click(screen.getByRole("button", { name: "Toggle chat sidebar" }));
      await act(async () => {
        resolveOpen?.(openedState);
        await pendingOpen;
      });

      await waitFor(() =>
        expect(nativeBridge.browserSidebar.update).toHaveBeenCalledWith({
          sessionId: expect.stringContaining(`${commaCenterSessionId}::`),
          visible: false,
        })
      );
      expect(
        nativeBridge.browserSidebar.update.mock.calls.some(
          ([input]) => "bounds" in input && input.visible === true
        )
      ).toBe(false);
    } finally {
      bounds.mockRestore();
      nativeBridge.platform = "web";
    }
  });
});

function SidebarRegistryHarness() {
  const [host, setHost] = useState(commaCenterHost);
  const sidebar = useChatSidebar();
  useRegisterChatSidebarHost(host, {
    commaCenter: host.conversationId === commaCenterHost.conversationId,
  });

  return (
    <div>
      <output data-testid="active-host">
        {sidebar.activeHost?.conversationId ?? "none"}
      </output>
      <output data-testid="active-sidebar-chat">
        {activeSidebarChat(sidebar.activeSession)?.conversationId ?? "none"}
      </output>
      <output data-testid="active-sidebar-tab">
        {sidebar.activeSession?.activeSurface ?? "none"}
      </output>
      <output data-testid="active-browser-url">
        {sidebar.activeSession?.browserPages.find(
          (page) => page.id === sidebar.activeSession?.activeBrowserPageId
        )?.url ??
          sidebar.activeSession?.browserPages[0]?.url ??
          "none"}
      </output>
      <output data-testid="active-browser-id">
        {sidebar.activeSession?.activeBrowserPageId ?? "none"}
      </output>
      <output data-testid="comma-lineage">
        {String(sidebar.canOpenChildChat(commaCenterHost))}
      </output>
      <output data-testid="task-a-lineage">
        {String(sidebar.canOpenChildChat(taskA))}
      </output>
      <output data-testid="task-b-lineage">
        {String(sidebar.canOpenChildChat(taskB))}
      </output>
      <output data-testid="unrelated-lineage">
        {String(sidebar.canOpenChildChat(unrelatedHost))}
      </output>
      <button onClick={() => sidebar.openChat(commaCenterHost, taskA)} type="button">
        Open task A
      </button>
      <button
        onClick={() =>
          sidebar.openBrowser(commaCenterHost, {
            title: "Documentation",
            url: "https://example.com/docs",
          })
        }
        type="button"
      >
        Open browser
      </button>
      <button onClick={() => sidebar.selectChat(commaCenterHost)} type="button">
        Select Chat tab
      </button>
      <button
        onClick={() => {
          sidebar.openChat(taskA, taskB);
          setHost(taskA);
        }}
        type="button"
      >
        Promote A and open task B
      </button>
      <button onClick={() => setHost(commaCenterHost)} type="button">
        Return to Comma assistant
      </button>
      <button onClick={() => setHost(taskA)} type="button">
        Return to task A
      </button>
    </div>
  );
}

function SidebarEvictionHarness() {
  const [opened, setOpened] = useState(0);
  const [inspectedHostIndex, setInspectedHostIndex] = useState(0);
  const sidebar = useChatSidebar();
  const inspectedHost = browserEvictionHost(inspectedHostIndex);
  useRegisterChatSidebarHost(inspectedHost);
  const inspectedPage = sidebar.activeSession?.browserPages[0];

  return (
    <div>
      <output data-testid="opened-browser-hosts">{opened}</output>
      <output data-testid="inspected-browser-host">
        {sidebar.activeHost?.conversationId ?? "none"}
      </output>
      <output data-testid="inspected-browser-status">
        {sidebar.activeSession ? "retained" : "missing"}
      </output>
      <output data-testid="inspected-browser-title">
        {inspectedPage?.title ?? "none"}
      </output>
      <output data-testid="inspected-browser-fence">
        {inspectedPage?.closeBeforeOpenSessionIds?.join(",") ?? "none"}
      </output>
      <button
        onClick={() => {
          const host = browserEvictionHost(opened);
          sidebar.openBrowser(host, {
            url: `https://example.com/${opened}`,
          });
          setOpened((current) => current + 1);
        }}
        type="button"
      >
        Open next browser host
      </button>
      <button
        onClick={() => {
          if (!inspectedPage) return;
          sidebar.updateBrowserPage(browserEvictionHost(0), inspectedPage.id, {
            title: "Touched oldest",
          });
        }}
        type="button"
      >
        Touch oldest host
      </button>
      <button onClick={() => setInspectedHostIndex(1)} type="button">
        Inspect next-oldest host
      </button>
      <button onClick={() => setInspectedHostIndex(0)} type="button">
        Inspect oldest host
      </button>
      <button
        onClick={() => setInspectedHostIndex(maxBrowserSidebarSessionsPerOwner)}
        type="button"
      >
        Inspect newest host
      </button>
    </div>
  );
}

function browserEvictionHost(index: number): ChatSidebarHost {
  return {
    conversationId: `browser-host-${index}`,
    groupId: "grp_test",
    workspaceId: "workspace-1",
  };
}

function SidebarPageEvictionHarness() {
  const [opened, setOpened] = useState(0);
  const sidebar = useChatSidebar();
  useRegisterChatSidebarHost(pageEvictionHost);
  const pages = sidebar.activeSession?.browserPages ?? [];
  const activePage = pages.find(
    (page) => page.id === sidebar.activeSession?.activeBrowserPageId
  );
  const firstUrlPage = pages.find((page) => Boolean(page.url));

  return (
    <div>
      <output data-testid="opened-browser-pages">{opened}</output>
      <output data-testid="browser-page-count">{pages.length}</output>
      <output data-testid="first-browser-page-id">{pages[0]?.id ?? "none"}</output>
      <output data-testid="first-url-page-id">{firstUrlPage?.id ?? "none"}</output>
      <output data-testid="active-browser-page-id">{activePage?.id ?? "none"}</output>
      <output data-testid="active-browser-page-url">{activePage?.url ?? "none"}</output>
      <button onClick={() => sidebar.addBrowserTab(pageEvictionHost)} type="button">
        Add blank browser page
      </button>
      <button
        onClick={() => {
          const firstPage = pages[0];
          if (firstPage) sidebar.selectBrowserPage(pageEvictionHost, firstPage.id);
        }}
        type="button"
      >
        Select first browser page
      </button>
      <button
        onClick={() => {
          if (activePage) {
            sidebar.updateBrowserPage(pageEvictionHost, activePage.id, {
              url: "https://example.com/active",
            });
          }
        }}
        type="button"
      >
        Fill active browser page
      </button>
      <button
        onClick={() => {
          sidebar.openBrowser(pageEvictionHost, {
            url: `https://example.com/${opened}`,
          });
          setOpened((current) => current + 1);
        }}
        type="button"
      >
        Open next browser page
      </button>
    </div>
  );
}

function CapacityFenceHarness() {
  const [host, setHost] = useState(protectedCapacityHost);
  const [opened, setOpened] = useState(0);
  const sidebar = useChatSidebar();
  useRegisterChatSidebarHost(host);
  const pages = sidebar.activeSession?.browserPages ?? [];
  const activePage = pages.find(
    (page) => page.id === sidebar.activeSession?.activeBrowserPageId
  );

  return (
    <main>
      <output data-testid="capacity-active-host">
        {sidebar.activeHost?.conversationId ?? "none"}
      </output>
      <output data-testid="capacity-page-count">{pages.length}</output>
      <button
        onClick={() =>
          sidebar.openBrowser(protectedCapacityHost, {
            url: "https://example.com/protected",
          })
        }
        type="button"
      >
        Open protected browser page
      </button>
      <button onClick={() => setHost(admittingCapacityHost)} type="button">
        Show admitting browser host
      </button>
      <button
        onClick={() => {
          sidebar.openBrowser(admittingCapacityHost, {
            url: `https://example.com/admitting-${opened}`,
          });
          setOpened((current) => current + 1);
        }}
        type="button"
      >
        Open next admitting browser page
      </button>
      <button
        onClick={() => sidebar.addBrowserTab(admittingCapacityHost)}
        type="button"
      >
        Add admitting blank page
      </button>
      <button
        onClick={() => {
          if (!activePage) return;
          sidebar.updateBrowserPage(admittingCapacityHost, activePage.id, {
            url: "https://example.com/admitted",
          });
        }}
        type="button"
      >
        Fill admitting blank page
      </button>
    </main>
  );
}

function SidebarLayout() {
  return (
    <>
      <Outlet />
      <ChatSidebarToggle />
      <ChatSidebar />
    </>
  );
}

function CommaCenterRoute() {
  const { activeSession, openBrowser, openChat, updateBrowserPage } = useChatSidebar();
  useRegisterChatSidebarHost(commaCenterHost, { commaCenter: true });
  const activeBrowserPage = activeSession?.browserPages.find(
    (page) => page.id === activeSession.activeBrowserPageId
  );

  useEffect(() => {
    openChat(commaCenterHost, taskA);
  }, [openChat]);

  return (
    <main data-testid="main-conversation">
      comma-center
      <button
        onClick={() =>
          openBrowser(commaCenterHost, {
            title: "Documentation",
            url: "https://example.com/docs",
          })
        }
        type="button"
      >
        Open browser
      </button>
      <button
        onClick={() =>
          openBrowser(commaCenterHost, {
            title: "Next documentation",
            url: "https://example.com/next",
          })
        }
        type="button"
      >
        Open next browser
      </button>
      <button
        onClick={() => {
          if (!activeBrowserPage) return;
          updateBrowserPage(commaCenterHost, activeBrowserPage.id, {
            url: "https://example.com/two",
          });
        }}
        type="button"
      >
        Navigate browser to two
      </button>
      <button
        onClick={() => {
          if (!activeBrowserPage) return;
          updateBrowserPage(commaCenterHost, activeBrowserPage.id, {
            url: "https://example.com/three",
          });
        }}
        type="button"
      >
        Navigate browser to three
      </button>
    </main>
  );
}

function TaskRoute() {
  const params = useParams({ strict: false });
  const host = {
    conversationId: params.conversationId ?? "",
    groupId: "grp_test",
    workspaceId: params.workspaceId ?? "",
  };
  useRegisterChatSidebarHost(host);

  return <main data-testid="main-conversation">{host.conversationId}</main>;
}

function browserSidebarState(
  sessionId: string,
  patch: Partial<BrowserSidebarState> = {}
): BrowserSidebarState {
  return {
    active: true,
    available: true,
    sessionId,
    visible: true,
    ...patch,
  };
}

function deferred<T>() {
  let resolve!: (value: T | PromiseLike<T>) => void;
  const promise = new Promise<T>((promiseResolve) => {
    resolve = promiseResolve;
  });
  return { promise, resolve };
}

function mockBrowserSidebarBounds() {
  return vi.spyOn(HTMLElement.prototype, "getBoundingClientRect").mockReturnValue({
    bottom: 640,
    height: 600,
    left: 0,
    right: 1_240,
    toJSON: () => ({}),
    top: 40,
    width: 1_240,
    x: 0,
    y: 40,
  });
}

function resetBrowserSidebarMocks() {
  nativeBridge.browserSidebar.capture.mockReset();
  nativeBridge.browserSidebar.capture.mockImplementation(async () => ({
    status: "unavailable",
  }));
  nativeBridge.browserSidebar.onChanged.mockReset();
  nativeBridge.browserSidebar.onChanged.mockImplementation(() => () => undefined);
  nativeBridge.browserSidebar.onOpenTabRequested.mockReset();
  nativeBridge.browserSidebar.onOpenTabRequested.mockImplementation(
    () => () => undefined
  );
  nativeBridge.browserSidebar.open.mockReset();
  nativeBridge.browserSidebar.open.mockImplementation(async ({ sessionId, url }) => ({
    ...browserSidebarState(sessionId),
    canGoBack: false,
    canGoForward: false,
    loading: false,
    url,
  }));
  nativeBridge.browserSidebar.inspect.mockReset();
  nativeBridge.browserSidebar.inspect.mockImplementation(async () => ({
    status: "cancelled",
  }));
  nativeBridge.browserSidebar.update.mockReset();
  nativeBridge.browserSidebar.update.mockImplementation(async (input) =>
    browserSidebarState(input.sessionId)
  );
  sendMessage.mockClear();
  nativeBridge.platform = "web";
}

function renderSidebarRouter({ strictMode = false } = {}) {
  const rootRoute = createRootRoute({ component: SidebarLayout });
  const commaCenterRoute = createRoute({
    component: CommaCenterRoute,
    getParentRoute: () => rootRoute,
    path: "/",
  });
  const taskRoute = createRoute({
    component: TaskRoute,
    getParentRoute: () => rootRoute,
    path: "/tasks/$workspaceId/$groupId/$conversationId",
  });
  const unsupportedRoute = createRoute({
    component: () => <main>Unsupported route</main>,
    getParentRoute: () => rootRoute,
    path: "/plugins",
  });
  const router = createRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
    routeTree: rootRoute.addChildren([commaCenterRoute, taskRoute, unsupportedRoute]),
  });

  const app = (
    <CommaWebClientSettingsProvider>
      <CommaAppShortcutsProvider>
        <ChatSidebarProvider>
          <RouterProvider router={router} />
        </ChatSidebarProvider>
      </CommaAppShortcutsProvider>
    </CommaWebClientSettingsProvider>
  );

  return {
    ...render(strictMode ? <StrictMode>{app}</StrictMode> : app),
    router,
  };
}

function renderCapacityFenceRouter() {
  const rootRoute = createRootRoute({ component: SidebarLayout });
  const capacityRoute = createRoute({
    component: CapacityFenceHarness,
    getParentRoute: () => rootRoute,
    path: "/",
  });
  const router = createRouter({
    history: createMemoryHistory({ initialEntries: ["/"] }),
    routeTree: rootRoute.addChildren([capacityRoute]),
  });

  return render(
    <CommaWebClientSettingsProvider>
      <CommaAppShortcutsProvider>
        <ChatSidebarProvider>
          <RouterProvider router={router} />
        </ChatSidebarProvider>
      </CommaAppShortcutsProvider>
    </CommaWebClientSettingsProvider>
  );
}

function escapeRegExp(value: string) {
  return value.replace(/[.*+?^${}()|[\]\\]/gu, "\\$&");
}
