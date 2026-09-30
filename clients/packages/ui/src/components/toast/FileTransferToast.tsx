import { useCommaMessages } from "@comma/i18n/react";
import { useEffect, useRef, type FocusEvent } from "react";
import {
  AirDropIcon,
  ArchiveIcon,
  FileIcon,
  FileTextIcon,
  Folder1Icon,
  ImageIcon,
  LoadingCircleIcon,
  VideoIcon,
} from "../icons";
import { ScrollArea } from "../scroll-area";
import { cx, definedProps } from "../utils";
import { ToastActions, ToastCloseButton } from "./ToastActions";
import { ToastErrorIcon, ToastSuccessIcon } from "./ToastIcons";
import {
  toastContentRow,
  toastDescription,
  toastRowGap,
  toastShellBase,
  toastShellVariant,
  toastStatusIcon,
  toastTitleSmAction,
} from "./styles";
import type { ToastAction } from "./types";

export type FileTransferToastFileKind =
  | "image"
  | "video"
  | "document"
  | "archive"
  | "folder"
  | "file";

export interface FileTransferToastFile {
  kind: FileTransferToastFileKind;
  name: string;
  /**
   * A rendered preview of the file's content, such as a data URL. Its size is
   * known up front so the card has its final height before the image decodes.
   */
  preview?: { height: number; src: string; width: number };
}

export interface FileTransferToastProps {
  /** `offer` waits for a decision; `progress` is a transfer under way. */
  status: "offer" | "progress" | "success" | "error";
  title: string;
  description?: string;
  files: readonly FileTransferToastFile[];
  /** Transferred fraction (0–1) while `status` is `progress`, when known. */
  progress?: number;
  actions?: ToastAction[];
  /** Without it the card has no close control. */
  onClose?: () => void;
  /**
   * Whether the pointer or keyboard focus is on the card, so an owner that
   * drives its lifetime can keep it while the user reads or scrolls it.
   */
  onHoldChange?: (held: boolean) => void;
  testId?: string;
}

const kindIcons = {
  archive: ArchiveIcon,
  document: FileTextIcon,
  file: FileIcon,
  folder: Folder1Icon,
  image: ImageIcon,
  video: VideoIcon,
} as const;

const StatusIcon = ({ status }: { status: FileTransferToastProps["status"] }) => {
  if (status === "success")
    return (
      <ToastSuccessIcon className={cx(toastStatusIcon, "text-fg-success-primary")} />
    );
  if (status === "error")
    return <ToastErrorIcon className={cx(toastStatusIcon, "text-fg-error-primary")} />;
  if (status === "progress")
    return (
      <LoadingCircleIcon
        className={cx(toastStatusIcon, "animate-spin text-toast-icon-primary")}
      />
    );
  return <AirDropIcon className={cx(toastStatusIcon, "text-toast-icon-primary")} />;
};

const KindIcon = ({
  className,
  kind,
}: {
  className: string;
  kind: FileTransferToastFileKind;
}) => {
  const Icon = kindIcons[kind];
  return <Icon className={className} />;
};

/**
 * A single file shows its name until its content arrives, then the content at
 * a readable size. Several ride one horizontal strip, the way they land in the
 * composer: images as square tiles, other files as named chips. Every item has
 * its final size from the start, so the card never grows as previews arrive.
 */
