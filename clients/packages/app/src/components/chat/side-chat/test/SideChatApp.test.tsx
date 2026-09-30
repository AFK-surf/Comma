import userEvent from "@testing-library/user-event";
import type {
  ChatWorkspaceResolution,
  ChatRuntimeSnapshot,
  SideChatPresentation,
} from "@comma/chat-contract";
import { initializeCommaI18n, type CommaLocale } from "@comma/i18n";
import { CommaI18nProvider } from "@comma/i18n/react";
import type {
  SessionProductLease,
  TerminalSessionSnapshot,
} from "@comma/session-contract";
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { act, fireEvent, render, screen, waitFor } from "@comma/test-utils/render";
import type { ReactNode } from "react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { SideChatApp } from "../SideChatApp";
import { SideChatTaskCards } from "../SideChatTaskCards";
import { CommaAuthGate, useCommaAuth } from "../../../AuthGate";
import type {
  NativeStateBridge,
  ProductInboxListResult,
} from "../../../../runtime-side-chat/nativeSideChat";
import {
  ProductInboxProjectionProvider,
  type ProductInboxProjectionController,
  type ProductInboxRefresh,
} from "../../../../product-inbox";
import {
  createProductInboxProjectionHarness,
  testProductLease,
} from "../../../../test/productInboxProjectionHarness";
import {
  createTestSessionHostController,
  publishTestSessionSnapshot,
  signedInSessionSnapshot,
  signedOutSessionSnapshot,
} from "../../../../test/sessionHostHarness";
import { CommaSessionHostProvider } from "../../../../session/react";
import {
  CommaWebClientSettingsProvider,
  commaClientSettingsStorageKey,
  readWebCommaClientSettings,
} from "../../../commaClientSettings";
import { legacyCommaAppearanceStorageKey as commaAppearanceStorageKey } from "../../../readLegacyCommaClientSettings";

type AssistantFallbackCase = {
  label: string;
  resolveWorkspaceChat: () => Promise<ChatWorkspaceResolution>;
  title: string;
};

const writeSideChatAppearance = (sideChatAppearance: "auto" | "light" | "dark") => {
  localStorage.setItem(
    commaClientSettingsStorageKey,
    JSON.stringify({
      ...readWebCommaClientSettings(),
      sideChatAppearance,
    })
  );
};

const assistantFallbackCases: AssistantFallbackCase[] = [
  {
    label: "loading",
    resolveWorkspaceChat: () => new Promise<ChatWorkspaceResolution>(() => undefined),
    title: "Connecting to Comma…",
  },
  {
    label: "error",
    resolveWorkspaceChat: async () => {
      throw new Error("assistant offline");
    },
    title: "Side Chat could not connect",
  },
];

