import { getNativeBridge } from "@comma/native-bridge";

export function supportsDynamicUiWidgets(): boolean {
  return getNativeBridge().platform === "electron";
}

export interface TextClipboardAdapter {
  readFiles?(): Promise<File[]>;
  readText(): Promise<string>;
  writeText(text: string): Promise<void>;
}

/**
 * Runtime boundary for user-triggered clipboard actions.
 * Electron owns the OS side effect in Main; web keeps the browser API and its
 * legacy write fallback.
 */
export const nativePlatformClipboard: TextClipboardAdapter = {
  async readFiles() {
    const bridge = getNativeBridge();
    if (bridge.platform === "electron") {
      const { pngImage } = await bridge.clipboard.readImage();
      return pngImage
        ? [
            new File([new Uint8Array(pngImage)], "clipboard-image.png", {
              type: "image/png",
            }),
          ]
        : [];
    }
    if (typeof navigator === "undefined" || !navigator.clipboard?.read) return [];
    const files: File[] = [];
    for (const item of await navigator.clipboard.read()) {
      const type = item.types.find((mimeType) => mimeType.startsWith("image/"));
      if (!type) continue;
      files.push(
        new File(
          [await item.getType(type)],
          `clipboard-image.${type.slice("image/".length)}`,
          { type }
        )
      );
    }
    return files;
  },
  async readText() {
    const bridge = getNativeBridge();
    if (bridge.platform === "electron") {
      return (await bridge.clipboard.readText()).text;
    }

    if (typeof navigator !== "undefined" && navigator.clipboard?.readText) {
      return navigator.clipboard.readText();
    }

    throw new Error("Clipboard read is unavailable in this runtime.");
  },

  async writeText(text: string) {
    const bridge = getNativeBridge();
    if (bridge.platform === "electron") {
      await bridge.clipboard.writeText({ text });
      return;
    }

    if (typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
      await navigator.clipboard.writeText(text);
      return;
    }

    const textarea = document.createElement("textarea");
    textarea.value = text;
    textarea.setAttribute("readonly", "");
    textarea.style.position = "fixed";
    textarea.style.opacity = "0";
    document.body.appendChild(textarea);
    textarea.select();
    try {
      if (!document.execCommand("copy")) throw new Error("Clipboard write was denied.");
    } finally {
      document.body.removeChild(textarea);
    }
  },
};

/** Opens an external URL after an explicit user action; Main validates its scheme. */
export async function openNativePlatformExternalUrl(url: string): Promise<void> {
  const bridge = getNativeBridge();
  if (bridge.platform === "electron") {
    await bridge.shell.openExternal({ url });
    return;
  }

  window.open(url, "_blank", "noopener,noreferrer");
}

/**
 * Opens an external URL produced asynchronously from a user gesture without
 * letting browser popup blocking swallow the destination.
 */
export async function openNativePlatformExternalUrlFromUserAction(
  resolveUrl: () => Promise<string>
): Promise<Window | undefined> {
  const bridge = getNativeBridge();
  if (bridge.platform === "electron") {
    await bridge.shell.openExternal({ url: await resolveUrl() });
    return;
  }

  const popup = window.open("about:blank", "_blank");
  if (!popup) {
    throw new Error("The checkout window was blocked by the browser.");
  }
  popup.opener = null;

  try {
    popup.location.href = await resolveUrl();
    return popup;
  } catch (error) {
    popup.close();
    throw error;
  }
}
