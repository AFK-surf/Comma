import type { AgentRequest } from "@comma/core-client";
import type { CommaTaskLabelCatalog } from "@comma/core/api-schemas";
import type { ChatMessage } from "@comma/core/chat";
import { useCommaMessages } from "@comma/i18n/react";
import { uiClock } from "@comma/ui/clock";
import { memo, useCallback, useEffect, useRef, useState, type RefObject } from "react";
import { useTaskArchive } from "../../tasks/useTaskArchive";
import type { InlineTaskLinkAdapter } from "../thread/inline/MessageInlineElements";
import { ChatTaskPanel, type ChatTaskOpenTarget } from "./ChatTaskPanel";
import {
  usePanelTaskDismissal,
  useRefreshPanelDismissalsWhenAttended,
} from "./chatTaskPanelDismissals";
import { useChatAttentionCards, type ChatAttentionCard } from "./useChatAttentionCards";
import { useChatCreatedTasks, type ChatCreatedTask } from "./useChatCreatedTasks";

export type ChatTaskDockReplyOptions = {
  advance?: boolean | undefined;
  progress?: { index: number; total: number } | undefined;
};

/** A run of pending cards answered one after another in their reply threads. */
type CardRun = {
  cardId: string;
  /** The card's deadline; a card gone after it expired, not answered. */
  expiresAt: number | null;
  index: number;
  rootId: string;
  total: number;
};

/** How long an answered card stays up before the next one takes its place. */
const CARD_RUN_HANDOFF_MS = 700;

/**
 * Binds this conversation's pending confirmation cards and created Tasks to
 * the dual-bubble dock above the composer.
 *
 * It is its own memo boundary on purpose. The dock follows the Inbox
 * projection, the Task summary cache, acknowledgement stores, and pending
 * confirmation sources, while the conversation surface renders on every
 * streamed delta. Kept apart, a Task or card moving on renders the dock alone,
 * and a reply streaming in renders everything but the dock.
 */
