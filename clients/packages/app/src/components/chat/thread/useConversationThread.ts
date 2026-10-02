import { useCommaLocale } from "@comma/i18n/react";
import { useCallback, useLayoutEffect, useMemo, useState } from "react";
import { useReplyChainHighlight } from "./replies/useReplyChainHighlight";
import type { ConversationThreadProps } from "./conversationThreadProps";
import { useTranscriptLayout } from "./layout/useTranscriptLayout";
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
  api,
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
  messages: currentMessages,
  onDiscard,
  onOpenAttachment,
  onOpenConversationRef,
  onOutgoingAnimationComplete,
  onPreviewLocalFile,
  onRetry,
  outgoingLaunches = noOutgoingLaunches,
  revealTurnHandle,
  scrollAreaEdgeMask = CHAT_EDGE_MASK,
  showMessageActions = true,
  variant = "default",
  workspaceId,
}: ConversationThreadProps) {
  const historyScope = `${workspaceId}/${groupId}/${conversationId ?? ""}`;
  const replyChain = useReplyChainHighlight(historyScope);
  const history = useReplyHistory({
    api,
    conversationId,
    conversationKind,
    currentMessages,
    groupId,
    historyScope,
  });
  const { messages } = history;
  const locale = useCommaLocale();
  // Attachment bytes come from the same api and conversation the transcript was
  // read from, so an attachment is addressed by where it arrived rather than by
  // any locator of its own. Keep this context stable across transcript updates.
  const fileSourceContext = useMemo(
    () =>
      api && conversationId && variant !== "side-chat"
        ? { api, groupId, conversationId, open: onOpenAttachment }
        : undefined,
    [api, conversationId, groupId, onOpenAttachment, variant]
  );
  const [initialMessageIds] = useState<ReadonlySet<string> | undefined>(() =>
    variant === "side-chat"
      ? new Set(messages.map((message) => message.messageId))
      : undefined
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
    variant,
  });
  const elements = useThreadElements();
  const { follow, revealTurn, turnWindow } = useThreadNavigation({
    anchoredTails,
    api,
    assistantDraft,
    assistantResponseSlotId,
    historyReveal: history.historyReveal,
    historyScope,
    layout,
    resolveNewestTurn: elements.resolveNewestTurn,
    revealTurnHandle,
    variant,
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
    api,
    assistantDraft,
    canonicalLayout: layout.canonicalLayout,
    conversationId,
    conversationKind,
    defaultAssistantActorRole,
    follow,
    history,
    replyChain,
    revealTurn,
    turnWindow,
    variant,
  });
  const completeOutgoingAnimation = useOutgoingAnimationCompletion(
    onOutgoingAnimationComplete
  );
  const scrollbar = useThreadScrollbar({
    follow,
    latestTurnKey: layout.latestTurnKey,
    messageKey: layout.messageKey,
    readThreadGeometry: elements.readThreadGeometry,
    reconcileViewport: turnWindow.reconcileViewport,
    variant,
  });
  const resize = useMeasuredThreadResize({
    follow,
    readThreadGeometry: elements.readThreadGeometry,
    scrollbar,
    turnWindow,
  });

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
    initialMessageIds,
    initialReplyDraftId,
    isEmpty: messages.length === 0 && !assistantDraft,
    layout,
    locale,
    replies,
    resize,
    responseFeedback,
    revealVideo,
    rows: {
      api,
      groupId,
      onAnchorOutgoingTurn: follow.anchorTurn,
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
    variant,
  };
}
