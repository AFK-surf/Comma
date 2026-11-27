import { chatAttachmentDownloadMaxBytes } from "@comma/chat-contract";
import type { CallFn, FileSource } from "@comma/core-client";

/**
 * A file of a message. An attachment keeps its original conversation as the byte authority. A file the person sent
 * with the message is in the Group's uploads instead (`workspacePath`), and is read from there; its
 * `attachmentIndex` is its place among the message's sent files.
 */
export interface ConversationFileSource {
  groupId: string;
  conversationId: string;
  messageId: string;
  attachmentIndex: number;
  fileName: string;
  mimeType?: string;
  size?: number;
  workspacePath?: string;
}

export const conversationFileSourceKey = (source: ConversationFileSource) =>
  JSON.stringify([
    source.groupId,
    source.conversationId,
    source.messageId,
    source.attachmentIndex,
    source.fileName,
    ...(source.workspacePath === undefined ? [] : [source.workspacePath]),
  ]);

/** A chat file's bytes as the core reads them, typed as the server gave them. */
export const readFileBlob = async (
  call: CallFn,
  source: FileSource,
  signal?: AbortSignal
) => {
  const { bytes, type } = await call("files.read", source, signal);
  return new Blob([bytes as Uint8Array<ArrayBuffer>], { type });
};

/** Where the core reads the bytes of a message's file: its attachment, or the upload the person sent with it. */
export const conversationFileSource = (source: ConversationFileSource): FileSource =>
  source.workspacePath === undefined
    ? {
        source: "attachment",
        group: source.groupId,
        conversation: source.conversationId,
        message: source.messageId,
        index: source.attachmentIndex,
      }
    : {
        source: "group-file",
        group: source.groupId,
        path: source.workspacePath,
        // A Task together's file is read through that Task's own route.
        ...(source.workspacePath.startsWith("/task/")
          ? { task: source.conversationId }
          : {}),
      };

/** Saves a message attachment into Downloads as it arrives (desktop): any size, never read whole. */
export const saveConversationFile =
  (call: CallFn, source: ConversationFileSource) => () =>
    call("files.save", {
      source: conversationFileSource(source),
      name: source.fileName,
    });

/**
 * A message attachment read a part at a time (`files.readRange`) for a browser to save: one with no link to it (a
 * Task's on a machine), at any size. The browser holds the parts, not this page.
 */
export const readConversationFileParts =
  (call: CallFn, source: ConversationFileSource) => async (signal?: AbortSignal) => {
    const parts: Uint8Array<ArrayBuffer>[] = [];
    let type = "";
    for (let offset = 0, size = 1; offset < size; ) {
      const range = await call(
        "files.readRange",
        {
          source: conversationFileSource(source),
          offset,
          length: chatAttachmentDownloadMaxBytes,
        },
        signal
      );
      size = range.size;
      type = range.type;
      if (range.bytes.length === 0) {
        if (offset < size) throw new Error("The file changed while it was read.");
        break;
      }
      parts.push(range.bytes as Uint8Array<ArrayBuffer>);
      offset += range.bytes.length;
    }
    return new Blob(parts, { type });
  };

/** A URL a browser downloads a message attachment from itself (web): any size, never read here. */
export const conversationFileLink =
  (call: CallFn, source: ConversationFileSource) => async () =>
    (await call("files.link", conversationFileSource(source))).url;

/** Up to `length` bytes of a message attachment from `offset`, and the whole file's size. */
export const readConversationFileRange = (
  call: CallFn,
  source: ConversationFileSource,
  offset: number,
  length: number,
  signal?: AbortSignal
) =>
  call(
    "files.readRange",
    { source: conversationFileSource(source), offset, length },
    signal
  );

export const resolveConversationFile = (
  call: CallFn,
  source: ConversationFileSource,
  signal?: AbortSignal
) => readFileBlob(call, conversationFileSource(source), signal);
