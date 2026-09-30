import type { CommaLocale } from "@comma/i18n";
import { getNativeBridge } from "@comma/native-bridge";
import type {
  AttachmentUploadInput,
  DraftAttachment,
} from "../../../components/chat/model/conversationChannel";
import type { ChannelLease } from "../ChannelLease";
import type { ChannelStore } from "../channelStore";
import type { DraftCommands } from "../DraftCommands";
import type { ProjectionFence } from "../projection/ProjectionFence";
import { AttachmentAdmissions } from "./admissions/AttachmentAdmissions";
import type { AttachmentChannel } from "./attachmentChannel";
import { NativeAttachments } from "./NativeAttachments";
import { LocalFilePicker } from "./picking/LocalFilePicker";
import { NativePick } from "./picking/NativePick";
import { PickFailures } from "./picking/PickFailures";
import { SendSettlement } from "./SendSettlement";

/**
 * The draft's attachments as this renderer shows them: those Main projects,
 * failed picks, and uploads Main has not projected yet.
 */
export class DraftAttachments {
  readonly #admissions: AttachmentAdmissions;
  readonly #channel: AttachmentChannel;
  readonly #failures = new PickFailures();
  readonly #nativePick: NativePick;
  readonly #picker: LocalFilePicker;
  readonly #store: ChannelStore;
  #attachmentAdmissionSequence = 0;

  constructor({
    commands,
    fence,
    lease,
    locale,
    store,
    surfaceId,
  }: {
    commands: DraftCommands;
    fence: ProjectionFence;
    lease: ChannelLease;
    locale: CommaLocale;
    store: ChannelStore;
    surfaceId: string;
  }) {
    this.#store = store;
    this.#channel = {
      commands,
      lease,
      locale,
      native: new NativeAttachments(),
      nextLocalId: (prefix) =>
        `${prefix}-${surfaceId}-${++this.#attachmentAdmissionSequence}`,
      publish: () => this.publish(),
      surfaceId,
    };
    const failures = this.#failures;
    this.#admissions = new AttachmentAdmissions(this.#channel);
    this.#nativePick = new NativePick(this.#channel, { failures, fence, store });
    this.#picker = new LocalFilePicker(this.#channel, {
      failures,
      fence,
      nativePick: this.#nativePick,
    });
  }

  attach(files: AttachmentUploadInput[]) {
    if (!this.#channel.lease.active || files.length === 0) {
      return;
    }
    if (this.#picker.accepts(files)) {
      this.#picker.attachSelected(files);
      return;
    }
    this.#admissions.admit(files);
    this.publish();
  }

  pickNative() {
    return this.#picker.pickNative();
  }

  remove(attachmentId: string) {
    if (this.#failures.remove(attachmentId)) {
      this.publish();
    }
    if (this.#admissions.requestRemoval(attachmentId)) {
      this.publish();
      return;
    }
    return this.#channel.commands.run((lease) =>
      getNativeBridge().chat.removeAttachment({
        ...lease,
        attachmentId,
        surfaceId: this.#channel.surfaceId,
      })
    );
  }

  retry(attachmentId: string) {
    const selectedFiles = this.#failures.takeSelection(attachmentId);
    if (selectedFiles) {
      this.attach(selectedFiles);
      this.publish();
      return;
    }
    if (attachmentId.startsWith("chat-intake-failure:")) {
      return this.#picker.retryIntakeFailure(attachmentId);
    }
    const admission = this.#admissions.get(attachmentId);
    if (admission) {
      if (this.#admissions.restart(admission)) this.publish();
      return;
    }
    return this.#channel.commands.run((lease) =>
      getNativeBridge().chat.retryAttachment({
        ...lease,
        attachmentId,
        surfaceId: this.#channel.surfaceId,
      })
    );
  }

  forState(): DraftAttachment[] {
    return [
      ...this.#channel.native.visible(),
      ...this.#failures.rows(),
      ...this.#admissions.pending(),
    ];
  }

  publish() {
    if (!this.#channel.lease.active) {
      return;
    }
    this.#store.patch({ draftAttachments: this.forState() });
  }

  observeIntakeInFlight(attachmentIntakeInFlight: boolean) {
    this.#nativePick.observeDialog(attachmentIntakeInFlight);
  }

  /** Adopts the attachments Main projects, which are authoritative. */
  adopt(attachments: DraftAttachment[]) {
    this.#channel.native.adopt(attachments);
    for (const attachment of attachments) {
      // Main's projection is authoritative and survives Renderer restart.
      // Drop the same-id optimistic row as soon as that projection arrives.
      this.#failures.resolve(attachment.id);
    }
    this.#admissions.reconcile();
    this.#channel.native.settleWaiters();
  }

  /** A stopped channel keeps showing only what Main projects. */
  abandon() {
    this.#admissions.cancelAll();
    this.#failures.clear();
    this.#picker.abandon();
    this.#channel.native.abandon();
    this.#store.state = {
      ...this.#store.state,
      draftAttachments: this.#channel.native.list,
    };
  }

  /** A session Main no longer projects leaves no attachment behind. */
  clear() {
    this.#admissions.cancelAll();
    this.#failures.clear();
    this.#picker.abandon();
    this.#nativePick.releaseDialog();
    this.#channel.native.clear();
  }

  sendSettlement() {
    return new SendSettlement(this.#admissions, this.#channel.native, this.#failures);
  }
}
