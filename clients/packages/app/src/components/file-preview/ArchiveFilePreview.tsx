import { useCommaLocale, useCommaMessages } from "@comma/i18n/react";
import { FileTypeIcon } from "@comma/ui/components/file-type-icon";
import {
  ChevronRightSmallIcon,
  ChevronsCollapseVerticalIcon,
  ChevronsExpandVerticalIcon,
  FolderIcon,
  FolderOpenIcon,
} from "@comma/ui/components/icons";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { cx } from "@comma/ui/components/utils";
import {
  useEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type ReactNode,
} from "react";
import { formatAttachmentSize } from "../chat/thread/attachments/attachmentLabels";
import {
  PreviewMessage,
  PreviewNotice,
  PreviewToolbarAction,
  PreviewToolbarPortal,
} from "./FilePreviewChrome";
import { FilePreviewLoading } from "./FilePreviewLoading";
import type { RangedFile } from "./PdfFilePreview";
import {
  archiveFolderPaths,
  buildArchiveTree,
  initiallyCollapsedArchiveFolders,
  readArchiveDirectory,
  visibleArchiveRows,
  type ArchiveTreeNode,
  type ArchiveTreeRow,
  type ParsedArchive,
} from "./archive";

type Locale = ReturnType<typeof useCommaLocale>;

/**
 * A ZIP stores local wall-clock time with no zone (read as if it were UTC); TAR and gzip store real instants. Shown
 * as the archive meant them either way.
 */
function useArchiveDateFormat(format: ParsedArchive["format"], locale: Locale) {
  return useMemo(() => {
    const formatter = new Intl.DateTimeFormat(locale, {
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "2-digit",
      minute: "2-digit",
      ...(format === "zip" ? { timeZone: "UTC" } : {}),
    });
    return (time: number | undefined) =>
      time === undefined ? undefined : formatter.format(time);
  }, [format, locale]);
}

/**
 * One row of the tree. Each level is indented by a chevron's width, and a hairline guide runs down under the chevron
 * of every folder it sits in, as in Finder's and VS Code's outlines. Sizes keep a right-aligned column; a folder's
 * file count and the modified time show only when the panel is wide enough (container queries on the tree).
 */
function ArchiveTreeRowView({
  row,
  collapsed,
  active,
  locale,
  formatDate,
  onToggle,
  onFocusRow,
}: {
  row: ArchiveTreeRow;
  collapsed: boolean;
  active: boolean;
  locale: Locale;
  formatDate: (time: number | undefined) => string | undefined;
  onToggle: (path: string) => void;
  onFocusRow: (path: string) => void;
}) {
  const messages = useCommaMessages();
  const { node, depth } = row;
  const guides = Array.from({ length: depth }, (_, level) => (
    <span
      aria-hidden
      className="pointer-events-none absolute inset-y-0 border-l-[length:var(--border-width-0-5)] border-primary"
      key={level}
      style={{
        insetInlineStart: `calc(var(--spacing-md) * 2 + var(--spacing-xl) * ${level})`,
      }}
    />
  ));
  const shared = {
    "aria-level": depth + 1,
    className:
      "relative flex h-7 w-full min-w-0 cursor-default items-center gap-xs rounded-md border-0 bg-transparent pr-md text-left text-sm text-primary outline-none hover:bg-secondary-hover focus-visible:shadow-focus-gray",
    "data-path": node.path,
    onFocus: () => onFocusRow(node.path),
    role: "treeitem",
    style: {
      paddingInlineStart: `calc(var(--spacing-md) + var(--spacing-xl) * ${depth})`,
    },
    tabIndex: active ? 0 : -1,
    title: node.path,
  } as const;
  const columns = (
    <span className="flex shrink-0 items-center gap-xl whitespace-nowrap text-xs tabular-nums">
      <span className="hidden w-36 text-right text-quaternary @md:block">
        {formatDate(node.modifiedAt)}
      </span>
      <span className="w-16 text-right text-tertiary">
        {formatAttachmentSize(node.size, locale)}
      </span>
    </span>
  );

  if (node.isDirectory) {
    const Folder = collapsed ? FolderIcon : FolderOpenIcon;
    return (
      <button
        {...shared}
        aria-expanded={!collapsed}
        onClick={() => onToggle(node.path)}
        type="button"
      >
        {guides}
        <span aria-hidden className="flex size-4 shrink-0 items-center justify-center">
          <ChevronRightSmallIcon
            className={cx(
              "size-4 text-fg-quaternary transition-transform duration-150 motion-reduce:transition-none",
              !collapsed && "rotate-90"
            )}
          />
        </span>
        <Folder aria-hidden className="size-4 shrink-0 text-fg-tertiary" />
        <span className="flex min-w-0 flex-1 items-baseline gap-md">
          <span className="min-w-0 truncate">{node.name}</span>
          <span className="hidden shrink-0 text-xs text-quaternary tabular-nums @sm:inline">
            {messages.file_preview_archive_files({ count: node.fileCount })}
          </span>
        </span>
        {columns}
      </button>
    );
  }
  return (
    <div {...shared}>
      {guides}
      <span aria-hidden className="size-4 shrink-0" />
      <FileTypeIcon className="size-4 shrink-0" fileName={node.name} />
      <span className="min-w-0 flex-1 truncate">{node.name}</span>
      {columns}
    </div>
  );
}

