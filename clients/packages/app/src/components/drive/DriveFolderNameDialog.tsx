import { useCommaMessages } from "@comma/i18n/react";
import { Dialog, InputField } from "@comma/ui";
import { useEffect, useRef, useState } from "react";

/**
 * Names a folder: a new one (the name is prefilled and selected, so typing
 * replaces it and Enter accepts it) or an existing one being renamed. One
 * dialog for both, because the only thing the user does in either is type
 * a name and confirm; what differs is the copy around the field.
 */
export function DriveFolderNameDialog({
  existingNames,
  location,
  mode,
  onClose,
  onSubmit,
  synced,
}: {
  /** Names the new name must not collide with (case-insensitive). */
  existingNames: readonly string[];
  /** Where the folder lives; shown under the field for a new folder. */
  location: string;
  mode: { kind: "create" } | { kind: "rename"; currentName: string };
  onClose: () => void;
  onSubmit: (name: string) => void;
  /** Rename only: the local folder follows the name, and the sheet says so. */
  synced?: boolean;
}) {
  const messages = useCommaMessages();
  const [name, setName] = useState(
    mode.kind === "rename" ? mode.currentName : messages.drive_new_folder_default_name()
  );
  const bodyRef = useRef<HTMLDivElement | null>(null);
  const trimmed = name.trim();
  const unchanged = mode.kind === "rename" && trimmed === mode.currentName;
  const taken = existingNames.some(
    (existing) =>
      existing.toLocaleLowerCase() === trimmed.toLocaleLowerCase() &&
      !(mode.kind === "rename" && existing === mode.currentName)
  );
  const canSubmit = trimmed.length > 0 && !taken && !unchanged;

  // The prefilled name is a suggestion: focus with it selected so a keystroke
  // replaces it, and Enter keeps it.
  useEffect(() => {
    const input = bodyRef.current?.querySelector("input");
    input?.focus();
    input?.select();
  }, []);

  const submit = () => {
    if (canSubmit) onSubmit(trimmed);
  };

  return (
    <Dialog
      actions={[
        {
          hierarchy: "secondary-gray",
          label: messages.drive_new_folder_cancel(),
          onPress: onClose,
        },
        {
          disabled: !canSubmit,
          hierarchy: "primary",
          label:
            mode.kind === "create"
              ? messages.drive_new_folder_create()
              : messages.drive_rename_folder_confirm(),
          onPress: submit,
        },
      ]}
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={
        mode.kind === "create"
          ? messages.drive_new_folder_title()
          : messages.drive_rename_folder_title()
      }
    >
      <div
        className="flex w-full flex-col gap-md"
        data-testid="drive-folder-name-dialog"
        ref={bodyRef}
      >
        <InputField
          aria-label={messages.drive_new_folder_name_label()}
          className="w-full"
          {...(taken ? { errorMessage: messages.drive_new_folder_exists() } : {})}
          label={messages.drive_new_folder_name_label()}
          onChange={(event) => setName(event.target.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              submit();
            }
          }}
          suppressFocusRing
          value={name}
        />
        <p className="m-0 text-xs text-quaternary">
          {mode.kind === "create"
            ? messages.drive_new_folder_location({ location })
            : synced
              ? messages.drive_rename_folder_synced_hint()
              : messages.drive_new_folder_location({ location })}
        </p>
      </div>
    </Dialog>
  );
}
