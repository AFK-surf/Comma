import { useCommaMessages } from "@comma/i18n/react";
import { ChatPanelVideoSurfaceProvider } from "@comma/ui/components/chat-panel";
import { useRef } from "react";
import { MessageReplyLines } from "./replies/MessageReplyLines";
import { ReplyThreadOverlay } from "./replies/ReplyThreadOverlay";
import { EmptyThread } from "./EmptyThread";
import { ThreadScrollViewport } from "./scroll/ThreadScrollViewport";
import {
  ThreadDefaultActorRoleContext,
  ThreadFileSourceContext,
  ThreadReplyActionsContext,
  ThreadUserAvatarContext,
} from "./threadContexts";
import { DefaultTurns } from "./turns/DefaultTurns";
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
  initialReplyDraftId,
  isEmpty,
  layout,
  locale,
  newTimestampId,
  replies,
  replyThread,
  resize,
  responseFeedback,
  revealVideo,
  rows,
  scrollAreaEdgeMask,
  scrollbar,
  showMessageActions,
  turnWindow,
}: ConversationThreadModel) {
  const messagesApi = useCommaMessages();
  const displayOnly = contentMode === "display-only";
  const columnRef = useRef<HTMLDivElement>(null);
  const turns: ThreadTurnsProps = {
    afterMessages,
    anchoredTailsFor: layout.anchoredTailsFor,
    conversationTurns: layout.conversationTurns,
    historyBoundaryMessageId,
    lastTurnKey: layout.lastTurnKey,
    newTimestampId,
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
                overlay={
                  replyThread.onExit ? (
                    <ReplyThreadOverlay
                      assistantDraft={replyThread.assistantDraft}
                      messages={replyThread.messages}
                      onExit={replyThread.onExit}
                      rows={rows}
                      selection={replyThread.selection}
                    />
                  ) : null
                }
                resize={resize}
                scrollbar={scrollbar}
              >
                <div
                  className="comma-chat-thread"
                  data-content-mode={contentMode}
                  data-comma-hidden-older-count={turnWindow.hiddenOlderCount}
                  data-comma-turn-window-start={turnWindow.visibleStart}
                  data-empty={isEmpty ? "true" : undefined}
                  inert={displayOnly ? true : undefined}
                  ref={elements.threadRef}
                >
                  <div
                    className="comma-chat-column"
                    ref={columnRef}
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
                    {isEmpty ? <EmptyThread /> : null}
                    {/* Clearing this surface's transcript does not stop its Participant. */}
                    {turnWindow.visibleTurns.length === 0
                      ? responseFeedback?.({ hasResponse: false })
                      : null}
                    <DefaultTurns
                      {...turns}
                      anchoredTails={anchoredTails}
                      locale={locale}
                      registerLatestTurnBody={elements.registerLatestTurnBody}
                      registerLatestTurnShell={elements.registerLatestTurnShell}
                      scrollEnabled={scrollbar.scrollEnabled}
                      showMessageActions={showMessageActions}
                    />
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
