import { MiddleEllipsis, splitMiddleEllipsis } from "@comma/ui/components/ai-input";
import { FileIcon } from "@comma/ui/components/icons";
import { localDirectory } from "../../composer/fileIntake";

/** A file of a message as a pill: its name, then its size, or the folder it is in on the sender's computer. */
export function AttachmentPill({
  label,
  localPath,
  messageId,
  onPreview,
  position,
  size,
}: {
  label: string;
  /** Where the file is on the sender's computer, when the message named it by its path. */
  localPath?: string | undefined;
  messageId: string;
  /** Opens the file in the sidebar's preview, where this device can read it. */
  onPreview?: (() => void) | undefined;
  position: number;
  size: string | undefined;
}) {
  const folder =
    size === undefined && localPath ? localDirectory(localPath) : undefined;
  const Pill = onPreview ? "button" : "span";
  return (
    <Pill
      className="comma-chat-attachment-pill"
      data-attachment-type="file"
      data-testid={`chat-attachment-pill-${messageId}-${position}`}
      title={localPath}
      {...(onPreview ? { onClick: onPreview, type: "button" as const } : {})}
    >
      <span
        aria-hidden
        className="comma-chat-attachment-file-icon"
        data-slot="file-icon-surface"
      >
        <FileIcon className="size-3.5" />
      </span>
      <span className="comma-chat-attachment-name">{label}</span>
      {size ? <span className="comma-chat-attachment-size">{size}</span> : null}
      {folder ? (
        <span
          className="comma-chat-attachment-folder"
          data-long={splitMiddleEllipsis(folder).tail ? "" : undefined}
          data-slot="attachment-folder"
        >
          <MiddleEllipsis text={folder} />
        </span>
      ) : null}
    </Pill>
  );
}
