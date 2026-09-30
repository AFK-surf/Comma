// Electron host adapter. The coordinator and state machine are shared with Web.
import {
  ChatCoordinator,
  type GroupImagePreviewRenderer,
} from "@comma/app/chat-coordinator";
import type { CommaLocale } from "@comma/i18n";
import type { ChatMessage, AttachmentTranscoder } from "@comma/app/chat-runtime";
import type { CommaConversation, CommaLocalFileRef } from "@comma/app/api";
import type { ChatTarget, ChatRuntimeSnapshot } from "@comma/chat-contract";
import {
  createCurrentMainSessionApiBinding,
  type MainSessionTransportAuthority,
} from "../session/main-session-transport";
export * from "@comma/app/chat-coordinator";

export function createMainChatCoordinatorOptions({
  fetch: fetchImpl,
  getClientDeviceId,
  locale,
  onCanonicalMessagesAppended,
  onLocalFilesCommitted,
  onStateChanged,
  renderGroupImagePreview,
  session,
  transcodeAttachment,
}: {
  fetch?: typeof fetch;
  getClientDeviceId?: (workspaceId: string) => string | undefined;
  locale?: CommaLocale;
  onCanonicalMessagesAppended?: (input: {
    conversation: CommaConversation;
    messages: readonly ChatMessage[];
    target: ChatTarget;
  }) => void;
  onLocalFilesCommitted?: (
    files: readonly CommaLocalFileRef[],
    committedAtMs: number | undefined
  ) => Promise<void> | void;
  onStateChanged?: (snapshot: ChatRuntimeSnapshot) => Promise<void> | void;
  renderGroupImagePreview: GroupImagePreviewRenderer;
  session: MainSessionTransportAuthority;
  transcodeAttachment?: AttachmentTranscoder;
}) {
  return {
    createSessionBoundApi: () =>
      createCurrentMainSessionApiBinding({
        ...(fetchImpl ? { fetch: fetchImpl } : {}),
        session,
      }),
    ...(getClientDeviceId ? { getClientDeviceId } : {}),
    ...(locale ? { locale } : {}),
    ...(onCanonicalMessagesAppended ? { onCanonicalMessagesAppended } : {}),
    ...(onLocalFilesCommitted ? { onLocalFilesCommitted } : {}),
    ...(onStateChanged ? { onStateChanged } : {}),
    renderGroupImagePreview,
    ...(transcodeAttachment ? { transcodeAttachment } : {}),
  } satisfies ConstructorParameters<typeof ChatCoordinator>[0];
}

export function createMainChatCoordinator(
  options: Parameters<typeof createMainChatCoordinatorOptions>[0]
) {
  return new ChatCoordinator(createMainChatCoordinatorOptions(options));
}
