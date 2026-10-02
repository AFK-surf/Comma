import { describe, expect, it } from "vitest";
import {
  avatarCropAt,
  avatarOutputSideFor,
  canUploadOriginal,
  initialAvatarCrop,
  isAcceptedAvatarFile,
} from "../avatarImage";

const file = (size: number, type = "image/png") =>
  new File([new Uint8Array(size)], "avatar", { type });

describe("avatar image preparation", () => {
  it("accepts supported images up to 2 MB", () => {
    expect(isAcceptedAvatarFile(file(2 * 1024 * 1024))).toBe(true);
    expect(isAcceptedAvatarFile(file(2 * 1024 * 1024 + 1))).toBe(false);
    expect(isAcceptedAvatarFile(file(1024, "image/gif"))).toBe(false);
  });

  it("keeps the square crop inside the image while zooming and panning", () => {
    const source = { width: 1600, height: 900 };

    expect(initialAvatarCrop(source)).toEqual({ x: 350, y: 0, size: 900 });
    expect(avatarCropAt(source, 2, { x: 0, y: 0 })).toEqual({ x: 0, y: 0, size: 450 });
    expect(avatarCropAt(source, 2, { x: 5000, y: 5000 })).toEqual({
      x: 1150,
      y: 450,
      size: 450,
    });
  });

  it("re-encodes only when the upload would be cropped, large, or heavy", () => {
    const small = { size: 50 * 1024 };
    const square = { width: 400, height: 400 };

    expect(canUploadOriginal(small, square, initialAvatarCrop(square))).toBe(true);
    expect(
      canUploadOriginal(small, square, avatarCropAt(square, 1.5, { x: 0, y: 0 }))
    ).toBe(false);
    expect(
      canUploadOriginal({ size: 300 * 1024 }, square, initialAvatarCrop(square))
    ).toBe(false);
    const large = { width: 2000, height: 2000 };
    expect(canUploadOriginal(small, large, initialAvatarCrop(large))).toBe(false);
    expect(avatarOutputSideFor(initialAvatarCrop(large))).toBe(512);
  });
});
