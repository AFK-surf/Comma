import { messages, type CommaLocale } from "@comma/i18n";
import { getNativeBridge } from "@comma/native-bridge";
import { MAX_ATTACHMENTS_PER_MESSAGE } from "../../../../components/chat/model/protocol";
import type { SessionBoundChatLease } from "../../ChannelLease";
import type { ChannelStore } from "../../channelStore";
import { localFilePreviewRefPattern } from "../../preview/LocalFilePreviews";
import type { ProjectionFence } from "../../projection/ProjectionFence";
import type { AttachmentChannel } from "../attachmentChannel";
import { deferred, type Deferred } from "../deferred";
import type { PickFailures } from "./PickFailures";

/**
 * How long a pick reply may still land after Main has published the intake as
 * settled. The projection is the authority, but it routinely beats its own
 * IPC reply by a hair; abandoning the reply on that margin would drop the
 * exact intake id the failure rows are acknowledged by. Only a reply the
 * transport genuinely never delivers should fall through to the projection.
 */
const LOST_PICK_REPLY_GRACE_MS = 500;

/**
 * One pick through Main's native attachment intake, within the draft's
 * attachment quota. Main owns the intake and its outcome; the reply only
 * attributes failed items to exact rows.
 */
export class NativePick {
  readonly #channel: AttachmentChannel;
  readonly #failures: PickFailures;
  readonly #fence: ProjectionFence;
  readonly #store: ChannelStore;
  /**
   * Whether Main has been seen reporting the dialog this pick opened. The
   * latch is released on the transition to closed, never on the first
   * projection that merely lacks the flag — that one can still be in flight
   * from before the claim registered.
   */
  #localFilePickObservedOpen = false;
  /** Resolves when Main reports the dialog this pick opened has closed. */
  #localFilePickClosed: Deferred<void> | undefined;

  constructor(
    channel: AttachmentChannel,
    {
      failures,
      fence,
      store,
    }: { failures: PickFailures; fence: ProjectionFence; store: ChannelStore }
  ) {
    this.#channel = channel;
    this.#failures = failures;
    this.#fence = fence;
    this.#store = store;
  }

  /** Picks files, or admits the given ones; false when no slot is left. */
  async pick(files?: File[]) {
    const { commands, lease, locale, native, surfaceId } = this.#channel;
    return lease.runWhenReady(async (currentLease) => {
      const lifecycleGeneration = lease.generation;
      const projectionGeneration = this.#fence.generation;
      this.#assertCurrent(lifecycleGeneration, currentLease, projectionGeneration);
      const bridge = getNativeBridge();
      const existing = this.#store.state.draftAttachments;
      // One authoritative mixed quota: each class budgets against itself.
      // Uploads never shrink the local-ref allowance and local refs never
      // shrink the image-upload allowance, so admission cannot depend on the
      // order the dialog or filesystem returned the selection in.
      const localAttachments = existing.filter(
        (attachment) =>
          attachment.localFile !== undefined ||
          localFilePreviewRefPattern.test(attachment.id)
      );
      const uploadCount = existing.length - localAttachments.length;
      const maxFiles = Math.max(0, 50 - localAttachments.length);
      const localBytes = localAttachments.reduce(
        (total, attachment) => total + attachment.size,
        0
      );
      const maxTotalSize = Math.max(0, 1024 * 1024 * 1024 - localBytes);
      const maxUploadFiles = Math.max(0, MAX_ATTACHMENTS_PER_MESSAGE - uploadCount);
      if (maxFiles === 0 && maxUploadFiles === 0) return false;
      // Main retains and projects the exact terminal outcome even if this
      // IPC reply is lost; Renderer sends no broad acknowledgement on the
      // rejection path because it has no exact intake id.
      // Main fences each claim by its own id and keeps the terminal outcome
      // on its own projection, so the reply is a convenience rather than the
      // authority. Fall back to that projection when the reply never arrives:
      // a lost reply must not strand this mutation, which would take the
      // shared draft sequence — and the picker control with it — down for the
      // rest of the session. The fallback waits out a grace window first, so
      // the ordinary case where the projection lands a beat before its own
      // reply still settles from the reply and still acknowledges by id.
      const closed = deferred();
      this.#localFilePickClosed = closed;
      let graceTimer: ReturnType<typeof setTimeout> | undefined;
      let result: Awaited<ReturnType<typeof bridge.chat.pickAttachments>> | undefined;
      try {
        result = await Promise.race([
          bridge.chat.pickAttachments({
            ...currentLease,
            maxFiles,
            maxTotalSize,
            maxUploadFiles,
            ...(files ? { files } : {}),
            surfaceId,
          }),
          closed.promise
            .then(
              () =>
                new Promise<void>((settle) => {
                  graceTimer = setTimeout(settle, LOST_PICK_REPLY_GRACE_MS);
                })
            )
            .then(() => undefined),
        ]);
      } finally {
        if (graceTimer !== undefined) clearTimeout(graceTimer);
        if (this.#localFilePickClosed === closed) {
          this.#localFilePickClosed = undefined;
        }
      }
      // Took the projection path: Main already published every failed row, so
      // there is nothing here to attribute and no exact intake id to ack.
      if (!result) return true;
      commands.observeDraftEpoch(result);
      this.#assertCurrent(lifecycleGeneration, currentLease, projectionGeneration);
      for (const [errorIndex, error] of result.errors.entries()) {
        const id = `chat-intake-failure:${result.intakeId}:${errorIndex}`;
        if (!native.list.some((attachment) => attachment.id === id)) {
          this.#failures.record(id, {
            error: localFilePickErrorMessage(error, locale),
            id,
            isImage: error.isImage ?? false,
            name: error.name ?? messages.chat_attachment_file({}, { locale }),
            path: undefined,
            size: 0,
            status: "failed",
          });
        }
      }
      if (result.errors.length > 0) {
        // Publish first, then acknowledge exact delivery. Main keeps the
        // failure gate until the user removes/retries its projected row;
        // acknowledgement never transfers or clears authority.
        this.#channel.publish();
        await getNativeBridge()
          .chat.acknowledgeIntakeFailures({
            ...currentLease,
            intakeId: result.intakeId,
            surfaceId,
          })
          .then(
            (receipt) => commands.observeDraftEpoch(receipt),
            () => undefined
          );
      }
      return true;
    });
  }

  // Renderer-side single-flight is a UX convenience, never the boundary:
  // Main fences each claim by its own id, so a duplicate press can never
  // displace an in-flight intake. The latch therefore must not outlive
  // Main's dialog — otherwise a reply the transport never delivers leaves
  // the picker control dead for the rest of the session.
  observeDialog(attachmentIntakeInFlight: boolean) {
    if (attachmentIntakeInFlight) {
      this.#localFilePickObservedOpen = true;
    } else if (this.#localFilePickObservedOpen) {
      this.#localFilePickObservedOpen = false;
      this.#localFilePickClosed?.resolve();
    }
  }

  releaseDialog() {
    this.#localFilePickObservedOpen = false;
    this.#localFilePickClosed?.resolve();
    this.#localFilePickClosed = undefined;
  }

  #assertCurrent(
    lifecycleGeneration: number,
    lease: SessionBoundChatLease,
    projectionGeneration: number
  ) {
    this.#channel.lease.assertCurrent(lifecycleGeneration, lease);
    this.#fence.assertCurrent(projectionGeneration);
  }
}

function localFilePickErrorMessage(
  error: { errorClass: string; message: string },
  locale: CommaLocale
) {
  return error.errorClass === "connector_reconfiguration_required"
    ? messages.chat_connector_reconfiguration_required({}, { locale })
    : error.message;
}
