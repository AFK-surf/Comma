import type { CallFn } from "@comma/core-client";
import type { DriveDownloaded } from "@comma/core/contract";
import { messages, type CommaLocale } from "@comma/i18n";
import { getNativeBridge, type CommaNativeBridge } from "@comma/native-bridge";
import { toast } from "@comma/ui/components/toast";
import { revealLabel, saveThroughBrowser } from "../../runtime-files/fileDownloads";
import type { DriveFile, DriveTransfer } from "./driveStore";

/**
 * What a window shows of Drive's transfers, which the core runs
 * (`drive.download`, `drive.upload`, `drive.retryTransfer`): the toasts, a
 * web download's save through the browser, and the files a person picked,
 * staged with Main before the core imports them.
 *
 * A download's toasts are keyed by its file, so its progress is replaced by
 * its outcome under the same id.
 */

type DriveTransferBridge = Pick<
  CommaNativeBridge,
  "files" | "os" | "platform" | "synchronicity"
>;

export interface DriveTransferDeps {
  call: CallFn;
  bridge?: DriveTransferBridge;
  locale: CommaLocale;
  /**
   * Skip the progress and success toasts. Reveal-in-Finder downloads first
   * only as a means to an end, and the Finder window that follows is its own
   * confirmation; failures still toast.
   */
  quiet?: boolean;
}

export const driveDownloadToastId = (key: string) => `comma-drive-download-${key}`;

// Update a transfer's existing notification to its terminal result. Sonner
// resets its duration on update; a separate dismiss can overtake a queued add.

const showDownloadInProgress = (
  toastKey: string,
  fileName: string,
  locale: CommaLocale
) => {
  toast(messages.ui_file_downloading(undefined, { locale }), {
    description: fileName,
    duration: Number.POSITIVE_INFINITY,
    id: driveDownloadToastId(toastKey),
    testId: driveDownloadToastId(toastKey),
  });
};

const showDownloadFailed = (
  toastKey: string,
  description: string,
  locale: CommaLocale
) => {
  toast.error(messages.file_download_failed_title(undefined, { locale }), {
    description,
    id: driveDownloadToastId(toastKey),
    testId: driveDownloadToastId(toastKey),
  });
};

const showRevealFailed = (fileName: string, locale: CommaLocale) => {
  toast.error(messages.file_download_missing_title(undefined, { locale }), {
    description: messages.file_download_missing_description({ fileName }, { locale }),
    id: "comma-drive-reveal-failed",
    testId: "comma-drive-reveal-failed",
  });
};

const showOpenFailed = (fileName: string, locale: CommaLocale) => {
  toast.error(messages.file_download_open_failed_title(undefined, { locale }), {
    description: messages.file_download_open_failed_description(
      { fileName },
      { locale }
    ),
    id: "comma-drive-reveal-failed",
    testId: "comma-drive-reveal-failed",
  });
};

export const revealDriveDownload = (
  bridge: DriveTransferBridge,
  downloadRef: string,
  fileName: string,
  locale: CommaLocale
) => {
  void bridge.files.revealDownload({ downloadRef }).then((result) => {
    if (result.status !== "revealed") {
      showRevealFailed(fileName, locale);
    }
  });
};

const showSavedInDownloads = ({
  bridge,
  locale,
  saved,
  toastKey,
}: {
  bridge: DriveTransferBridge;
  locale: CommaLocale;
  saved: { downloadRef: string; fileName: string };
  toastKey: string;
}) => {
  toast.success(messages.file_download_complete_title(undefined, { locale }), {
    actions: [
      {
        hierarchy: "secondary-gray",
        label: revealLabel(bridge.os, locale),
        onPress: () =>
          revealDriveDownload(bridge, saved.downloadRef, saved.fileName, locale),
      },
      {
        hierarchy: "tertiary-gray",
        label: messages.file_download_open(undefined, { locale }),
        onPress: () => {
          void bridge.files
            .openDownload({ downloadRef: saved.downloadRef })
            .then((result) => {
              if (result.status !== "opened") {
                showOpenFailed(saved.fileName, locale);
              }
            });
        },
      },
    ],
    description: messages.file_download_complete_description(
      { fileName: saved.fileName },
      { locale }
    ),
    id: driveDownloadToastId(toastKey),
    testId: driveDownloadToastId(toastKey),
  });
};

/** Shows a finished download: Main saved it, or the browser saves its bytes now. */
function showDownloaded(
  downloaded: DriveDownloaded,
  fileName: string,
  toastKey: string,
  { bridge = getNativeBridge(), locale, quiet = false }: DriveTransferDeps
) {
  if ("saved" in downloaded) {
    if (!quiet)
      showSavedInDownloads({
        bridge,
        locale,
        saved: downloaded.saved,
        toastKey: toastKey,
      });
    return;
  }
  saveThroughBrowser(
    new Blob([downloaded.bytes as Uint8Array<ArrayBuffer>], {
      type: downloaded.mediaType,
    }),
    fileName
  );
  if (quiet) return;
  toast.success(messages.file_download_complete_title(undefined, { locale }), {
    description: messages.file_download_complete_browser_description(
      { fileName },
      { locale }
    ),
    id: driveDownloadToastId(toastKey),
    testId: driveDownloadToastId(toastKey),
  });
}

