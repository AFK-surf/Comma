import { formatDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  cx,
  Dialog,
  FileIcon,
  Folder1Icon,
  InboxIcon,
  ReloadIcon,
  XIcon,
} from "@comma/ui";
import { useState } from "react";
import { Button as AriaButton } from "react-aria-components";
import { ShellIconButtonControl } from "../ShellIconButton";
import { panelTabButton } from "../panelTabButton";
import { driveSecondaryButton } from "./driveButtonStyles";
import { DriveFileName } from "./DriveFileName";
import { formatDriveFileSize, type DriveSyncHistoryEntry } from "./driveStore";

type HistoryTab = "failures" | "history";

/**
 * The five fixed columns; Name takes what is left, which has to hold a long
 * path plus the reason line a failed row carries under it.
 */
const columnWidth = {
  direction: "w-[150px]",
  operation: "w-[110px]",
  size: "w-[80px]",
  status: "w-[72px]",
  time: "w-[130px]",
} as const;

function DriveSyncHistoryRow({ entry }: { entry: DriveSyncHistoryEntry }) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const operation =
    entry.kind === "folder"
      ? entry.operation === "added"
        ? messages.drive_sync_history_operation_added_folder()
        : entry.operation === "updated"
          ? messages.drive_sync_history_operation_updated_folder()
          : messages.drive_sync_history_operation_removed_folder()
      : entry.operation === "added"
        ? messages.drive_sync_history_operation_added_file()
        : entry.operation === "updated"
          ? messages.drive_sync_history_operation_updated_file()
          : messages.drive_sync_history_operation_removed_file();

  return (
    <tr
      className="border-t-[length:var(--border-width-0-5)] border-primary"
      data-status={entry.status}
      data-testid={`drive-sync-history-row-${entry.id}`}
    >
      <td className="py-sm pr-md pl-lg">
        <span className="flex min-w-0 items-center gap-md">
          {entry.kind === "folder" ? (
            <Folder1Icon aria-hidden className="size-5 shrink-0 text-quaternary" />
          ) : (
            <FileIcon aria-hidden className="size-5 shrink-0 text-quaternary" />
          )}
          <span className="flex min-w-0 flex-1 flex-col">
            <DriveFileName className="text-sm text-primary" name={entry.name} />
            {/* A failure says why on its own line: the row is the record, and
                the reason is what tells the user whether to retry. */}
            {entry.status === "failed" ? (
              <span className="min-w-0 truncate text-xs text-quaternary">
                {messages.drive_sync_history_conflict_reason()}
              </span>
            ) : null}
          </span>
        </span>
      </td>
      <td className={cx("py-sm pr-md text-sm", columnWidth.status)}>
        <span
          className={
            entry.status === "success"
              ? "text-fg-success-primary"
              : "text-error-primary"
          }
        >
          {entry.status === "success"
            ? messages.drive_sync_history_status_success()
            : messages.drive_sync_history_status_failed()}
        </span>
      </td>
      <td
        className={cx(
          "py-sm pr-md text-sm whitespace-nowrap text-quaternary",
          columnWidth.direction
        )}
      >
        {entry.direction === "download"
          ? messages.drive_sync_history_direction_download()
          : messages.drive_sync_history_direction_upload()}
      </td>
      <td
        className={cx(
          "py-sm pr-md text-sm whitespace-nowrap text-quaternary",
          columnWidth.operation
        )}
      >
        {operation}
      </td>
      <td
        className={cx(
          "py-sm pr-md text-sm whitespace-nowrap text-quaternary tabular-nums",
          columnWidth.size
        )}
      >
        {entry.sizeBytes === undefined ? "-" : formatDriveFileSize(entry.sizeBytes)}
      </td>
      <td
        className={cx(
          "py-sm pr-lg text-sm whitespace-nowrap text-quaternary tabular-nums",
          columnWidth.time
        )}
      >
        {formatDate(entry.at, locale, {
          dateStyle: "short",
          hourCycle: "h23",
          timeStyle: "short",
        })}
      </td>
    </tr>
  );
}

/**
 * What local sync has done, as a table of paths rather than a summary: one
 * row per file or folder, with which way it moved and whether it landed. A
 * second tab collects the ones that failed, so a problem is never buried
 * among the successes — and can be retried from there.
 */
