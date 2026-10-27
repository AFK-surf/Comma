import type { CoreClient } from "@comma/core-client";
import {
  draftUploadIdOfPreviewRef,
  draftUploadPreviewRef,
  localFilePreviewRefPattern,
  type ChatImagePreviewRef,
  type ConversationChannelState,
  type DraftAttachment,
} from "@comma/core/chat";
import type { CommaNativeBridge } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import { LocalFilePreviewCache } from "./LocalFilePreviewCache";

const workspaceImagePreviewPathPattern =
  /^\/uploads\/[A-Za-z0-9_-]{22}-[A-Za-z0-9._-]+\.(?:png|jpe?g|gif|webp)$/i;

type LocalFilePreviewLoader = (
  previewRef: ChatImagePreviewRef
) => Promise<Uint8Array | undefined>;

/**
 * The channel's session-local image preview cache: replaced on every start,
 * dropped with its session, and rebuilt once the session is projected again.
 */
export class LocalFilePreviews {
  readonly #load: LocalFilePreviewLoader;
  #cache: LocalFilePreviewCache | undefined;
  /** A sent message's image still uploading, by its message and position: the upload it shows from. */
  #sentUploads = new Map<string, string>();

  constructor(
    client: CoreClient,
    bridge: CommaNativeBridge,
    {
      conversationId,
      groupId,
      session,
    }: { conversationId: string; groupId: string; session: SessionProductLease }
  ) {
    const readGroupImage = (input: object) =>
      client.call("chat.readGroupImage", input) as Promise<Uint8Array>;
    this.#load = async (previewRef) => {
      if (typeof previewRef !== "string") {
        // A message's image is read where its conversation keeps it.
        if (previewRef.kind === "attachment")
          return Uint8Array.from(
            await readGroupImage({
              conversationId,
              fileName: previewRef.fileName,
              groupId,
              index: previewRef.index,
              messageId: previewRef.messageId,
              session,
              source: "attachment",
            })
          );
        return Uint8Array.from(
          await readGroupImage({
            agentId: previewRef.agentId,
            blobRef: previewRef.blobRef,
            fileName: previewRef.fileName,
            groupId,
            mediaType: previewRef.mediaType,
            session,
            source: "agent-blob",
          })
        );
      }
      const uploadingId = draftUploadIdOfPreviewRef(previewRef);
      if (uploadingId) {
        return Uint8Array.from(
          await readGroupImage({
            attachmentId: uploadingId,
            groupId,
            session,
            source: "draft-upload",
          })
        );
      }
      if (localFilePreviewRefPattern.test(previewRef)) {
        const result = await bridge.localFiles.preview({
          localFileRef: previewRef,
          session,
        });
        return result.status === "ready" ? Uint8Array.from(result.pngImage) : undefined;
      }
      if (workspaceImagePreviewPathPattern.test(previewRef)) {
        return Uint8Array.from(
          await readGroupImage({
            groupId,
            path: previewRef,
            session,
            source: "group-file",
          })
        );
      }
      return undefined;
    };
  }

  acquire(previewRef: ChatImagePreviewRef, signal?: AbortSignal) {
    return this.#cache?.acquire(previewRef, signal) ?? Promise.resolve(undefined);
  }

  /**
   * Images that uploaded: the message they are sent in reads each by its
   * path, while the draft held it by the ref it was previewed from. Joining
   * the two keeps the thumbnail's URL through the send instead of reading the
   * image again from the server. An image sent while it still uploaded is
   * read by its upload's bytes until it uploads, and by its path after.
   */
  aliasUploaded(state: ConversationChannelState) {
    const cache = this.#cache;
    const sentUploads = new Map<string, string>();
    for (const message of state.messages) {
      if (message.source !== "pending") continue;
      message.attachments.forEach((attachment, position) => {
        const slot = `${message.clientRequestId ?? message.messageId}\u0000${position}`;
        if (attachment.uploadingId) {
          sentUploads.set(slot, attachment.uploadingId);
          return;
        }
        const uploadId = this.#sentUploads.get(slot);
        if (cache && uploadId && attachment.workspacePath)
          cache.alias(attachment.workspacePath, draftUploadPreviewRef(uploadId));
      });
    }
    this.#sentUploads = sentUploads;
    if (!cache) return;
    for (const row of [
      ...state.draftAttachments,
      ...Object.values(state.questionAttachments ?? {}).flat(),
    ]) {
      if (row.isImage && row.status === "uploaded" && row.path)
        cache.alias(row.path, draftImagePreviewRef(row));
    }
  }

  /** Recreates the cache a lost session projection dropped. */
  ensure() {
    this.#cache ??= this.#create();
  }

  replace() {
    this.dispose();
    this.#cache = this.#create();
  }

  dispose() {
    this.#cache?.dispose();
    this.#cache = undefined;
  }

  #create() {
    return new LocalFilePreviewCache({ load: this.#load });
  }
}

/**
 * The ref a draft image is previewed from while it is in the draft: its local
 * file where the host keeps one, else the bytes the core holds for its upload.
 */
export function draftImagePreviewRef(
  attachment: Pick<DraftAttachment, "id">
): ChatImagePreviewRef {
  return localFilePreviewRefPattern.test(attachment.id)
    ? attachment.id
    : draftUploadPreviewRef(attachment.id);
}
