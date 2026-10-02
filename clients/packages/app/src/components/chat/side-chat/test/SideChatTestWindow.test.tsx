import type { ChatRuntimeSnapshot, SideChatPresentation } from "@comma/chat-contract";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  parseSideChatTaskWindowTarget,
  parseSideChatTestWindowSourceFrame,
  SideChatTestWindow,
} from "../SideChatTestWindow";
import type { NativeStateBridge } from "../../../../runtime-side-chat/nativeSideChat";
import {
  createTestSessionHostController,
  signedInSessionSnapshot,
} from "../../../../test/sessionHostHarness";
import { testProductLease } from "../../../../test/productInboxProjectionHarness";
import { CommaSessionHostProvider } from "../../../../session/react";
import { CommaWebClientSettingsProvider } from "../../../commaClientSettings";

const renderWithClientSettings = (children: React.ReactNode) =>
  render(<CommaWebClientSettingsProvider>{children}</CommaWebClientSettingsProvider>);

describe("SideChatTestWindow", () => {
  beforeEach(() => {
    window.location.hash =
      "#/side-chat/test-window?sourceHeight=30&sourceWidth=32&sourceX=42.5&sourceY=84.25";
    Object.defineProperties(window, {
      devicePixelRatio: { configurable: true, value: 2 },
      innerHeight: { configurable: true, value: 900 },
      innerWidth: { configurable: true, value: 1440 },
    });
  });

  afterEach(() => {
    window.location.hash = "";
    document.body.removeAttribute("data-comma-window-role");
    localStorage.clear();
    vi.unstubAllGlobals();
    vi.useRealTimers();
  });

  it("parses a task conversation target only when both ids are present", () => {
    expect(
      parseSideChatTaskWindowTarget(
        "#/side-chat/test-window?workspaceId=wsp_1&groupId=grp_1&conversationId=cnv_task_1"
      )
    ).toEqual({
      conversationId: "cnv_task_1",
      groupId: "grp_1",
      workspaceId: "wsp_1",
    });
    expect(
      parseSideChatTaskWindowTarget("#/side-chat/test-window?workspaceId=wsp_1")
    ).toBeUndefined();
  });

  it("morphs from the source frame, streams presentation metrics, and explicitly refreshes them", async () => {
    const presentationState = createControllableStateBridge(
      createPresentation({ progress: 0.64, revision: 7 })
    );
    installTestWindowBridge({ presentationState });

    const { container } = renderWithClientSettings(<SideChatTestWindow />);
    const root = container.querySelector<HTMLElement>(".comma-side-chat-test-window")!;

    expect(root).toHaveAttribute("data-source-x", "42.5");
    expect(root).toHaveAttribute("data-source-y", "84.25");
    expect(root.style.getPropertyValue("--source-width")).toBe("32px");
    expect(root.style.getPropertyValue("--source-height")).toBe("30px");
    expect(await screen.findByText("1440 × 900 pt")).toBeInTheDocument();
    expect(screen.getByText("2880 × 1800")).toBeInTheDocument();
    expect(screen.getByText("open · 64%")).toBeInTheDocument();
    expect(screen.getByText("1 / 0 pt")).toBeInTheDocument();
    expect(screen.getByText("7")).toBeInTheDocument();
    expect(screen.queryByText("Messages")).not.toBeInTheDocument();
    expect(screen.queryByText("Draft")).not.toBeInTheDocument();
    expect(screen.queryByText("Streaming")).not.toBeInTheDocument();
    await waitFor(() => expect(root).toHaveAttribute("data-expanded", "true"));
    await waitFor(() => expect(root).toHaveAttribute("data-content-visible", "true"));

    const readsBeforeSubscription = presentationState.get.mock.calls.length;
    act(() =>
      presentationState.emit(
        createPresentation({
          offsetX: -120.25,
          phase: "interactive",
          progress: 0.5,
          revision: 8,
        })
      )
    );

    await waitFor(() => expect(screen.getByText("interactive · 50%")).toBeVisible());
    expect(screen.getByText("1 / -120.25 pt")).toBeVisible();
    expect(screen.getByText("8")).toBeVisible();
    expect(presentationState.get).toHaveBeenCalledTimes(readsBeforeSubscription);

    presentationState.set(
      createPresentation({
        offsetX: -120.25,
        phase: "open",
        progress: 0.75,
        revision: 9,
      })
    );
    const readsBeforeRefresh = presentationState.get.mock.calls.length;
    fireEvent.click(screen.getByRole("button", { name: "Refresh content" }));

    await waitFor(() => expect(screen.getByText("open · 75%")).toBeVisible());
    expect(screen.getByText("1 / -120.25 pt")).toBeVisible();
    expect(screen.getByText("9")).toBeVisible();
    expect(presentationState.get).toHaveBeenCalledTimes(readsBeforeRefresh + 1);
  });

  it("does not regress metrics when subscription or refresh returns an older revision", async () => {
    const presentationState = createControllableStateBridge(createPresentation());
    installTestWindowBridge({ presentationState });

    renderWithClientSettings(<SideChatTestWindow />);
    expect(await screen.findByText("open · 100%")).toBeInTheDocument();

    act(() =>
      presentationState.emit(
        createPresentation({
          offsetX: -80,
          phase: "interactive",
          progress: 0.4,
          revision: 9,
        })
      )
    );
    await waitFor(() => expect(screen.getByText("interactive · 40%")).toBeVisible());
    expect(screen.getByText("1 / -80 pt")).toBeVisible();
    expect(screen.getByText("9")).toBeVisible();

    act(() =>
      presentationState.emit(
        createPresentation({ phase: "closed", progress: 0, revision: 8 })
      )
    );
    expect(screen.getByText("interactive · 40%")).toBeVisible();
    expect(screen.getByText("1 / -80 pt")).toBeVisible();
    expect(screen.getByText("9")).toBeVisible();

    presentationState.set(
      createPresentation({ phase: "opening", progress: 0.1, revision: 8 })
    );
    const readsBeforeRefresh = presentationState.get.mock.calls.length;
    fireEvent.click(screen.getByRole("button", { name: "Refresh content" }));
    await waitFor(() =>
      expect(presentationState.get).toHaveBeenCalledTimes(readsBeforeRefresh + 1)
    );
    expect(screen.getByText("interactive · 40%")).toBeVisible();
    expect(screen.getByText("1 / -80 pt")).toBeVisible();
    expect(screen.getByText("9")).toBeVisible();
  });

  it("finishes the task exit in 200ms and closes only the test window", async () => {
    vi.useFakeTimers();
    window.location.hash +=
      "&workspaceId=wsp_1&groupId=grp_1&conversationId=cnv_task_1";
    const close = vi.fn(async () => ({ revision: 7 }));
    const closeTestWindow = vi.fn(async () => ({ revision: 7 }));
    installTestWindowBridge({ close, closeTestWindow });

    const { container } = renderWithClientSettings(
      <CommaSessionHostProvider
        controller={createTestSessionHostController({
          initial: signedInSessionSnapshot,
        })}
      >
        <SideChatTestWindow />
      </CommaSessionHostProvider>
    );
    const root = container.querySelector<HTMLElement>(".comma-side-chat-test-window")!;
    expect(root).toHaveAttribute("data-transition-phase", "opening");
    fireEvent.pointerDown(root);

    expect(root).toHaveAttribute("data-expanded", "false");
    expect(root).toHaveAttribute("data-transition-phase", "closing");
    act(() => vi.advanceTimersByTime(199));
    expect(closeTestWindow).not.toHaveBeenCalled();
    act(() => vi.advanceTimersByTime(1));
    await vi.runAllTimersAsync();
    expect(closeTestWindow).toHaveBeenCalledOnce();
    expect(close).not.toHaveBeenCalled();
  });

  it("hands Escape to closeTestWindow without closing the Side Chat presentation", async () => {
    vi.useFakeTimers();
    const close = vi.fn(async () => ({ revision: 7 }));
    const closeTestWindow = vi.fn(async () => ({ revision: 7 }));
    installTestWindowBridge({ close, closeTestWindow });

    renderWithClientSettings(<SideChatTestWindow />);
    fireEvent.keyDown(window, { key: "Escape" });
    act(() => vi.advanceTimersByTime(500));
    await vi.runAllTimersAsync();

    expect(closeTestWindow).toHaveBeenCalledOnce();
    expect(close).not.toHaveBeenCalled();
  });

  it("opens a nested inline Task through the native replacement handoff", async () => {
    window.location.hash +=
      "&workspaceId=wsp_1&groupId=grp_1&conversationId=cnv_parent";
    const openTestWindow = vi.fn(async () => ({ revision: 8 }));
    installTestWindowBridge({
      chatState: nestedTaskChatState,
      openTestWindow,
    });

    renderWithClientSettings(
      <CommaSessionHostProvider
        controller={createTestSessionHostController({
          initial: signedInSessionSnapshot,
        })}
      >
        <SideChatTestWindow />
      </CommaSessionHostProvider>
    );

    const taskButton = await screen.findByRole("button", {
      name: "Open task: Nested task",
    });
    vi.spyOn(taskButton, "getBoundingClientRect").mockReturnValue({
      bottom: 44,
      height: 24,
      left: 12,
      right: 132,
      top: 20,
      width: 120,
      x: 12,
      y: 20,
      toJSON: () => ({}),
    } as DOMRect);

    fireEvent.click(taskButton);

    await waitFor(() =>
      expect(openTestWindow).toHaveBeenCalledWith({
        sourceFrame: {
          height: 24,
          width: 120,
          x: window.screenX + 12,
          y: window.screenY + 20,
        },
        target: {
          conversationId: "cnv_nested",
          groupId: "grp_1",
          workspaceId: "wsp_1",
        },
      })
    );
  });

  it("labels Router replies with the name of the Task's own workspace", async () => {
    window.location.hash +=
      "&workspaceId=wsp_1&groupId=grp_1&conversationId=cnv_parent";
    // Main last activated another workspace; the Task still belongs to wsp_1.
    localStorage.setItem("comma.activeWorkspaceId", "wsp_other");
    const browserFetch = globalThis.fetch;
    const fetchMock = vi.fn((input: RequestInfo | URL, init?: RequestInit) => {
      const path = new URL(String(input), "https://api.example").pathname;
      if (!path.endsWith("/agent-models")) return browserFetch(input, init);
      const router = {
        agent_id: "agent_router",
        model: "model-a",
        name: path.includes("/wsp_1/") ? "Atlas" : "Juno",
        provider: "comma",
        role: "router",
        source: "platform_default",
        template_id: "tpl_default",
        template_name: "Default",
      };
      return Promise.resolve(
        Response.json({
          agents: { router, worker: { ...router, name: "Worker", role: "worker" } },
          available_models: [],
          platform_defaults: { router: null, worker: null },
          worker_default_template_id: null,
          workers: { items: [], next_cursor: null },
          workspace_id: "wsp_1",
        })
      );
    });
    vi.stubGlobal("fetch", fetchMock);
    const session = nestedTaskChatState.sessions[0]!;
    installTestWindowBridge({
      chatState: {
        ...nestedTaskChatState,
        sessions: [
          {
            ...session,
            state: {
              ...session.state,
              messages: session.state.messages.map((message) => ({
                ...message,
                actorRole: "router" as const,
              })),
            },
          },
        ],
      },
    });

    renderWithClientSettings(
      <CommaSessionHostProvider
        controller={createTestSessionHostController({
          initial: signedInSessionSnapshot,
        })}
      >
        <SideChatTestWindow />
      </CommaSessionHostProvider>
    );

    expect(await screen.findByText("Atlas")).toHaveClass(
      "comma-chat-assistant-source-label"
    );
    expect(fetchMock.mock.calls.map(([input]) => String(input))).toEqual(
      expect.not.arrayContaining([expect.stringContaining("wsp_other")])
    );
  });

  it("takes over the first-painted shell without replaying its entrance or loading diagnostics", async () => {
    window.location.hash +=
      "&workspaceId=wsp_1&groupId=grp_1&conversationId=cnv_parent";
    const boot = document.createElement("div");
    boot.id = "comma-task-window-boot";
    let finish!: () => void;
    const finished = new Promise<void>((resolve) => {
      finish = resolve;
    });
    Object.assign(boot, { getAnimations: () => [{ finished }] });
    document.body.append(boot);
    const presentationState = createStateBridge(() => createPresentation());
    installTestWindowBridge({ chatState: nestedTaskChatState, presentationState });
    try {
      const { container } = renderWithClientSettings(
        <CommaSessionHostProvider
          controller={createTestSessionHostController({
            initial: signedInSessionSnapshot,
          })}
        >
          <SideChatTestWindow />
        </CommaSessionHostProvider>
      );
      const root = container.querySelector(".comma-side-chat-test-window")!;
      expect(root).toHaveAttribute("data-expanded", "true");
      expect(root).toHaveAttribute("data-content-visible", "true");
      expect(boot).toBeInTheDocument();
      expect(presentationState.get).not.toHaveBeenCalled();
      await act(async () => {
        finish();
        await finished;
      });
      expect(boot).not.toBeInTheDocument();
      expect(root).toHaveAttribute("data-expanded", "true");
    } finally {
      boot.remove();
    }
  });

  it("opens task links in the shared browser sidebar and retains tabs when collapsed", async () => {
    window.location.hash +=
      "&workspaceId=wsp_1&groupId=grp_1&conversationId=cnv_parent";
    const chatState = structuredClone(nestedTaskChatState);
    chatState.sessions[0]!.state.messages[0]!.parts = [
      { kind: "markdown", text: "[Preview](https://example.com/preview)" },
    ];
    chatState.sessions[0]!.state.messages[0]!.text =
      "[Preview](https://example.com/preview)";
    installTestWindowBridge({ chatState });
    const { container } = renderWithClientSettings(
      <CommaSessionHostProvider
        controller={createTestSessionHostController({
          initial: signedInSessionSnapshot,
        })}
      >
        <SideChatTestWindow />
      </CommaSessionHostProvider>
    );
    const root = container.querySelector(".comma-side-chat-test-window")!;
    const toggle = await screen.findByRole("button", { name: "Toggle chat sidebar" });
    expect(root).toHaveAttribute("data-sidebar-open", "false");
    const link = await screen.findByRole("link", { name: "Preview" });
    fireEvent.contextMenu(link);
    fireEvent.click(await screen.findByRole("menuitem", { name: "Open in Comma" }));
    expect(root).toHaveAttribute("data-sidebar-open", "true");
    expect(
      await screen.findByDisplayValue("https://example.com/preview")
    ).toBeInTheDocument();
    const sidebarPanel = screen.getByTestId("chat-sidebar");
    const dialog = screen.getByRole("dialog", { name: "Task chat" });
    expect(dialog).not.toContainElement(sidebarPanel);
    expect(sidebarPanel.parentElement).toHaveClass("comma-side-chat-task-sidebar");
    expect(sidebarPanel.parentElement?.parentElement).toBe(root);
    const offsetBeforeResize = (root as HTMLElement).style.getPropertyValue(
      "--task-chat-offset"
    );
    const resizeHandle = screen.getByRole("separator", { name: "Resize chat sidebar" });
    fireEvent.keyDown(resizeHandle, { key: "Home" });
    expect((root as HTMLElement).style.getPropertyValue("--task-chat-offset")).not.toBe(
      offsetBeforeResize
    );
    fireEvent.click(toggle);
    expect(root).toHaveAttribute("data-sidebar-open", "false");
    fireEvent.click(toggle);
    expect(root).toHaveAttribute("data-sidebar-open", "true");
    expect(screen.getByDisplayValue("https://example.com/preview")).toBeInTheDocument();
  });

  it("rejects a malformed source route instead of fabricating geometry", () => {
    expect(() =>
      parseSideChatTestWindowSourceFrame(
        "#/side-chat/test-window?sourceX=0&sourceY=0&sourceWidth=0&sourceHeight=30"
      )
    ).toThrow();
  });
});

