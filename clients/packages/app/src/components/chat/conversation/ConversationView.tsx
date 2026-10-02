import { AgentBrowserPanel, AgentBrowserTrigger } from "./browser/AgentBrowserPanel";
import { useSessionBrowser } from "./browser/useSessionBrowser";
import {
  MediaMenuContext,
  mediaElementSource,
  useMediaContextMenu,
} from "../../file-preview/useMediaContextMenu";
import {
  DynamicUiDraftContext,
  DynamicUiLinkContext,
  DynamicUiLinkMenuContext,
} from "../dynamic-ui/DynamicUiWidget";
import { HomeLayout } from "../../home/HomeRailFolds";
import { ConversationParticipants } from "../session-history/SessionHistory";
import { useOptionalChatSidebar } from "../../chat-sidebar/ChatSidebarContext";
import { useRouter } from "@tanstack/react-router";
import { acceptedSendPromise } from "./sendAcceptance";
import type {
  ComposerDraftSource,
  ConversationViewState,
} from "../composer/conversationDraft";
import { useTaskSummary } from "../../tasks/useTaskArchive";
import { TaskShareButton } from "../../tasks/TaskShareButton";
import { taskStatusBucketLabel } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  Badge,
  Button,
  ContentHeader,
  CommaLogoAnimation,
  CopyContextMenu,
  LinkContextMenu,
  MarkdownStreamLinkDecoratorContext,
  SelectionActionBar,
  taskStatusBucket,
  taskStatusIcon,
  toast,
  type CopyContextMenuAction,
  type LinkContextMenuAction,
  type MarkdownStreamLinkDecorator,
  type SelectionActionBarAction,
  useTextEditContextMenuState,
} from "@comma/ui";
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
} from "react";
import type { CommaApiClient, CommaChatSuggestion, CommaSkill } from "../../../api";
import { createConversationAnalytics } from "../../../analytics/experience";
import { beginCommaMessageSend } from "../../../analytics/client";
import { ParticipantStatusSlot } from "../thread/activity/ActivityLine";
import { ChatBanner } from "./ChatBanner";
import { CreditWarningNotice } from "../../billing/CreditWarningNotice";
import { ChatLinkHoverCard } from "../thread/inline/ChatLinkHoverCard";
import {
  ChatLabelProposals,
  conversationLabelProposals,
} from "../tasks/labels/ChatLabelProposals";
import { groupLabelProposalsByAnchor } from "../tasks/labels/labelProposalAnchor";
import { useTaskLabelsCatalog } from "../tasks/labels/useTaskLabelsCatalog";
import { ChatTaskDock } from "../tasks/ChatTaskDock";
import type { TaskDetailsDoneState } from "../tasks/TaskDetailsPanel";
import { stateSwapExitMs, useLeaving } from "../motion/useLeaving";
import type { TasksFilterLink } from "../../tasks/taskChips";
import {
  TaskPanelBody,
  TaskPanelFoldedTrigger,
  useTaskPanelFold,
} from "../tasks/TaskPanelFold";
import { Composer } from "../composer/Composer";
import { createChatDraftQuote, type ChatDraftQuote } from "../composer/draftQuotes";
import { useChatSelectionQuote } from "./useChatSelectionQuote";
import {
  ConversationThread,
  type ChatOutgoingLaunch,
} from "../thread/ConversationThread";
import { measureOutgoingBubbleSource } from "../motion/outgoingBubbleMotion";
import {
  InlineTaskLinkAdapterProvider,
  routeInlineTaskLinkAdapter,
  staticInlineTaskLinkAdapter,
  type InlineTaskLinkAdapter,
} from "../thread/inline/MessageInlineElements";
import type {
  AttachmentUploadInput,
  ChatImagePreviewRef,
  ChatConversationRef,
  LocalFilePreview,
} from "../model/conversationChannel";

import {
  isInteractiveChatMessageTarget,
  resolveChatMessageArticleFromEventTarget,
  resolveChatMessageCopyText,
  resolveChatMessageText,
} from "./chatMessageContextMenu";
import {
  copyTextToClipboard,
  openUrlInExternalBrowser,
  resolveHttpLinkFromEventTarget,
} from "../thread/inline/linkActions";
import { hasRecommendationLinkPreview } from "../../recommendations/linkPreviewCache";
import {
  composeMessageWithQuotes,
  isTranscodedImageAttachment,
} from "../model/protocol";
import { useComposerMentionSources } from "../composer/useComposerMentionSources";
import { ChatSuggestionChips } from "../suggestions/ChatSuggestionChips";
import { useChatSuggestions } from "../suggestions/useChatSuggestions";
import { conversationMessageTurnKey } from "../model/visibleReplyPresentation";
import { useMarkLoadedTaskReviewSeen } from "../tasks/useMarkLoadedTaskReviewSeen";

export type ConversationViewActions = {
  acceptTaskReview?: (reviewVersion: number) => unknown;
  attachFiles?: (files: AttachmentUploadInput[]) => unknown;
  /** Replaces the Task's labels; absent when this host cannot edit labels. */
  setTaskLabels?: (labelIds: string[]) => unknown;
  discard: (clientRequestId: string) => unknown;
  pickAttachments?: () => unknown;
  previewLocalFile?: (
    previewRef: ChatImagePreviewRef,
    signal?: AbortSignal
  ) => Promise<LocalFilePreview | undefined>;
  refresh: () => unknown;
  removeAttachment: (id: string) => unknown;
  retry: (clientRequestId: string) => unknown;
  retryAttachment: (id: string) => unknown;
  send: (
    text: string,
    options?: {
      consumeDraft?: boolean;
      replyToMessageId?: string;
      skills?: { location: string }[];
    }
  ) => unknown;
  setDraft: (draft: string) => unknown;
  /** Async hosts that hide the channel result record send analytics at that boundary. */
  tracksSendAnalytics?: boolean;
  /** Whether the host re-encodes HEIC/HEIF before upload; browsers cannot. */
  transcodesImages?: boolean;
};

export type ConversationComposerPresentation = {
  disabled?: boolean | undefined;
  feedback?: ReactNode;
  placeholder?: string | undefined;
  submitDisabled?: boolean | undefined;
};

function currentAwaitingSendFailed(
  awaitingTurnKey: ConversationViewState["awaitingTurnKey"],
  pendingSends: ConversationViewState["pending"]
) {
  return Boolean(
    awaitingTurnKey &&
    pendingSends.some(
      (pending) =>
        pending.clientRequestId === awaitingTurnKey && pending.status === "failed"
    )
  );
}

