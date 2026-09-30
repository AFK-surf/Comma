import { getNativeBridge } from "@comma/native-bridge";
import type { AttachmentUploadInput } from "../../../../components/chat/model/conversationChannel";
import type { ProjectionFence } from "../../projection/ProjectionFence";
import { attachmentAdmissionError } from "../admissions/attachmentAdmission";
import type { AttachmentChannel } from "../attachmentChannel";
import type { NativePick } from "./NativePick";
import type { PickFailures } from "./PickFailures";

/**
 * Electron's local-file picks, each queued in the draft command sequence:
 * the picker control, files dropped or pasted into the composer, and the
 * replacement pick that retries an intake failure row.
 */
export class LocalFilePicker {
  readonly #channel: AttachmentChannel;
  readonly #failures: PickFailures;
  readonly #fence: ProjectionFence;
  readonly #nativePick: NativePick;
  readonly #localFilePickRetries = new Map<string, Promise<unknown>>();
  #localFilePickOperation: Promise<unknown> | undefined;

  constructor(
    channel: AttachmentChannel,
    {
      failures,
      fence,
      nativePick,
    }: { failures: PickFailures; fence: ProjectionFence; nativePick: NativePick }
  ) {
    this.#channel = channel;
    this.#failures = failures;
    this.#fence = fence;
    this.#nativePick = nativePick;
  }

  /** Whether these files are picked through Main rather than uploaded. */
  accepts(files: AttachmentUploadInput[]) {
    return (
      getNativeBridge().platform === "electron" &&
      files.every((file) => typeof File !== "undefined" && file.data instanceof File)
    );
  }

  attachSelected(files: AttachmentUploadInput[]) {
    const { commands, lease } = this.#channel;
    const selected = files.map((file) => file.data as File);
    const generation = lease.generation;
    const projectionGeneration = this.#fence.generation;
    const isCurrent = () =>
      lease.active &&
      generation === lease.generation &&
      projectionGeneration === this.#fence.generation;
    void commands
      .enqueue(async () => {
        if (isCurrent()) await this.#nativePick.pick(selected);
      })
      .catch((error) => {
        if (!isCurrent()) return;
        const id = this.#channel.nextLocalId("renderer-intake-failure");
        this.#failures.recordSelection(id, files, {
          id,
          name: selected[0]!.name,
          size: 0,
          path: undefined,
          isImage: false,
          status: "failed",
          error: attachmentAdmissionError(error, this.#channel.locale),
        });
        this.#channel.publish();
      });
  }

  pickNative() {
    if (this.#localFilePickOperation) return this.#localFilePickOperation;
    const operation = this.#channel.commands.enqueue(async () => {
      await this.#nativePick.pick();
    });
    this.#localFilePickOperation = operation;
    void operation.then(
      () => this.#settleLocalFilePick(operation),
      () => this.#settleLocalFilePick(operation)
    );
    return operation;
  }

  retryIntakeFailure(attachmentId: string) {
    const existing = this.#localFilePickRetries.get(attachmentId);
    if (existing) return existing;

    // Reserve a genuinely fresh picker in the draft command sequence now,
    // before a Send click can reserve its intent. Keep the old Main-owned
    // failure gate until that replacement claim has reached a terminal
    // outcome; a lost/failed replacement reply must leave the old failure
    // retryable rather than opening a gap in send admission.
    const { commands, lease, surfaceId } = this.#channel;
    const operation = commands.enqueue(async () => {
      const claimed = await this.#nativePick.pick();
      if (!claimed) {
        throw new Error("No attachment slot is available for a replacement selection.");
      }
      return lease.runWhenReady(async (currentLease) => {
        const receipt = await getNativeBridge().chat.retryAttachment({
          ...currentLease,
          attachmentId,
          surfaceId,
        });
        commands.observeDraftEpoch(receipt);
        if (this.#failures.resolve(attachmentId)) {
          this.#channel.publish();
        }
        return receipt;
      });
    });
    this.#localFilePickRetries.set(attachmentId, operation);
    this.#localFilePickOperation = operation;
    void operation.then(
      () => this.#settleLocalFilePickRetry(attachmentId, operation),
      () => this.#settleLocalFilePickRetry(attachmentId, operation)
    );
    return operation;
  }

  /** Forgets the picks in flight, so later picks and retries start afresh. */
  abandon() {
    this.#localFilePickRetries.clear();
    this.#localFilePickOperation = undefined;
  }

  #settleLocalFilePick(operation: Promise<unknown>) {
    if (this.#localFilePickOperation === operation) {
      this.#localFilePickOperation = undefined;
    }
  }

  #settleLocalFilePickRetry(attachmentId: string, operation: Promise<unknown>) {
    if (this.#localFilePickRetries.get(attachmentId) === operation) {
      this.#localFilePickRetries.delete(attachmentId);
    }
    this.#settleLocalFilePick(operation);
  }
}
