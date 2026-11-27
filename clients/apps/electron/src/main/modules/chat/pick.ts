// A window's file pick, as the client core asks Main for it (`DesktopPorts.pickAttachments`, utility op `chatPick`):
// the core opened the intake and attaches what this gives; Main opens the dialog on the window, keeps the files and
// registers the local ones under that intake. Each registration first asks the core whether the intake is still its
// draft's, and stops once the core gave the pick up (it restarted, or the session changed).
import type {
  ChatPickAnswer,
  ChatPickedItem,
  ChatPickRequest,
} from "@comma/core/utility-protocol";
import type { LocalFilePickerProvider } from "../local-files/picker";
import type { MainNativeSessionAdmissionGuard } from "../session/native-session-admission";
import type { MainChat } from ".";

export function createCoreChatPick(deps: {
  chat: Pick<MainChat, "intake">;
  picker: () => Pick<LocalFilePickerProvider, "pickForChat">;
  guard: Pick<MainNativeSessionAdmissionGuard, "runLease">;
  /** The open window `surfaceId` names, by its web contents; undefined once it closed. */
  windowContents: (surfaceId: string) => number | undefined;
}) {
  return (request: ChatPickRequest, signal: AbortSignal): Promise<ChatPickAnswer> =>
    deps.guard.runLease(request.lease, async (assertSession) => {
      const owner = deps.windowContents(request.surfaceId);
      if (owner === undefined)
        throw new Error("The window that asked for files is not open.");
      const intake = deps.chat.intake(request.intakeId);
      const assertCurrent = () => {
        if (signal.aborted) throw new Error("The Comma core gave this pick up.");
        assertSession();
        intake.assertCurrent();
      };
      const picked = await deps.picker().pickForChat({
        assertLocalFileRegistrationAllowed: assertCurrent,
        dialogOwnerWebContentsId: owner,
        localFileIntakeId: request.intakeId,
        maxFiles: request.maxFiles,
        maxTotalSize: request.maxTotalSize,
        maxUploadFiles: request.maxUploadFiles,
        localPathMode: request.localPathMode,
        onDialogClosed: intake.markDialogClosed,
        refreshLocalFileRegistration: intake.refresh,
        workspaceId: request.workspaceId,
      });
      return {
        cancelled: picked.cancelled,
        errors: picked.errors,
        items: picked.items.map((item): ChatPickedItem => {
          switch (item.kind) {
            case "upload":
              return {
                kind: "upload",
                name: item.name,
                size: item.size,
                bytes: new Uint8Array(item.bytes),
              };
            case "local_path":
              return { kind: "local_path", file: { ...item.file } };
            case "local_file":
              return {
                kind: "local_file",
                file: {
                  localFileRef: item.file.localFileRef,
                  mediaType: item.file.mediaType,
                  name: item.file.name,
                  size: item.file.size,
                },
              };
          }
        }),
      };
    });
}
