/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
import { useCommaMessages } from "@comma/i18n/react";
import {
  InboxDeleteIcon,
  InboxMarkUnreadIcon,
  Menu,
  MenuItem,
  MenuPopover,
  type MenuPointerOffsets,
} from "@comma/ui";
import { useCallback, useState, type RefObject } from "react";

export type InboxItemMenuAction = "mark-unread" | "mark-read" | "delete";

/**
 * Right-click state for one Inbox row: a pointer open carries offsets so the
 * menu lands at the cursor, a keyboard open leaves them null and the popover
 * falls back to the anchor edge.
 */
export function useInboxItemMenu() {
  const [isOpen, setIsOpen] = useState(false);
  const [pointerOffsets, setPointerOffsets] = useState<MenuPointerOffsets | null>(null);
  const open = useCallback((offsets: MenuPointerOffsets | null) => {
    setPointerOffsets(offsets);
    setIsOpen(true);
  }, []);
  return { isOpen, onOpenChange: setIsOpen, open, pointerOffsets };
}

/**
 * The Inbox row's context menu: toggle this notification's unread state, or
 * hide it until the conversation updates again.
 */
export function InboxItemMenuPopover({
  isOpen,
  onAction,
  onOpenChange,
  pointerOffsets,
  triggerRef,
  unread,
}: {
  isOpen: boolean;
  onAction: (action: InboxItemMenuAction) => void;
  onOpenChange: (isOpen: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  triggerRef: RefObject<HTMLElement | null>;
  unread: boolean;
}) {
  const messages = useCommaMessages();
  if (!isOpen) return null;

  return (
    <MenuPopover
      className="min-w-52 motion-reduce:animate-none"
      crossOffset={pointerOffsets?.crossOffset ?? 0}
      dismissControlledNonModalOnInteractOutside
      isNonModal
      isOpen={isOpen}
      offset={pointerOffsets?.offset ?? 0}
      onOpenChange={onOpenChange}
      placement={pointerOffsets ? "right top" : "bottom end"}
      triggerRef={triggerRef}
    >
      <Menu
        aria-label={messages.inbox_item_actions()}
        autoFocus="first"
        className="bg-popup-secondary px-sm py-sm shadow-2xl"
        onAction={(key) => onAction(String(key) as InboxItemMenuAction)}
        onClose={() => onOpenChange(false)}
      >
        <MenuItem
          contentClassName="h-8"
          gutter="none"
          icon={<InboxMarkUnreadIcon />}
          id={unread ? "mark-read" : "mark-unread"}
        >
          {unread ? messages.inbox_mark_as_read() : messages.inbox_mark_as_unread()}
        </MenuItem>
        <MenuItem
          contentClassName="h-8"
          gutter="none"
          icon={<InboxDeleteIcon />}
          id="delete"
        >
          {messages.inbox_delete_notification()}
        </MenuItem>
      </Menu>
    </MenuPopover>
  );
}
