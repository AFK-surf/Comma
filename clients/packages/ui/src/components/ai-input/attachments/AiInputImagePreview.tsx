import { type RefObject } from "react";
import { useCommaMessages } from "@comma/i18n/react";
import {
  ChatPanelImageFilmstrip,
  type ChatPanelImageFilmstripImage,
} from "../../chat-panel/ChatPanelImageFilmstrip";
import { ChatPanelMediaPreview } from "../../chat-panel/ChatPanelMediaPreview";

export type AiInputImagePreviewImage = ChatPanelImageFilmstripImage;

export interface AiInputImagePreviewProps {
  images: AiInputImagePreviewImage[];
  index: number;
  /** Keyboard-opened previews skip the enter motion, as in the chat panel. */
  instantMotion?: boolean;
  isOpen: boolean;
  onIndexChange: (index: number) => void;
  onOpenChange: (isOpen: boolean) => void;
  returnFocusRef?: RefObject<HTMLElement | null>;
}

/**
 * Full-size look at the images staged in the composer. It is the same overlay
 * a sent message's image group opens, so an attachment reads identically
 * before and after it is sent: one filmstrip over every staged image, entered
 * at the tile that was pressed.
 *
 * Files that are not images never reach here — their chips stand in for
 * content the composer cannot show.
 */
export const AiInputImagePreview = ({
  images,
  index,
  instantMotion = false,
  isOpen,
  onIndexChange,
  onOpenChange,
  returnFocusRef,
}: AiInputImagePreviewProps) => {
  const messages = useCommaMessages();

  return (
    <ChatPanelMediaPreview
      instantMotion={instantMotion}
      isOpen={isOpen}
      onOpenChange={onOpenChange}
      {...(returnFocusRef ? { returnFocusRef } : {})}
      title={messages.chat_image_group_preview()}
      variant="filmstrip"
    >
      <ChatPanelImageFilmstrip
        images={images}
        index={index}
        onNavigate={(step) =>
          onIndexChange(Math.min(Math.max(index + step, 0), images.length - 1))
        }
      />
    </ChatPanelMediaPreview>
  );
};
