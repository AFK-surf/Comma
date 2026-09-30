import { randomUUID } from "node:crypto";
import { readdir, stat } from "node:fs/promises";
import { chatAttachmentUploadLimit } from "@comma/chat-contract";
import type { ChatCoordinator, ChatAttachmentIntakeOutcome } from "../chat";
import type { LocalFilePickerService } from "../local-files";
import type { AirDropIntake, AirDropOffer } from ".";
import type { AirDropReception } from "./reception";

export async function approveAirDropForChat(options: {
  offer: AirDropOffer;
  signal: AbortSignal;
  surfaceId?: string | undefined;
  chat: ChatCoordinator;
  picker: Pick<LocalFilePickerService, "importForChat">;
  reception: Pick<
    AirDropReception,
    "complete" | "confirm" | "fail" | "progress" | "received" | "refuse"
  >;
}): Promise<AirDropIntake | undefined> {
  const { offer, signal, chat, picker, reception } = options;
  const selected = options.surfaceId
    ? chat.incomingAttachmentTarget(options.surfaceId)
    : undefined;
  const presentation = {
    ...(selected ? { chatTitle: selected.title } : {}),
    files: offer.files,
    linkCount: offer.linkCount,
    requestId: offer.requestId,
    ...(offer.senderName ? { senderName: offer.senderName } : {}),
    ...(options.surfaceId ? { surfaceId: options.surfaceId } : {}),
  };
  // Nothing can be attached: decline now instead of holding the sender.
  if (!selected) {
    reception.refuse(presentation, "no_chat");
    return undefined;
  }
  if (offer.files.some((file) => file.isDirectory)) {
    reception.refuse(presentation, "directory");
    return undefined;
  }
  // Keep the exact conversation alive even if the user changes views during upload.
  const { title: _title, ...original } = selected;
  const target = {
    ...original,
    subscriberId: `airdrop:${offer.requestId}`,
    leaseId: randomUUID(),
  };
  chat.retain(target);
  let claim: ReturnType<ChatCoordinator["claimAttachmentIntake"]>;
  try {
    claim = chat.claimAttachmentIntake(target);
  } catch (error) {
    chat.release(target);
    throw error;
  }
  let settled = false;
  const finish = (outcome: ChatAttachmentIntakeOutcome) => {
    if (settled) return;
    settled = true;
    signal.removeEventListener("abort", abort);
    claim.settle(outcome);
    claim.releaseIfUnused();
    try {
      chat.release(target);
    } catch {
      /* The session may have ended. */
    }
  };
  const abort = () => finish({ cancelled: true, errorCount: 0 });
  signal.addEventListener("abort", abort, { once: true });
  const assertCurrent = () => {
    if (settled || signal.aborted)
      throw new Error("AirDrop attachment intake is no longer active.");
    const current = chat.incomingAttachmentTarget(selected.surfaceId);
    if (
      !current ||
      current.subscriberId !== original.subscriberId ||
      current.leaseId !== original.leaseId ||
      current.workspaceId !== original.workspaceId
    ) {
      throw new Error("The destination chat changed during AirDrop reception.");
    }
    claim.assertCurrent();
  };
  try {
    assertCurrent();
    if (!(await reception.confirm(presentation, signal))) {
      finish({ cancelled: true, errorCount: 0 });
      return undefined;
    }
    assertCurrent();
  } catch (error) {
    finish({ cancelled: true, errorCount: 0 });
    reception.fail(offer.requestId, "no_chat");
    throw error;
  }

  return {
    async complete(received) {
      // A sender's package, such as a Live Photo's .pvt bundle, arrives as a
      // directory that only the picker's local-file route cannot attach. The
      // helper publishes its members beside it, so a bundle left empty is
      // spent; one with contents stays on this Mac for Show in Finder.
      const paths: string[] = [];
      const folders: string[] = [];
      for (const path of received) {
        if (!(await stat(path)).isDirectory()) paths.push(path);
        else if ((await readdir(path)).length > 0) folders.push(path);
      }
      reception.received(offer.requestId, [...paths, ...folders]);
      try {
        assertCurrent();
        const state = chat
          .state()
          .sessions.find(
            (entry) =>
              entry.workspaceId === target.workspaceId &&
              entry.groupId === target.groupId &&
              entry.conversationId === target.conversationId
          )?.state;
        if (!state) throw new Error("The destination chat is no longer available.");
        const local = state.draftAttachments.filter((file) =>
          file.id.startsWith("lfi1_")
        );
        const picked = await picker.importForChat(paths, {
          workspaceId: target.workspaceId,
          assertLocalFileRegistrationAllowed: assertCurrent,
          maxFiles: Math.max(0, 50 - local.length),
          maxTotalSize: Math.max(
            0,
            1024 * 1024 * 1024 - local.reduce((sum, file) => sum + file.size, 0)
          ),
          maxUploadFiles: Math.max(
            0,
            chatAttachmentUploadLimit - (state.draftAttachments.length - local.length)
          ),
        });
        assertCurrent();
        for (const item of picked.items) {
          if (item.kind === "upload")
            chat.attach({
              ...target,
              bytes: new Uint8Array(item.bytes),
              name: item.name,
              size: item.size,
            });
          else chat.attachLocalFiles({ ...target, files: [item.file] });
        }
        finish({
          cancelled: false,
          errorCount: picked.errors.length,
          errors: picked.errors,
        });
        await reception.complete(
          offer.requestId,
          picked.errors.length + folders.length
        );
      } catch (error) {
        if (!settled) {
          finish({ cancelled: false, errorCount: 1 });
          reception.fail(offer.requestId, "attach");
        }
        throw error;
      }
    },
    cancel(reason) {
      if (settled) return;
      finish({ cancelled: !reason, errorCount: reason ? 1 : 0 });
      reception.fail(offer.requestId, "transfer");
    },
    progress(progress) {
      reception.progress(offer.requestId, progress);
    },
  };
}
