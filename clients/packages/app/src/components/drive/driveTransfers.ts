import { ensureDriveFileBlob, refreshDrive } from "./driveBackend";
import { driveFileIdFor, type DriveBackend } from "./driveSynchronicityBackend";
import { messages, type CommaLocale } from "@comma/i18n";
import {
  fileDownloadMaxBytes,
  getNativeBridge,
  type CommaNativeBridge,
  type FilesSaveDownloadResult,
} from "@comma/native-bridge";
import { toast } from "@comma/ui";
import { revealLabel, saveThroughBrowser } from "../../runtime-files/fileDownloads";
import {
  driveFileTypeLabel,
  driveUploadMimeType,
  type DriveFile,
  type DriveStore,
} from "./driveStore";

/**
 * Drive's transfer orchestration over the shared `files.*` capability.
 *
 * Unlike the one-shot chat download path, every Drive transfer is a row in the
 * transfer panel, so toasts are keyed per transfer (progress replaced by the
 * outcome under the same id) and the saved-download handle is kept on the row
 * to power its reveal-in-Finder affordance.
 */

type DriveTransferBridge = Pick<CommaNativeBridge, "files" | "os" | "platform">;

const driveFallbackUploadMaxBytes = fileDownloadMaxBytes;
const DRIVE_TRANSFER_CONCURRENCY = 2;

export interface DriveTransferDeps {
  /** The node behind Drive, when there is one: bytes come from it and uploads go to it. */
  backend?: DriveBackend;
  bridge?: DriveTransferBridge;
  locale: CommaLocale;
  /**
   * Skip the progress and success toasts. Reveal-in-Finder downloads first
   * only as a means to an end, and the Finder window that follows is its own
   * confirmation; failures still toast.
   */
  quiet?: boolean;
}

export const driveDownloadToastId = (transferId: string) =>
  `comma-drive-download-${transferId}`;

// Update a transfer's existing notification to its terminal result. Sonner
// resets its duration on update; a separate dismiss can overtake a queued add.

const showDownloadInProgress = (
  transferId: string,
  fileName: string,
  locale: CommaLocale
) => {
  toast(messages.ui_file_downloading(undefined, { locale }), {
    description: fileName,
    duration: Number.POSITIVE_INFINITY,
    id: driveDownloadToastId(transferId),
    testId: driveDownloadToastId(transferId),
  });
};

const showDownloadFailed = (
  transferId: string,
  description: string,
  locale: CommaLocale
) => {
  toast.error(messages.file_download_failed_title(undefined, { locale }), {
    description,
    id: driveDownloadToastId(transferId),
    testId: driveDownloadToastId(transferId),
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
  transferId,
}: {
  bridge: DriveTransferBridge;
  locale: CommaLocale;
  saved: Extract<FilesSaveDownloadResult, { status: "saved" }>;
  transferId: string;
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
    id: driveDownloadToastId(transferId),
    testId: driveDownloadToastId(transferId),
  });
};

