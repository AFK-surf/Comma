import type { Key, RefObject } from "react";
import { definedProps } from "../utils";
import { Menu, MenuItem, MenuPopover, MenuSeparator } from "./Menu";
import type { MenuPointerOffsets } from "./pointerPosition";
import { menuCompactClasses } from "./styles";

export type LinkContextMenuAction =
  | "open-external-browser"
  | "open-in-comma"
  | "copy-link"
  | "copy-message";

export interface LinkContextMenuLabels {
  ariaLabel: string;
  openInExternalBrowser: string;
  openInComma: string;
  copyLink: string;
  /**
   * Omit on a surface that has no message behind the link — the item is then
   * left out rather than shown permanently disabled.
   */
  copyMessage?: string;
}

export interface LinkContextMenuDisabledActions {
  openInComma?: boolean;
  copyMessage?: boolean;
}

export interface LinkContextMenuProps {
  triggerRef: RefObject<Element | null>;
  isOpen: boolean;
  onOpenChange: (open: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  labels: LinkContextMenuLabels;
  disabledActions?: LinkContextMenuDisabledActions;
  onAction: (action: LinkContextMenuAction) => void;
}

/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
export const LinkContextMenu = ({
  triggerRef,
  isOpen,
  onOpenChange,
  pointerOffsets,
  labels,
  disabledActions,
  onAction,
}: LinkContextMenuProps) => {
  const handleAction = (key: Key) => {
    onAction(String(key) as LinkContextMenuAction);
  };

  return (
    <MenuPopover
      crossOffset={pointerOffsets?.crossOffset ?? 0}
      dismissControlledNonModalOnInteractOutside
      isNonModal
      isOpen={isOpen}
      offset={pointerOffsets?.offset ?? 0}
      onOpenChange={onOpenChange}
      placement="right top"
      triggerRef={triggerRef}
    >
      <Menu
        aria-label={labels.ariaLabel}
        autoFocus="first"
        className={menuCompactClasses}
        onAction={handleAction}
        onClose={() => onOpenChange(false)}
      >
        <MenuItem id="open-external-browser">{labels.openInExternalBrowser}</MenuItem>
        <MenuItem
          id="open-in-comma"
          {...definedProps({ isDisabled: disabledActions?.openInComma })}
        >
          {labels.openInComma}
        </MenuItem>
        <MenuSeparator />
        <MenuItem id="copy-link">{labels.copyLink}</MenuItem>
        {labels.copyMessage ? (
          <MenuItem
            id="copy-message"
            {...definedProps({ isDisabled: disabledActions?.copyMessage })}
          >
            {labels.copyMessage}
          </MenuItem>
        ) : null}
      </Menu>
    </MenuPopover>
  );
};
/* oxlint-enable jsx-a11y/no-autofocus */
