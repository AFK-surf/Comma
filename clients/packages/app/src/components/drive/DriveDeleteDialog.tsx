import { useCommaMessages } from "@comma/i18n/react";
import { Dialog } from "@comma/ui";
import { DriveFileIcon } from "./DriveFileIcon";
import { DriveFileName } from "./DriveFileName";
import type { DriveFile } from "./driveStore";

/**
 * Confirms deleting one file or a selection. Deleting publishes a tombstone,
 * so the file leaves the space on every device — not just this one — which
 * is why it asks; but it does not touch the publishing device's own disk, so
 * a single Delete is enough and nothing has to be typed back. The files are
 * listed so "3 files" is never a guess about which three.
 */
export function DriveDeleteDialog({
  files,
  onClose,
  onConfirm,
}: {
  files: readonly DriveFile[];
  onClose: () => void;
  onConfirm: () => void;
}) {
  const messages = useCommaMessages();
  const single = files.length === 1 ? files[0] : undefined;

  return (
    <Dialog
      actions={[
        {
          hierarchy: "secondary-gray",
          label: messages.drive_delete_cancel(),
          onPress: onClose,
        },
        {
          hierarchy: "destructive",
          label: messages.drive_delete_confirm(),
          onPress: onConfirm,
        },
      ]}
      description={
        single
          ? messages.drive_delete_description_one({ name: single.name })
          : messages.drive_delete_description_many({ count: String(files.length) })
      }
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={
        single
          ? messages.drive_delete_title_one({ name: single.name })
          : messages.drive_delete_title_many({ count: String(files.length) })
      }
    >
      {single ? null : (
        <ul
          className="m-0 flex max-h-48 list-none flex-col gap-xs overflow-y-auto rounded-xs bg-quaternary px-md py-sm"
          data-testid="drive-delete-files"
        >
          {files.map((file) => (
            <li className="flex items-center gap-md py-xxs" key={file.id}>
              <DriveFileIcon file={file} size="sm" />
              <DriveFileName
                className="min-w-0 flex-1 text-sm text-primary"
                name={file.name}
              />
            </li>
          ))}
        </ul>
      )}
    </Dialog>
  );
}
