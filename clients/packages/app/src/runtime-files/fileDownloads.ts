import { messages, type CommaLocale } from "@comma/i18n";
import {
  fileDownloadMaxBytes,
  getNativeBridge,
  type CommaNativeBridge,
  type FilesSaveDownloadResult,
} from "@comma/native-bridge";
import {
  toast,
  type ChatPanelMediaDownloadCapability,
  type ChatPanelMediaDownloadResult,
} from "@comma/ui";
import { CommaApiError } from "../api";

/**
 * The client's single download path.
 *
 * A caller only says what the file is called and how to get its bytes; this
 * module owns everything after that — placing the file, telling the user where
 * it went, and turning the toast's actions back into operating-system calls.
 * Bytes are resolved in the renderer because that is where the authenticated
 * transport lives; Main owns the Downloads directory and hands back an opaque
 * handle, so no host path ever reaches this side.
 */
export type ResolveFileBytes = (signal?: AbortSignal) => Promise<Blob>;

export interface FileDownloadRequest {
  fileName: string;
  resolve: ResolveFileBytes;
}

type FileDownloadBridge = Pick<CommaNativeBridge, "files" | "os" | "platform">;

export interface FileDownloadOptions {
  bridge?: FileDownloadBridge;
  locale: CommaLocale;
}

/**
 * One id for the whole surface: downloading a second file replaces the first
 * toast rather than stacking, matching the product's other one-shot action
 * results.
 */
export const FILE_DOWNLOAD_TOAST_ID = "file-download";

const failedDownload: ChatPanelMediaDownloadResult = {
  code: "unknown",
  retryable: true,
  status: "error",
};

type DownloadError = Extract<ChatPanelMediaDownloadResult, { status: "error" }>;

const retrievalError = (error: unknown): DownloadError => {
  if (!(error instanceof CommaApiError)) {
    return { code: "network", retryable: true, status: "error" };
  }

  const { status: httpStatus } = error;
  let code: DownloadError["code"] = "unsupported";
  if (httpStatus === 404 || httpStatus === 410) code = "not-found";
  else if (
    httpStatus === 401 ||
    (httpStatus === 409 && error.body?.error === "session_changed")
  )
    code = "unauthorized";
  else if (httpStatus === 403) code = "forbidden";
  else if (httpStatus === 413) code = "too-large";
  else if (httpStatus === 408 || httpStatus === 429 || httpStatus >= 500) {
    code = "network";
  }

  return { code, httpStatus, retryable: code === "network", status: "error" };
};

const showRetrievalFailed = (
  fileName: string,
  locale: CommaLocale,
  error: DownloadError
) => {
  const description = {
    "not-found": messages.file_download_unavailable_description,
    unauthorized: messages.file_download_unauthorized_description,
    forbidden: messages.file_download_forbidden_description,
    "too-large": messages.file_download_too_large_description,
    network: messages.file_download_network_description,
    unsupported: messages.file_download_unsupported_description,
    expired: messages.file_download_unavailable_description,
    unknown: messages.file_download_network_description,
  }[error.code];
  toast.error(messages.file_download_failed_title(undefined, { locale }), {
    description: description({ fileName }, { locale }),
    id: FILE_DOWNLOAD_TOAST_ID,
    testId: FILE_DOWNLOAD_TOAST_ID,
  });
};

/**
 * macOS names the file manager in the action itself; every other desktop says
 * "folder". This mirrors how the settings surface picks menu-bar vs system-tray
 * wording from the same bridge field.
 */
export const revealLabel = (
  os: CommaNativeBridge["os"],
  locale: CommaLocale
): string =>
  os === "macos"
    ? messages.file_download_reveal_in_finder(undefined, { locale })
    : messages.file_download_show_in_folder(undefined, { locale });

const showDownloadFailed = (fileName: string, locale: CommaLocale) => {
  toast.error(messages.file_download_failed_title(undefined, { locale }), {
    description: messages.file_download_failed_description({ fileName }, { locale }),
    id: FILE_DOWNLOAD_TOAST_ID,
    testId: FILE_DOWNLOAD_TOAST_ID,
  });
};

const showRevealFailed = (fileName: string, locale: CommaLocale) => {
  toast.error(messages.file_download_missing_title(undefined, { locale }), {
    description: messages.file_download_missing_description({ fileName }, { locale }),
    id: FILE_DOWNLOAD_TOAST_ID,
    testId: FILE_DOWNLOAD_TOAST_ID,
  });
};

const showOpenFailed = (fileName: string, locale: CommaLocale) => {
  toast.error(messages.file_download_open_failed_title(undefined, { locale }), {
    description: messages.file_download_open_failed_description(
      { fileName },
      { locale }
    ),
    id: FILE_DOWNLOAD_TOAST_ID,
    testId: FILE_DOWNLOAD_TOAST_ID,
  });
};