export const ConversationView = memo(function ConversationView({
  actions,
  api,
  composerPresentation,
  conversationId: selectedConversationId,
  draftSource,
  groupId,
  inlineTaskLinkAdapter,
  leadingPanel,
  state,
  surfaceActive = true,
  trailingPanel,
  variant = "route",
  workspaceId,
  skills = [],
  onComposerContentHeightChange,
  onComposerNoticeHeightChange,
  onOpenConversationRef,
  onOpenInCommaBrowser,
  onOpenTasksFilter,
  outgoingMotion,
  outgoingPlaybackRate = 1,
}: {
  actions: ConversationViewActions;
  api?: CommaApiClient | undefined;
  composerPresentation?: ConversationComposerPresentation | undefined;
  /** Selected identity is available before the runtime loads its history. */
  conversationId?: string | undefined;
  /** The composer's draft; only the composer subscribes to it. */
  draftSource: ComposerDraftSource;
  groupId?: string | undefined;
  inlineTaskLinkAdapter?: InlineTaskLinkAdapter | undefined;
  leadingPanel?: ReactNode;
  onComposerContentHeightChange?: (height: number) => void;
  onComposerNoticeHeightChange?: (height: number) => void;
  onOpenConversationRef?: ((conversationRef: ChatConversationRef) => void) | undefined;
  /** Opens an http(s) URL in Comma's embedded browser sidebar. */
  onOpenInCommaBrowser?: ((url: string) => void) | undefined;
  /** Opens the Tasks page narrowed to a label or platform chip of the Task. */
  onOpenTasksFilter?: ((filter: TasksFilterLink) => void) | undefined;
  outgoingMotion?: import("@comma/ui").MessageSendMotionConfig | undefined;
  outgoingPlaybackRate?:
    | import("../motion/outgoingBubbleMotion").OutgoingBubblePlaybackRate
    | undefined;
  state: ConversationViewState;
  /** False while a retained surface is mounted but not visible to the reader. */
  surfaceActive?: boolean | undefined;
  skills?: CommaSkill[];
  trailingPanel?: ReactNode;
  variant?: "home" | "route" | "rail" | "side-chat";
  workspaceId?: string | undefined;
}) {
  const observeAnalytics = useMemo(
    () => createConversationAnalytics(variant),
    [variant]
  );
  useEffect(
    () => observeAnalytics(state, surfaceActive),
    [observeAnalytics, state, surfaceActive]
  );
  const sidebar = useOptionalChatSidebar();
  const router = useRouter({ warn: false });
  const routeRef = useRef<HTMLElement | null>(null);
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [browserOpen, setBrowserOpen] = useState(false);
  const browserPanelId = useId();
  const syncWarningToastId = `chat-sync-warning-${useId()}`;
  const heicToastId = `chat-heic-unsupported-${useId()}`;
  const resolvedInlineTaskLinkAdapter = useMemo<InlineTaskLinkAdapter>(() => {
    if (inlineTaskLinkAdapter) return inlineTaskLinkAdapter;
    if (variant === "side-chat") return staticInlineTaskLinkAdapter;
    return {
      ...routeInlineTaskLinkAdapter,
      previewBoundaryRef: routeRef,
      openTask: router
        ? (target) => {
            void router.navigate({
              params: {
                conversationId: target.conversationId,
                groupId: target.groupId,
                workspaceId: target.workspaceId,
              },
              to: "/tasks/$workspaceId/$groupId/$conversationId",
            });
          }
        : undefined,
      openInSidebar: onOpenConversationRef
        ? ({ conversationId, title }) =>
            onOpenConversationRef({ conversationId, kind: "agent_task", title })
        : undefined,
    };
  }, [inlineTaskLinkAdapter, onOpenConversationRef, router, variant]);
  const mountedRef = useRef(false);
  const previousAssistantMessageId = useRef<string | undefined>(undefined);
  const [replyAnnouncementId, setReplyAnnouncementId] = useState(0);
  const [acceptingTask, setAcceptingTask] = useState<{
    conversationId: string;
    reviewVersion: number;
  }>();
  const [acceptTaskError, setAcceptTaskError] = useState<{
    conversationId: string;
    reviewVersion: number;
  }>();
  const linkMenuUrlRef = useRef<string | null>(null);
  const linkMenuMessageTextRef = useRef<string>("");
  const copyMenuTextRef = useRef<string>("");
  const {
    isOpen: isLinkMenuOpen,
    pointerOffsets: linkMenuPointerOffsets,
    handleOpenChange: setLinkMenuOpen,
    openAtPointer: openLinkMenuAtPointer,
  } = useTextEditContextMenuState({
    isEnabled: true,
    preserveTextSelection: true,
  });
  const {
    isOpen: isCopyMenuOpen,
    pointerOffsets: copyMenuPointerOffsets,
    handleOpenChange: setCopyMenuOpen,
    openAtPointer: openCopyMenuAtPointer,
  } = useTextEditContextMenuState({
    isEnabled: true,
    preserveTextSelection: true,
  });
  const [outgoingLaunches, setOutgoingLaunches] = useState<ChatOutgoingLaunch[]>([]);
  // Home is the Comma assistant product surface, not a named conversation. Its
  // identity must not inherit a persisted, potentially unlocalized chat title.
  const homeSurfaceLabel = variant === "home" ? messages.home_region() : undefined;
  const terminalError = state.status === "error" && state.errorKind !== "network";
  const canonicalTask = useTaskSummary(
    api,
    groupId ?? state.conversation?.group_id ?? "",
    selectedConversationId ??
      (state.conversation?.kind === "agent_task" ? state.conversation.id : ""),
    // The selected channel already owns the detail request. A cold view reads
    // existing list/reference facts without starting another request lane.
    { fetch: state.conversation?.kind === "agent_task" }
  );
  // Summary facts describe the Task; they never establish loaded history,
  // review visibility, or permission to perform detail-dependent actions.
  const taskSummary =
    canonicalTask?.kind === "agent_task" && !terminalError ? canonicalTask : undefined;
  const presentation = state.conversation ?? taskSummary;
  const title =
    homeSurfaceLabel ?? (presentation?.title || messages.chat_default_title());
  const isTask = presentation?.kind === "agent_task";
  const taskStatus =
    taskSummary &&
    (taskSummary.updated_at ?? 0) >= (state.conversation?.updated_at ?? 0)
      ? taskSummary.status
      : state.conversation?.status;
  const isArchived = isTask && taskStatus === "archived";
  const taskSchedule = extractTaskSchedule(state.conversation?.schedule);
  const taskConversationId = state.conversation?.id;
  const taskReviewVersion = state.conversation?.review_version;
  const headerTaskStatus =
    isTask && taskStatus ? taskStatusBucket(taskStatus) : undefined;
  const taskStatusLabel = headerTaskStatus
    ? taskStatusBucketLabel(headerTaskStatus, locale)
    : undefined;
  const canAcceptTask =
    isTask &&
    !isArchived &&
    state.conversation?.status === "ready_for_review" &&
    typeof taskReviewVersion === "number" &&
    Number.isInteger(taskReviewVersion) &&
    taskReviewVersion > 0 &&
    !hasTaskSchedule(state.conversation?.schedule) &&
    actions.acceptTaskReview !== undefined;
  const isAcceptingTask =
    acceptingTask !== undefined &&
    acceptingTask.conversationId === taskConversationId &&
    acceptingTask.reviewVersion === taskReviewVersion;
  const threadGroupId = groupId ?? state.conversation?.group_id ?? "";
  const threadWorkspaceId = workspaceId ?? "";
  const latestAssistantMessageId = state.messages.findLast(
    (message) => message.role === "assistant"
  )?.messageId;

  useMarkLoadedTaskReviewSeen({
    conversationId: isTask ? taskConversationId : undefined,
    enabled: surfaceActive,
    groupId: isTask ? state.conversation?.group_id : undefined,
    renderedUpdatedAt: isTask ? state.conversation?.updated_at : undefined,
    workspaceId,
  });

  const showHomeStarterControls =
    variant === "home" &&
    state.messages.length === 0 &&
    state.pending.length === 0 &&
    state.assistantDraft === undefined &&
    state.activity === undefined &&
    state.participantStatus?.state !== "active" &&
    state.participantStatus?.state !== "error";

  const anyUploading = state.draftAttachments.some(
    (attachment) => attachment.status === "uploading"
  );
  const anyFailedAttachment = state.draftAttachments.some(
    (attachment) => attachment.status === "failed"
  );
  const hasCanonicalConversation = state.conversation !== undefined;
  const loadingHistory = !hasCanonicalConversation && state.status === "loading";
  const connecting = !presentation && loadingHistory;
  const unboundComposerDisabled =
    isArchived ||
    (!hasCanonicalConversation && composerPresentation?.disabled === true);
  const unboundSubmitDisabled =
    isArchived ||
    (!hasCanonicalConversation && composerPresentation?.submitDisabled === true);
  // Sync degradation is transient channel state, not conversation content, so
  // it surfaces as a persistent toast that dismisses itself once sync recovers.
  const syncWarning = state.syncWarning;
  const refresh = actions.refresh;
  useEffect(() => {
    if (!syncWarning) return undefined;
    toast.warning(
      syncWarning === "suspect-empty"
        ? messages.chat_suspect_empty()
        : messages.chat_stale(),
      {
        actions: [{ label: messages.chat_retry_sync(), onPress: refresh }],
        id: syncWarningToastId,
        testId: "chat-sync-warning",
      }
    );
    return () => {
      toast.dismiss(syncWarningToastId);
    };
  }, [messages, refresh, syncWarning, syncWarningToastId]);
  // A browser cannot decode HEIC/HEIF and the runtime cannot read it either,
  // so without a host transcoder the file is turned away with guidance
  // instead of parked in the draft as a failed row.
  const attachFiles = actions.attachFiles;
  const transcodesImages = actions.transcodesImages === true;
  const handleAttachFiles = useMemo(
    () =>
      attachFiles
        ? (files: AttachmentUploadInput[]) => {
            const admitted = transcodesImages
              ? files
              : files.filter((file) => !isTranscodedImageAttachment(file.name));
            if (admitted.length !== files.length) {
              toast.error(messages.chat_heic_unsupported_browser(), {
                id: heicToastId,
                testId: "chat-heic-unsupported",
              });
            }
            if (admitted.length > 0) attachFiles(admitted);
          }
        : undefined,
    [attachFiles, heicToastId, messages, transcodesImages]
  );
  const { open: openImageMenu, menu: imageMenu } =
    useMediaContextMenu(handleAttachFiles);
  // handleSend only needs the state at click time. Reading it through a ref
  // keeps the callback identity stable across emits, which keeps the memoized
  // Composer from re-rendering on every stream chunk.
  const stateRef = useRef(state);
  const outgoingMotionRef = useRef(outgoingMotion);
  outgoingMotionRef.current = outgoingMotion;
  const outgoingPlaybackRateRef = useRef(outgoingPlaybackRate);
  outgoingPlaybackRateRef.current = outgoingPlaybackRate;
  useEffect(() => {
    stateRef.current = state;
  }, [state]);
  const launchOutgoing = useCallback(
    (
      text: string,
      options: {
        consumeDraft?: boolean;
        onAdmissionRejected?: () => void;
        skills: { location: string }[];
        sourceFrame?: ChatOutgoingLaunch["sourceFrame"];
      }
    ) => {
      const launchId = nextChatOutgoingLaunchId();
      const source = options.sourceFrame ?? measureChatComposer(routeRef.current);
      const currentState = stateRef.current;
      const launch: ChatOutgoingLaunch = {
        expiresAt: Date.now() + 4_000 / outgoingPlaybackRateRef.current,
        existingTurnKeys: new Set(
          currentState.messages
            .filter((message) => message.role === "user")
            .map(conversationMessageTurnKey)
        ),
        id: launchId,
        sourceFrame: source,
        motionConfig: outgoingMotionRef.current,
        playbackRate: outgoingPlaybackRateRef.current,
        startedFromEmpty:
          variant === "side-chat" &&
          currentState.messages.length === 0 &&
          currentState.assistantDraft === undefined,
        text,
      };
      if (text.trim()) {
        setOutgoingLaunches((current) => [...current, launch].slice(-4));
      }

      let result: unknown;
      const finishAnalytics = actions.tracksSendAnalytics
        ? undefined
        : beginCommaMessageSend(variant);
      try {
        result = actions.send(text, {
          skills: options.skills,
          ...(options.consumeDraft !== false && uiReplyRef.current
            ? { replyToMessageId: uiReplyRef.current }
            : {}),
          ...(options.consumeDraft === false ? { consumeDraft: false } : {}),
        });
      } catch (error) {
        finishAnalytics?.("failed", "dispatch");
        setOutgoingLaunches((current) =>
          current.filter((candidate) => candidate.id !== launchId)
        );
        throw error;
      }
      const accepted = acceptedSendPromise(result);
      const completion =
        accepted ??
        (result && typeof (result as PromiseLike<unknown>).then === "function"
          ? Promise.resolve(result)
          : undefined);
      if (completion && finishAnalytics) {
        const boundary = accepted ? "runtime" : "server";
        void completion.then(
          () => finishAnalytics("accepted", boundary),
          () => finishAnalytics("failed", boundary)
        );
      }
      if (accepted) {
        void accepted.catch(() => {
          setOutgoingLaunches((current) =>
            current.filter((candidate) => candidate.id !== launchId)
          );
          options.onAdmissionRejected?.();
        });
      }
      return result;
    },
    [actions, variant]
  );

  const conversationId = state.conversation?.id;
  const conversationIdRef = useRef(conversationId);
  conversationIdRef.current = conversationId;

  // Reuse settled-turn generation on full chat surfaces.
  const { clear: clearSuggestions, items: suggestionItems } = useChatSuggestions({
    api,
    conversationId,
    enabled: !isArchived && (variant === "route" || variant === "home"),
    groupId: threadGroupId || undefined,
    locale,
    state,
  });

  // Tasks the agent created in this conversation dock above the composer, on
  // the full chat surfaces only — the rail and side chat are too narrow for a
  // second panel.
  const showTaskDock = variant === "route" || variant === "home";
  const revealTurnHandleRef = useRef<
    ((turnKey: string, highlightMessageId?: string) => void) | null
  >(null);

  // Tasks, routines, and plugins for the composer's "@" panel. Loaded once
  // per group/workspace with a short TTL; a Task chat never lists itself.
  const mentionSources = useComposerMentionSources({
    api,
    excludeConversationId: conversationId,
    groupId: threadGroupId || undefined,
    workspaceId: threadWorkspaceId || undefined,
  });

  // Quoted passages are renderer-only draft state, folded into the message
  // text on send. Keeping them out of the channel avoids widening the
  // Main-owned draft epoch for something with no intake or upload lifecycle.
  const uiReplyRef = useRef<string | undefined>(undefined);
  // A widget reply targets its message until the reader empties the draft.
  // Watched without rendering: the view never re-renders for a keystroke.
  useEffect(() => {
    const releaseReplyTarget = () => {
      if (!draftSource.getSnapshot().trim()) uiReplyRef.current = undefined;
    };
    releaseReplyTarget();
    return draftSource.subscribe(releaseReplyTarget);
  }, [draftSource]);
  // Reads the draft when a widget replies, so the context value stays stable
  // and a keystroke does not re-render every widget in the transcript.
  const { setDraft } = actions;
  const replyFromDynamicUi = useCallback(
    (text: string, messageId: string) => {
      uiReplyRef.current = messageId;
      const draft = draftSource.getSnapshot();
      setDraft(draft ? `${draft}\n\n${text}` : text);
    },
    [draftSource, setDraft]
  );
  const [draftQuotes, setDraftQuotes] = useState<ChatDraftQuote[]>([]);
  const draftQuotesRef = useRef(draftQuotes);
  useEffect(() => {
    draftQuotesRef.current = draftQuotes;
  }, [draftQuotes]);
  // A quote belongs to the conversation it was taken from; switching threads
  // must not carry it along. Bail on an empty set so mounting, and binding a
  // freshly created conversation, cost no render.
  useEffect(() => {
    uiReplyRef.current = undefined;
    setDraftQuotes((current) => (current.length === 0 ? current : []));
  }, [conversationId]);

  // Staging a quote is a reading gesture, so it stays available even while
  // the composer is momentarily blocked on a send in flight.
  const { clear: clearSelectionQuote, selection: selectionQuote } =
    useChatSelectionQuote(routeRef);

  const removeDraftQuote = useCallback((id: string) => {
    setDraftQuotes((current) => current.filter((quote) => quote.id !== id));
  }, []);

  const quoteSelection = useCallback(() => {
    const text = selectionQuote?.text.trim();
    if (!text) return;
    setDraftQuotes((current) => [...current, createChatDraftQuote(text)]);
    // The passage is staged now; leaving it highlighted would keep the bar up
    // and invite a second, duplicate quote of the same text.
    window.getSelection()?.removeAllRanges();
    clearSelectionQuote();
  }, [clearSelectionQuote, selectionQuote]);

  useEffect(() => {
    if (!selectionQuote) return undefined;

    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "l" && event.key !== "L") return;
      if (!(event.metaKey || event.ctrlKey) || event.altKey || event.shiftKey) return;
      event.preventDefault();
      quoteSelection();
    };

    window.addEventListener("keydown", handleKeyDown, true);
    return () => window.removeEventListener("keydown", handleKeyDown, true);
  }, [quoteSelection, selectionQuote]);

  const selectionActions = useMemo<SelectionActionBarAction[]>(
    () => [
      {
        id: "add-to-chat",
        label: messages.chat_add_to_chat(),
        onPress: quoteSelection,
        shortcut: ["\u2318", "L"],
      },
    ],
    [messages, quoteSelection]
  );

  const handleSend = useCallback(
    (text: string, options: { skills: { location: string }[] }) => {
      const submittedConversationId = conversationIdRef.current;
      const submittedQuotes = draftQuotesRef.current;
      const submittedQuoteIds = new Set(submittedQuotes.map((quote) => quote.id));
      const restoreSubmittedQuotes = () => {
        if (
          submittedQuotes.length === 0 ||
          conversationIdRef.current !== submittedConversationId
        ) {
          return;
        }
        setDraftQuotes((current) => {
          const currentIds = new Set(current.map((quote) => quote.id));
          const missing = submittedQuotes.filter((quote) => !currentIds.has(quote.id));
          return missing.length === 0 ? current : [...missing, ...current];
        });
      };
      // Folded in before the handoff so a send that is nothing but a quoted
      // passage still carries text.
      const quoted = composeMessageWithQuotes(
        text,
        submittedQuotes.map((quote) => quote.text)
      );
      if (submittedQuotes.length > 0) {
        setDraftQuotes((current) =>
          current.filter((quote) => !submittedQuoteIds.has(quote.id))
        );
      }

      let result: unknown;
      try {
        result = launchOutgoing(quoted, {
          onAdmissionRejected: restoreSubmittedQuotes,
          skills: options.skills,
        });
      } catch (error) {
        restoreSubmittedQuotes();
        throw error;
      }
      return result;
    },
    [launchOutgoing]
  );

  const handleSelectSuggestion = useCallback(
    (suggestion: CommaChatSuggestion) => {
      clearSuggestions();
      return launchOutgoing(suggestion.prompt, {
        consumeDraft: false,
        skills: [],
      });
    },
    [clearSuggestions, launchOutgoing]
  );

  const handleAcceptTask = useCallback(async () => {
    if (!canAcceptTask || !actions.acceptTaskReview || !taskConversationId) return;
    const request = {
      conversationId: taskConversationId,
      reviewVersion: taskReviewVersion,
    };
    setAcceptingTask(request);
    setAcceptTaskError(undefined);
    try {
      await actions.acceptTaskReview(taskReviewVersion);
    } catch {
      setAcceptTaskError(request);
      setAcceptingTask((current) =>
        current?.conversationId === request.conversationId &&
        current.reviewVersion === request.reviewVersion
          ? undefined
          : current
      );
    }
  }, [actions, canAcceptTask, taskConversationId, taskReviewVersion]);

  const finishOutgoingLaunch = useCallback((launchId: number) => {
    setOutgoingLaunches((current) =>
      current.filter((candidate) => candidate.id !== launchId)
    );
  }, []);

  // Hover previews for external message links. Keyed on [api, workspaceId]
  // only: every MarkdownStream link node subscribes to this context, so a new
  // decorator identity per render would re-render every link on every emit
  // (PR #857 identity contract) — memoize hard.
  const linkDecorator = useMemo<MarkdownStreamLinkDecorator | undefined>(() => {
    if (!api || !threadWorkspaceId) return undefined;
    return ({ anchor, href }) =>
      hasRecommendationLinkPreview(href) ? (
        <ChatLinkHoverCard
          anchor={anchor}
          api={api}
          href={href}
          workspaceId={threadWorkspaceId}
        />
      ) : (
        anchor
      );
  }, [api, threadWorkspaceId]);

  const handleClickCapture = useCallback(
    (event: ReactMouseEvent<HTMLElement>) => {
      if (!onOpenInCommaBrowser) return;
      const url = resolveHttpLinkFromEventTarget(event.target, event.currentTarget);
      if (!url) return;
      try {
        if (new URL(url).origin === window.location.origin) return;
      } catch {
        return;
      }
      event.preventDefault();
      onOpenInCommaBrowser(url);
    },
    [onOpenInCommaBrowser]
  );

  const handleContextMenuCapture = useCallback(
    (event: ReactMouseEvent<HTMLElement>) => {
      if (variant !== "side-chat" && event.target instanceof Element) {
        if (event.target.closest('[data-media-context-menu="true"]')) return;
        const media = event.target.closest("img, video");
        if (media instanceof HTMLImageElement || media instanceof HTMLVideoElement) {
          openImageMenu(event, mediaElementSource(media));
          return;
        }
      }
      const article = resolveChatMessageArticleFromEventTarget(
        event.target,
        event.currentTarget
      );
      if (!article) return;

      const url = resolveHttpLinkFromEventTarget(event.target, article);
      if (url) {
        try {
          if (new URL(url).origin === window.location.origin) return;
        } catch {
          return;
        }
        event.preventDefault();
        linkMenuUrlRef.current = url;
        linkMenuMessageTextRef.current = resolveChatMessageText(
          article,
          state.messages,
          state.assistantDraft
        );
        setCopyMenuOpen(false);
        openLinkMenuAtPointer(
          event.currentTarget,
          event.clientX,
          event.clientY,
          event.target instanceof Element ? event.target : event.currentTarget
        );
        return;
      }

      if (isInteractiveChatMessageTarget(event.target, article)) return;

      const copyText = resolveChatMessageCopyText(
        article,
        state.messages,
        state.assistantDraft
      );
      if (!copyText) return;

      event.preventDefault();
      copyMenuTextRef.current = copyText;
      setLinkMenuOpen(false);
      openCopyMenuAtPointer(
        event.currentTarget,
        event.clientX,
        event.clientY,
        event.target instanceof Element ? event.target : event.currentTarget
      );
    },
    [
      openImageMenu,
      variant,
      openCopyMenuAtPointer,
      openLinkMenuAtPointer,
      setCopyMenuOpen,
      setLinkMenuOpen,
      state.assistantDraft,
      state.messages,
    ]
  );

  // Widget frames keep their events, so a right-click on a widget link arrives
  // as a request with viewport coordinates instead of a contextmenu event.
  const handleDynamicUiLinkMenu = useCallback(
    (url: string, clientX: number, clientY: number, frame: HTMLIFrameElement) => {
      const route = routeRef.current;
      if (!route) return;
      const article = resolveChatMessageArticleFromEventTarget(frame, route);
      if (!article) return;
      linkMenuUrlRef.current = url;
      linkMenuMessageTextRef.current = resolveChatMessageText(
        article,
        state.messages,
        state.assistantDraft
      );
      setCopyMenuOpen(false);
      openLinkMenuAtPointer(route, clientX, clientY, frame);
    },
    [openLinkMenuAtPointer, setCopyMenuOpen, state.assistantDraft, state.messages]
  );

  const handleLinkMenuAction = useCallback(
    (action: LinkContextMenuAction) => {
      const url = linkMenuUrlRef.current;
      if (action === "copy-message") {
        const messageText = linkMenuMessageTextRef.current;
        if (messageText) void copyTextToClipboard(messageText);
        return;
      }
      if (!url) return;

      if (action === "open-external-browser") {
        void openUrlInExternalBrowser(url);
        return;
      }
      if (action === "open-in-comma") {
        onOpenInCommaBrowser?.(url);
        return;
      }
      void copyTextToClipboard(url);
    },
    [onOpenInCommaBrowser]
  );

  const handleCopyMenuAction = useCallback((action: CopyContextMenuAction) => {
    if (action !== "copy") return;
    const text = copyMenuTextRef.current;
    if (text) void copyTextToClipboard(text);
  }, []);

  const handleLinkMenuOpenChange = useCallback(
    (open: boolean) => {
      const changed = setLinkMenuOpen(open);
      if (!open && changed) {
        linkMenuUrlRef.current = null;
        linkMenuMessageTextRef.current = "";
      }
    },
    [setLinkMenuOpen]
  );

  const handleCopyMenuOpenChange = useCallback(
    (open: boolean) => {
      const changed = setCopyMenuOpen(open);
      if (!open && changed) copyMenuTextRef.current = "";
    },
    [setCopyMenuOpen]
  );

  const actionsMemo = useMemo(
    () => ({
      discard: actions.discard,
      retry: actions.retry,
    }),
    [actions.discard, actions.retry]
  );

  // Slot elements handed to the memoized ConversationThread must keep their
  // identity across unrelated emits, or the memo boundary never holds.
  const showAcceptTaskError =
    acceptTaskError !== undefined &&
    acceptTaskError.conversationId === taskConversationId &&
    acceptTaskError.reviewVersion === taskReviewVersion;
  // After an accept the card leaves the way the panel's Done does: it stays
  // for its exit instead of vanishing. Keyed by Task, so switching Tasks
  // never shows the last one's card on its way out.
  const reviewLeavingId = useLeaving(
    canAcceptTask ? taskConversationId : undefined,
    stateSwapExitMs
  );
  const reviewLeaving =
    !canAcceptTask &&
    reviewLeavingId !== undefined &&
    reviewLeavingId === taskConversationId;
  const taskReviewAction = useMemo(
    () =>
      canAcceptTask || reviewLeaving ? (
        <div
          className="comma-task-review-action comma-status-swap-exit"
          data-leaving={reviewLeaving ? "true" : undefined}
          data-testid="task-review-action"
        >
          <div className="comma-task-review-copy">
            <span className="comma-task-review-label">{messages.chat_task()}</span>
            <span className="comma-task-review-title">
              {messages.tasks_review_prompt()}
            </span>
          </div>
          <Button
            hierarchy="secondary-gray"
            isDisabled={isAcceptingTask || reviewLeaving}
            onPress={handleAcceptTask}
            size="sm"
          >
            {isAcceptingTask
              ? messages.tasks_accepting_result()
              : messages.tasks_accept_result()}
          </Button>
          {showAcceptTaskError ? (
            <p className="comma-task-review-feedback" role="alert">
              {messages.tasks_accept_result_failed()}
            </p>
          ) : null}
        </div>
      ) : null,
    [
      canAcceptTask,
      handleAcceptTask,
      isAcceptingTask,
      messages,
      reviewLeaving,
      showAcceptTaskError,
    ]
  );
  // The details panel lives on the Task route and in the chat sidebar (rail),
  // both on the same responsive rule: a second column while the host is wide,
  // a popover behind a trigger once it folds. Home and the side chat keep the
  // header status badge instead.
  const showTaskPanel =
    isTask && (variant === "route" || variant === "rail") && presentation !== undefined;
  const taskPanelFold = useTaskPanelFold(routeRef, showTaskPanel);
  const taskPanelProps =
    showTaskPanel && presentation
      ? {
          api,
          canDone: canAcceptTask,
          conversation: {
            ...presentation,
            status: taskStatus ?? presentation.status,
          },
          doneState: (isAcceptingTask
            ? "pending"
            : showAcceptTaskError
              ? "failed"
              : "idle") as TaskDetailsDoneState,
          groupId: threadGroupId,
          worker: state.boundWorker,
          onDone: handleAcceptTask,
          onOpenTasksFilter,
          onSetLabels: hasCanonicalConversation ? actions.setTaskLabels : undefined,
        }
      : undefined;

  const responseFeedback = useCallback(
    ({ hasResponse }: { hasResponse: boolean }) => (
      <ParticipantStatusSlot
        hasResponse={hasResponse}
        activity={state.activity}
        toolPresentation={variant === "side-chat" ? "bubble" : "inline"}
        reserveSpace={false}
        streaming={state.assistantDraft?.status === "streaming"}
        optimisticThinking={
          state.awaitingReply &&
          state.locallyAwaitingReply === true &&
          !state.awaitingTimedOut &&
          state.assistantDraft === undefined &&
          !currentAwaitingSendFailed(state.awaitingTurnKey, state.pending)
        }
        participantStatus={state.participantStatus}
        participantStatuses={state.participantStatuses}
        replyTimedOut={state.awaitingReply && state.awaitingTimedOut}
      />
    ),
    [
      state.activity,
      state.assistantDraft,
      state.awaitingReply,
      state.awaitingTimedOut,
      state.awaitingTurnKey,
      state.locallyAwaitingReply,
      state.participantStatus,
      state.participantStatuses,
      state.pending,
      variant,
    ]
  );
  // The newest reply's identity: a Router reply may have filed label
  // proposals, which the chat then offers for confirmation in place.
  const latestReplyKey = useMemo(() => {
    for (let index = state.messages.length - 1; index >= 0; index -= 1) {
      const message = state.messages[index];
      if (message?.role === "assistant") return message.messageId;
    }
    return undefined;
  }, [state.messages]);
  // The Group's shared label catalog. The card reads it too, and every
  // proposal mutation hands the fresh catalog back through `replace`.
  const { catalog: labelCatalog } = useTaskLabelsCatalog(api, threadGroupId, !isTask);
  // A proposal records when it was filed, not the reply that filed it. Each card
  // belongs to the reply nearest that time: it holds that reply's place in the
  // transcript, so a later round neither drags an older card along nor hides the
  // new decision at the bottom.
  const labelProposalsTails = useMemo(() => {
    if (isTask || !api || !threadGroupId || !conversationId) return undefined;
    const groups = groupLabelProposalsByAnchor(
      conversationLabelProposals(labelCatalog, conversationId),
      state.messages
    );
    if (groups.length === 0) {
      // The card is what notices proposals a new reply files. It renders
      // nothing until there is one, so the newest turn is where it waits.
      return [
        {
          key: "proposals",
          messageId: undefined,
          node: (
            <ChatLabelProposals
              api={api}
              conversationId={conversationId}
              groupId={threadGroupId}
              replyKey={latestReplyKey}
              workspaceId={threadWorkspaceId}
            />
          ),
        },
      ];
    }
    return groups.map((group, index) => {
      const newest = index === groups.length - 1;
      return {
        key: group.messageId ?? "tail",
        messageId: group.messageId,
        node: (
          <ChatLabelProposals
            api={api}
            conversationId={conversationId}
            groupId={threadGroupId}
            proposals={group.proposals}
            replyKey={newest ? latestReplyKey : undefined}
            revealOnAppear={newest}
            workspaceId={threadWorkspaceId}
          />
        ),
      };
    });
  }, [
    api,
    conversationId,
    isTask,
    labelCatalog,
    latestReplyKey,
    state.messages,
    threadGroupId,
    threadWorkspaceId,
  ]);
  const transcriptTail = useMemo(
    () => (
      <>
        {showTaskPanel ? null : taskReviewAction}
        {!isArchived && suggestionItems.length > 0 ? (
          <ChatSuggestionChips
            items={suggestionItems}
            onSelect={handleSelectSuggestion}
          />
        ) : null}
        {isTask ? responseFeedback({ hasResponse: false }) : null}
      </>
    ),
    [
      isTask,
      responseFeedback,
      showTaskPanel,
      taskReviewAction,
      isArchived,
      suggestionItems,
      handleSelectSuggestion,
    ]
  );

  useEffect(() => {
    if (
      acceptingTask !== undefined &&
      acceptingTask.conversationId === taskConversationId &&
      (acceptingTask.reviewVersion !== taskReviewVersion || !canAcceptTask)
    ) {
      setAcceptingTask(undefined);
    }
  }, [acceptingTask, canAcceptTask, taskConversationId, taskReviewVersion]);

  useEffect(() => {
    if (!mountedRef.current) {
      mountedRef.current = true;
      previousAssistantMessageId.current = latestAssistantMessageId;
      return;
    }

    if (
      latestAssistantMessageId &&
      latestAssistantMessageId !== previousAssistantMessageId.current
    ) {
      setReplyAnnouncementId((current) => current + 1);
    }
    previousAssistantMessageId.current = latestAssistantMessageId;
  }, [latestAssistantMessageId]);

  useEffect(() => {
    const nextExpiry = Math.min(...outgoingLaunches.map((launch) => launch.expiresAt));
    if (!Number.isFinite(nextExpiry)) return;

    const timer = window.setTimeout(
      () => {
        const now = Date.now();
        setOutgoingLaunches((current) =>
          current.filter((launch) => launch.expiresAt > now)
        );
      },
      Math.max(0, nextExpiry - Date.now())
    );
    return () => window.clearTimeout(timer);
  }, [outgoingLaunches]);

  const historyParticipants =
    state.participantStatuses ??
    (state.participantStatus ? [state.participantStatus] : []);
  const conversationContent =
    loadingHistory && variant !== "home" ? (
      <output
        aria-label={
          isTask ? messages.search_palette_loading_history() : messages.common_loading()
        }
        aria-busy="true"
        className="flex flex-1 items-center justify-center p-xl"
      >
        <span className="size-8 text-disabled">
          <CommaLogoAnimation style={{ color: "inherit" }} aria-hidden="true" />
        </span>
      </output>
    ) : !hasCanonicalConversation && terminalError && variant !== "home" ? (
      <ChatBanner errorKind={state.errorKind} />
    ) : (
      <>
        <ChatBanner errorKind={state.errorKind} />
        {sidebar && workspaceId && threadGroupId && historyParticipants.length > 0 ? (
          <ConversationParticipants
            groupId={threadGroupId}
            participants={historyParticipants}
            onOpen={(participant) =>
              sidebar.openSessionHistory(
                sidebar.activeHost ?? {
                  workspaceId,
                  groupId: threadGroupId,
                  conversationId: participant.conversationId,
                },
                { groupId: threadGroupId, participant }
              )
            }
          />
        ) : null}
        {isArchived ? (
          <output className="block p-md text-sm text-secondary">
            {messages.tasks_archived_readonly()}{" "}
            <a href="/#/settings?category=archived-tasks">
              {messages.tasks_archived_settings()}
            </a>
          </output>
        ) : null}
        <MarkdownStreamLinkDecoratorContext.Provider value={linkDecorator}>
          <InlineTaskLinkAdapterProvider adapter={resolvedInlineTaskLinkAdapter}>
            <DynamicUiLinkContext.Provider value={onOpenInCommaBrowser}>
              <DynamicUiLinkMenuContext.Provider value={handleDynamicUiLinkMenu}>
                <DynamicUiDraftContext.Provider value={replyFromDynamicUi}>
                  <ConversationThread
                    api={api}
                    assistantDraft={state.assistantDraft}
                    assistantResponseSlotId={state.conversation?.id ?? "conversation"}
                    conversationId={state.conversation?.id}
                    conversationKind={isTask ? "agent_task" : "user_chat"}
                    defaultAssistantActorRole={isTask ? undefined : "router"}
                    groupId={threadGroupId}
                    afterMessages={transcriptTail}
                    anchoredTails={labelProposalsTails}
                    responseFeedback={isTask ? undefined : responseFeedback}
                    messages={state.messages}
                    onOpenConversationRef={onOpenConversationRef}
                    onOutgoingAnimationComplete={finishOutgoingLaunch}
                    onPreviewLocalFile={actions.previewLocalFile}
                    onDiscard={actionsMemo.discard}
                    onRetry={actionsMemo.retry}
                    outgoingLaunches={outgoingLaunches}
                    revealTurnHandle={revealTurnHandleRef}
                    variant={variant === "side-chat" ? "side-chat" : "default"}
                    workspaceId={threadWorkspaceId}
                  />
                </DynamicUiDraftContext.Provider>
              </DynamicUiLinkMenuContext.Provider>
            </DynamicUiLinkContext.Provider>
          </InlineTaskLinkAdapterProvider>
        </MarkdownStreamLinkDecoratorContext.Provider>
        <div className="comma-chat-composer-zone">
          <div
            className="comma-chat-composer-frame"
            {...(variant === "home"
              ? { "aria-label": messages.shell_ai_input(), role: "group" }
              : {})}
          >
            {showTaskDock ? (
              <ChatTaskDock
                api={api}
                groupId={threadGroupId}
                messages={state.messages}
                revealTurnHandle={revealTurnHandleRef}
                taskLinkAdapter={resolvedInlineTaskLinkAdapter}
                workspaceId={threadWorkspaceId}
              />
            ) : null}
            <CreditWarningNotice
              api={api}
              workspaceId={workspaceId}
              active={surfaceActive && !isArchived}
              onHeightChange={onComposerNoticeHeightChange}
            />
            <Composer
              controlCommandsEnabled={state.conversation?.kind === "user_chat"}
              disabled={unboundComposerDisabled}
              draftSource={draftSource}
              suggestion={isArchived ? undefined : suggestionItems[0]?.prompt}
              onAcceptSuggestion={clearSuggestions}
              draftAttachments={state.draftAttachments}
              draftQuotes={draftQuotes}
              {...(handleAttachFiles ? { onAttachFiles: handleAttachFiles } : {})}
              {...(actions.pickAttachments
                ? { onPickAttachments: actions.pickAttachments }
                : {})}
              {...(actions.previewLocalFile
                ? { onPreviewLocalFile: actions.previewLocalFile }
                : {})}
              mentionSources={mentionSources}
              onDraftChange={actions.setDraft}
              onRemoveAttachment={actions.removeAttachment}
              onRemoveQuote={removeDraftQuote}
              onRetryAttachment={actions.retryAttachment}
              onSend={handleSend}
              {...(onComposerContentHeightChange
                ? { onContentHeightChange: onComposerContentHeightChange }
                : {})}
              {...(variant === "side-chat"
                ? { placeholder: messages.chat_side_composer_placeholder() }
                : {})}
              {...(showHomeStarterControls
                ? {
                    placeholder: messages.home_prompt_placeholder(),
                    sendLabel: messages.common_send(),
                    showVoiceButton: true,
                  }
                : {})}
              {...(composerPresentation?.placeholder
                ? { placeholder: composerPresentation.placeholder }
                : {})}
              size="small"
              skills={skills}
              submitDisabled={
                unboundComposerDisabled ||
                unboundSubmitDisabled ||
                anyUploading ||
                anyFailedAttachment
              }
              variant={variant === "side-chat" ? "side-chat" : "default"}
            />
            {composerPresentation?.feedback}
          </div>
        </div>
        <div className="app-sr-only" aria-live="polite">
          {state.pending.some((pending) => pending.status === "failed") ? (
            messages.chat_failed()
          ) : replyAnnouncementId > 0 ? (
            <span key={replyAnnouncementId}>{messages.chat_new_reply()}</span>
          ) : (
            ""
          )}
        </div>
      </>
    );

  const browserParticipantId = isTask
    ? state.boundWorker?.participantId
    : state.participantStatus?.conversationId === conversationId
      ? state.participantStatus?.participantId
      : undefined;
  const { browser, refresh: refreshBrowser } = useSessionBrowser(
    variant === "side-chat" || !surfaceActive ? undefined : api,
    workspaceId,
    conversationId,
    browserParticipantId
  );
  useEffect(() => {
    setBrowserOpen(false);
  }, [workspaceId, conversationId, browserParticipantId, browser?.session_id]);

  const browserTrigger = browser ? (
    <AgentBrowserTrigger
      open={browserOpen}
      panelId={browserPanelId}
      onToggle={() => setBrowserOpen((open) => !open)}
    />
  ) : null;
  const browserPanel =
    browserOpen && browser && api && workspaceId ? (
      <AgentBrowserPanel
        key={JSON.stringify([workspaceId, browser.agent_id, browser.session_id])}
        binding={browser}
        onRefresh={refreshBrowser}
        id={browserPanelId}
        api={api}
        workspaceId={workspaceId}
      />
    ) : null;

  return (
    <MediaMenuContext.Provider
      value={variant === "side-chat" ? undefined : openImageMenu}
    >
      <section
        aria-label={homeSurfaceLabel ?? messages.chat_region()}
        className="comma-chat-route flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
        data-variant={variant}
        onClickCapture={handleClickCapture}
        onContextMenuCapture={handleContextMenuCapture}
        ref={routeRef}
      >
        {variant === "side-chat" || variant === "home" ? null : (
          <ContentHeader aria-busy={connecting} className="comma-chat-header">
            <div
              className="flex min-w-0 flex-1 items-center gap-sm"
              data-task-header={isTask ? "true" : undefined}
            >
              {connecting ? (
                <span
                  aria-hidden="true"
                  className="h-4 w-32 max-w-full rounded-md bg-quaternary motion-safe:animate-pulse"
                  data-testid="chat-title-loading"
                />
              ) : (
                <h1 className="comma-chat-title">{title}</h1>
              )}
              {isTask &&
              !connecting &&
              variant === "route" &&
              api &&
              groupId &&
              selectedConversationId ? (
                <TaskShareButton
                  api={api}
                  conversationId={selectedConversationId}
                  groupId={groupId}
                  status={taskStatus}
                  title={title}
                  updatedAt={presentation?.updated_at}
                  workspaceId={threadWorkspaceId}
                />
              ) : null}
              {isTask && !showTaskPanel ? (
                <div
                  className="comma-chat-task-meta flex shrink-0 items-center"
                  data-testid="task-conversation-meta"
                >
                  {headerTaskStatus && taskStatusLabel ? (
                    <Badge
                      className="shrink-0 whitespace-nowrap border-0 bg-quaternary py-xxs pl-xs pr-md text-primary"
                      data-testid="task-conversation-status"
                      size="sm"
                    >
                      <span
                        aria-hidden
                        className="comma-icon-slot size-4 shrink-0 [&_svg]:size-4"
                      >
                        {taskStatusIcon(headerTaskStatus)}
                      </span>
                      {taskStatusLabel}
                    </Badge>
                  ) : null}
                </div>
              ) : null}
              {isTask && taskSchedule ? (
                <span className="min-w-0 truncate text-xs text-tertiary">
                  · {messages.chat_schedule({ schedule: taskSchedule })}
                </span>
              ) : null}
            </div>
            {browserTrigger}
            {variant !== "rail" && taskPanelProps ? (
              <TaskPanelFoldedTrigger fold={taskPanelFold} panel={taskPanelProps} />
            ) : null}
          </ContentHeader>
        )}

        {variant !== "home" ? browserPanel : null}

        {variant === "home" ? (
          <HomeLayout>
            {leadingPanel}
            <div className="comma-home-chat">
              {browserTrigger ? (
                <div className="flex h-11 shrink-0 items-center justify-end px-xl">
                  {browserTrigger}
                </div>
              ) : null}
              {browserPanel}
              {conversationContent}
            </div>
            {trailingPanel}
          </HomeLayout>
        ) : taskPanelProps ? (
          <TaskPanelBody
            floatingTrigger={variant === "rail"}
            fold={taskPanelFold}
            panel={taskPanelProps}
          >
            {conversationContent}
          </TaskPanelBody>
        ) : (
          conversationContent
        )}
        <LinkContextMenu
          disabledActions={{ openInComma: !onOpenInCommaBrowser }}
          isOpen={isLinkMenuOpen}
          labels={{
            ariaLabel: messages.chat_link_menu(),
            copyLink: messages.chat_copy_link(),
            copyMessage: messages.chat_copy_message(),
            openInComma: messages.chat_open_in_comma(),
            openInExternalBrowser: messages.chat_open_in_external_browser(),
          }}
          onAction={handleLinkMenuAction}
          onOpenChange={handleLinkMenuOpenChange}
          pointerOffsets={linkMenuPointerOffsets}
          triggerRef={routeRef}
        />
        <SelectionActionBar
          actions={selectionActions}
          anchor={selectionQuote?.anchor ?? null}
          ariaLabel={messages.chat_selection_menu()}
          direction={selectionQuote?.direction ?? "none"}
        />
        <CopyContextMenu
          isOpen={isCopyMenuOpen}
          labels={{
            ariaLabel: messages.chat_text_menu(),
            copy: messages.common_copy(),
          }}
          onAction={handleCopyMenuAction}
          onOpenChange={handleCopyMenuOpenChange}
          pointerOffsets={copyMenuPointerOffsets}
          triggerRef={routeRef}
        />
        {variant !== "side-chat" ? imageMenu : null}
      </section>
    </MediaMenuContext.Provider>
  );
});

function extractTaskSchedule(schedule: unknown) {
  if (!schedule || typeof schedule !== "object" || Array.isArray(schedule)) {
    return undefined;
  }

  const value = schedule as Record<string, unknown>;
  const label = value.next_run_at ?? value.run_at ?? value.cron ?? value.expression;
  return typeof label === "string" && label ? label : undefined;
}

function hasTaskSchedule(schedule: unknown) {
  if (!schedule || typeof schedule !== "object" || Array.isArray(schedule)) {
    return false;
  }
  const scheduleId = (schedule as Record<string, unknown>).schedule_id;
  return typeof scheduleId === "string" && scheduleId.trim() !== "";
}

let chatOutgoingLaunchSequence = 0;

function nextChatOutgoingLaunchId() {
  chatOutgoingLaunchSequence += 1;
  return chatOutgoingLaunchSequence;
}

function measureChatComposer(root: HTMLElement | null) {
  const composer = root?.querySelector<HTMLElement>(".comma-chat-composer");
  return measureOutgoingBubbleSource(composer);
}