describe("SideChatApp", () => {
  beforeEach(() => {
    vi.stubGlobal(
      "ResizeObserver",
      class ResizeObserverMock {
        readonly callback: ResizeObserverCallback;

        constructor(callback: ResizeObserverCallback) {
          this.callback = callback;
        }

        disconnect() {}

        observe(target: Element) {
          this.callback(
            [
              {
                contentRect: {
                  bottom: 215,
                  height: 215,
                  left: 0,
                  right: 364,
                  top: 0,
                  width: 364,
                  x: 0,
                  y: 0,
                  toJSON: () => ({}),
                },
                target,
              } as ResizeObserverEntry,
            ],
            this as unknown as ResizeObserver
          );
        }

        unobserve() {}
      }
    );
  });

  afterEach(() => {
    initializeCommaI18n(["en"]);
    document.body.removeAttribute("data-comma-window-role");
    localStorage.clear();
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
  });

  it("uses the shared renderer provider for Simplified Chinese", async () => {
    installSideChatBridge({ sessionState: signedOutSessionSnapshot });

    renderSideChatApp("zh-CN");

    expect(await screen.findByText("登录后使用 Side Chat")).toBeInTheDocument();
    expect(screen.getByText(/请在 Comma 主窗口登录/)).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "登录" })).toBeInTheDocument();
  });

  it("applies the persisted app font size in the standalone Side Chat renderer", async () => {
    localStorage.setItem(
      commaAppearanceStorageKey,
      JSON.stringify({
        fontSize: "large",
        pointerCursors: false,
        theme: "system",
      })
    );
    installSideChatBridge({ sessionState: signedOutSessionSnapshot });

    renderSideChatApp();

    await waitFor(() =>
      expect(document.documentElement).toHaveAttribute("data-comma-font-size", "large")
    );
  });

  it("keeps the persisted Large Side Chat composer at the single-line threshold", async () => {
    localStorage.setItem(
      commaAppearanceStorageKey,
      JSON.stringify({
        fontSize: "large",
        pointerCursors: false,
        theme: "system",
      })
    );
    const originalScrollHeight = Object.getOwnPropertyDescriptor(
      HTMLElement.prototype,
      "scrollHeight"
    );
    Object.defineProperty(HTMLElement.prototype, "scrollHeight", {
      configurable: true,
      get(this: HTMLElement) {
        return this.getAttribute("aria-label") === "AI prompt" ? 20 : 0;
      },
    });

    try {
      installSideChatBridge({
        chatState: readyChatState,
        presentationState: openPresentation,
        sessionState: signedInSessionSnapshot,
      });
      renderSideChatApp();

      await waitFor(() =>
        expect(document.documentElement).toHaveAttribute(
          "data-comma-font-size",
          "large"
        )
      );
      const editor = await screen.findByRole("textbox", { name: "AI prompt" });

      expect(editor).toHaveStyle({ minHeight: "36px" });
      expect(editor.closest(".comma-chat-composer-shell")).not.toHaveAttribute(
        "data-side-chat-multiline"
      );
    } finally {
      if (originalScrollHeight) {
        Object.defineProperty(
          HTMLElement.prototype,
          "scrollHeight",
          originalScrollHeight
        );
      } else {
        delete (HTMLElement.prototype as { scrollHeight?: number }).scrollHeight;
      }
    }
  });

  it("applies persisted token themes and follows cross-window storage changes", async () => {
    let prefersDark = false;
    const colorSchemeListeners = new Set<(event: MediaQueryListEvent) => void>();
    vi.stubGlobal("matchMedia", (query: string) => ({
      addEventListener: (
        _type: "change",
        listener: (event: MediaQueryListEvent) => void
      ) => colorSchemeListeners.add(listener),
      dispatchEvent: () => true,
      matches: query === "(prefers-color-scheme: dark)" && prefersDark,
      media: query,
      onchange: null,
      removeEventListener: (
        _type: "change",
        listener: (event: MediaQueryListEvent) => void
      ) => colorSchemeListeners.delete(listener),
    }));
    writeSideChatAppearance("light");
    installSideChatBridge({ sessionState: signedOutSessionSnapshot });

    const { container } = renderSideChatApp();
    const host = container.querySelector(".comma-side-chat-host");
    expect(host).toHaveAttribute("data-theme", "Light mode");

    act(() => {
      writeSideChatAppearance("dark");
      window.dispatchEvent(
        new StorageEvent("storage", {
          key: commaClientSettingsStorageKey,
          newValue: localStorage.getItem(commaClientSettingsStorageKey),
        })
      );
    });
    await waitFor(() => expect(host).toHaveAttribute("data-theme", "Dark mode"));

    act(() => {
      writeSideChatAppearance("auto");
      window.dispatchEvent(
        new StorageEvent("storage", {
          key: commaClientSettingsStorageKey,
          newValue: localStorage.getItem(commaClientSettingsStorageKey),
        })
      );
    });
    await waitFor(() => expect(host).toHaveAttribute("data-theme", "Light mode"));

    act(() => {
      prefersDark = true;
      const event = { matches: true } as MediaQueryListEvent;
      for (const listener of colorSchemeListeners) listener(event);
    });
    await waitFor(() => expect(host).toHaveAttribute("data-theme", "Dark mode"));
  });

  it("keeps the compact signed-out shell usable and leaves presentation translation native-owned", async () => {
    vi.spyOn(HTMLElement.prototype, "scrollHeight", "get").mockImplementation(function (
      this: HTMLElement
    ) {
      return this.classList.contains("comma-side-chat-status-content") ? 160 : 0;
    });
    const close = vi.fn(async () => ({ revision: 1 }));
    const focusMainWindow = vi.fn(async () => undefined as never);
    const setContentSize = vi.fn(async () => ({ revision: 1 }));
    installSideChatBridge({
      close,
      focusMainWindow,
      setContentSize,
      sessionState: signedOutSessionSnapshot,
    });

    const { container } = renderSideChatApp();
    const host = container.querySelector<HTMLElement>(".comma-side-chat-host")!;

    expect(await screen.findByText("Sign in to use Side Chat")).toBeInTheDocument();
    expect(screen.getByText(/main window to sign in/i)).toBeInTheDocument();
    await userEvent.click(screen.getByRole("button", { name: "Sign in" }));
    expect(focusMainWindow).toHaveBeenCalledWith({ windowId: "win_main" });
    await waitFor(() => expect(host).toHaveStyle({ height: "286px" }));
    expect(document.documentElement).toHaveAttribute(
      "data-comma-window-role",
      "side-chat"
    );
    expect(document.body).toHaveAttribute("data-comma-window-role", "side-chat");
    await waitFor(() => {
      expect(host).toHaveAttribute("data-phase", "interactive");
      expect(host).toHaveAttribute("data-progress", "0.68");
    });
    expect(host.style.transform).toBe("");

    expect(screen.getByRole("textbox", { name: "AI prompt" })).toHaveStyle({
      minHeight: "36px",
    });
    expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled();

    fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => expect(close).toHaveBeenCalledTimes(1));
    await waitFor(() =>
      expect(setContentSize).toHaveBeenCalledWith(
        expect.objectContaining({ height: 330, visualHeight: 286, width: 364 })
      )
    );
  });

  it("keeps renderer geometry aligned to fresh presentation frames", async () => {
    const presentationStateBridge = createControllableStateBridge<SideChatPresentation>(
      {
        ...presentation,
        contentFrame: { height: 0, width: 0, x: 0, y: 0 },
        offsetX: -539,
        phase: "closed",
        progress: 0,
        revision: 0,
        windowFrame: { height: 0, width: 0, x: 0, y: 0 },
      }
    );
    installSideChatBridge({
      presentationStateBridge,
      sessionState: signedOutSessionSnapshot,
    });

    const { container } = renderSideChatApp();
    const host = container.querySelector<HTMLElement>(".comma-side-chat-host")!;
    expect(host).toHaveStyle({ bottom: "-9px", left: "5px", width: "364px" });
    expect(host.style.transform).toBe("");
    await waitFor(() =>
      expect(host).toHaveAttribute("data-presentation-ready", "true")
    );
    expect(host).toHaveStyle({ bottom: "-9px", left: "5px", width: "364px" });

    act(() =>
      presentationStateBridge.emit({
        ...openPresentation,
        contentFrame: {
          ...openPresentation.contentFrame,
          width: 500,
          x: 74,
          y: 32,
        },
        revision: 3,
      })
    );
    await waitFor(() =>
      expect(host).toHaveStyle({ bottom: "20px", left: "70px", width: "500px" })
    );
    expect(host.style.transform).toBe("");

    act(() =>
      presentationStateBridge.emit({
        ...openPresentation,
        revision: 2,
      })
    );
    expect(host).toHaveStyle({ bottom: "20px", left: "70px", width: "500px" });
    expect(host.style.transform).toBe("");
  });

  it.each(assistantFallbackCases)(
    "retains the composer shell while assistant resolution is $label",
    async ({ label, resolveWorkspaceChat, title }) => {
      installSideChatBridge({
        resolveWorkspaceChat,
        sessionState: signedInSessionSnapshot,
      });

      renderSideChatApp();

      if (label === "loading") {
        const status = await screen.findByRole("status", { name: title });
        expect(status).toHaveAttribute("aria-busy", "true");
        expect(
          status.querySelector('[data-slot="comma-logo-animation"]')
        ).toBeInTheDocument();
      } else {
        expect(await screen.findByText(title)).toBeInTheDocument();
      }
      expect(screen.getByRole("textbox", { name: "AI prompt" })).toBeEnabled();
      expect(screen.getByRole("button", { name: "Send message" })).toBeDisabled();
    }
  );

  it.each(assistantFallbackCases)(
    "discards the $label fallback composer draft after a generation bump and account switch",
    async ({ label, resolveWorkspaceChat, title }) => {
      installSideChatBridge({
        bumpGenerationOnReconcile: true,
        resolveWorkspaceChat,
        sessionState: signedInSessionSnapshot,
      });

      renderSideChatApp();

      expect(
        await (label === "loading"
          ? screen.findByRole("status", { name: title })
          : screen.findByText(title))
      ).toBeInTheDocument();
      const editor = screen.getByRole("textbox", { name: "AI prompt" });
      await userEvent.type(editor, "Account A draft");
      expect(editor).toHaveTextContent("Account A draft");
      expect(editor).toHaveAttribute("data-empty", "false");

      await act(() =>
        currentSessionHostController.lifecycle.reconcile({ reason: "manual_retry" })
      );

      expect(
        await (label === "loading"
          ? screen.findByRole("status", { name: title })
          : screen.findByText(title))
      ).toBeInTheDocument();
      const afterBump = screen.getByRole("textbox", { name: "AI prompt" });
      expect(afterBump).not.toBe(editor);
      expect(afterBump).toHaveAttribute("data-empty", "true");
      expect(afterBump).toHaveTextContent(/^$/);

      await userEvent.type(afterBump, "Still account A");
      expect(afterBump).toHaveTextContent("Still account A");

      act(() => {
        publishTestSessionSnapshot(currentSessionHostController, {
          ...signedInSessionSnapshot,
          generation: signedInSessionSnapshot.generation + 2,
          principal: {
            email: "other@example.com",
            userId: "usr_2",
          },
          revision: signedInSessionSnapshot.revision + 2,
          session: {
            ...signedInSessionSnapshot.session,
            sessionId: "22222222-2222-4222-8222-222222222222",
          },
        });
      });

      expect(
        await (label === "loading"
          ? screen.findByRole("status", { name: title })
          : screen.findByText(title))
      ).toBeInTheDocument();
      const afterAccount = screen.getByRole("textbox", { name: "AI prompt" });
      expect(afterAccount).not.toBe(afterBump);
      expect(afterAccount).toHaveAttribute("data-empty", "true");
      expect(afterAccount).toHaveTextContent(/^$/);
    }
  );

  it("leaves an unauthorized Session transition exclusively to Main", async () => {
    const signOut = vi.fn(async () => ({
      ...signedOutSessionSnapshot,
      revision: signedInSessionSnapshot.revision + 1,
    }));
    installSideChatBridge({
      resolveWorkspaceChat: async () => ({ status: "unauthorized" }),
      sessionState: signedInSessionSnapshot,
      signOut,
    });

    renderSideChatApp();

    expect(await screen.findByText("Your Comma session expired")).toBeInTheDocument();
    expect(signOut).not.toHaveBeenCalled();
    expect(screen.queryByRole("button", { name: "Sign in" })).toBeNull();
    expect(signOut).not.toHaveBeenCalled();
  });

  it("keeps the current session when the workspace is hidden", async () => {
    const signOut = vi.fn(async () => signedOutSessionSnapshot);
    installSideChatBridge({
      resolveWorkspaceChat: async () => ({ status: "hidden" }),
      sessionState: signedInSessionSnapshot,
      signOut,
    });

    renderSideChatApp();

    expect(await screen.findByText("Side Chat is unavailable")).toBeInTheDocument();
    expect(signOut).not.toHaveBeenCalled();
  });

  it("renders workspace provisioning without entering Chat", async () => {
    const signOut = vi.fn(async () => signedOutSessionSnapshot);
    installSideChatBridge({
      resolveWorkspaceChat: async () => ({
        groupId: "grp_reserved",
        retryAfterSeconds: 30,
        status: "provisioning",
        workspaceId: "wsp_reserved",
      }),
      sessionState: signedInSessionSnapshot,
      signOut,
    });

    renderSideChatApp();

    expect(await screen.findByText("Preparing your workspace…")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Retry now" })).toBeEnabled();
    expect(screen.queryByText("Hello from Comma")).toBeNull();
    expect(signOut).not.toHaveBeenCalled();
  });

  it("leaves horizontal text-selection drags to the browser", async () => {
    const finishInteractiveProgress = vi.fn<
      (input: { shouldOpen: boolean }) => Promise<{ revision: number }>
    >(async (_input: { shouldOpen: boolean }) => ({ revision: 2 }));
    const setInteractiveProgress = vi.fn<
      (input: { progress: number }) => Promise<{ revision: number }>
    >(async (_input: { progress: number }) => ({ revision: 2 }));
    installSideChatBridge({
      finishInteractiveProgress,
      presentationState: openPresentation,
      sessionState: signedOutSessionSnapshot,
      setInteractiveProgress,
    });

    const { container } = renderSideChatApp();
    const host = container.querySelector<HTMLElement>(".comma-side-chat-host")!;
    const setPointerCapture = vi.fn();
    Object.defineProperty(host, "setPointerCapture", {
      configurable: true,
      value: setPointerCapture,
    });
    await waitFor(() => expect(host).toHaveAttribute("data-phase", "open"));

    const selectionMove = new PointerEvent("pointermove", {
      bubbles: true,
      cancelable: true,
      clientX: 120,
      clientY: 100,
      pointerId: 1,
    });
    fireEvent.pointerDown(screen.getByText("Sign in to use Side Chat"), {
      button: 0,
      clientX: 300,
      clientY: 100,
      pointerId: 1,
    });
    host.dispatchEvent(selectionMove);
    fireEvent.pointerUp(host, {
      clientX: 120,
      clientY: 100,
      pointerId: 1,
    });

    expect(selectionMove.defaultPrevented).toBe(false);
    expect(setInteractiveProgress).not.toHaveBeenCalled();
    expect(finishInteractiveProgress).not.toHaveBeenCalled();
    expect(setPointerCapture).not.toHaveBeenCalled();
  });

  it.each([false, true])(
    "reserves native height while the visible composer follows its content (empty=%s)",
    async (empty) => {
      const originalScrollHeight = Object.getOwnPropertyDescriptor(
        HTMLElement.prototype,
        "scrollHeight"
      );
      let scrollHeight = 0;
      Object.defineProperty(HTMLElement.prototype, "scrollHeight", {
        configurable: true,
        get(this: HTMLElement) {
          return this.getAttribute("aria-label") === "AI prompt" ? scrollHeight : 0;
        },
      });
      const setContentSize = vi.fn<
        (input: { height: number; width: number }) => Promise<{ revision: number }>
      >(async (_input: { height: number; width: number }) => ({ revision: 2 }));
      installSideChatBridge({
        chatState: empty
          ? {
              ...readyChatState,
              sessions: readyChatState.sessions.map((session) => ({
                ...session,
                state: { ...session.state, messages: [] },
              })),
            }
          : readyChatState,
        presentationState: openPresentation,
        sessionState: signedInSessionSnapshot,
        setContentSize,
      });

      const { container } = renderSideChatApp();
      expect(
        await screen.findByText(empty ? "New conversation" : "Hello from Comma")
      ).toBeInTheDocument();
      const editor = await screen.findByRole("textbox", { name: "AI prompt" });
      const host = container.querySelector<HTMLElement>(".comma-side-chat-host")!;
      const shell = editor.closest(".comma-chat-composer-shell");
      expect(editor).toHaveStyle({ minHeight: "36px" });
      expect(shell).not.toHaveAttribute("data-side-chat-multiline");
      await waitFor(() =>
        expect(host).toHaveStyle({ height: empty ? "231px" : "215px" })
      );
      await waitFor(() =>
        expect(setContentSize).toHaveBeenCalledWith({
          height: empty ? 275 : 248,
          visualHeight: empty ? 231 : 215,
          width: 364,
        })
      );
      setContentSize.mockClear();

      try {
        scrollHeight = 60;
        await userEvent.type(
          editor,
          "one{Shift>}{Enter}{/Shift}two{Shift>}{Enter}{/Shift}three"
        );

        expect(shell).toHaveAttribute("data-side-chat-multiline", "true");
        await waitFor(() =>
          expect(host).toHaveStyle({ height: empty ? "255px" : "228px" })
        );
        // The window reserve stays fixed, but the backdrop follows visible growth.
        await waitFor(() =>
          expect(setContentSize).toHaveBeenCalledWith({
            height: empty ? 275 : 248,
            visualHeight: empty ? 255 : 228,
            width: 364,
          })
        );

        scrollHeight = 120;
        await userEvent.type(editor, "{Shift>}{Enter}{/Shift}four");
        await waitFor(() =>
          expect(host).toHaveStyle({ height: empty ? "315px" : "288px" })
        );
        // The small composer's 120px ceiling exceeds the reserve; the renderer
        // requests the taller native window.
        await waitFor(() =>
          expect(setContentSize).toHaveBeenCalledWith({
            height: empty ? 315 : 288,
            visualHeight: empty ? 315 : 288,
            width: 364,
          })
        );

        scrollHeight = 20;
        await userEvent.clear(editor);
        await userEvent.type(editor, "short again");
        expect(editor).toHaveStyle({ minHeight: "36px" });
        expect(shell).not.toHaveAttribute("data-side-chat-multiline");
        await waitFor(() =>
          expect(host).toHaveStyle({ height: empty ? "231px" : "215px" })
        );
        await waitFor(() =>
          expect(setContentSize).toHaveBeenCalledWith({
            height: empty ? 275 : 248,
            visualHeight: empty ? 231 : 215,
            width: 364,
          })
        );
        expect(setContentSize).toHaveBeenCalledTimes(3);
      } finally {
        if (originalScrollHeight) {
          Object.defineProperty(
            HTMLElement.prototype,
            "scrollHeight",
            originalScrollHeight
          );
        } else {
          delete (HTMLElement.prototype as { scrollHeight?: number }).scrollHeight;
        }
      }
    }
  );

  it("reserves the rendered image-group card height for local image messages", async () => {
    const setContentSize = vi.fn<
      (input: { height: number; width: number }) => Promise<{ revision: number }>
    >(async (_input: { height: number; width: number }) => ({ revision: 2 }));
    const session = readyChatState.sessions[0]!;
    const assistantMessage = session.state.messages[0]!;
    installSideChatBridge({
      chatState: {
        ...readyChatState,
        sessions: [
          {
            ...session,
            state: {
              ...session.state,
              messages: [
                {
                  ...assistantMessage,
                  attachments: [
                    {
                      blockType: "image",
                      fileName: "side-chat-photo.png",
                      localFileRef: `lfi1_${"s".repeat(43)}`,
                      mimeType: "image/png",
                      size: 456,
                    },
                  ],
                  text: "",
                },
              ],
            },
          },
        ],
      },
      presentationState: openPresentation,
      previewLocalFile: vi.fn(async () => ({
        pngImage: new Uint8Array([137, 80, 78, 71]),
        status: "ready" as const,
      })),
      sessionState: signedInSessionSnapshot,
      setContentSize,
    });

    const { container } = renderSideChatApp();
    expect(
      await screen.findByRole("img", { name: "side-chat-photo.png" })
    ).toBeInTheDocument();
    const host = container.querySelector<HTMLElement>(".comma-side-chat-host")!;
    await waitFor(() => expect(host).toHaveStyle({ height: "440px" }));
    await waitFor(() =>
      expect(setContentSize).toHaveBeenCalledWith(
        expect.objectContaining({ height: 484, width: 364 })
      )
    );
  });

  it("loads retained task cards for the workspace and opens their native task window", async () => {
    const loadTasks = vi.fn(
      async (): Promise<ProductInboxListResult> => ({
        activeWorkspaceId: "wsp_1",
        items: [
          {
            conversationId: "cnv_task_1",
            groupId: "grp_test",
            id: "grp_test:cnv_task_1",
            kind: "agent_task",
            source: "salix.conversation",
            status: "in_progress",
            title: "Ship Side Chat tasks",
            updatedAt: 1_753_100_800,
            workspaceId: "wsp_1",
            workspaceName: "Comma",
          },
        ],
        source: "live-sync",
      })
    );
    const bridge = installSideChatBridge({
      loadTasks,
      sessionState: signedInSessionSnapshot,
    });
    renderSideChatContent(
      <CommaAuthGate>
        <SideChatTaskCardsHarness />
      </CommaAuthGate>
    );

    expect(await screen.findByText("Ship Side Chat tasks")).toBeInTheDocument();
    expect(loadTasks).toHaveBeenCalledWith({
      limit: 50,
      session: testProductLease,
      workspaceId: "wsp_1",
    });
    const taskButton = screen.getByRole("button", {
      name: "Open task: Ship Side Chat tasks",
    });
    vi.spyOn(taskButton, "getBoundingClientRect").mockReturnValue({
      bottom: 260,
      height: 120,
      left: 30,
      right: 330,
      top: 140,
      width: 300,
      x: 30,
      y: 140,
      toJSON: () => ({}),
    } as DOMRect);
    fireEvent.click(taskButton);
    await waitFor(() =>
      expect(bridge.sideChat.openTestWindow).toHaveBeenLastCalledWith({
        sourceFrame: {
          height: 120,
          width: 300,
          x: window.screenX + 30,
          y: window.screenY + 140,
        },
        target: {
          conversationId: "cnv_task_1",
          groupId: "grp_test",
          workspaceId: "wsp_1",
        },
      })
    );
  });

  it("closes with Escape without clearing chat and accepts an owner projection reset", async () => {
    const chatState = createControllableStateBridge(readyChatState);
    const bridge = installSideChatBridge({
      chatStateBridge: chatState,
      sessionState: signedInSessionSnapshot,
    });
    renderSideChatApp();
    expect(await screen.findByText("Hello from Comma")).toBeInTheDocument();
    fireEvent.keyDown(window, { key: "Escape" });
    await waitFor(() => expect(bridge.sideChat.close).toHaveBeenCalledOnce());
    expect(bridge.chat.clearPresentation).not.toHaveBeenCalled();
    expect(screen.getByText("Hello from Comma")).toBeInTheDocument();
    // Independently exercise a Main-owned projection reset.
    act(() => {
      chatState.emit(
        withSideChatSurfaceProjection(
          streamingChatState(2, "", "draft_unused"),
          clearedSideChatProjection(readyChatState.sessions[0]!.state)
        )
      );
    });
    await waitFor(() => {
      expect(screen.queryByText("Hello from Comma")).toBeNull();
      expect(screen.getByText("New conversation")).toBeInTheDocument();
    });
    expect(bridge.chat.discard).not.toHaveBeenCalled();
    expect(bridge.chat.release).not.toHaveBeenCalled();

    await userEvent.type(
      screen.getByRole("textbox", { name: "AI prompt" }),
      "Continue after clear"
    );
    await userEvent.click(screen.getByRole("button", { name: "Send message" }));
    await waitFor(() =>
      expect(bridge.chat.send).toHaveBeenCalledWith(
        expect.objectContaining({
          conversationId: "cnv_assistant",
          groupId: "grp_test",
          session: testProductLease,
          text: "Continue after clear",
          workspaceId: "wsp_1",
        })
      )
    );
  });

  it("renders only the Main-owned response generation after local clear", async () => {
    const setContentSize = vi.fn<
      (input: { height: number; width: number }) => Promise<{ revision: number }>
    >(async (_input: { height: number; width: number }) => ({ revision: 2 }));
    const chatState = createControllableStateBridge(streamingChatState(1, ""));
    const bridge = installSideChatBridge({
      chatStateBridge: chatState,
      sessionState: signedInSessionSnapshot,
      setContentSize,
    });

    renderSideChatApp();

    const initialParticipantStatus = await screen.findByText("Checking the workspace");
    expect(screen.queryByText("is executing a tool...")).toBeNull();
    const initialActivity = initialParticipantStatus.closest(
      '[data-slot="ai-activity"]'
    );
    expect(initialActivity).toHaveAttribute("data-status", "running");
    act(() => {
      chatState.emit(streamingChatState(2, "Streaming answer ".repeat(300)));
    });
    expect(await screen.findByTestId("chat-assistant-draft")).toHaveTextContent(
      "Streaming answer"
    );
    expect(initialActivity).toHaveAttribute("data-status", "running");
    expect(
      initialParticipantStatus.closest(".comma-chat-activity-row")
    ).toHaveAttribute("aria-hidden", "false");
    expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
      "data-active",
      "true"
    );
    await waitFor(() =>
      expect(setContentSize.mock.calls.some(([size]) => size.height > 215)).toBe(true)
    );

    // The projection reset arrives from Main, not the window-close control.
    expect(bridge.chat.clearPresentation).not.toHaveBeenCalled();

    act(() => {
      const canonical = streamingChatState(3, "Late streaming answer");
      chatState.emit(
        withSideChatSurfaceProjection(
          canonical,
          clearedSideChatProjection(canonical.sessions[0]!.state)
        )
      );
    });

    await waitFor(() => {
      expect(screen.queryByText("Late streaming answer")).toBeNull();
      expect(screen.getByText("Thinking")).toBeInTheDocument();
      expect(screen.queryByText("is executing a tool...")).toBeNull();
      expect(screen.getByText("New conversation")).toBeInTheDocument();
    });

    await userEvent.type(
      screen.getByRole("textbox", { name: "AI prompt" }),
      "Continue streaming chat"
    );
    await userEvent.click(screen.getByRole("button", { name: "Send message" }));
    await waitFor(() =>
      expect(bridge.chat.send).toHaveBeenCalledWith(
        expect.objectContaining({
          conversationId: "cnv_assistant",
          groupId: "grp_test",
          session: testProductLease,
          text: "Continue streaming chat",
          workspaceId: "wsp_1",
        })
      )
    );
    expect(screen.queryByText("Late streaming answer")).toBeNull();

    act(() => {
      const canonical = responseEpochChatState({
        activitySummary: "Checking the workspace",
        assistantDraftId: "draft_D1",
        assistantDraftText: "Late streaming answer",
        revision: 4,
      });
      const state = canonical.sessions[0]!.state;
      const visibleMessages = state.messages.filter(
        (message) => message.clientRequestId === "req_new_generation"
      );
      chatState.emit(
        withSideChatSurfaceProjection(canonical, {
          ...clearedSideChatProjection(state),
          messages: visibleMessages,
          pending: state.pending,
        })
      );
    });
    await waitFor(() => {
      expect(screen.getByText("Continue streaming chat")).toBeInTheDocument();
      expect(screen.queryByText("D1 final after clear")).toBeNull();
      expect(screen.queryByText("Late streaming answer")).toBeNull();
      expect(screen.getByText("Thinking")).toBeInTheDocument();
      expect(screen.queryByText("Checking the workspace")).toBeNull();
    });

    act(() => {
      const canonical = responseEpochChatState({
        activitySummary: "Working on the new response",
        assistantDraftId: "draft_D2",
        assistantDraftText: "Fresh D2 answer",
        revision: 5,
      });
      const state = canonical.sessions[0]!.state;
      chatState.emit(
        withSideChatSurfaceProjection(canonical, {
          ...clearedSideChatProjection(state),
          activity: state.activity,
          assistantDraft: state.assistantDraft,
          awaitingReply: state.awaitingReply,
          awaitingSince: state.awaitingSince,
          awaitingTimedOut: state.awaitingTimedOut,
          messages: state.messages.filter(
            (message) => message.clientRequestId === "req_new_generation"
          ),
          pending: state.pending,
        })
      );
    });
    await waitFor(() => {
      expect(screen.getByText("Continue streaming chat")).toBeInTheDocument();
      expect(screen.getByText("Fresh D2 answer")).toBeInTheDocument();
      expect(screen.getByText("Working on the new response")).toBeInTheDocument();
      expect(screen.getByTestId("participant-status-slot")).toHaveAttribute(
        "data-active",
        "true"
      );
      expect(screen.queryByText("D1 final after clear")).toBeNull();
      expect(screen.queryByText("Late streaming answer")).toBeNull();
    });
  });

  it("opens an inline task through the standalone native task-window handoff", async () => {
    const session = readyChatState.sessions[0]!;
    const assistantMessage = session.state.messages[0]!;
    const bridge = installSideChatBridge({
      chatState: {
        ...readyChatState,
        sessions: [
          {
            ...session,
            state: {
              ...session.state,
              messages: [
                {
                  ...assistantMessage,
                  parts: [
                    { kind: "markdown", text: "Created " },
                    {
                      kind: "inline-task",
                      task: {
                        conversationId: "cnv_inline_task",
                        title: "Deploy report",
                        unavailable: false,
                      },
                    },
                    { kind: "markdown", text: "." },
                  ],
                  text: "Created Deploy report.",
                },
              ],
            },
          },
        ],
      },
      sessionState: signedInSessionSnapshot,
    });

    renderSideChatApp();

    const taskButton = await screen.findByRole("button", {
      name: "Open task: Deploy report",
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
      expect(bridge.sideChat.openTestWindow).toHaveBeenCalledWith({
        sourceFrame: {
          height: 24,
          width: 120,
          x: window.screenX + 12,
          y: window.screenY + 20,
        },
        target: {
          conversationId: "cnv_inline_task",
          groupId: "grp_test",
          workspaceId: "wsp_1",
        },
      })
    );
  });

  it("uses the remaining screen height before scrolling long conversations", async () => {
    const setContentSize = vi.fn<
      (input: { height: number; width: number }) => Promise<{ revision: number }>
    >(async (_input: { height: number; width: number }) => ({ revision: 2 }));
    installSideChatBridge({
      chatState: streamingChatState(2, "Streaming answer ".repeat(300)),
      presentationState: {
        ...openPresentation,
        availableContentHeight: 900,
      },
      sessionState: signedInSessionSnapshot,
      setContentSize,
    });

    const { container } = renderSideChatApp();

    expect(await screen.findByTestId("chat-assistant-draft")).toHaveTextContent(
      "Streaming answer"
    );
    const host = container.querySelector<HTMLElement>(".comma-side-chat-host")!;
    await waitFor(() => expect(host).toHaveStyle({ height: "900px" }));
    await waitFor(() =>
      expect(setContentSize).toHaveBeenCalledWith(
        expect.objectContaining({ height: 900, width: 364 })
      )
    );
  });

  it.each([
    { expectedHeight: 339.6, fontSize: "small" as const },
    { expectedHeight: 354, fontSize: "default" as const },
    { expectedHeight: 368.4, fontSize: "large" as const },
  ])(
    "budgets regular multiline message height at the $fontSize appearance setting",
    async ({ expectedHeight, fontSize }) => {
      localStorage.setItem(
        commaAppearanceStorageKey,
        JSON.stringify({ fontSize, pointerCursors: false, theme: "system" })
      );
      const snapshot = streamingChatState(
        2,
        ["Line one", "Line two", "Line three", "Line four", "Line five"].join("\n")
      );
      const session = snapshot.sessions[0]!;
      installSideChatBridge({
        chatState: {
          ...snapshot,
          sessions: [
            {
              ...session,
              state: {
                ...session.state,
                messages: session.state.messages.filter(
                  (message) => message.role === "user"
                ),
                serverMessages: [],
              },
            },
          ],
        },
        presentationState: {
          ...openPresentation,
          availableContentHeight: 900,
        },
        sessionState: signedInSessionSnapshot,
      });

      const { container } = renderSideChatApp();

      expect(await screen.findByTestId("chat-assistant-draft")).toHaveTextContent(
        "Line five"
      );
      const host = container.querySelector<HTMLElement>(".comma-side-chat-host")!;
      await waitFor(() => expect(host).toHaveStyle({ height: `${expectedHeight}px` }));
    }
  );
});

