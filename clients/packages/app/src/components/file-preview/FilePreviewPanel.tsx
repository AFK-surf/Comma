import type { ChatConversationFile } from "@comma/chat-contract";
import type { AttachmentUploadInput } from "@comma/core/chat";
import { mediaElementSource, useMediaContextMenu } from "./useMediaContextMenu";
import {
  ChatPanelFileApplicationItems,
  useChatPanelFileOpenIn,
  useChatPanelMediaDownloadController,
  type ChatPanelMediaDownloadAction,
  type ChatPanelFileOpenInAction,
} from "@comma/ui/components/chat-panel";
import { DownloadIcon, FileIcon } from "@comma/ui/components/icons";
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
import { useCommaMessages } from "@comma/i18n/react";
import { useEffect, useId, useState, type ReactNode } from "react";
import { Header, MenuSection, MenuTrigger } from "react-aria-components";
import { ShellIconButtonControl } from "../ShellIconButton";
import { DriveFileName } from "../drive/DriveFileName";
import type {
  DownloadLink,
  ResolveFileBytes,
  SaveToDownloads,
} from "../../runtime-files/fileDownloads";
import type { ConversationFileSource } from "../../runtime-files/fileSources";
import { FilePreviewContent, filePreviewKind } from "./FilePreviewContent";
import { ArtifactAnnotations } from "./ArtifactAnnotations";
import { PdfFilePreview, type RangedFile } from "./PdfFilePreview";
import { pdfRegionEditMessage } from "./pdfRegionEdit";

/** Drive's existing filename and shell controls, shared by both preview entries. */
function FilePreviewToolbar({
  fileName,
  download,
  openIn,
  viewerActions,
  extraActions,
}: {
  fileName: string;
  download: ChatPanelMediaDownloadAction;
  openIn?: ChatPanelFileOpenInAction | undefined;
  /** The reader's own controls (a PDF's zoom), before the file's. */
  viewerActions?: ReactNode;
  extraActions?: ReactNode;
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
        <DriveFileName className="min-w-0 flex-1" name={fileName} />
      </h2>
      <div className="flex shrink-0 items-center gap-xs">
        {viewerActions}
        {extraActions}
        {openIn ? (
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
      {/* Long application lists scroll inside the popover's own
          viewport-derived max-height instead of running off the window. */}
      <MenuPopover
        placement="bottom end"
        className={cx(
          "chat-panel-file-applications w-60 overflow-hidden",
          menuSurfaceClasses
        )}
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
  const [viewerActions, setViewerActions] = useState<HTMLElement | null>(null);
  return (
    <section
      className="flex min-h-0 min-w-0 flex-1 flex-col"
      data-testid={testId}
      role="tabpanel"
      id={panelId}
    >
      <FilePreviewToolbar
        fileName={fileName}
        download={download}
        openIn={openIn}
        viewerActions={
          pdf ? <span className="contents" ref={setViewerActions} /> : undefined
        }
        extraActions={extraActions}
      />
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
                  ...((kind === "image" || kind === "video") && blob
                    ? {
                        fileName,
                        resolve: async () => blob,
                        ...(media instanceof HTMLVideoElement ? { video: media } : {}),
                      }
                    : mediaElementSource(media)),
                  ...(save ? { save } : {}),
                  ...(link ? { link } : {}),
                  ...(parts ? { parts } : {}),
                  ...(attachment ? { attachment } : {}),
                });
              }}
            >
              {annotationContext && (kind === "text" || kind === "markdown") ? (
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
