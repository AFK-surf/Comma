import type { ChatWorkspaceResolution } from "@comma/chat-contract";
import type { WorkspaceChatValue } from "@comma/core/contract";

/** The core's `workspaceChat` value for a resolution it made, or (`null`) for one that failed. */
export function workspaceChatValue(
  resolution: ChatWorkspaceResolution | null
): WorkspaceChatValue {
  if (resolution === null) return { status: "error", chat: null, kept: false };
  if (resolution.status === "ready") {
    const { status, ...chat } = resolution;
    return { status, chat, kept: false };
  }
  if (resolution.status === "provisioning") {
    const { status, ...provisioning } = resolution;
    return { status, chat: null, kept: false, provisioning };
  }
  return { status: resolution.status, chat: null, kept: false };
}