const showSavedInDownloads = ({
  bridge,
  locale,
  saved,
}: {
  bridge: FileDownloadBridge;
  locale: CommaLocale;
  saved: Extract<FilesSaveDownloadResult, { status: "saved" }>;
}) => {
  toast.success(messages.file_download_complete_title(undefined, { locale }), {
    actions: [
      {
        hierarchy: "secondary-gray",
        label: revealLabel(bridge.os, locale),
        onPress: () => {
          void bridge.files
            .revealDownload({ downloadRef: saved.downloadRef })
            .then((result) => {
              if (result.status !== "revealed") {
                showRevealFailed(saved.fileName, locale);
              }
            });
        },
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
    id: FILE_DOWNLOAD_TOAST_ID,
    testId: FILE_DOWNLOAD_TOAST_ID,
  });
};

/**
 * The browser owns its own download location and its own completion UI, so the
 * web toast reports the outcome without offering actions this runtime cannot
 * perform.
 */
export const saveThroughBrowser = (blob: Blob, fileName: string) => {
  const objectUrl = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.download = fileName;
  anchor.href = objectUrl;
  anchor.rel = "noopener";
  anchor.hidden = true;
  document.body.append(anchor);

  try {
    anchor.click();
  } finally {
    anchor.remove();
    globalThis.setTimeout(() => URL.revokeObjectURL(objectUrl), 0);
  }
};

export async function downloadFile(
  { fileName, resolve }: FileDownloadRequest,
  { bridge = getNativeBridge(), locale }: FileDownloadOptions
): Promise<ChatPanelMediaDownloadResult> {
  let blob: Blob;
  try {
    blob = await resolve();
  } catch (error) {
    const failure = retrievalError(error);
    showRetrievalFailed(fileName, locale, failure);
    return failure;
  }

  // The server locator, browser adapter, and native IPC leaf all own this same
  // inclusive byte domain. Check before choosing an adapter so Web cannot
  // promise a download that the desktop surface must reject.
  if (blob.size > fileDownloadMaxBytes) {
    const failure: DownloadError = {
      code: "too-large",
      retryable: false,
      status: "error",
    };
    showRetrievalFailed(fileName, locale, failure);
    return failure;
  }

  if (bridge.platform !== "electron") {
    saveThroughBrowser(blob, fileName);
    toast.success(messages.file_download_complete_title(undefined, { locale }), {
      // The browser, not Comma, chose where this landed — say only what is true.
      description: messages.file_download_complete_browser_description(
        { fileName },
        { locale }
      ),
      id: FILE_DOWNLOAD_TOAST_ID,
      testId: FILE_DOWNLOAD_TOAST_ID,
    });
    return { status: "success" };
  }

  let saved: FilesSaveDownloadResult;
  try {
    saved = await bridge.files.saveDownload({
      content: new Uint8Array(await blob.arrayBuffer()),
      fileName,
    });
  } catch {
    showDownloadFailed(fileName, locale);
    return failedDownload;
  }

  if (saved.status !== "saved") {
    showDownloadFailed(fileName, locale);
    return failedDownload;
  }

  showSavedInDownloads({ bridge, locale, saved });
  return { status: "success" };
}

/**
 * Opens or reveals content that has no local file yet (a server-held document
 * such as a skill's SKILL.md): places one copy in Downloads, then hands it to
 * the operating system. Returns the copy's handle; pass it back as
 * `downloadRef` so a repeated action reuses that copy instead of writing
 * "name (1)". A handle whose file the user has since removed is replaced by a
 * fresh copy. Desktop only: a browser cannot open or reveal a local file.
 */
export async function saveFileAndShow(
  { content, fileName }: { content: Blob; fileName: string },
  show: "open" | "reveal",
  {
    bridge = getNativeBridge(),
    downloadRef,
    locale,
  }: FileDownloadOptions & { downloadRef?: string | undefined }
): Promise<string | undefined> {
  const showRef = async (ref: string) =>
    show === "open"
      ? (await bridge.files.openDownload({ downloadRef: ref })).status === "opened"
      : (await bridge.files.revealDownload({ downloadRef: ref })).status === "revealed";

  if (downloadRef && (await showRef(downloadRef))) return downloadRef;

  let saved: FilesSaveDownloadResult;
  try {
    saved = await bridge.files.saveDownload({
      content: new Uint8Array(await content.arrayBuffer()),
      fileName,
    });
  } catch {
    showDownloadFailed(fileName, locale);
    return undefined;
  }

  if (saved.status !== "saved") {
    showDownloadFailed(fileName, locale);
    return undefined;
  }

  if (!(await showRef(saved.downloadRef))) {
    if (show === "open") showOpenFailed(saved.fileName, locale);
    else showRevealFailed(saved.fileName, locale);
  }
  return saved.downloadRef;
}

/**
 * Adapts the shared path to the chat panel's download slot, so a card renders
 * an action without knowing anything about Downloads folders or toasts.
 */
export function createFileDownloadCapability(
  resolve: ResolveFileBytes,
  options: FileDownloadOptions
): ChatPanelMediaDownloadCapability {
  return {
    execute: ({ fileName }) => downloadFile({ fileName, resolve }, options),
  };
}
