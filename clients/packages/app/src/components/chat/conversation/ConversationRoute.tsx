import { useParams } from "@tanstack/react-router";
import { useCallback, useMemo } from "react";
import {
  useChatSidebar,
  useRegisterChatSidebarHost,
} from "../../chat-sidebar/ChatSidebarContext";
import { useChatApi } from "../ChatProvider";
import type { ChatConversationRef } from "../model/conversationChannel";
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
  const api = useChatApi();
  const conversation = useConversation(workspaceId, groupId, conversationId);
  const skills = useWorkspaceSkills(api, workspaceId);
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
    attachFiles,
    discard,
    pickAttachments,
    previewLocalFile,
    refresh,
    removeAttachment,
    retry,
    retryAttachment,
    send,
    setDraft,
  } = conversation;
  // Keep the actions identity stable across state emits: it flows into the
  // memoized Composer/ConversationThread boundaries via ConversationView.
  const actions: ConversationViewActions = useMemo(
    () => ({
      acceptTaskReview,
      setTaskLabels: async (labelIds) => {
        try {
          await api.setTaskLabels(groupId, conversationId, labelIds);
        } finally {
          await refresh();
        }
      },
      attachFiles,
      discard,
      ...(pickAttachments ? { pickAttachments } : {}),
      ...(previewLocalFile ? { previewLocalFile } : {}),
      refresh,
      removeAttachment,
      retry,
      retryAttachment,
      send,
      setDraft,
    }),
    [
      acceptTaskReview,
      api,
      attachFiles,
      conversationId,
      discard,
      groupId,
      pickAttachments,
      previewLocalFile,
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
      api={api}
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