export async function downloadDriveFile(
  file: Pick<DriveFile, "id" | "name">,
  deps: DriveTransferDeps
): Promise<boolean> {
  const { call, locale, quiet = false } = deps;
  if (!quiet) showDownloadInProgress(file.id, file.name, locale);
  let downloaded: DriveDownloaded;
  try {
    downloaded = await call("drive.download", { file: file.id });
  } catch {
    showDownloadFailed(
      file.id,
      messages.file_download_failed_description({ fileName: file.name }, { locale }),
      locale
    );
    return false;
  }
  showDownloaded(downloaded, file.name, file.id, deps);
  return true;
}

/**
 * Downloads a selection as one operation: every file gets its own transfer
 * row, but the toasts collapse into a single summary, so picking ten files
 * does not stack ten progress cards in the corner. Files that fail fail their
 * own row, as they would alone, and are counted in the summary.
 */
export async function downloadDriveFiles(
  files: readonly Pick<DriveFile, "id" | "name">[],
  deps: DriveTransferDeps
): Promise<void> {
  if (files.length === 0) return;
  const { locale } = deps;
  const toastId = "comma-drive-download-all";
  toast(messages.ui_file_downloading(undefined, { locale }), {
    description: messages.drive_download_all_progress(
      { count: String(files.length) },
      { locale }
    ),
    duration: Number.POSITIVE_INFINITY,
    id: toastId,
    testId: toastId,
  });

  const outcomes = await Promise.all(
    files.map((file) => downloadDriveFile(file, { ...deps, quiet: true }))
  );
  const saved = outcomes.filter(Boolean).length;
  const failed = outcomes.length - saved;

  if (saved === 0) {
    toast.error(messages.file_download_failed_title(undefined, { locale }), {
      description: messages.drive_download_all_failed(
        { count: String(failed) },
        { locale }
      ),
      id: toastId,
      testId: toastId,
    });
    return;
  }
  toast.success(messages.file_download_complete_title(undefined, { locale }), {
    description:
      failed === 0
        ? messages.drive_download_all_complete({ count: String(saved) }, { locale })
        : messages.drive_download_all_partial(
            { failed: String(failed), saved: String(saved) },
            { locale }
          ),
    id: toastId,
    testId: toastId,
  });
}

/**
 * Uploads picked or dropped files into a space (Electron): each is staged with
 * Main, which keeps its path, and the core imports what was staged. A folder
 * upload carries each file's path inside the picked folder
 * (`webkitRelativePath`); dropped folders are grouped by their directory
 * before they get here.
 */
export async function uploadDriveFiles(
  sources: readonly File[],
  target: { folderPath?: string; spaceId: string },
  { bridge = getNativeBridge(), call, locale }: DriveTransferDeps
): Promise<void> {
  const staged = await Promise.all(
    sources.map(async (source) => {
      const result = await bridge.synchronicity
        .stageImport({ source })
        .catch(() => ({ status: "unavailable" }) as const);
      if (result.status !== "staged") return null;
      const relativeDir = source.webkitRelativePath
        ? source.webkitRelativePath.split("/").slice(0, -1).join("/")
        : "";
      return {
        ref: result.ref,
        name: source.name,
        ...(relativeDir ? { relativeDir } : {}),
      };
    })
  );
  const files = staged.filter((file) => file !== null);
  if (files.length < sources.length)
    toast.error(messages.drive_upload_failed_publish(undefined, { locale }), {
      id: "comma-drive-upload-failed",
      testId: "comma-drive-upload-failed",
    });
  if (files.length === 0) return;
  await call("drive.upload", {
    space: target.spaceId,
    ...(target.folderPath ? { folderPath: target.folderPath } : {}),
    files,
  }).catch(() => undefined);
}

/** Runs a failed transfer again; a download shows its outcome as a first one does. */
export async function retryDriveTransfer(
  transfer: DriveTransfer,
  deps: DriveTransferDeps
): Promise<void> {
  const { call, locale } = deps;
  const toastKey = transfer.fileId ?? transfer.id;
  const download = transfer.direction === "download";
  if (download) showDownloadInProgress(toastKey, transfer.fileName, locale);
  try {
    const downloaded = await call("drive.retryTransfer", { transfer: transfer.id });
    if (downloaded) showDownloaded(downloaded, transfer.fileName, toastKey, deps);
  } catch {
    if (download)
      showDownloadFailed(
        toastKey,
        messages.file_download_failed_description(
          { fileName: transfer.fileName },
          { locale }
        ),
        locale
      );
  }
}
