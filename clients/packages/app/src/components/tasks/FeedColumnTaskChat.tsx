import { useCall } from "@comma/core-client";
import type { ChatConversationRef } from "@comma/core/chat";
import { useCallback, useMemo } from "react";
import { useOptionalChatSidebarActions } from "../chat-sidebar/ChatSidebarContext";
import {
  ConversationView,
  type ConversationViewActions,
} from "../chat/conversation/ConversationView";
import { useConversation } from "../chat/conversation/useConversation";
import { useWorkspaceSkills } from "../chat/useWorkspaceSkills";
import { useOpenTasksFilter } from "./taskChips";

export interface FeedColumnTaskChatProps {
  conversationId: string;
  groupId: string;
  revealMessageId?: string | undefined;
  title?: string | undefined;
  workspaceId: string;
}

/**
 * Mounts Comma's real embedded Task Chat (`<ConversationView variant="rail" />`)
 * directly inside a Task Feed column when the user drills into a Task or milestone.
 */
export function FeedColumnTaskChat({
  conversationId,
  groupId,
  revealMessageId,
  title,
  workspaceId,
}: FeedColumnTaskChatProps) {
  const call = useCall();
  const conversation = useConversation(workspaceId, groupId, conversationId);
  const skills = useWorkspaceSkills(workspaceId);
  const openTasksFilter = useOpenTasksFilter();
  const sidebarActions = useOptionalChatSidebarActions();

  const { acceptTaskReview, refresh, setTaskRun, setTaskStatus } = conversation;
  const actions = useMemo<ConversationViewActions>(
    () => ({
      acceptTaskReview,
      setTaskStatus,
      setTaskRun,
      setTaskLabels: async (labelIds) => {
        try {
          await call("taskLabels.assign", {
            group: groupId,
            conversation: conversationId,
            labels: [...labelIds],
          });
        } finally {
          await refresh();
        }
      },
      attachFiles: conversation.attachFiles,
      ...(conversation.attachConversationFiles
        ? { attachConversationFiles: conversation.attachConversationFiles }
        : {}),
      discard: conversation.discard,
      ...(conversation.pickAttachments
        ? { pickAttachments: conversation.pickAttachments }
        : {}),
      ...(conversation.previewLocalFile
        ? { previewLocalFile: conversation.previewLocalFile }
        : {}),
      older: conversation.older,
      readTaskActivity: conversation.readTaskActivity,
      refresh,
      removeAttachment: conversation.removeAttachment,
      retry: conversation.retry,
      retryAttachment: conversation.retryAttachment,
      answerQuestion: conversation.answerQuestion,
      send: conversation.send,
      setDraft: conversation.setDraft,
    }),
    [
      acceptTaskReview,
      setTaskStatus,
      setTaskRun,
      call,
      conversationId,
      groupId,
      conversation.attachFiles,
      conversation.attachConversationFiles,
      conversation.discard,
      conversation.pickAttachments,
      conversation.previewLocalFile,
      conversation.older,
      conversation.readTaskActivity,
      refresh,
      conversation.removeAttachment,
      conversation.retry,
      conversation.retryAttachment,
      conversation.answerQuestion,
      conversation.send,
      conversation.setDraft,
    ]
  );

  const sidebarHost = useMemo(
    () => ({ conversationId, groupId, workspaceId }),
    [conversationId, groupId, workspaceId]
  );

  const handleOpenBrowser = useCallback(
    (url: string) => {
      sidebarActions?.openBrowser(sidebarHost, { url });
    },
    [sidebarActions, sidebarHost]
  );

  const handleOpenConversationRef = useCallback(
    (conversationRef: ChatConversationRef) => {
      sidebarActions?.openChat(sidebarHost, {
        conversationId: conversationRef.conversationId,
        groupId,
        kind: "agent_task",
        title: conversationRef.title,
        workspaceId,
      });
    },
    [groupId, sidebarActions, sidebarHost, workspaceId]
  );

  return (
    <div
      aria-label={title ? `Chat: ${title}` : "Task chat"}
      className="comma-chat-sidebar-chat comma-feed-column-chat flex size-full min-h-0 flex-1 flex-col"
      data-testid={`task-feed-column-chat-${conversationId}`}
    >
      <ConversationView
        actions={actions}
        conversationId={conversationId}
        draftSource={conversation.draftSource}
        groupId={groupId}
        live
        onOpenConversationRef={sidebarActions ? handleOpenConversationRef : undefined}
        onOpenInCommaBrowser={sidebarActions ? handleOpenBrowser : undefined}
        onOpenTasksFilter={openTasksFilter}
        revealMessageId={revealMessageId}
        skills={skills}
        state={conversation.state}
        variant="rail"
        workspaceId={workspaceId}
      />
    </div>
  );
}
