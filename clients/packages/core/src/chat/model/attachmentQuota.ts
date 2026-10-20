// What a draft has room for: the limits a pick admits files within (the core's picks, and files dropped on Electron's
// windows, which Main reads).
import type { DraftAttachment } from "./conversationChannel";
import { MAX_ATTACHMENTS_PER_MESSAGE } from "./protocol";

/** A file the core keeps on this computer (not uploaded): its preview ref. */
export const localFilePreviewRefPattern = /^lfi1_[A-Za-z0-9_-]{43}$/;

/** A local file a draft may carry: at most 50, of 1 GiB together. */
const MAX_LOCAL_FILES = 50;
const MAX_LOCAL_BYTES = 1024 * 1024 * 1024;

/**
 * What one pick may add to a draft that has `attachments`: local files and uploads each count against their own
 * limit, so what is admitted does not depend on the order files were picked in. Null when the draft has no room.
 */
export function pickQuota(
  attachments: readonly Pick<DraftAttachment, "id" | "localFile" | "size">[]
): { maxFiles: number; maxTotalSize: number; maxUploadFiles: number } | null {
  const local = attachments.filter(
    (a) => a.localFile !== undefined || localFilePreviewRefPattern.test(a.id)
  );
  const maxFiles = Math.max(0, MAX_LOCAL_FILES - local.length);
  const maxTotalSize = Math.max(
    0,
    MAX_LOCAL_BYTES - local.reduce((total, a) => total + a.size, 0)
  );
  const maxUploadFiles = Math.max(
    0,
    MAX_ATTACHMENTS_PER_MESSAGE - (attachments.length - local.length)
  );
  return maxFiles === 0 && maxUploadFiles === 0
    ? null
    : { maxFiles, maxTotalSize, maxUploadFiles };
}
