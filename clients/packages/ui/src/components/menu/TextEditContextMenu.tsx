import type { Key, RefObject } from "react";
import { definedProps } from "../utils";
import { Menu, MenuItem, MenuPopover, MenuSeparator } from "./Menu";
import type { MenuPointerOffsets } from "./pointerPosition";
import { menuCompactClasses } from "./styles";

export type TextEditContextMenuAction = "cut" | "copy" | "paste" | "select-all";

export interface TextEditContextMenuLabels {
  ariaLabel: string;
  cut: string;
  copy: string;
  paste: string;
  selectAll: string;
}

export interface TextEditContextMenuDisabledActions {
  cut?: boolean;
  copy?: boolean;
  paste?: boolean;
  selectAll?: boolean;
}

export interface TextEditContextMenuProps {
  triggerRef: RefObject<Element | null>;
  isOpen: boolean;
  onOpenChange: (open: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  labels: TextEditContextMenuLabels;
  disabledActions?: TextEditContextMenuDisabledActions;
  onAction: (action: TextEditContextMenuAction) => void;
}

/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
export const TextEditContextMenu = ({
  triggerRef,
  isOpen,
  onOpenChange,
  pointerOffsets,
  labels,
  disabledActions,
  onAction,
}: TextEditContextMenuProps) => {
  const handleAction = (key: Key) => {
    onAction(String(key) as TextEditContextMenuAction);
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
        <MenuItem id="copy" {...definedProps({ isDisabled: disabledActions?.copy })}>
          {labels.copy}
        </MenuItem>
        <MenuItem id="paste" {...definedProps({ isDisabled: disabledActions?.paste })}>
          {labels.paste}
        </MenuItem>
        <MenuItem id="cut" {...definedProps({ isDisabled: disabledActions?.cut })}>
          {labels.cut}
        </MenuItem>
        <MenuSeparator />
        <MenuItem
          id="select-all"
          {...definedProps({ isDisabled: disabledActions?.selectAll })}
        >
          {labels.selectAll}
        </MenuItem>
      </Menu>
    </MenuPopover>
  );
};
/* oxlint-enable jsx-a11y/no-autofocus */
