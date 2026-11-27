import type { ChatConversationFile } from "@comma/chat-contract";
import type { AttachmentUploadInput } from "@comma/core/chat";
import { mediaElementSource, useMediaContextMenu } from "./useMediaContextMenu";
import {
  ChatPanelFileApplicationItems,
  fileApplicationsMaxHeight,
  useChatPanelFileOpenIn,
  useChatPanelMediaDownloadController,
  type ChatPanelMediaDownloadAction,
  type ChatPanelFileOpenInAction,
} from "@comma/ui/components/chat-panel";
import { Button } from "@comma/ui/components/Button";
import { Dialog } from "@comma/ui/components/dialog";
import {
  ArrowRightIcon,
  CheckIcon,
  CheckLargeIcon,
  ChevronDownSmallIcon,
  CopyIcon,
  DownloadIcon,
  FileIcon,
  MoreHorizontalIcon,
} from "@comma/ui/components/icons";
import {
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  menuSurfaceClasses,
} from "@comma/ui/components/menu";
import { ScrollArea } from "@comma/ui/components/scroll-area";
import { toast } from "@comma/ui/components/toast";
import { Tooltip } from "@comma/ui/components/tooltip";
import { cx } from "@comma/ui/components/utils";
import { uiClock } from "@comma/ui/clock";
import { getNativeBridge } from "@comma/native-bridge";
import { useCommaMessages } from "@comma/i18n/react";
import {
  useContext,
  useEffect,
  useId,
  useMemo,
  useState,
  type ComponentProps,
  type ReactNode,
} from "react";
import {
  Button as AriaButton,
  Header,
  MenuSection,
  MenuTrigger,
  OverlayTriggerStateContext,
} from "react-aria-components";
import { ShellIconButtonControl } from "../ShellIconButton";
import { DriveFileName } from "../drive/DriveFileName";
import type {
  DownloadLink,
  ResolveFileBytes,
  SaveToDownloads,
} from "../../runtime-files/fileDownloads";
import type { ConversationFileSource } from "../../runtime-files/fileSources";
import {
  FilePreviewContent,
  filePreviewKind,
  textPreviewLimit,
} from "./FilePreviewContent";
import { FilePreviewLoading } from "./FilePreviewLoading";
import {
  documentHtml,
  documentMarkdown,
  documentParts,
  documentTree,
} from "./documentExport";
import { nativePlatformClipboard } from "../../nativePlatformActions";
import { ArtifactAnnotations } from "./ArtifactAnnotations";
import { DocumentFilePreview, type DocumentWriter } from "./DocumentFilePreview";
import { PdfFilePreview, type RangedFile } from "./PdfFilePreview";
import { pdfRegionEditMessage } from "./pdfRegionEdit";
import { ArchiveFilePreview } from "./ArchiveFilePreview";
import { CsvFilePreview } from "./CsvFilePreview";
import { DocxFilePreview } from "./DocxFilePreview";
import { JsonFilePreview } from "./JsonFilePreview";
import { NotebookFilePreview } from "./NotebookFilePreview";
import { SheetFilePreview } from "./SheetFilePreview";
import { SlidesFilePreview } from "./SlidesFilePreview";
import { TiffFilePreview } from "./TiffFilePreview";
import { tiffPreviewMaxBytes } from "./tiff";
import { wholeFileOf } from "./wholeFile";

/** The versions a document's title opens: the ones its chat holds, and the earlier one the page compares with. */
export type DocumentVersions = {
  /**
   * Oldest first; the last is the current one. `title` says when the version was written, `author` who wrote it,
   * and `avatar` is the author's picture (about one line of text high).
   */
  items: readonly { id: string; title: string; author: string; avatar: ReactNode }[];
  /** The version the page shows. */
  current: string;
  onSelect: (id: string) => void;
  /**
   * The earlier version the page compares the shown one with: the page shows what changed from it. Undefined: the
   * page shows the version itself.
   */
  comparing: string | undefined;
  /** Compares the shown version with `base`, an earlier one; undefined stops comparing. */
  onCompare: (base: string | undefined) => void;
  /**
   * Makes an earlier version the document's current one again (its text becomes a new version). Without it, a
   * version cannot be restored here.
   */
  onRestore?: ((id: string) => void) | undefined;
  /**
   * The reader's own edits of the shown version, which no message has carried yet: the page shows them, and they
   * head the list until they are sent or discarded.
   */
  unsent?:
    | { title: string; author: string; avatar: ReactNode; onDiscard: () => void }
    | undefined;
};

type DocumentVersionItem = DocumentVersions["items"][number];

/** A version as a row of a list: when it was written, and under it who wrote it. */
function DocumentVersionRow({
  version,
  tag,
}: {
  version: Omit<DocumentVersionItem, "id">;
  /** What the version is among the others: the current one, or one not sent yet. */
  tag?: string | undefined;
}) {
  return (
    <span className="flex min-w-0 flex-col gap-xs">
      <span className="flex min-w-0 items-baseline gap-md">
        <span className="truncate font-medium text-primary">{version.title}</span>
        {tag ? (
          <span className="shrink-0 text-xs font-regular text-quaternary">{tag}</span>
        ) : null}
      </span>
      <span className="flex min-w-0 items-center gap-sm font-regular text-tertiary">
        <span className="flex size-2xl shrink-0 items-center justify-center">
          {version.avatar}
        </span>
        <span className="truncate">{version.author}</span>
      </span>
    </span>
  );
}

