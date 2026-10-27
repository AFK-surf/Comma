import { uiClock } from "@comma/ui/clock";
import { messages, type CommaLocale } from "@comma/i18n";
import {
  fileDownloadMaxBytes,
  getNativeBridge,
  type CommaNativeBridge,
  type FilesSaveDownloadResult,
} from "@comma/native-bridge";
import { toast } from "@comma/ui/components/toast";
import {
  type ChatPanelMediaDownloadCapability,
  type ChatPanelMediaDownloadResult,
} from "@comma/ui/components/chat-panel";
import { CoreError } from "@comma/core-client";

/**
 * The client's single download path.
 *
 * A caller only says what the file is called and how to get its bytes; this
 * module owns everything after that — placing the file, telling the user where
 * it went, and turning the toast's actions back into operating-system calls.
 * The caller's resolver gets the bytes (the core's `files.read` for chat files);
 * Main owns the Downloads directory and hands back an opaque handle, so no host
 * path ever reaches this side.
 */
export type ResolveFileBytes = (signal?: AbortSignal) => Promise<Blob>;

/**
 * Saves the file into Downloads as it arrives, without reading it whole (the
 * core's `files.save`, desktop only): its handle and the name it took, or null.
 */
export type SaveToDownloads = () => Promise<{
  downloadRef: string;
  fileName: string;
} | null>;

/**
 * A URL a browser downloads the file from itself, at any size (the server's
 * media URL of a chat file, the core's `files.link`, which answers it as an
 * attachment under its own name). Asked for when the person downloads.
 */
export type DownloadLink = () => Promise<string>;

export interface FileDownloadRequest {
  fileName: string;
  resolve: ResolveFileBytes;
  /** How the desktop saves the file instead, at any size (a chat file). */
  save?: SaveToDownloads | undefined;
  /** How a browser downloads the file instead, at any size (a chat file on the web). */
  link?: DownloadLink | undefined;
  /**
   * How the file is read a part at a time instead, at any size, for a browser to save: one with no link to it (a
   * Task's on a machine: `no_link`).
   */
  parts?: ResolveFileBytes | undefined;
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
  // A file the core read: refused by the server (its code and status), over the
  // limit, or with no answer.
  if (
    error instanceof CoreError &&
    error.code === "too_large" &&
    error.status === undefined
  )
    return { code: "too-large", retryable: false, status: "error" };
  const refusal =
    error instanceof CoreError && error.status !== undefined
      ? { httpStatus: error.status, reason: error.code }
      : undefined;
  if (!refusal) {
    return { code: "network", retryable: true, status: "error" };
  }

  const { httpStatus, reason } = refusal;
  let code: DownloadError["code"] = "unsupported";
  if (httpStatus === 404 || httpStatus === 410) code = "not-found";
  else if (httpStatus === 401 || (httpStatus === 409 && reason === "session_changed"))
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
 * web toast reports the handoff without claiming that the file was saved.
 */
export const saveThroughBrowser = (file: Blob | string, fileName: string) => {
  const objectUrl = typeof file === "string" ? undefined : URL.createObjectURL(file);
  const anchor = document.createElement("a");
  anchor.download = fileName;
  anchor.href = objectUrl ?? (file as string);
  anchor.rel = "noopener";
  anchor.hidden = true;
  document.body.append(anchor);

  try {
    anchor.click();
  } finally {
    anchor.remove();
    if (objectUrl) uiClock.after(0, () => URL.revokeObjectURL(objectUrl));
  }
};

/** Download frames kept at once, the oldest removed first. */
const MAX_DOWNLOAD_FRAMES = 4;
/** The frames of recent linked downloads, oldest first. */
let browserDownloadFrames: HTMLIFrameElement[] = [];

/**
 * Each download navigates a hidden frame of its own, so a later download never replaces one still waiting for its
 * response headers. The browser owns a download once it starts, so removing an old frame leaves its transfer running.
 */
const startLinkedBrowserDownload = (url: string) => {
  const frame = document.createElement("iframe");
  frame.hidden = true;
  frame.setAttribute("sandbox", "allow-downloads");
  document.body.append(frame);
  try {
    frame.src = url;
  } catch (error) {
    frame.remove();
    throw error;
  }
  browserDownloadFrames = [
    ...browserDownloadFrames.filter((kept) => kept.isConnected),
    frame,
  ];
  while (browserDownloadFrames.length > MAX_DOWNLOAD_FRAMES)
    browserDownloadFrames.shift()!.remove();
};

const showStartedThroughBrowser = (fileName: string, locale: CommaLocale) => {
  toast(messages.file_download_started_title(undefined, { locale }), {
    description: messages.file_download_started_browser_description(
      { fileName },
      { locale }
    ),
    id: FILE_DOWNLOAD_TOAST_ID,
    testId: FILE_DOWNLOAD_TOAST_ID,
  });
};

export async function downloadFile(
  { fileName, resolve, save, link, parts }: FileDownloadRequest,
  { bridge = getNativeBridge(), locale }: FileDownloadOptions
): Promise<ChatPanelMediaDownloadResult> {
  // A file with no link to it (a Task's on a machine: `no_link`) is read a part at a time, at any size, and handed to
  // the browser.
  let url: string | null = null;
  if (link && bridge.platform !== "electron") {
    try {
      url = await link();
    } catch (error) {
      if (!(error instanceof CoreError && error.code === "no_link")) {
        const failure = retrievalError(error);
        showRetrievalFailed(fileName, locale, failure);
        return failure;
      }
      if (parts) {
        let read: Blob;
        try {
          read = await parts();
        } catch (partError) {
          const failure = retrievalError(partError);
          showRetrievalFailed(fileName, locale, failure);
          return failure;
        }
        saveThroughBrowser(read, fileName);
        showStartedThroughBrowser(fileName, locale);
        return { status: "started" };
      }
    }
  }
  if (url !== null) {
    try {
      startLinkedBrowserDownload(url);
    } catch {
      toast.error(messages.file_download_failed_title(undefined, { locale }), {
        description: messages.file_download_browser_start_description(
          { fileName },
          { locale }
        ),
        id: FILE_DOWNLOAD_TOAST_ID,
        testId: FILE_DOWNLOAD_TOAST_ID,
      });
      return failedDownload;
    }
    showStartedThroughBrowser(fileName, locale);
    return { status: "started" };
  }

  if (save && bridge.platform === "electron") {
    let saved: Awaited<ReturnType<SaveToDownloads>>;
    try {
      saved = await save();
    } catch (error) {
      const failure = retrievalError(error);
      showRetrievalFailed(fileName, locale, failure);
      return failure;
    }
    if (!saved) {
      showDownloadFailed(fileName, locale);
      return failedDownload;
    }
    showSavedInDownloads({ bridge, locale, saved: { ...saved, status: "saved" } });
    return { status: "success" };
  }

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
    showStartedThroughBrowser(fileName, locale);
    return { status: "started" };
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
  options: FileDownloadOptions,
  { save, link, parts }: Pick<FileDownloadRequest, "save" | "link" | "parts"> = {}
): ChatPanelMediaDownloadCapability {
  return {
    execute: ({ fileName }) =>
      downloadFile({ fileName, resolve, save, link, parts }, options),
  };
}
