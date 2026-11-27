import { memo, type Key, type RefObject } from "react";
import { definedProps } from "../utils";
import { Menu, MenuItem, MenuPopover, MenuSeparator } from "./Menu";
import type { MenuPointerOffsets } from "./pointerPosition";
import { menuCompactClasses } from "./styles";

export type CopyContextMenuAction = "copy" | "forward" | "reply";

export interface CopyContextMenuLabels {
  ariaLabel: string;
  copy: string;
  /** Offers Forward (share selected text as image) below Copy when present. */
  forward?: string | undefined;
  /** Offers Reply above Copy when present. */
  reply?: string | undefined;
}

export interface CopyContextMenuDisabledActions {
  copy?: boolean;
  forward?: boolean;
  reply?: boolean;
}

export interface CopyContextMenuProps {
  triggerRef: RefObject<Element | null>;
  isOpen: boolean;
  onOpenChange: (open: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  labels: CopyContextMenuLabels;
  disabledActions?: CopyContextMenuDisabledActions;
  onAction: (action: CopyContextMenuAction) => void;
}

/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
export const CopyContextMenu = memo(function CopyContextMenu({
  triggerRef,
  isOpen,
  onOpenChange,
  pointerOffsets,
  labels,
  disabledActions,
  onAction,
}: CopyContextMenuProps) {
  const handleAction = (key: Key) => {
    onAction(String(key) as CopyContextMenuAction);
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
        {labels.reply ? (
          <MenuItem
            id="reply"
            {...definedProps({ isDisabled: disabledActions?.reply })}
          >
            {labels.reply}
          </MenuItem>
        ) : null}
        <MenuItem id="copy" {...definedProps({ isDisabled: disabledActions?.copy })}>
          {labels.copy}
        </MenuItem>
        {labels.forward ? <MenuSeparator /> : null}
        {labels.forward ? (
          <MenuItem
            id="forward"
            {...definedProps({ isDisabled: disabledActions?.forward })}
          >
            {labels.forward}
          </MenuItem>
        ) : null}
      </Menu>
    </MenuPopover>
  );
});
/* oxlint-enable jsx-a11y/no-autofocus */
