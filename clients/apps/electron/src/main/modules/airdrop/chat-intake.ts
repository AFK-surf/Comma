import { readdir, stat } from "node:fs/promises";
import type { ChatAttachmentIntakeOutcome, MainChat, MainChatReceived } from "../chat";
import type { LocalFilePickerService } from "../local-files";
import type { AirDropIntake, AirDropOffer } from ".";
import type { AirDropReception } from "./reception";

/**
 * An AirDrop offer for a window's chat. The core decides where the files go and whether they can (`MainChat.receive`):
 * the draft of the conversation the window shows, held while the person changes conversation, and the room that draft
 * has. Main asks the person, receives the files, keeps them on this Mac and registers the ones the core can attach.
 */
export async function approveAirDropForChat(options: {
  offer: AirDropOffer;
  signal: AbortSignal;
  surfaceId?: string | undefined;
  chat: MainChat;
  picker: Pick<LocalFilePickerService, "importForChat">;
  reception: Pick<
    AirDropReception,
    "complete" | "confirm" | "fail" | "progress" | "received" | "refuse"
  >;
}): Promise<AirDropIntake | undefined> {
  const { offer, signal, chat, picker, reception } = options;
  const received: MainChatReceived = options.surfaceId
    ? await chat.receive(options.surfaceId, offer.files)
    : { refused: "no_chat" };
  const presentation = {
    ...(received.title !== undefined ? { chatTitle: received.title } : {}),
    files: offer.files,
    linkCount: offer.linkCount,
    requestId: offer.requestId,
    ...(offer.senderName ? { senderName: offer.senderName } : {}),
    ...(options.surfaceId ? { surfaceId: options.surfaceId } : {}),
  };
  // Nothing can be attached: decline now instead of holding the sender.
  if (received.refused !== undefined) {
    reception.refuse(presentation, received.refused);
    return undefined;
  }
  const { intake, workspaceId } = received;
  let settled = false;
  const finish = (outcome: ChatAttachmentIntakeOutcome) => {
    if (settled) return;
    settled = true;
    signal.removeEventListener("abort", abort);
    void intake.settle(outcome);
  };
  const abort = () => finish({ cancelled: true, errorCount: 0 });
  signal.addEventListener("abort", abort, { once: true });
  // Each step asks the core first (`refresh`); file registrations in between check its last answer synchronously.
  const assertCurrent = () => {
    if (settled || signal.aborted)
      throw new Error("AirDrop attachment intake is no longer active.");
    intake.assertCurrent();
  };
  try {
    await intake.refresh();
    assertCurrent();
    if (!(await reception.confirm(presentation, signal))) {
      finish({ cancelled: true, errorCount: 0 });
      return undefined;
    }
    await intake.refresh();
    assertCurrent();
  } catch (error) {
    finish({ cancelled: true, errorCount: 0 });
    reception.fail(offer.requestId, "no_chat");
    throw error;
  }

  return {
    async complete(receivedPaths) {
      // A sender's package, such as a Live Photo's .pvt bundle, arrives as a
      // directory that only the picker's local-file route cannot attach. The
      // helper publishes its members beside it, so a bundle left empty is
      // spent; one with contents stays on this Mac for Show in Finder.
      const paths: string[] = [];
      const folders: string[] = [];
      for (const path of receivedPaths) {
        if (!(await stat(path)).isDirectory()) paths.push(path);
        else if ((await readdir(path)).length > 0) folders.push(path);
      }
      reception.received(offer.requestId, [...paths, ...folders]);
      try {
        const room = await intake.refresh();
        assertCurrent();
        const picked = await picker.importForChat(paths, {
          workspaceId,
          assertLocalFileRegistrationAllowed: assertCurrent,
          localFileIntakeId: intake.intakeId,
          ...room,
        });
        await intake.refresh();
        assertCurrent();
        await intake.attach(
          picked.items.map((item) =>
            item.kind === "upload"
              ? {
                  kind: "upload" as const,
                  bytes: new Uint8Array(item.bytes),
                  name: item.name,
                  size: item.size,
                }
              : {
                  kind: "local_file" as const,
                  file: {
                    localFileRef: item.file.localFileRef,
                    mediaType: item.file.mediaType,
                    name: item.file.name,
                    size: item.file.size,
                  },
                }
          )
        );
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
