import type { SideChatPresentation } from "@comma/chat-contract";
import {
  closeNativeSideChatTestWindow,
  getNativeSideChatPresentation,
  parseNativeSideChatTestWindowSourceFrame,
  subscribeNativeSideChatPresentation,
  type SideChatTestWindowSourceFrame,
} from "../../../runtime-side-chat/nativeSideChat";
import { ChatSidebarSurface, ChatSidebarToggle } from "../../chat-sidebar/ChatSidebar";
import {
  ChatSidebarProvider,
  useChatSidebar,
  useChatSidebarWidth,
  useRegisterChatSidebarHost,
} from "../../chat-sidebar/ChatSidebarContext";
import { motionDuration, SideChatDiagnostics } from "@comma/ui";
import {
  createContext,
  memo,
  useContext,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import { createPortal } from "react-dom";
import { CommaAuthGate, useCommaAuth } from "../../AuthGate";
import { CommaUiThemeProvider } from "../../commaUiTheme";
import { useSideChatAppearance, useSideChatThemeName } from "../../sideChatAppearance";
import { ChatProvider, useChatApi } from "../ChatProvider";
import {
  ConversationView,
  type ConversationViewActions,
} from "../conversation/ConversationView";
import { sideChatInlineTaskLinkAdapter } from "./sideChatInlineTaskLink";
import { useConversation } from "../conversation/useConversation";

type SideChatTaskWindowTarget = {
  conversationId: string;
  groupId: string;
  workspaceId: string;
};

type SideChatTestMetrics = {
  devicePixelRatio: number;
  devicePixelSize: { height: number; width: number };
  presentation: Pick<
    SideChatPresentation,
    "displayId" | "offsetX" | "phase" | "progress" | "revision"
  >;
  viewportSize: { height: number; width: number };
};

const SIDE_CHAT_WINDOW_CLOSE_DELAY_MS = 500;
type SideChatWindowTransitionPhase = "closing" | "open" | "opening";

export function SideChatTestWindow() {
  const sourceFrame = useMemo(
    () => parseSideChatTestWindowSourceFrame(window.location.hash),
    []
  );
  const taskTarget = useMemo(
    () => parseSideChatTaskWindowTarget(window.location.hash),
    []
  );
  const appearance = useSideChatAppearance();
  const theme = useSideChatThemeName(appearance);
  const [bootShell] = useState(() => document.getElementById("comma-task-window-boot"));
  const [contentVisible, setContentVisible] = useState(Boolean(bootShell));
  const [expanded, setExpanded] = useState(Boolean(bootShell));
  const [transitionPhase, setTransitionPhase] = useState<SideChatWindowTransitionPhase>(
    bootShell ? "open" : "opening"
  );
  const [metrics, setMetrics] = useState<SideChatTestMetrics | null>(null);
  const [metricsError, setMetricsError] = useState<string | null>(null);
  const dismissingRef = useRef(false);
  const closeTimerRef = useRef<number | null>(null);
  const latestPresentationRef = useRef<SideChatPresentation | null>(null);

  const applyPresentation = useCallback((presentation: SideChatPresentation) => {
    const latestPresentation = latestPresentationRef.current;
    if (latestPresentation && presentation.revision < latestPresentation.revision) {
      return;
    }

    latestPresentationRef.current = presentation;
    const devicePixelRatio = window.devicePixelRatio;
    const viewportSize = {
      height: window.innerHeight,
      width: window.innerWidth,
    };
    setMetrics({
      devicePixelRatio,
      devicePixelSize: {
        height: Math.round(viewportSize.height * devicePixelRatio),
        width: Math.round(viewportSize.width * devicePixelRatio),
      },
      presentation: {
        displayId: presentation.displayId,
        offsetX: presentation.offsetX,
        phase: presentation.phase,
        progress: presentation.progress,
        revision: presentation.revision,
      },
      viewportSize,
    });
    setMetricsError(null);
  }, []);

  const refreshMetrics = useCallback(async () => {
    try {
      applyPresentation(await getNativeSideChatPresentation());
    } catch (error) {
      setMetricsError(error instanceof Error ? error.message : String(error));
    }
  }, [applyPresentation]);

  const dismiss = useCallback(() => {
    if (dismissingRef.current) return;
    dismissingRef.current = true;
    setTransitionPhase("closing");
    setContentVisible(false);
    setExpanded(false);
    closeTimerRef.current = window.setTimeout(
      () => {
        void closeNativeSideChatTestWindow().catch((error: unknown) => {
          console.error("[side-chat-test-window] close handoff failed", error);
        });
      },
      taskTarget ? motionDuration.dialogExit : SIDE_CHAT_WINDOW_CLOSE_DELAY_MS
    );
  }, [taskTarget]);

  useEffect(() => {
    if (bootShell) {
      // Keep the compositor-owned entrance uninterrupted even when hydration
      // wins the race; the real chat is already laid out underneath it.
      const animations = bootShell.getAnimations?.({ subtree: true }) ?? [];
      void Promise.allSettled(animations.map((animation) => animation.finished)).then(
        () => bootShell.remove()
      );
      return;
    }
    let contentTimer: number | undefined;
    let secondFrame = 0;
    const firstFrame = window.requestAnimationFrame(() => {
      secondFrame = window.requestAnimationFrame(() => {
        if (dismissingRef.current) return;
        setTransitionPhase("open");
        setExpanded(true);
        contentTimer = window.setTimeout(() => setContentVisible(true), 120);
      });
    });
    return () => {
      window.cancelAnimationFrame(firstFrame);
      window.cancelAnimationFrame(secondFrame);
      if (contentTimer !== undefined) window.clearTimeout(contentTimer);
    };
  }, [bootShell]);

  useEffect(() => {
    if (taskTarget) return;
    const unsubscribe = subscribeNativeSideChatPresentation(applyPresentation);
    void refreshMetrics();
    return unsubscribe;
  }, [applyPresentation, refreshMetrics, taskTarget]);

  useEffect(() => {
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      dismiss();
    };
    const handleResize = () => {
      if (taskTarget) return;
      const presentation = latestPresentationRef.current;
      if (presentation) {
        applyPresentation(presentation);
      } else {
        void refreshMetrics();
      }
    };

    window.addEventListener("keydown", handleKeyDown);
    window.addEventListener("resize", handleResize);
    return () => {
      window.removeEventListener("keydown", handleKeyDown);
      window.removeEventListener("resize", handleResize);
      if (closeTimerRef.current !== null) {
        window.clearTimeout(closeTimerRef.current);
      }
    };
  }, [applyPresentation, dismiss, refreshMetrics, taskTarget]);

  if (taskTarget) {
    return (
      <CommaUiThemeProvider theme={theme}>
        <ChatSidebarProvider>
          <SideChatTaskWindowSurface
            contentVisible={contentVisible}
            expanded={expanded}
            onDismiss={dismiss}
            sourceFrame={sourceFrame}
            target={taskTarget}
            theme={theme}
            transitionPhase={transitionPhase}
          />
        </ChatSidebarProvider>
      </CommaUiThemeProvider>
    );
  }

  return (
    <SideChatDiagnostics
      contentVisible={contentVisible}
      error={metricsError}
      expanded={expanded}
      metrics={metrics}
      onDismiss={dismiss}
      onRefresh={() => void refreshMetrics()}
      sourceFrame={sourceFrame}
      theme={theme}
    />
  );
}