/** A version in one line: its author's picture and when it was written. */
function DocumentVersionName({ version }: { version: DocumentVersionItem }) {
  return (
    <span className="flex min-w-0 items-center gap-sm" title={version.author}>
      <span className="flex size-2xl shrink-0 items-center justify-center">
        {version.avatar}
      </span>
      <span className="truncate font-medium text-primary">{version.title}</span>
    </span>
  );
}

const versionCheck = <CheckLargeIcon className="size-xl text-fg-brand-primary" />;

/**
 * The bar over a page that compares two versions. It names both: the earlier one the changes are counted from, then
 * the one shown. Where the document has more earlier versions, the first is a menu of them, so the reader chooses
 * what to compare with. Done shows the version itself again.
 */
function DocumentCompareBar({ versions }: { versions: DocumentVersions }) {
  const messages = useCommaMessages();
  const shownAt = versions.items.findIndex((item) => item.id === versions.current);
  const shown = versions.items[shownAt];
  const base = versions.items
    .slice(0, Math.max(0, shownAt))
    .find((item) => item.id === versions.comparing);
  if (!shown || !base) return null;
  const earlier = versions.items.slice(0, shownAt);
  const baseLabel = messages.file_preview_document_compare_base();
  return (
    <div
      aria-label={messages.file_preview_document_compare()}
      className="flex shrink-0 items-center gap-md border-b-[length:var(--border-width-0-5)] border-primary bg-secondary px-xl py-sm text-sm text-tertiary"
      data-testid="document-compare-bar"
      // A bar of two names and a button, not a form's set of fields.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="group"
    >
      {/* In a narrow panel the shown version goes to a line of its own, after its arrow. */}
      <div className="flex min-w-0 flex-1 flex-wrap items-center gap-x-md gap-y-xs">
        <span className="flex min-w-0 items-center gap-md">
          <span className="shrink-0">{messages.file_preview_document_comparing()}</span>
          {earlier.length > 1 ? (
            <MenuTrigger>
              <AriaButton
                aria-label={baseLabel}
                className="-mx-xs flex min-w-0 items-center gap-xs rounded-sm border-0 bg-transparent px-xs py-xxs outline-none hover:bg-quaternary focus-visible:shadow-focus-gray"
                data-testid="document-compare-base"
              >
                <DocumentVersionName version={base} />
                <ChevronDownSmallIcon
                  aria-hidden
                  className="size-xl shrink-0 text-quaternary"
                />
              </AriaButton>
              <MenuPopover
                className={cx("w-72 overflow-hidden", menuSurfaceClasses)}
                placement="bottom start"
              >
                <ScrollArea
                  className="max-h-[inherit]"
                  viewportClassName="max-h-[inherit]"
                >
                  <Menu
                    aria-label={baseLabel}
                    className="py-sm"
                    disallowEmptySelection
                    onSelectionChange={(keys) => {
                      if (keys === "all") return;
                      const [key] = Array.from(keys);
                      if (key !== undefined) versions.onCompare(String(key));
                    }}
                    selectedKeys={[base.id]}
                    selectionMode="single"
                    variant="embedded"
                  >
                    {earlier.toReversed().map((version) => (
                      <MenuItem
                        contentClassName="py-md"
                        id={version.id}
                        key={version.id}
                        shortcut={version.id === base.id ? versionCheck : undefined}
                        textValue={`${version.title}, ${version.author}`}
                      >
                        <DocumentVersionRow version={version} />
                      </MenuItem>
                    ))}
                  </Menu>
                </ScrollArea>
              </MenuPopover>
            </MenuTrigger>
          ) : (
            <DocumentVersionName version={base} />
          )}
        </span>
        <span className="flex min-w-0 items-center gap-md">
          <ArrowRightIcon aria-hidden className="size-xl shrink-0 text-quaternary" />
          <DocumentVersionName version={shown} />
        </span>
      </div>
      <Button
        className="shrink-0"
        data-testid="document-compare-done"
        hierarchy="secondary-gray"
        onPress={() => versions.onCompare(undefined)}
        size="xs"
      >
        {messages.file_preview_document_compare_done()}
      </Button>
    </div>
  );
}

/**
 * What a reader does with a row of the versions list besides showing it: restore an earlier version, or discard
 * edits not sent yet. The button shows with the pointer over the row; a reader at the keyboard restores a version
 * from the bar over the page that shows it (`DocumentEarlierBar`), and undoes edits in the page.
 */
