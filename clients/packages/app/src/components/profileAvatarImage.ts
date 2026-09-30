// Matches the server's avatar limit in Comma.ProfileAvatar.
const maxAvatarBytes = 102_400;
const avatarSizes = [512, 384, 256];
const avatarQualities = [0.9, 0.8, 0.7, 0.6, 0.5];

/** The selected file cannot become an avatar within the server's limit. */
export class ProfileAvatarImageError extends Error {}

/**
 * Center-crops any image the browser can decode to a square, downscales it to
 * at most 512px, and re-encodes it until it fits the server's avatar limit.
 */
export async function prepareProfileAvatar(file: Blob): Promise<File> {
  let bitmap: ImageBitmap;
  try {
    bitmap = await createImageBitmap(file);
  } catch (cause) {
    throw new ProfileAvatarImageError("Avatar image cannot be decoded.", { cause });
  }
  try {
    const cropSize = Math.min(bitmap.width, bitmap.height);
    const cropX = Math.floor((bitmap.width - cropSize) / 2);
    const cropY = Math.floor((bitmap.height - cropSize) / 2);
    // Browsers without a WebP encoder (Safari) return PNG; use JPEG there.
    let type = "image/webp";
    const sizes = new Set(avatarSizes.map((size) => Math.min(size, cropSize)));
    for (const size of sizes) {
      const canvas = new OffscreenCanvas(size, size);
      const context = canvas.getContext("2d");
      if (!context) throw new Error("Avatar canvas is unavailable.");
      const draw = () => {
        if (type === "image/jpeg") {
          // JPEG has no alpha; keep transparent areas white instead of black.
          context.fillStyle = "#fff";
          context.fillRect(0, 0, size, size);
        }
        context.drawImage(bitmap, cropX, cropY, cropSize, cropSize, 0, 0, size, size);
      };
      draw();
      for (const quality of avatarQualities) {
        let blob = await canvas.convertToBlob({ type, quality });
        if (type === "image/webp" && blob.type !== type) {
          type = "image/jpeg";
          draw();
          blob = await canvas.convertToBlob({ type, quality });
        }
        if (blob.size > 0 && blob.size <= maxAvatarBytes) {
          const extension = type === "image/webp" ? "webp" : "jpg";
          return new File([blob], `avatar.${extension}`, { type });
        }
      }
    }
    throw new ProfileAvatarImageError(
      "Avatar image cannot be compressed under the size limit."
    );
  } finally {
    bitmap.close();
  }
}
