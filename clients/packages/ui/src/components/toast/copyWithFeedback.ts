import type { useCommaMessages } from "@comma/i18n/react";
import { toast } from "./toastApi";

type CopyMessages = Pick<
  ReturnType<typeof useCommaMessages>,
  "common_copied" | "copy_failed_title" | "copy_failed_detail"
>;

/**
 * Shared id so copies in a row update one toast in place instead of stacking,
 * and a failure replaces the success it invalidates.
 */
export const COPY_FEEDBACK_TOAST_ID = "copy-feedback";

export interface CopyFeedbackOptions {
  /** Confirmation title naming what was copied; "Copied" by default. */
  copied?: string;
  copiedDetail?: string;
  /** A surface whose other results share one toast passes its own id. */
  id?: string;
  /** False keeps a failed write quiet, for a copy the person did not ask for. */
  reportFailure?: boolean;
}

/** Feedback for an explicit copy action, after its clipboard write settles. */
export async function copyWithFeedback(
  write: () => Promise<void> | void,
  messages: CopyMessages,
  {
    copied = messages.common_copied(),
    copiedDetail,
    id = COPY_FEEDBACK_TOAST_ID,
    reportFailure = true,
  }: CopyFeedbackOptions = {}
): Promise<boolean> {
  try {
    await write();
  } catch {
    if (reportFailure) {
      toast.error(messages.copy_failed_title(), {
        description: messages.copy_failed_detail(),
        id,
        testId: "copy-feedback",
      });
    }
    return false;
  }
  toast.success(copied, {
    ...(copiedDetail === undefined ? {} : { description: copiedDetail }),
    id,
    testId: "copy-feedback",
  });
  return true;
}
