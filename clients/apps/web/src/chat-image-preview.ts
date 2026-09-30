import { chatImagePreviewMaxBytes } from "@comma/chat-contract";
import type { GroupImagePreviewRenderer } from "@comma/app/chat-coordinator";

/** Worker-native counterpart of Main's image effect. Preserve source resolution
 * for the full-size viewer; only downscale when PNG exceeds the bridge limit. */
export const renderWebChatImagePreview: GroupImagePreviewRenderer = async ({
  bytes,
  mediaType,
}) => {
  const bitmap = await createImageBitmap(
    new Blob([Uint8Array.from(bytes)], { type: mediaType })
  );
  try {
    if (bitmap.width > 4096 || bitmap.height > 4096) {
      throw new Error("Workspace image exceeds preview dimensions.");
    }
    // Like Main, preserve animation for formats the browser decodes directly.
    if (
      (mediaType === "image/gif" || mediaType === "image/webp") &&
      bytes.byteLength <= chatImagePreviewMaxBytes
    ) {
      return bytes;
    }
    for (const scale of [1, 0.75, 0.5, 0.35, 0.25]) {
      const canvas = new OffscreenCanvas(
        Math.max(1, Math.round(bitmap.width * scale)),
        Math.max(1, Math.round(bitmap.height * scale))
      );
      const context = canvas.getContext("2d");
      if (!context) throw new Error("Workspace image preview canvas is unavailable.");
      context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
      const png = await canvas.convertToBlob({ type: "image/png" });
      if (png.size <= chatImagePreviewMaxBytes)
        return new Uint8Array(await png.arrayBuffer());
    }
    throw new Error("Workspace image exceeds preview byte limit.");
  } finally {
    bitmap.close();
  }
};
