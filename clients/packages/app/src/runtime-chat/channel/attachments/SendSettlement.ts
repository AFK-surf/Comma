import type { AttachmentAdmissions } from "./admissions/AttachmentAdmissions";
import type { AttachmentAdmission } from "./admissions/attachmentAdmission";
import type { NativeAttachments } from "./NativeAttachments";
import type { PickFailures } from "./picking/PickFailures";

/**
 * One send's wait for the draft attachments it carries. Each round waits for
 * every attachment known when it starts; once a round ends with nothing
 * added, removed, or still uploading, the send is admitted or refused.
 */
export class SendSettlement {
  readonly #admissions: AttachmentAdmissions;
  readonly #failures: PickFailures;
  readonly #native: NativeAttachments;
  readonly #observedAdmissions = new Set<AttachmentAdmission>();
  #admissionRevision = 0;

  constructor(
    admissions: AttachmentAdmissions,
    native: NativeAttachments,
    failures: PickFailures
  ) {
    this.#admissions = admissions;
    this.#native = native;
    this.#failures = failures;
  }

  round(): Promise<unknown> {
    this.#admissionRevision = this.#admissions.revision;
    const admissions = this.#admissions.all();
    for (const admission of admissions) this.#observedAdmissions.add(admission);
    const nativeAttachmentIds = new Set(
      this.#native.list.map((attachment) => attachment.id)
    );
    return Promise.all([
      this.#native.waitForSettled(nativeAttachmentIds),
      ...admissions.flatMap((admission) =>
        admission.completion ? [admission.completion] : []
      ),
    ]);
  }

  /** Whether the attachments moved during the round, so another is due. */
  moved() {
    return (
      this.#admissionRevision !== this.#admissions.revision ||
      this.#admissions
        .all()
        .some(
          (admission) =>
            admission.outcome === "pending" || admission.outcome === "removing"
        ) ||
      this.#native.list.some((attachment) => attachment.status === "uploading")
    );
  }

  assertSendable() {
    const hasFailedAdmission = [...this.#observedAdmissions].some(
      (admission) => admission.outcome === "failed"
    );
    const hasFailedNativeAttachment = this.#native.list.some(
      (attachment) => attachment.status === "failed"
    );
    const missingUploadedAdmission = [...this.#observedAdmissions].some(
      (admission) =>
        admission.outcome === "uploaded" &&
        admission.nativeAttachmentId !== undefined &&
        !this.#native.list.some(
          (attachment) => attachment.id === admission.nativeAttachmentId
        )
    );
    if (
      hasFailedAdmission ||
      hasFailedNativeAttachment ||
      missingUploadedAdmission ||
      // Unresolved picker failures are part of this draft: the user must
      // remove or resolve them before the message may be committed.
      this.#failures.size > 0
    ) {
      throw new Error(
        "An attachment could not be added. Remove or retry it, then send again."
      );
    }
  }
}