/** The tree: a flat list of visible rows with one tab stop, moved with the arrow keys (WAI-ARIA tree pattern). */
function ArchiveTree({
  label,
  tree,
  collapsed,
  onToggle,
  locale,
  formatDate,
}: {
  label: string;
  tree: readonly ArchiveTreeNode[];
  collapsed: ReadonlySet<string>;
  onToggle: (path: string) => void;
  locale: Locale;
  formatDate: (time: number | undefined) => string | undefined;
}) {
  const rows = useMemo(() => visibleArchiveRows(tree, collapsed), [tree, collapsed]);
  const [activePath, setActivePath] = useState<string | undefined>();
  const treeRef = useRef<HTMLDivElement>(null);
  const active = rows.some((row) => row.node.path === activePath)
    ? activePath
    : rows[0]?.node.path;

  const focusRow = (path: string | undefined) => {
    if (path === undefined) return;
    setActivePath(path);
    treeRef.current
      ?.querySelector<HTMLElement>(`[data-path="${CSS.escape(path)}"]`)
      ?.focus();
  };

  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    const index = rows.findIndex((row) => row.node.path === active);
    const row = rows[index];
    if (!row) return;
    const isOpenFolder = row.node.isDirectory && !collapsed.has(row.node.path);
    switch (event.key) {
      case "ArrowDown":
        focusRow(rows[index + 1]?.node.path);
        break;
      case "ArrowUp":
        focusRow(rows[index - 1]?.node.path);
        break;
      case "Home":
        focusRow(rows[0]?.node.path);
        break;
      case "End":
        focusRow(rows.at(-1)?.node.path);
        break;
      case "ArrowRight":
        if (!row.node.isDirectory) break;
        if (isOpenFolder) {
          const child = rows[index + 1];
          if (child?.parentPath === row.node.path) focusRow(child.node.path);
        } else {
          onToggle(row.node.path);
        }
        break;
      case "ArrowLeft":
        if (isOpenFolder) onToggle(row.node.path);
        else focusRow(row.parentPath);
        break;
      default:
        return;
    }
    event.preventDefault();
  };

  return (
    <div
      aria-label={label}
      className="@container flex min-w-0 flex-col px-md py-xs outline-none"
      onKeyDown={onKeyDown}
      ref={treeRef}
      role="tree"
      // The rows hold the one tab stop; the tree itself takes focus only from script.
      tabIndex={-1}
    >
      {rows.map((row) => (
        <ArchiveTreeRowView
          active={row.node.path === active}
          collapsed={collapsed.has(row.node.path)}
          formatDate={formatDate}
          key={row.node.path}
          locale={locale}
          onFocusRow={setActivePath}
          onToggle={onToggle}
          row={row}
        />
      ))}
    </div>
  );
}

/** A .gz of one file: there is nothing to browse, so it shows the file it holds instead of a one-row tree. */
function GzipSingleFile({
  node,
  locale,
  formatDate,
}: {
  node: ArchiveTreeNode;
  locale: Locale;
  formatDate: (time: number | undefined) => string | undefined;
}) {
  const messages = useCommaMessages();
  const details = [formatAttachmentSize(node.size, locale), formatDate(node.modifiedAt)]
    .filter(Boolean)
    .join(" · ");
  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col items-center justify-center gap-lg p-xl text-center">
      <FileTypeIcon className="size-12 shrink-0" fileName={node.name} />
      <div className="flex w-full min-w-0 flex-col items-center gap-xxs">
        <p
          className="m-0 max-w-full truncate text-sm font-medium text-primary"
          title={node.name}
        >
          {node.name}
        </p>
        {details ? (
          <p className="m-0 text-xs text-tertiary tabular-nums">{details}</p>
        ) : null}
      </div>
      <p className="m-0 text-xs text-quaternary">
        {messages.file_preview_archive_gzip_file()}
      </p>
    </div>
  );
}

/**
 * An archive (.zip, .tar, .tar.gz, .tgz, .gz): lists its files and folders as a collapsible tree with sizes, without
 * unpacking ZIP payloads.
 */
