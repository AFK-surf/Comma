import { PageLoading } from "@comma/ui";
import {
  defaultRangeExtractor,
  useVirtualizer,
  type Rect,
} from "@tanstack/react-virtual";
/* oxlint-disable jsx-a11y/prefer-tag-over-role -- A file row hosts its checkbox and hover actions, so the open-preview surface cannot itself be a button element. */
/* oxlint-disable jsx-a11y/no-static-element-interactions -- The checkbox cell only fences clicks so a selection toggle never doubles as the row's open gesture. */
import { formatDate } from "@comma/i18n";
import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import {
  ArrowUpIcon,
  BranchIcon,
  Checkbox,
  CloudCheckIcon,
  CloudSimpleUploadIcon,
  cx,
  DownloadIcon,
  ExclamationTriangleIcon,
  Folder1Icon,
  FolderOpenIcon,
  getMenuPointerOffsets,
  MoreHorizontalIcon,
  ScrollArea,
  Tooltip,
} from "@comma/ui";
import {
  memo,
  useCallback,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { Focusable } from "react-aria-components";
import { drivePrimaryButton } from "./driveButtonStyles";
import { driveFileKind, type DriveNodeStatus } from "./driveStore";
import { DriveFileName } from "./DriveFileName";
import {
  DriveFileMenuPopover,
  DriveSelectionMenuPopover,
  type DriveFileMenuAction,
  type DriveSelectionMenuAction,
} from "./DriveFileMenu";
import { useDriveContextMenu } from "./DriveItemMenu";
import { DriveBreadcrumb } from "./DriveBreadcrumb";
import { DriveFileIcon } from "./DriveFileIcon";
import {
  defaultDriveSort,
  driveVersionCount,
  formatDriveFileSize,
  sortDriveFiles,
  type DriveFile,
  type DriveSort,
  type DriveSortColumn,
} from "./driveStore";

// Keep metadata and actions in separate, non-shrinking columns. The date uses
// a compact form until the list itself has room for the full timestamp.
const driveColumnWidth = {
  modified: "w-[120px] @xl:w-[200px]",
  size: "w-[80px]",
  versions: "w-[120px]",
} as const;

const actionColumnClassName = "flex w-[56px] shrink-0 items-center justify-between";

const metaColumnClassName =
  "hidden shrink-0 text-left text-sm text-quaternary whitespace-nowrap @lg:inline";

/**
 * "Nothing to show here". A hyphen, not the em dash the rest of the app uses
 * for a missing value: in a dense row of numbers a full-width dash reads as
 * content rather than as the absence of it. Decorative — a row with no
 * versions badge already says it has one version — so it stays out of the
 * a11y tree.
 */
const DriveEmptyCell = () => (
  <span aria-hidden className="text-sm text-quaternary">
    -
  </span>
);

// Rows are scanned, not admired: hovering one is a pointer moving through a
// list dozens of times a minute, so every hover state here lands instantly.
const hoverActionClassName = (alwaysVisible: boolean) =>
  cx(
    "inline-flex size-5 shrink-0 items-center justify-center rounded-sm border-0 bg-transparent p-0 text-quaternary outline-none",
    "hover:text-secondary focus-visible:opacity-100 focus-visible:shadow-focus-gray",
    alwaysVisible ? "opacity-100" : "opacity-0 group-hover/drive-file:opacity-100"
  );

function DriveSortHeader({
  active,
  className,
  column,
  direction,
  label,
  onSort,
}: {
  active: boolean;
  className?: string;
  column: DriveSortColumn;
  direction: DriveSort["direction"];
  label: string;
  onSort: (column: DriveSortColumn) => void;
}) {
  const messages = useCommaMessages();
  return (
    <button
      aria-label={messages.drive_sort_by({ column: label })}
      aria-pressed={active}
      className={cx(
        "inline-flex items-center gap-xxs rounded-xs border-0 bg-transparent p-0 text-xs font-medium whitespace-nowrap outline-none",
        "focus-visible:shadow-focus-gray",
        active ? "text-primary" : "text-quaternary hover:text-secondary",
        className
      )}
      data-sort-column={column}
      data-sort-direction={active ? direction : undefined}
      data-testid={`drive-sort-${column}`}
      onClick={() => onSort(column)}
      type="button"
    >
      <span>{label}</span>
      {active ? (
        <ArrowUpIcon
          aria-hidden
          className={cx(
            "size-4 shrink-0 transition-transform duration-[160ms] ease-[cubic-bezier(0.23,1,0.32,1)] motion-reduce:transition-none",
            direction === "desc" && "rotate-180"
          )}
        />
      ) : null}
    </button>
  );
}

function DriveListHeader({
  allSelected,
  anySelected,
  onSort,
  onToggleAll,
  sort,
}: {
  allSelected: boolean;
  anySelected: boolean;
  onSort: (column: DriveSortColumn) => void;
  onToggleAll: (selected: boolean) => void;
  sort: DriveSort;
}) {
  const messages = useCommaMessages();
  const header = (column: DriveSortColumn, label: string, className?: string) => (
    <DriveSortHeader
      active={sort.column === column}
      column={column}
      direction={sort.direction}
      label={label}
      onSort={onSort}
      {...(className === undefined ? {} : { className })}
    />
  );
  return (
    <div
      className="flex w-full items-center gap-md rounded-lg px-md py-sm"
      data-testid="drive-list-header"
    >
      <div className="flex min-w-0 flex-1 items-center gap-md">
        <div className="flex shrink-0 items-center justify-center">
          <Checkbox
            aria-label={messages.drive_select_all()}
            checked={allSelected}
            indeterminate={anySelected && !allSelected}
            onChange={(event) => onToggleAll(event.target.checked)}
            size="sm"
          />
        </div>
        <div className="flex min-w-0 flex-1 items-center">
          {header("name", messages.drive_column_name())}
        </div>
        <div className="hidden shrink-0 items-center gap-md @sm:flex">
          <span
            className={cx(
              "flex shrink-0 items-center justify-start",
              driveColumnWidth.versions
            )}
          >
            {header("versions", messages.drive_column_versions())}
          </span>
          <span
            className={cx(
              "hidden shrink-0 items-center justify-start @lg:flex",
              driveColumnWidth.size
            )}
          >
            {header("size", messages.drive_column_size())}
          </span>
          <span
            className={cx(
              "hidden shrink-0 items-center justify-start @lg:flex",
              driveColumnWidth.modified
            )}
          >
            {header("modified", messages.drive_column_modified())}
          </span>
        </div>
      </div>
      {/* Keeps the header's columns flush with the rows' hover actions. */}
      <span aria-hidden className={actionColumnClassName} />
    </div>
  );
}

/**
 * A folder inside the space, derived from the files under it. A single click
 * steps in; Enter does the same from the keyboard.
 */
function DriveFolderRow({
  itemCount,
  name,
  onOpen,
  onToggleSelected,
  selection,
}: {
  itemCount: number;
  name: string;
  onOpen: () => void;
  onToggleSelected: (selected: boolean) => void;
  /** How much of the folder's contents is selected: its checkbox mirrors that. */
  selection: "all" | "none" | "some";
}) {
  const messages = useCommaMessages();
  return (
    <div
      aria-label={messages.drive_folder_row_open({ name })}
      className={cx(
        "group/drive-folder relative flex w-full min-w-0 cursor-default items-center gap-md rounded-lg p-md text-left outline-none",
        "focus-visible:shadow-focus-gray",
        selection === "all" ? "bg-sidebar-bg-item" : "hover:bg-sidebar-bg-item"
      )}
      data-selected={selection === "all" ? "true" : undefined}
      data-testid={`drive-folder-${name}`}
      onClick={onOpen}
      onKeyDown={(event) => {
        if (event.target !== event.currentTarget) return;
        if (event.key === "Enter") {
          event.preventDefault();
          onOpen();
        }
      }}
      role="button"
      tabIndex={0}
    >
      <div className="flex min-w-0 flex-1 items-center gap-md">
        {/* Selecting a folder selects everything under it; the checkbox
            reads back the folder's contents (all, some, none). The cell is
            fenced off from the row's click, like a file row's. */}
        <div
          className={cx(
            "flex shrink-0 items-center justify-center",
            selection === "none"
              ? "opacity-0 group-hover/drive-folder:opacity-100 focus-within:opacity-100"
              : "opacity-100"
          )}
          onClick={(event) => event.stopPropagation()}
          onKeyDown={(event) => event.stopPropagation()}
        >
          <Checkbox
            aria-label={messages.drive_select_folder({ name })}
            checked={selection === "all"}
            indeterminate={selection === "some"}
            onChange={(event) => onToggleSelected(event.target.checked)}
            size="sm"
          />
        </div>
        <div className="flex min-w-0 flex-1 items-center gap-md">
          <Folder1Icon aria-hidden className="size-6 shrink-0 text-quaternary" />
          <span className="min-w-0 truncate text-sm text-sidebar-text-secondary">
            {name}
          </span>
        </div>
        <div className="hidden shrink-0 items-center gap-md @sm:flex">
          <span
            className={cx(
              "flex shrink-0 items-center justify-start",
              driveColumnWidth.versions
            )}
          >
            <DriveEmptyCell />
          </span>
          <span className={cx(metaColumnClassName, driveColumnWidth.size)}>
            {messages.drive_folder_items({ count: String(itemCount) })}
          </span>
          <span className={cx(metaColumnClassName, driveColumnWidth.modified)} />
        </div>
      </div>
      <span aria-hidden className={actionColumnClassName} />
    </div>
  );
}

const DriveFileRow = memo(function DriveFileRow({
  file,
  onDownload,
  onMenuAction,
  onMenuOpenChange,
  onNeedThumbnail,
  onOpen,
  onSelectionMenuAction,
  onToggleSelected,
  selected,
  selecting,
  selectionKeptOffline,
  writable,
}: {
  file: DriveFile;
  onDownload: (file: DriveFile) => void;
  onMenuAction: (action: DriveFileMenuAction, file: DriveFile) => void;
  onMenuOpenChange: (fileId: string, open: boolean) => void;
  /** Present with a backend: an image row on screen asks for its thumbnail. */
  onNeedThumbnail: ((file: DriveFile) => void) | undefined;
  onOpen: (file: DriveFile) => void;
  /** Present when this row is one of several selected: the menu then acts on all of them. */
  onSelectionMenuAction: ((action: DriveSelectionMenuAction) => void) | undefined;
  onToggleSelected: (file: DriveFile, selected: boolean) => void;
  selected: boolean;
  /** True while a selection is under way: the row's press joins it. */
  selecting: boolean;
  /** True when every selected file is already pinned, so the action unpins. */
  selectionKeptOffline: boolean;
  writable: boolean;
}) {
  const locale = useCommaLocale();
  const messages = useCommaMessages();
  const modifiedAt = formatDate(file.modifiedAt, locale, {
    dateStyle: "medium",
    hourCycle: "h23",
    timeStyle: "short",
  });
  const compactModifiedAt = formatDate(file.modifiedAt, locale, {
    dateStyle: "short",
  });
  const rowRef = useRef<HTMLDivElement | null>(null);
  const menu = useDriveContextMenu();
  useEffect(() => {
    if (!menu.isOpen) return;
    onMenuOpenChange(file.id, true);
    return () => onMenuOpenChange(file.id, false);
  }, [file.id, menu.isOpen, onMenuOpenChange]);
  // A row on screen is what wants a thumbnail; rows in other folders do not
  // exist, so the ask is bounded by what the reader is looking at. It is
  // asked again only for new content — the id and the hash are the key.
  const wantsThumbnail =
    onNeedThumbnail !== undefined &&
    driveFileKind(file) === "image" &&
    file.thumbnail === undefined &&
    file.blob === undefined;
  useEffect(() => {
    if (wantsThumbnail) onNeedThumbnail?.(file);
    // The file object is fresh each snapshot; what decides a fetch is whether
    // this content still lacks a thumbnail, which the flag carries.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [file.id, file.contentsHash, wantsThumbnail]);

  // Once anything is checked the list is in the middle of a selection, so a
  // press adds this row to it — or takes it back out — instead of opening the
  // file: picking several in a row is never interrupted by a preview.
  const press = () => (selecting ? onToggleSelected(file, !selected) : onOpen(file));

  return (
    <>
      <div
        className={cx(
          "group/drive-file relative flex w-full min-w-0 cursor-default items-center gap-md rounded-lg p-md text-left outline-none",
          "focus-visible:shadow-focus-gray",
          selected || menu.isOpen ? "bg-sidebar-bg-item" : "hover:bg-sidebar-bg-item"
        )}
        data-selected={selected ? "true" : undefined}
        data-testid={`drive-file-${file.id}`}
        onClick={() => press()}
        onContextMenu={(event) => {
          if (!rowRef.current) return;
          event.preventDefault();
          menu.open(
            getMenuPointerOffsets(rowRef.current, event.clientX, event.clientY)
          );
        }}
        onKeyDown={(event) => {
          if (event.target !== event.currentTarget) return;
          if (event.key === "Enter" || event.key === " ") {
            event.preventDefault();
            press();
          }
        }}
        ref={rowRef}
        role="button"
        tabIndex={0}
      >
        <div className="flex min-w-0 flex-1 items-center gap-md">
          {/* The checkbox cell is carved out of the row's open gesture. */}
          <div
            className={cx(
              "flex shrink-0 items-center justify-center",
              selected
                ? "opacity-100"
                : "opacity-0 group-hover/drive-file:opacity-100 focus-within:opacity-100"
            )}
            onClick={(event) => event.stopPropagation()}
            onKeyDown={(event) => event.stopPropagation()}
          >
            <Checkbox
              aria-label={messages.drive_select_file({ fileName: file.name })}
              checked={selected}
              onChange={(event) => onToggleSelected(file, event.target.checked)}
              size="sm"
            />
          </div>
          <div className="flex min-w-0 flex-1 items-center gap-md">
            <DriveFileIcon file={file} />
            {/* The name only shrinks, never grows, so the pin sits right after
                it instead of being pushed out to the column's far edge. */}
            <DriveFileName
              className="min-w-0 text-sm text-sidebar-text-secondary"
              name={file.name}
            />
            {/* The checked cloud, as on the local-sync pill: one glyph for
                "the bytes are on this Mac". The rail's crossed-out cloud is
                its opposite, so the two never mean the same thing twice. */}
            {file.keepOffline ? (
              <Tooltip content={messages.drive_file_kept_offline()} placement="top">
                <span
                  className="flex shrink-0 items-center text-quaternary"
                  data-testid={`drive-file-pinned-${file.id}`}
                  role="img"
                  aria-label={messages.drive_file_kept_offline()}
                >
                  <CloudCheckIcon className="size-4" />
                </span>
              </Tooltip>
            ) : null}
          </div>
          <div className="hidden shrink-0 items-center gap-md @sm:flex">
            <span
              className={cx(
                "flex shrink-0 items-center justify-start",
                driveColumnWidth.versions
              )}
            >
              {driveVersionCount(file) > 1 ? (
                /* The badge is the way in: pressing it opens the file and its
                   versions panel, which is where the count can be explained. */
                <button
                  aria-label={messages.drive_versions_open({
                    count: String(driveVersionCount(file)),
                    fileName: file.name,
                  })}
                  className={cx(
                    "inline-flex h-6 cursor-default items-center justify-center gap-xs rounded-full border border-primary bg-transparent px-md py-xxs",
                    "transition-colors duration-100 hover:bg-quaternary hover:text-secondary",
                    "focus:outline-none focus-visible:shadow-focus-gray"
                  )}
                  data-testid={`drive-file-versions-${file.id}`}
                  onClick={(event) => {
                    event.stopPropagation();
                    onOpen(file);
                  }}
                  type="button"
                >
                  <BranchIcon aria-hidden className="size-4 text-quaternary" />
                  <span className="text-center text-sm font-medium whitespace-nowrap text-quaternary">
                    {messages.drive_versions_badge({
                      count: String(driveVersionCount(file)),
                    })}
                  </span>
                </button>
              ) : (
                <DriveEmptyCell />
              )}
            </span>
            <span className={cx(metaColumnClassName, driveColumnWidth.size)}>
              {formatDriveFileSize(file.sizeBytes)}
            </span>
            <Tooltip content={modifiedAt} placement="top">
              <Focusable>
                <span
                  className={cx(metaColumnClassName, driveColumnWidth.modified)}
                  data-testid={`drive-file-modified-${file.id}`}
                  tabIndex={-1}
                >
                  <span className="sr-only">{modifiedAt}</span>
                  <span aria-hidden className="block truncate @xl:hidden">
                    {compactModifiedAt}
                  </span>
                  <span aria-hidden className="hidden truncate @xl:block">
                    {modifiedAt}
                  </span>
                </span>
              </Focusable>
            </Tooltip>
          </div>
        </div>
        <div className={actionColumnClassName}>
          <button
            aria-label={messages.drive_row_download({ fileName: file.name })}
            className={hoverActionClassName(false)}
            onClick={(event) => {
              event.stopPropagation();
              onDownload(file);
            }}
            type="button"
          >
            <DownloadIcon aria-hidden className="size-5" />
          </button>
          <button
            aria-label={messages.drive_row_more_actions({ fileName: file.name })}
            className={hoverActionClassName(menu.isOpen)}
            onClick={(event) => {
              event.stopPropagation();
              menu.open(null);
            }}
            type="button"
          >
            <MoreHorizontalIcon aria-hidden className="size-5" />
          </button>
        </div>
      </div>
      {onSelectionMenuAction ? (
        <DriveSelectionMenuPopover
          askCommaAgentLabel={messages.drive_ask_comma_agent()}
          deleteLabel={messages.drive_delete_selected()}
          downloadAllLabel={messages.drive_download_all()}
          isOpen={menu.isOpen}
          keepOfflineLabel={
            selectionKeptOffline
              ? messages.drive_file_menu_stop_keeping_offline()
              : messages.drive_file_menu_keep_offline()
          }
          onAction={onSelectionMenuAction}
          onOpenChange={menu.onOpenChange}
          pointerOffsets={menu.pointerOffsets}
          triggerRef={rowRef}
          writable={writable}
        />
      ) : (
        <DriveFileMenuPopover
          askCommaAgentLabel={messages.drive_ask_comma_agent()}
          deleteLabel={messages.drive_file_menu_delete()}
          downloadLabel={messages.drive_file_menu_download()}
          isOpen={menu.isOpen}
          keepOfflineLabel={
            file.keepOffline
              ? messages.drive_file_menu_stop_keeping_offline()
              : messages.drive_file_menu_keep_offline()
          }
          onAction={(action) => onMenuAction(action, file)}
          onOpenChange={menu.onOpenChange}
          pointerOffsets={menu.pointerOffsets}
          triggerRef={rowRef}
          writable={writable}
        />
      )}
    </>
  );
});

/**
 * The node's own state, while there is nothing else to show: coming up (the
 * files follow in a moment) or unable to start (the reason, and a way to
 * try again). A ready node with no files is an empty folder like any other.
 */
function DriveNodeState({
  node,
  onRetry,
}: {
  node: DriveNodeStatus;
  onRetry: () => void;
}) {
  const messages = useCommaMessages();
  const starting = node.status === "starting";
  return (
    <div
      className="flex min-w-0 flex-1 flex-col items-center justify-center p-xl"
      data-node-status={node.status}
      data-testid="drive-node-state"
    >
      <div className="flex w-[295px] min-w-0 max-w-full flex-col items-center gap-md text-center">
        <div className="flex w-full flex-col items-center gap-md">
          {starting ? (
            <PageLoading label={messages.drive_node_starting_title()} />
          ) : (
            <ExclamationTriangleIcon
              aria-hidden
              className="size-5 shrink-0 text-fg-error-primary"
            />
          )}
          {starting ? null : (
            <p className="m-0 text-sm text-primary">
              {messages.drive_node_error_title()}
            </p>
          )}
        </div>
        <p className="m-0 w-full max-w-[277px] whitespace-pre-wrap text-sm text-quaternary [overflow-wrap:anywhere]">
          {starting ? messages.drive_node_starting_description() : node.reason}
        </p>
        {starting ? null : (
          <button
            className={cx(drivePrimaryButton, "text-sm")}
            data-testid="drive-node-retry"
            onClick={onRetry}
            type="button"
          >
            <span className="px-xxs whitespace-nowrap">
              {messages.drive_node_retry()}
            </span>
          </button>
        )}
      </div>
    </div>
  );
}

function DriveEmptyFolder({
  onUploadFiles,
  writable,
}: {
  onUploadFiles: () => void;
  writable: boolean;
}) {
  const messages = useCommaMessages();
  return (
    <div className="flex flex-1 flex-col items-center justify-center p-xl">
      <div className="flex w-[295px] max-w-full flex-col items-center gap-md text-center">
        <div className="flex w-full flex-col items-center gap-md">
          <FolderOpenIcon aria-hidden className="size-5 shrink-0 text-quaternary" />
          <p className="m-0 text-sm text-primary">
            {messages.drive_empty_folder_title()}
          </p>
        </div>
        <p className="m-0 max-w-[277px] text-sm text-quaternary">
          {messages.drive_empty_folder_description()}
        </p>
        <button
          className={cx(drivePrimaryButton, "text-sm")}
          data-testid="drive-empty-upload"
          disabled={!writable}
          onClick={onUploadFiles}
          type="button"
        >
          <CloudSimpleUploadIcon aria-hidden className="size-5" />
          <span className="px-xxs whitespace-nowrap">
            {messages.drive_empty_folder_upload()}
          </span>
        </button>
      </div>
    </div>
  );
}

/** The immediate subfolders of `folderPath`, each with how many entries sit under it. */
function subfoldersOf(files: readonly DriveFile[], prefix: string) {
  const groups = new Map<string, DriveFile[]>();
  for (const file of files) {
    const dir = file.folderPath ?? "";
    if (prefix ? !(dir === prefix || dir.startsWith(`${prefix}/`)) : dir === "")
      continue;
    const rest = prefix ? dir.slice(prefix.length + 1) : dir;
    const [head] = rest.split("/");
    if (!head) continue;
    const descendants = groups.get(head);
    if (descendants) descendants.push(file);
    else groups.set(head, [file]);
  }
  return [...groups.entries()]
    .map(([name, descendants]) => ({ descendants, name }))
    .toSorted((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true }));
}

export function DriveFileList({
  files,
  folderPath,
  node,
  onDownload,
  onMenuAction,
  onNavigate,
  onNeedThumbnail,
  onOpen,
  onRetryNode,
  onSelectionMenuAction,
  onToggleFiles,
  onToggleSelected,
  onUploadFiles,
  revealFileId,
  selectedFileIds,
  selecting,
  selectionKeptOffline,
  spaceName,
  writable,
}: {
  files: readonly DriveFile[];
  /** The folder the list is showing, as path segments inside the space; empty at the root. */
  folderPath: readonly string[];
  onDownload: (file: DriveFile) => void;
  /** Move the list to a folder depth (breadcrumb) or into a subfolder (row). */
  onNavigate: (folderPath: readonly string[]) => void;
  onMenuAction: (action: DriveFileMenuAction, file: DriveFile) => void;
  /** With a backend, an image row on screen asks for its thumbnail through this. */
  onNeedThumbnail?: ((file: DriveFile) => void) | undefined;
  onOpen: (file: DriveFile) => void;
  /** The whole-selection actions: the bar's, plus Keep Offline in the menu. */
  onSelectionMenuAction: (action: DriveSelectionMenuAction) => void;
  /** True while the selection bar is up, so a row's press selects instead of opening. */
  selecting: boolean;
  /** True when every selected file is already pinned, so the action unpins. */
  selectionKeptOffline: boolean;
  /** A folder's or the header's checkbox: the given files go in or out of the selection together. */
  onToggleFiles: (files: readonly DriveFile[], selected: boolean) => void;
  onToggleSelected: (file: DriveFile, selected: boolean) => void;
  /** The node behind the list, shown while it has nothing else to show. */
  node: DriveNodeStatus;
  onRetryNode: () => void;
  onUploadFiles: () => void;
  /** Keep a requested recording mounted until its owner scrolls and focuses it. */
  revealFileId?: string | undefined;
  selectedFileIds: ReadonlySet<string>;
  spaceName: string;
  writable: boolean;
}) {
  const messages = useCommaMessages();
  const [sort, setSort] = useState<DriveSort>(defaultDriveSort);
  const here = folderPath.join("/");
  const filesHere = useMemo(
    () => files.filter((file) => (file.folderPath ?? "") === here),
    [files, here]
  );
  const folders = useMemo(() => subfoldersOf(files, here), [files, here]);
  const sortedFiles = useMemo(() => sortDriveFiles(filesHere, sort), [filesHere, sort]);
  // The header checkbox speaks for everything the list shows: the files at
  // this level and whatever the folder rows stand for.
  const visibleFiles = useMemo(
    () =>
      files.filter((file) => {
        const dir = file.folderPath ?? "";
        return here ? dir === here || dir.startsWith(`${here}/`) : true;
      }),
    [files, here]
  );
  const selectedCount = visibleFiles.filter((file) =>
    selectedFileIds.has(file.id)
  ).length;
  const onSort = (column: DriveSortColumn) =>
    setSort((current) =>
      current.column === column
        ? { column, direction: current.direction === "asc" ? "desc" : "asc" }
        : { column, direction: "asc" }
    );
  const rows = useMemo(
    () => [
      ...folders.map((folder) => ({
        kind: "folder" as const,
        folder,
        key: `folder:${folder.name}`,
      })),
      ...sortedFiles.map((file) => ({
        kind: "file" as const,
        file,
        key: `file:${file.id}`,
      })),
    ],
    [folders, sortedFiles]
  );
  const indexes = useMemo(
    () => new Map(rows.map((row, index) => [row.key, index])),
    [rows]
  );
  const viewport = useRef<HTMLDivElement>(null);
  const list = useRef<HTMLDivElement>(null);
  const rectListener = useRef<((rect: Rect) => void) | undefined>(undefined);
  const [probe, setProbe] = useState<HTMLDivElement | null>(null);
  const [geometry, setGeometry] = useState({ block: 40, gap: 2, margin: 0 });
  const [focusedKey, setFocusedKey] = useState<string | null>(null);
  const [menuFileId, setMenuFileId] = useState<string | null>(null);
  const onMenuOpenChange = useCallback((id: string, open: boolean) => {
    setMenuFileId((current) => (open ? id : current === id ? null : current));
  }, []);
  const measure = useCallback(() => {
    const element = viewport.current;
    if (element)
      rectListener.current?.({
        width: element.clientWidth,
        height: element.clientHeight,
      });
    if (!probe || !list.current) return;
    const next = {
      block: probe.getBoundingClientRect().height,
      gap: Number.parseFloat(getComputedStyle(probe).marginBottom),
      margin: list.current.offsetTop,
    };
    setGeometry((current) =>
      current.block === next.block &&
      current.gap === next.gap &&
      current.margin === next.margin
        ? current
        : next
    );
  }, [probe]);
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => viewport.current,
    getItemKey: useCallback((index) => rows[index]!.key, [rows]),
    estimateSize: () => geometry.block,
    gap: geometry.gap,
    scrollMargin: geometry.margin,
    overscan: 5,
    initialRect: { width: 800, height: 800 },
    observeElementRect: useCallback(
      (_instance: unknown, callback: (rect: Rect) => void) => {
        rectListener.current = callback;
        const element = viewport.current;
        if (element)
          callback({ width: element.clientWidth, height: element.clientHeight });
        return () => {
          rectListener.current = undefined;
        };
      },
      []
    ),
    rangeExtractor: useCallback(
      (range) => {
        const visible = new Set(defaultRangeExtractor(range));
        const focused = focusedKey === null ? undefined : indexes.get(focusedKey);
        if (focused !== undefined) {
          for (
            let index = Math.max(0, focused - 1);
            index <= Math.min(rows.length - 1, focused + 1);
            index++
          )
            visible.add(index);
        }
        // A portal menu retains its anchor. A recording reveal needs its row
        // mounted before the route owner scrolls and focuses the exact file.
        for (const id of [menuFileId, revealFileId]) {
          const index = id ? indexes.get(`file:${id}`) : undefined;
          if (index !== undefined) visible.add(index);
        }
        return [...visible].toSorted((left, right) => left - right);
      },
      [focusedKey, indexes, menuFileId, revealFileId, rows.length]
    ),
  });
  useLayoutEffect(
    () => virtualizer.measure(),
    [geometry.block, geometry.gap, virtualizer]
  );
  useLayoutEffect(() => {
    // Font and density changes move virtual rows. Keep the keyboard target
    // visible after the shared resize measurement updates their positions.
    const focused = document.activeElement;
    if (focused instanceof HTMLElement && list.current?.contains(focused))
      focused.scrollIntoView({
        block: "nearest",
        inline: "nearest",
        behavior: "instant",
      });
  }, [geometry.block, geometry.gap]);

  return (
    <section
      aria-label={messages.drive_files()}
      className="@container flex min-h-0 min-w-0 flex-1 flex-col"
    >
      {files.length === 0 ? (
        node.status === "starting" || node.status === "error" ? (
          <DriveNodeState node={node} onRetry={onRetryNode} />
        ) : (
          <DriveEmptyFolder onUploadFiles={onUploadFiles} writable={writable} />
        )
      ) : (
        <ScrollArea
          className="min-h-0 flex-1"
          ref={viewport}
          contentResizeTarget={probe}
          onContentResize={measure}
          onViewportResize={measure}
        >
          <div className="relative flex flex-col gap-xxs px-md py-lg">
            <div
              aria-hidden
              ref={setProbe}
              style={{
                position: "absolute",
                visibility: "hidden",
                pointerEvents: "none",
                height:
                  "calc(max(24px, 1.5rem, var(--text-sm--line-height)) + var(--spacing-md) * 2)",
                marginBottom: "var(--spacing-xxs)",
                width: 1,
              }}
            />
            <DriveBreadcrumb
              onNavigate={(depth) => onNavigate(folderPath.slice(0, depth))}
              path={folderPath}
              spaceName={spaceName}
            />
            <DriveListHeader
              allSelected={
                visibleFiles.length > 0 && selectedCount === visibleFiles.length
              }
              anySelected={selectedCount > 0}
              onSort={onSort}
              onToggleAll={(selected) => onToggleFiles(visibleFiles, selected)}
              sort={sort}
            />
            <div
              ref={list}
              role="list"
              aria-label={messages.drive_files()}
              style={{ position: "relative", height: virtualizer.getTotalSize() }}
              onFocusCapture={(event) => {
                const key = (event.target as HTMLElement).closest<HTMLElement>(
                  "[data-drive-row-key]"
                )?.dataset.driveRowKey;
                if (key) setFocusedKey(key);
              }}
              onBlurCapture={(event) => {
                const next = event.relatedTarget as HTMLElement | null;
                // Portaled menus restore their trigger after closing. Keep
                // that row through the transient blur while the portal leaves.
                if (
                  next &&
                  !event.currentTarget.contains(next) &&
                  !next.closest('[role="menu"]')
                )
                  setFocusedKey(null);
              }}
            >
              {virtualizer.getVirtualItems().map((virtual) => {
                const row = rows[virtual.index]!;
                const folder = row.kind === "folder" ? row.folder : undefined;
                const file = row.kind === "file" ? row.file : undefined;
                const chosen =
                  folder?.descendants.filter((entry) => selectedFileIds.has(entry.id))
                    .length ?? 0;
                return (
                  <div
                    key={virtual.key}
                    role="listitem"
                    aria-posinset={virtual.index + 1}
                    aria-setsize={rows.length}
                    data-drive-row-key={row.key}
                    style={{
                      position: "absolute",
                      top: 0,
                      left: 0,
                      width: "100%",
                      transform: `translateY(${virtual.start - geometry.margin}px)`,
                    }}
                  >
                    {folder ? (
                      <DriveFolderRow
                        itemCount={folder.descendants.length}
                        name={folder.name}
                        onOpen={() => onNavigate([...folderPath, folder.name])}
                        onToggleSelected={(selected) =>
                          onToggleFiles(folder.descendants, selected)
                        }
                        selection={
                          chosen === 0
                            ? "none"
                            : chosen === folder.descendants.length
                              ? "all"
                              : "some"
                        }
                      />
                    ) : file ? (
                      <DriveFileRow
                        file={file}
                        onDownload={onDownload}
                        onMenuAction={onMenuAction}
                        onMenuOpenChange={onMenuOpenChange}
                        onNeedThumbnail={onNeedThumbnail}
                        onOpen={onOpen}
                        onSelectionMenuAction={
                          selectedCount > 1 && selectedFileIds.has(file.id)
                            ? onSelectionMenuAction
                            : undefined
                        }
                        onToggleSelected={onToggleSelected}
                        selected={selectedFileIds.has(file.id)}
                        selecting={selecting}
                        selectionKeptOffline={selectionKeptOffline}
                        writable={writable}
                      />
                    ) : null}
                  </div>
                );
              })}
            </div>
          </div>
        </ScrollArea>
      )}
    </section>
  );
}