export const ChatTaskDock = memo(function ChatTaskDock({
  closeReplyThread,
  conversationId,
  groupId,
  labelCatalog,
  messages,
  openReplyThread,
  replyRootId,
  replyTouched,
  requests,
  revealTurnHandle,
  taskLinkAdapter,
  workspaceId,
}: {
  closeReplyThread: () => void;
  conversationId?: string | undefined;
  groupId: string;
  labelCatalog?: CommaTaskLabelCatalog | undefined;
  messages: readonly ChatMessage[];
  /** Opens the reply thread of a message in this conversation; returns its root. */
  openReplyThread: (
    messageId: string,
    options?: ChatTaskDockReplyOptions
  ) => string | undefined;
  /** Root of the reply thread open now, if any. */
  replyRootId: string | undefined;
  /** The reader has acted in the open reply thread since it opened. */
  replyTouched: boolean;
  requests?: readonly AgentRequest[] | undefined;
  revealTurnHandle: RefObject<
    ((turnKey: string, highlightMessageId?: string) => void) | null
  >;
  /** How this surface opens a Task; shared with the transcript's Task chips. */
  taskLinkAdapter: InlineTaskLinkAdapter;
  workspaceId: string;
}) {
  const copy = useCommaMessages();
  const items = useChatCreatedTasks({ groupId, messages });
  const attentionCards = useChatAttentionCards({
    conversationId,
    labelCatalog,
    messages,
    requests,
  });
  const archive = useTaskArchive();
  const dismissPanelTask = usePanelTaskDismissal();
  // A Dismiss made on another device clears its row here once the reader is back.
  useRefreshPanelDismissalsWhenAttended();

  const handleArchive = useCallback(
    (task: ChatCreatedTask) =>
      archive(
        { group_id: groupId, id: task.conversationId, updated_at: task.archiveVersion },
        "archive"
      ),
    [archive, groupId]
  );
  const handleDismiss = useCallback(
    (task: ChatCreatedTask) => dismissPanelTask(task.conversationId, task.version),
    [dismissPanelTask]
  );
  const handleOpen = useCallback(
    (task: ChatCreatedTask, target: ChatTaskOpenTarget) => {
      const title = task.title || copy.chat_ref_task();
      const open =
        target === "page" ? taskLinkAdapter.openTask : taskLinkAdapter.openInSidebar;
      open?.({
        ariaLabel: copy.tasks_open({ title }),
        conversationId: task.conversationId,
        groupId,
        title,
        workspaceId,
      });
    },
    [copy, groupId, taskLinkAdapter, workspaceId]
  );
  // Jumping to a settled Task's announcement is also its acknowledgement; a
  // running Task stays docked until it settles.
  const handleReveal = useCallback(
    (task: ChatCreatedTask) => {
      if (task.turnKey !== undefined) {
        revealTurnHandle.current?.(task.turnKey, task.messageId);
      }
      // A running Task or a standing Loop stays docked, so revealing it dismisses nothing.
      if (task.statusBucket !== "in_progress" && task.statusBucket !== "loops")
        dismissPanelTask(task.conversationId, task.version);
    },
    [dismissPanelTask, revealTurnHandle]
  );
  // Answering a card enters its message's reply thread: the card and its
  // context gather above the composer, the transcript blurred behind them.
  // With more cards pending, answering one hands over to the next until none
  // is left; leaving the thread ends the run.
  const [run, setRun] = useState<CardRun>();
  const cardsRef = useRef(attentionCards);
  useEffect(() => {
    cardsRef.current = attentionCards;
  }, [attentionCards]);
  const handleRevealCard = useCallback(
    (card: ChatAttentionCard) => {
      if (card.messageId === undefined) {
        setRun(undefined);
        if (card.turnKey !== undefined) revealTurnHandle.current?.(card.turnKey);
        return;
      }
      const total = cardsRef.current.filter(
        (item) => item.messageId !== undefined
      ).length;
      const progress = total > 1 ? { index: 1, total } : undefined;
      const rootId = openReplyThread(card.messageId, { progress });
      if (rootId === undefined) {
        // No thread to answer in (the chat is read-only, or the message is
        // still sending): show the card where it is in the transcript.
        setRun(undefined);
        if (card.turnKey !== undefined) {
          revealTurnHandle.current?.(card.turnKey, card.messageId);
        }
        return;
      }
      setRun(
        progress
          ? { cardId: card.id, expiresAt: card.expiresAt, index: 1, rootId, total }
          : undefined
      );
    },
    [openReplyThread, revealTurnHandle]
  );
  const runCardAnswered =
    run !== undefined && !attentionCards.some((card) => card.id === run.cardId);
  useEffect(() => {
    if (!run) return;
    if (replyRootId !== run.rootId) {
      setRun(undefined);
      return;
    }
    if (!runCardAnswered) return;
    // Only an answer given here moves the run on. A card that expired, or was
    // answered on another device, ends the run and leaves its thread open.
    if (!replyTouched || (run.expiresAt !== null && uiClock.now() >= run.expiresAt)) {
      setRun(undefined);
      return;
    }
    // Presentation timing: the answered card shows its sent state before the
    // next one slides in.
    return uiClock.after(CARD_RUN_HANDOFF_MS, () => {
      const remaining = cardsRef.current.filter((card) => card.messageId !== undefined);
      const next = remaining[0];
      const rootId =
        next?.messageId !== undefined
          ? openReplyThread(next.messageId, {
              advance: true,
              progress: { index: run.index + 1, total: run.index + remaining.length },
            })
          : undefined;
      if (next === undefined || rootId === undefined) {
        setRun(undefined);
        if (next === undefined) closeReplyThread();
        return;
      }
      setRun({
        cardId: next.id,
        expiresAt: next.expiresAt,
        index: run.index + 1,
        rootId,
        total: run.index + remaining.length,
      });
    });
  }, [
    closeReplyThread,
    openReplyThread,
    replyRootId,
    replyTouched,
    run,
    runCardAnswered,
  ]);

  return (
    <ChatTaskPanel
      attentionCards={attentionCards}
      items={items}
      onArchive={handleArchive}
      onDismiss={handleDismiss}
      onOpen={handleOpen}
      onReveal={handleReveal}
      onRevealCard={handleRevealCard}
    />
  );
});
