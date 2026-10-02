import { appendRecommendationPrompt } from "./recommendations/appendRecommendationPrompt";
import { beginCommaMessageSend } from "../analytics/client";
import { acceptedSendPromise } from "./chat/conversation/sendAcceptance";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
  useContext,
} from "react";
import { toast } from "@comma/ui";
import type { CommaApiClient, CommaConversation, CommaSkill } from "../api";
import { HomeTasksRail, HomeTasksRailLoading } from "./home/HomeTasksRail";
import { useHomeRailFolded } from "./home/HomeRailFolds";
import { HomeRailCollapseHandle } from "./home/HomeRailHandle";
import { AppIcon, type AppIconName } from "./icons";
import {
  useChatSidebar,
  useRegisterChatSidebarHost,
} from "./chat-sidebar/ChatSidebarContext";
import {
  ConversationView,
  type ConversationComposerPresentation,
  type ConversationViewActions,
} from "./chat/conversation/ConversationView";
import {
  idleConversationChannelState,
  type ChatConversationRef,
} from "./chat/model/conversationChannel";
import {
  fixedDraftSource,
  useComposerDraftSelector,
  type ComposerDraftSource,
  type ConversationViewState,
} from "./chat/composer/conversationDraft";
import {
  isStaleChatSessionError,
  useChatApi,
  useChatRegistry,
} from "./chat/ChatProvider";
import {
  resolveWorkspaceChat,
  useWorkspaceChat,
  type WorkspaceChatState,
} from "./chat/useWorkspaceChat";
import { traceCommaNav } from "../devtools/commaNavTrace";
import { useConversation } from "./chat/conversation/useConversation";
import { useWorkspaceSkills } from "./chat/useWorkspaceSkills";
import { CommaAuthContext } from "./auth-context";
import { useOnboardingHandoff } from "./onboarding/onboardingHandoff";
import { useOnboardingOpen } from "./onboarding/onboardingPresence";
import { useOnboardingAhead } from "./onboarding/useOnboardingAhead";
import { getUserDisplayName } from "./UserAvatar";
import { RecommendationRail } from "./recommendations/RecommendationRail";

