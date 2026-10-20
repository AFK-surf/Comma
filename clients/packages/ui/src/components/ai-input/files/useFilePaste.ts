import { useCallback, type ClipboardEvent } from "react";
import type { AiInputClipboard, ForwardedAiInputProps } from "../types";
import { dataTransferHasFiles } from "./dataTransferHasFiles";

export type FilePaste = ReturnType<typeof useFilePaste>;

/**
 * Pastes, from the keyboard or the edit menu's Paste, that the host takes
 * instead of the prompt: files go to the host the way a drop's do, and text
 * goes to the host when it asks for it.
 */
export function useFilePaste({
  clipboard,
  onPaste,
  onPasteFiles,
  onPasteText,
}: ForwardedAiInputProps<"onPaste" | "onPasteFiles" | "onPasteText"> & {
  clipboard: AiInputClipboard;
}) {
  /**
   * A clipboard holding files is an attach gesture, not a text edit, so the
   * paste is consumed here and whatever text rides along with the files never
   * reaches the prompt. A selection that merely contains images carries no
   * files, so ordinary rich-text pastes still insert their text.
   */
  const handlePaste = (event: ClipboardEvent<HTMLElement>) => {
    onPaste?.(event);
    if (event.defaultPrevented) return;
    if (onPasteFiles && dataTransferHasFiles(event.clipboardData)) {
      event.preventDefault();
      onPasteFiles(event.clipboardData);
      return;
    }
    if (onPasteText?.(event.clipboardData.getData("text/plain"))) {
      event.preventDefault();
    }
  };

  const pasteFilesFromMenu = useCallback(async (): Promise<boolean> => {
    if (!onPasteFiles || !clipboard.readFiles) return false;
    let files: File[];
    try {
      files = await clipboard.readFiles();
    } catch {
      // A browser can allow text reads but deny richer clipboard reads.
      return false;
    }
    if (files.length === 0) return false;
    const transfer = new DataTransfer();
    for (const file of files) transfer.items.add(file);
    onPasteFiles(transfer);
    return true;
  }, [clipboard, onPasteFiles]);

  /** The edit menu's Paste: true when the host took the clipboard. */
  const pasteFromMenu = useCallback(async (): Promise<boolean> => {
    if (await pasteFilesFromMenu()) return true;
    if (!onPasteText) return false;
    return onPasteText(await clipboard.readText());
  }, [clipboard, onPasteText, pasteFilesFromMenu]);

  return { handlePaste, pasteFromMenu };
}
