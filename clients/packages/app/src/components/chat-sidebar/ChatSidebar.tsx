import { useApplicationMenu } from "../application-menu/useApplicationMenu";
import { useTaskSummary } from "../tasks/useTaskArchive";
import { openUrlInExternalBrowser } from "../chat/thread/inline/linkActions";
import {
  Button,
  ExpandSimpleIcon,
  FileIcon,
  GlobeIcon,
  taskStatusBucket,
  taskStatusIcon,
  RightSidebar,
  RightSidebarBrowserToolbar,
  RightSidebarToolbarButton,
  appKeybindingKeycaps,
  claimToastObstructionRight,
  releaseToastObstructionRight,
  toast,
  useNativeSurfaceSuppressed,
  type RightSidebarTab,
} from "@comma/ui";
import { useCommaMessages } from "@comma/i18n/react";
import {
  getNativeBridge,
  type BrowserSidebarInspectResult,
  type BrowserSidebarState,
} from "@comma/native-bridge";
import { useNavigate } from "@tanstack/react-router";
import {
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type CSSProperties,
} from "react";
import { flushSync } from "react-dom";
import type { CommaApiClient } from "../../api";
import { ShellIconButton } from "../ShellIconButton";
import { commaChatSidebarMaxWidth, commaChatSidebarMinWidth } from "../shellGeometry";
import { useOptionalAppShortcutBinding } from "../shortcuts/commaAppShortcuts";
import {
  ConversationView,
  type ConversationViewActions,
} from "../chat/conversation/ConversationView";
import { type TasksFilterLink, useOpenTasksFilter } from "../tasks/taskChips";
import type {
  AttachmentUploadInput,
  ChatConversationRef,
} from "../chat/model/conversationChannel";
import { useChatApi, useChatRegistry } from "../chat/ChatProvider";
import { useConversation } from "../chat/conversation/useConversation";
import { useWorkspaceSkills } from "../chat/useWorkspaceSkills";
import {
  activeSidebarChat,
  browserPageLabel,
  chatSidebarBrowserPageSessionId,
  chatSidebarHostKey,
  type ChatSidebarBrowserPage,
  type ChatSidebarConversationTarget,
  type ChatSidebarHost,
  type ChatSidebarSession,
  useChatSidebar,
  useChatSidebarWidth,
} from "./ChatSidebarContext";
import { buildBrowserElementInspectionMessage } from "./browserElementInspection";
import { FilePreviewPanel } from "./FilePreviewPanel";
import { DrivePreviewPanel } from "../drive/DrivePreviewPanel";
import {
  SessionHistoryPage,
  sessionParticipantName,
} from "../chat/session-history/SessionHistory";
import { useRouterDisplayName } from "../router-identity/RouterIdentityProvider";
import { useCommaClientSettings } from "../commaClientSettings";
import { needsDesktopApp, requestDesktopApp } from "../DesktopAppPrompt";

const nativeBrowserUnavailable =
  "The embedded browser is unavailable here. Open the link in your browser instead.";
const chatTabPrefix = "task:";
const chatTabId = (chat: ChatSidebarConversationTarget) =>
  `${chatTabPrefix}${chatSidebarHostKey(chat)}`;
/** Drive file ids share a tab namespace with browser page ids, so they carry a prefix. */
const fileTabPrefix = "file:";
const driveTabPrefix = "drive:";
const driveTabId = (fileId: string) => `${driveTabPrefix}${fileId}`;
const historyTabPrefix = "history:";
const historyTabId = (pageId: string) => `${historyTabPrefix}${pageId}`;
const driveFileIdFromTab = (tabId: string) =>
  tabId.startsWith(driveTabPrefix) ? tabId.slice(driveTabPrefix.length) : undefined;

export function ChatSidebar({
  maxWidth,
  primaryContentMinWidth,
}: {
  /**
   * Widest the sidebar may grow before the product route hits its minimum, as
   * of the last settled window size. The shell's CSS clamps the rendered width
   * live, so this bounds the drag and the keyboard only.
   */
  maxWidth?: number | undefined;
  /**
   * The product route's content minimum. The shell stylesheet yields the
   * sidebar's rendered width to it; it is scoped to the sidebar, the only
   * element that reads it, so a page switch restyles just this subtree.
   */
  primaryContentMinWidth?: number | undefined;
} = {}) {
  const navigate = useNavigate();
  const openTasksFilter = useOpenTasksFilter();
  return (
    <ChatSidebarSurface
      hostClampsRenderedWidth
      maxWidth={maxWidth}
      style={
        primaryContentMinWidth === undefined
          ? undefined
          : ({
              "--comma-primary-content-min-width": `${primaryContentMinWidth}px`,
            } as CSSProperties)
      }
      onOpenChat={(target) => {
        void navigate({
          params: target,
          to: "/tasks/$workspaceId/$groupId/$conversationId",
        });
      }}
      onOpenTasksFilter={openTasksFilter}
    />
  );
}

