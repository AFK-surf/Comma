import { useCommaMessages } from "@comma/i18n/react";
import { Dialog, InputField } from "@comma/ui";
import { useEffect, useRef, useState } from "react";
import { DriveInlinePath } from "./DriveInlinePath";

/** What the dialog is about to stop sharing. */
export type DriveStopSharingTarget =
  | { kind: "space"; name: string; originPath?: string }
  | { kind: "file"; name: string };

/**
 * Confirms stopping a share (macOS Synchronicity's "Stop sharing" sheet).
 * Destructive and not undoable from here, so the name has to be typed back
 * before the destructive action arms; Escape and Cancel always work.
 */
export function DriveStopSharingDialog({
  onClose,
  onConfirm,
  target,
}: {
  onClose: () => void;
  onConfirm: (target: DriveStopSharingTarget) => void;
  target: DriveStopSharingTarget;
}) {
  const messages = useCommaMessages();
  const [typed, setTyped] = useState("");
  const bodyRef = useRef<HTMLDivElement | null>(null);
  const armed = typed.trim() === target.name;

  // The sheet exists to take one typed answer, so the field takes focus as
  // the sheet lands; the modal's own focus trap keeps it there.
  useEffect(() => {
    bodyRef.current?.querySelector("input")?.focus();
  }, []);

  // The label quotes the name the user must type; the quoted name is the one
  // thing to read, so it carries the primary ink while the rest stays label
  // grey. Split the translated sentence around it rather than assembling it
  // from fragments, so each locale keeps its own word order.
  const confirmLabel = messages.drive_stop_sharing_confirm_label({ name: target.name });
  const quoted = `'${target.name}'`;
  const quotedAt = confirmLabel.indexOf(quoted);
  const confirmLabelNode =
    quotedAt === -1 ? (
      confirmLabel
    ) : (
      <>
        {confirmLabel.slice(0, quotedAt)}
        <span className="text-primary">{quoted}</span>
        {confirmLabel.slice(quotedAt + quoted.length)}
      </>
    );

  const description =
    target.kind === "file" ? (
      messages.drive_stop_sharing_file({ name: target.name })
    ) : target.originPath ? (
      <DriveInlinePath
        path={target.originPath}
        sentence={messages.drive_stop_sharing_space_origin({ path: target.originPath })}
      />
    ) : (
      messages.drive_stop_sharing_space_replica({ name: target.name })
    );

  return (
    <Dialog
      actions={[
        {
          hierarchy: "secondary-gray",
          label: messages.drive_stop_sharing_cancel(),
          onPress: onClose,
        },
        {
          disabled: !armed,
          hierarchy: "destructive",
          label: messages.drive_delete_space_confirm(),
          onPress: () => onConfirm(target),
        },
      ]}
      description={description}
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={messages.drive_delete_space_title({ name: target.name })}
    >
      <div className="w-full" data-testid="drive-stop-sharing-dialog" ref={bodyRef}>
        <InputField
          aria-label={confirmLabel}
          className="w-full"
          label={confirmLabelNode}
          onChange={(event) => setTyped(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter" && armed) {
              event.preventDefault();
              onConfirm(target);
            }
          }}
          suppressFocusRing
          value={typed}
        />
      </div>
    </Dialog>
  );
}
