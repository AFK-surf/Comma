import {
  chatAttachmentUploadMaxBytes,
  chatGroupImagePreviewSchema,
  chatReadGroupImageInputSchema,
  type ChatReadGroupImageInput,
} from "@comma/chat-contract";
import type { ChatSessionBoundary } from "../entries/sessionBoundary";
import type {
  ChatCoordinatorOptions,
  GroupImagePreviewRenderer,
} from "../hostContract";

/** Previews of workspace images, rendered by the host from verified bytes. */
export class GroupImagePreviews {
  readonly #openBoundary: () => ChatSessionBoundary;
  readonly #renderGroupImagePreview: GroupImagePreviewRenderer | undefined;

  constructor(
    openBoundary: () => ChatSessionBoundary,
    { renderGroupImagePreview }: Pick<ChatCoordinatorOptions, "renderGroupImagePreview">
  ) {
    this.#openBoundary = openBoundary;
    this.#renderGroupImagePreview = renderGroupImagePreview;
  }

  async read(input: ChatReadGroupImageInput): Promise<Uint8Array> {
    const validated = chatReadGroupImageInputSchema.parse(input);
    const boundary = this.#openBoundary();
    boundary.assertCurrent();
    const image =
      validated.source === "agent-blob"
        ? await boundary.api.fetchAgentBlob(
            validated.groupId,
            validated.agentId,
            validated.blobRef
          )
        : await boundary.api.fetchGroupFile(validated.groupId, validated.path);
    boundary.assertCurrent();
    const mediaType =
      validated.source === "agent-blob" ? validated.mediaType : image.type;
    const fileName =
      validated.source === "agent-blob" ? validated.fileName : validated.path;
    if (
      image.size === 0 ||
      image.size > chatAttachmentUploadMaxBytes ||
      (validated.source === "agent-blob" && image.size !== validated.blobRef.size) ||
      !groupImageMediaTypeMatchesPath(mediaType, fileName)
    ) {
      throw new Error("Workspace image response is unavailable.");
    }
    const bytes = new Uint8Array(await image.arrayBuffer());
    boundary.assertCurrent();
    if (!this.#renderGroupImagePreview) {
      throw new Error("Workspace image previews are unavailable.");
    }
    const preview = await this.#renderGroupImagePreview({
      bytes,
      mediaType,
    });
    boundary.assertCurrent();
    return chatGroupImagePreviewSchema.parse(preview);
  }
}

function groupImageMediaTypeMatchesPath(mediaType: string, path: string) {
  const normalizedMediaType = mediaType.trim().toLowerCase();
  const normalizedPath = path.toLowerCase();
  if (normalizedPath.endsWith(".png")) return normalizedMediaType === "image/png";
  if (normalizedPath.endsWith(".gif")) return normalizedMediaType === "image/gif";
  if (normalizedPath.endsWith(".webp")) return normalizedMediaType === "image/webp";
  return normalizedMediaType === "image/jpeg";
}
