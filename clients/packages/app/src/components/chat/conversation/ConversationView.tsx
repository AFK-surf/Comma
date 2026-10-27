import type { QuestionCardAnswer } from "../channel/ChatChannel";
import {
  QuestionCardActionsContext,
  QuestionCardAttachmentsContext,
  type QuestionCardActions,
} from "../question/QuestionCardContext";
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
import { useOptionalChatSidebarActions } from "../../chat-sidebar/ChatSidebarContext";
import { getNativeBridge } from "@comma/native-bridge";
import { CodingPullRequestPrompt } from "../tasks/CodingPullRequestPrompt";
import { publishCodingTaskFacts } from "../tasks/CodingSession";
import { useRouter } from "@tanstack/react-router";
import { acceptedSendPromise } from "./sendAcceptance";
import type {
  ChatConversationFile,
  ChatTaskRunChoice,
  ManualTaskStatus,
} from "@comma/chat-contract";
import { useStageTaskStatus } from "../../../product-inbox";
import type {
  ComposerDraftFill,
  ComposerDraftSource,
  ConversationViewState,
} from "../composer/conversationDraft";
import { useTaskSummary } from "../../tasks/useTaskArchive";
import { TaskShareButton } from "../../tasks/TaskShareButton";
import { taskStatusLabel as taskStatusLabelOf } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { Badge } from "@comma/ui/components/Badge";
import { Button } from "@comma/ui/components/Button";
import { uiClock } from "@comma/ui/clock";
import { isImeKeyEvent } from "@comma/ui/components/utils";
import { ContentHeader } from "@comma/ui/components/content-header";
import { useFileDrop } from "@comma/ui/components/ai-input/files/useFileDrop";
import { TitleSwap } from "@comma/ui/components/title-swap";
import { CommaLogoAnimation } from "@comma/ui/components/comma-mascot";
import {
  CopyContextMenu,
  LinkContextMenu,
  type CopyContextMenuAction,
  type LinkContextMenuAction,
  useTextEditContextMenuState,
} from "@comma/ui/components/menu";
import {
  MarkdownStreamLinkDecoratorContext,
  type MarkdownStreamLinkDecorator,
} from "@comma/ui/components/markdown-stream";
import {
  SelectionActionBar,
  type SelectionActionBarAction,
} from "@comma/ui/components/selection-action-bar";
import { taskStatusBucket, taskStatusIcon } from "@comma/ui/components/task-workspace";
import { toast } from "@comma/ui/components/toast";
import {
  memo,
  useCallback,
  useEffect,
  useId,
  useMemo,
  useRef,
  useState,
  type ComponentProps,
  type MouseEvent as ReactMouseEvent,
  type ReactNode,
} from "react";
import type { CommaSkill } from "@comma/core/api-schemas";
import type { ChatSuggestion } from "@comma/core/contract";
import { createConversationAnalytics } from "../../../analytics/experience";
import { beginCommaMessageSend } from "../../../analytics/client";
import { FocusComputerUseScreen } from "../../remote-screen/WorkerComputerUseScreen";
import { ParticipantStatusSlot } from "../thread/activity/ActivityLine";
import { TaskRunDialog } from "../tasks/TaskRunDialog";
import { TaskRunSwitchContext } from "../tasks/taskRunSwitch";
import type { ActivityFocusTask } from "../thread/activity/activityFocus";
import { useActivityFocus } from "../thread/activity/useActivityFocus";
import { ThreadWorkerVendorContext } from "../thread/threadContexts";
import { ChatBanner } from "./ChatBanner";
import { CreditWarningToast } from "../../billing/CreditWarningToast";
import { showOutOfCreditsToast } from "../../billing/outOfCredits";
import { fundingStopKind, showFundingStopToast } from "../../billing/fundingStops";
import { ChatLinkHoverCard } from "../thread/inline/ChatLinkHoverCard";
import {
  ChatLabelProposals,
  conversationLabelProposals,
} from "../tasks/labels/ChatLabelProposals";
import { groupLabelProposalsByAnchor } from "../tasks/labels/labelProposalAnchor";
import { useTaskLabelsCatalog } from "../tasks/labels/useTaskLabelsCatalog";
import { ChatTaskDock } from "../tasks/ChatTaskDock";
import { ChatTaskCardsContext, useChatTaskCards } from "../tasks/chatTaskCards";
import type { TaskDetailsStatusState } from "../tasks/TaskDetailsPanel";
import { stateSwapExitMs, useLeaving } from "../motion/useLeaving";
import type { TasksFilterLink } from "../../tasks/taskChips";
import {
  TaskPanelBody,
  TaskPanelFoldedTrigger,
  useTaskPanelFold,
} from "../tasks/TaskPanelFold";
import { useTaskActivity } from "../tasks/useTaskActivity";
import { Composer } from "../composer/Composer";
import { attachTransferredFiles } from "../composer/fileIntake";
import { createChatDraftQuote, type ChatDraftQuote } from "../composer/draftQuotes";
import {
  composeMessageWithSnippets,
  createChatDraftSnippet,
  snippetAttachedTexts,
  useConversationDraftSnippets,
  type ChatDraftSnippet,
  type ComposerDraftSnippets,
} from "../composer/draftSnippets";
import { useChatSelectionQuote } from "./useChatSelectionQuote";
import { useTouchLongPressMenu } from "./useTouchLongPressMenu";
import {
  canReplyTo,
  replyThreadSendTarget,
  threadRootOf,
  type ReplyThreadSelection,
} from "../thread/replies/replyThread";
import {
  ConversationThread,
  type ChatOutgoingLaunch,
} from "../thread/ConversationThread";
import {
  measureOutgoingBubbleSource,
  measureOutgoingTranscriptAnchor,
} from "../motion/outgoingBubbleMotion";
import {
  InlineTaskLinkAdapterProvider,
  renderInlineTaskLink,
  routeInlineTaskLinkAdapter,
  type InlineTaskLinkAdapter,
} from "../thread/inline/MessageInlineElements";
import type {
  AttachmentUploadInput,
  ChatImagePreviewRef,
  ChatConversationRef,
  ChatParticipantStatus,
  LocalFilePreview,
} from "@comma/core/chat";

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
import {
  composeMessageWithAttachedTexts,
  composeMessageWithQuotes,
  isTranscodedImageAttachment,
} from "@comma/core/chat";
import { useComposerMentionSources } from "../composer/useComposerMentionSources";
import { conversationMessageTurnKey } from "@comma/core/chat";
import { ChatSuggestionChips } from "../suggestions/ChatSuggestionChips";
import {
  AgentRequestCardsContext,
  useAgentRequests,
} from "../requests/useAgentRequests";
import { useChatSuggestions } from "../suggestions/useChatSuggestions";
import { useMarkLoadedTaskReviewSeen } from "../tasks/useMarkLoadedTaskReviewSeen";
import {
  MiniAppTaskContext,
  useShareMiniAppTask,
  type MiniAppTaskState,
} from "../../apps/MiniAppMessageCard";
import { MiniAppDraftContext } from "../../apps/MiniAppFrame";

