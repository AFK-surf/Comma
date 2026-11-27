import { useCall } from "@comma/core-client";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { useMemo } from "react";
import { createFileOpenInAction } from "../../../../runtime-files/fileOpenActions";
import {
  conversationFileSourceKey,
  type ConversationFileSource,
} from "../../../../runtime-files/fileSources";
import { useOptionalChatSidebar } from "../../../chat-sidebar/ChatSidebarContext";
import { useOptionalChatRegistry } from "../../ChatProvider";
import type { ChatAttachment } from "@comma/core/chat";
import type { ThreadFileSource } from "../threadContexts";
import { attachmentLabel } from "./attachmentLabels";

type AttachmentFileFields = Pick<
  ConversationFileSource,
  "attachmentIndex" | "fileName" | "mimeType" | "size" | "workspacePath"
>;

/**
 * Where a message's file is read from. A message's own attachment (it has an index) is read from the message,
 * whatever path it also names; a file the person sent has no index and is read from where it was uploaded
 * (`workspacePath`), its place in the message standing for its index.
 */
export function attachmentFileSource(
  attachment: Partial<AttachmentFileFields> & Pick<AttachmentFileFields, "fileName">,
  position: number,
  messageId: string,
  sourceContext: ThreadFileSource | undefined
): ConversationFileSource | undefined {
  if (
    !sourceContext ||
    (attachment.attachmentIndex === undefined && !attachment.workspacePath)
  )
    return undefined;
  return {
    groupId: sourceContext.groupId,
    conversationId: sourceContext.conversationId,
    messageId,
    attachmentIndex: attachment.attachmentIndex ?? position,
    ...(attachment.attachmentIndex === undefined && attachment.workspacePath
      ? { workspacePath: attachment.workspacePath }
      : {}),
    fileName: attachment.fileName,
    ...(attachment.mimeType ? { mimeType: attachment.mimeType } : {}),
    ...(attachment.size === undefined ? {} : { size: attachment.size }),
  };
}

export function useAttachmentFileActions(
  attachments: ChatAttachment[],
  messageId: string,
  sourceContext: ThreadFileSource | undefined
) {
  const locale = useCommaLocale();
  const messagesApi = useCommaMessages();
  const call = useCall();
  const registry = useOptionalChatRegistry();
  const sidebar = useOptionalChatSidebar();
  const fileActionSignature = JSON.stringify(
    attachments.map((attachment) => ({
      attachmentIndex: attachment.attachmentIndex,
      workspacePath: attachment.workspacePath,
      fileName: attachmentLabel(attachment, messagesApi),
      mimeType: attachment.mimeType,
      size: attachment.size,
    }))
  );
  const activeHost = sidebar?.activeHost;
  const openFilePreview = sidebar?.openFilePreview;
  const beginAttempt = registry?.beginAttempt;
  // Sources change only with the attachments themselves. Sidebar and locale
  // changes rebuild the actions below, and an inline player keyed to those
  // would restart its request and lose its playback position.
  const fileSources = useMemo(
    () =>
      new Map(
        (
          JSON.parse(fileActionSignature) as Pick<
            ConversationFileSource,
            "attachmentIndex" | "fileName" | "mimeType" | "size" | "workspacePath"
          >[]
        ).flatMap((attachment, position) => {
          const source = attachmentFileSource(
            attachment,
            position,
            messageId,
            sourceContext
          );
          return source ? [[position, source] as const] : [];
        })
      ),
    [sourceContext, fileActionSignature, messageId]
  );
  const fileActions = useMemo(
    () =>
      new Map(
        Array.from(
          fileSources,
          ([position, source]) =>
            [
              position,
              {
                onPreview:
                  activeHost && openFilePreview
                    ? () => openFilePreview(activeHost, source)
                    : sourceContext?.open
                      ? () => sourceContext.open?.(source)
                      : undefined,
                openIn:
                  sourceContext && beginAttempt
                    ? createFileOpenInAction({
                        call,
                        source,
                        locale,
                        beginAttempt,
                      })
                    : undefined,
                key: conversationFileSourceKey(source),
              },
            ] as const
        )
      ),
    [
      fileSources,
      sourceContext,
      call,
      locale,
      beginAttempt,
      activeHost,
      openFilePreview,
    ]
  );
  return { beginAttempt, fileActions, fileSources };
}