async function runDownload(
  store: DriveStore,
  transferId: string,
  file: DriveFile,
  { backend, bridge = getNativeBridge(), locale, quiet = false }: DriveTransferDeps
): Promise<boolean> {
  if (!quiet) showDownloadInProgress(transferId, file.name, locale);

  if (backend && bridge.platform === "electron") {
    let streamed: FilesSaveDownloadResult;
    try {
      streamed = await backend.saveDownload(file);
    } catch {
      streamed = { status: "unavailable" };
    }
    if (streamed.status === "saved") {
      store.completeTransfer(transferId, { downloadRef: streamed.downloadRef });
      if (!quiet) showSavedInDownloads({ bridge, locale, saved: streamed, transferId });
      return true;
    }
    store.failTransfer(
      transferId,
      messages.file_download_failed_title(undefined, { locale })
    );
    showDownloadFailed(
      transferId,
      messages.file_download_failed_description({ fileName: file.name }, { locale }),
      locale
    );
    return false;
  }

  // The node holds the bytes until something asks; a read that fails leaves
  // the file unsynced here, which the failure below already explains.
  const blob =
    file.blob ??
    (backend
      ? await ensureDriveFileBlob(store, backend, file).catch(() => undefined)
      : undefined);
  if (!blob || blob.size > fileDownloadMaxBytes) {
    // The panel row wants a short reason; the toast can afford the sentence.
    store.failTransfer(
      transferId,
      blob
        ? messages.file_download_failed_title(undefined, { locale })
        : messages.drive_file_not_synced(undefined, { locale })
    );
    showDownloadFailed(
      transferId,
      blob
        ? messages.file_download_failed_description({ fileName: file.name }, { locale })
        : messages.drive_file_not_synced(undefined, { locale }),
      locale
    );
    return false;
  }

  if (bridge.platform !== "electron") {
    saveThroughBrowser(blob, file.name);
    store.completeTransfer(transferId);
    if (quiet) return true;
    toast.success(messages.file_download_complete_title(undefined, { locale }), {
      description: messages.file_download_complete_browser_description(
        { fileName: file.name },
        { locale }
      ),
      id: driveDownloadToastId(transferId),
      testId: driveDownloadToastId(transferId),
    });
    return true;
  }

  let saved: FilesSaveDownloadResult;
  try {
    saved = await bridge.files.saveDownload({
      content: new Uint8Array(await blob.arrayBuffer()),
      fileName: file.name,
    });
  } catch {
    saved = { status: "unavailable" };
  }

  if (saved.status !== "saved") {
    store.failTransfer(
      transferId,
      messages.file_download_failed_title(undefined, { locale })
    );
    showDownloadFailed(
      transferId,
      messages.file_download_failed_description({ fileName: file.name }, { locale }),
      locale
    );
    return false;
  }

  store.completeTransfer(transferId, { downloadRef: saved.downloadRef });
  if (!quiet) showSavedInDownloads({ bridge, locale, saved, transferId });
  return true;
}

export async function downloadDriveFile(
  store: DriveStore,
  file: DriveFile,
  deps: DriveTransferDeps
): Promise<boolean> {
  const transfer = store.beginTransfer({
    detail: driveFileTypeLabel(file.name),
    direction: "download",
    fileId: file.id,
    fileName: file.name,
  });
  return runDownload(store, transfer.id, file, deps);
}

/**
 * Downloads a selection as one operation: every file gets its own transfer
 * row, but the toasts collapse into a single summary, so picking ten files
 * does not stack ten progress cards in the corner. Files without local bytes
 * fail their own row, as they would alone, and are counted in the summary.
 */