export type ConversationViewActions = {
  acceptTaskReview?: (reviewVersion: number) => unknown;
  /** Ends the Task by hand at the exact version the viewer saw. */
  setTaskStatus?: (status: ManualTaskStatus, expectedUpdatedAt: number) => unknown;
  /** Runs the Task on another model; fails with why not. Absent where this host cannot. */
  setTaskRun?: (run: ChatTaskRunChoice) => Promise<unknown>;
  /** Files for the draft, or with `questionMessageId` for that question card's other answer. */
  attachFiles?: (files: AttachmentUploadInput[], questionMessageId?: string) => unknown;
  /** Message attachments for the draft, by reference (Add to Context on a message's file). */
  attachConversationFiles?: (files: ChatConversationFile[]) => unknown;
  /** Replaces the Task's labels; absent when this host cannot edit labels. */
  setTaskLabels?: (labelIds: string[]) => unknown;
  discard: (clientRequestId: string) => unknown;
  pickAttachments?: () => unknown;
  previewLocalFile?: (
    previewRef: ChatImagePreviewRef,
    signal?: AbortSignal
  ) => Promise<LocalFilePreview | undefined>;
  /** Reads a Task's history before the transcript held, for its Activity alone. */
  readTaskActivity?: () => unknown;
  refresh: () => unknown;
  removeAttachment: (id: string, questionMessageId?: string) => unknown;
  retry: (clientRequestId: string) => unknown;
  retryAttachment: (id: string, questionMessageId?: string) => unknown;
  /** Answers a question card; absent where cards are shown but not answered. */
  answerQuestion?: (answer: QuestionCardAnswer) => Promise<unknown>;
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
  /** Each new value focuses the composer's prompt. */
  focusRequest?: number | undefined;
  placeholder?: string | undefined;
  /** The conversation's snippets, when a surface beside it also stages them. */
  snippets?: ComposerDraftSnippets | undefined;
  submitDisabled?: boolean | undefined;
};

