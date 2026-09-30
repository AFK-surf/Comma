import type { AiInputClipboard } from "../types";

export const browserAiInputClipboard: AiInputClipboard = {
  async readFiles() {
    if (!navigator.clipboard?.read) return [];
    const items = await navigator.clipboard.read();
    const files: File[] = [];
    for (const item of items) {
      const type = item.types.find((mimeType) => mimeType.startsWith("image/"));
      if (!type) continue;
      const blob = await item.getType(type);
      files.push(
        new File([blob], `clipboard-image.${type.slice("image/".length)}`, { type })
      );
    }
    return files;
  },
  async readText() {
    if (typeof navigator === "undefined" || !navigator.clipboard?.readText) {
      throw new Error("Clipboard read is unavailable in this runtime.");
    }
    return navigator.clipboard.readText();
  },
  async writeText(text) {
    if (typeof navigator === "undefined" || !navigator.clipboard?.writeText) {
      throw new Error("Clipboard write is unavailable in this runtime.");
    }
    await navigator.clipboard.writeText(text);
  },
};
