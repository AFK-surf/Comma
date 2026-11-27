import { useCommaMessages } from "@comma/i18n/react";
import type { ReactNode, Ref } from "react";
import { Button } from "react-aria-components";
import { secondaryActionTreatment } from "../toast/styles";
import {
  ChatPanelFileOpenInMenu,
  type ChatPanelFileOpenInAction,
} from "./ChatPanelFileOpenInMenu";
import { cx } from "../utils";

export type ChatPanelPreviewCardProps = {
  /** What opens: a document's title, a page's, a file's name. */
  title: string;
  /** What it is and where it opens: "Markdown · 12 KB", "example.com". */
  subtitle?: string | undefined;
  /** The mark of its kind, before its name: a file type's artwork, a site's icon. */
  icon?: ReactNode;
  /**
   * The picture: the top of what opening shows, across the card's width. It is decoration: nothing in it takes the
   * pointer or the keyboard. Without it the card is its header alone.
   */
  children?: ReactNode;
  /**
   * The picture is text that runs past the card's bottom edge: its last line fades into the card. A picture that
   * is an image keeps its own edge.
   */
  fades?: boolean | undefined;
  /** Opens it: from the Open button for everyone, and from a press anywhere else on the card for a pointer. */
  onOpen: () => void;
  /**
   * Other places to open it in (the desktop's apps). With it Open is one button in two zones: its word opens the
   * card, and its chevron opens the menu of these.
   */
  openIn?: ChatPanelFileOpenInAction | undefined;
  className?: string | undefined;
  /** The card's own element, for a caller that waits for the card to come into view. */
  cardRef?: Ref<HTMLElement> | undefined;
  testId?: string | undefined;
};

/**
 * A card for something that opens beside the chat (a document, a web page, a deck): what it is and Open, then a
 * picture of it. One shape for every kind, so a reader learns once where the sidebar's content comes from.
 */
export const ChatPanelPreviewCard = ({
  cardRef,
  children,
  className,
  fades,
  icon,
  onOpen,
  openIn,
  subtitle,
  testId,
  title,
}: ChatPanelPreviewCardProps) => {
  const messages = useCommaMessages();
  const openName = `${messages.common_open()} ${title}`;
  return (
    // The whole card opens it for a pointer; the Open button is the same action for everyone.
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions, jsx-a11y/click-events-have-key-events
    <article
      className={cx("chat-panel-preview-card", className)}
      data-testid={testId}
      onClick={(event) => {
        // The card's own controls do what they are for. A press in a menu one of them opened comes here through
        // React and is no press on the card: the menu is not in the card's element.
        const pressed = event.target;
        if (
          pressed instanceof Element &&
          event.currentTarget.contains(pressed) &&
          !pressed.closest(".chat-panel-preview-card-actions")
        )
          onOpen();
      }}
      ref={cardRef}
    >
      <div className="chat-panel-preview-card-header">
        {icon ? (
          <span aria-hidden="true" className="chat-panel-preview-card-icon">
            {icon}
          </span>
        ) : null}
        <div className="chat-panel-preview-card-details">
          <p className="chat-panel-preview-card-title" title={title}>
            {title}
          </p>
          {subtitle ? (
            <p className="chat-panel-preview-card-subtitle">{subtitle}</p>
          ) : null}
        </div>
        <div className="chat-panel-preview-card-actions">
          {openIn ? (
            <ChatPanelFileOpenInMenu
              action={openIn}
              primary={{
                label: messages.common_open(),
                name: openName,
                onPress: onOpen,
              }}
            />
          ) : (
            // The frame of a file row's Open in: a card's one control reads the same in both.
            <Button
              aria-label={openName}
              className={cx(secondaryActionTreatment, "px-lg")}
              onPress={onOpen}
            >
              {messages.common_open()}
            </Button>
          )}
        </div>
      </div>
      {children ? (
        <div
          aria-hidden="true"
          className="chat-panel-preview-card-picture"
          data-fades={fades ? "true" : undefined}
        >
          <div className="chat-panel-preview-card-content" inert>
            {children}
          </div>
        </div>
      ) : null}
    </article>
  );
};
