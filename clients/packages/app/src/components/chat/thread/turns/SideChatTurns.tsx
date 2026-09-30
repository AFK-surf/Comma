import { useCommaMessages } from "@comma/i18n/react";
import { cx } from "@comma/ui";
import { useCallback } from "react";
import { conversationMessageTurnKey as messageTurnKey } from "../../model/visibleReplyPresentation";
import {
  continuesTurnRole,
  emptyThreadTurnKey,
  type ConversationEntry,
} from "../layout/conversationLayout";
import { AssistantResponseRow } from "../rows/assistant/AssistantResponseRow";
import { MessageRow } from "../rows/MessageRow";
import { ConversationTurnEntries } from "./ConversationTurnEntries";
import type { ThreadTurnsProps } from "./threadTurns";

export function SideChatTurns({
  afterMessages,
  anchoredTailsFor,
  conversationTurns,
  historyBoundaryMessageId,
  initialMessageIds,
  lastTurnKey,
  outgoing: { outgoingPresentationByTurnKey, outgoingTurnKeys },
  registerNewestTurnAnchor,
  replyChainState,
  responseFeedback,
  rowRelationshipProps,
  rows: {
    api,
    groupId,
    onAnchorOutgoingTurn,
    onDiscard,
    onOpenConversationRef,
    onOutgoingAnimationComplete,
    onPreviewLocalFile,
    onRetry,
    workspaceId,
  },
  visibleTurns,
}: ThreadTurnsProps & {
  initialMessageIds: ReadonlySet<string> | undefined;
  registerNewestTurnAnchor: (node: HTMLElement | null) => void;
}) {
  const messagesApi = useCommaMessages();
  const renderEntry = useCallback(
    (entry: ConversationEntry) => {
      const entryTurnKey =
        entry.kind === "message" && entry.message.role === "user"
          ? messageTurnKey(entry.message)
          : undefined;
      const hidesOutgoingDestination =
        entryTurnKey !== undefined && outgoingTurnKeys.has(entryTurnKey);
      const row = (
        <div
          className="comma-side-chat-message-slot"
          data-outgoing-entry={hidesOutgoingDestination ? "true" : undefined}
          key={entry.key}
        >
          <div
            className={cx(
              "comma-side-chat-message-slot-inner",
              entry.kind === "assistant-response" &&
                "comma-side-chat-assistant-slot-inner"
            )}
          >
            {entry.kind === "assistant-response" ? (
              <AssistantResponseRow
                {...rowRelationshipProps(
                  entry.message?.messageId ?? entry.draft?.draftId
                )}
                api={api}
                animateEntry={Boolean(
                  entry.message && !initialMessageIds?.has(entry.message.messageId)
                )}
                chainState={replyChainState(entry.message?.messageId)}
                groupId={groupId}
                draft={entry.draft}
                message={entry.message}
                onOpenConversationRef={onOpenConversationRef}
                onPreviewLocalFile={onPreviewLocalFile}
                referenceMode="static"
                showActions={false}
                streamId={entry.key}
                variant="side-chat"
                workspaceId={workspaceId}
              />
            ) : (
              <MessageRow
                {...rowRelationshipProps(entry.message.messageId)}
                api={api}
                animateAssistantEntry={
                  entry.message.role === "assistant" &&
                  !initialMessageIds?.has(entry.message.messageId)
                }
                chainState={replyChainState(entry.message.messageId)}
                groupId={groupId}
                message={entry.message}
                onAnchorOutgoingTurn={onAnchorOutgoingTurn}
                onDiscard={onDiscard}
                onOutgoingAnimationComplete={onOutgoingAnimationComplete}
                onOpenConversationRef={onOpenConversationRef}
                onPreviewLocalFile={onPreviewLocalFile}
                onRetry={onRetry}
                outgoingPresentation={
                  entryTurnKey
                    ? outgoingPresentationByTurnKey.get(entryTurnKey)
                    : undefined
                }
                referenceMode="static"
                showActions={false}
                variant="side-chat"
                workspaceId={workspaceId}
              />
            )}
          </div>
        </div>
      );
      return [
        historyBoundaryMessageId &&
        entry.message?.messageId === historyBoundaryMessageId ? (
          <div className="comma-chat-history-gap" key="history-gap">
            {messagesApi.chat_reply_later_messages()}
          </div>
        ) : null,
        row,
      ];
    },
    [
      api,
      groupId,
      historyBoundaryMessageId,
      initialMessageIds,
      messagesApi,
      onAnchorOutgoingTurn,
      onDiscard,
      onOpenConversationRef,
      onOutgoingAnimationComplete,
      onPreviewLocalFile,
      onRetry,
      outgoingPresentationByTurnKey,
      outgoingTurnKeys,
      replyChainState,
      rowRelationshipProps,
      workspaceId,
    ]
  );
  return (
    <>
      {visibleTurns.map((turn, turnIndex) => {
        const isCurrent = turn.key === lastTurnKey;
        return (
          <div
            className="comma-chat-turn comma-side-chat-turn"
            data-chat-turn-anchor="true"
            data-chat-latest-turn={isCurrent ? "true" : undefined}
            data-testid={isCurrent ? "chat-current-turn" : undefined}
            data-turn-key={turn.key}
            data-continues-role={
              continuesTurnRole(visibleTurns[turnIndex - 1], turn) ? "true" : undefined
            }
            key={turn.key}
            ref={isCurrent ? registerNewestTurnAnchor : null}
          >
            <ConversationTurnEntries
              renderEntry={renderEntry}
              responseFeedback={isCurrent ? responseFeedback : undefined}
              turn={turn}
            />
            {anchoredTailsFor(turn.key)}
            {isCurrent ? afterMessages : null}
          </div>
        );
      })}
      {conversationTurns.length === 0 ? (
        <>
          {anchoredTailsFor(emptyThreadTurnKey)}
          {afterMessages}
        </>
      ) : null}
    </>
  );
}