export async function downloadDriveFiles(
  store: DriveStore,
  files: readonly DriveFile[],
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

  const outcomes: boolean[] = [];
  await runWithConcurrency(files, async (file) => {
    outcomes.push(await downloadDriveFile(store, file, { ...deps, quiet: true }));
  });
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

async function runUpload(
  store: DriveStore,
  transferId: string,
  source: File,
  target: { deviceId: string; folderPath?: string; spaceId: string },
  { backend, bridge = getNativeBridge(), locale }: DriveTransferDeps
) {
  // A folder upload carries each file's path inside the picked folder
  // (`webkitRelativePath`); dropped folders are grouped by their directory
  // before they get here, so each destination path is relative to the space.
  const relativeDir = source.webkitRelativePath
    ? source.webkitRelativePath.split("/").slice(0, -1).join("/")
    : "";
  const folderPath = [target.folderPath, relativeDir].filter(Boolean).join("/");
  const nativeImport = Boolean(backend && bridge.platform === "electron");

  if (!nativeImport && source.size > driveFallbackUploadMaxBytes) {
    store.failTransfer(
      transferId,
      messages.drive_upload_failed_too_large(undefined, { locale })
    );
    return;
  }

  if (backend) {
    try {
      if (nativeImport) {
        await backend.writeFile({
          ...(folderPath ? { folderPath } : {}),
          name: source.name,
          source,
          spaceId: target.spaceId,
        });
        await refreshDrive(store, backend);
        const fileId = driveFileIdFor(
          target.spaceId,
          folderPath ? `${folderPath}/${source.name}` : source.name
        );
        store.completeTransfer(transferId, { fileId });
        return;
      }

      const blob = await blobFromDriveUploadSource(source);
      await backend.writeFile({
        blob,
        ...(folderPath ? { folderPath } : {}),
        name: source.name,
        spaceId: target.spaceId,
      });
      await refreshDrive(store, backend);
      const fileId = driveFileIdFor(
        target.spaceId,
        folderPath ? `${folderPath}/${source.name}` : source.name
      );
      store.attachBlob(fileId, blob);
      store.completeTransfer(transferId, { fileId });
      return;
    } catch {
      store.failTransfer(
        transferId,
        messages.drive_upload_failed_publish(undefined, { locale })
      );
      return;
    }
  }

  let blob: Blob;
  try {
    blob = await blobFromDriveUploadSource(source);
  } catch {
    store.failTransfer(
      transferId,
      messages.drive_upload_failed_read(undefined, { locale })
    );
    return;
  }
  const file = store.addFile({
    blob,
    deviceId: target.deviceId,
    ...(folderPath ? { folderPath } : {}),
    name: source.name,
    spaceId: target.spaceId,
  });
  store.completeTransfer(transferId, { fileId: file.id });
}

async function blobFromDriveUploadSource(source: File) {
  // Snapshot the bytes for non-native/demo runtimes: a File handle keeps reading
  // from disk, and the space's copy must not change if the picked file later
  // moves or changes. Electron node uploads use a Main-owned stream instead.
  const bytes = await source.arrayBuffer();
  return new Blob([bytes], { type: driveUploadMimeType(source.name, source.type) });
}

export async function uploadDriveFiles(
  store: DriveStore,
  sources: readonly File[],
  target: { deviceId: string; folderPath?: string; spaceId: string },
  deps: DriveTransferDeps
): Promise<void> {
  const pending = sources.map((source) => ({
    source,
    transfer: store.beginTransfer({
      detail: driveFileTypeLabel(source.name),
      direction: "upload",
      fileName: source.name,
      spaceId: target.spaceId,
      uploadSource: source,
    }),
  }));
  await runWithConcurrency(pending, ({ source, transfer }) =>
    runUpload(store, transfer.id, source, target, deps)
  );
}

async function runWithConcurrency<T>(
  values: readonly T[],
  run: (value: T) => Promise<unknown>
) {
  let next = 0;
  const worker = async () => {
    for (;;) {
      const index = next;
      next += 1;
      if (index >= values.length) return;
      await run(values[index]!);
    }
  };
  await Promise.all(
    Array.from({ length: Math.min(DRIVE_TRANSFER_CONCURRENCY, values.length) }, () =>
      worker()
    )
  );
}

export async function retryDriveTransfer(
  store: DriveStore,
  transferId: string,
  target: { deviceId: string; spaceId: string },
  deps: DriveTransferDeps
): Promise<void> {
  const transfer = store.transferById(transferId);
  if (!transfer || transfer.status !== "error") return;

  if (transfer.direction === "upload") {
    const source = store.uploadSource(transferId);
    if (!source) return;
    store.restartTransfer(transferId);
    await runUpload(
      store,
      transferId,
      source,
      { deviceId: target.deviceId, spaceId: transfer.spaceId ?? target.spaceId },
      deps
    );
    return;
  }

  const file = transfer.fileId ? store.fileById(transfer.fileId) : undefined;
  if (!file) return;
  store.restartTransfer(transferId);
  await runDownload(store, transferId, file, deps);
}