// Rail geometry updates do not change the conversation or its data sources.
export const HomeRoute = memo(function HomeRoute({
  onConnectApps,
  surfaceActive = true,
}: {
  onConnectApps?: (() => void) | undefined;
  surfaceActive?: boolean;
} = {}) {
  useEffect(() => {
    if (!import.meta.env.DEV) return undefined;
    traceCommaNav("home-mount");
    return () => {
      traceCommaNav("home-unmount");
    };
  }, []);

  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const api = useChatApi();
  const registry = useChatRegistry();
  const chat = useWorkspaceChat({ api });
  const retainedConversationTarget = registry.getHomeConversationTarget();
  const [pendingDraft, setPendingDraft] = useState("");
  const [pendingError, setPendingError] = useState<string | undefined>();
  const [pendingSend, setPendingSend] = useState(false);
  const workspaceBusy = chat.state.status === "provisioning";
  const noWorkspaceMessage = messages.home_no_workspace();

  useLayoutEffect(() => {
    if (
      chat.state.status !== "hidden" &&
      chat.state.status !== "unauthorized" &&
      chat.state.status !== "provisioning"
    ) {
      return;
    }

    const target = registry.getHomeConversationTarget();
    if (target) {
      registry.retireHomeConversationTarget(target.groupId, target.conversationId);
    }
  }, [chat.state.status, registry]);

  const sendPendingDraft = async (value: string) => {
    const text = value.trim();
    if (!text || pendingSend || workspaceBusy) return;

    setPendingSend(true);
    setPendingError(undefined);
    setPendingDraft("");
    const attempt = registry.beginAttempt();
    let sendAccepted = false;
    let observableSend = false;
    let boundary: "server" | "runtime" | "dispatch" = "server";
    const finishAnalytics = beginCommaMessageSend("home");

    try {
      await attempt.run(async (attemptApi, signal) => {
        const resolution = await resolveWorkspaceChat({
          api: attemptApi,
          locale,
          session: registry.productLease,
          signal,
        });
        if (resolution.status !== "ready") {
          throw new Error(noWorkspaceMessage);
        }

        const lease = attempt.retain(
          resolution.workspaceId,
          resolution.groupId,
          resolution.conversation.id
        );
        const pendingIds = new Set(
          lease.channel.getSnapshot().pending.map((pending) => pending.clientRequestId)
        );
        try {
          boundary = "dispatch";
          const send = lease.channel.send(text);
          const admission = acceptedSendPromise(send);
          boundary = admission ? "runtime" : "server";
          observableSend = Boolean(
            admission ||
            (send && typeof (send as PromiseLike<unknown>).then === "function")
          );
          await (admission ?? send);
          sendAccepted = true;
        } catch (error) {
          if (!isStaleChatSessionError(error) && attempt.isCurrent()) {
            sendAccepted = lease.channel
              .getSnapshot()
              .pending.some((pending) => !pendingIds.has(pending.clientRequestId));
          }
          throw error;
        }
      });
      if (observableSend && attempt.isCurrent()) finishAnalytics("accepted", boundary);
    } catch (error) {
      if (attempt.isCurrent() && !isStaleChatSessionError(error))
        finishAnalytics("failed", boundary);
      if (attempt.isCurrent() && !sendAccepted && !isStaleChatSessionError(error)) {
        setPendingDraft(text);
        setPendingError(
          error instanceof Error && error.message === noWorkspaceMessage
            ? noWorkspaceMessage
            : messages.chat_unavailable()
        );
      }
    } finally {
      const updateCurrentRoute = attempt.isCurrent();
      attempt.release();
      if (updateCurrentRoute) setPendingSend(false);
    }
  };

  const conversationTarget =
    chat.state.status === "ready"
      ? {
          conversationId: chat.state.conversation.id,
          groupId: chat.state.groupId,
          workspaceId: chat.state.workspaceId,
        }
      : chat.state.status === "loading" || chat.state.status === "error"
        ? retainedConversationTarget
        : undefined;
  const conversationSummary =
    chat.state.status === "ready"
      ? chat.state.conversation
      : retainedConversationTarget?.summary;

  return (
    <HomeConversation
      composerDisabled={pendingSend}
      conversationSummary={conversationSummary}
      conversationTarget={conversationTarget}
      onConnectApps={onConnectApps}
      onDraftChange={(draft) => {
        setPendingError(undefined);
        setPendingDraft(draft);
      }}
      onPendingDraftApplied={() => setPendingDraft("")}
      onPendingErrorClear={() => setPendingError(undefined)}
      onRetry={chat.retry}
      onSend={sendPendingDraft}
      pendingDraft={pendingDraft}
      pendingError={pendingError}
      surfaceActive={surfaceActive}
      workspaceState={chat.state}
    />
  );
});

// Both render nothing: route-level resolution feedback rides the toast stack
// (persistent, with a Retry action) and clears itself when the state recovers.
function HomeResolutionFeedback({
  onRetry,
  pendingError,
  workspaceState,
}: {
  onRetry: () => unknown;
  pendingError: string | undefined;
  workspaceState: WorkspaceChatState;
}) {
  // Workspace feedback already owns the recovery action. Do not cover it with
  // a second toast for the same failed startup send.
  const sendError =
    workspaceState.status === "loading" || workspaceState.status === "ready"
      ? pendingError
      : undefined;
  useEffect(() => {
    if (!sendError) return undefined;
    const toastId = toast.error(sendError, {
      duration: Number.POSITIVE_INFINITY,
      testId: "home-pending-error",
    });
    return () => {
      toast.dismiss(toastId);
    };
  }, [sendError]);
  return <WorkspaceResolutionFeedback onRetry={onRetry} state={workspaceState} />;
}

function WorkspaceResolutionFeedback({
  onRetry,
  state,
}: {
  onRetry: () => unknown;
  state: WorkspaceChatState;
}) {
  const messages = useCommaMessages();
  const status = state.status;
  // The first-launch onboarding covers Home and reports workspace preparation
  // itself. This feedback waits for it to close, then shows what still applies.
  const onboardingOpen = useOnboardingOpen();
  const heldBack = useRef(onboardingOpen);

  useEffect(() => {
    if (onboardingOpen) {
      heldBack.current = true;
      return undefined;
    }
    if (heldBack.current) {
      heldBack.current = false;
      // Home's few automatic retries may have run out under a long
      // onboarding while the workspace was still being prepared: ask again
      // once, so the composer the onboarding hands over can send.
      if (status === "provisioning" || status === "error") {
        onRetry();
        return undefined;
      }
    }
    const retry = { label: messages.common_retry(), onPress: onRetry };
    let toastId: string | number;
    if (status === "provisioning") {
      toastId = toast.info(messages.home_workspace_preparing(), {
        actions: [retry],
        testId: "workspace-resolution",
      });
    } else if (status === "error" || status === "hidden") {
      toastId = toast.error(
        status === "error" ? messages.chat_unavailable() : messages.home_no_workspace(),
        {
          actions: [retry],
          testId: "workspace-resolution",
        }
      );
    } else if (status === "unauthorized") {
      toastId = toast.error(messages.chat_unauthorized(), {
        duration: Number.POSITIVE_INFINITY,
        testId: "workspace-resolution",
      });
    } else {
      return undefined;
    }
    return () => {
      toast.dismiss(toastId);
    };
  }, [messages, onRetry, onboardingOpen, status]);

  return null;
}

