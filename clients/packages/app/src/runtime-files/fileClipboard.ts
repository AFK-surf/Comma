import { messages, type CommaLocale } from "@comma/i18n";
import {
  fileDownloadMaxBytes,
  getNativeBridge,
  type FilesSaveDownloadResult,
} from "@comma/native-bridge";
import { toast } from "@comma/ui";

export function canCopyFile() {
  const bridge = getNativeBridge();
  return bridge.platform === "electron" && bridge.os === "macos";
}
const savedCopies = new WeakMap<
  Blob,
  Map<string, Extract<FilesSaveDownloadResult, { status: "saved" }>>
>();

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
  const copied = await bridge.files.copyDownload({ downloadRef: saved.downloadRef });
  if (copied.status !== "copied") {
    savedCopies.get(blob)?.delete(fileName);
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
