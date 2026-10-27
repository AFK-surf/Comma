import {
  chatAttachmentUploadMaxBytes,
  chatGroupImagePreviewSchema,
  chatReadGroupImageInputSchema,
  type ChatReadGroupImageInput,
} from "@comma/chat-contract";
import { Effect } from "effect";
import { ChatError } from "../../api";
import type { AttachmentUploadInput } from "../../model/conversationChannel";
import type { ChatSessionBoundary } from "../entries/sessionBoundary";
import type {
  ChatCoordinatorOptions,
  GroupImagePreviewRenderer,
} from "../hostContract";

/** The bytes of a file a group's chat still uploads (or holds for its draft), by its attachment id. */
export type HeldUploadLookup = (
  groupId: string,
  attachmentId: string
) => AttachmentUploadInput | undefined;

/**
 * Previews of workspace images, rendered by the host from verified bytes; an image still uploading is rendered from
 * the bytes the core holds.
 */
export class GroupImagePreviews {
  readonly #openBoundary: () => ChatSessionBoundary;
  readonly #renderGroupImagePreview: GroupImagePreviewRenderer | undefined;
  readonly #heldUpload: HeldUploadLookup;

  constructor(
    openBoundary: () => ChatSessionBoundary,
    {
      renderGroupImagePreview,
    }: Pick<ChatCoordinatorOptions, "renderGroupImagePreview">,
    heldUpload: HeldUploadLookup
  ) {
    this.#openBoundary = openBoundary;
    this.#renderGroupImagePreview = renderGroupImagePreview;
    this.#heldUpload = heldUpload;
  }

  read(input: ChatReadGroupImageInput): Effect.Effect<Uint8Array, Error> {
    return Effect.gen({ self: this }, function* () {
      const validated = chatReadGroupImageInputSchema.parse(input);
      const boundary = this.#openBoundary();
      boundary.assertCurrent();
      let image: Blob;
      let mediaType: string;
      let fileName: string;
      // A message's image is read by the core's chat, where its conversation keeps it (chat/index.ts).
      if (validated.source === "attachment")
        return yield* new ChatError("A message's image is not a workspace image.");
      if (validated.source === "draft-upload") {
        const held = this.#heldUpload(validated.groupId, validated.attachmentId);
        const heldType = held && imageMediaTypeOfName(held.name);
        if (!held || !heldType) {
          return yield* new ChatError("The uploading image is no longer held.");
        }
        image = held.data;
        mediaType = heldType;
        fileName = held.name;
      } else {
        image = yield* validated.source === "agent-blob"
          ? boundary.api.fetchAgentBlob(
              validated.groupId,
              validated.agentId,
              validated.blobRef
            )
          : boundary.api.fetchGroupFile(validated.groupId, validated.path);
        mediaType =
          validated.source === "agent-blob" ? validated.mediaType : image.type;
        fileName =
          validated.source === "agent-blob" ? validated.fileName : validated.path;
      }
      boundary.assertCurrent();
      if (
        image.size === 0 ||
        image.size > chatAttachmentUploadMaxBytes ||
        (validated.source === "agent-blob" && image.size !== validated.blobRef.size) ||
        !groupImageMediaTypeMatchesPath(mediaType, fileName)
      ) {
        return yield* new ChatError("Workspace image response is unavailable.");
      }
      const bytes = new Uint8Array(yield* Effect.promise(() => image.arrayBuffer()));
      boundary.assertCurrent();
      const render = this.#renderGroupImagePreview;
      if (!render) {
        return yield* new ChatError("Workspace image previews are unavailable.");
      }
      const preview = yield* Effect.tryPromise({
        try: () => Promise.resolve(render({ bytes, mediaType })),
        catch: (error) =>
          new ChatError(error instanceof Error ? error.message : String(error), {
            cause: error,
          }),
      });
      boundary.assertCurrent();
      return chatGroupImagePreviewSchema.parse(preview);
    });
  }
}

/** The previewable image type a file's name says it is; none for any other (HEIC is uploaded as its JPEG). */
export function imageMediaTypeOfName(name: string) {
  const extension = name.toLowerCase().match(/\.([a-z0-9]+)$/)?.[1];
  if (extension === "png") return "image/png";
  if (extension === "jpg" || extension === "jpeg") return "image/jpeg";
  if (extension === "gif") return "image/gif";
  if (extension === "webp") return "image/webp";
  return undefined;
}

function groupImageMediaTypeMatchesPath(mediaType: string, path: string) {
  const normalizedMediaType = mediaType.trim().toLowerCase();
  const normalizedPath = path.toLowerCase();
  if (normalizedPath.endsWith(".png")) return normalizedMediaType === "image/png";
  if (normalizedPath.endsWith(".gif")) return normalizedMediaType === "image/gif";
  if (normalizedPath.endsWith(".webp")) return normalizedMediaType === "image/webp";
  return normalizedMediaType === "image/jpeg";
}