export function ArchiveFilePreview({
  fileName,
  mimeType,
  blob,
  ranged,
  toolbarSlot,
  children,
}: {
  fileName: string;
  mimeType?: string | undefined;
  blob?: Blob | undefined;
  ranged?: RangedFile | undefined;
  /** Where Expand all / Collapse all go: the file preview toolbar. */
  toolbarSlot?: HTMLElement | null | undefined;
  /** Content after the tree, in the same scroll. */
  children?: ReactNode;
}) {
  const messages = useCommaMessages();
  const locale = useCommaLocale();
  const [state, setState] = useState<
    | { status: "loading" }
    | { status: "too_large" }
    | { status: "failed" }
    | { status: "ready"; parsed: ParsedArchive }
  >({ status: "loading" });
  const [collapsed, setCollapsed] = useState<Set<string>>(() => new Set());

  useEffect(() => {
    if (!blob && !ranged) return undefined;
    const controller = new AbortController();
    const { signal } = controller;
    setState({ status: "loading" });
    void (async () => {
      try {
        const parsed = await readArchiveDirectory(
          { blob, ranged },
          fileName,
          mimeType,
          signal
        );
        if (signal.aborted) return;
        setCollapsed(
          initiallyCollapsedArchiveFolders(buildArchiveTree(parsed.entries))
        );
        setState({ status: "ready", parsed });
      } catch (error) {
        if (signal.aborted) return;
        const tooLarge =
          error instanceof Error && error.message === "archive too large";
        setState({ status: tooLarge ? "too_large" : "failed" });
      }
    })();
    return () => controller.abort();
  }, [blob, fileName, mimeType, ranged]);

  const parsed = state.status === "ready" ? state.parsed : undefined;
  const tree = useMemo(
    () => (parsed ? buildArchiveTree(parsed.entries) : []),
    [parsed]
  );
  const allFolders = useMemo(() => archiveFolderPaths(tree), [tree]);
  const formatDate = useArchiveDateFormat(parsed?.format ?? "zip", locale);

  if (state.status === "loading") return <FilePreviewLoading />;

  if (state.status === "too_large" || state.status === "failed") {
    return (
      <PreviewMessage alert>
        {state.status === "too_large"
          ? messages.file_preview_office_too_large({ limit: 64 })
          : messages.file_preview_failed()}
      </PreviewMessage>
    );
  }

  const ready = state.parsed;
  const toggleFolder = (path: string) => {
    setCollapsed((current) => {
      const next = new Set(current);
      if (!next.delete(path)) next.add(path);
      return next;
    });
  };
  // One action that does what the tree needs next: open what is still closed, or close it all once all is open.
  const anyClosed = allFolders.some((path) => collapsed.has(path));
  const singleGzip =
    ready.format === "gz" && tree.length === 1 && !tree[0]!.isDirectory
      ? tree[0]!
      : undefined;

  return (
    <div className="flex min-h-0 min-w-0 flex-1 flex-col">
      {allFolders.length > 0 ? (
        <PreviewToolbarPortal slot={toolbarSlot}>
          {anyClosed ? (
            <PreviewToolbarAction
              icon={<ChevronsExpandVerticalIcon className="comma-input-icon" />}
              label={messages.file_preview_expand_all()}
              onPress={() => setCollapsed(new Set())}
              testId="file-preview-archive-expand-all"
            />
          ) : (
            <PreviewToolbarAction
              icon={<ChevronsCollapseVerticalIcon className="comma-input-icon" />}
              label={messages.file_preview_collapse_all()}
              onPress={() => setCollapsed(new Set(allFolders))}
              testId="file-preview-archive-collapse-all"
            />
          )}
        </PreviewToolbarPortal>
      ) : null}
      {ready.truncated ? (
        <PreviewNotice testId="file-preview-archive-truncated">
          {messages.file_preview_archive_truncated({ count: ready.entries.length })}
        </PreviewNotice>
      ) : null}
      <ScrollArea
        className="min-h-0 flex-1"
        viewportClassName="h-full"
        contentClassName="flex min-h-full flex-col"
        edgeEffect="none"
      >
        <div className="flex min-h-full flex-1 flex-col">
          <div
            className="flex min-w-0 flex-1 flex-col"
            data-testid="file-preview-archive"
          >
            {tree.length === 0 ? (
              <PreviewMessage>{messages.file_preview_archive_empty()}</PreviewMessage>
            ) : singleGzip ? (
              <GzipSingleFile
                formatDate={formatDate}
                locale={locale}
                node={singleGzip}
              />
            ) : (
              <ArchiveTree
                collapsed={collapsed}
                formatDate={formatDate}
                label={fileName}
                locale={locale}
                onToggle={toggleFolder}
                tree={tree}
              />
            )}
          </div>
          {children}
        </div>
      </ScrollArea>
    </div>
  );
}