function DocumentVersionActions({
  action,
  onAction,
}: {
  /** The one action's name. */
  action: string;
  /** Does it, and closes the list. */
  onAction: () => void;
}) {
  const messages = useCommaMessages();
  return (
    <MenuTrigger>
      <AriaButton
        aria-label={messages.file_preview_document_version_actions()}
        className="flex size-3xl shrink-0 items-center justify-center rounded-sm border-0 bg-transparent text-tertiary opacity-0 outline-none group-hover/version:opacity-100 hover:bg-primary hover:text-primary focus-visible:opacity-100 focus-visible:shadow-focus-gray aria-expanded:bg-primary aria-expanded:opacity-100"
        data-testid="document-version-actions"
      >
        <MoreHorizontalIcon aria-hidden className="size-xl" />
      </AriaButton>
      <MenuPopover
        className={cx("w-48 overflow-hidden", menuSurfaceClasses)}
        placement="bottom end"
      >
        <Menu
          aria-label={messages.file_preview_document_version_actions()}
          className="py-sm"
          onAction={onAction}
          variant="embedded"
        >
          <MenuItem id="action">{action}</MenuItem>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}

/** The key of the row of edits not sent yet: no version's id. */
const unsentRow = "\u0000unsent";

/**
 * The rows of the versions list: edits not sent yet first, then the versions, newest first. They close the list
 * they are in when an action is taken from one.
 */
function DocumentVersionItems({ versions }: { versions: DocumentVersions }) {
  const messages = useCommaMessages();
  const list = useContext(OverlayTriggerStateContext);
  const { onRestore, unsent } = versions;
  const row = (
    id: string,
    version: Omit<DocumentVersionItem, "id">,
    shown: boolean,
    tag: string | undefined,
    action: { name: string; run: () => void } | undefined
  ) => (
    <MenuItem
      contentClassName="group/version py-md"
      id={id}
      key={id}
      shortcut={shown ? versionCheck : undefined}
      textValue={`${version.title}, ${version.author}`}
    >
      <span className="flex min-w-0 items-center gap-md">
        <span className="min-w-0 flex-1">
          <DocumentVersionRow tag={tag} version={version} />
        </span>
        {action ? (
          <DocumentVersionActions
            action={action.name}
            onAction={() => {
              list?.close();
              action.run();
            }}
          />
        ) : null}
      </span>
    </MenuItem>
  );
  return [
    ...(unsent
      ? [
          row(
            unsentRow,
            unsent,
            true,
            messages.file_preview_document_version_unsent_tag(),
            {
              name: messages.file_preview_document_discard(),
              run: unsent.onDiscard,
            }
          ),
        ]
      : []),
    ...versions.items.toReversed().map((version, index) =>
      row(
        version.id,
        version,
        // The page shows the reader's edits of the version, where there are some.
        !unsent && version.id === versions.current,
        index === 0 ? messages.file_preview_document_version_current() : undefined,
        // The newest version is the current one already.
        onRestore && index > 0
          ? {
              name: messages.file_preview_document_restore(),
              run: () => onRestore(version.id),
            }
          : undefined
      )
    ),
  ];
}

/**
 * Asks before a version is restored: it names the version, and says what restoring does and does not do.
 */
function DocumentRestoreDialog({
  version,
  onRestore,
  onClose,
}: {
  version: DocumentVersionItem;
  onRestore: () => void;
  onClose: () => void;
}) {
  const messages = useCommaMessages();
  return (
    <Dialog
      actions={[
        {
          label: messages.drive_editor_cancel(),
          hierarchy: "secondary-gray",
          onPress: onClose,
        },
        {
          label: messages.file_preview_document_restore_confirm(),
          hierarchy: "primary",
          onPress: onRestore,
        },
      ]}
      description={
        <>
          <span className="mb-md flex items-center gap-sm text-primary">
            <DocumentVersionName version={version} />
            <span className="shrink-0 text-tertiary">· {version.author}</span>
          </span>
          {messages.file_preview_document_restore_description()}
        </>
      }
      isOpen
      onOpenChange={(open) => {
        if (!open) onClose();
      }}
      title={messages.file_preview_document_restore()}
    />
  );
}

/**
 * The bar over a page that shows an earlier version: it says so, names the version, and restores it.
 */
function DocumentEarlierBar({ versions }: { versions: DocumentVersions }) {
  const messages = useCommaMessages();
  const { onRestore } = versions;
  const shown = versions.items.find((item) => item.id === versions.current);
  if (
    !onRestore ||
    !shown ||
    shown === versions.items.at(-1) ||
    versions.comparing !== undefined
  )
    return null;
  return (
    <div
      aria-label={messages.file_preview_document_earlier()}
      className="flex shrink-0 items-center gap-md border-b-[length:var(--border-width-0-5)] border-primary bg-secondary px-xl py-sm text-sm text-tertiary"
      data-testid="document-earlier-bar"
      // A bar of a name and a button, not a form's set of fields.
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="group"
    >
      <div className="flex min-w-0 flex-1 flex-wrap items-center gap-x-md gap-y-xs">
        <span className="shrink-0">{messages.file_preview_document_earlier()}</span>
        <DocumentVersionName version={shown} />
      </div>
      <Button
        className="shrink-0"
        data-testid="document-earlier-restore"
        hierarchy="secondary-gray"
        onPress={() => onRestore(shown.id)}
        size="xs"
      >
        {messages.file_preview_document_restore()}
      </Button>
    </div>
  );
}

/**
 * A document's name as the way to its versions: a history, newest first. Each version is when it was written and
 * who wrote it; the newest is marked current and the one the page shows is checked. Under them, where the shown
 * version has an earlier one, is the choice to compare the two (`DocumentCompareBar` then says which they are).
 */
function DocumentVersionsMenu({
  fileName,
  versions,
}: {
  fileName: string;
  versions: DocumentVersions;
}) {
  const messages = useCommaMessages();
  const label = messages.file_preview_document_versions({ fileName });
  // The version before the one shown: what a comparison starts with.
  const previous =
    versions.items[
      versions.items.findIndex((item) => item.id === versions.current) - 1
    ];
  return (
    <MenuTrigger>
      <AriaButton
        aria-label={label}
        className="-ml-md flex min-w-0 items-center gap-xs rounded-sm border-0 bg-transparent px-md py-xs text-sm font-medium text-primary outline-none hover:bg-button-tertiary-bg-hover focus-visible:shadow-focus-gray"
        data-testid="file-preview-versions"
      >
        <DriveFileName className="min-w-0 flex-1" name={fileName} />
        <ChevronDownSmallIcon
          aria-hidden
          className="size-xl shrink-0 text-quaternary"
        />
      </AriaButton>
      <MenuPopover
        placement="bottom start"
        className={cx("w-72 overflow-hidden", menuSurfaceClasses)}
      >
        <ScrollArea className="max-h-[inherit]" viewportClassName="max-h-[inherit]">
          <Menu
            aria-label={label}
            className="py-sm"
            disallowEmptySelection
            onSelectionChange={(keys) => {
              if (keys === "all") return;
              const [key] = Array.from(keys);
              if (key !== undefined && key !== versions.current && key !== unsentRow)
                versions.onSelect(String(key));
            }}
            selectedKeys={[versions.unsent ? unsentRow : versions.current]}
            selectionMode="single"
            variant="embedded"
          >
            <DocumentVersionItems versions={versions} />
          </Menu>
          {previous === undefined ? null : (
            <>
              <MenuSeparator />
              <Menu
                aria-label={messages.file_preview_document_compare()}
                className="pb-sm"
                onSelectionChange={(keys) =>
                  versions.onCompare(
                    keys === "all" || keys.size > 0 ? previous.id : undefined
                  )
                }
                selectedKeys={versions.comparing === undefined ? [] : ["compare"]}
                selectionMode="multiple"
                variant="embedded"
              >
                <MenuItem
                  id="compare"
                  shortcut={versions.comparing === undefined ? undefined : versionCheck}
                >
                  {messages.file_preview_document_compare()}
                </MenuItem>
              </Menu>
            </>
          )}
        </ScrollArea>
      </MenuPopover>
    </MenuTrigger>
  );
}

/** Drive's existing filename and shell controls, shared by both preview entries. */
function FilePreviewToolbar({
  fileName,
  versions,
  download,
  openIn,
  viewerActions,
  extraActions,
  page,
}: {
  fileName: string;
  /** A document's versions: its name opens them. */
  versions?: DocumentVersions | undefined;
  download: ChatPanelMediaDownloadAction;
  openIn?: ChatPanelFileOpenInAction | undefined;
  /** The reader's own controls (a PDF's zoom), before the file's. */
  viewerActions?: ReactNode;
  extraActions?: ReactNode;
  /** The file is a document read as a page: its ways out are under one Open button. */
  page?: boolean | undefined;
}) {
  const messages = useCommaMessages();
  const feedbackId = useId();
  const controller = useChatPanelMediaDownloadController({
    action: download,
    kind: "file",
  });
  const pending = controller.state.status === "pending";
  const label = messages.drive_preview_download({ fileName });
  const feedback = pending
    ? messages.ui_file_downloading()
    : controller.state.status === "success"
      ? messages.ui_file_downloaded_feedback()
      : controller.state.status === "error"
        ? messages.ui_file_download_failed_feedback()
        : "";

  const tooltip = pending ? messages.ui_file_downloading() : label;
  const button = {
    "aria-label": label,
    "aria-busy": pending,
    ...(feedback ? { "aria-describedby": feedbackId } : {}),
    "data-testid": "file-preview-download",
    "data-download-state": controller.state.status,
    icon: <DownloadIcon className="comma-input-icon" />,
  };

  return (
    <div
      className="flex min-h-11 shrink-0 items-center justify-between gap-md border-b-[0.5px] border-primary py-xs pr-2.5 pl-xl"
      data-testid="file-preview-toolbar"
    >
      <h2 className="m-0 flex min-w-0 flex-1 text-sm font-medium text-primary">
        {versions ? (
          <DocumentVersionsMenu fileName={fileName} versions={versions} />
        ) : (
          <DriveFileName className="min-w-0 flex-1" name={fileName} />
        )}
      </h2>
      <div className="flex shrink-0 items-center gap-xs">
        {viewerActions}
        {extraActions}
        {openIn && page ? (
          <DocumentOpenMenu
            action={openIn}
            canDownload={controller.canExecute}
            download={() => void controller.execute()}
            downloading={pending}
          />
        ) : openIn ? (
          <FileActionsMenu
            action={openIn}
            button={button}
            canDownload={controller.canExecute}
            download={() => void controller.execute()}
            downloading={pending}
            fileName={fileName}
            label={label}
            tooltip={tooltip}
          />
        ) : (
          <Tooltip content={tooltip} placement="bottom">
            <ShellIconButtonControl
              {...button}
              isDisabled={!controller.canExecute}
              onPress={() => void controller.execute()}
            />
          </Tooltip>
        )}
        <output
          aria-atomic="true"
          aria-live="polite"
          className="sr-only"
          id={feedbackId}
        >
          {feedback}
        </output>
      </div>
    </div>
  );
}

/**
 * Where the desktop opens files in other apps, the download button holds every way out of the preview: the file
 * itself, the apps that open it, and its place on disk.
 */
function FileActionsMenu({
  action,
  button,
  canDownload,
  download,
  downloading,
  fileName,
  label,
  tooltip,
}: {
  action: ChatPanelFileOpenInAction;
  button: Omit<Parameters<typeof ShellIconButtonControl>[0], "onPress">;
  canDownload: boolean;
  download: () => void;
  downloading: boolean;
  fileName: string;
  label: string;
  tooltip: string;
}) {
  const messages = useCommaMessages();
  const [open, setOpen] = useState(false);
  useEffect(() => setOpen(false), [action]);
  const openIn = useChatPanelFileOpenIn(action, open);
  const pending = openIn.operation === "pending";
  const failed = openIn.operation === "error";
  useEffect(() => {
    if (failed) toast.error(messages.ui_file_open_failed());
  }, [failed, messages]);
  // The download names the file's format, as a save panel's Format does.
  const extension = /\.([^./]+)$/u.exec(fileName)?.[1];
  // A heading sits in the column of the rows below it.
  const header = "mx-sm px-md pt-sm pb-xs text-xs font-medium text-quaternary";
  return (
    <MenuTrigger isOpen={open} onOpenChange={setOpen}>
      <Tooltip content={tooltip} placement="bottom">
        <ShellIconButtonControl
          {...button}
          aria-busy={downloading || pending}
          className={cx(open && "bg-button-tertiary-bg-hover text-fg-brand-primary")}
          isDisabled={pending}
        />
      </Tooltip>
      {/* A long list of applications scrolls inside the popover, which is no taller than the list's own bound. */}
      <MenuPopover
        placement="bottom end"
        className={cx(
          "chat-panel-file-applications w-60 overflow-hidden",
          menuSurfaceClasses
        )}
        maxHeight={fileApplicationsMaxHeight}
      >
        <ScrollArea className="max-h-[inherit]" viewportClassName="max-h-[inherit]">
          <Menu aria-label={label} className="py-sm" variant="embedded">
            <MenuSection>
              <Header className={header}>{messages.ui_file_download()}</Header>
              <MenuItem
                icon={<FileIcon />}
                id="download"
                isDisabled={!canDownload}
                onAction={download}
                textValue={extension?.toUpperCase() ?? messages.ui_file_download()}
              >
                {extension?.toUpperCase() ?? messages.ui_file_download()}
              </MenuItem>
            </MenuSection>
            <MenuSeparator />
            <MenuSection>
              <Header className={header}>{messages.ui_file_open_in()}</Header>
              <ChatPanelFileApplicationItems action={action} openIn={openIn} />
              {action.reveal ? (
                <MenuItem id="reveal" onAction={() => openIn.run(action.reveal!.run)}>
                  {action.reveal.label}
                </MenuItem>
              ) : null}
            </MenuSection>
          </Menu>
        </ScrollArea>
      </MenuPopover>
    </MenuTrigger>
  );
}

/**
 * A document's Open, where the desktop opens files in other apps: the apps that open it, then its place on disk
 * and its download. It is the one way out of the page, in place of the download button.
 */
function DocumentOpenMenu({
  action,
  canDownload,
  download,
  downloading,
}: {
  action: ChatPanelFileOpenInAction;
  canDownload: boolean;
  download: () => void;
  downloading: boolean;
}) {
  const messages = useCommaMessages();
  const [open, setOpen] = useState(false);
  useEffect(() => setOpen(false), [action]);
  const openIn = useChatPanelFileOpenIn(action, open);
  const pending = openIn.operation === "pending";
  const failed = openIn.operation === "error";
  useEffect(() => {
    if (failed) toast.error(messages.ui_file_open_failed());
  }, [failed, messages]);
  return (
    <MenuTrigger isOpen={open} onOpenChange={setOpen}>
      <Button
        aria-busy={downloading || pending}
        className="ml-xs"
        data-testid="file-preview-open"
        hierarchy="secondary-gray"
        iconTrailing={<ChevronDownSmallIcon aria-hidden />}
        isDisabled={pending}
        size="xs"
      >
        {messages.common_open()}
      </Button>
      {/* A long list of applications scrolls inside the popover, which is no taller than the list's own bound. */}
      <MenuPopover
        placement="bottom end"
        className={cx(
          "chat-panel-file-applications w-60 overflow-hidden",
          menuSurfaceClasses
        )}
        maxHeight={fileApplicationsMaxHeight}
      >
        <ScrollArea className="max-h-[inherit]" viewportClassName="max-h-[inherit]">
          <Menu
            aria-label={messages.ui_file_open_in()}
            className="py-sm"
            variant="embedded"
          >
            <ChatPanelFileApplicationItems action={action} openIn={openIn} />
            <MenuSeparator />
            {action.reveal ? (
              <MenuItem id="reveal" onAction={() => openIn.run(action.reveal!.run)}>
                {action.reveal.label}
              </MenuItem>
            ) : null}
            <MenuItem id="download" isDisabled={!canDownload} onAction={download}>
              {messages.ui_file_download()}
            </MenuItem>
          </Menu>
        </ScrollArea>
      </MenuPopover>
    </MenuTrigger>
  );
}

// The longest HTML the desktop's clipboard takes beside the text (`clipboard.writeText`).
const clipboardHtmlLimit = 4_000_000;

/**
 * Copies a document as Markdown other products take (`documentExport`), with the same document as HTML beside it:
 * a plain editor pastes the Markdown, a rich one (Google Docs, Notion) pastes headings, lists and tables.
 */
async function copyDocument(
  blob: Blob,
  parts: ResolveFileBytes | undefined,
  draft: string | undefined
) {
  // A preview holds the head of a long file; the copy is of all of it. A reader's edits of the page are what
  // the page shows, so they are what is copied.
  const whole = blob.size > textPreviewLimit && parts ? await parts() : blob;
  // The copy is of the page: the document's front matter is facts about the file, not text a reader pastes.
  const tree = documentTree(documentParts(draft ?? (await whole.text())).page);
  const text = documentMarkdown(tree);
  const html = documentHtml(tree);
  const bridge = getNativeBridge();
  if (bridge.platform === "electron") {
    await bridge.clipboard.writeText({
      text,
      ...(html.length <= clipboardHtmlLimit ? { html } : {}),
    });
    return;
  }
  try {
    await navigator.clipboard.write([
      new ClipboardItem({
        "text/plain": new Blob([text], { type: "text/plain" }),
        "text/html": new Blob([html], { type: "text/html" }),
      }),
    ]);
  } catch {
    // A browser that writes no HTML still copies the Markdown.
    await nativePlatformClipboard.writeText(text);
  }
}

/** The document toolbar's Copy as Markdown: the button shows a check while the copy is fresh. */
function CopyDocumentButton({
  blob,
  parts,
  draft,
}: {
  blob: Blob;
  parts: ResolveFileBytes | undefined;
  /** The reader's edits of the document not sent yet, as the whole document. */
  draft: string | undefined;
}) {
  const messages = useCommaMessages();
  const [copied, setCopied] = useState(false);
  useEffect(
    () => (copied ? uiClock.after(1400, () => setCopied(false)) : undefined),
    [copied]
  );
  const label = messages.file_preview_document_copy_markdown();
  return (
    <Tooltip
      content={copied ? messages.file_preview_document_copied() : label}
      placement="bottom"
    >
      <ShellIconButtonControl
        aria-label={label}
        data-testid="file-preview-copy-markdown"
        icon={
          // The two icons hold one cell and change by the shared icon swap, as a message's Copy does.
          <span
            aria-hidden="true"
            className="t-icon-swap [--icon-swap-dur:var(--motion-duration-feedback-in)]"
            data-state={copied ? "b" : "a"}
            data-swap-blur="none"
          >
            <span className="t-icon inline-flex" data-icon="a">
              <CopyIcon className="comma-input-icon" />
            </span>
            <span className="t-icon inline-flex" data-icon="b">
              <CheckIcon className="comma-input-icon text-fg-success-primary" />
            </span>
          </span>
        }
        onPress={() =>
          void copyDocument(blob, parts, draft).then(
            () => setCopied(true),
            () =>
              toast.error(messages.file_preview_document_copy_failed(), {
                id: "comma-document-copy",
                testId: "comma-document-copy",
              })
          )
        }
      />
    </Tooltip>
  );
}

/** The same reader and file actions serve chat attachments and Drive files. */
export function FilePreviewPanel({
  fileName,
  mimeType,
  blob,
  mediaUrl,
  mediaKey,
  ranged,
  error,
  placeholder,
  panelId,
  testId,
  download,
  save,
  link,
  parts,
  openIn,
  extraActions,
  annotationContext,
  requestEdits,
  documentWriter,
  documentPlayFirst,
  documentEdits,
  documentVersions,
  documentCompare,
  documentEditing,
  documentPictures,
  children,
  onOpenBrowser,
  onAttachFiles,
  attachment,
  onAttachConversationFiles,
}: {
  fileName: string;
  mimeType?: string | undefined;
  blob?: Blob | undefined;
  mediaUrl?: string | undefined;
  /** The file `mediaUrl` reads, when that URL can be renewed: a new URL of it keeps the playback position. */
  mediaKey?: string | undefined;
  ranged?: RangedFile | undefined;
  error?: string | undefined;
  placeholder?: string | undefined;
  panelId: string;
  testId: string;
  download: ChatPanelMediaDownloadAction;
  /** How the desktop saves the shown file without reading it whole, for the media menu's Save (a chat file). */
  save?: SaveToDownloads | undefined;
  /** How a browser downloads the shown file itself, for the media menu's Save (a chat file on the web). */
  link?: DownloadLink | undefined;
  /** How the shown file is read a part at a time for a browser to save, when it has no link (a Task's on a machine). */
  parts?: ResolveFileBytes | undefined;
  openIn?: ChatPanelFileOpenInAction | undefined;
  extraActions?: ReactNode;
  children?: ReactNode;
  annotationContext?:
    | { storageKey: string; onSend: (text: string) => void }
    | undefined;
  /** Where a PDF's Request edits sends an area of a page; without it the PDF is read-only. */
  requestEdits?:
    | {
        /** How the agent finds the file: the attachment it was sent as. */
        reference: string;
        send: (
          text: string,
          files: { bytes: Uint8Array; name: string; size: number }[]
        ) => void;
      }
    | undefined;
  /** The Agent whose versions of a Markdown document arrive while it is shown: each is typed into the page. */
  documentWriter?: DocumentWriter | undefined;
  /** The document shown first is the writer's own, new now. */
  documentPlayFirst?: boolean | undefined;
  /** A reader's own edits of a Markdown document's page (`DocumentFilePreview`). */
  documentEditing?: ComponentProps<typeof DocumentFilePreview>["editing"];
  /** Reads a file that goes with the document: a page that is read draws the document's own pictures with it. */
  documentPictures?: ComponentProps<typeof DocumentFilePreview>["pictures"];
  /** A Markdown document's versions, which its name opens. */
  documentVersions?: DocumentVersions | undefined;
  /** The version before the one shown, when the page compares the two. */
  documentCompare?: Blob | undefined;
  /** Asking Comma to change passages of a Markdown document (`DocumentFilePreview`). */
  documentEdits?: ComponentProps<typeof DocumentFilePreview>["edits"];
  onOpenBrowser: (url: string) => void;
  onAttachFiles?: ((files: AttachmentUploadInput[]) => unknown) | undefined;
  /** The message attachment shown, which Add to Context attaches by reference (`onAttachConversationFiles`). */
  attachment?: ConversationFileSource | undefined;
  onAttachConversationFiles?: ((files: ChatConversationFile[]) => unknown) | undefined;
}) {
  const imageMenu = useMediaContextMenu(onAttachFiles, onAttachConversationFiles);
  const kind = filePreviewKind(fileName, mimeType || blob?.type);
  const document = kind === "text" || kind === "markdown" || kind === "html";
  // A PDF reader scrolls its own pages, with the panel's content after the last one.
  const pdf = kind === "pdf" && !error && (blob || ranged);
  // A deck's slides, a Word document's pages and a workbook's sheet scroll in a column of their own, as a PDF's
  // pages do.
  const office = !error && (blob || ranged);
  const slides = kind === "slides" && office;
  const docx = kind === "docx" && office;
  const xlsx = kind === "xlsx" && office;
  const csv = kind === "csv" && office;
  const notebook = kind === "notebook" && office;
  const json = (kind === "json" || kind === "jsonl") && office;
  const archive = kind === "archive" && office;
  // A TIFF is decoded to a PNG and shown in the image column below, as any other image is.
  const tiff = kind === "tiff" && office;
  // A Markdown file is read as a page in a reading column of its own: `paged` from the moment it opens, `page` once
  // its bytes are here. The toolbar is the page's from the start, so it does not change when the bytes arrive.
  const paged = kind === "markdown" && !error;
  const page = paged ? blob : undefined;
  const [viewerActions, setViewerActions] = useState<HTMLElement | null>(null);
  // Restoring a version replaces what the page holds, so the reader is asked first: the list and the bar over an
  // earlier version only name the version, and the dialog restores it.
  const [restoring, setRestoring] = useState<string>();
  const restore = documentVersions?.onRestore;
  const versions = useMemo(
    () =>
      documentVersions && restore
        ? { ...documentVersions, onRestore: setRestoring }
        : documentVersions,
    [documentVersions, restore]
  );
  const restored = documentVersions?.items.find((item) => item.id === restoring);
  return (
    <section
      className="flex min-h-0 min-w-0 flex-1 flex-col"
      data-testid={testId}
      role="tabpanel"
      id={panelId}
    >
      <FilePreviewToolbar
        fileName={fileName}
        versions={paged ? versions : undefined}
        page={paged}
        download={download}
        openIn={openIn}
        viewerActions={
          pdf || paged || json || archive ? (
            <span className="contents" ref={setViewerActions} />
          ) : undefined
        }
        extraActions={
          // The adapter's own actions keep their place whether or not the file is a document, so they stay the
          // same controls when the file's bytes arrive.
          <>
            {page ? (
              <CopyDocumentButton
                blob={page}
                draft={documentEditing?.draft}
                parts={parts}
              />
            ) : null}
            {extraActions}
          </>
        }
      />
      {page && versions ? (
        <>
          <DocumentEarlierBar versions={versions} />
          <DocumentCompareBar versions={versions} />
        </>
      ) : null}
      {restore && restored ? (
        <DocumentRestoreDialog
          onClose={() => setRestoring(undefined)}
          onRestore={() => {
            setRestoring(undefined);
            restore(restored.id);
          }}
          version={restored}
        />
      ) : null}
      {pdf ? (
        <PdfFilePreview
          blob={ranged ? undefined : blob}
          ranged={ranged}
          toolbarSlot={viewerActions}
          onRequestEdit={
            requestEdits
              ? (edit) => {
                  const message = pdfRegionEditMessage(edit, {
                    fileName,
                    reference: requestEdits.reference,
                  });
                  requestEdits.send(message.text, message.files);
                }
              : undefined
          }
        >
          {children}
        </PdfFilePreview>
      ) : slides ? (
        <SlidesFilePreview
          blob={ranged ? undefined : blob}
          ranged={ranged}
          onOpenBrowser={onOpenBrowser}
        >
          {children}
        </SlidesFilePreview>
      ) : docx ? (
        <DocxFilePreview
          blob={ranged ? undefined : blob}
          ranged={ranged}
          onOpenBrowser={onOpenBrowser}
        >
          {children}
        </DocxFilePreview>
      ) : xlsx ? (
        <SheetFilePreview
          blob={ranged ? undefined : blob}
          ranged={ranged}
          onOpenBrowser={onOpenBrowser}
        >
          {children}
        </SheetFilePreview>
      ) : csv ? (
        <CsvFilePreview
          blob={ranged ? undefined : blob}
          fileName={fileName}
          mimeType={mimeType}
          ranged={ranged}
          onOpenBrowser={onOpenBrowser}
        >
          {children}
        </CsvFilePreview>
      ) : notebook ? (
        <NotebookFilePreview
          blob={ranged ? undefined : blob}
          ranged={ranged}
          onOpenBrowser={onOpenBrowser}
        >
          {children}
        </NotebookFilePreview>
      ) : json ? (
        <JsonFilePreview
          blob={ranged ? undefined : blob}
          fileName={fileName}
          lines={kind === "jsonl"}
          ranged={ranged}
          toolbarSlot={viewerActions}
          onOpenBrowser={onOpenBrowser}
        >
          {children}
        </JsonFilePreview>
      ) : archive ? (
        <ArchiveFilePreview
          blob={ranged ? undefined : blob}
          fileName={fileName}
          mimeType={mimeType}
          ranged={ranged}
          toolbarSlot={viewerActions}
        >
          {children}
        </ArchiveFilePreview>
      ) : page ? (
        <DocumentFilePreview
          blob={page}
          fileName={fileName}
          writer={documentWriter}
          playFirst={documentPlayFirst}
          toolbarSlot={viewerActions}
          onOpenBrowser={onOpenBrowser}
          edits={documentEdits}
          compare={documentCompare}
          editing={documentEditing}
          pictures={documentPictures}
        >
          {children}
        </DocumentFilePreview>
      ) : paged ? (
        // The document's bytes are on their way: the mark is in the middle of the panel, and nothing else is there.
        <FilePreviewLoading />
      ) : (
        <ScrollArea
          className="min-h-0 flex-1"
          viewportClassName="h-full"
          contentClassName="flex min-h-full flex-col"
          edgeEffect="none"
        >
          <div className="flex min-h-full flex-1 flex-col">
            <div
              className={cx(
                "flex min-h-0 flex-1 flex-col p-xl",
                document ? "items-stretch justify-start" : "items-center justify-center"
              )}
              data-testid="file-preview-content"
              onContextMenu={(event) => {
                const media =
                  event.target instanceof Element
                    ? event.target.closest("img, video")
                    : null;
                if (
                  !(
                    media instanceof HTMLImageElement ||
                    media instanceof HTMLVideoElement
                  )
                )
                  return;
                imageMenu.open(event, {
                  ...(tiff && media instanceof HTMLImageElement
                    ? {
                        // Saved and attached as the TIFF it is; copied as the decoded PNG the clipboard takes.
                        fileName,
                        resolve: async (signal) => {
                          if (blob && !ranged) return blob;
                          const read = await wholeFileOf(
                            { ranged },
                            signal ?? new AbortController().signal,
                            tiffPreviewMaxBytes
                          );
                          if ("error" in read) throw new Error(read.error);
                          return new Blob([read.bytes], { type: "image/tiff" });
                        },
                        copyImage: mediaElementSource(media).resolve,
                      }
                    : (kind === "image" || kind === "video") && blob
                      ? {
                          fileName,
                          resolve: async () => blob,
                          ...(media instanceof HTMLVideoElement
                            ? { video: media }
                            : {}),
                        }
                      : mediaElementSource(media)),
                  ...(save ? { save } : {}),
                  ...(link ? { link } : {}),
                  ...(parts ? { parts } : {}),
                  ...(attachment ? { attachment } : {}),
                });
              }}
            >
              {/* Notes are of text a reader can select: a file whose bytes are on their way has none yet, and a
                  Markdown file is a page with its own way to ask for a change. */}
              {tiff ? (
                <TiffFilePreview
                  blob={ranged ? undefined : blob}
                  fileName={fileName}
                  ranged={ranged}
                />
              ) : annotationContext && kind === "text" && blob ? (
                <ArtifactAnnotations
                  key={annotationContext.storageKey}
                  storageKey={annotationContext.storageKey}
                  fileName={fileName}
                  onSend={annotationContext.onSend}
                >
                  <FilePreviewContent
                    fileName={fileName}
                    mimeType={mimeType}
                    blob={blob}
                    error={error}
                    placeholder={placeholder}
                    onOpenBrowser={onOpenBrowser}
                  />
                </ArtifactAnnotations>
              ) : (
                <FilePreviewContent
                  fileName={fileName}
                  mimeType={mimeType}
                  blob={blob}
                  mediaUrl={mediaUrl}
                  mediaKey={mediaKey}
                  error={error}
                  placeholder={placeholder}
                  onOpenBrowser={onOpenBrowser}
                />
              )}
            </div>
            {children}
          </div>
        </ScrollArea>
      )}
      {imageMenu.menu}
    </section>
  );
}
