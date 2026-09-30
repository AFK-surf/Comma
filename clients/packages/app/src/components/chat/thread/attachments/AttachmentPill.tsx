import { FileIcon } from "@comma/ui";

export function AttachmentPill({
  label,
  messageId,
  position,
  size,
}: {
  label: string;
  messageId: string;
  position: number;
  size: string | undefined;
}) {
  return (
    <span
      className="comma-chat-attachment-pill"
      data-attachment-type="file"
      data-testid={`chat-attachment-pill-${messageId}-${position}`}
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
    </span>
  );
}
