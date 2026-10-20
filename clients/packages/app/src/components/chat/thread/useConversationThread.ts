import { useCommaLocale } from "@comma/i18n/react";
import { useCallback, useEffect, useLayoutEffect, useMemo, useState } from "react";
import { useReplyChainHighlight } from "./replies/useReplyChainHighlight";
import type { ConversationThreadProps } from "./conversationThreadProps";
import { newestAgentTimestampId } from "./layout/conversationLayout";
import { useTranscriptLayout } from "./layout/useTranscriptLayout";
import { useAwayNews } from "./useAwayNews";
import { useThreadNavigation } from "./navigation/useThreadNavigation";
import {
  sameNumberStringMap,
  type ChatOutgoingLaunch,
} from "./outgoing/outgoingPresentation";
import { useOutgoingAnimationCompletion } from "./outgoing/useOutgoingAnimationCompletion";
import { useReplyHistory } from "./replies/useReplyHistory";
import { useThreadRelationships } from "./replies/useThreadRelationships";
import { useMeasuredThreadResize } from "./scroll/useMeasuredThreadResize";
import { useThreadScrollbar } from "./scroll/useThreadScrollbar";
import { useThreadElements } from "./scroll/useThreadElements";

const CHAT_EDGE_MASK = { endSize: 24, startSize: 16 } as const;
const noOutgoingLaunches: readonly ChatOutgoingLaunch[] = [];

export type ConversationThreadModel = ReturnType<typeof useConversationThread>;