const TaskSidebarPortalContext = createContext<{
  host: HTMLDivElement | null;
  maxWidth: number;
  minWidth: number;
  moving: boolean;
  previewWidth?: (width: number) => void;
}>({ host: null, maxWidth: 720, minWidth: 320, moving: false });

function SideChatTaskWindowSurface({
  contentVisible,
  expanded,
  onDismiss,
  sourceFrame,
  target,
  theme,
  transitionPhase,
}: {
  contentVisible: boolean;
  expanded: boolean;
  onDismiss: () => void;
  sourceFrame: SideChatTestWindowSourceFrame;
  target: SideChatTaskWindowTarget;
  theme: "Dark mode" | "Light mode";
  transitionPhase: SideChatWindowTransitionPhase;
}) {
  const { isOpen } = useChatSidebar();
  const { width } = useChatSidebarWidth();
  const shellRef = useRef<HTMLDialogElement>(null);
  const [sidebarHost, setSidebarHost] = useState<HTMLDivElement | null>(null);
  const [viewportWidth, setViewportWidth] = useState(() => window.innerWidth);
  const chatWidth = Math.min(560, viewportWidth - 80);
  const availableWidth = Math.max(1, viewportWidth - 48 - chatWidth - 12);
  const anchorWidth = Math.min(width, 720, availableWidth);
  const offset = isOpen ? -(anchorWidth + 12) / 2 : 0;
  const chatLeft = (viewportWidth - chatWidth - anchorWidth - 12) / 2;
  const maxWidth = Math.min(720, availableWidth);
  const minWidth = Math.min(320, maxWidth);
  const previewWidth = useCallback(
    (next: number) => {
      // Transform is not inherited: moving the shells must not invalidate styles
      // throughout a long transcript on every pointer frame.
      if (shellRef.current)
        shellRef.current.style.transform = `translate(calc(-50% - ${(next + 12) / 2}px), -50%)`;
      if (sidebarHost)
        sidebarHost.style.transform = `translate(${(chatWidth - next + 12) / 2}px, -50%)`;
    },
    [chatWidth, sidebarHost]
  );
  useLayoutEffect(() => {
    // React has committed the final width/position, or the window is opening or
    // closing. Hand ownership back to its normal transition styles atomically.
    shellRef.current?.style.removeProperty("transform");
    sidebarHost?.style.removeProperty("transform");
  }, [width, isOpen, expanded, viewportWidth, sidebarHost]);
  const motionTarget = `${isOpen}:${viewportWidth}`;
  const [settledTarget, setSettledTarget] = useState(motionTarget);
  const moving = settledTarget !== motionTarget;
  useEffect(() => {
    const resize = () => setViewportWidth(window.innerWidth);
    window.addEventListener("resize", resize);
    return () => window.removeEventListener("resize", resize);
  }, []);
  useLayoutEffect(() => {
    if (!sidebarHost) return;
    let cancelled = false;
    // getAnimations flushes the new CSS state; no timer or per-frame React work.
    const animations = sidebarHost.getAnimations?.() ?? [];
    void Promise.allSettled(animations.map((animation) => animation.finished)).then(
      () => {
        if (!cancelled) setSettledTarget(motionTarget);
      }
    );
    return () => {
      cancelled = true;
    };
  }, [motionTarget, sidebarHost]);
  useLayoutEffect(() => {
    const updateSourceTransform = () => {
      const shell = shellRef.current;
      if (!shell || !shell.offsetWidth || !shell.offsetHeight) return;
      shell.style.setProperty(
        "--task-source-transform",
        `translate(-50%, -50%) translate(${sourceFrame.x + sourceFrame.width / 2 - window.innerWidth / 2}px, ${sourceFrame.y + sourceFrame.height / 2 - window.innerHeight / 2}px) scale(${sourceFrame.width / shell.offsetWidth}, ${sourceFrame.height / shell.offsetHeight})`
      );
    };
    updateSourceTransform();
    window.addEventListener("resize", updateSourceTransform);
    return () => window.removeEventListener("resize", updateSourceTransform);
  }, [sourceFrame]);
  const portalValue = useMemo(
    () => ({ host: sidebarHost, maxWidth, minWidth, moving, previewWidth }),
    [sidebarHost, maxWidth, minWidth, moving, previewWidth]
  );
  const style = {
    "--task-chat-offset": `${offset}px`,
    "--task-sidebar-x": `${chatLeft + chatWidth + 12 - viewportWidth / 2}px`,
    "--source-height": `${sourceFrame.height}px`,
    "--source-width": `${sourceFrame.width}px`,
    "--source-x": `${sourceFrame.x}px`,
    "--source-y": `${sourceFrame.y}px`,
  } as CSSProperties;
  return (
    <main
      aria-label="Task chat window"
      className="comma-side-chat-test-window"
      data-content-visible={contentVisible}
      data-expanded={expanded}
      data-transition-phase={transitionPhase}
      data-window-content="task-chat"
      data-sidebar-open={isOpen}
      data-sidebar-moving={moving}
      data-theme={theme}
      onPointerDown={(event) => {
        if (event.target === event.currentTarget) onDismiss();
      }}
      style={style}
    >
      <div
        className="comma-side-chat-task-sidebar"
        ref={setSidebarHost}
        aria-hidden={!isOpen}
        inert={!isOpen}
      />
      <dialog
        aria-label="Task chat"
        aria-modal="true"
        className="comma-side-chat-test-shell"
        ref={shellRef}
        open
      >
        <div className="comma-side-chat-test-content comma-side-chat-task-window-content">
          {contentVisible ? (
            <CommaAuthGate
              signedOutFallback={
                <div className="comma-side-chat-task-window-state">
                  Sign in from the Comma main window to open this task chat.
                </div>
              }
            >
              <TaskSidebarPortalContext.Provider value={portalValue}>
                <SideChatTaskWindowAuthenticated
                  onDismiss={onDismiss}
                  target={target}
                />
              </TaskSidebarPortalContext.Provider>
            </CommaAuthGate>
          ) : (
            <div className="comma-task-window-placeholder" aria-hidden="true" />
          )}
        </div>
      </dialog>
    </main>
  );
}