function installTestWindowBridge({
  chatState,
  close = vi.fn(async () => ({ revision: 7 })),
  closeTestWindow = vi.fn(async () => ({ revision: 7 })),
  openTestWindow = vi.fn(async () => ({ revision: 7 })),
  presentationState = createStateBridge(() => createPresentation()),
}: {
  chatState?: ChatRuntimeSnapshot;
  close?: () => Promise<{ revision: number }>;
  closeTestWindow?: () => Promise<{ revision: number }>;
  openTestWindow?: (input: {
    sourceFrame: { height: number; width: number; x: number; y: number };
    target?:
      | { conversationId: string; groupId: string; workspaceId: string }
      | undefined;
  }) => Promise<{ revision: number }>;
  presentationState?: NativeStateBridge<SideChatPresentation>;
} = {}) {
  return installNativeBridgeMock({
    ...(chatState
      ? {
          chat: {
            state: bindSessionChatStateBridge(createStateBridge(() => chatState)),
          },
        }
      : {}),
    os: "macos",
    platform: "electron",
    self: { role: "side-chat-test-window", windowId: "win_side_chat_test" },
    sideChat: {
      close,
      closeTestWindow,
      openTestWindow,
      presentation: presentationState,
    },
  });
}

function bindSessionChatStateBridge(
  state: NativeStateBridge<ChatRuntimeSnapshot>
): NativeStateBridge<
  { session: typeof testProductLease; snapshot: ChatRuntimeSnapshot },
  { session: typeof testProductLease }