/** Runs the thread's hooks in the order their effects must run. */
export function useConversationThread({
  assistantDraft,
  assistantResponseSlotId = "conversation",
  afterMessages,
  anchoredTails,
  responseFeedback,
  conversationId,
  conversationKind = "user_chat",
  contentMode = "interactive",
  defaultAssistantActorRole,
  freezeContentInlineSizeOnWindowResize = false,
  groupId,
  live = false,
  messages: currentMessages,
  onDiscard,
  onOpenAttachment,
  onOpenConversationRef,
  onOutgoingAnimationComplete,
  onPreviewLocalFile,
  onExitReplyThread,
  onRetry,
  outgoingLaunches = noOutgoingLaunches,
  replyThread,
  revealMessageHandle,
  revealTurnHandle,
  scrollAreaEdgeMask = CHAT_EDGE_MASK,
  showMessageActions = true,
  workspaceId,
}: ConversationThreadProps) {
  const historyScope = `${workspaceId}/${groupId}/${conversationId ?? ""}`;
  const replyChain = useReplyChainHighlight(historyScope);
  const history = useReplyHistory({
    conversationId,
    conversationKind,
    currentMessages,
    groupId,
    historyScope,
    live,
  });
  const { messages } = history;
  const locale = useCommaLocale();
  // Attachment bytes come from the conversation the transcript was read from, so an attachment is addressed by where it arrived rather than by
  // any locator of its own. Keep this context stable across transcript updates.
  const fileSourceContext = useMemo(
    () =>
      live && conversationId
        ? { groupId, conversationId, open: onOpenAttachment }
        : undefined,
    [conversationId, groupId, live, onOpenAttachment]
  );
  const [initialReplyDraftId] = useState(assistantDraft?.draftId);
  const [outgoingMatches, setOutgoingMatches] = useState<ReadonlyMap<number, string>>(
    () => new Map()
  );
  const layout = useTranscriptLayout({
    anchoredTails,
    assistantDraft,
    assistantResponseSlotId,
    messages,
    outgoingLaunches,
    outgoingMatches,
  });
  // Home marks its newest timestamp "New" while it heads what the agent sent
  // on its own while the window was not in front; a Task transcript or a
  // static preview has no such news.
  const draftId = assistantDraft?.draftId;
  const awayNews = useAwayNews(currentMessages, draftId);
  const { canonicalLayout, draftTimestamp } = layout;
  const newTimestampId = useMemo(
    () =>
      live && conversationKind === "user_chat"
        ? newestAgentTimestampId(
            canonicalLayout.turns,
            draftId === undefined
              ? undefined
              : { id: draftId, timestamped: Boolean(draftTimestamp) },
            (id) => awayNews.has(id)
          )
        : undefined,
    [awayNews, canonicalLayout, conversationKind, draftId, draftTimestamp, live]
  );
  const elements = useThreadElements();
  const { follow, revealTurn, turnWindow } = useThreadNavigation({
    anchoredTails,
    assistantDraft,
    assistantResponseSlotId,
    historyReveal: history.historyReveal,
    historyScope,
    layout,
    resolveNewestTurn: elements.resolveNewestTurn,
    revealTurnHandle,
  });
  // A floating video jumps back the way a reply jump does: the thread stops
  // following, scrolls the video into reading position, and focuses its message.
  const { revealElement } = follow;
  const revealVideo = useCallback(
    (player: HTMLElement) => {
      revealElement(
        player.closest<HTMLElement>("article[data-message-id]") ?? player,
        player,
        () => undefined
      );
    },
    [revealElement]
  );
  const replies = useThreadRelationships({
    assistantDraft,
    canonicalLayout: layout.canonicalLayout,
    conversationId,
    conversationKind,
    defaultAssistantActorRole,
    draftTimestamped: Boolean(layout.draftTimestamp),
    follow,
    history,
    live,
    replyChain,
    revealTurn,
    turnWindow,
  });
  // A message in the transcript is revealed in place; an older one is read
  // first, the way a reply's quoted message is.
  const { loadReplyTarget } = history;
  useEffect(() => {
    if (!revealMessageHandle) return undefined;
    revealMessageHandle.current = (messageId) => {
      const turn = canonicalLayout.turns.find((candidate) =>
        candidate.entries.some((entry) => entry.message?.messageId === messageId)
      );
      if (turn)
        revealTurn(turn.key, messageId, { focusMessage: true, highlightInPlace: true });
      // A message the server no longer has leaves the transcript where it is.
      else void loadReplyTarget(messageId).catch(() => undefined);
    };
    return () => {
      revealMessageHandle.current = null;
    };
  }, [canonicalLayout, loadReplyTarget, revealMessageHandle, revealTurn]);
  const completeOutgoingAnimation = useOutgoingAnimationCompletion(
    onOutgoingAnimationComplete
  );
  const scrollbar = useThreadScrollbar({
    follow,
    latestTurnKey: layout.lastTurnKey,
    messageKey: layout.messageKey,
    presentingOutgoing: layout.outgoing.outgoingPresentations.length > 0,
    readThreadGeometry: elements.readThreadGeometry,
    reconcileViewport: turnWindow.reconcileViewport,
  });
  const resize = useMeasuredThreadResize({
    follow,
    readThreadGeometry: elements.readThreadGeometry,
    scrollbar,
    turnWindow,
  });

  const { anchorTurn } = follow;
  const { decideForOutgoingLaunch } = scrollbar;
  // A launching message settles whether the thread scrolls before anchoring its turn,
  // so the flight measures the layout it lands in.
  const anchorOutgoingTurn = useCallback(
    (turnKey: string) => {
      decideForOutgoingLaunch();
      anchorTurn(turnKey);
    },
    [anchorTurn, decideForOutgoingLaunch]
  );

  const { outgoingPresentations } = layout.outgoing;
  useLayoutEffect(() => {
    const next = new Map(
      outgoingPresentations.map((presentation) => [
        presentation.launch.id,
        presentation.turnKey,
      ])
    );
    setOutgoingMatches((current) =>
      sameNumberStringMap(current, next) ? current : next
    );
  }, [outgoingPresentations]);

  return {
    afterMessages,
    anchoredTails,
    contentMode,
    defaultAssistantActorRole,
    elements,
    fileSourceContext,
    follow,
    freezeContentInlineSizeOnWindowResize,
    historyBoundaryMessageId: history.historyBoundaryMessageId,
    initialReplyDraftId,
    isEmpty: messages.length === 0 && !assistantDraft,
    layout,
    locale,
    newTimestampId,
    replies,
    replyThread: {
      assistantDraft,
      messages: history.messages,
      onExit: onExitReplyThread,
      selection: replyThread,
    },
    resize,
    responseFeedback,
    revealVideo,
    rows: {
      groupId,
      live,
      onAnchorOutgoingTurn: anchorOutgoingTurn,
      onDiscard,
      onOpenConversationRef,
      onOutgoingAnimationComplete: completeOutgoingAnimation,
      onPreviewLocalFile,
      onRetry,
      workspaceId,
    },
    scrollAreaEdgeMask,
    scrollbar,
    showMessageActions,
    turnWindow,
  };
}