/** The shared sidebar can also be hosted by a standalone task window. */
export function ChatSidebarSurface({
  hostClampsRenderedWidth = false,
  maxWidth,
  minWidth = commaChatSidebarMinWidth,
  resizeEdge = "left",
  resizeHandleAppearance = "divider",
  resizeWidthMultiplier = 1,
  onWidthPreview,
  style,
  suppressNativeSurface = false,
  onOpenChat,
  onOpenTasksFilter,
}: {
  /** See `RightSidebar`: the host's CSS clamps the rendered width live. */
  hostClampsRenderedWidth?: boolean;
  maxWidth?: number | undefined;
  minWidth?: number;
  resizeEdge?: "left" | "right";
  resizeHandleAppearance?: "divider" | "invisible";
  resizeWidthMultiplier?: number;
  onWidthPreview?: ((width: number) => void) | undefined;
  style?: CSSProperties | undefined;
  suppressNativeSurface?: boolean;
  onOpenChat: (target: ChatSidebarConversationTarget) => void;
  onOpenTasksFilter?: ((filter: TasksFilterLink) => void) | undefined;
}) {
  const api = useChatApi();
  const registry = useChatRegistry();
  const messages = useCommaMessages();
  const routerName = useRouterDisplayName();
  const { settings } = useCommaClientSettings();
  const {
    activeHost,
    activeSession,
    addBrowserTab,
    closeBrowserPage,
    closeChat,
    closeDrivePreview,
    closeFilePreview,
    selectFilePreview,
    closeHistoryPage,
    getNativeBrowserCapacityBlockedEpoch,
    isOpen,
    toggleActive,
    nativeBrowserCapacityEpoch,
    nativeBrowserStates,
    openBrowser,
    openChat,
    recordNativeBrowserState,
    selectBrowserPage,
    selectChat,
    selectDrivePreview,
    selectHistoryPage,
    trailingRef,
    updateBrowserPage,
    updateBrowserPageMetadata,
  } = useChatSidebar();
  // A full-window DOM overlay (dialog, media preview) holds this while open;
  // the native browser view composites above the DOM, so for the duration it
  // swaps itself for a frame-accurate DOM snapshot instead of painting over
  // (and stealing clicks from under) the overlay.
  const nativeSurfaceSuppressed = useNativeSurfaceSuppressed();
  const { setWidth, width } = useChatSidebarWidth();
  const resolvedMaxWidth = Math.max(minWidth, maxWidth ?? commaChatSidebarMaxWidth);
  const handleWidthChange = useCallback(
    (nextWidth: number) => setWidth(Math.min(nextWidth, resolvedMaxWidth)),
    [resolvedMaxWidth, setWidth]
  );
  // The stored width is the user's choice and survives a squeeze: rendering
  // and drag anchoring both go through the constrained width (min of stored
  // and the live maximum), so a narrow window clamps what shows without
  // rewriting what the user picked — widening hands their width straight
  // back. An effect here used to write the store down to the shrunken
  // maximum, which ratcheted the panel narrower with every deep resize.
  const [renderedSidebar, setRenderedSidebar] = useState<
    | {
        host: ChatSidebarHost;
        session: ChatSidebarSession;
      }
    | undefined
  >(() =>
    activeHost && activeSession
      ? { host: activeHost, session: activeSession }
      : undefined
  );
  const open = isOpen;

  useLayoutEffect(() => {
    if (activeHost && activeSession) {
      setRenderedSidebar({ host: activeHost, session: activeSession });
    }
  }, [activeHost, activeSession]);
  const displayedHost =
    activeHost && activeSession ? activeHost : renderedSidebar?.host;
  const displayedSession =
    activeHost && activeSession ? activeSession : renderedSidebar?.session;
  const canSendBrowserInspection = Boolean(
    displayedHost &&
    displayedHost.workspaceId !== "__global__" &&
    displayedHost.conversationId !== "__global_browser__"
  );
  const inspectionConversation = useConversation(
    canSendBrowserInspection ? displayedHost?.workspaceId : undefined,
    canSendBrowserInspection ? displayedHost?.groupId : undefined,
    canSendBrowserInspection ? displayedHost?.conversationId : undefined
  );
  const inspectionChannel = inspectionConversation.channel;
  const sendInspection = inspectionConversation.send;
  const handleBrowserInspection = useCallback(
    (inspection: Extract<BrowserSidebarInspectResult, { status: "selected" }>) => {
      if (!inspectionChannel) {
        toast.error("The chat is not ready to receive browser context yet.");
        return;
      }
      sendInspection(buildBrowserElementInspectionMessage(inspection), {
        consumeDraft: false,
      });
    },
    [inspectionChannel, sendInspection]
  );

  const attachPreviewImage = useCallback(
    (files: AttachmentUploadInput[]) => {
      if (!displayedHost) return;
      const attempt = registry.beginAttempt();
      return attempt
        .run(() => {
          const lease = attempt.retain(
            displayedHost.workspaceId,
            displayedHost.groupId,
            displayedHost.conversationId
          );
          lease.channel.attachFiles(files);
        })
        .finally(() => attempt.release());
    },
    [displayedHost, registry]
  );

  const activeChat = activeSidebarChat(displayedSession);
  const chats = displayedSession?.chats ?? [];
  const browserPages = displayedSession?.browserPages ?? [];
  const drivePreviews = displayedSession?.drivePreviews ?? [];
  const filePreviews = displayedSession?.filePreviews ?? [];
  const activeFilePreview =
    filePreviews.find(
      (preview) => preview.id === displayedSession?.activeFilePreviewId
    ) ?? filePreviews[0];
  const historyPages = settings.sessionHistoryEnabled
    ? (displayedSession?.historyPages ?? [])
    : [];
  const activeHistoryPage =
    historyPages.find((page) => page.id === displayedSession?.activeHistoryPageId) ??
    historyPages[0];
  const activeBrowserPageId = displayedSession?.activeBrowserPageId;
  const activeBrowserPage =
    browserPages.find((page) => page.id === activeBrowserPageId) ?? browserPages[0];
  const activeDrivePreview =
    drivePreviews.find(
      (preview) => preview.id === displayedSession?.activeDrivePreviewId
    ) ?? drivePreviews[0];
  // A surface whose content has all been closed falls through to whatever the
  // session still holds, so the panel never renders empty beside live tabs.
  const requestedSurface = displayedSession?.activeSurface ?? "chat";
  const availableSurfaces = {
    chat: Boolean(activeChat),
    browser: browserPages.length > 0,
    drive: drivePreviews.length > 0,
    file: filePreviews.length > 0,
    history: historyPages.length > 0,
  };
  const activeSurface = availableSurfaces[requestedSurface]
    ? requestedSurface
    : ((["chat", "browser", "drive", "history", "file"] as const).find(
        (surface) => availableSurfaces[surface]
      ) ?? "chat");
  const activeTab =
    activeSurface === "file"
      ? `${fileTabPrefix}${activeFilePreview?.id ?? ""}`
      : activeSurface === "chat"
        ? activeChat
          ? chatTabId(activeChat)
          : ""
        : activeSurface === "history"
          ? historyTabId(activeHistoryPage?.id ?? "")
          : activeSurface === "drive"
            ? driveTabId(activeDrivePreview?.id ?? "")
            : (activeBrowserPage?.id ?? browserPages[0]?.id ?? "");

  const expandChat = () => {
    if (!activeChat) return;
    onOpenChat(activeChat);
  };
  const openChildChat = (conversationRef: ChatConversationRef) => {
    if (!displayedHost || conversationRef.kind !== "agent_task") return;
    openChat(displayedHost, {
      conversationId: conversationRef.conversationId,
      groupId: displayedHost.groupId,
      kind: "agent_task",
      title: conversationRef.title,
      workspaceId: displayedHost.workspaceId,
    });
  };
  const clearExitedContent = () => {
    if (!open) {
      setRenderedSidebar(undefined);
    }
  };
  const hostKey = displayedHost ? chatSidebarHostKey(displayedHost) : "";
  const sidebarTabs: RightSidebarTab[] = [
    ...chats.map((chat) => ({
      closable: true,
      icon: <SidebarTaskIcon api={api} target={chat} />,
      id: chatTabId(chat),
      label: chat.title?.trim() || messages.chat_ref_task(),
      panelId: "chat-sidebar-chat-panel",
    })),
    ...filePreviews.map((preview) => ({
      closable: true,
      icon: <FileIcon className="size-5" />,
      id: `${fileTabPrefix}${preview.id}`,
      label: preview.source.fileName,
      panelId: "chat-sidebar-file-panel",
    })),
    ...drivePreviews.map((preview) => ({
      closable: true,
      icon: <FileIcon className="size-5" />,
      id: driveTabId(preview.id),
      label: preview.name,
      panelId: `chat-sidebar-drive-panel-${preview.id}`,
    })),
    ...historyPages.map((page) => ({
      closable: true,
      id: historyTabId(page.id),
      label: `${messages.session_history_title()} · ${sessionParticipantName(page.participant, routerName, messages.chat_actor_worker())}`,
      panelId: `chat-sidebar-history-panel-${page.id}`,
    })),
    ...browserPages.map((page) => ({
      closable: true,
      icon: <BrowserPageIcon favicon={page.favicon} />,
      id: page.id,
      label: browserPageLabel(page),
      panelId: `chat-sidebar-browser-panel-${page.id}`,
    })),
  ];
  const handleTabChange = (tabId: string) => {
    if (!displayedHost) return;
    if (tabId.startsWith(fileTabPrefix)) {
      selectFilePreview(displayedHost, tabId.slice(fileTabPrefix.length));
      return;
    }
    if (tabId.startsWith(historyTabPrefix)) {
      selectHistoryPage(displayedHost, tabId.slice(historyTabPrefix.length));
      return;
    }
    if (tabId.startsWith(chatTabPrefix)) {
      selectChat(displayedHost, tabId.slice(chatTabPrefix.length));
      return;
    }
    const driveFileId = driveFileIdFromTab(tabId);
    if (driveFileId) {
      selectDrivePreview(displayedHost, driveFileId);
      return;
    }
    selectBrowserPage(displayedHost, tabId);
  };
  const handleTabClose = (tabId: string) => {
    if (!displayedHost) return;
    if (tabId.startsWith(fileTabPrefix)) {
      closeFilePreview(displayedHost, tabId.slice(fileTabPrefix.length));
      return;
    }
    if (tabId.startsWith(historyTabPrefix)) {
      closeHistoryPage(displayedHost, tabId.slice(historyTabPrefix.length));
      return;
    }
    if (tabId.startsWith(chatTabPrefix)) {
      closeChat(displayedHost, tabId.slice(chatTabPrefix.length));
      return;
    }
    const driveFileId = driveFileIdFromTab(tabId);
    if (driveFileId) {
      closeDrivePreview(displayedHost, driveFileId);
      return;
    }
    closeBrowserPage(displayedHost, tabId);
  };

  useApplicationMenu([
    {
      id: "browser-new-tab",
      enabled: true,
      run: () => {
        if (displayedHost) addBrowserTab(displayedHost);
        else toggleActive();
      },
    },
    {
      id: "browser-close-tab",
      enabled: isOpen && Boolean(activeTab),
      run: () => {
        if (activeTab) handleTabClose(activeTab);
      },
    },
  ]);
  return (
    <RightSidebar
      activeTab={activeTab}
      ariaLabel="Chat sidebar"
      data-testid="chat-sidebar"
      headerActions={
        activeSurface === "chat" && activeChat ? (
          <RightSidebarToolbarButton
            aria-label={messages.chat_task_open()}
            onClick={expandChat}
          >
            <ExpandSimpleIcon className="size-4" />
          </RightSidebarToolbarButton>
        ) : null
      }
      onAddTab={
        displayedHost
          ? () => {
              addBrowserTab(displayedHost);
            }
          : undefined
      }
      hostClampsRenderedWidth={hostClampsRenderedWidth}
      maxWidth={resolvedMaxWidth}
      minWidth={minWidth}
      resizeEdge={resizeEdge}
      resizeHandleAppearance={resizeHandleAppearance}
      resizeWidthMultiplier={resizeWidthMultiplier}
      onWidthPreview={onWidthPreview}
      onExitComplete={clearExitedContent}
      onTabChange={handleTabChange}
      onTabClose={handleTabClose}
      onWidthChange={handleWidthChange}
      open={open}
      ref={trailingRef}
      style={style}
      tabs={sidebarTabs}
      width={width}
    >
      {displayedHost && displayedSession ? (
        <>
          {browserPages.map((page) =>
            page.url ? (
              <BrowserSidebarPanel
                key={page.id}
                nativeCapacityBlockedAtEpoch={getNativeBrowserCapacityBlockedEpoch(
                  chatSidebarBrowserPageSessionId(hostKey, page.id)
                )}
                nativeCapacityEpoch={nativeBrowserCapacityEpoch}
                nativeState={nativeBrowserStates.get(
                  chatSidebarBrowserPageSessionId(hostKey, page.id)
                )}
                onNativeStateChanged={recordNativeBrowserState}
                onInspectElement={
                  canSendBrowserInspection ? handleBrowserInspection : undefined
                }
                onPageMetadataChange={(patch) => {
                  updateBrowserPageMetadata(displayedHost, page.id, patch);
                }}
                page={page}
                sessionId={chatSidebarBrowserPageSessionId(hostKey, page.id)}
                suppressed={nativeSurfaceSuppressed || suppressNativeSurface}
                visible={
                  open &&
                  activeSurface === "browser" &&
                  activeBrowserPage?.id === page.id
                }
              />
            ) : activeSurface === "browser" && activeBrowserPage?.id === page.id ? (
              <BrowserNewTabPanel
                key={page.id}
                onSubmitUrl={(url) => {
                  updateBrowserPage(displayedHost, page.id, { url });
                }}
                page={page}
              />
            ) : null
          )}
          {open && activeSurface === "file" && activeFilePreview ? (
            <FilePreviewPanel
              api={api}
              key={activeFilePreview.id}
              source={activeFilePreview.source}
              panelId="chat-sidebar-file-panel"
              onAttachFiles={attachPreviewImage}
              onOpenBrowser={(url) => openBrowser(displayedHost, { url })}
            />
          ) : null}
          {open && activeSurface === "drive" && activeDrivePreview ? (
            <DrivePreviewPanel
              onAttachFiles={attachPreviewImage}
              onOpenBrowser={(url) => openBrowser(displayedHost, { url })}
              fileId={activeDrivePreview.id}
              key={activeDrivePreview.id}
              panelId={`chat-sidebar-drive-panel-${activeDrivePreview.id}`}
            />
          ) : null}
          {historyPages.map((page) => (
            <section
              key={page.id}
              role="tabpanel"
              id={`chat-sidebar-history-panel-${page.id}`}
              aria-label={messages.session_history_title()}
              hidden={activeSurface !== "history" || activeHistoryPage?.id !== page.id}
              style={{
                display:
                  activeSurface === "history" && activeHistoryPage?.id === page.id
                    ? "flex"
                    : "none",
              }}
              className="min-h-0 min-w-0 flex-1 flex-col"
            >
              <SessionHistoryPage
                groupId={page.groupId}
                participant={page.participant}
                active={
                  open &&
                  activeSurface === "history" &&
                  activeHistoryPage?.id === page.id
                }
              />
            </section>
          ))}
          {activeSurface === "chat" && activeChat ? (
            <ChatSidebarConversation
              api={api}
              key={chatSidebarHostKey(activeChat)}
              onOpenBrowser={(url) => openBrowser(displayedHost, { url })}
              onOpenConversationRef={openChildChat}
              onOpenTasksFilter={onOpenTasksFilter}
              surfaceActive={open}
              target={activeChat}
            />
          ) : null}
          {sidebarTabs.length === 0 ? (
            <ChatSidebarEmptyState
              onCreateBrowserTab={() => addBrowserTab(displayedHost)}
            />
          ) : null}
        </>
      ) : null}
    </RightSidebar>
  );
}