> {
  const get = vi.fn(async () => ({
    session: testProductLease,
    snapshot: await state.get(),
  }));
  return Object.assign(get, {
    get,
    subscribe: vi.fn(
      (
        listener: (envelope: {
          session: typeof testProductLease;
          snapshot: ChatRuntimeSnapshot;
        }) => void
      ) =>
        state.subscribe((snapshot) => listener({ session: testProductLease, snapshot }))
    ),
  });
}

const nestedTaskChatState: ChatRuntimeSnapshot = {
  protocolVersion: 3,
  revision: 1,
  sessions: [
    {
      conversationId: "cnv_parent",
      groupId: "grp_1",
      key: "grp_1/cnv_parent",
      refs: 1,
      revision: 1,
      state: {
        awaitingReply: false,
        awaitingTimedOut: false,
        connection: "live",
        conversation: {
          groupId: "grp_1",
          id: "cnv_parent",
          kind: "agent_task",
          status: "open",
          title: "Parent task",
          workspaceId: "wsp_1",
        },
        draft: "",
        draftAttachments: [],
        lastBackoffMs: 0,
        messages: [
          {
            attachments: [],
            delivery: "sent",
            messageId: "msg_nested_task",
            parts: [
              { kind: "markdown", text: "Continue in " },
              {
                kind: "inline-task",
                task: {
                  conversationId: "cnv_nested",
                  title: "Nested task",
                  unavailable: false,
                },
              },
            ],
            refs: [],
            role: "assistant",
            source: "server",
            text: "Continue in Nested task",
          },
        ],
        pending: [],
        serverMessages: [],
        status: "ready",
      },
      workspaceId: "wsp_1",
    },
  ],
};

