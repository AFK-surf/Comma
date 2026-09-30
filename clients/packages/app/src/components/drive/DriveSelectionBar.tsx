import { useCommaMessages } from "@comma/i18n/react";
import {
  Cursor1Icon,
  cx,
  DownloadIcon,
  SelectionBar,
  selectionBarButtonClasses,
  TrashCanIcon,
} from "@comma/ui";

/** The selection bar over the file list (Figma 1371:19684) with Drive's actions. */
export function DriveSelectionBar({
  count,
  onAskCommaAgent,
  onClear,
  onDelete,
  onDownloadAll,
  writable,
}: {
  count: number;
  onAskCommaAgent: () => void;
  onClear: () => void;
  onDelete: () => void;
  onDownloadAll: () => void;
  writable: boolean;
}) {
  const messages = useCommaMessages();
  return (
    <SelectionBar
      aria-label={messages.drive_selection_toolbar()}
      clearLabel={messages.drive_clear_selection()}
      clearTestId="drive-clear-selection"
      countLabel={messages.drive_selected_count({ count: String(count) })}
      onClear={onClear}
      testId="drive-selection-bar"
    >
      <button
        className={cx(selectionBarButtonClasses, "px-md")}
        data-testid="drive-ask-comma-agent"
        onClick={onAskCommaAgent}
        type="button"
      >
        <Cursor1Icon aria-hidden className="size-5" />
        <span className="px-xxs whitespace-nowrap">
          {messages.drive_ask_comma_agent()}
        </span>
      </button>
      <button
        className={cx(selectionBarButtonClasses, "px-md")}
        data-testid="drive-download-selected"
        onClick={onDownloadAll}
        type="button"
      >
        <DownloadIcon aria-hidden className="size-5" />
        <span className="px-xxs whitespace-nowrap">
          {messages.drive_download_all()}
        </span>
      </button>
      {writable ? (
        <button
          className={cx(selectionBarButtonClasses, "pl-md pr-lg text-error-primary")}
          data-testid="drive-delete-selected"
          onClick={onDelete}
          type="button"
        >
          <TrashCanIcon aria-hidden className="size-5" />
          <span className="px-xxs whitespace-nowrap">
            {messages.drive_delete_selected()}
          </span>
        </button>
      ) : null}
    </SelectionBar>
  );
}