/** Window bar control for the Chat Sidebar; the bar owns its placement. */
export function ChatSidebarToggle() {
  const { isOpen, toggleActive } = useChatSidebar();
  const rightSidebarShortcut = useOptionalAppShortcutBinding("toggle-right-sidebar");

  return (
    <ShellIconButton
      className="comma-chat-sidebar-toggle"
      expanded={isOpen}
      icon="layout-right"
      label="Toggle chat sidebar"
      onClick={toggleActive}
      {...(rightSidebarShortcut
        ? { shortcut: appKeybindingKeycaps(rightSidebarShortcut) }
        : {})}
      testId="chat-sidebar-toggle"
    />
  );
}

function ChatSidebarEmptyState({
  onCreateBrowserTab,
}: {
  onCreateBrowserTab: () => void;
}) {
  const messages = useCommaMessages();

  return (
    <div
      className="flex min-h-0 flex-1 flex-col items-center justify-center gap-md px-xl text-center"
      data-testid="chat-sidebar-empty"
    >
      <GlobeIcon className="size-6 text-tertiary" />
      <div className="flex flex-col gap-xs">
        <span className="text-sm font-medium text-primary">
          {messages.chat_sidebar_empty_title()}
        </span>
        <span className="text-xs text-tertiary">
          {messages.chat_sidebar_empty_description()}
        </span>
      </div>
      <Button
        className="h-7 px-lg"
        hierarchy="secondary-gray"
        onPress={onCreateBrowserTab}
        size="sm"
      >
        {messages.chat_sidebar_new_browser_tab()}
      </Button>
    </div>
  );
}

function ChatSidebarConversation({
  onOpenTasksFilter,
  api,
  onOpenBrowser,
  onOpenConversationRef,
  surfaceActive,
  target,
}: {
  api: CommaApiClient;
  onOpenTasksFilter?: ((filter: TasksFilterLink) => void) | undefined;
  onOpenBrowser: (url: string) => void;
  onOpenConversationRef: (conversationRef: ChatConversationRef) => void;
  surfaceActive: boolean;
  target: ChatSidebarConversationTarget;
}) {
  const conversation = useConversation(
    target.workspaceId,
    target.groupId,
    target.conversationId
  );
  const skills = useWorkspaceSkills(api, target.workspaceId);
  // Depend on the stable per-channel action identities, not the conversation
  // object (whose identity changes on every state emit).
  const { acceptTaskReview, refresh } = conversation;
  const actions = useMemo<ConversationViewActions>(
    () => ({
      acceptTaskReview,
      setTaskLabels: async (labelIds) => {
        try {
          await api.setTaskLabels(target.groupId, target.conversationId, labelIds);
        } finally {
          await refresh();
        }
      },
      attachFiles: conversation.attachFiles,
      discard: conversation.discard,
      ...(conversation.pickAttachments
        ? { pickAttachments: conversation.pickAttachments }
        : {}),
      ...(conversation.previewLocalFile
        ? { previewLocalFile: conversation.previewLocalFile }
        : {}),
      refresh,
      removeAttachment: conversation.removeAttachment,
      retry: conversation.retry,
      retryAttachment: conversation.retryAttachment,
      send: conversation.send,
      setDraft: conversation.setDraft,
    }),
    [
      acceptTaskReview,
      api,
      target.conversationId,
      target.groupId,
      conversation.attachFiles,
      conversation.discard,
      conversation.pickAttachments,
      conversation.previewLocalFile,
      refresh,
      conversation.removeAttachment,
      conversation.retry,
      conversation.retryAttachment,
      conversation.send,
      conversation.setDraft,
    ]
  );

  return (
    <div
      aria-label={target.title ? `Chat: ${target.title}` : "Child chat"}
      className="comma-chat-sidebar-chat"
      data-testid={`chat-sidebar-conversation-${target.conversationId}`}
      id="chat-sidebar-chat-panel"
      role="tabpanel"
    >
      <ConversationView
        actions={actions}
        api={api}
        groupId={target.groupId}
        conversationId={target.conversationId}
        draftSource={conversation.draftSource}
        onOpenConversationRef={onOpenConversationRef}
        onOpenInCommaBrowser={onOpenBrowser}
        onOpenTasksFilter={onOpenTasksFilter}
        skills={skills}
        state={conversation.state}
        surfaceActive={surfaceActive}
        variant="rail"
        workspaceId={target.workspaceId}
      />
    </div>
  );
}

