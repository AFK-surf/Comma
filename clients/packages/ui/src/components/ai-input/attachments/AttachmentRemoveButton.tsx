import { useCommaMessages } from "@comma/i18n/react";
import { Button as AriaButton } from "react-aria-components";
import { CrossLargeIcon } from "../../icons";
import { aiInputAttachmentClose } from "../styles";
import type { AiInputAttachment } from "../types";

/** What every staged tile takes: its attachment, and who hears it removed. */
export interface AttachmentTileProps {
  attachment: AiInputAttachment;
  onRemove?: ((attachment: AiInputAttachment) => void) | undefined;
}

export const AttachmentRemoveButton = ({
  attachment,
  onRemove,
}: AttachmentTileProps) => {
  const messages = useCommaMessages();
  const handleRemove = () => {
    attachment.onRemove?.();
    onRemove?.(attachment);
  };

  if (!attachment.onRemove && !onRemove) return null;

  return (
    <AriaButton
      aria-label={messages.ui_ai_remove_attachment({ name: attachment.name })}
      className={aiInputAttachmentClose}
      onPress={handleRemove}
    >
      <CrossLargeIcon className="size-2.5" />
    </AriaButton>
  );
};
