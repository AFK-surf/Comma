import { useCommaMessages } from "@comma/i18n/react";
import { memo, useCallback, type RefObject } from "react";
import type { CommaApiClient } from "../../../api";
import { useTaskArchiveForApi } from "../../tasks/useTaskArchive";
import { ChatTaskPanel, type ChatTaskOpenTarget } from "./ChatTaskPanel";
import { dismissPanelTask } from "./chatTaskPanelDismissals";
import type { ChatMessage } from "../model/conversationChannel";
import type { InlineTaskLinkAdapter } from "../thread/inline/MessageInlineElements";
import { useChatCreatedTasks, type ChatCreatedTask } from "./useChatCreatedTasks";

/**
 * Binds the Tasks this conversation created to the panel above the composer.
 *
 * It is its own memo boundary on purpose. The panel follows the Inbox
 * projection, the Task summary cache, and two acknowledgement stores, none of
 * which the conversation surface reads; and the conversation surface renders
 * on every streamed delta, which none of those sources care about. Kept apart,
 * a Task moving on renders the panel alone, and a reply streaming in renders
 * everything but the panel.
 */
export const ChatTaskDock = memo(function ChatTaskDock({
  api,
  groupId,
  messages,
  revealTurnHandle,
  taskLinkAdapter,
  workspaceId,
}: {
  api?: CommaApiClient | undefined;
  groupId: string;
  messages: readonly ChatMessage[];
  revealTurnHandle: RefObject<
    ((turnKey: string, highlightMessageId?: string) => void) | null
  >;
  /** How this surface opens a Task; shared with the transcript's Task chips. */
  taskLinkAdapter: InlineTaskLinkAdapter;
  workspaceId: string;
}) {
  const copy = useCommaMessages();
  const items = useChatCreatedTasks({ api, groupId, messages });
  const archive = useTaskArchiveForApi(api);

  const handleArchive = useCallback(
    (task: ChatCreatedTask) =>
      archive(
        { group_id: groupId, id: task.conversationId, updated_at: task.archiveVersion },
        "archive"
      ),
    [archive, groupId]
  );
  const handleDismiss = useCallback((task: ChatCreatedTask) => {
    dismissPanelTask(task.conversationId);
  }, []);
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
      if (task.statusBucket !== "in_progress") dismissPanelTask(task.conversationId);
    },
    [revealTurnHandle]
  );

  return (
    <ChatTaskPanel
      items={items}
      onArchive={handleArchive}
      onDismiss={handleDismiss}
      onOpen={handleOpen}
      onReveal={handleReveal}
    />
  );
});
