import { useCall, useTopic } from "@comma/core-client";
import { useCommaMessages } from "@comma/i18n/react";
import { Button } from "@comma/ui/components/Button";
import { useNavigate, useParams, useSearch } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo } from "react";
import {
  useChatSidebarActions,
  useRegisterChatSidebarHost,
} from "../../chat-sidebar/ChatSidebarContext";
import { isMailPreviewLink, isStillfailChatLink } from "../../links/useLinkPreview";
import {
  useActiveWorkspace,
  useActiveWorkspaceId,
  useSelectWorkspace,
} from "../../activeWorkspace";
import type { ChatConversationRef } from "@comma/core/chat";
import { useConversation } from "./useConversation";
import { ConversationView, type ConversationViewActions } from "./ConversationView";
import { useWorkspaceSkills } from "../useWorkspaceSkills";
import { useOpenTasksFilter } from "../../tasks/taskChips";
import { TaskSequenceNavigator } from "../../tasks/TaskSequenceNavigator";
import { TaskMessageFind } from "../../search/TaskMessageFind";

export function ConversationRoute() {
  const params = useParams({ strict: false }) as {
    workspaceId?: string;
    groupId?: string;
    conversationId?: string;
  };
  const workspaceId = params.workspaceId ?? "";
  const groupId = params.groupId ?? "";
  const conversationId = params.conversationId ?? "";
  // Opened from a search: the address keeps what was searched and the matching Message shown.
  const { message: foundMessageId, q: foundQuery } = useSearch({ strict: false }) as {
    message?: string;
    q?: string;
  };
  const navigate = useNavigate();
  const showFoundMessage = useCallback(
    (messageId: string) => {
      void navigate({
        to: ".",
        search: (previous: Record<string, unknown>) => ({
          ...previous,
          message: messageId,
        }),
        replace: true,
      });
    },
    [navigate]
  );
  const closeFind = useCallback(() => {
    void navigate({ to: ".", search: {}, replace: true });
  }, [navigate]);
  const call = useCall();
  const activeWorkspaceId = useActiveWorkspaceId();
  const needsWorkspaceSync = Boolean(
    workspaceId && activeWorkspaceId && activeWorkspaceId !== workspaceId
  );
  const preferredWorkspace = useTopic(
    needsWorkspaceSync ? { prefer: workspaceId, topic: "workspace" } : null
  ).value;
  const selectWorkspace = useSelectWorkspace();
  useEffect(() => {
    if (
      needsWorkspaceSync &&
      preferredWorkspace?.status === "ready" &&
      preferredWorkspace.workspace?.id === workspaceId
    ) {
      selectWorkspace(workspaceId);
    }
  }, [needsWorkspaceSync, preferredWorkspace, selectWorkspace, workspaceId]);
  const conversation = useConversation(workspaceId, groupId, conversationId);
  const skills = useWorkspaceSkills(workspaceId);
  const openTasksFilter = useOpenTasksFilter();
  const { openBrowser, openChat, openMailPreview, openStillfailPreview } =
    useChatSidebarActions();
  const host = { conversationId, groupId, workspaceId };

  useRegisterChatSidebarHost(host);

  const handleOpenConversationRef = useCallback(
    (conversationRef: ChatConversationRef) => {
      if (conversationRef.kind !== "agent_task") return;
      openChat(
        { conversationId, groupId, workspaceId },
        {
          conversationId: conversationRef.conversationId,
          groupId: conversationRef.groupId ?? groupId,
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
      if (isStillfailChatLink(url)) {
        openStillfailPreview(
          { conversationId, groupId, workspaceId },
          { id: url.trim(), href: url.trim(), workspaceId }
        );
        return;
      }
      if (isMailPreviewLink(url)) {
        openMailPreview(
          { conversationId, groupId, workspaceId },
          { id: url.trim(), href: url.trim(), workspaceId }
        );
        return;
      }
      openBrowser({ conversationId, groupId, workspaceId }, { url });
    },
    [
      conversationId,
      groupId,
      openBrowser,
      openMailPreview,
      openStillfailPreview,
      workspaceId,
    ]
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
    older,
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
      older,
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
      older,
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
  const headerTrailing = useMemo(
    () => (
      <>
        {foundMessageId && foundQuery ? (
          <TaskMessageFind
            conversationId={conversationId}
            current={foundMessageId}
            groupId={groupId}
            onClose={closeFind}
            onStep={showFoundMessage}
            query={foundQuery}
          />
        ) : null}
        <TaskSequenceNavigator conversationId={conversationId} />
      </>
    ),
    [closeFind, conversationId, foundMessageId, foundQuery, groupId, showFoundMessage]
  );

  // A Task of another person's Group the account is no longer in (it left, or was taken out): nothing of it is shown,
  // whatever this device kept of it.
  // Its own Group, from the workspace the app already follows (no subscription of its own); a route of another of the
  // account's workspaces is never taken for someone else's.
  const active = useActiveWorkspace()?.workspace;
  const own = active && active.id === workspaceId ? active : undefined;
  const elsewhere = own !== undefined && groupId !== "" && own.groupId !== groupId;
  // Only a Task of another Group reads the account's memberships.
  const memberships = useTopic(elsewhere ? { topic: "collaborations" } : null).value
    ?.items;
  const outside =
    elsewhere &&
    memberships != null &&
    !memberships.some(
      (item) => item.status === "active" && item.task.id === conversationId
    );
  if (outside) return <NotInTask />;

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
      revealMessageId={foundMessageId}
      headerTrailing={headerTrailing}
      skills={skills}
      state={conversation.state}
      workspaceId={workspaceId}
    />
  );
}

/** Where a Task the account left or was taken out of was: one quiet line, and the way back to its Tasks. */
function NotInTask() {
  const m = useCommaMessages();
  const navigate = useNavigate();
  return (
    <section
      className="flex min-h-0 flex-1 flex-col items-center justify-center gap-md bg-main-panel-bg px-xl text-center"
      data-testid="task-not-member"
    >
      <p className="m-0 max-w-(--container-xs) text-sm text-tertiary">
        {m.people_not_in_task()}
      </p>
      <Button
        hierarchy="secondary-gray"
        onPress={() => void navigate({ replace: true, to: "/tasks" })}
        size="sm"
      >
        {m.people_not_in_task_back()}
      </Button>
    </section>
  );
}
