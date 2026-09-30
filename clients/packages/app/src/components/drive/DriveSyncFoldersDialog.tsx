import { useCommaMessages } from "@comma/i18n/react";
import { Checkbox, Dialog, Folder1Icon } from "@comma/ui";
import { useState } from "react";
import { formatDriveFileSize, type DriveSpace } from "./driveStore";

/** Free space this Mac reports for the sync root; a fixed figure until the daemon reports one. */
const localFreeBytes = 324 * 1024 ** 3;

/**
 * Turning local sync on starts with choosing what to mirror: every space,
 * with what it would occupy, all checked by default so the common case is
 * one click. The header checkbox is the whole list's switch.
 */
export function DriveSyncFoldersDialog({
  onClose,
  onConfirm,
  sizeOf,
  spaces,
}: {
  onClose: () => void;
  onConfirm: (spaceIds: ReadonlySet<string>) => void | Promise<void>;
  sizeOf: (spaceId: string) => number;
  spaces: readonly DriveSpace[];
}) {
  const messages = useCommaMessages();
  const [chosen, setChosen] = useState<ReadonlySet<string>>(
    () => new Set(spaces.map((space) => space.id))
  );
  const [pending, setPending] = useState(false);
  const allChosen = chosen.size === spaces.length && spaces.length > 0;
  const estimate = spaces
    .filter((space) => chosen.has(space.id))
    .reduce((total, space) => total + sizeOf(space.id), 0);

  const toggle = (spaceId: string, on: boolean) => {
    setChosen((current) => {
      const next = new Set(current);
      if (on) next.add(spaceId);
      else next.delete(spaceId);
      return next;
    });
  };

  return (
    <Dialog
      actions={[
        {
          hierarchy: "secondary-gray",
          label: messages.drive_sync_pick_cancel(),
          disabled: pending,
          onPress: onClose,
        },
        {
          disabled: pending || chosen.size === 0,
          hierarchy: "primary",
          label: messages.drive_sync_pick_confirm(),
          onPress: async () => {
            if (pending) return;
            setPending(true);
            try {
              await onConfirm(chosen);
            } finally {
              setPending(false);
            }
          },
        },
      ]}
      description={messages.drive_sync_pick_estimate({
        free: formatDriveFileSize(localFreeBytes),
        size: formatDriveFileSize(estimate),
      })}
      isOpen
      onOpenChange={(open) => {
        if (!open && !pending) onClose();
      }}
      title={messages.drive_sync_pick_title()}
    >
      <div className="flex w-full flex-col gap-md" data-testid="drive-sync-pick-dialog">
        <div className="overflow-hidden rounded-xs border-[length:var(--border-width-0-5)] border-primary">
          <div className="flex items-center gap-md bg-quaternary px-md py-sm text-xs text-quaternary">
            <Checkbox
              disabled={pending}
              aria-label={messages.drive_sync_pick_column_name()}
              checked={allChosen}
              indeterminate={chosen.size > 0 && !allChosen}
              onChange={(event) =>
                setChosen(
                  event.target.checked
                    ? new Set(spaces.map((space) => space.id))
                    : new Set()
                )
              }
              size="sm"
            />
            <span className="min-w-0 flex-1">
              {messages.drive_sync_pick_column_name()}
            </span>
            <span className="shrink-0">{messages.drive_sync_pick_column_size()}</span>
          </div>
          <ul className="m-0 flex max-h-64 list-none flex-col overflow-y-auto p-0">
            {spaces.map((space) => (
              <li
                className="flex items-center gap-md border-t-[length:var(--border-width-0-5)] border-primary px-md py-sm"
                data-testid={`drive-sync-pick-${space.id}`}
                key={space.id}
              >
                <Checkbox
                  aria-label={space.name}
                  disabled={pending}
                  checked={chosen.has(space.id)}
                  onChange={(event) => toggle(space.id, event.target.checked)}
                  size="sm"
                />
                <Folder1Icon aria-hidden className="size-5 shrink-0 text-quaternary" />
                <span className="min-w-0 flex-1 truncate text-sm text-primary">
                  {space.name}
                </span>
                <span className="shrink-0 text-sm text-quaternary tabular-nums">
                  {formatDriveFileSize(sizeOf(space.id))}
                </span>
              </li>
            ))}
          </ul>
        </div>
        <p className="m-0 text-xs text-quaternary">{messages.drive_sync_pick_note()}</p>
      </div>
    </Dialog>
  );
}
