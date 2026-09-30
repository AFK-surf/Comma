import type { AttachmentUploadInput } from "../chat/model/conversationChannel";
import { mediaElementSource, useMediaContextMenu } from "./useMediaContextMenu";
import {
  ChatPanelFileOpenInMenu,
  DownloadIcon,
  ScrollArea,
  Tooltip,
  cx,
  useChatPanelMediaDownloadController,
  type ChatPanelMediaDownloadAction,
  type ChatPanelFileOpenInAction,
} from "@comma/ui";
import { useCommaMessages } from "@comma/i18n/react";
import { useId, type ReactNode } from "react";
import { ShellIconButtonControl } from "../ShellIconButton";
import { DriveFileName } from "../drive/DriveFileName";
import { FilePreviewContent, filePreviewKind } from "./FilePreviewContent";

/** Drive's existing filename and shell controls, shared by both preview entries. */
function FilePreviewToolbar({
  fileName,
  download,
  openIn,
  extraActions,
}: {
  fileName: string;
  download: ChatPanelMediaDownloadAction;
  openIn?: ChatPanelFileOpenInAction | undefined;
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

  return (
    <div
      className="flex min-h-11 shrink-0 items-center justify-between gap-md border-b-[0.5px] border-primary py-xs pr-2.5 pl-xl"
      data-testid="file-preview-toolbar"
    >
      <h2 className="m-0 flex min-w-0 flex-1 text-sm font-medium text-primary">
        <DriveFileName className="min-w-0 flex-1" name={fileName} />
      </h2>
      <div className="flex shrink-0 items-center gap-xs">
        {openIn ? (
          <ChatPanelFileOpenInMenu action={openIn} presentation="split" />
        ) : null}
        {extraActions}
        <Tooltip
          content={pending ? messages.ui_file_downloading() : label}
          placement="bottom"
        >
          <ShellIconButtonControl
            aria-label={label}
            aria-busy={pending}
            {...(feedback ? { "aria-describedby": feedbackId } : {})}
            data-testid="file-preview-download"
            data-download-state={controller.state.status}
            icon={<DownloadIcon className="comma-input-icon" />}
            isDisabled={!controller.canExecute}
            onPress={() => void controller.execute()}
          />
        </Tooltip>
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

/** The same reader and file actions serve chat attachments and Drive files. */
export function FilePreviewPanel({
  fileName,
  mimeType,
  blob,
  error,
  placeholder,
  panelId,
  testId,
  download,
  openIn,
  extraActions,
  children,
  onOpenBrowser,
  onAttachFiles,
}: {
  fileName: string;
  mimeType?: string | undefined;
  blob?: Blob | undefined;
  error?: string | undefined;
  placeholder?: string | undefined;
  panelId: string;
  testId: string;
  download: ChatPanelMediaDownloadAction;
  openIn?: ChatPanelFileOpenInAction | undefined;
  extraActions?: ReactNode;
  children?: ReactNode;
  onOpenBrowser: (url: string) => void;
  onAttachFiles?: ((files: AttachmentUploadInput[]) => unknown) | undefined;
}) {
  const imageMenu = useMediaContextMenu(onAttachFiles);
  const kind = filePreviewKind(fileName, mimeType || blob?.type);
  const document =
    kind === "text" || kind === "markdown" || kind === "html" || kind === "pdf";
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
        extraActions={extraActions}
      />
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
                  media instanceof HTMLImageElement || media instanceof HTMLVideoElement
                )
              )
                return;
              imageMenu.open(
                event,
                (kind === "image" || kind === "video") && blob
                  ? {
                      fileName,
                      resolve: async () => blob,
                      ...(media instanceof HTMLVideoElement ? { video: media } : {}),
                    }
                  : mediaElementSource(media)
              );
            }}
          >
            <FilePreviewContent
              fileName={fileName}
              mimeType={mimeType}
              blob={blob}
              error={error}
              placeholder={placeholder}
              onOpenBrowser={onOpenBrowser}
            />
          </div>
          {children}
        </div>
      </ScrollArea>
      {imageMenu.menu}
    </section>
  );
}
