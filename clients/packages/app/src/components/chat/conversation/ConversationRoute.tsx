import { useCall } from "@comma/core-client";
import { useParams } from "@tanstack/react-router";
import { useCallback, useMemo } from "react";
import {
  useChatSidebar,
  useRegisterChatSidebarHost,
} from "../../chat-sidebar/ChatSidebarContext";
import type { ChatConversationRef } from "@comma/core/chat";
import { useConversation } from "./useConversation";
import { ConversationView, type ConversationViewActions } from "./ConversationView";
import { useWorkspaceSkills } from "../useWorkspaceSkills";
import { useOpenTasksFilter } from "../../tasks/taskChips";

export function ConversationRoute() {
  const params = useParams({ strict: false }) as {
    workspaceId?: string;
    groupId?: string;
    conversationId?: string;
  };
  const workspaceId = params.workspaceId ?? "";
  const groupId = params.groupId ?? "";
  const conversationId = params.conversationId ?? "";
  const call = useCall();
  const conversation = useConversation(workspaceId, groupId, conversationId);
  const skills = useWorkspaceSkills(workspaceId);
  const openTasksFilter = useOpenTasksFilter();
  const { openBrowser, openChat } = useChatSidebar();
  const host = { conversationId, groupId, workspaceId };

  useRegisterChatSidebarHost(host);

  const handleOpenConversationRef = useCallback(
    (conversationRef: ChatConversationRef) => {
      if (conversationRef.kind !== "agent_task") return;
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
      openBrowser({ conversationId, groupId, workspaceId }, { url });
    },
    [conversationId, groupId, openBrowser, workspaceId]
  );

  const {
    acceptTaskReview,
    setTaskStatus,
    attachFiles,
    discard,
    pickAttachments,
    previewLocalFile,
    readTaskActivity,
    refresh,
    removeAttachment,
    retry,
    retryAttachment,
    answerQuestion,
    send,
    setDraft,
  } = conversation;
  // Keep the actions identity stable across state emits: it flows into the
  // memoized Composer/ConversationThread boundaries via ConversationView.
  const actions: ConversationViewActions = useMemo(
    () => ({
      acceptTaskReview,
      setTaskStatus,
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
      attachFiles,
      discard,
      ...(pickAttachments ? { pickAttachments } : {}),
      ...(previewLocalFile ? { previewLocalFile } : {}),
      readTaskActivity,
      refresh,
      removeAttachment,
      retry,
      retryAttachment,
      answerQuestion,
      send,
      setDraft,
    }),
    [
      answerQuestion,
      acceptTaskReview,
      setTaskStatus,
      call,
      attachFiles,
      conversationId,
      discard,
      groupId,
      pickAttachments,
      previewLocalFile,
      readTaskActivity,
      refresh,
      removeAttachment,
      retry,
      retryAttachment,
      send,
      setDraft,
    ]
  );

  return (
    <ConversationView
      actions={actions}
      live
      conversationId={conversationId}
      draftSource={conversation.draftSource}
      onOpenConversationRef={handleOpenConversationRef}
      onOpenInCommaBrowser={handleOpenInCommaBrowser}
      onOpenTasksFilter={openTasksFilter}
      groupId={groupId}
      skills={skills}
      state={conversation.state}
      workspaceId={workspaceId}
    />
  );
}