function createStateBridge<Snapshot>(getSnapshot: () => Promise<Snapshot> | Snapshot) {
  const get = vi.fn(async () => getSnapshot());
  return Object.assign(get, {
    get,
    subscribe: vi.fn(() => () => {}),
  }) as NativeStateBridge<Snapshot> & { get: typeof get };
}

function createControllableStateBridge<Snapshot>(initial: Snapshot) {
  let current = initial;
  const listeners = new Set<(snapshot: Snapshot) => void>();
  const get = vi.fn(async () => current);
  return Object.assign(get, {
    emit(snapshot: Snapshot) {
      current = snapshot;
      for (const listener of listeners) listener(snapshot);
    },
    get,
    set(snapshot: Snapshot) {
      current = snapshot;
    },
    subscribe: vi.fn((listener: (snapshot: Snapshot) => void) => {
      listeners.add(listener);
      void get().then((snapshot) => {
        if (listeners.has(listener)) listener(snapshot);
      });
      return () => listeners.delete(listener);
    }),
  }) as NativeStateBridge<Snapshot> & {
    emit(snapshot: Snapshot): void;
    get: typeof get;
    set(snapshot: Snapshot): void;
  };
}

function createPresentation(
  overrides: Partial<SideChatPresentation> = {}
): SideChatPresentation {
  return {
    availableContentHeight: 600,
    contentFrame: { height: 286, width: 364, x: 9, y: 3 },
    displayId: 1,
    kind: "side-chat.presentation",
    offsetX: 0,
    phase: "open",
    progress: 1,
    protocolVersion: 3,
    revision: 7,
    screenFrame: { height: 900, width: 1440, x: 0, y: 0 },
    windowFrame: { height: 412, width: 523, x: 4, y: 12 },
    ...overrides,
  };
}