function HomeConversation({
  composerDisabled,
  conversationSummary,
  conversationTarget,
  onConnectApps,
  onDraftChange,
  onPendingDraftApplied,
  onPendingErrorClear,
  onRetry,
  onSend,
  pendingDraft,
  pendingError,
  surfaceActive,
  workspaceState,
}: {
  composerDisabled: boolean;
  conversationSummary: CommaConversation | undefined;
  conversationTarget:
    | { conversationId: string; groupId: string; workspaceId: string }
    | undefined;
  onConnectApps?: (() => void) | undefined;
  onDraftChange: (draft: string) => void;
  onPendingDraftApplied: () => void;
  onPendingErrorClear: () => void;
  onRetry: () => unknown;
  onSend: (draft: string) => unknown;
  pendingDraft: string;
  pendingError: string | undefined;
  surfaceActive: boolean;
  workspaceState: WorkspaceChatState;
}) {
  // Greets the signed-in user by name in the briefing title (no auth in
  // isolated renders: stories and tests keep the plain greeting). Accounts
  // without a profile name still get greeted: fall back to the email local
  // part, the same identity the sidebar account row shows.
  const auth = useContext(CommaAuthContext);
  const greetingName = auth
    ? getUserDisplayName({ displayName: auth.userDisplayName, email: auth.userEmail })
    : undefined;
  // A guest Session has only its Router chat: no skills, recommendations, or Tasks.
  const guest = auth?.isGuest === true;
  // The Routines wait for the first-launch onboarding: its apps step starts
  // them once, with every app it connected (useOnboardingRoutines). Read
  // before or under it, they would start before any app is connected and
  // restart with each connection.
  const onboardingAhead = useOnboardingAhead();
  const messages = useCommaMessages();
  const api = useChatApi();
  const registry = useChatRegistry();
  const conversationId = conversationTarget?.conversationId;
  const groupId = conversationTarget?.groupId;
  const workspaceId = conversationTarget?.workspaceId;
  const conversation = useConversation(workspaceId, groupId, conversationId);
  const recommendationChannel = conversation.channel;
  const skills = useWorkspaceSkills(api, guest ? "" : (workspaceId ?? ""));
  const { openBrowser, openChat } = useChatSidebar();
  // The onboarding's "Start chatting" lands on this composer.
  const [composerFocusRequest, setComposerFocusRequest] = useState(0);
  useOnboardingHandoff(() => {
    if (surfaceActive) setComposerFocusRequest((request) => request + 1);
  });

  useLayoutEffect(() => {
    if (!workspaceId || !groupId || !conversationId) return;
    registry.rememberHomeConversationTarget(
      workspaceId,
      groupId,
      conversationId,
      conversationSummary
    );
  }, [conversationId, conversationSummary, groupId, registry, workspaceId]);

  useRegisterChatSidebarHost(surfaceActive ? conversationTarget : undefined, {
    commaCenter: true,
  });

  const handleOpenConversationRef = useCallback(
    (conversationRef: ChatConversationRef) => {
      if (
        conversationRef.kind !== "agent_task" ||
        !conversationId ||
        !groupId ||
        !workspaceId
      ) {
        return;
      }
      openChat(
        { conversationId, groupId, workspaceId },
        {
          conversationId: conversationRef.conversationId,
          groupId,
          kind: "agent_task",
          title: conversationRef.title,
          workspaceId,
        }
      );
    },
    [conversationId, groupId, openChat, workspaceId]
  );
  const handleOpenInCommaBrowser = useCallback(
    (url: string) => {
      if (!conversationId || !groupId || !workspaceId) return;
      openBrowser({ conversationId, groupId, workspaceId }, { url });
    },
    [conversationId, groupId, openBrowser, workspaceId]
  );
  const handleOpenRecommendationTask = useCallback(
    (targetConversationId: string) => {
      if (!conversationId || !groupId || !workspaceId) return;
      openChat(
        { conversationId, groupId, workspaceId },
        {
          conversationId: targetConversationId,
          groupId,
          kind: "agent_task",
          workspaceId,
        }
      );
    },
    [conversationId, groupId, openChat, workspaceId]
  );
  const handleUseRecommendationPrompt = useCallback(
    (prompt: string) => {
      onPendingErrorClear();
      if (recommendationChannel)
        appendRecommendationPrompt(recommendationChannel, prompt);
    },
    [onPendingErrorClear, recommendationChannel]
  );

  // Only whether the channel holds a draft matters here, so this surface
  // re-renders when the draft empties or fills, not on each keystroke.
  const channelHasDraft = useComposerDraftSelector(
    conversation.draftSource,
    hasDraftText
  );
  useEffect(() => {
    if (
      !conversationTarget ||
      !pendingDraft ||
      channelHasDraft ||
      !conversation.channel
    ) {
      return;
    }
    conversation.channel.setDraft(pendingDraft);
    onPendingDraftApplied();
  }, [
    conversation.channel,
    channelHasDraft,
    conversationTarget,
    onPendingDraftApplied,
    pendingDraft,
  ]);

  const isBound = Boolean(conversationTarget);
  const actions: ConversationViewActions = isBound
    ? {
        ...(conversation.channel ? { attachFiles: conversation.attachFiles } : {}),
        ...(conversation.channel && conversation.pickAttachments
          ? { pickAttachments: conversation.pickAttachments }
          : {}),
        ...(conversation.channel && conversation.previewLocalFile
          ? { previewLocalFile: conversation.previewLocalFile }
          : {}),
        discard: conversation.discard,
        refresh: conversation.refresh,
        removeAttachment: conversation.removeAttachment,
        retry: conversation.retry,
        retryAttachment: conversation.retryAttachment,
        send: (text, options) => {
          onPendingErrorClear();
          return conversation.send(text, options);
        },
        setDraft: (draft) => {
          onPendingErrorClear();
          return conversation.setDraft(draft);
        },
      }
    : {
        discard: () => undefined,
        refresh: onRetry,
        removeAttachment: () => undefined,
        retry: () => undefined,
        retryAttachment: () => undefined,
        send: onSend,
        tracksSendAnalytics: true,
        setDraft: onDraftChange,
      };
  const state: ConversationViewState = isBound
    ? conversation.state
    : idleConversationChannelState;
  // The pending draft shows until the bound channel takes it over.
  const pendingDraftSource = useMemo(
    () => fixedDraftSource(pendingDraft),
    [pendingDraft]
  );
  const draftSource =
    isBound && !(pendingDraft && !channelHasDraft)
      ? conversation.draftSource
      : pendingDraftSource;
  const workspaceSubmitBlocked =
    !isBound &&
    (workspaceState.status === "error" ||
      workspaceState.status === "provisioning" ||
      workspaceState.status === "hidden" ||
      workspaceState.status === "unauthorized");
  const composerPresentation: ConversationComposerPresentation = {
    disabled: composerDisabled,
    focusRequest: composerFocusRequest,
    feedback: (
      <HomeResolutionFeedback
        onRetry={onRetry}
        pendingError={pendingError}
        workspaceState={workspaceState}
      />
    ),
    ...(workspaceState.status === "provisioning"
      ? { placeholder: messages.home_workspace_preparing_placeholder() }
      : {}),
    submitDisabled: composerDisabled || workspaceSubmitBlocked,
  };

  return (
    <HomeConversationSurface
      actions={actions}
      api={api}
      composerPresentation={composerPresentation}
      draftSource={draftSource}
      groupId={groupId}
      // A guest has no Tasks or in-app browser; links open normally.
      onOpenConversationRef={guest ? undefined : handleOpenConversationRef}
      onOpenInCommaBrowser={guest ? undefined : handleOpenInCommaBrowser}
      recommendationsContent={
        workspaceId && conversationId && !guest ? (
          <RecommendationRail
            active={surfaceActive && !onboardingAhead}
            api={api}
            greetingName={greetingName}
            onConnectApps={onConnectApps}
            onOpenTask={handleOpenRecommendationTask}
            onOpenUrl={handleOpenInCommaBrowser}
            onUsePrompt={handleUseRecommendationPrompt}
            workspaceId={workspaceId}
          />
        ) : undefined
      }
      skills={isBound ? skills : []}
      state={state}
      surfaceActive={surfaceActive}
      tasksContent={
        guest ? undefined : workspaceState.status === "hidden" ||
          workspaceState.status === "unauthorized" ? (
          <HomeTasksRailLoading />
        ) : (
          <HomeTasksRail enabled={surfaceActive} />
        )
      }
      workspaceId={workspaceId}
    />
  );
}