const SideChatTaskWindowAuthenticated = memo(function SideChatTaskWindowAuthenticated({
  onDismiss,
  target,
}: {
  onDismiss: () => void;
  target: SideChatTaskWindowTarget;
}) {
  const { api, productLease, sessionSignal } = useCommaAuth();
  return (
    <ChatProvider api={api} productLease={productLease} sessionSignal={sessionSignal}>
      <SideChatTaskWindowConversation onDismiss={onDismiss} target={target} />
    </ChatProvider>
  );
});

function SideChatTaskWindowConversation({
  onDismiss,
  target: initialTarget,
}: {
  onDismiss: () => void;
  target: SideChatTaskWindowTarget;
}) {
  const [target, setTarget] = useState(initialTarget);
  const portal = useContext(TaskSidebarPortalContext);
  const sidebar = useChatSidebar();
  useRegisterChatSidebarHost(target);
  const api = useChatApi();
  const conversation = useConversation(
    target.workspaceId,
    target.groupId,
    target.conversationId
  );
  const actions = useMemo<ConversationViewActions>(
    () => ({
      attachFiles: (files) => conversation.attachFiles(files),
      discard: (clientRequestId) => conversation.discard(clientRequestId),
      ...(conversation.previewLocalFile
        ? { previewLocalFile: conversation.previewLocalFile }
        : {}),
      refresh: () => conversation.refresh(),
      removeAttachment: (id) => conversation.removeAttachment(id),
      retry: (clientRequestId) => conversation.retry(clientRequestId),
      retryAttachment: (id) => conversation.retryAttachment(id),
      send: (text, options) => conversation.send(text, options),
      setDraft: (draft) => conversation.setDraft(draft),
    }),
    [conversation]
  );
  return (
    <div className="comma-side-chat-task-window-layout">
      <section className="comma-side-chat-task-window-chat">
        <header className="comma-side-chat-task-window-header">
          <h1>{conversation.state.conversation?.title || "Task chat"}</h1>
          <ChatSidebarToggle />
          <button aria-label="Close task chat" onClick={onDismiss} type="button">
            ×
          </button>
        </header>
        <ConversationView
          actions={actions}
          api={api}
          groupId={target.groupId}
          conversationId={target.conversationId}
          draftSource={conversation.draftSource}
          inlineTaskLinkAdapter={sideChatInlineTaskLinkAdapter}
          onOpenInCommaBrowser={(url) => sidebar.openBrowser(target, { url })}
          state={conversation.state}
          variant="side-chat"
          workspaceId={target.workspaceId}
        />
      </section>
      {portal.host &&
        createPortal(
          <ChatSidebarSurface
            maxWidth={portal.maxWidth}
            minWidth={portal.minWidth}
            resizeEdge="right"
            resizeHandleAppearance="invisible"
            resizeWidthMultiplier={2}
            onWidthPreview={portal.previewWidth}
            suppressNativeSurface={portal.moving}
            onOpenChat={setTarget}
          />,
          portal.host
        )}
    </div>
  );
}

export function parseSideChatTestWindowSourceFrame(
  hash: string
): SideChatTestWindowSourceFrame {
  const query = hash.includes("?") ? hash.slice(hash.indexOf("?") + 1) : "";
  const search = new URLSearchParams(query);
  return parseNativeSideChatTestWindowSourceFrame({
    height: Number(search.get("sourceHeight")),
    width: Number(search.get("sourceWidth")),
    x: Number(search.get("sourceX")),
    y: Number(search.get("sourceY")),
  });
}

export function parseSideChatTaskWindowTarget(
  hash: string
): SideChatTaskWindowTarget | undefined {
  const query = hash.includes("?") ? hash.slice(hash.indexOf("?") + 1) : "";
  const search = new URLSearchParams(query);
  const conversationId = search.get("conversationId")?.trim();
  const groupId = search.get("groupId")?.trim();
  const workspaceId = search.get("workspaceId")?.trim();
  return conversationId && groupId && workspaceId
    ? { conversationId, groupId, workspaceId }
    : undefined;
}
