/**
 * @vitest-environment jsdom
 */
import { installNativeBridgeMock } from "@comma/test-utils/native-bridge";
import { afterEach, describe, expect, it, vi } from "vitest";
import {
  isAllowedAttachment,
  isImageAttachment,
} from "../components/chat/model/protocol";
import {
  nativePlatformClipboard,
  openNativePlatformExternalUrl,
  openNativePlatformExternalUrlFromUserAction,
} from "../runtime-chat/nativePlatformActions";

const originalClipboard = navigator.clipboard;

afterEach(() => {
  Reflect.deleteProperty(globalThis, "commaNative");
  Object.defineProperty(navigator, "clipboard", {
    configurable: true,
    value: originalClipboard,
  });
  vi.restoreAllMocks();
});

describe("native platform user actions", () => {
  it("routes Electron clipboard and external-link effects through generated leaves", async () => {
    const readText = vi.fn(async () => ({ text: "from Main" }));
    const writeText = vi.fn(async () => ({ ok: true as const }));
    const openExternal = vi.fn(async () => ({ ok: true as const }));
    installNativeBridgeMock({
      clipboard: { readText, writeText },
      platform: "electron",
      shell: { openExternal },
    });

    await expect(nativePlatformClipboard.readText()).resolves.toBe("from Main");
    await nativePlatformClipboard.writeText("to Main");
    await openNativePlatformExternalUrl("https://example.com/docs");

    expect(readText).toHaveBeenCalledOnce();
    expect(writeText).toHaveBeenCalledWith({ text: "to Main" });
    expect(openExternal).toHaveBeenCalledWith({ url: "https://example.com/docs" });
  });

  it("reads Electron images through Main and preserves their PNG bytes", async () => {
    const pngImage = new Uint8Array([137, 80, 78, 71]);
    const readImage = vi.fn(async () => ({ pngImage }));
    installNativeBridgeMock({ platform: "electron", clipboard: { readImage } });
    const files = await nativePlatformClipboard.readFiles!();
    expect(readImage).toHaveBeenCalledOnce();
    expect(files).toHaveLength(1);
    expect(files[0]).toMatchObject({
      name: "clipboard-image.png",
      type: "image/png",
      size: 4,
    });
    const bytes = await new Promise<ArrayBuffer>((resolve) => {
      const reader = new FileReader();
      reader.addEventListener("load", () => resolve(reader.result as ArrayBuffer), {
        once: true,
      });
      reader.readAsArrayBuffer(files[0]!);
    });
    expect(new Uint8Array(bytes)).toEqual(pngImage);
  });

  it("returns no files when the OS clipboard has no image", async () => {
    installNativeBridgeMock({
      platform: "electron",
      clipboard: { readImage: async () => ({ pngImage: null }) },
    });
    await expect(nativePlatformClipboard.readFiles!()).resolves.toEqual([]);
  });

  it("reads one browser image representation instead of attaching HTML or text", async () => {
    installNativeBridgeMock({ platform: "web" });
    const getType = vi.fn(async () => new Blob(["png"], { type: "image/png" }));
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: {
        read: async () => [
          { types: ["text/html", "image/png", "image/jpeg"], getType },
        ],
      },
    });
    const files = await nativePlatformClipboard.readFiles!();
    expect(files).toHaveLength(1);
    expect(files[0]?.type).toBe("image/png");
    expect(files[0]?.name).toBe("clipboard-image.png");
    expect(isAllowedAttachment(files[0]!.name)).toBe(true);
    expect(isImageAttachment(files[0]!.name)).toBe(true);
    expect(getType).toHaveBeenCalledExactlyOnceWith("image/png");
  });

  it("keeps browser clipboard and external links on web APIs", async () => {
    installNativeBridgeMock({ platform: "web" });
    const readText = vi.fn(async () => "from browser");
    const writeText = vi.fn(async () => undefined);
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: { readText, writeText },
    });
    const open = vi.spyOn(window, "open").mockImplementation(() => null);

    await expect(nativePlatformClipboard.readText()).resolves.toBe("from browser");
    await nativePlatformClipboard.writeText("to browser");
    await openNativePlatformExternalUrl("https://example.com/docs");

    expect(writeText).toHaveBeenCalledWith("to browser");
    expect(open).toHaveBeenCalledWith(
      "https://example.com/docs",
      "_blank",
      "noopener,noreferrer"
    );
  });

  it("reserves a browser window before resolving an asynchronous URL", async () => {
    installNativeBridgeMock({ platform: "web" });
    const popup = {
      close: vi.fn(),
      location: { href: "about:blank" },
      opener: {} as Window | null,
    };
    const open = vi.spyOn(window, "open").mockReturnValue(popup as unknown as Window);
    let resolveUrl!: (url: string) => void;
    const url = new Promise<string>((resolve) => {
      resolveUrl = resolve;
    });

    const opening = openNativePlatformExternalUrlFromUserAction(() => url);

    expect(open).toHaveBeenCalledWith("about:blank", "_blank");
    expect(popup.opener).toBeNull();
    expect(popup.location.href).toBe("about:blank");

    resolveUrl("https://checkout.stripe.com/test");
    expect(await opening).toBe(popup);

    expect(popup.location.href).toBe("https://checkout.stripe.com/test");
    expect(popup.close).not.toHaveBeenCalled();
  });

  it("does not report a denied legacy clipboard write as copied", async () => {
    installNativeBridgeMock({ platform: "web" });
    Object.defineProperty(navigator, "clipboard", {
      configurable: true,
      value: undefined,
    });
    const previous = document.execCommand;
    document.execCommand = vi.fn(() => false);
    try {
      await expect(
        nativePlatformClipboard.writeText("private link code")
      ).rejects.toThrow("Clipboard write was denied");
      expect(document.querySelector("textarea")).toBeNull();
    } finally {
      document.execCommand = previous;
    }
  });
});