// Address/browser failures surface as a persistent error toast that clears
// itself once the address recovers; the toolbar input still turns red.
function useBrowserErrorToast(error: string | undefined) {
  const toastId = useRef<string | number | undefined>(undefined);
  useEffect(() => {
    if (!error) {
      if (toastId.current !== undefined) {
        toast.dismiss(toastId.current);
        toastId.current = undefined;
      }
      return;
    }
    // Sonner dismisses on a later frame. Update a live error in place, and
    // allocate a fresh ID after recovery so an old dismissal cannot remove it.
    const nextToastId = toast.error(error, {
      duration: Number.POSITIVE_INFINITY,
      ...(toastId.current !== undefined ? { id: toastId.current } : {}),
      onClose: () => {
        if (toastId.current === nextToastId) toastId.current = undefined;
      },
      testId: "browser-error",
    });
    toastId.current = nextToastId === "" ? undefined : nextToastId;
  }, [error]);
  useEffect(
    () => () => {
      if (toastId.current !== undefined) {
        toast.dismiss(toastId.current);
        toastId.current = undefined;
      }
    },
    []
  );
}

function BrowserNewTabPanel({
  onSubmitUrl,
  page,
}: {
  onSubmitUrl: (url: string) => void;
  page: ChatSidebarBrowserPage;
}) {
  const [address, setAddress] = useState(page.url);
  const [addressError, setAddressError] = useState<string | undefined>();
  useBrowserErrorToast(addressError);

  const submitAddress = () => {
    const url = normalizeBrowserAddress(address);
    if (!url) {
      setAddressError("Enter a valid http or https address.");
      return;
    }
    setAddressError(undefined);
    setAddress(url);
    onSubmitUrl(url);
  };

  return (
    <section
      aria-label="Browser"
      className="comma-chat-sidebar-browser"
      id={`chat-sidebar-browser-panel-${page.id}`}
      role="tabpanel"
    >
      <RightSidebarBrowserToolbar
        address={address}
        addressInvalid={Boolean(addressError)}
        canGoBack={false}
        canGoForward={false}
        disabled={false}
        loading={false}
        onAddressChange={setAddress}
        onAddressSubmit={submitAddress}
        onBack={() => undefined}
        onForward={() => undefined}
        onReload={() => undefined}
      />
      <div className="comma-chat-sidebar-browser-unavailable">
        <p>Search or enter a URL to open a page.</p>
      </div>
    </section>
  );
}

function BrowserSidebarPanel({
  nativeCapacityBlockedAtEpoch,
  nativeCapacityEpoch,
  nativeState,
  onNativeStateChanged,
  onInspectElement,
  onPageMetadataChange,
  page,
  sessionId,
  suppressed,
  visible,
}: {
  nativeCapacityBlockedAtEpoch?: number | undefined;
  nativeCapacityEpoch: number;
  nativeState?: BrowserSidebarState | undefined;
  onNativeStateChanged: (
    state: BrowserSidebarState,
    capacityAttemptEpoch?: number | undefined
  ) => void;
  onInspectElement?:
    | ((
        inspection: Extract<BrowserSidebarInspectResult, { status: "selected" }>
      ) => void)
    | undefined;
  onPageMetadataChange: (
    patch: Partial<Pick<ChatSidebarBrowserPage, "title" | "url">>
  ) => void;
  page: ChatSidebarBrowserPage;
  sessionId: string;
  suppressed: boolean;
  visible: boolean;
}) {
  // Native metadata and inactive-session recovery are modeled in
  // tla/browser-sidebar/BrowserSidebar.tla.
  const bridge = getNativeBridge();
  const messages = useCommaMessages();
  const [unavailableReason, setUnavailableReason] = useState<string | undefined>(
    bridge.platform === "electron" ? undefined : nativeBrowserUnavailable
  );
  const [browserState, setBrowserState] = useState<BrowserSidebarState>({
    ...(nativeState?.sessionId === sessionId
      ? nativeState
      : {
          active: false,
          available: bridge.platform === "electron",
          canGoBack: false,
          canGoForward: false,
          loading: false,
          url: page.url,
        }),
  });
  const [address, setAddress] = useState(page.url);
  const [addressError, setAddressError] = useState<string | undefined>();
  const [editingAddress, setEditingAddress] = useState(false);
  const [inspecting, setInspecting] = useState(false);
  useBrowserErrorToast(
    addressError ?? (browserState.available ? browserState.reason : undefined)
  );
  const panelGenerationRef = useRef(0);
  const panelMountedRef = useRef(false);
  const panelRequestGenerationRef = useRef(0);
  const inspectionGenerationRef = useRef(0);

  useLayoutEffect(() => {
    const generation = panelGenerationRef.current + 1;
    panelGenerationRef.current = generation;
    panelMountedRef.current = true;
    return () => {
      if (panelGenerationRef.current === generation) {
        panelMountedRef.current = false;
        panelGenerationRef.current += 1;
      }
    };
  }, [sessionId]);

  const isCurrentPanelGeneration = useCallback(
    (generation: number) =>
      panelMountedRef.current && panelGenerationRef.current === generation,
    []
  );

  const publishBrowserState = useCallback(
    (state: BrowserSidebarState, capacityAttemptEpoch?: number | undefined) => {
      if (!panelMountedRef.current) {
        if (state.reasonCode === "capacity") {
          onNativeStateChanged(state, capacityAttemptEpoch);
        }
        return;
      }
      setBrowserState(state);
      onNativeStateChanged(state, capacityAttemptEpoch);
      if (!state.available) {
        setUnavailableReason(state.reason ?? nativeBrowserUnavailable);
      } else {
        setUnavailableReason(undefined);
      }
    },
    [onNativeStateChanged]
  );
  useEffect(() => {
    if (nativeState?.sessionId !== sessionId) return;
    setBrowserState(nativeState);
    if (!nativeState.available) {
      setUnavailableReason(nativeState.reason ?? nativeBrowserUnavailable);
    } else {
      setUnavailableReason(undefined);
    }
  }, [nativeState, sessionId]);
  useEffect(() => {
    if (!editingAddress && browserState.url) {
      setAddress(browserState.url);
    }
  }, [browserState.url, editingAddress]);
  useEffect(() => {
    if (!editingAddress) setAddress(page.url);
  }, [editingAddress, page.url]);

  const navigate = async (action: "back" | "forward" | "reload" | "stop") => {
    const panelGeneration = panelGenerationRef.current;
    const requestGeneration = panelRequestGenerationRef.current + 1;
    panelRequestGenerationRef.current = requestGeneration;
    try {
      const state = await bridge.browserSidebar.navigate({ action, sessionId });
      if (
        !isCurrentPanelGeneration(panelGeneration) ||
        panelRequestGenerationRef.current !== requestGeneration
      ) {
        return;
      }
      publishBrowserState(state);
    } catch (error: unknown) {
      if (
        !isCurrentPanelGeneration(panelGeneration) ||
        panelRequestGenerationRef.current !== requestGeneration
      ) {
        return;
      }
      setUnavailableReason(
        error instanceof Error ? error.message : nativeBrowserUnavailable
      );
    }
  };
  const submitAddress = async () => {
    const url = normalizeBrowserAddress(address);
    if (!url) {
      setAddressError("Enter a valid http or https address.");
      return;
    }
    const panelGeneration = panelGenerationRef.current;
    const requestGeneration = panelRequestGenerationRef.current + 1;
    panelRequestGenerationRef.current = requestGeneration;
    setAddressError(undefined);
    setAddress(url);
    onPageMetadataChange({ url });
    try {
      const state = await bridge.browserSidebar.update({ sessionId, url });
      if (
        !isCurrentPanelGeneration(panelGeneration) ||
        panelRequestGenerationRef.current !== requestGeneration
      ) {
        return;
      }
      publishBrowserState(state);
    } catch (error: unknown) {
      if (
        !isCurrentPanelGeneration(panelGeneration) ||
        panelRequestGenerationRef.current !== requestGeneration
      ) {
        return;
      }
      setAddressError(
        error instanceof Error ? error.message : "This page could not be loaded."
      );
    }
  };
  const toggleInspection = async () => {
    const generation = inspectionGenerationRef.current + 1;
    inspectionGenerationRef.current = generation;
    if (inspecting) {
      setInspecting(false);
      await bridge.browserSidebar
        .inspect({ action: "cancel", sessionId })
        .catch(() => undefined);
      return;
    }

    setInspecting(true);
    try {
      const result = await bridge.browserSidebar.inspect({
        action: "start",
        sessionId,
      });
      if (inspectionGenerationRef.current !== generation) return;
      if (result.status === "selected") {
        onInspectElement?.(result);
      } else if (result.status === "unavailable") {
        toast.error(result.reason);
      }
    } catch (error: unknown) {
      if (inspectionGenerationRef.current !== generation) return;
      toast.error(
        error instanceof Error
          ? error.message
          : "Element selection could not be started."
      );
    } finally {
      if (inspectionGenerationRef.current === generation) setInspecting(false);
    }
  };

  useEffect(
    () => () => {
      inspectionGenerationRef.current += 1;
      void bridge.browserSidebar
        .inspect({ action: "cancel", sessionId })
        .catch(() => undefined);
    },
    [bridge.browserSidebar, sessionId]
  );

  return (
    <section
      aria-label="Browser"
      className="comma-chat-sidebar-browser"
      data-visible={visible ? "true" : "false"}
      hidden={!visible}
      id={`chat-sidebar-browser-panel-${page.id}`}
      role="tabpanel"
    >
      <RightSidebarBrowserToolbar
        address={address}
        addressInvalid={Boolean(addressError)}
        canGoBack={Boolean(browserState.canGoBack)}
        canGoForward={Boolean(browserState.canGoForward)}
        disabled={!browserState.active}
        loading={Boolean(browserState.loading)}
        inspecting={inspecting}
        onAddressBlur={() => setEditingAddress(false)}
        onAddressChange={setAddress}
        onAddressFocus={() => setEditingAddress(true)}
        onAddressSubmit={() => {
          void submitAddress();
        }}
        onBack={() => {
          void navigate("back");
        }}
        onForward={() => {
          void navigate("forward");
        }}
        onInspect={
          onInspectElement
            ? () => {
                void toggleInspection();
              }
            : undefined
        }
        onOpenExternal={() => {
          void openUrlInExternalBrowser(page.url).catch(() =>
            toast.error(messages.chat_open_browser_failed())
          );
        }}
        onPermissions={
          bridge.platform === "electron"
            ? (anchor) => {
                void bridge.browserSidebar
                  .showPermissions({ sessionId, anchor })
                  .then((result) => {
                    if (result.status === "unavailable")
                      toast.error(
                        result.reason ?? "Website permissions are unavailable."
                      );
                  })
                  .catch((error) =>
                    toast.error(
                      error instanceof Error
                        ? error.message
                        : "Website permissions are unavailable."
                    )
                  );
              }
            : undefined
        }
        onReload={() => {
          void navigate("reload");
        }}
        onStop={() => {
          void navigate("stop");
        }}
      />
      {bridge.platform === "electron" && !unavailableReason ? (
        <NativeBrowserViewport
          closeBeforeOpenSessionIds={page.closeBeforeOpenSessionIds}
          nativeCapacityBlockedAtEpoch={nativeCapacityBlockedAtEpoch}
          nativeState={browserState}
          nativeCapacityEpoch={nativeCapacityEpoch}
          onStateChanged={publishBrowserState}
          onStateSettled={onNativeStateChanged}
          onUnavailable={setUnavailableReason}
          sessionId={sessionId}
          tabId={page.id}
          suppressed={suppressed}
          navigationRevision={page.navigationRevision}
          url={page.url}
          visible={visible}
        />
      ) : (
        <BrowserUnavailable
          canOpenExternal={bridge.platform !== "electron"}
          reason={unavailableReason ?? nativeBrowserUnavailable}
          url={page.url}
        />
      )}
    </section>
  );
}

