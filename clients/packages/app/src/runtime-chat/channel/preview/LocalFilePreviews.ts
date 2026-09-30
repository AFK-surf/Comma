import type { CommaNativeBridge } from "@comma/native-bridge";
import type { SessionProductLease } from "@comma/session-contract";
import type { ChatImagePreviewRef } from "../../../components/chat/model/conversationChannel";
import { LocalFilePreviewCache } from "./LocalFilePreviewCache";

export const localFilePreviewRefPattern = /^lfi1_[A-Za-z0-9_-]{43}$/;
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
    bridge: CommaNativeBridge,
    { groupId, session }: { groupId: string; session: SessionProductLease }
  ) {
    this.#load = async (previewRef) => {
      if (typeof previewRef !== "string") {
        if (previewRef.kind !== "agent-blob") return undefined;
        return Uint8Array.from(
          await bridge.chat.readGroupImage({
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
      if (localFilePreviewRefPattern.test(previewRef)) {
        const result = await bridge.localFiles.preview({
          localFileRef: previewRef,
          session,
        });
        return result.status === "ready" ? Uint8Array.from(result.pngImage) : undefined;
      }
      if (workspaceImagePreviewPathPattern.test(previewRef)) {
        return Uint8Array.from(
          await bridge.chat.readGroupImage({
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