function HomeConversationSurface({
  actions,
  api,
  composerPresentation,
  draftSource,
  groupId,
  onOpenConversationRef,
  onOpenInCommaBrowser,
  recommendationsContent,
  skills,
  state,
  surfaceActive,
  tasksContent,
  workspaceId,
}: {
  actions: ConversationViewActions;
  api: CommaApiClient;
  composerPresentation?: ConversationComposerPresentation | undefined;
  draftSource: ComposerDraftSource;
  groupId?: string | undefined;
  onOpenConversationRef?: ((conversationRef: ChatConversationRef) => void) | undefined;
  onOpenInCommaBrowser?: ((url: string) => void) | undefined;
  recommendationsContent?: ReactNode;
  skills: CommaSkill[];
  state: ConversationViewState;
  surfaceActive: boolean;
  tasksContent?: ReactNode;
  workspaceId?: string | undefined;
}) {
  const messages = useCommaMessages();

  return (
    <ConversationView
      actions={actions}
      api={api}
      composerPresentation={composerPresentation}
      draftSource={draftSource}
      groupId={groupId}
      leadingPanel={
        <>
          <HomeRail
            id="comma-home-greet-panel"
            label={messages.home_greet_panel()}
            name="greet"
          >
            {recommendationsContent}
          </HomeRail>
          <HomeRailCollapseHandle
            controls="comma-home-greet-panel"
            label={messages.home_greet_panel()}
            name="greet"
          />
        </>
      }
      onOpenConversationRef={onOpenConversationRef}
      onOpenInCommaBrowser={onOpenInCommaBrowser}
      skills={skills}
      state={state}
      surfaceActive={surfaceActive}
      trailingPanel={
        <>
          <HomeRailCollapseHandle
            controls="comma-home-tasks-panel"
            label={messages.tasks_title()}
            name="tasks"
          />
          <HomeRail
            id="comma-home-tasks-panel"
            label={messages.tasks_title()}
            name="tasks"
          >
            {tasksContent}
          </HomeRail>
        </>
      }
      variant="home"
      workspaceId={workspaceId}
    />
  );
}

