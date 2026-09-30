import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { useMemo } from "react";
import { createFileOpenInAction } from "../../../../runtime-files/fileOpenActions";
import {
  conversationFileSourceKey,
  type ConversationFileSource,
} from "../../../../runtime-files/fileSources";
import { useOptionalChatSidebar } from "../../../chat-sidebar/ChatSidebarContext";
import { useOptionalChatRegistry } from "../../ChatProvider";
import type { ChatAttachment } from "../../model/conversationChannel";
import type { ThreadFileSource } from "../threadContexts";
import { attachmentLabel } from "./attachmentLabels";

export function useAttachmentFileActions(
  attachments: ChatAttachment[],
  messageId: string,
  sourceContext: ThreadFileSource | undefined
) {
  const locale = useCommaLocale();
  const messagesApi = useCommaMessages();
  const registry = useOptionalChatRegistry();
  const sidebar = useOptionalChatSidebar();
  const fileActionSignature = JSON.stringify(
    attachments.map((attachment) => ({
      attachmentIndex: attachment.attachmentIndex,
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
            "attachmentIndex" | "fileName" | "mimeType" | "size"
          >[]
        ).flatMap((attachment, position) => {
          if (!sourceContext || attachment.attachmentIndex === undefined) return [];
          const source: ConversationFileSource = {
            groupId: sourceContext.groupId,
            conversationId: sourceContext.conversationId,
            messageId,
            attachmentIndex: attachment.attachmentIndex,
            fileName: attachment.fileName,
            ...(attachment.mimeType ? { mimeType: attachment.mimeType } : {}),
            ...(attachment.size === undefined ? {} : { size: attachment.size }),
          };
          return [[position, source] as const];
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
                        api: sourceContext.api,
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
    [fileSources, sourceContext, locale, beginAttempt, activeHost, openFilePreview]
  );
  return { beginAttempt, fileActions, fileSources };
}