export const ConversationView = memo(function ConversationView({
  actions,
  composerPresentation,
  conversationId: selectedConversationId,
  draftSource,
  groupId,
  headerTrailing,
  inlineTaskLinkAdapter,
  leadingPanel,
  live = false,
  state,
  surfaceActive = true,
  trailingPanel,
  homeAccessory,
  variant = "route",
  workspaceId,
  skills = [],
  onOpenConversationRef,
  onOpenInCommaBrowser,
  onOpenTasksFilter,
  outgoingMotion,
  outgoingPlaybackRate = 1,
}: {
  actions: ConversationViewActions;
  composerPresentation?: ConversationComposerPresentation | undefined;
  /** Selected identity is available before the runtime loads its history. */
  conversationId?: string | undefined;
  /** The composer's draft; only the composer subscribes to it. */
  draftSource: ComposerDraftSource;
  groupId?: string | undefined;
  /** Route controls at the header's trailing end, such as the Task sequence. */
  headerTrailing?: ReactNode;
  inlineTaskLinkAdapter?: InlineTaskLinkAdapter | undefined;
  leadingPanel?: ReactNode;
  /**
   * The view shows the core's live data (link previews, the Task panel, label proposals, the agent's browser,
   * attachments). A static view (a share preview) shows only what it was given.
   */
  live?: boolean | undefined;
  onOpenConversationRef?: ((conversationRef: ChatConversationRef) => void) | undefined;
  /** Opens an http(s) URL in Comma's embedded browser sidebar. */
  onOpenInCommaBrowser?: ((url: string) => void) | undefined;
  /** Opens the Tasks page narrowed to a label or platform chip of the Task. */
  onOpenTasksFilter?: ((filter: TasksFilterLink) => void) | undefined;
  outgoingMotion?: import("@comma/ui/tokens").MessageSendMotionConfig | undefined;
  outgoingPlaybackRate?:
    | import("../motion/outgoingBubbleMotion").OutgoingBubblePlaybackRate
    | undefined;
  state: ConversationViewState;
  /** False while a retained surface is mounted but not visible to the reader. */
  surfaceActive?: boolean | undefined;
  skills?: CommaSkill[];
  trailingPanel?: ReactNode;
  /** Home's own controls at the top right of its chat, beside the browser trigger (the desktop's call). */
  homeAccessory?: ReactNode;
  variant?: "home" | "route" | "rail";
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
  // Its actions only: the view does not show the sidebar, so the sidebar's own changes do not render it.
  const sidebar = useOptionalChatSidebarActions();
  const router = useRouter({ warn: false });
  const routeRef = useRef<HTMLElement | null>(null);
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const announcedCreditFailures = useRef(new Set<string>());
  useEffect(() => {
    if (!surfaceActive) return;
    const failures = new Set(
      state.pending
        .filter(
          (pending) =>
            pending.status === "failed" &&
            (pending.failureAction === "billing" ||
              pending.error === messages.chat_insufficient_credits())
        )
        .map((pending) => pending.clientRequestId)
    );
    if ([...failures].some((id) => !announcedCreditFailures.current.has(id))) {
      showOutOfCreditsToast(locale);
    }
    announcedCreditFailures.current = failures;
  }, [locale, messages, state.pending, surfaceActive]);
  // A participant that stops mid-request for lack of funds raises the matching
  // toast once per stop in this view: Comma credits, the provider account
  // behind the member's own key, or an external runtime's own subscription.
  // The toast names the provider and Profile when the runtime published them.
  const announcedFundingStops = useRef(new Set<string>());
  useEffect(() => {
    if (!surfaceActive) return;
    const statuses =
      state.participantStatuses ??
      (state.participantStatus ? [state.participantStatus] : []);
    const stops = new Map<string, ChatParticipantStatus>();
    for (const status of statuses) {
      if (status.state === "error" && fundingStopKind(status.issue)) {
        const detail = status.issueDetail;
        stops.set(
          [
            status.participantId,
            status.issue,
            detail?.source,
            detail?.profileId,
            detail?.resetAt,
          ].join(":"),
          status
        );
      }
    }
    for (const [key, status] of stops) {
      if (!announcedFundingStops.current.has(key)) showFundingStopToast(status, locale);
    }
    announcedFundingStops.current = new Set(stops.keys());
  }, [locale, state.participantStatus, state.participantStatuses, surfaceActive]);
  const [browserOpen, setBrowserOpen] = useState(false);
  const browserPanelId = useId();
  const syncWarningToastId = `chat-sync-warning-${useId()}`;
  const heicToastId = `chat-heic-unsupported-${useId()}`;
  const resolvedInlineTaskLinkAdapter = useMemo<InlineTaskLinkAdapter>(() => {
    if (inlineTaskLinkAdapter) return inlineTaskLinkAdapter;
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
  }, [inlineTaskLinkAdapter, onOpenConversationRef, router]);
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
  // A manual status change shows at once. The chosen status stands in for the
  // canonical one until the Task's version moves on or the request fails.
  const [settingTaskStatus, setSettingTaskStatus] = useState<{
    conversationId: string;
    settled: boolean;
    status: ManualTaskStatus;
    version: number;
  }>();
  const [taskStatusError, setTaskStatusError] = useState<{
    conversationId: string;
    status: string | undefined;
  }>();
  const linkMenuUrlRef = useRef<string | null>(null);
  const linkMenuMessageTextRef = useRef<string>("");
  const copyMenuTextRef = useRef<string>("");
  const replyMenuTargetRef = useRef<ReplyThreadSelection | null>(null);
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
  const taskVersion =
    taskSummary &&
    (taskSummary.updated_at ?? 0) >= (state.conversation?.updated_at ?? 0)
      ? taskSummary.updated_at
      : state.conversation?.updated_at;
  const isArchived = isTask && taskStatus === "archived";
  // A Loop Task's Loop, as the core read it into the Task's summary.
  const taskLoop = taskSummary?.loop;
  const taskConversationId = state.conversation?.id;
  const taskReviewVersion = state.conversation?.review_version;
  // A deployed app's card offers Publish while this Task is in review.
  const miniAppTask = useMemo<MiniAppTaskState | undefined>(
    () =>
      isTask && taskConversationId
        ? {
            conversationId: taskConversationId,
            status: taskStatus,
            reviewVersion: taskReviewVersion,
          }
        : undefined,
    [isTask, taskConversationId, taskStatus, taskReviewVersion]
  );
  // The right panel, outside this view, offers Publish for the apps this Task built.
  useShareMiniAppTask(miniAppTask);
  const optimisticTaskStatus =
    settingTaskStatus !== undefined &&
    settingTaskStatus.conversationId === taskConversationId &&
    settingTaskStatus.version === taskVersion
      ? settingTaskStatus
      : undefined;
  const shownTaskStatus = optimisticTaskStatus?.status ?? taskStatus;
  const headerTaskStatus =
    isTask && shownTaskStatus ? taskStatusBucket(shownTaskStatus) : undefined;
  const taskStatusLabel =
    isTask && shownTaskStatus ? taskStatusLabelOf(shownTaskStatus, locale) : undefined;
  const canAcceptTask =
    isTask &&
    !isArchived &&
    state.conversation?.status === "ready_for_review" &&
    typeof taskReviewVersion === "number" &&
    Number.isInteger(taskReviewVersion) &&
    taskReviewVersion > 0 &&
    // A Task whose Loop still runs never waits for a review.
    (taskLoop === undefined || taskLoop.state === "ended") &&
    actions.acceptTaskReview !== undefined;
  // A user ends an in-progress or in-review Task by hand, a Loop Task included:
  // its Loop ends with it. The server also rejects Workflow and Triage Tasks,
  // which this view cannot tell apart.
  const canSetTaskStatus =
    isTask &&
    !isArchived &&
    taskConversationId !== undefined &&
    (taskStatus === "active" ||
      taskStatus === "ready_for_review" ||
      taskStatus === "escalated") &&
    typeof taskVersion === "number" &&
    taskVersion > 0 &&
    actions.setTaskStatus !== undefined;
  // Until the canonical Task catches up, the menu stays open to focus but
  // offers no second change from the version the first one consumed.
  const taskStatusState: TaskDetailsStatusState =
    optimisticTaskStatus !== undefined
      ? "pending"
      : taskStatusError !== undefined &&
          taskStatusError.conversationId === taskConversationId &&
          taskStatusError.status === taskStatus
        ? "failed"
        : "idle";
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
        ? (files: AttachmentUploadInput[], questionMessageId?: string) => {
            const admitted = transcodesImages
              ? files
              : files.filter((file) => !isTranscodedImageAttachment(file.name));
            if (admitted.length !== files.length) {
              toast.error(messages.chat_heic_unsupported_browser(), {
                id: heicToastId,
                testId: "chat-heic-unsupported",
              });
            }
            if (admitted.length === 0) return;
            if (questionMessageId === undefined) attachFiles(admitted);
            else attachFiles(admitted, questionMessageId);
          }
        : undefined,
    [attachFiles, heicToastId, messages, transcodesImages]
  );
  const { open: openImageMenu, menu: imageMenu } = useMediaContextMenu(
    handleAttachFiles,
    actions.attachConversationFiles
  );
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
  const composerFocusRequest = composerPresentation?.focusRequest;
  useEffect(() => {
    if (!composerFocusRequest) return;
    routeRef.current
      ?.querySelector<HTMLElement>('.comma-chat-composer [role="textbox"]')
      ?.focus({ preventScroll: true });
  }, [composerFocusRequest]);
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
        expiresAt: uiClock.now() + 4_000 / outgoingPlaybackRateRef.current,
        existingTurnKeys: new Set(
          currentState.messages
            .filter((message) => message.role === "user")
            .map(conversationMessageTurnKey)
        ),
        id: launchId,
        sourceFrame: source,
        // Read only for a launch: it lays out the transcript.
        transcriptAnchor: text.trim()
          ? measureOutgoingTranscriptAnchor(routeRef.current)
          : undefined,
        motionConfig: outgoingMotionRef.current,
        playbackRate: outgoingPlaybackRateRef.current,
        text,
      };
      if (text.trim()) {
        setOutgoingLaunches((current) => [...current, launch].slice(-4));
      }

      let result: unknown;
      const finishAnalytics = actions.tracksSendAnalytics
        ? undefined
        : beginCommaMessageSend(variant);
      // An open reply thread names the target; otherwise a widget reply may.
      const replyThread =
        options.consumeDraft !== false ? replyThreadRef.current : undefined;
      const replyToMessageId =
        options.consumeDraft === false
          ? undefined
          : replyThread
            ? replyThreadSendTarget(currentState.messages, replyThread)
            : uiReplyRef.current;
      try {
        result = actions.send(text, {
          skills: options.skills,
          ...(replyToMessageId ? { replyToMessageId } : {}),
          ...(options.consumeDraft === false ? { consumeDraft: false } : {}),
        });
      } catch (error) {
        finishAnalytics?.("failed", "dispatch");
        setOutgoingLaunches((current) =>
          current.filter((candidate) => candidate.id !== launchId)
        );
        throw error;
      }
      // Later replies in the thread answer its newest message.
      if (replyThread?.targetId) {
        setReplyThread((current) =>
          current?.rootId === replyThread.rootId
            ? { rootId: current.rootId, targetId: undefined }
            : current
        );
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
    conversationId,
    enabled: !isArchived && (variant === "route" || variant === "home"),
    groupId: threadGroupId || undefined,
    locale,
    state,
  });

  // Tasks the agent created in this conversation dock above the composer, on
  // the full chat surfaces only — the rail is too narrow for a second panel.
  const showTaskDock = variant === "route" || variant === "home";
  const revealTurnHandleRef = useRef<
    ((turnKey: string, highlightMessageId?: string) => void) | null
  >(null);
  const revealMessageHandleRef = useRef<((messageId: string) => void) | null>(null);

  // Tasks, routines, and plugins for the composer's "@" panel, as the core
  // keeps them; a Task chat never lists itself. A retained surface the reader
  // does not see follows none of them: showing it again reads them afresh.
  const mentionScope = useMemo(
    () => ({
      enabled: surfaceActive,
      excludeConversationId: conversationId,
      groupId: threadGroupId || undefined,
      // Home is the Router chat: a model named there starts a Task with it.
      models: variant === "home",
      workspaceId: threadWorkspaceId || undefined,
    }),
    [conversationId, surfaceActive, threadGroupId, threadWorkspaceId, variant]
  );

  // Quoted passages are renderer-only draft state, folded into the message
  // text on send. Keeping them out of the channel avoids widening the
  // Main-owned draft epoch for something with no intake or upload lifecycle.
  const uiReplyRef = useRef<string | undefined>(undefined);
  // The thread gathered above the composer for a reply. Sends read it through
  // the ref so the send callback keeps its identity.
  const [replyThread, setReplyThread] = useState<ReplyThreadSelection>();
  const replyThreadRef = useRef(replyThread);
  useEffect(() => {
    replyThreadRef.current = replyThread;
  }, [replyThread]);
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
  // An app running in this thread writes into its composer; the person sends it.
  const draftFromMiniApp = useCallback(
    (text: string) => {
      const draft = draftSource.getSnapshot();
      setDraft(draft ? `${draft}\n\n${text}` : text);
    },
    [draftSource, setDraft]
  );
  const {
    answerQuestion,
    removeAttachment,
    retryAttachment,
    previewLocalFile: previewQuestionImage,
  } = actions;
  // A card's images go through the composer's own attach, remove and retry, named by the question.
  const questionCardActions = useMemo<QuestionCardActions | undefined>(
    () =>
      answerQuestion && handleAttachFiles
        ? {
            answer: answerQuestion,
            attach: (questionMessageId, files) =>
              handleAttachFiles(files, questionMessageId),
            removeAttachment: (questionMessageId, attachmentId) =>
              removeAttachment(attachmentId, questionMessageId),
            retryAttachment: (questionMessageId, attachmentId) =>
              retryAttachment(attachmentId, questionMessageId),
            previewLocalFile: previewQuestionImage,
          }
        : undefined,
    [
      answerQuestion,
      handleAttachFiles,
      removeAttachment,
      retryAttachment,
      previewQuestionImage,
    ]
  );
  // Each state update maps the images anew: the cards re-render only when they change.
  const questionAttachmentsKey = JSON.stringify(state.questionAttachments ?? {});
  const questionAttachments = useMemo(
    () => state.questionAttachments ?? {},
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- keyed by value
    [questionAttachmentsKey]
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
    setReplyThread(undefined);
    setDraftQuotes((current) => (current.length === 0 ? current : []));
  }, [conversationId]);

  // Staging a quote is a reading gesture, so it stays available even while
  // the composer is momentarily blocked on a send in flight.
  const { clear: clearSelectionQuote, selection: liveSelectionQuote } =
    useChatSelectionQuote(routeRef);
  // Typing a reply under the selection moves the page selection into that
  // field, so the passage being replied to is kept here until it is sent or
  // put away.
  const [pinnedSelectionQuote, setPinnedSelectionQuote] =
    useState<typeof liveSelectionQuote>(null);
  const selectionQuote = pinnedSelectionQuote ?? liveSelectionQuote;
  const pinnedSelectionQuoteRef = useRef(pinnedSelectionQuote);
  useEffect(() => {
    pinnedSelectionQuoteRef.current = pinnedSelectionQuote;
  }, [pinnedSelectionQuote]);
  useEffect(() => {
    setPinnedSelectionQuote(null);
  }, [conversationId]);

  const removeDraftQuote = useCallback((id: string) => {
    setDraftQuotes((current) => current.filter((quote) => quote.id !== id));
  }, []);

  // Snippets stay with their conversation, as its draft does: switching away
  // and back finds them. Home stages its Routines' into the same place. Sends
  // read them through refs so the send callback keeps its identity.
  const ownSnippets = useConversationDraftSnippets(conversationId);
  const { items: draftSnippets, setItems: setDraftSnippets } =
    composerPresentation?.snippets ?? ownSnippets;
  const draftSnippetsRef = useRef(draftSnippets);
  const setDraftSnippetsRef = useRef(setDraftSnippets);
  useEffect(() => {
    draftSnippetsRef.current = draftSnippets;
    setDraftSnippetsRef.current = setDraftSnippets;
  }, [draftSnippets, setDraftSnippets]);
  const removeDraftSnippet = useCallback(
    (id: string) =>
      setDraftSnippets((current) => current.filter((snippet) => snippet.id !== id)),
    [setDraftSnippets]
  );
  const pasteDraftSnippet = useCallback(
    (text: string) =>
      setDraftSnippets((current) => [
        ...current,
        createChatDraftSnippet({ kind: "paste", text }),
      ]),
    [setDraftSnippets]
  );
  // "Show in text field" writes the snippet after the draft. Its source still
  // opens on send while the draft keeps the source's URL.
  const [composerFill, setComposerFill] = useState<ComposerDraftFill>();
  const expandedSourceUrlsRef = useRef(new Map<string, Set<string>>());
  const expandDraftSnippet = useCallback(
    (snippet: ChatDraftSnippet) => {
      removeDraftSnippet(snippet.id);
      if (snippet.sourceUrl) {
        const key = conversationIdRef.current ?? "";
        const urls = expandedSourceUrlsRef.current.get(key) ?? new Set<string>();
        urls.add(snippet.sourceUrl);
        expandedSourceUrlsRef.current.set(key, urls);
      }
      const draft = draftSource.getSnapshot();
      const next = draft ? `${draft}\n\n${snippet.text}` : snippet.text;
      setDraft(next);
      setComposerFill({ draft: next });
    },
    [draftSource, removeDraftSnippet, setDraft]
  );

  const finishSelectionQuote = useCallback(() => {
    // Leaving the passage highlighted would keep the bar up and invite a
    // second, duplicate quote of the same text.
    window.getSelection()?.removeAllRanges();
    clearSelectionQuote();
    setPinnedSelectionQuote(null);
  }, [clearSelectionQuote]);

  // What the person has typed in the selection's own field so far.
  const selectionReplyTextRef = useRef("");
  const setSelectionReplyText = useCallback((text: string) => {
    selectionReplyTextRef.current = text;
  }, []);

  const quoteSelection = useCallback(() => {
    const text = selectionQuote?.text.trim();
    if (!text) return;
    setDraftQuotes((current) => [...current, createChatDraftQuote(text)]);
    // A question already typed about the passage goes with it into the
    // composer instead of vanishing with the bar.
    const question = selectionReplyTextRef.current.trim();
    selectionReplyTextRef.current = "";
    if (question) {
      const draft = draftSource.getSnapshot();
      const next = draft ? `${draft}\n\n${question}` : question;
      setDraft(next);
      setComposerFill({ draft: next });
    }
    finishSelectionQuote();
  }, [draftSource, finishSelectionQuote, selectionQuote, setDraft]);

  const selectionReply = useMemo(() => {
    if (!selectionQuote) return undefined;
    return {
      excerpt: selectionQuote.text.trim(),
      onDismiss: () => setPinnedSelectionQuote(null),
      onEngage: () => setPinnedSelectionQuote((current) => current ?? selectionQuote),
      // The reply goes out on its own with the passage as its quote; the main
      // draft and its staged quotes stay as they are.
      onSubmit: (text: string) => {
        const quote = selectionQuote.text.trim();
        const result = launchOutgoing(
          composeMessageWithQuotes(text, quote ? [quote] : []),
          { consumeDraft: false, skills: [] }
        );
        // The card, its passage and the typed reply stay until the runtime
        // takes the send: a refusal (another send still holding the
        // conversation) creates no turn, so nothing else would keep them.
        const accepted =
          acceptedSendPromise(result) ??
          (result && typeof (result as PromiseLike<unknown>).then === "function"
            ? Promise.resolve(result)
            : undefined);
        if (!accepted) {
          finishSelectionQuote();
          return undefined;
        }
        // Only the card this reply came from closes: the reader may have put it
        // away and selected something else while the send was taken.
        const replied = pinnedSelectionQuoteRef.current;
        return accepted.then(() => {
          if (!replied || pinnedSelectionQuoteRef.current === replied) {
            finishSelectionQuote();
          }
        });
      },
      onTextChange: setSelectionReplyText,
      failedLabel: messages.chat_selection_reply_failed(),
      placeholder: messages.chat_selection_reply_placeholder(),
    };
  }, [
    finishSelectionQuote,
    launchOutgoing,
    messages,
    selectionQuote,
    setSelectionReplyText,
  ]);

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
      const submittedSnippets = draftSnippetsRef.current;
      const setSnippets = setDraftSnippetsRef.current;
      const submittedSnippetIds = new Set(
        submittedSnippets.map((snippet) => snippet.id)
      );
      const restoreSubmittedSnippets = () => {
        if (submittedSnippets.length === 0) return;
        setSnippets((current) => {
          const currentIds = new Set(current.map((snippet) => snippet.id));
          const missing = submittedSnippets.filter(
            (snippet) => !currentIds.has(snippet.id)
          );
          return missing.length === 0 ? current : [...missing, ...current];
        });
      };
      // The items the sent snippets are about open beside the conversation.
      const expandedKey = submittedConversationId ?? "";
      const expandedSourceUrls = expandedSourceUrlsRef.current.get(expandedKey);
      expandedSourceUrlsRef.current.delete(expandedKey);
      const restoreSubmitted = () => {
        restoreSubmittedQuotes();
        restoreSubmittedSnippets();
        if (expandedSourceUrls) {
          expandedSourceUrlsRef.current.set(expandedKey, expandedSourceUrls);
        }
      };
      // Folded in before the handoff so a send that is nothing but a quoted
      // passage or a snippet still carries text.
      const quoted = composeMessageWithQuotes(
        composeMessageWithAttachedTexts(
          composeMessageWithSnippets(text, submittedSnippets),
          snippetAttachedTexts(submittedSnippets)
        ),
        submittedQuotes.map((quote) => quote.text)
      );
      if (submittedQuotes.length > 0) {
        setDraftQuotes((current) =>
          current.filter((quote) => !submittedQuoteIds.has(quote.id))
        );
      }
      if (submittedSnippets.length > 0) {
        setSnippets((current) =>
          current.filter((snippet) => !submittedSnippetIds.has(snippet.id))
        );
      }

      let result: unknown;
      try {
        result = launchOutgoing(quoted, {
          onAdmissionRejected: restoreSubmitted,
          skills: options.skills,
        });
      } catch (error) {
        restoreSubmitted();
        throw error;
      }
      const sourceUrls = new Set([
        ...submittedSnippets.flatMap((snippet) =>
          snippet.sourceUrl ? [snippet.sourceUrl] : []
        ),
        ...[...(expandedSourceUrls ?? [])].filter((url) => text.includes(url)),
      ]);
      if (sourceUrls.size > 0 && onOpenInCommaBrowser) {
        const openSources = () => {
          for (const url of sourceUrls) onOpenInCommaBrowser(url);
        };
        // A send the runtime may still refuse opens them once it is accepted.
        const accepted = acceptedSendPromise(result);
        if (accepted) void accepted.then(openSources, () => undefined);
        else openSources();
      }
      return result;
    },
    [launchOutgoing, onOpenInCommaBrowser]
  );

  const handleSelectSuggestion = useCallback(
    (suggestion: ChatSuggestion) => {
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

  const stageTaskStatus = useStageTaskStatus();
  const handleSetTaskStatus = useCallback(
    async (status: ManualTaskStatus) => {
      if (
        !canSetTaskStatus ||
        optimisticTaskStatus !== undefined ||
        !actions.setTaskStatus ||
        taskConversationId === undefined ||
        typeof taskVersion !== "number"
      ) {
        return;
      }
      const request = {
        conversationId: taskConversationId,
        settled: false,
        status,
        version: taskVersion,
      };
      setSettingTaskStatus(request);
      setTaskStatusError(undefined);
      // Lists that read the projected Inbox show the choice at once too.
      const listStage = stageTaskStatus({
        conversationId: taskConversationId,
        groupId: threadGroupId,
        status,
        version: taskVersion,
      });
      try {
        await actions.setTaskStatus(status, taskVersion);
        listStage.confirm();
        // Keep showing the chosen status until the canonical Task catches up,
        // so the pill never flashes back to the old status.
        setSettingTaskStatus((current) =>
          current === request ? { ...request, settled: true } : current
        );
      } catch {
        listStage.rollback();
        setSettingTaskStatus((current) => (current === request ? undefined : current));
        setTaskStatusError({ conversationId: taskConversationId, status: taskStatus });
      }
    },
    [
      actions,
      canSetTaskStatus,
      optimisticTaskStatus,
      stageTaskStatus,
      taskConversationId,
      taskStatus,
      taskVersion,
      threadGroupId,
    ]
  );

  const finishOutgoingLaunch = useCallback((launchId: number) => {
    setOutgoingLaunches((current) =>
      current.filter((candidate) => candidate.id !== launchId)
    );
  }, []);

  // Hover previews for every external message link: a rich card where the
  // server can read the link, the generic destination tile otherwise. Keyed on
  // [live, workspaceId] only: every MarkdownStream link node subscribes to this
  // context, so a new decorator identity per render would re-render every link
  // on every emit (PR #857 identity contract) — memoize hard.
  const linkDecorator = useMemo<MarkdownStreamLinkDecorator | undefined>(() => {
    if (!live || !threadWorkspaceId) return undefined;
    return ({ anchor, href }) => (
      <ChatLinkHoverCard anchor={anchor} href={href} workspaceId={threadWorkspaceId} />
    );
  }, [live, threadWorkspaceId]);

  // Only a canonical message can be answered, and only where the reader can send.
  const canReply = !isArchived && !unboundComposerDisabled;
  // Files dropped anywhere on the conversation, not only on the composer, are
  // attached to the draft; while they are dragged over it, the composer shows
  // its drop overlay.
  const dropFiles = useMemo(
    () =>
      handleAttachFiles && canReply
        ? (transfer: DataTransfer) =>
            attachTransferredFiles(transfer, handleAttachFiles)
        : undefined,
    [canReply, handleAttachFiles]
  );
  const conversationDrop = useFileDrop(dropFiles);
  const resolveReplyTarget = useCallback(
    (article: HTMLElement): ReplyThreadSelection | null => {
      const messageId = article.dataset.messageId;
      if (!messageId || messageId === state.assistantDraft?.draftId) return null;
      const message = state.messages.find((item) => item.messageId === messageId);
      if (canReplyTo(message)) {
        return { rootId: threadRootOf(message), targetId: messageId };
      }
      // An older thread member loaded only for the open thread.
      const open = replyThreadRef.current;
      if (open && !message && article.closest(".comma-chat-reply-thread")) {
        return { rootId: open.rootId, targetId: messageId };
      }
      return null;
    },
    [state.assistantDraft?.draftId, state.messages]
  );
  const focusComposer = useCallback(() => {
    routeRef.current
      ?.querySelector<HTMLElement>('.comma-chat-composer [role="textbox"]')
      ?.focus({ preventScroll: true });
  }, []);
  const openReplyThread = useCallback(
    (target: ReplyThreadSelection) => {
      setReplyThread(target);
      focusComposer();
    },
    [focusComposer]
  );
  const closeReplyThread = useCallback(() => setReplyThread(undefined), []);
  const replyThreadOpen = replyThread !== undefined;
  useEffect(() => {
    if (!replyThreadOpen) return;
    const handleKeyDown = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented || isImeKeyEvent(event))
        return;
      event.preventDefault();
      closeReplyThread();
    };
    window.addEventListener("keydown", handleKeyDown);
    return () => window.removeEventListener("keydown", handleKeyDown);
  }, [closeReplyThread, replyThreadOpen]);

  const longPress = useTouchLongPressMenu();
  const handleClickCapture = useCallback(
    (event: ReactMouseEvent<HTMLElement>) => {
      longPress.onClickCapture(event);
      if (event.defaultPrevented || !onOpenInCommaBrowser) return;
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
    [longPress, onOpenInCommaBrowser]
  );

  const handleContextMenuCapture = useCallback(
    (event: ReactMouseEvent<HTMLElement>) => {
      longPress.onContextMenuCapture();
      if (event.target instanceof Element) {
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
      const replyTarget = canReply ? resolveReplyTarget(article) : null;
      if (!copyText && !replyTarget) return;

      event.preventDefault();
      copyMenuTextRef.current = copyText;
      replyMenuTargetRef.current = replyTarget;
      setLinkMenuOpen(false);
      openCopyMenuAtPointer(
        event.currentTarget,
        event.clientX,
        event.clientY,
        event.target instanceof Element ? event.target : event.currentTarget
      );
    },
    [
      canReply,
      longPress,
      openImageMenu,
      openCopyMenuAtPointer,
      openLinkMenuAtPointer,
      resolveReplyTarget,
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

  const handleCopyMenuAction = useCallback(
    (action: CopyContextMenuAction) => {
      if (action === "reply") {
        const target = replyMenuTargetRef.current;
        if (target) openReplyThread(target);
        return;
      }
      const text = copyMenuTextRef.current;
      if (text) void copyTextToClipboard(text);
    },
    [openReplyThread]
  );

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

  // A press inside a widget frame never reaches this document, so React Aria
  // cannot treat it as an outside interaction. The window losing focus to the
  // frame closes the menu instead.
  useEffect(() => {
    if (!isLinkMenuOpen) return;
    const close = () => handleLinkMenuOpenChange(false);
    window.addEventListener("blur", close);
    return () => window.removeEventListener("blur", close);
  }, [handleLinkMenuOpenChange, isLinkMenuOpen]);

  const handleCopyMenuOpenChange = useCallback(
    (open: boolean) => {
      const changed = setCopyMenuOpen(open);
      if (!open && changed) {
        copyMenuTextRef.current = "";
        replyMenuTargetRef.current = null;
      }
    },
    [setCopyMenuOpen]
  );

  // The menus stay mounted while the conversation streams; their props keep
  // their identity, so the memoized menus do not render with each chunk.
  const linkMenuDisabledActions = useMemo(
    () => ({ openInComma: !onOpenInCommaBrowser }),
    [onOpenInCommaBrowser]
  );
  const linkMenuLabels = useMemo(
    () => ({
      ariaLabel: messages.chat_link_menu(),
      copyLink: messages.chat_copy_link(),
      copyMessage: messages.chat_copy_message(),
      openInComma: messages.chat_open_in_comma(),
      openInExternalBrowser: messages.chat_open_in_external_browser(),
    }),
    [messages]
  );
  // What the copy menu offers is read when it opens: the press that opens it
  // writes the text and the reply target first.
  const copyMenuDisabledActions = useMemo(
    () => ({ copy: !copyMenuTextRef.current }),
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- re-read on open
    [isCopyMenuOpen]
  );
  const copyMenuLabels = useMemo(
    () => ({
      ariaLabel: messages.chat_text_menu(),
      copy: messages.common_copy(),
      reply: replyMenuTargetRef.current ? messages.chat_reply() : undefined,
    }),
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- re-read on open
    [isCopyMenuOpen, messages]
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
  // a popover behind a trigger once it folds. Home keeps the header status
  // badge instead.
  const showTaskPanel =
    isTask && (variant === "route" || variant === "rail") && presentation !== undefined;
  const taskPanelFold = useTaskPanelFold(routeRef, showTaskPanel);
  const taskActivity = useTaskActivity(showTaskPanel ? state.taskActivity : undefined);
  // The Activity reads the Task's whole history; the transcript holds only its latest messages.
  const { readTaskActivity } = actions;
  const readEarlierActivity = useMemo(
    () =>
      readTaskActivity
        ? () => void Promise.resolve(readTaskActivity()).catch(() => undefined)
        : undefined,
    [readTaskActivity]
  );
  // Only a Task whose first message the transcript does not hold has more to read.
  const taskHasEarlier =
    showTaskPanel && state.status === "ready" && state.history?.hasOlder === true;
  useEffect(() => {
    if (taskHasEarlier) readEarlierActivity?.();
  }, [readEarlierActivity, taskHasEarlier]);
  const revealActivityStep = useCallback(
    (messageId: string) => revealMessageHandleRef.current?.(messageId),
    []
  );
  // The model picker for a Task: opened from its panel's Environment, or from the notice that its model cannot start.
  const [switchingRun, setSwitchingRun] = useState(false);
  const canSwitchRun =
    isTask &&
    hasCanonicalConversation &&
    actions.setTaskRun !== undefined &&
    !!threadWorkspaceId &&
    // A coding Task runs on its own sandbox: it is not switched.
    state.taskRun?.place.kind !== "sandbox" &&
    // Nor one the core says cannot switch (a Task a station hosts switches its model alone: `move`).
    !state.unsupported?.includes("run");
  const openRunSwitch = useMemo(
    () => (canSwitchRun ? () => setSwitchingRun(true) : undefined),
    [canSwitchRun]
  );
  // A Task's chat draws its `task_run_blocked` message as a card that switches the model in place.
  const taskRunSwitch = useMemo(
    () =>
      canSwitchRun && actions.setTaskRun
        ? {
            blockedMessageId: state.taskRunBlocked?.messageId,
            run: state.taskRun,
            switchRun: actions.setTaskRun,
            workspaceId: threadWorkspaceId,
          }
        : undefined,
    [
      actions.setTaskRun,
      canSwitchRun,
      state.taskRun,
      state.taskRunBlocked,
      threadWorkspaceId,
    ]
  );
  // A Loop Task stays in progress between runs; its Activity reads as working only while an Agent is.
  const taskAgentWorking = (
    state.participantStatuses ??
    (state.participantStatus ? [state.participantStatus] : [])
  ).some((status) => status.state === "active");
  // A coding Task's changes open as a tab of the sidebar, at the file pressed in the panel.
  const sandboxBranch =
    state.taskRun?.place.kind === "sandbox"
      ? state.taskRun.place.repo?.branch
      : undefined;
  const isSandboxTask = state.taskRun?.place.kind === "sandbox";
  // A coding Task: a sandbox Task with a repository. One without has no changes or pull request.
  const isCodingTask =
    state.taskRun?.place.kind === "sandbox" && state.taskRun.place.repo !== undefined;
  const sandboxBase =
    state.taskRun?.place.kind === "sandbox"
      ? state.taskRun.place.repo?.baseRef
      : undefined;
  const sandboxOwner =
    state.taskRun?.place.kind === "sandbox"
      ? state.taskRun.place.repo?.owner
      : undefined;
  const sandboxRepoName =
    state.taskRun?.place.kind === "sandbox"
      ? state.taskRun.place.repo?.name
      : undefined;
  const sandboxReady =
    state.taskRun?.place.kind === "sandbox" && state.taskRun.place.state === "ready";
  const openCodingChanges = useMemo(
    () =>
      sidebar && isCodingTask && workspaceId && threadGroupId && taskConversationId
        ? (file?: string) =>
            sidebar.openCodingChanges(
              sidebar.getActiveHost() ?? {
                workspaceId,
                groupId: threadGroupId,
                conversationId: taskConversationId,
              },
              {
                workspaceId,
                taskId: taskConversationId,
                ready: sandboxReady,
                ...(file ? { file } : {}),
                ...(sandboxBranch ? { branch: sandboxBranch } : {}),
                ...(sandboxBase ? { base: sandboxBase } : {}),
                ...(sandboxOwner && sandboxRepoName
                  ? { repo: { owner: sandboxOwner, name: sandboxRepoName } }
                  : {}),
              }
            )
        : undefined,
    [
      isCodingTask,
      sandboxReady,
      sandboxBase,
      sandboxOwner,
      sandboxRepoName,
      sandboxBranch,
      sidebar,
      taskConversationId,
      threadGroupId,
      workspaceId,
    ]
  );
  // The sandbox's terminal opens as a browser tab of the sidebar where the app embeds one; the browser outside else.
  const embedsBrowser = getNativeBridge().platform === "electron";
  const openCodingTerminal = useMemo(
    () =>
      sidebar &&
      embedsBrowser &&
      isSandboxTask &&
      workspaceId &&
      threadGroupId &&
      taskConversationId
        ? (url: string) =>
            sidebar.openBrowser(
              sidebar.getActiveHost() ?? {
                workspaceId,
                groupId: threadGroupId,
                conversationId: taskConversationId,
              },
              // One terminal tab per Task: opened again, it comes to the front and reconnects.
              {
                kind: "terminal",
                taskId: taskConversationId,
                title: messages.coding_terminal_tab(),
                url,
              }
            )
        : undefined,
    [
      embedsBrowser,
      isSandboxTask,
      messages,
      sidebar,
      taskConversationId,
      threadGroupId,
      workspaceId,
    ]
  );
  // One target for the panel's reads and the prompt: a new object each render would read the sandbox again each render.
  const codingTarget = useMemo(
    () =>
      isSandboxTask && workspaceId && taskConversationId
        ? { workspaceId, taskId: taskConversationId }
        : undefined,
    [isSandboxTask, taskConversationId, workspaceId]
  );
  // What the conversation knows of a coding Task now, for the surfaces outside its panel (the sidebar's Changes tab).
  const sandboxPlaceState =
    state.taskRun?.place.kind === "sandbox" ? state.taskRun.place.state : undefined;
  useEffect(() => {
    if (taskConversationId && sandboxPlaceState !== undefined)
      publishCodingTaskFacts(taskConversationId, {
        placeState: sandboxPlaceState,
        working: taskAgentWorking,
      });
  }, [sandboxPlaceState, taskAgentWorking, taskConversationId]);
  // The moment to propose the branch: the coding Task in review or done, its sandbox running or not (Comma opens the
  // pushed branch on GitHub once it is gone). Through a Worker's turn the prompt stays and waits.
  const pullRequestDue =
    isCodingTask &&
    (headerTaskStatus === "needs_review" || headerTaskStatus === "done");
  const taskPanelProps =
    showTaskPanel && presentation
      ? {
          activity: taskActivity,
          activityWorking: taskAgentWorking,
          conversation: {
            ...presentation,
            status: shownTaskStatus ?? presentation.status,
          },
          groupId: threadGroupId,
          loop: taskLoop,
          run: state.taskRun,
          // A coding Task's panel reads its changes and record from its sandbox, and acts on it.
          coding: codingTarget,
          onSwitchRun: openRunSwitch,
          onOpenTasksFilter,
          onReadEarlierActivity: readEarlierActivity,
          onRevealActivityStep: revealActivityStep,
          onOpenCodingChanges: openCodingChanges,
          onOpenCodingTerminal: openCodingTerminal,
          onSetLabels: hasCanonicalConversation ? actions.setTaskLabels : undefined,
          onSetStatus: canSetTaskStatus ? handleSetTaskStatus : undefined,
          statusState: taskStatusState,
        }
      : undefined;

  // Task work behind the Router's status, or this chat's Workers while the
  // Router is idle. A Task view lists its own Participants instead, and a
  // retained surface that is not shown follows no Task.
  const activityFocus = useActivityFocus({
    enabled: surfaceActive && !isTask && Boolean(threadGroupId) && live,
    groupId: threadGroupId,
    messages: state.messages,
    participantStatus: state.participantStatus,
  });
  // A Task card under each message that announced a Task. Its Workers' steps
  // follow the reply slot's rule.
  const taskCards = useChatTaskCards(state.messages, surfaceActive && live);
  // The bubble opens a Task the way this surface's Task chips do.
  const focusTaskLink = useCallback(
    (task: ActivityFocusTask) => {
      const taskTitle = task.title || messages.chat_ref_task();
      return renderInlineTaskLink(resolvedInlineTaskLinkAdapter, {
        ariaLabel: messages.tasks_open({ title: taskTitle }),
        conversationId: task.conversationId,
        groupId: threadGroupId,
        title: taskTitle,
        workspaceId: threadWorkspaceId,
      });
    },
    [messages, resolvedInlineTaskLinkAdapter, threadGroupId, threadWorkspaceId]
  );

  const workerVendor = state.taskRun?.vendor;
  const responseFeedback = useCallback(
    ({ hasResponse }: { hasResponse: boolean }) => (
      <>
        <ParticipantStatusSlot
          hasResponse={hasResponse}
          activity={state.activity}
          reserveSpace={false}
          streaming={state.reply?.streaming === true}
          optimisticThinking={state.reply?.thinking === true}
          participantStatus={state.participantStatus}
          participantStatuses={state.participantStatuses}
          replyTimedOut={state.reply?.timedOut === true}
          focus={activityFocus}
          taskLink={focusTaskLink}
          workerVendor={workerVendor}
          onSwitchRun={openRunSwitch}
        />
        {threadGroupId && state.participantStatus?.state === "active" ? (
          <FocusComputerUseScreen
            conversationId={state.participantStatus.conversationId}
            groupId={threadGroupId}
            participantId={state.participantStatus.participantId}
          />
        ) : null}
      </>
    ),
    [
      state.activity,
      state.reply,
      state.participantStatus,
      state.participantStatuses,
      activityFocus,
      focusTaskLink,
      threadGroupId,
      workerVendor,
      openRunSwitch,
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
  const { catalog: labelCatalog } = useTaskLabelsCatalog(threadGroupId, !isTask);
  // A proposal records when it was filed, not the reply that filed it. Each card
  // belongs to the reply nearest that time: it holds that reply's place in the
  // transcript, so a later round neither drags an older card along nor hides the
  // new decision at the bottom.
  const labelProposalsTails = useMemo(() => {
    if (isTask || !live || !threadGroupId || !conversationId) return undefined;
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
    conversationId,
    isTask,
    labelCatalog,
    latestReplyKey,
    live,
    state.messages,
    threadGroupId,
    threadWorkspaceId,
  ]);
  // An Agent's requests (connect an account): a card in the reply that owns it, or on the newest turn. A retained
  // surface the reader does not see follows none, as for the rest of the live data.
  const { cards: requestCards, tails: requestTails } = useAgentRequests({
    live: surfaceActive && live === true,
    groupId: threadGroupId,
    conversationId,
    messages: state.messages,
  });
  const anchoredTails = useMemo(
    () =>
      requestTails.length === 0
        ? labelProposalsTails
        : [...(labelProposalsTails ?? []), ...requestTails],
    [labelProposalsTails, requestTails]
  );
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
      settingTaskStatus !== undefined &&
      (settingTaskStatus.conversationId !== taskConversationId ||
        settingTaskStatus.version !== taskVersion)
    ) {
      setSettingTaskStatus(undefined);
    }
  }, [settingTaskStatus, taskConversationId, taskVersion]);

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

    const timer = uiClock.after(Math.max(0, nextExpiry - uiClock.now()), () => {
      const now = uiClock.now();
      setOutgoingLaunches((current) =>
        current.filter((launch) => launch.expiresAt > now)
      );
    });
    return () => timer();
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
      <div
        className="comma-chat-drop-zone"
        data-drop-active={conversationDrop.dropActive ? "true" : undefined}
        {...conversationDrop.shellDropProps}
      >
        <ChatBanner errorKind={state.errorKind} />
        {sidebar && workspaceId && threadGroupId && historyParticipants.length > 0 ? (
          <ConversationParticipants
            groupId={threadGroupId}
            participants={historyParticipants}
            taskRun={state.taskRun}
            onOpen={(participant) =>
              sidebar.openSessionHistory(
                sidebar.getActiveHost() ?? {
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
            <ChatTaskCardsContext.Provider value={taskCards}>
              <DynamicUiLinkContext.Provider value={onOpenInCommaBrowser}>
                <DynamicUiLinkMenuContext.Provider value={handleDynamicUiLinkMenu}>
                  <DynamicUiDraftContext.Provider value={replyFromDynamicUi}>
                    <QuestionCardActionsContext.Provider value={questionCardActions}>
                      <QuestionCardAttachmentsContext.Provider
                        value={questionAttachments}
                      >
                        <ThreadWorkerVendorContext.Provider value={workerVendor}>
                          <TaskRunSwitchContext.Provider value={taskRunSwitch}>
                            <AgentRequestCardsContext.Provider value={requestCards}>
                              <MiniAppTaskContext.Provider value={miniAppTask}>
                                <MiniAppDraftContext.Provider value={draftFromMiniApp}>
                                  <ConversationThread
                                    live={live}
                                    assistantDraft={state.assistantDraft}
                                    assistantResponseSlotId={
                                      state.conversation?.id ?? "conversation"
                                    }
                                    conversationId={state.conversation?.id}
                                    conversationKind={
                                      isTask ? "agent_task" : "user_chat"
                                    }
                                    defaultAssistantActorRole={
                                      isTask ? undefined : "router"
                                    }
                                    groupId={threadGroupId}
                                    afterMessages={transcriptTail}
                                    anchoredTails={anchoredTails}
                                    responseFeedback={
                                      isTask ? undefined : responseFeedback
                                    }
                                    messages={state.messages}
                                    onOpenConversationRef={onOpenConversationRef}
                                    onOutgoingAnimationComplete={finishOutgoingLaunch}
                                    onPreviewLocalFile={actions.previewLocalFile}
                                    onDiscard={actionsMemo.discard}
                                    onExitReplyThread={closeReplyThread}
                                    onRetry={actionsMemo.retry}
                                    outgoingLaunches={outgoingLaunches}
                                    replyThread={replyThread}
                                    revealMessageHandle={revealMessageHandleRef}
                                    revealTurnHandle={revealTurnHandleRef}
                                    workspaceId={threadWorkspaceId}
                                  />
                                </MiniAppDraftContext.Provider>
                              </MiniAppTaskContext.Provider>
                            </AgentRequestCardsContext.Provider>
                          </TaskRunSwitchContext.Provider>
                        </ThreadWorkerVendorContext.Provider>
                      </QuestionCardAttachmentsContext.Provider>
                    </QuestionCardActionsContext.Provider>
                  </DynamicUiDraftContext.Provider>
                </DynamicUiLinkMenuContext.Provider>
              </DynamicUiLinkContext.Provider>
            </ChatTaskCardsContext.Provider>
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
                groupId={threadGroupId}
                messages={state.messages}
                revealTurnHandle={revealTurnHandleRef}
                taskLinkAdapter={resolvedInlineTaskLinkAdapter}
                workspaceId={threadWorkspaceId}
              />
            ) : null}
            <CreditWarningToast
              workspaceId={workspaceId}
              active={surfaceActive && !isArchived}
            />
            {codingTarget ? (
              <CodingPullRequestPrompt
                branch={sandboxBranch}
                coding={codingTarget}
                due={pullRequestDue}
                // Another Task's changes never show while this one's are read.
                key={codingTarget.taskId}
                working={taskAgentWorking}
              />
            ) : null}
            <SourcedComposer
              controlCommandsEnabled={state.conversation?.kind === "user_chat"}
              disabled={unboundComposerDisabled}
              draftSource={draftSource}
              suggestion={isArchived ? undefined : suggestionItems[0]?.prompt}
              onAcceptSuggestion={clearSuggestions}
              draftAttachments={state.draftAttachments}
              draftQuotes={draftQuotes}
              draftSnippets={draftSnippets}
              fill={composerFill}
              {...(handleAttachFiles ? { onAttachFiles: handleAttachFiles } : {})}
              {...(actions.pickAttachments
                ? { onPickAttachments: actions.pickAttachments }
                : {})}
              {...(actions.previewLocalFile
                ? { onPreviewLocalFile: actions.previewLocalFile }
                : {})}
              mentionScope={mentionScope}
              onDraftChange={actions.setDraft}
              onRemoveAttachment={actions.removeAttachment}
              onExpandSnippet={expandDraftSnippet}
              onPasteSnippet={pasteDraftSnippet}
              onRemoveQuote={removeDraftQuote}
              onRemoveSnippet={removeDraftSnippet}
              onRetryAttachment={actions.retryAttachment}
              onSend={handleSend}
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
              {...(replyThread
                ? { placeholder: messages.chat_composer_placeholder() }
                : {})}
              size="small"
              skills={skills}
              submitDisabled={
                unboundComposerDisabled || unboundSubmitDisabled || anyFailedAttachment
              }
              {...(conversationDrop.dropEnabled
                ? { surfaceDropActive: conversationDrop.dropActive }
                : {})}
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
      </div>
    );

  const browserParticipantId = isTask
    ? state.boundWorker?.participantId
    : state.participantStatus?.conversationId === conversationId
      ? state.participantStatus?.participantId
      : undefined;
  const { browser, refresh: refreshBrowser } = useSessionBrowser(
    surfaceActive && live,
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
    browserOpen && browser && live && workspaceId ? (
      <AgentBrowserPanel
        key={JSON.stringify([workspaceId, browser.agent_id, browser.session_id])}
        binding={browser}
        onRefresh={refreshBrowser}
        id={browserPanelId}
        workspaceId={workspaceId}
      />
    ) : null;

  return (
    <MediaMenuContext.Provider value={openImageMenu}>
      <section
        aria-label={homeSurfaceLabel ?? messages.chat_region()}
        className="comma-chat-route flex min-h-0 w-full min-w-0 flex-1 flex-col bg-main-panel-bg"
        data-variant={variant}
        onClickCapture={handleClickCapture}
        onContextMenuCapture={handleContextMenuCapture}
        onPointerCancel={longPress.onPointerCancel}
        onPointerDown={longPress.onPointerDown}
        onPointerMove={longPress.onPointerMove}
        onPointerUp={longPress.onPointerUp}
        ref={routeRef}
      >
        {variant === "home" ? null : (
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
                <h1 className="comma-chat-title">
                  {/* The placeholder giving way to the first title is no rename. */}
                  <TitleSwap
                    identity={presentation?.title ? selectedConversationId : undefined}
                    text={title}
                  />
                </h1>
              )}
              {isTask &&
              !connecting &&
              variant === "route" &&
              live &&
              groupId &&
              selectedConversationId &&
              !state.unsupported?.includes("share") ? (
                <TaskShareButton
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
            </div>
            {headerTrailing}
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
              {browserTrigger || homeAccessory ? (
                <div className="flex h-11 shrink-0 items-center justify-end gap-sm px-xl">
                  {homeAccessory}
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
        {switchingRun && actions.setTaskRun ? (
          <TaskRunDialog
            unsupported={state.unsupported}
            onClose={() => setSwitchingRun(false)}
            onSwitch={actions.setTaskRun}
            run={state.taskRun}
            workspaceId={threadWorkspaceId}
          />
        ) : null}
        <LinkContextMenu
          disabledActions={linkMenuDisabledActions}
          isOpen={isLinkMenuOpen}
          labels={linkMenuLabels}
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
          {...(selectionReply ? { reply: selectionReply } : {})}
        />
        <CopyContextMenu
          isOpen={isCopyMenuOpen}
          disabledActions={copyMenuDisabledActions}
          labels={copyMenuLabels}
          onAction={handleCopyMenuAction}
          onOpenChange={handleCopyMenuOpenChange}
          pointerOffsets={copyMenuPointerOffsets}
          triggerRef={routeRef}
        />
        {imageMenu}
      </section>
    </MediaMenuContext.Provider>
  );
});

/**
 * The composer with its "@" panel's sources. Only the composer shows them, so
 * it subscribes to them itself: a Task list that moves renders the composer,
 * not the conversation around it.
 */
const SourcedComposer = memo(function SourcedComposer({
  mentionScope,
  ...props
}: Omit<ComponentProps<typeof Composer>, "mentionSources"> & {
  mentionScope: Parameters<typeof useComposerMentionSources>[0];
}) {
  const mentionSources = useComposerMentionSources(mentionScope);
  return <Composer {...props} mentionSources={mentionSources} />;
});

let chatOutgoingLaunchSequence = 0;

function nextChatOutgoingLaunchId() {
  chatOutgoingLaunchSequence += 1;
  return chatOutgoingLaunchSequence;
}

function measureChatComposer(root: HTMLElement | null) {
  const composer = root?.querySelector<HTMLElement>(".comma-chat-composer");
  return measureOutgoingBubbleSource(composer);
}
