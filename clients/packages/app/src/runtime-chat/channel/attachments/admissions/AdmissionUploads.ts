import { getNativeBridge } from "@comma/native-bridge";
import type { AttachmentChannel } from "../attachmentChannel";
import type { AttachmentAdmission } from "./attachmentAdmission";

/** What an upload needs from the admissions it belongs to. */
export type AdmissionLedger = {
  delete(admission: AttachmentAdmission): void;
  fail(admission: AttachmentAdmission, error: unknown): void;
  isCurrent(admission: AttachmentAdmission): boolean;
  reconcile(): void;
};

/**
 * The Main round trips of an admission: attaching its file, then waiting for
 * Main to settle the attachment or removing it again.
 */
export class AdmissionUploads {
  readonly #channel: AttachmentChannel;
  readonly #ledger: AdmissionLedger;

  constructor(ledger: AdmissionLedger, channel: AttachmentChannel) {
    this.#ledger = ledger;
    this.#channel = channel;
  }

  async upload(admission: AttachmentAdmission) {
    const ledger = this.#ledger;
    const { commands, lease, native, surfaceId } = this.#channel;
    try {
      if (!ledger.isCurrent(admission)) {
        return;
      }
      const buffer = await admission.file.data.arrayBuffer();
      if (!ledger.isCurrent(admission)) {
        return;
      }

      const ready = lease.ready;
      if (!ready) {
        throw new Error("Chat bridge is not retained.");
      }
      await ready;
      if (!ledger.isCurrent(admission)) {
        return;
      }

      admission.nativeAttachmentIdsAtStart = new Set(
        native.list.map((attachment) => attachment.id)
      );
      admission.attachStarted = true;
      const attachReceipt = await getNativeBridge().chat.attach({
        ...lease.requiredLease(admission.generation),
        bytes: new Uint8Array(buffer),
        name: admission.file.name,
        size: admission.file.size,
        surfaceId,
      });
      commands.observeDraftEpoch(attachReceipt);
      if (!ledger.isCurrent(admission)) {
        return;
      }

      admission.receiptAccepted = true;
      ledger.reconcile();
      this.#channel.publish();
      const settlement = await Promise.race([
        admission.authoritative.promise.then((attachment) => ({
          attachment,
          kind: "authoritative" as const,
        })),
        admission.removalRequested.promise.then(() => ({
          kind: "remove" as const,
        })),
      ]);
      if (admission.outcome === "removing" || settlement.kind === "remove") {
        await this.remove(admission);
        return;
      }
      const authoritative = settlement.attachment;
      if (!ledger.isCurrent(admission) || !authoritative) {
        return;
      }

      admission.outcome = authoritative.status === "uploaded" ? "uploaded" : "failed";
      ledger.delete(admission);
      this.#channel.publish();
    } catch (error) {
      if (!ledger.isCurrent(admission)) {
        return;
      }
      if (admission.outcome === "removing") {
        if (admission.nativeAttachmentId) {
          await this.remove(admission);
        } else {
          ledger.delete(admission);
          this.#channel.publish();
        }
        return;
      }
      ledger.fail(admission, error);
      this.#channel.publish();
    }
  }

  /** Removes the admission's attachment from Main once its id is known. */
  async remove(admission: AttachmentAdmission) {
    const { commands, lease, native, surfaceId } = this.#channel;
    const authoritative = await Promise.race([
      admission.identity.promise,
      admission.cancelled.promise.then(() => undefined),
    ]);
    if (!this.#ledger.isCurrent(admission) || !authoritative) {
      return;
    }
    native.suppress(authoritative.id);
    try {
      const receipt = await getNativeBridge().chat.removeAttachment({
        ...lease.requiredLease(admission.generation),
        attachmentId: authoritative.id,
        surfaceId,
      });
      commands.observeDraftEpoch(receipt);
    } catch (error) {
      native.unsuppress(authoritative.id);
      lease.applyBridgeError(error, admission.generation);
    } finally {
      this.#ledger.delete(admission);
      this.#channel.publish();
    }
  }
}