export function DriveSyncHistoryDialog({
  entries,
  onClose,
  onRetryFailures,
}: {
  entries: readonly DriveSyncHistoryEntry[];
  onClose: () => void;
  onRetryFailures: () => void;
}) {
  const messages = useCommaMessages();
  const [tab, setTab] = useState<HistoryTab>("history");
  // A retried conflict leaves the failures tab but stays in the full log.
  const failures = entries.filter(
    (entry) => entry.status === "failed" && entry.resolved !== true
  );
  const visible = tab === "history" ? entries : failures;

  return (
    <Dialog
      className="w-dialog-wide"
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={messages.drive_sync_history_title()}
    >
      {/* The panel is `relative`, so the close control sits where the built-in
          one would; it is the transfer panel's, so one dismiss affordance
          carries across Drive's surfaces. */}
      <ShellIconButtonControl
        aria-label={messages.common_close()}
        className="absolute top-lg right-lg"
        data-testid="drive-sync-history-close"
        icon={<XIcon className="comma-input-icon" />}
        onPress={onClose}
      />
      <div
        className="flex w-full flex-col gap-lg"
        data-testid="drive-sync-history-dialog"
      >
        {/* The title is the dialog's, so the tabs carry the section names.
            The row backs out of the pill's own px-md so the first label starts
            on the title's left edge, not eight pixels inside it. */}
        <div className="-ml-md flex items-center gap-xs">
          <button
            aria-pressed={tab === "history"}
            className={panelTabButton(tab === "history")}
            data-testid="drive-sync-history-tab-history"
            onClick={() => setTab("history")}
            type="button"
          >
            {messages.drive_sync_history_tab_history()}
          </button>
          <button
            aria-pressed={tab === "failures"}
            className={panelTabButton(tab === "failures")}
            data-testid="drive-sync-history-tab-failures"
            onClick={() => setTab("failures")}
            type="button"
          >
            {messages.drive_sync_history_tab_failures()}
          </button>
        </div>

        {/* One fixed frame for both tabs: switching between them must not
            resize the dialog under the pointer, so the list scrolls inside a
            box whose height never changes. */}
        <div className="relative flex h-[420px] flex-col overflow-hidden rounded-md border-[length:var(--border-width-0-5)] border-primary">
          {/* Retrying acts on the list below it, so it lives in the same box. */}
          {tab === "failures" ? (
            <div className="flex shrink-0 justify-end px-lg py-md">
              <AriaButton
                className={cx(driveSecondaryButton, "text-xs")}
                data-testid="drive-sync-history-retry-all"
                isDisabled={failures.length === 0}
                onPress={onRetryFailures}
              >
                <ReloadIcon className="size-4" />
                <span className="px-xxs whitespace-nowrap">
                  {messages.drive_sync_history_retry_all()}
                </span>
              </AriaButton>
            </div>
          ) : null}
          {visible.length === 0 ? (
            <div
              className="pointer-events-none absolute inset-0 flex flex-col items-center justify-center gap-md"
              data-testid="drive-sync-history-empty"
            >
              <InboxIcon aria-hidden className="size-8 text-quaternary" />
              <p className="m-0 text-sm text-quaternary">
                {tab === "failures"
                  ? messages.drive_sync_history_failures_empty()
                  : messages.drive_sync_history_empty()}
              </p>
            </div>
          ) : (
            <div className="min-h-0 flex-1 overflow-y-auto">
              <table className="w-full table-fixed border-collapse text-left">
                <thead className="sticky top-0 z-[1] bg-quaternary">
                  <tr className="text-xs text-quaternary">
                    <th className="py-sm pr-md pl-lg font-medium">
                      {messages.drive_sync_history_column_name()}
                    </th>
                    <th className={cx("py-sm pr-md font-medium", columnWidth.status)}>
                      {messages.drive_sync_history_column_status()}
                    </th>
                    <th
                      className={cx("py-sm pr-md font-medium", columnWidth.direction)}
                    >
                      {messages.drive_sync_history_column_direction()}
                    </th>
                    <th
                      className={cx("py-sm pr-md font-medium", columnWidth.operation)}
                    >
                      {messages.drive_sync_history_column_operation()}
                    </th>
                    <th className={cx("py-sm pr-md font-medium", columnWidth.size)}>
                      {messages.drive_sync_history_column_size()}
                    </th>
                    <th className={cx("py-sm pr-lg font-medium", columnWidth.time)}>
                      {messages.drive_sync_history_column_time()}
                    </th>
                  </tr>
                </thead>
                <tbody data-testid="drive-sync-history-rows">
                  {visible.map((entry) => (
                    <DriveSyncHistoryRow entry={entry} key={entry.id} />
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </Dialog>
  );
}
