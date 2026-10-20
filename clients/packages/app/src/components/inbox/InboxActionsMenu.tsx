import { useCommaMessages } from "@comma/i18n/react";
import { InboxDeleteIcon, MoreHorizontalIcon } from "@comma/ui/components/icons";
import { Menu, MenuItem, MenuPopover, MenuTrigger } from "@comma/ui/components/menu";
import { spacing } from "@comma/ui/tokens";
import { taskToolbarIconButtonClassName } from "@comma/ui/components/task-workspace";
import { Button as AriaButton } from "react-aria-components";

export interface InboxActionsMenuProps {
  canDeleteAll: boolean;
  canDeleteRead: boolean;
  onDeleteAll: () => void;
  onDeleteRead: () => void;
}

/**
 * The Inbox rail's "···" menu: bulk-deletes the notifications the rail
 * currently lists, filters included.
 */
export function InboxActionsMenu({
  canDeleteAll,
  canDeleteRead,
  onDeleteAll,
  onDeleteRead,
}: InboxActionsMenuProps) {
  const messages = useCommaMessages();
  const disabledKeys = [
    ...(canDeleteAll ? [] : ["delete-all"]),
    ...(canDeleteRead ? [] : ["delete-read"]),
  ];

  return (
    <MenuTrigger>
      <AriaButton
        aria-label={messages.inbox_actions()}
        className={taskToolbarIconButtonClassName}
        data-testid="inbox-actions-trigger"
      >
        <MoreHorizontalIcon />
      </AriaButton>
      <MenuPopover offset={spacing.xs} placement="bottom start">
        <Menu
          aria-label={messages.inbox_actions()}
          className="w-44 bg-popup-secondary px-sm py-sm shadow-2xl"
          disabledKeys={disabledKeys}
          onAction={(key) => {
            if (key === "delete-all") onDeleteAll();
            else if (key === "delete-read") onDeleteRead();
          }}
        >
          <MenuItem
            contentClassName="h-8"
            gutter="none"
            icon={<InboxDeleteIcon />}
            id="delete-all"
          >
            {messages.inbox_delete_all()}
          </MenuItem>
          <MenuItem
            contentClassName="h-8"
            gutter="none"
            icon={<InboxDeleteIcon />}
            id="delete-read"
          >
            {messages.inbox_delete_all_read()}
          </MenuItem>
        </Menu>
      </MenuPopover>
    </MenuTrigger>
  );
}
