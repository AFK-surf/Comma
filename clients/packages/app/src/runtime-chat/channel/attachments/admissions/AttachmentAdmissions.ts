import type { AttachmentUploadInput } from "../../../../components/chat/model/conversationChannel";
import type { AttachmentChannel } from "../attachmentChannel";
import { AdmissionUploads, type AdmissionLedger } from "./AdmissionUploads";
import {
  attachmentAdmissionError,
  cancelAttachmentAdmission,
  createAttachmentAdmission,
  reconcileAttachmentAdmissions,
  restartAttachmentAdmission,
  type AttachmentAdmission,
} from "./attachmentAdmission";

/**
 * Files this renderer uploads through Main's `chat.attach`. Each shows as the
 * renderer's own row until Main projects the attachment it became.
 */
export class AttachmentAdmissions implements AdmissionLedger {
  readonly #admissions = new Map<string, AttachmentAdmission>();
  readonly #channel: AttachmentChannel;
  readonly #uploads: AdmissionUploads;
  #revision = 0;

  constructor(channel: AttachmentChannel) {
    this.#channel = channel;
    this.#uploads = new AdmissionUploads(this, channel);
  }

  /** Moves whenever an admission is added, restarted, removed, or fails. */
  get revision() {
    return this.#revision;
  }

  all() {
    return [...this.#admissions.values()];
  }

  get(attachmentId: string) {
    return this.#admissions.get(attachmentId);
  }

  admit(files: AttachmentUploadInput[]) {
    const admissions = files.map((file) =>
      createAttachmentAdmission(
        file,
        this.#channel.nextLocalId("renderer-attachment"),
        this.#channel.lease.generation
      )
    );

    for (const admission of admissions) {
      this.#admissions.set(admission.attachment.id, admission);
    }
    this.#revision += 1;

    for (const admission of admissions) {
      this.#start(admission);
    }
  }

  /** Uploads a failed admission again; false when it has not failed. */
  restart(admission: AttachmentAdmission) {
    if (admission.attachment.status !== "failed") {
      return false;
    }
    restartAttachmentAdmission(admission);
    this.#revision += 1;
    this.#start(admission);
    return true;
  }

  /** Removes the admission with this own or Main attachment id, if any. */
  requestRemoval(attachmentId: string) {
    const admission =
      this.#admissions.get(attachmentId) ??
      this.all().find((candidate) => candidate.nativeAttachmentId === attachmentId);
    if (!admission) {
      return false;
    }
    this.#requestRemoval(admission);
    return true;
  }

  cancelAll() {
    for (const admission of this.#admissions.values()) {
      cancelAttachmentAdmission(admission);
    }
    this.#admissions.clear();
  }

  /** The rows of admissions Main does not project yet. */
  pending() {
    return this.all()
      .filter(
        (admission) => !admission.nativeAttachmentId && admission.outcome !== "removing"
      )
      .map((admission) => admission.attachment);
  }

  reconcile() {
    reconcileAttachmentAdmissions(this.all(), this.#channel.native);
  }

  isCurrent(admission: AttachmentAdmission) {
    return (
      this.#channel.lease.active &&
      admission.generation === this.#channel.lease.generation &&
      this.#admissions.get(admission.attachment.id) === admission
    );
  }

  delete(admission: AttachmentAdmission) {
    if (this.#admissions.get(admission.attachment.id) !== admission) {
      return;
    }
    this.#admissions.delete(admission.attachment.id);
    this.#revision += 1;
  }

  fail(admission: AttachmentAdmission, error: unknown) {
    admission.attachment = {
      ...admission.attachment,
      error: attachmentAdmissionError(error, this.#channel.locale),
      status: "failed",
    };
    admission.outcome = "failed";
    this.#revision += 1;
  }

  #start(admission: AttachmentAdmission) {
    admission.completion = Promise.race([
      Promise.resolve().then(() => this.#uploads.upload(admission)),
      admission.cancelled.promise,
    ]);
  }

  #requestRemoval(admission: AttachmentAdmission) {
    if (admission.outcome === "cancelled" || admission.outcome === "removing") {
      return;
    }
    if (admission.outcome === "failed") {
      if (!admission.nativeAttachmentId) {
        cancelAttachmentAdmission(admission);
        this.delete(admission);
        return;
      }
      admission.outcome = "removing";
      this.#channel.native.suppress(admission.nativeAttachmentId);
      admission.removalRequested.resolve();
      this.#revision += 1;
      admission.completion = this.#uploads.remove(admission);
      return;
    }
    if (!admission.attachStarted) {
      cancelAttachmentAdmission(admission);
      this.delete(admission);
      return;
    }
    admission.outcome = "removing";
    if (admission.nativeAttachmentId) {
      this.#channel.native.suppress(admission.nativeAttachmentId);
    }
    admission.removalRequested.resolve();
    this.#revision += 1;
  }
}
