import { describe, expect, it, vi } from "vitest";
import { ElectronClipboardService } from "../modules/native";

const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);

describe("ElectronClipboardService", () => {
  it("returns OS image bytes and reports an empty clipboard without an image", () => {
    const readImage = vi.fn<() => Uint8Array | null>(() => png);
    const clipboard = new ElectronClipboardService({
      readImage,
      readText: () => "",
      writeText: () => {},
      writeImage: () => true,
    });
    expect(clipboard.readImage()).toEqual({ pngImage: png });
    readImage.mockReturnValue(null);
    expect(clipboard.readImage()).toEqual({ pngImage: null });
  });

  it("hands the renderer's PNG bytes to the operating-system clipboard", () => {
    const writeImage = vi.fn(() => true);
    const clipboard = new ElectronClipboardService({
      readImage: () => null,
      readText: () => "",
      writeImage,
      writeText: () => {},
    });

    expect(clipboard.writeImage({ pngImage: png })).toEqual({ status: "copied" });
    expect(writeImage).toHaveBeenCalledWith(png);
  });

  it("reports bytes the platform could not decode instead of claiming a copy", () => {
    const clipboard = new ElectronClipboardService({
      readImage: () => null,
      readText: () => "",
      writeImage: () => false,
      writeText: () => {},
    });

    expect(clipboard.writeImage({ pngImage: png })).toEqual({ status: "unavailable" });
  });
});
