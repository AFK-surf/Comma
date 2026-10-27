import { messages, type CommaLocale } from "@comma/i18n";
import {
  fileDownloadMaxBytes,
  getNativeBridge,
  type FilesSaveDownloadResult,
} from "@comma/native-bridge";
import { toast } from "@comma/ui/components/toast";

export function canCopyFile() {
  const bridge = getNativeBridge();
  return (
    bridge.platform === "electron" && (bridge.os === "macos" || bridge.os === "windows")
  );
}
/** A file saved into Downloads: its handle and the name it took. */
type SavedCopy = { downloadRef: string; fileName: string };
const savedCopies = new WeakMap<
  Blob,
  Map<string, Extract<FilesSaveDownloadResult, { status: "saved" }>>
>();
/** Files saved for copying by the save that wrote them, so a copy again reuses the file. */
const streamedCopies = new WeakMap<object, SavedCopy>();

/**
 * Copies a file a save writes into Downloads as it arrives (`save`, a chat file of any size), never reading it into
 * the window: the clipboard holds the saved file.
 */
export async function copySavedFile(
  save: () => Promise<SavedCopy | null>,
  locale: CommaLocale,
  signal: AbortSignal
) {
  signal.throwIfAborted();
  if (!canCopyFile()) throw new Error("File copy is unavailable.");
  let saved = streamedCopies.get(save);
  if (!saved) {
    const result = await save();
    if (!result) throw new Error("File could not be saved for copying.");
    saved = result;
    streamedCopies.set(save, saved);
  }
  signal.throwIfAborted();
  await copyDownloadToClipboard(saved, locale, signal, () =>
    streamedCopies.delete(save)
  );
}

export async function copyFile(
  blob: Blob,
  fileName: string,
  locale: CommaLocale,
  signal: AbortSignal
) {
  const bridge = getNativeBridge();
  signal.throwIfAborted();
  if (!canCopyFile() || blob.size > fileDownloadMaxBytes)
    throw new Error("File copy is unavailable.");
  let saved = savedCopies.get(blob)?.get(fileName);
  if (!saved) {
    const result = await bridge.files.saveDownload({
      fileName,
      content: new Uint8Array(await blob.arrayBuffer()),
    });
    if (result.status !== "saved")
      throw new Error("File could not be saved for copying.");
    saved = result;
    let names = savedCopies.get(blob);
    if (!names) {
      names = new Map();
      savedCopies.set(blob, names);
    }
    names.set(fileName, saved);
  }
  signal.throwIfAborted();
  await copyDownloadToClipboard(saved, locale, signal, () =>
    savedCopies.get(blob)?.delete(fileName)
  );
}

/** Puts a saved file on the clipboard; `forget` drops it from its cache when it is gone. */
async function copyDownloadToClipboard(
  saved: SavedCopy,
  locale: CommaLocale,
  signal: AbortSignal,
  forget: () => void
) {
  const copied = await getNativeBridge().files.copyDownload({
    downloadRef: saved.downloadRef,
  });
  if (copied.status !== "copied") {
    forget();
    throw new Error("File could not be copied.");
  }
  signal.throwIfAborted();
  toast.success(messages.video_context_file_copied(undefined, { locale }), {
    description: messages.video_context_file_copied_description(
      { name: saved.fileName },
      { locale }
    ),
    id: "video-file-copy",
    testId: "video-file-copy",
  });
}
