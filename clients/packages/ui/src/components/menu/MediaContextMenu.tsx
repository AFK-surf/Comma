import type { RefObject } from "react";
import { Menu, MenuItem, MenuPopover, MenuSeparator } from "./Menu";
import type { MenuPointerOffsets } from "./pointerPosition";
import { menuCompactClasses } from "./styles";

export type MediaContextMenuAction = "add-to-context" | "copy" | "copy-frame" | "save";

/* oxlint-disable jsx-a11y/no-autofocus -- Context menus receive keyboard focus when opened. */
export function MediaContextMenu({
  triggerRef,
  isOpen,
  onOpenChange,
  pointerOffsets,
  labels,
  canAttach,
  canCopy = true,
  canCopyFrame = false,
  onAction,
}: {
  triggerRef: RefObject<Element | null>;
  isOpen: boolean;
  onOpenChange: (open: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  labels: {
    ariaLabel: string;
    addToContext: string;
    copy: string;
    copyFrame?: string;
    copyUnavailable?: string;
    save: string;
  };
  canAttach: boolean;
  canCopy?: boolean;
  canCopyFrame?: boolean;
  onAction: (action: MediaContextMenuAction) => void;
}) {
  return (
    // Keep media actions modal: non-modal popovers dismiss on ancestor scroll,
    // including layout-driven scroll while a previous attachment is admitted.
    // The standard popover still dismisses on Escape and outside interaction.
    <MenuPopover
      crossOffset={pointerOffsets?.crossOffset ?? 0}
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
        onAction={(key) => onAction(String(key) as MediaContextMenuAction)}
        onClose={() => onOpenChange(false)}
      >
        <MenuItem id="add-to-context" isDisabled={!canAttach}>
          {labels.addToContext}
        </MenuItem>
        <MenuSeparator />
        <MenuItem
          id="copy"
          isDisabled={!canCopy}
          aria-description={!canCopy ? labels.copyUnavailable : undefined}
        >
          {labels.copy}
        </MenuItem>
        {labels.copyFrame ? (
          <MenuItem id="copy-frame" isDisabled={!canCopyFrame}>
            {labels.copyFrame}
          </MenuItem>
        ) : null}
        <MenuItem id="save">{labels.save}</MenuItem>
      </Menu>
    </MenuPopover>
  );
}
