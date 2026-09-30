import { useCommaMessages } from "@comma/i18n/react";
import { ChatPanelVideoSurfaceProvider } from "@comma/ui";
import { useRef } from "react";
import { MessageReplyLines } from "./replies/MessageReplyLines";
import { EmptyThread } from "./EmptyThread";
import { ThreadScrollViewport } from "./scroll/ThreadScrollViewport";
import {
  ThreadDefaultActorRoleContext,
  ThreadFileSourceContext,
  ThreadReplyActionsContext,
  ThreadUserAvatarContext,
} from "./threadContexts";
import { DefaultTurns } from "./turns/DefaultTurns";
import { SideChatTurns } from "./turns/SideChatTurns";
import type { ThreadTurnsProps } from "./turns/threadTurns";
import type { ConversationThreadModel } from "./useConversationThread";

export function ConversationThreadView({
  afterMessages,
  anchoredTails,
  contentMode,
  defaultAssistantActorRole,
  elements,
  fileSourceContext,
  follow,
  freezeContentInlineSizeOnWindowResize,
  historyBoundaryMessageId,
  initialMessageIds,
  initialReplyDraftId,
  isEmpty,
  layout,
  locale,
  replies,
  resize,
  responseFeedback,
  revealVideo,
  rows,
  scrollAreaEdgeMask,
  scrollbar,
  showMessageActions,
  turnWindow,
  variant,
}: ConversationThreadModel) {
  const messagesApi = useCommaMessages();
  const displayOnly = contentMode === "display-only";
  const columnRef = useRef<HTMLDivElement>(null);
  const showExitingEmpty =
    variant === "side-chat" &&
    layout.outgoing.outgoingPresentations.some(
      (presentation) => presentation.launch.startedFromEmpty
    );
  // A brand-new side chat shows its floating empty card instead of a
  // transcript. The thread says so itself: the rules that restyle the zone and
  // the column for that card used to find it with `:has()`, and an ancestor
  // that `:has()` watches restyles its whole subtree on every node the
  // transcript gains or loses — on every surface, for a card only one shows.
  const showsEmptyCard = variant === "side-chat" && isEmpty;
  const turns: ThreadTurnsProps = {
    afterMessages,
    anchoredTailsFor: layout.anchoredTailsFor,
    conversationTurns: layout.conversationTurns,
    historyBoundaryMessageId,
    lastTurnKey: layout.lastTurnKey,
    outgoing: layout.outgoing,
    replyChainState: replies.replyChainState,
    responseFeedback,
    rowRelationshipProps: replies.rowRelationshipProps,
    rows,
    visibleTurns: turnWindow.visibleTurns,
  };
  return (
    <ThreadFileSourceContext.Provider value={fileSourceContext}>
      <ThreadDefaultActorRoleContext.Provider value={defaultAssistantActorRole}>
        <ThreadReplyActionsContext.Provider value={replies.replyActions}>
          <ThreadUserAvatarContext.Provider value={replies.userAvatar}>
            <ChatPanelVideoSurfaceProvider
              returnLabel={messagesApi.chat_video_jump_to_message()}
              revealPlayer={revealVideo}
            >
              <ThreadScrollViewport
                contentResizeTarget={elements.latestTurnBody}
                displayOnly={displayOnly}
                edgeMask={scrollAreaEdgeMask}
                follow={follow}
                freezeContentInlineSizeOnWindowResize={
                  freezeContentInlineSizeOnWindowResize
                }
                locale={locale}
                resize={resize}
                scrollbar={scrollbar}
                showsEmptyCard={showsEmptyCard}
              >
                <div
                  className="comma-chat-thread"
                  data-content-mode={contentMode}
                  data-comma-hidden-older-count={turnWindow.hiddenOlderCount}
                  data-comma-turn-window-start={turnWindow.visibleStart}
                  data-empty={variant !== "side-chat" && isEmpty ? "true" : undefined}
                  inert={displayOnly ? true : undefined}
                  ref={elements.threadRef}
                >
                  <div
                    className="comma-chat-column"
                    ref={columnRef}
                    data-empty-card={showsEmptyCard ? "true" : undefined}
                    data-reply-chain-highlight={replies.highlightedChain}
                  >
                    <MessageReplyLines
                      columnRef={columnRef}
                      initialDraftId={initialReplyDraftId}
                      replies={replies.relationships.replies}
                      chainState={replies.replyChainState}
                    />
                    {turnWindow.hasOlder ? (
                      <div aria-hidden className="h-0" data-comma-load-older="" />
                    ) : null}
                    {isEmpty ? <EmptyThread variant={variant} /> : null}
                    {/* Clearing this surface's transcript does not stop its Participant. */}
                    {turnWindow.visibleTurns.length === 0
                      ? responseFeedback?.({ hasResponse: false })
                      : null}
                    {showExitingEmpty ? (
                      <div className="comma-side-chat-empty-exit-layer" aria-hidden>
                        <EmptyThread exiting variant="side-chat" />
                      </div>
                    ) : null}
                    {variant === "side-chat" ? (
                      <SideChatTurns
                        {...turns}
                        initialMessageIds={initialMessageIds}
                        registerNewestTurnAnchor={elements.registerNewestTurnAnchor}
                      />
                    ) : (
                      <DefaultTurns
                        {...turns}
                        anchoredTails={anchoredTails}
                        locale={locale}
                        registerLatestTurnBody={elements.registerLatestTurnBody}
                        registerLatestTurnShell={elements.registerLatestTurnShell}
                        scrollEnabled={scrollbar.scrollEnabled}
                        showMessageActions={showMessageActions}
                      />
                    )}
                  </div>
                </div>
              </ThreadScrollViewport>
            </ChatPanelVideoSurfaceProvider>
          </ThreadUserAvatarContext.Provider>
        </ThreadReplyActionsContext.Provider>
      </ThreadDefaultActorRoleContext.Provider>
    </ThreadFileSourceContext.Provider>
  );
}
