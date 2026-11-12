/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
import { useCommaMessages } from "@comma/i18n/react";
import {
  CircleXIcon,
  InboxDeleteIcon,
  InboxMarkUnreadIcon,
  ResetIcon,
} from "@comma/ui/components/icons";
import {
  getMenuPointerOffsets,
  Menu,
  MenuItem,
  MenuPopover,
  type MenuPointerOffsets,
} from "@comma/ui/components/menu";
import {
  useCallback,
  useState,
  type KeyboardEvent,
  type MouseEvent,
  type ReactNode,
  type RefObject,
} from "react";

/**
 * What a row's menu offers. A Task's notification: toggle its unread state or hide it. A request the person sent:
 * withdraw it while it waits, or hide it once decided. A request waiting for the owner: decline it.
 */
export type InboxItemMenuAction =
  | "mark-unread"
  | "mark-read"
  | "delete"
  | "withdraw"
  | "decline";

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

/** What opens a row's menu: a right click at the cursor, or the ContextMenu key or Shift+F10 at the row. */
export function inboxItemMenuTrigger(
  menu: ReturnType<typeof useInboxItemMenu>,
  rowRef: RefObject<HTMLElement | null>
) {
  return {
    "aria-haspopup": "menu" as const,
    onContextMenu: (event: MouseEvent) => {
      if (!rowRef.current) return;
      event.preventDefault();
      menu.open(getMenuPointerOffsets(rowRef.current, event.clientX, event.clientY));
    },
    onKeyDown: (event: KeyboardEvent) => {
      if (event.key !== "ContextMenu" && !(event.shiftKey && event.key === "F10")) {
        return;
      }
      event.preventDefault();
      menu.open(null);
    },
  };
}

/** The Inbox row's context menu, with the actions its row offers, in order. */
export function InboxItemMenuPopover({
  actions,
  isOpen,
  onAction,
  onOpenChange,
  pointerOffsets,
  triggerRef,
}: {
  actions: readonly InboxItemMenuAction[];
  isOpen: boolean;
  onAction: (action: InboxItemMenuAction) => void;
  onOpenChange: (isOpen: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  triggerRef: RefObject<HTMLElement | null>;
}) {
  const messages = useCommaMessages();
  if (!isOpen) return null;
  const items: Record<InboxItemMenuAction, { icon: ReactNode; label: string }> = {
    "mark-read": {
      icon: <InboxMarkUnreadIcon />,
      label: messages.inbox_mark_as_read(),
    },
    "mark-unread": {
      icon: <InboxMarkUnreadIcon />,
      label: messages.inbox_mark_as_unread(),
    },
    delete: { icon: <InboxDeleteIcon />, label: messages.inbox_delete_notification() },
    withdraw: { icon: <ResetIcon />, label: messages.task_requests_withdraw() },
    decline: { icon: <CircleXIcon />, label: messages.task_requests_decline() },
  };

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
        {actions.map((action) => (
          <MenuItem
            contentClassName="h-8"
            gutter="none"
            icon={items[action].icon}
            id={action}
            key={action}
          >
            {items[action].label}
          </MenuItem>
        ))}
      </Menu>
    </MenuPopover>
  );
}
