import type { CoreClient } from "@comma/core-client";
import {
  draftUploadIdOfPreviewRef,
  localFilePreviewRefPattern,
  type ChatImagePreviewRef,
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

  constructor(
    client: CoreClient,
    bridge: CommaNativeBridge,
    { groupId, session }: { groupId: string; session: SessionProductLease }
  ) {
    const readGroupImage = (input: object) =>
      client.call("chat.readGroupImage", input) as Promise<Uint8Array>;
    this.#load = async (previewRef) => {
      if (typeof previewRef !== "string") {
        if (previewRef.kind !== "agent-blob") return undefined;
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
