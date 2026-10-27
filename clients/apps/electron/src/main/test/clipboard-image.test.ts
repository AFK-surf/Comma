import { describe, expect, it, vi } from "vitest";
import { ElectronClipboardService } from "../modules/native";

const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]);

describe("ElectronClipboardService", () => {
  it("returns OS image bytes and reports an empty clipboard without an image", async () => {
    const readImage = vi.fn<() => Promise<Uint8Array | null>>(async () => png);
    const clipboard = new ElectronClipboardService({
      readImage,
      readText: async () => "",
      writeText: async () => {},
      writeImage: async () => true,
    });
    expect(await clipboard.readImage()).toEqual({ pngImage: png });
    readImage.mockResolvedValue(null);
    expect(await clipboard.readImage()).toEqual({ pngImage: null });
  });

  it("hands the renderer's PNG bytes to the operating-system clipboard", async () => {
    const writeImage = vi.fn(async () => true);
    const clipboard = new ElectronClipboardService({
      readImage: async () => null,
      readText: async () => "",
      writeImage,
      writeText: async () => {},
    });

    expect(await clipboard.writeImage({ pngImage: png })).toEqual({ status: "copied" });
    expect(writeImage).toHaveBeenCalledWith(png);
  });

  it("reports bytes the platform could not decode instead of claiming a copy", async () => {
    const clipboard = new ElectronClipboardService({
      readImage: async () => null,
      readText: async () => "",
      writeImage: async () => false,
      writeText: async () => {},
    });

    expect(await clipboard.writeImage({ pngImage: png })).toEqual({
      status: "unavailable",
    });
  });
});