function NativeBrowserViewport({
  closeBeforeOpenSessionIds,
  nativeCapacityBlockedAtEpoch,
  nativeCapacityEpoch,
  nativeState,
  onStateChanged,
  onStateSettled,
  onUnavailable,
  sessionId,
  tabId,
  suppressed,
  navigationRevision,
  url,
  visible,
}: {
  closeBeforeOpenSessionIds?: string[] | undefined;
  nativeCapacityBlockedAtEpoch?: number | undefined;
  nativeCapacityEpoch: number;
  nativeState: BrowserSidebarState;
  onStateChanged: (
    state: BrowserSidebarState,
    capacityAttemptEpoch?: number | undefined
  ) => void;
  onStateSettled: (
    state: BrowserSidebarState,
    capacityAttemptEpoch?: number | undefined
  ) => void;
  onUnavailable: (reason: string | undefined) => void;
  sessionId: string;
  tabId: string;
  suppressed: boolean;
  navigationRevision: number;
  url: string;
  visible: boolean;
}) {
  const elementRef = useRef<HTMLDivElement | null>(null);
  const mountedRef = useRef(false);
  const mountedSessionIdRef = useRef(sessionId);
  const viewportGenerationRef = useRef(0);
  const openRequestGenerationRef = useRef(0);
  const openingRef = useRef(false);
  const openedRef = useRef(false);
  const openViewRef = useRef<() => boolean>(() => false);
  const capacityBlockedAttemptEpochRef = useRef<number | undefined>(
    nativeCapacityBlockedAtEpoch
  );
  const capacityBlockedRef = useRef(nativeState.reasonCode === "capacity");
  const nativeCapacityBlockedAtEpochRef = useRef(nativeCapacityBlockedAtEpoch);
  const nativeCapacityEpochRef = useRef(nativeCapacityEpoch);
  const recoveryAttemptedRef = useRef(false);
  const recoveryScheduledRef = useRef(false);
  const lastSubmittedNavigationRevisionRef = useRef(0);
  const requestedNavigationRef = useRef({
    closeBeforeOpenSessionIds: closeBeforeOpenSessionIds ?? [],
    navigationRevision,
    url,
  });
  const syncFrameRef = useRef<number | undefined>(undefined);
  // What the native view may show right now: the product says the panel is
  // displayed AND no full-window DOM overlay holds a suppression claim.
  const nativeVisible = visible && !suppressed;
  const visibleRef = useRef(nativeVisible);
  const [suppressionSnapshotUrl, setSuppressionSnapshotUrl] = useState<
    string | undefined
  >(undefined);
  const suppressionSnapshotUrlRef = useRef<string | undefined>(undefined);
  const suppressionSnapshotRef = useRef<HTMLImageElement>(null);
  const nativeVisibilityEpochRef = useRef(0);
  // The ref owns the resource independently of React state so unmount can
  // synchronously revoke it even though state updates no longer have an owner.
  const revokeSuppressionSnapshot = useCallback(() => {
    const previous = suppressionSnapshotUrlRef.current;
    suppressionSnapshotUrlRef.current = undefined;
    if (previous) URL.revokeObjectURL(previous);
  }, []);
  const clearSuppressionSnapshot = useCallback(() => {
    revokeSuppressionSnapshot();
    if (mountedRef.current) setSuppressionSnapshotUrl(undefined);
  }, [revokeSuppressionSnapshot]);
  const replaceSuppressionSnapshot = useCallback((objectUrl: string) => {
    const previous = suppressionSnapshotUrlRef.current;
    suppressionSnapshotUrlRef.current = objectUrl;
    if (previous && previous !== objectUrl) URL.revokeObjectURL(previous);
    setSuppressionSnapshotUrl(objectUrl);
  }, []);
  capacityBlockedRef.current = nativeState.reasonCode === "capacity";
  nativeCapacityBlockedAtEpochRef.current = nativeCapacityBlockedAtEpoch;
  nativeCapacityEpochRef.current = nativeCapacityEpoch;
  requestedNavigationRef.current = {
    closeBeforeOpenSessionIds: closeBeforeOpenSessionIds ?? [],
    navigationRevision,
    url,
  };
  visibleRef.current = nativeVisible;
  mountedSessionIdRef.current = sessionId;
  const requestRecovery = useCallback(() => {
    if (
      !mountedRef.current ||
      !visibleRef.current ||
      openingRef.current ||
      recoveryAttemptedRef.current ||
      recoveryScheduledRef.current
    ) {
      return;
    }
    recoveryScheduledRef.current = true;
    queueMicrotask(() => {
      recoveryScheduledRef.current = false;
      if (
        !mountedRef.current ||
        !visibleRef.current ||
        openingRef.current ||
        openedRef.current
      ) {
        return;
      }
      if (openViewRef.current()) {
        recoveryAttemptedRef.current = true;
      }
    });
  }, []);
  const reflectNativeState = useCallback(
    (state: BrowserSidebarState) => {
      openedRef.current = state.available && state.active;
      if (openedRef.current) {
        openingRef.current = false;
        capacityBlockedAttemptEpochRef.current = undefined;
        recoveryAttemptedRef.current = false;
        onUnavailable(undefined);
      } else if (!state.available) {
        onUnavailable(state.reason ?? nativeBrowserUnavailable);
      } else if (state.reasonCode === "capacity") {
        capacityBlockedAttemptEpochRef.current ??=
          nativeCapacityBlockedAtEpochRef.current ?? nativeCapacityEpochRef.current;
        recoveryAttemptedRef.current = true;
      } else {
        requestRecovery();
      }
    },
    [onUnavailable, requestRecovery]
  );
  const publishState = useCallback(
    (state: BrowserSidebarState, capacityAttemptEpoch?: number | undefined) => {
      reflectNativeState(state);
      onStateChanged(state, capacityAttemptEpoch);
    },
    [onStateChanged, reflectNativeState]
  );
  const isCurrentViewportGeneration = useCallback(
    (generation: number) =>
      mountedRef.current && viewportGenerationRef.current === generation,
    []
  );
  const isCurrentViewportIntent = useCallback(
    (
      viewportGeneration: number,
      requestIntent: { navigationRevision: number; url: string }
    ) =>
      isCurrentViewportGeneration(viewportGeneration) &&
      requestedNavigationRef.current.navigationRevision ===
        requestIntent.navigationRevision &&
      requestedNavigationRef.current.url === requestIntent.url,
    [isCurrentViewportGeneration]
  );
  const settleState = useCallback(
    (
      state: BrowserSidebarState,
      viewportGeneration: number,
      capacityAttemptEpoch?: number | undefined,
      requestIntent?: { navigationRevision: number; url: string } | undefined
    ) => {
      if (
        (requestIntent === undefined &&
          !isCurrentViewportGeneration(viewportGeneration)) ||
        (requestIntent !== undefined &&
          !isCurrentViewportIntent(viewportGeneration, requestIntent))
      ) {
        if (state.reasonCode === "capacity") {
          onStateSettled(state, capacityAttemptEpoch);
        }
        return false;
      }
      if (state.reasonCode === "capacity") {
        capacityBlockedAttemptEpochRef.current = capacityAttemptEpoch;
      }
      publishState(
        state,
        state.reasonCode === "capacity" ? capacityAttemptEpoch : undefined
      );
      return true;
    },
    [isCurrentViewportGeneration, isCurrentViewportIntent, onStateSettled, publishState]
  );
  const settleOpenState = useCallback(
    (
      state: BrowserSidebarState,
      viewportGeneration: number,
      requestGeneration: number,
      requestNavigationRevision: number,
      requestUrl: string,
      capacityAttemptEpoch: number
    ) => {
      if (
        !isCurrentViewportGeneration(viewportGeneration) ||
        openRequestGenerationRef.current !== requestGeneration ||
        requestedNavigationRef.current.navigationRevision !==
          requestNavigationRevision ||
        requestedNavigationRef.current.url !== requestUrl
      ) {
        if (state.reasonCode === "capacity") {
          onStateSettled(state, capacityAttemptEpoch);
        }
        return false;
      }
      return settleState(state, viewportGeneration, capacityAttemptEpoch);
    },
    [isCurrentViewportGeneration, onStateSettled, settleState]
  );

  const readBounds = useCallback(() => {
    const element = elementRef.current;
    if (!element) return undefined;
    const rect = element.getBoundingClientRect();
    if (rect.width < 1 || rect.height < 1) return undefined;
    // Read the live DOM width, including an uncommitted drag preview. Do not
    // capture shared width here: that used to reinstall observers every frame.
    const sidebar = element.closest<HTMLElement>(".comma-chat-sidebar");
    const liveWidth = Number.parseFloat(
      sidebar?.style.getPropertyValue("--comma-chat-sidebar-width") ?? ""
    );
    const width = Math.min(
      rect.width,
      Number.isFinite(liveWidth) ? liveWidth : rect.width
    );
    return {
      height: Math.max(1, Math.round(rect.height)),
      width: Math.max(1, Math.round(width)),
      x: Math.max(0, Math.round(rect.right - width)),
      y: Math.max(0, Math.round(rect.y)),
    };
  }, []);

  const syncBounds = useCallback(() => {
    if (!visibleRef.current) return;
    if (!openedRef.current) {
      requestRecovery();
      return;
    }
    const bounds = readBounds();
    if (!bounds) return;
    const viewportGeneration = viewportGenerationRef.current;
    const requestIntent = requestedNavigationRef.current;
    void getNativeBridge()
      .browserSidebar.update({ bounds, sessionId })
      .then((state) => settleState(state, viewportGeneration, undefined, requestIntent))
      .catch((error: unknown) => {
        if (!isCurrentViewportIntent(viewportGeneration, requestIntent)) return;
        onUnavailable(
          error instanceof Error ? error.message : nativeBrowserUnavailable
        );
      });
  }, [
    isCurrentViewportIntent,
    onUnavailable,
    readBounds,
    requestRecovery,
    sessionId,
    settleState,
  ]);

  const openView = useCallback(() => {
    if (openingRef.current || openedRef.current) return false;
    const bounds = readBounds();
    if (!bounds) return false;
    openingRef.current = true;
    const openingViewportGeneration = viewportGenerationRef.current;
    const openingRequestGeneration = openRequestGenerationRef.current + 1;
    openRequestGenerationRef.current = openingRequestGeneration;
    const openingCapacityEpoch = nativeCapacityEpochRef.current;
    if (capacityBlockedRef.current) {
      capacityBlockedAttemptEpochRef.current = openingCapacityEpoch;
    }
    const openingIntent = requestedNavigationRef.current;
    lastSubmittedNavigationRevisionRef.current = openingIntent.navigationRevision;
    void getNativeBridge()
      .browserSidebar.open({
        bounds,
        closeBeforeOpenSessionIds: openingIntent.closeBeforeOpenSessionIds,
        navigationRevision: openingIntent.navigationRevision,
        sessionId,
        tabId,
        url: openingIntent.url,
      })
      .then(async (result) => {
        if (
          !isCurrentViewportGeneration(openingViewportGeneration) ||
          openRequestGenerationRef.current !== openingRequestGeneration ||
          requestedNavigationRef.current.navigationRevision !==
            openingIntent.navigationRevision ||
          requestedNavigationRef.current.url !== openingIntent.url
        ) {
          settleOpenState(
            result,
            openingViewportGeneration,
            openingRequestGeneration,
            openingIntent.navigationRevision,
            openingIntent.url,
            openingCapacityEpoch
          );
          // Cleanup already emitted this instance's hide, and a newer request
          // owns this mounted viewport. Neither may be overwritten by this reply.
          return;
        }
        openingRef.current = false;
        if (result.reasonCode === "capacity") {
          capacityBlockedAttemptEpochRef.current = openingCapacityEpoch;
        }
        if (result.available && result.active && !visibleRef.current) {
          openedRef.current = true;
          recoveryAttemptedRef.current = false;
          try {
            settleState(
              await getNativeBridge().browserSidebar.update({
                sessionId,
                visible: false,
              }),
              openingViewportGeneration,
              undefined,
              openingIntent
            );
          } catch {
            // The view will also be closed by cleanup if its owner disappears.
          }
        } else {
          const settled = settleOpenState(
            result,
            openingViewportGeneration,
            openingRequestGeneration,
            openingIntent.navigationRevision,
            openingIntent.url,
            openingCapacityEpoch
          );
          if (settled && result.available && result.active && visibleRef.current) {
            syncBounds();
          }
        }
        const requestedIntent = requestedNavigationRef.current;
        if (
          openedRef.current &&
          requestedIntent.navigationRevision !== openingIntent.navigationRevision
        ) {
          const latestBounds = readBounds();
          if (!latestBounds) return;
          lastSubmittedNavigationRevisionRef.current =
            requestedIntent.navigationRevision;
          const latestViewportGeneration = viewportGenerationRef.current;
          const latestRequestGeneration = openRequestGenerationRef.current + 1;
          openRequestGenerationRef.current = latestRequestGeneration;
          const latestCapacityEpoch = nativeCapacityEpochRef.current;
          void getNativeBridge()
            .browserSidebar.open({
              bounds: latestBounds,
              closeBeforeOpenSessionIds: requestedIntent.closeBeforeOpenSessionIds,
              navigationRevision: requestedIntent.navigationRevision,
              sessionId,
              tabId,
              url: requestedIntent.url,
            })
            .then((state) => {
              const settled = settleOpenState(
                state,
                latestViewportGeneration,
                latestRequestGeneration,
                requestedIntent.navigationRevision,
                requestedIntent.url,
                latestCapacityEpoch
              );
              if (settled && state.available && state.active && visibleRef.current) {
                syncBounds();
              }
            })
            .catch((error: unknown) => {
              if (
                !isCurrentViewportGeneration(latestViewportGeneration) ||
                openRequestGenerationRef.current !== latestRequestGeneration ||
                requestedNavigationRef.current.navigationRevision !==
                  requestedIntent.navigationRevision ||
                requestedNavigationRef.current.url !== requestedIntent.url
              ) {
                return;
              }
              onUnavailable(
                error instanceof Error ? error.message : nativeBrowserUnavailable
              );
            });
        }
      })
      .catch((error: unknown) => {
        if (
          !isCurrentViewportGeneration(openingViewportGeneration) ||
          openRequestGenerationRef.current !== openingRequestGeneration ||
          requestedNavigationRef.current.navigationRevision !==
            openingIntent.navigationRevision ||
          requestedNavigationRef.current.url !== openingIntent.url
        ) {
          return;
        }
        openingRef.current = false;
        onUnavailable(
          error instanceof Error ? error.message : nativeBrowserUnavailable
        );
      });
    return true;
  }, [
    isCurrentViewportGeneration,
    onUnavailable,
    readBounds,
    sessionId,
    tabId,
    settleOpenState,
    settleState,
    syncBounds,
  ]);
  openViewRef.current = openView;

  useEffect(() => {
    if (nativeState.sessionId !== sessionId) return;
    reflectNativeState(nativeState);
  }, [nativeState, reflectNativeState, sessionId]);

  useEffect(() => {
    if (
      nativeState.sessionId !== sessionId ||
      nativeState.reasonCode !== "capacity" ||
      !visible
    ) {
      return;
    }
    const blockedAt = capacityBlockedAttemptEpochRef.current;
    if (blockedAt === undefined || nativeCapacityEpoch <= blockedAt) return;
    recoveryAttemptedRef.current = false;
    requestRecovery();
  }, [nativeCapacityEpoch, nativeState, requestRecovery, sessionId, visible]);

  useLayoutEffect(() => {
    const viewportGeneration = viewportGenerationRef.current + 1;
    viewportGenerationRef.current = viewportGeneration;
    mountedRef.current = true;
    // A session-id replacement preserves component state but not the previous
    // native viewport's resource ownership. Its cleanup revoked the ref before
    // this setup, so mirror that empty owner before paint.
    if (!suppressionSnapshotUrlRef.current) {
      setSuppressionSnapshotUrl(undefined);
    }
    return () => {
      // Invalidate every capture/paint continuation before dropping its
      // resource. A capture that resolves after this point must do nothing.
      nativeVisibilityEpochRef.current += 1;
      if (viewportGenerationRef.current === viewportGeneration) {
        viewportGenerationRef.current += 1;
        mountedRef.current = false;
      }
      revokeSuppressionSnapshot();
      openingRef.current = false;
      openedRef.current = false;
      capacityBlockedAttemptEpochRef.current = undefined;
      recoveryAttemptedRef.current = false;
      recoveryScheduledRef.current = false;
      if (syncFrameRef.current !== undefined) {
        window.cancelAnimationFrame(syncFrameRef.current);
      }
      // React StrictMode replays layout-effect cleanup/setup for the same
      // mounted tree. Let the matching setup reclaim this exact native
      // session before hiding it; otherwise the transient cleanup stops the
      // first navigation and the next URL becomes the first history entry.
      queueMicrotask(() => {
        if (mountedRef.current && mountedSessionIdRef.current === sessionId) return;
        void getNativeBridge()
          .browserSidebar.update({ sessionId, visible: false })
          .catch(() => {});
      });
    };
  }, [revokeSuppressionSnapshot, sessionId]);

  useLayoutEffect(() => {
    const epoch = ++nativeVisibilityEpochRef.current;
    const currentEpoch = () => nativeVisibilityEpochRef.current === epoch;

    if (!nativeVisible) {
      if (!capacityBlockedRef.current) recoveryAttemptedRef.current = false;
      if (syncFrameRef.current !== undefined) {
        window.cancelAnimationFrame(syncFrameRef.current);
        syncFrameRef.current = undefined;
      }
      if (openedRef.current) {
        const viewportGeneration = viewportGenerationRef.current;
        const requestIntent = requestedNavigationRef.current;
        const hide = () =>
          getNativeBridge()
            .browserSidebar.update({ sessionId, visible: false })
            .then((state) =>
              settleState(state, viewportGeneration, undefined, requestIntent)
            )
            .catch((error: unknown) => {
              if (!isCurrentViewportIntent(viewportGeneration, requestIntent)) {
                return;
              }
              onUnavailable(
                error instanceof Error ? error.message : nativeBrowserUnavailable
              );
            });
        if (suppressed && visible) {
          // Hiding for a DOM overlay, with the panel still displayed: the
          // native view composites above the DOM, so first capture its frame,
          // commit the stand-in <img>, and only then hide — the region shows
          // identical pixels throughout instead of a blank.
          void getNativeBridge()
            .browserSidebar.capture({ sessionId })
            .then(async (capture) => {
              if (
                capture.status !== "ready" ||
                !currentEpoch() ||
                !mountedRef.current
              ) {
                return;
              }
              let installed = false;
              // Synchronous commit: the img is in the DOM before the hide IPC
              // below can leave this renderer. Recheck inside flushSync because
              // it may flush an already-pending unmount before this callback.
              flushSync(() => {
                if (!currentEpoch() || !mountedRef.current) return;
                replaceSuppressionSnapshot(
                  URL.createObjectURL(
                    new Blob([capture.pngImage as BlobPart], { type: "image/png" })
                  )
                );
                installed = true;
              });
              if (!installed) return;
              // A committed img can still be blank while Chromium decodes the
              // PNG. Keep the live view until this exact stand-in is drawable.
              await suppressionSnapshotRef.current?.decode();
              if (!currentEpoch() || !mountedRef.current) return;
              // Cross a paint boundary after decoding; a single rAF runs
              // before paint, so hiding from it can still reveal a blank frame.
              // A timer bounds this wait when an occluded window pauses rAF;
              // the paint is invisible there anyway.
              return new Promise<void>((resolve) => {
                const timer = window.setTimeout(resolve, 48);
                requestAnimationFrame(() => {
                  requestAnimationFrame(() => {
                    window.clearTimeout(timer);
                    resolve();
                  });
                });
              });
            })
            .catch(() => undefined)
            .then(() => (currentEpoch() ? hide() : undefined));
        } else {
          void hide();
        }
      }
      return;
    }

    if (!capacityBlockedRef.current) openView();
    if (openedRef.current) {
      const viewportGeneration = viewportGenerationRef.current;
      const requestIntent = requestedNavigationRef.current;
      void getNativeBridge()
        .browserSidebar.update({ sessionId, visible: true })
        .then((result) => {
          if (
            settleState(result, viewportGeneration, undefined, requestIntent) &&
            result.available &&
            result.active
          ) {
            syncBounds();
          }
          // The live view composites above the DOM again; the stand-in can go.
          if (currentEpoch()) clearSuppressionSnapshot();
        })
        .catch((error: unknown) => {
          if (!isCurrentViewportIntent(viewportGeneration, requestIntent)) return;
          onUnavailable(
            error instanceof Error ? error.message : nativeBrowserUnavailable
          );
        });
    } else {
      clearSuppressionSnapshot();
    }
  }, [
    clearSuppressionSnapshot,
    isCurrentViewportIntent,
    nativeVisible,
    onUnavailable,
    openView,
    replaceSuppressionSnapshot,
    sessionId,
    settleState,
    suppressed,
    syncBounds,
    visible,
  ]);

  useEffect(() => {
    if (
      !openedRef.current ||
      navigationRevision <= lastSubmittedNavigationRevisionRef.current
    ) {
      return;
    }
    const bounds = readBounds();
    if (!bounds) return;
    lastSubmittedNavigationRevisionRef.current = navigationRevision;
    const viewportGeneration = viewportGenerationRef.current;
    const requestGeneration = openRequestGenerationRef.current + 1;
    openRequestGenerationRef.current = requestGeneration;
    const openingCapacityEpoch = nativeCapacityEpochRef.current;
    void getNativeBridge()
      .browserSidebar.open({
        bounds,
        closeBeforeOpenSessionIds: closeBeforeOpenSessionIds ?? [],
        navigationRevision,
        sessionId,
        tabId,
        url,
      })
      .then((state) =>
        settleOpenState(
          state,
          viewportGeneration,
          requestGeneration,
          navigationRevision,
          url,
          openingCapacityEpoch
        )
      )
      .catch((error: unknown) => {
        if (
          !isCurrentViewportGeneration(viewportGeneration) ||
          openRequestGenerationRef.current !== requestGeneration ||
          requestedNavigationRef.current.navigationRevision !== navigationRevision ||
          requestedNavigationRef.current.url !== url
        ) {
          return;
        }
        onUnavailable(
          error instanceof Error ? error.message : nativeBrowserUnavailable
        );
      });
  }, [
    closeBeforeOpenSessionIds,
    isCurrentViewportGeneration,
    navigationRevision,
    onUnavailable,
    readBounds,
    sessionId,
    tabId,
    settleOpenState,
    url,
  ]);

  // The native view composites above the whole renderer, so a toast raised
  // while it is showing — the browser's own error toasts included — would be
  // painted over rather than layered on top. Publish the slice of the window's
  // right edge it holds so the toast stack anchors clear of it, and let the
  // claim go the moment this view stops showing. Only a view Main has actually
  // opened obstructs anything; a blocked or failed one leaves DOM behind.
  const obstructsToasts =
    visible &&
    nativeState.sessionId === sessionId &&
    nativeState.available &&
    nativeState.active;

  const publishToastObstruction = useCallback(() => {
    const bounds = obstructsToasts ? readBounds() : undefined;
    if (!bounds) {
      releaseToastObstructionRight(sessionId);
      return;
    }
    claimToastObstructionRight(sessionId, window.innerWidth - bounds.x);
  }, [obstructsToasts, readBounds, sessionId]);

  useEffect(() => {
    const element = elementRef.current;
    if (!element) return undefined;
    const syncSurface = () => {
      syncBounds();
      publishToastObstruction();
    };
    const scheduleSync = () => {
      if (syncFrameRef.current !== undefined) {
        window.cancelAnimationFrame(syncFrameRef.current);
      }
      syncFrameRef.current = window.requestAnimationFrame(() => {
        syncFrameRef.current = undefined;
        syncSurface();
      });
    };
    const observer =
      typeof ResizeObserver === "undefined"
        ? undefined
        : new ResizeObserver(scheduleSync);
    const sidebar = element.closest(".comma-chat-sidebar");
    const syncAfterSidebarTransition = (event: Event) => {
      const transition = event as TransitionEvent;
      if (event.target === sidebar && transition.propertyName === "width") {
        scheduleSync();
      }
    };
    // The claim tracks the sidebar's own box rather than the viewport's. The
    // viewport keeps its width through the open transition — the sidebar clips
    // it instead of resizing it — so an observer on the viewport alone never
    // fires and the claim latches on a mid-transition rect a few pixels wide.
    // Watching the sidebar republishes on every frame of that transition, and
    // also covers the widths `transitionend` never reports: a `max-width`
    // clamp, an interrupted transition, or none at all under reduced motion.
    const obstructionObserver =
      typeof ResizeObserver === "undefined"
        ? undefined
        : new ResizeObserver(publishToastObstruction);
    observer?.observe(element);
    if (sidebar) obstructionObserver?.observe(sidebar);
    sidebar?.addEventListener("transitionend", syncAfterSidebarTransition);
    sidebar?.addEventListener("transitioncancel", syncAfterSidebarTransition);
    window.addEventListener("resize", scheduleSync);
    window.addEventListener("scroll", scheduleSync, true);
    // Published here and not only on the next frame: a resize drag re-runs this
    // effect on every committed width, and the cleanup that ran just before it
    // dropped the claim, so a deferred republish would blink the toast stack
    // back to the window corner for a frame.
    publishToastObstruction();
    scheduleSync();
    return () => {
      observer?.disconnect();
      obstructionObserver?.disconnect();
      sidebar?.removeEventListener("transitionend", syncAfterSidebarTransition);
      sidebar?.removeEventListener("transitioncancel", syncAfterSidebarTransition);
      window.removeEventListener("resize", scheduleSync);
      window.removeEventListener("scroll", scheduleSync, true);
      releaseToastObstructionRight(sessionId);
    };
  }, [publishToastObstruction, sessionId, syncBounds]);

  return (
    <div
      aria-label="Browser content"
      className="comma-chat-sidebar-browser-viewport"
      ref={elementRef}
    >
      {suppressionSnapshotUrl ? (
        // Frame-accurate stand-in for the hidden native view while a
        // full-window DOM overlay is up; dimmed by the overlay's backdrop like
        // any other page content.
        <img
          alt=""
          className="comma-chat-sidebar-browser-snapshot"
          ref={suppressionSnapshotRef}
          src={suppressionSnapshotUrl}
        />
      ) : null}
    </div>
  );
}