export type HomePanelName = "greet" | "tasks";

// A Home rail column; the shared geometry folds it below its 240px floor.
export function HomeRail({
  children,
  id,
  label,
  name,
}: {
  children?: ReactNode;
  id: string;
  label: string;
  name: HomePanelName;
}) {
  const folded = useHomeRailFolded(name);

  return (
    <aside
      aria-label={label}
      className={`comma-home-rail comma-home-${name}-rail`}
      data-folded={folded}
      data-testid={`home-${name}-rail`}
      id={id}
    >
      <div className="comma-home-rail-surface">
        {children ?? (
          <>
            <h2 className="app-sr-only">{label}</h2>
            <div
              className="comma-home-card-stack"
              data-testid={`home-${name}-card-stack`}
            />
          </>
        )}
      </div>
    </aside>
  );
}

export function EmptyRoute({
  ariaLabel,
  icon,
  title,
}: {
  ariaLabel?: string;
  icon: AppIconName;
  title: string;
}) {
  return (
    <section
      className="comma-empty-route flex min-h-0 w-full min-w-0 flex-1 items-center justify-center p-5xl"
      aria-label={ariaLabel ?? title}
    >
      <div
        className="comma-empty-route-marker flex min-w-40 flex-col items-center gap-lg text-secondary"
        data-testid="route-content"
      >
        <AppIcon name={icon} className="comma-empty-route-icon text-tertiary" />
        <h1 className="m-0 text-lg font-medium text-primary">{title}</h1>
      </div>
    </section>
  );
}

function hasDraftText(draft: string) {
  return draft.length > 0;
}
