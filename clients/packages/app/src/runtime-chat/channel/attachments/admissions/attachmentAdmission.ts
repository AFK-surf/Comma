import { messages, type CommaLocale } from "@comma/i18n";
import type {
  AttachmentUploadInput,
  DraftAttachment,
} from "../../../../components/chat/model/conversationChannel";
import {
  isImageAttachment,
  isTranscodedImageAttachment,
} from "../../../../components/chat/model/protocol";
import { deferred, type Deferred } from "../deferred";
import type { NativeAttachments } from "../NativeAttachments";

export type AttachmentAdmission = {
  attachment: DraftAttachment;
  attachStarted: boolean;
  authoritative: Deferred<DraftAttachment | undefined>;
  cancelled: Deferred<void>;
  completion: Promise<void> | undefined;
  file: AttachmentUploadInput;
  generation: number;
  identity: Deferred<DraftAttachment | undefined>;
  nativeAttachmentId: string | undefined;
  nativeAttachmentIdsAtStart: Set<string>;
  outcome: "pending" | "uploaded" | "failed" | "cancelled" | "removing";
  removalRequested: Deferred<void>;
  receiptAccepted: boolean;
};

export function createAttachmentAdmission(
  file: AttachmentUploadInput,
  id: string,
  generation: number
): AttachmentAdmission {
  return {
    attachment: {
      error: undefined,
      id,
      isImage: isImageAttachment(file.name) || isTranscodedImageAttachment(file.name),
      name: file.name,
      path: undefined,
      size: file.size,
      status: "uploading",
    },
    attachStarted: false,
    authoritative: deferred(),
    cancelled: deferred(),
    completion: undefined,
    file,
    generation,
    identity: deferred(),
    nativeAttachmentId: undefined,
    nativeAttachmentIdsAtStart: new Set(),
    outcome: "pending",
    removalRequested: deferred(),
    receiptAccepted: false,
  };
}

/** Returns a failed admission to its initial, uploading state. */
export function restartAttachmentAdmission(admission: AttachmentAdmission) {
  admission.attachment = {
    ...admission.attachment,
    error: undefined,
    status: "uploading",
  };
  admission.authoritative = deferred();
  admission.cancelled = deferred();
  admission.identity = deferred();
  admission.attachStarted = false;
  admission.nativeAttachmentId = undefined;
  admission.nativeAttachmentIdsAtStart = new Set();
  admission.outcome = "pending";
  admission.removalRequested = deferred();
  admission.receiptAccepted = false;
}

/** Settles everything waiting on an admission that will never complete. */
export function cancelAttachmentAdmission(admission: AttachmentAdmission) {
  admission.outcome = "cancelled";
  admission.cancelled.resolve();
  admission.authoritative.resolve(undefined);
  admission.identity.resolve(undefined);
  admission.removalRequested.resolve();
}

/**
 * Pairs each started admission with the attachment Main projects for it, and
 * settles an accepted admission once that attachment stopped uploading.
 */
export function reconcileAttachmentAdmissions(
  admissions: AttachmentAdmission[],
  native: NativeAttachments
) {
  const claimedAttachmentIds = new Set(
    admissions.flatMap((admission) =>
      admission.nativeAttachmentId ? [admission.nativeAttachmentId] : []
    )
  );

  for (const admission of admissions) {
    if (
      !admission.attachStarted ||
      (admission.outcome !== "pending" && admission.outcome !== "removing")
    ) {
      continue;
    }

    if (!admission.nativeAttachmentId) {
      const match = native.list.find(
        (attachment) =>
          attachment.name === admission.attachment.name &&
          attachment.size === admission.attachment.size &&
          !admission.nativeAttachmentIdsAtStart.has(attachment.id) &&
          !claimedAttachmentIds.has(attachment.id)
      );
      if (match) {
        admission.nativeAttachmentId = match.id;
        admission.identity.resolve(match);
        if (admission.outcome === "removing") {
          native.suppress(match.id);
        }
        claimedAttachmentIds.add(match.id);
      }
    }

    const authoritative = admission.nativeAttachmentId
      ? native.list.find((attachment) => attachment.id === admission.nativeAttachmentId)
      : undefined;
    if (
      admission.receiptAccepted &&
      authoritative &&
      authoritative.status !== "uploading"
    ) {
      admission.authoritative.resolve(authoritative);
    }
  }
}

export function attachmentAdmissionError(error: unknown, locale: CommaLocale) {
  if (error instanceof Error && error.message) {
    return error.message;
  }
  const message = String(error);
  return message && message !== "undefined"
    ? message
    : messages.chat_attachment_admission_failed({}, { locale });
}
