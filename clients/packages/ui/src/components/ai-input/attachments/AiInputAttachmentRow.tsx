import type { MouseEvent, RefObject } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import { ScrollArea } from "../../scroll-area";
import type { AiInputAttachment } from "../types";
import { AttachmentChip } from "./AttachmentChip";
import type { AttachmentTileProps } from "./AttachmentRemoveButton";
import type { AttachmentPreview } from "./useAttachmentPreview";

/** The staged attachments above the prompt; nothing when none are staged. */
export const AiInputAttachmentRow = ({
  attachments,
  onRemove,
  preview,
  rowRef,
}: {
  attachments: AiInputAttachment[];
  onRemove: AttachmentTileProps["onRemove"];
  preview: AttachmentPreview;
  rowRef: RefObject<HTMLDivElement | null>;
}) => {
  const messages = useCommaMessages();
  if (attachments.length === 0) return null;

  return (
    <div className="comma-ai-input-attachment-row w-full" ref={rowRef}>
      {/* The horizontal scroll viewport clips on both axes; pt-xs and pr-xs
          keep the tiles' 4px focus ring visible at the top and trailing edge. */}
      <ScrollArea
        aria-label={messages.ui_ai_attachments()}
        className="w-full"
        contentClassName="flex w-max items-center gap-md pt-xs pr-xs"
        edgeEffect="mask"
        edgeMask={{ size: 24 }}
        orientation="horizontal"
        scrollbar={false}
      >
        {attachments.map((attachment) => (
          <AttachmentChip
            key={attachment.id}
            attachment={attachment}
            {...(preview.canPreview(attachment.id)
              ? {
                  onPreview: (event: MouseEvent<HTMLButtonElement>) =>
                    preview.openPreview(attachment.id, event),
                }
              : {})}
            onRemove={onRemove}
          />
        ))}
      </ScrollArea>
    </div>
  );
};
