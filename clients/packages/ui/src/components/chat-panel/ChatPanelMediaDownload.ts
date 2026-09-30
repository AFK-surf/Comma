export interface DownloadMediaSourceOptions {
  fileName?: string;
  source: string;
}

/**
 * Every downloadable the chat panel renders. Generated documents carry no
 * renderer-fetchable `source`; the application capability closes over their
 * byte source instead.
 */
export type ChatPanelMediaDownloadKind = "audio" | "file" | "image" | "video";

export interface ChatPanelMediaDownloadRequest {
  fileName: string;
  kind: ChatPanelMediaDownloadKind;
  source?: string;
}

export type ChatPanelMediaDownloadErrorCode =
  | "unauthorized"
  | "forbidden"
  | "not-found"
  | "too-large"
  | "expired"
  | "network"
  | "unsupported"
  | "unknown";

export type ChatPanelMediaDownloadResult =
  | {
      status: "success";
    }
  | {
      code: ChatPanelMediaDownloadErrorCode;
      httpStatus?: number;
      retryable: boolean;
      status: "error";
    };

export interface ChatPanelMediaDownloadCapability {
  execute: (
    request: ChatPanelMediaDownloadRequest
  ) => ChatPanelMediaDownloadResult | Promise<ChatPanelMediaDownloadResult>;
}

export interface ChatPanelMediaDownloadAction {
  capability: ChatPanelMediaDownloadCapability;
  fileName: string;
  fileSize?: number | string;
}

export const formatMediaFileSize = (fileSize: number | string) => {
  if (typeof fileSize === "string") return fileSize;
  if (!Number.isFinite(fileSize) || fileSize < 0) return "0B";

  const units = ["B", "KB", "MB", "GB", "TB"] as const;
  let value = fileSize;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }

  const roundedValue =
    value >= 10 || Number.isInteger(value) ? value.toFixed(0) : value.toFixed(1);
  return `${roundedValue}${units[unitIndex]}`;
};

const resolveDownloadFileName = (source: string, fileName?: string) => {
  if (fileName?.trim()) return fileName.trim();

  try {
    const pathName = new URL(source, document.baseURI).pathname;
    const encodedName = pathName.split("/").at(-1);
    if (!encodedName) return "download";

    try {
      return decodeURIComponent(encodedName);
    } catch {
      return encodedName;
    }
  } catch {
    return "download";
  }
};

/**
 * Explicit browser adapter for application-owned download capabilities.
 *
 * The generated-media components never call this helper themselves. An
 * application may use it from a capability when its URL contract guarantees
 * that the renderer can fetch the source.
 */
export const downloadMediaSource = async ({
  fileName,
  source,
}: DownloadMediaSourceOptions) => {
  const response = await fetch(source);
  if (!response.ok) {
    throw new Error(`Media download failed with status ${response.status}.`);
  }

  const objectUrl = URL.createObjectURL(await response.blob());
  const anchor = document.createElement("a");
  anchor.download = resolveDownloadFileName(source, fileName);
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