const presentation: SideChatPresentation = {
  availableContentHeight: 600,
  contentFrame: { height: 254, width: 364, x: 9, y: 3 },
  displayId: 1,
  kind: "side-chat.presentation",
  offsetX: -120,
  phase: "interactive",
  progress: 0.68,
  protocolVersion: 3,
  revision: 1,
  screenFrame: { height: 900, width: 1440, x: 0, y: 0 },
  windowFrame: { height: 380, width: 523, x: 4, y: 12 },
};

const openPresentation: SideChatPresentation = {
  ...presentation,
  offsetX: 0,
  phase: "open",
  progress: 1,
  revision: 2,
};

const readyChatState: ChatRuntimeSnapshot = {
  protocolVersion: 3,
  revision: 1,
  sessions: [
    {
      conversationId: "cnv_assistant",
      groupId: "grp_test",
      key: "grp_test/cnv_assistant",
      refs: 1,
      revision: 1,
      state: {
        awaitingReply: false,
        awaitingTimedOut: false,
        connection: "live",
        conversation: {
          groupId: "grp_test",
          id: "cnv_assistant",
          kind: "user_chat",
          status: "open",
          title: "Assistant",
          workspaceId: "wsp_1",
        },
        draft: "",
        draftAttachments: [],
        lastBackoffMs: 0,
        messages: [
          {
            attachments: [],
            delivery: "sent",
            messageId: "msg_1",
            refs: [],
            role: "assistant",
            source: "server",
            text: "Hello from Comma",
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

function streamingChatState(
  revision: number,
  draft = "Streaming answer",
  draftId = "draft_D1"
): ChatRuntimeSnapshot {
  const session = readyChatState.sessions[0]!;
  return {
    ...readyChatState,
    revision,
    sessions: [
      {
        ...session,
        revision,
        state: {
          ...session.state,
          activity: {
            action: "Checking the workspace",
            conversationId: "cnv_assistant",
            goal: "Checking the workspace",
            ownerTurnKey: "msg_streaming_user",
            phase: "execution",
            producerEpoch: "epoch-side-chat",
            responseKey: `response:${draftId}`,
            sequence: revision + 1,
            sourceMessageIds: ["msg_streaming_user"],
            status: "running",
            streamIncarnation: 1,
            summary: "Checking the workspace",
            summaryClass: "public",
            toolName: "env.exec",
            updatedAt: revision,
          },
          assistantDraft: {
            conversationId: "cnv_assistant",
            draftId,
            responseKey: `response:${draftId}`,
            sourceMessageIds: ["msg_streaming_user"],
            status: "completed",
            text: draft,
          },
          participantStatus: {
            conversationId: "cnv_assistant",
            participantId: "ptp_side_chat",
            state: "active",
            status: "is executing a tool...",
            updatedAt: revision,
          },
          awaitingReply: true,
          messages: [
            ...session.state.messages,
            {
              attachments: [],
              delivery: "sent",
              messageId: "msg_streaming_user",
              refs: [],
              role: "user",
              source: "server",
              text: "Prompt",
            },
          ],
        },
      },
    ],
  };
}

function responseEpochChatState({
  activitySummary,
  assistantDraftId,
  assistantDraftText,
  revision,
}: {
  activitySummary: string;
  assistantDraftId: string;
  assistantDraftText: string;
  revision: number;
}): ChatRuntimeSnapshot {
  const snapshot = streamingChatState(revision, assistantDraftText, assistantDraftId);
  const session = snapshot.sessions[0]!;
  const lateD1Final = {
    attachments: [],
    delivery: "sent" as const,
    messageId: "msg_d1_final",
    refs: [],
    role: "assistant",
    source: "server" as const,
    text: "D1 final after clear",
  };
  const newPending = {
    attachments: [],
    clientRequestId: "req_new_generation",
    delivery: "sending" as const,
    messageId: "msg_new_generation",
    refs: [],
    role: "user",
    source: "pending" as const,
    text: "Continue streaming chat",
  };
  return {
    ...snapshot,
    sessions: [
      {
        ...session,
        state: {
          ...session.state,
          assistantDraft: session.state.assistantDraft
            ? {
                ...session.state.assistantDraft,
                sourceMessageIds:
                  assistantDraftId === "draft_D1"
                    ? ["msg_streaming_user"]
                    : ["msg_new_generation"],
              }
            : undefined,
          activity: {
            ...session.state.activity!,
            ownerTurnKey:
              assistantDraftId === "draft_D1"
                ? "msg_streaming_user"
                : "req_new_generation",
            responseKey: `response:${assistantDraftId}`,
            sourceMessageIds:
              assistantDraftId === "draft_D1"
                ? ["msg_streaming_user"]
                : ["msg_new_generation"],
            action: activitySummary,
            goal: activitySummary,
            summary: activitySummary,
          },
          participantStatus: {
            ...session.state.participantStatus!,
            status: activitySummary,
            updatedAt: revision,
          },
          messages: [
            readyChatState.sessions[0]!.state.messages[0]!,
            lateD1Final,
            newPending,
          ],
          pending: [
            {
              clientRequestId: "req_new_generation",
              createdAt: revision,
              status: "sending",
              text: "Continue streaming chat",
            },
          ],
          serverMessages: [lateD1Final],
        },
      },
    ],
  };
}

function clearedSideChatProjection(
  state: ChatRuntimeSnapshot["sessions"][number]["state"]
): ChatRuntimeSnapshot["sessions"][number]["state"] {
  return {
    ...state,
    activity: undefined,
    assistantDraft: undefined,
    awaitingReply: false,
    awaitingSince: undefined,
    awaitingTimedOut: false,
    errorKind: undefined,
    messages: [],
    pending: [],
    serverMessages: [],
    syncWarning: undefined,
  };
}

function withSideChatSurfaceProjection(
  snapshot: ChatRuntimeSnapshot,
  state: ChatRuntimeSnapshot["sessions"][number]["state"],
  generation = 1
): ChatRuntimeSnapshot {
  const session = snapshot.sessions[0]!;
  return {
    ...snapshot,
    sessions: [
      {
        ...session,
        surfaceProjections: [
          {
            generation,
            state,
            subscriberId: "win_side_chat:grp_test/cnv_assistant",
          },
        ],
      },
    ],
  };
}

function installSideChatBridge({
  bumpGenerationOnReconcile = false,
  chatState = { protocolVersion: 3, revision: 0, sessions: [] },
  chatStateBridge,
  close = vi.fn(async () => ({ revision: 1 })),
  finishInteractiveProgress = vi.fn(async () => ({ revision: 1 })),
  focusMainWindow,
  loadTasks,
  presentationState = presentation,
  presentationStateBridge,
  previewLocalFile,
  resolveWorkspaceChat = vi.fn(async () => ({
    conversationId: "cnv_assistant",
    groupId: "grp_test",
    status: "ready" as const,
    workspaceId: "wsp_1",
  })),
  sessionState,
  signOut,
  setContentSize = vi.fn(async () => ({ revision: 1 })),
  setInteractiveProgress = vi.fn(async () => ({ revision: 1 })),
}: {
  bumpGenerationOnReconcile?: boolean;
  chatState?: ChatRuntimeSnapshot;
  chatStateBridge?: NativeStateBridge<ChatRuntimeSnapshot>;
  close?: () => Promise<{ revision: number }>;
  finishInteractiveProgress?: (input: {
    shouldOpen: boolean;
  }) => Promise<{ revision: number }>;
  focusMainWindow?: (input: { windowId: string }) => Promise<never>;
  loadTasks?: (
    input: ProductInboxRefresh & { session: SessionProductLease }
  ) => Promise<ProductInboxListResult>;
  presentationState?: SideChatPresentation;
  presentationStateBridge?: NativeStateBridge<SideChatPresentation>;
  previewLocalFile?: () => Promise<
    { pngImage: Uint8Array; status: "ready" } | { status: "unavailable" }
  >;
  resolveWorkspaceChat?: () => Promise<ChatWorkspaceResolution>;
  sessionState: TerminalSessionSnapshot;
  signOut?: () => Promise<TerminalSessionSnapshot>;
  setContentSize?: (input: {
    height: number;
    width: number;
  }) => Promise<{ revision: number }>;
  setInteractiveProgress?: (input: {
    progress: number;
  }) => Promise<{ revision: number }>;
}) {
  currentSessionHostController = createTestSessionHostController({
    bumpGenerationOnReconcile,
    initial: sessionState,
    ...(signOut ? { onSignOut: signOut } : {}),
  });
  const unavailable: ProductInboxListResult = {
    errorCode: "utility_unavailable",
    items: [],
    source: "unavailable",
  };
  currentProductInboxController = createProductInboxProjectionHarness({
    initial: unavailable,
    refresh: loadTasks ?? (() => unavailable),
  }).controller;

  return installNativeBridgeMock({
    chat: {
      resolveWorkspaceChat,
      state: bindSessionChatStateBridge(
        chatStateBridge ?? createStateBridge(() => chatState)
      ),
    },
    ...(previewLocalFile ? { localFiles: { preview: previewLocalFile } } : {}),
    os: "macos",
    platform: "electron",
    self: { role: "side-chat-window", windowId: "win_side_chat" },
    sideChat: {
      close,
      finishInteractiveProgress,
      presentation:
        presentationStateBridge ?? createStateBridge(() => presentationState),
      setContentSize,
      setInteractiveProgress,
    },
    ...(focusMainWindow ? { windows: { focus: focusMainWindow } } : {}),
  });
}

let currentSessionHostController = createTestSessionHostController({
  initial: signedOutSessionSnapshot,
});
let currentProductInboxController: ProductInboxProjectionController =
  createProductInboxProjectionHarness({
    initial: {
      errorCode: "utility_unavailable",
      items: [],
      source: "unavailable",
    },
  }).controller;

function SideChatTaskCardsHarness() {
  const { api } = useCommaAuth();
  return <SideChatTaskCards api={api} workspaceId="wsp_1" />;
}

function renderSideChatApp(locale?: CommaLocale) {
  return renderSideChatContent(<SideChatApp />, locale);
}

function renderSideChatContent(children: ReactNode, locale?: CommaLocale) {
  const content = (
    <CommaSessionHostProvider controller={currentSessionHostController}>
      <ProductInboxProjectionProvider controller={currentProductInboxController}>
        {children}
      </ProductInboxProjectionProvider>
    </CommaSessionHostProvider>
  );
  return render(
    <CommaWebClientSettingsProvider>
      {locale ? (
        <CommaI18nProvider locale={locale}>{content}</CommaI18nProvider>
      ) : (
        content
      )}
    </CommaWebClientSettingsProvider>
  );
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
    subscribe: vi.fn((listener: (snapshot: Snapshot) => void) => {
      listeners.add(listener);
      void get().then((snapshot) => {
        if (listeners.has(listener)) listener(snapshot);
      });
      return () => listeners.delete(listener);
    }),
  }) as NativeStateBridge<Snapshot> & { emit(snapshot: Snapshot): void };
}

function createStateBridge<Snapshot>(
  getSnapshot: () => Promise<Snapshot> | Snapshot
): NativeStateBridge<Snapshot> {
  const get = vi.fn(async () => getSnapshot());
  return Object.assign(get, {
    get,
    subscribe: vi.fn((listener: (snapshot: Snapshot) => void) => {
      let active = true;
      void get().then((snapshot) => {
        if (active) {
          listener(snapshot);
        }
      });
      return () => {
        active = false;
      };
    }),
  });
}

type SessionBoundChatStateEnvelope = {
  session: SessionProductLease;
  snapshot: ChatRuntimeSnapshot;
};

function bindSessionChatStateBridge(
  state: NativeStateBridge<ChatRuntimeSnapshot>
): NativeStateBridge<SessionBoundChatStateEnvelope, { session: SessionProductLease }> {
  const get = vi.fn(async (_input: { session: SessionProductLease }) => ({
    session: testProductLease,
    snapshot: await state.get(),
  }));
  return Object.assign(get, {
    get,
    subscribe: vi.fn(
      (
        listener: (envelope: SessionBoundChatStateEnvelope) => void,
        _input: { session: SessionProductLease }
      ) =>
        state.subscribe((snapshot) => listener({ session: testProductLease, snapshot }))
    ),
  });
}