const FileTransferFiles = ({ files }: { files: readonly FileTransferToastFile[] }) => {
  const messages = useCommaMessages();
  const [first] = files;
  if (!first) return null;

  if (files.length === 1 && first.preview) {
    const { height, src, width } = first.preview;
    return (
      <figure className={cx(toastContentRow, "flex-col items-start gap-xs")}>
        <img
          alt={first.name}
          className="h-auto max-w-full rounded-md border-[length:var(--border-width-0-5)] border-primary object-cover"
          data-slot="file-transfer-preview"
          src={src}
          // At most half the row wide and --spacing-8xl tall, in its own ratio.
          style={{
            aspectRatio: `${width} / ${height}`,
            width: `min(50%, calc(var(--spacing-8xl) * ${width / height}))`,
          }}
        />
        <figcaption className="w-full truncate text-xs text-toast-text-secondary">
          {first.name}
        </figcaption>
      </figure>
    );
  }

  if (files.length === 1) {
    return (
      <div className={cx(toastContentRow, "items-center", toastRowGap)}>
        <span className="flex size-3xl shrink-0 items-center justify-center rounded-xs bg-panel-bg-file text-toast-icon-primary">
          <KindIcon className="size-lg" kind={first.kind} />
        </span>
        <span className="min-w-0 truncate text-sm text-toast-text-primary">
          {first.name}
        </span>
      </div>
    );
  }

  return (
    <div className={toastContentRow}>
      <ScrollArea
        className="min-w-0 flex-1"
        contentClassName="w-max"
        edgeEffect="mask"
        edgeMask={{ size: 24 }}
        orientation="horizontal"
        scrollbar={false}
        viewportProps={{ "aria-label": messages.ui_file_transfer_files() }}
      >
        <ul className="flex items-center gap-md" data-slot="file-transfer-strip">
          {files.map((file, index) =>
            file.kind === "image" ? (
              <li
                className="flex size-6xl shrink-0 items-center justify-center overflow-hidden rounded-md border-[length:var(--border-width-0-5)] border-primary bg-panel-bg-file text-toast-icon-primary"
                // Several received files can share a display name.
                // eslint-disable-next-line react/no-array-index-key
                key={index}
                title={file.name}
              >
                {file.preview ? (
                  <img
                    alt={file.name}
                    className="size-full object-cover"
                    data-slot="file-transfer-preview"
                    src={file.preview.src}
                  />
                ) : (
                  <KindIcon className="size-2xl" kind={file.kind} />
                )}
              </li>
            ) : (
              <li
                className="flex h-6xl w-11xl shrink-0 items-center gap-sm rounded-md border-[length:var(--border-width-0-5)] border-primary bg-popup-primary p-sm"
                // eslint-disable-next-line react/no-array-index-key
                key={index}
                title={file.name}
              >
                <span className="flex aspect-square shrink-0 items-center justify-center self-stretch overflow-hidden rounded-xs bg-panel-bg-file text-toast-icon-primary">
                  {file.preview ? (
                    // A document's page or a file's icon keeps its own shape.
                    <img
                      alt={file.name}
                      className="size-full object-contain"
                      data-slot="file-transfer-preview"
                      src={file.preview.src}
                    />
                  ) : (
                    <KindIcon className="size-lg" kind={file.kind} />
                  )}
                </span>
                <span className="min-w-0 flex-1 truncate text-xs text-toast-text-primary">
                  {file.name}
                </span>
              </li>
            )
          )}
        </ul>
      </ScrollArea>
    </div>
  );
};

/** Reports pointer-or-focus presence on the card as one flag, on change only. */
const useHold = (onHoldChange: ((held: boolean) => void) | undefined) => {
  const card = useRef<HTMLOutputElement>(null);
  const presence = useRef({ held: false, pointer: false });
  const report = useRef(onHoldChange);
  report.current = onHoldChange;
  const sync = (focusTarget: Element | null = document.activeElement) => {
    const held = presence.current.pointer || !!card.current?.contains(focusTarget);
    if (held === presence.current.held) return;
    presence.current.held = held;
    report.current?.(held);
  };
  // A focused control can leave with a render, as Accept does once the offer
  // is answered, and a removed element never blurs: look again after each one.
  useEffect(() => sync());
  useEffect(
    () => () => {
      if (presence.current.held) report.current?.(false);
    },
    []
  );
  return {
    onBlur: (event: FocusEvent<HTMLOutputElement>) =>
      sync(event.relatedTarget instanceof Element ? event.relatedTarget : null),
    onFocus: () => sync(),
    onPointerEnter: () => {
      presence.current.pointer = true;
      sync();
    },
    onPointerLeave: () => {
      presence.current.pointer = false;
      sync();
    },
    ref: card,
  };
};

/** A toast card for files arriving from another device, previewing their content. */
export const FileTransferToast = ({
  actions,
  description,
  files,
  onClose,
  onHoldChange,
  progress,
  status,
  testId,
  title,
}: FileTransferToastProps) => {
  const hold = useHold(onHoldChange);
  return (
    <output
      aria-live="polite"
      className={cx(toastShellBase, toastShellVariant.action)}
      data-status={status}
      {...hold}
      {...(testId ? { "data-testid": testId } : {})}
    >
      <div className={cx("flex w-full items-start", toastRowGap)}>
        <StatusIcon status={status} />
        <div className="flex min-w-0 flex-1 flex-col">
          <p className={toastTitleSmAction}>{title}</p>
          {description && <p className={toastDescription}>{description}</p>}
        </div>
        {onClose && <ToastCloseButton onPress={onClose} />}
      </div>
      <FileTransferFiles files={files} />
      {status === "progress" && progress !== undefined && (
        <div className={cx(toastContentRow, "items-center gap-md")}>
          <progress
            aria-label={title}
            className="h-sm min-w-0 flex-1 appearance-none [&::-webkit-progress-bar]:rounded-full [&::-webkit-progress-bar]:bg-tertiary [&::-webkit-progress-value]:rounded-full [&::-webkit-progress-value]:bg-brand-solid [&::-webkit-progress-value]:transition-[width] [&::-webkit-progress-value]:duration-[var(--motion-duration-progress-fill)] [&::-webkit-progress-value]:ease-linear motion-reduce:[&::-webkit-progress-value]:transition-none [&::-moz-progress-bar]:rounded-full [&::-moz-progress-bar]:bg-brand-solid"
            max={100}
            value={Math.round(progress * 100)}
          />
          <span className="shrink-0 text-xs tabular-nums text-toast-text-secondary">
            {Math.round(progress * 100)}%
          </span>
        </div>
      )}
      <ToastActions {...definedProps({ actions })} />
    </output>
  );
};
