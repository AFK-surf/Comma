import { useCallback, useEffect, useMemo, useState, useSyncExternalStore } from "react";
import type { ChatChannel } from "../../../runtime-chat/channel/ChatChannel";
import { isStaleChatSessionError, useChatRegistry } from "../ChatProvider";
import {
  idleConversationChannelState,
  type ChatImagePreviewRef,
} from "../model/conversationChannel";
import {
  createViewStateProjection,
  type ComposerDraftSource,
} from "../composer/conversationDraft";

export function useConversation(
  workspaceId: string | undefined,
  groupId: string | undefined,
  conversationId: string | undefined
) {
  const registry = useChatRegistry();
  const [retained, setRetained] = useState<{
    registry: typeof registry;
    workspaceId: string;
    groupId: string;
    conversationId: string;
    channel: ChatChannel | null;
  } | null>(null);
  const current =
    retained?.registry === registry &&
    retained.workspaceId === workspaceId &&
    retained.groupId === groupId &&
    retained.conversationId === conversationId
      ? retained
      : null;
  const channel = current?.channel ?? null;

  useEffect(() => {
    if (!workspaceId || !groupId || !conversationId) {
      setRetained(null);
      return undefined;
    }

    let lease;
    try {
      lease = registry.retain(workspaceId, groupId, conversationId);
    } catch (error) {
      if (isStaleChatSessionError(error)) {
        setRetained({ registry, workspaceId, groupId, conversationId, channel: null });
        return undefined;
      }
      throw error;
    }
    setRetained({
      registry,
      workspaceId,
      groupId,
      conversationId,
      channel: lease.channel,
    });

    return () => {
      setRetained(null);
      lease.release();
    };
  }, [conversationId, groupId, registry, workspaceId]);

  const subscribe = useCallback(
    (listener: () => void) => channel?.subscribe(listener) ?? (() => {}),
    [channel]
  );
  const getSnapshot = useCallback(
    () =>
      channel?.getSnapshot() ??
      (groupId && conversationId
        ? registry.getRetainedSnapshot(groupId, conversationId)
        : undefined) ??
      (!current && workspaceId && groupId && conversationId
        ? loadingConversationState
        : idleConversationChannelState),
    [channel, conversationId, current, groupId, registry, workspaceId]
  );

  // The view state skips draft-only emits; the draft has its own source, so
  // a keystroke re-renders the composer and none of this hook's consumers.
  const [projectViewState] = useState(createViewStateProjection);
  const getViewState = useCallback(
    () => projectViewState(getSnapshot()),
    [getSnapshot, projectViewState]
  );
  const state = useSyncExternalStore(subscribe, getViewState, getViewState);
  const draftSource = useMemo<ComposerDraftSource>(
    () => ({ getSnapshot: () => getSnapshot().draft, subscribe }),
    [getSnapshot, subscribe]
  );

  // Keep every action identity stable per channel. These callbacks feed
  // React.memo boundaries downstream (Composer, ConversationThread rows), so
  // fresh arrow functions per render would silently defeat all of them.
  const actions = useMemo(
    () => ({
      acceptTaskReview: (reviewVersion: number) =>
        channel?.acceptTaskReview(reviewVersion),
      attachFiles: (files: Parameters<ChatChannel["attachFiles"]>[0]) =>
        channel?.attachFiles(files),
      transcodesImages: channel?.transcodesImages === true,
      ...(channel?.pickAttachments
        ? { pickAttachments: () => channel.pickAttachments?.() }
        : {}),
      ...(channel?.previewLocalFile
        ? {
            previewLocalFile: (previewRef: ChatImagePreviewRef, signal?: AbortSignal) =>
              channel.previewLocalFile!(previewRef, signal),
          }
        : {}),
      clearPresentation: () => channel?.clearPresentation?.(),
      discard: (clientRequestId: string) => channel?.discard(clientRequestId),
      refresh: () => channel?.refresh(),
      removeAttachment: (id: string) => channel?.removeAttachment(id),
      retry: (clientRequestId: string) => channel?.retry(clientRequestId),
      retryAttachment: (id: string) => channel?.retryAttachment(id),
      send: (
        text: string,
        options?: {
          consumeDraft?: boolean;
          replyToMessageId?: string;
          skills?: { location: string }[];
        }
      ) => channel?.send(text, options),
      setDraft: (draft: string) => channel?.setDraft(draft),
    }),
    [channel]
  );

  return useMemo(
    () => ({
      ...actions,
      channel,
      draftSource,
      state,
    }),
    [actions, channel, draftSource, state]
  );
}

const loadingConversationState = {
  ...idleConversationChannelState,
  status: "loading" as const,
  connection: "connecting" as const,
};
