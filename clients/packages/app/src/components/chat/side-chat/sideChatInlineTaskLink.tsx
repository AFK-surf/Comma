import { openNativeSideChatTestWindow } from "../../../runtime-side-chat/nativeSideChat";
import type { InlineTaskLinkAdapter } from "../thread/inline/MessageInlineElements";

export const sideChatInlineTaskLinkAdapter = {
  render: ({ ariaLabel, conversationId, groupId, workspaceId }) => (
    <button
      aria-label={ariaLabel}
      onClick={(event) =>
        openSideChatTaskWindow(
          { conversationId, groupId, workspaceId },
          event.currentTarget
        )
      }
      type="button"
    />
  ),
} satisfies InlineTaskLinkAdapter;

export function sideChatScreenFrame(source: HTMLElement) {
  const sourceRect = source.getBoundingClientRect();
  const screenX = Number.isFinite(window.screenX) ? window.screenX : 0;
  const screenY = Number.isFinite(window.screenY) ? window.screenY : 0;
  return {
    height: Number.isFinite(sourceRect.height) ? Math.max(1, sourceRect.height) : 1,
    width: Number.isFinite(sourceRect.width) ? Math.max(1, sourceRect.width) : 1,
    x: screenX + sourceRect.left,
    y: screenY + sourceRect.top,
  };
}

export function openSideChatTaskWindow(
  task: { conversationId: string; groupId: string; workspaceId: string },
  source: HTMLElement
) {
  void openNativeSideChatTestWindow(sideChatScreenFrame(source), {
    conversationId: task.conversationId,
    groupId: task.groupId,
    workspaceId: task.workspaceId,
  }).catch((error: unknown) => {
    console.error("[side-chat] task-window handoff failed", error);
  });
}
