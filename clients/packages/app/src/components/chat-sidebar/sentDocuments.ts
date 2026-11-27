import type { ChatMessage } from "@comma/core/chat";
import type { ConversationFileSource } from "../../runtime-files/fileSources";
import { documentImageName } from "../file-preview/documentEditorModel";
import { filePreviewKind } from "../file-preview/FilePreviewContent";

/**
 * The Markdown documents a person's message sent, each as where it is read from. A sent file is no attachment of
 * the message: it is a file of the Group's uploads that the message names (`workspacePath`).
 */
export function sentDocuments(message: ChatMessage) {
  return message.role !== "user"
    ? []
    : (message.display?.files ?? []).flatMap((file, index) =>
        // A file named by its path on the sender's computer is not in the Group's uploads: there is nothing to read.
        !file.local && filePreviewKind(file.name, undefined) === "markdown"
          ? [{ attachmentIndex: index, fileName: file.name, workspacePath: file.path }]
          : []
      );
}

/**
 * The pictures and videos a conversation's people sent, by file name: where each is read from (its path in the Group's
 * uploads). A document names its own pictures by these file names; of two of one name, the later is the one.
 */
export function sentPictures(messages: readonly ChatMessage[]) {
  const pictures = new Map<string, string>();
  for (const message of messages) {
    if (message.role !== "user") continue;
    for (const file of message.display?.files ?? [])
      if (file.path && !file.local && documentImageName(file.name))
        pictures.set(file.name, file.path);
  }
  return pictures;
}

/** One version of a document: the message attachment it is, who sent it and when. */
export type DocumentVersion = {
  source: ConversationFileSource;
  author: "agent" | "user";
  /** When it was sent, in ms; unknown for a message with no time. */
  at?: number | undefined;
};

/**
 * The versions of the document `shown` that a conversation's messages hold, oldest first: each attachment of its
 * name. None for a file that is no document, or one of another conversation.
 */
export function documentVersionsIn(
  messages: readonly ChatMessage[],
  shown: Pick<
    ConversationFileSource,
    "groupId" | "conversationId" | "fileName" | "mimeType"
  >
): DocumentVersion[] | undefined {
  if (filePreviewKind(shown.fileName, shown.mimeType) !== "markdown") return undefined;
  return messages.flatMap((message): DocumentVersion[] => {
    if (message.source !== "server") return [];
    const author = message.role === "assistant" ? "agent" : "user";
    // A message's time is in seconds or ms (`messageTimestamp`).
    const at =
      message.createdAt === undefined
        ? undefined
        : message.createdAt < 10_000_000_000
          ? message.createdAt * 1000
          : message.createdAt;
    const place = {
      groupId: shown.groupId,
      conversationId: shown.conversationId,
      messageId: message.messageId,
    };
    return [
      ...message.attachments.flatMap((attachment): DocumentVersion[] =>
        attachment.attachmentIndex === undefined ||
        attachment.fileName !== shown.fileName
          ? []
          : [
              {
                source: {
                  ...place,
                  attachmentIndex: attachment.attachmentIndex,
                  fileName: attachment.fileName,
                  ...(attachment.mimeType ? { mimeType: attachment.mimeType } : {}),
                  ...(attachment.size === undefined ? {} : { size: attachment.size }),
                },
                author,
                at,
              },
            ]
      ),
      // A version the person sent (an edit of the page, a restored version) is a file of the Group's uploads
      // that their message names.
      ...sentDocuments(message).flatMap((file): DocumentVersion[] =>
        file.fileName === shown.fileName
          ? [{ source: { ...place, ...file }, author, at }]
          : []
      ),
    ];
  });
}
