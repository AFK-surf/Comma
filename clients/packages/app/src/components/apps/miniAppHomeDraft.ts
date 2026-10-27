import { useCommaLocale } from "@comma/i18n/react";
import { useCallback } from "react";
import { useWorkspacePreference } from "../activeWorkspace";
import { useOptionalChatActionRegistry } from "../chat/ChatProvider";
import { resolveWorkspaceChat } from "../chat/useWorkspaceChat";
import { prefillDeviceDraft } from "../devices/routerDeviceDraft";

/**
 * Puts an app's `chat.draft` text in Home's composer (the Router chat of the Workspace in focus, a guest's own chat
 * too), for an app that runs outside a chat: full width or in its own window. Nothing is sent; the viewer sends it.
 * Undefined where no chat registry is mounted.
 */
export function useMiniAppHomeDraft(): ((text: string) => Promise<void>) | undefined {
  const registry = useOptionalChatActionRegistry();
  const workspaceId = useWorkspacePreference();
  const locale = useCommaLocale();
  const draft = useCallback(
    async (text: string) => {
      if (!registry) throw new Error("No chat here.");
      const attempt = registry.beginAttempt();
      try {
        await attempt.run(async (signal) => {
          const resolved = await resolveWorkspaceChat({
            core: registry.core,
            locale,
            session: registry.productLease,
            signal,
            ...(workspaceId ? { workspaceId, exactWorkspace: true } : {}),
          });
          if (resolved.status !== "ready") throw new Error("Home is not ready.");
          const lease = attempt.retain(
            resolved.workspaceId,
            resolved.groupId,
            resolved.conversation.id
          );
          await prefillDeviceDraft(lease.channel, text, signal);
          registry.rememberHomeConversationTarget(
            resolved.workspaceId,
            resolved.groupId,
            resolved.conversation.id,
            resolved.conversation
          );
        });
      } finally {
        attempt.release();
      }
    },
    [registry, workspaceId, locale]
  );
  return registry ? draft : undefined;
}