function BrowserUnavailable({
  canOpenExternal,
  reason,
  url,
}: {
  canOpenExternal: boolean;
  reason: string;
  url: string;
}) {
  const messages = useCommaMessages();
  return (
    <div className="comma-chat-sidebar-browser-unavailable">
      <p>{reason}</p>
      {needsDesktopApp() ? (
        <Button
          className="h-7 px-lg"
          hierarchy="secondary-gray"
          onPress={() => requestDesktopApp("browser")}
          size="sm"
        >
          {messages.desktop_app_get_mac()}
        </Button>
      ) : null}
      {canOpenExternal ? (
        <a href={url} rel="noopener noreferrer" target="_blank">
          Open in browser
        </a>
      ) : (
        <p className="break-all text-xs">{url}</p>
      )}
    </div>
  );
}

function normalizeBrowserAddress(value: string) {
  const candidate = value.trim();
  if (!candidate) return undefined;
  const withProtocol = /^[a-z][a-z\d+.-]*:/i.test(candidate)
    ? candidate
    : `https://${candidate}`;
  try {
    const url = new URL(withProtocol);
    return url.protocol === "http:" || url.protocol === "https:"
      ? url.toString()
      : undefined;
  } catch {
    return undefined;
  }
}

function BrowserPageIcon({ favicon }: { favicon: string | undefined }) {
  const [failed, setFailed] = useState<string>();
  if (!favicon || failed === favicon) return <GlobeIcon className="size-5" />;
  return (
    <img
      alt=""
      className="size-4 object-contain"
      draggable={false}
      onError={() => setFailed(favicon)}
      src={favicon}
    />
  );
}

function SidebarTaskIcon({
  api,
  target,
}: {
  api: CommaApiClient;
  target: ChatSidebarConversationTarget;
}) {
  const task = useTaskSummary(api, target.groupId, target.conversationId);
  return (
    <span
      className="comma-inline-task-icon"
      data-task-status={task?.status ?? "unknown"}
    >
      {taskStatusIcon(taskStatusBucket(task?.status ?? "unknown"))}
    </span>
  );
}
