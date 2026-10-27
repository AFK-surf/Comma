import { useCall } from "@comma/core-client";
import { useParams } from "@tanstack/react-router";
import { useCallback, useMemo } from "react";
import {
  useChatSidebarActions,
  useRegisterChatSidebarHost,
} from "../../chat-sidebar/ChatSidebarContext";
import type { ChatConversationRef } from "@comma/core/chat";
import { useConversation } from "./useConversation";
import { ConversationView, type ConversationViewActions } from "./ConversationView";
import { useWorkspaceSkills } from "../useWorkspaceSkills";
import { useOpenTasksFilter } from "../../tasks/taskChips";
import { TaskSequenceNavigator } from "../../tasks/TaskSequenceNavigator";

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
  const { openBrowser, openChat } = useChatSidebarActions();
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
    setTaskRun,
    attachFiles,
    attachConversationFiles,
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
      attachFiles,
      ...(attachConversationFiles ? { attachConversationFiles } : {}),
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
      setTaskRun,
      call,
      attachFiles,
      attachConversationFiles,
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

  // A stable element keeps the memoized view from rendering for it.
  const sequenceNavigator = useMemo(
    () => <TaskSequenceNavigator conversationId={conversationId} />,
    [conversationId]
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
      headerTrailing={sequenceNavigator}
      skills={skills}
      state={conversation.state}
      workspaceId={workspaceId}
    />
  );
}
