import type { CommaLocale } from "@comma/i18n";
import { useCommaMessages } from "@comma/i18n/react";
import { cx } from "@comma/ui";
import { Fragment, useCallback, type ReactNode } from "react";
import {
  continuesTurnRole,
  emptyThreadTurnKey,
  type ConversationEntry,
  type ConversationTurn,
} from "../layout/conversationLayout";
import { AssistantResponseRow } from "../rows/assistant/AssistantResponseRow";
import { MessageRow } from "../rows/MessageRow";
import { ConversationTimestamp } from "./ConversationTimestamp";
import { ConversationTurnEntries } from "./ConversationTurnEntries";
import type { ThreadTurnsProps } from "./threadTurns";
import type { AnchoredTail } from "./useAnchoredTails";

export function DefaultTurns({
  afterMessages,
  anchoredTails,
  anchoredTailsFor,
  conversationTurns,
  historyBoundaryMessageId,
  lastTurnKey,
  locale,
  outgoing: { outgoingPresentationByTurnKey, outgoingTurnKeys },
  registerLatestTurnBody,
  registerLatestTurnShell,
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
  scrollEnabled,
  showMessageActions,
  visibleTurns,
}: ThreadTurnsProps & {
  anchoredTails: readonly AnchoredTail[] | undefined;
  locale: CommaLocale;
  registerLatestTurnBody: (node: HTMLElement | null) => void;
  registerLatestTurnShell: (node: HTMLElement | null) => void;
  scrollEnabled: boolean;
  showMessageActions: boolean;
}) {
  const messagesApi = useCommaMessages();
  const renderEntry = useCallback(
    (entry: ConversationEntry, turn: ConversationTurn) => {
      const row =
        entry.kind === "assistant-response" ? (
          <AssistantResponseRow
            {...rowRelationshipProps(entry.message?.messageId ?? entry.draft?.draftId)}
            api={api}
            animateEntry={false}
            chainState={replyChainState(entry.message?.messageId)}
            groupId={groupId}
            draft={entry.draft}
            message={entry.message}
            onOpenConversationRef={onOpenConversationRef}
            onPreviewLocalFile={onPreviewLocalFile}
            referenceMode="link"
            showActions={showMessageActions}
            streamId={entry.key}
            workspaceId={workspaceId}
          />
        ) : (
          <MessageRow
            {...rowRelationshipProps(entry.message.messageId)}
            api={api}
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
              entry.message.role === "user"
                ? outgoingPresentationByTurnKey.get(turn.key)
                : undefined
            }
            referenceMode="link"
            showActions={showMessageActions}
            workspaceId={workspaceId}
          />
        );
      const keyedRow = <Fragment key={entry.key}>{row}</Fragment>;
      const precedingRows: ReactNode[] = [];
      if (
        historyBoundaryMessageId &&
        entry.message?.messageId === historyBoundaryMessageId
      ) {
        precedingRows.push(
          <div className="comma-chat-history-gap" key="history-gap">
            {messagesApi.chat_reply_later_messages()}
          </div>
        );
      }
      if (
        entry.kind === "message" &&
        entry.message.role === "user" &&
        turn.timestamp?.messageId === entry.message.messageId
      ) {
        precedingRows.push(
          <ConversationTimestamp
            animate={outgoingTurnKeys.has(turn.key)}
            createdAt={turn.timestamp.createdAt}
            key={`timestamp:${turn.key}`}
            locale={locale}
            messageId={entry.message.messageId}
          />
        );
      }
      return [...precedingRows, keyedRow];
    },
    [
      api,
      groupId,
      historyBoundaryMessageId,
      locale,
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
      showMessageActions,
      workspaceId,
    ]
  );
  return (
    <>
      {visibleTurns.map((turn, turnIndex) => {
        const isCurrent = turn.key === lastTurnKey;
        return (
          <div
            className={cx(
              "comma-chat-turn-shell",
              isCurrent && scrollEnabled && "comma-chat-latest-turn"
            )}
            data-chat-turn-anchor="true"
            data-chat-latest-turn={isCurrent ? "true" : undefined}
            data-chat-outgoing-turn={
              isCurrent && outgoingTurnKeys.has(turn.key) ? "true" : undefined
            }
            data-testid={isCurrent ? "chat-latest-turn" : undefined}
            data-turn-key={turn.key}
            data-continues-role={
              continuesTurnRole(visibleTurns[turnIndex - 1], turn) ? "true" : undefined
            }
            key={turn.key}
            ref={isCurrent ? registerLatestTurnShell : null}
          >
            <div
              className="comma-chat-turn"
              data-testid={isCurrent ? "chat-current-turn" : undefined}
              data-turn-key={turn.key}
              ref={isCurrent ? registerLatestTurnBody : null}
            >
              <ConversationTurnEntries
                renderEntry={renderEntry}
                responseFeedback={isCurrent ? responseFeedback : undefined}
                turn={turn}
              />
              {anchoredTailsFor(turn.key)}
              {isCurrent ? afterMessages : null}
            </div>
          </div>
        );
      })}
      {conversationTurns.length === 0 && (afterMessages ?? anchoredTails) ? (
        <div
          className="comma-chat-turn"
          data-testid="chat-current-turn"
          data-turn-key={emptyThreadTurnKey}
        >
          {anchoredTailsFor(emptyThreadTurnKey)}
          {afterMessages}
        </div>
      ) : null}
    </>
  );
}
