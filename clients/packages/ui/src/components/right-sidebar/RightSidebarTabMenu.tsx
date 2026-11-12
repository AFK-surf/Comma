/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
import { useCommaMessages } from "@comma/i18n/react";
import type { RefObject } from "react";
import { Menu, MenuItem, MenuPopover, MenuSeparator } from "../menu";
import type { MenuPointerOffsets } from "../menu";
import { NativeSurfaceSuppressor } from "../native-surface/NativeSurfaceSuppressor";

export type RightSidebarTabMenuAction =
  | "pin"
  | "unpin"
  | "duplicate"
  | "close"
  | "close-others"
  | "close-right";

const item = (id: RightSidebarTabMenuAction, label: string) => (
  <MenuItem contentClassName="h-8" gutter="none" id={id} key={id}>
    {label}
  </MenuItem>
);

/**
 * A tab's context menu: what keeps or copies the tab, then what closes it or
 * its neighbours. A group the tab offers nothing in is left out; a close that
 * has no tab to act on stays in place, disabled.
 *
 * The menu drops from the tab strip over the browser page, whose native view
 * paints above every DOM layer. The suppressor swaps that view for a snapshot
 * for as long as the menu is open.
 */
export function RightSidebarTabMenu({
  closeOthersDisabled,
  closeRightDisabled,
  canClose,
  canDuplicate,
  canPin,
  onAction,
  onOpenChange,
  pinned,
  pointerOffsets,
  triggerRef,
}: {
  canClose: boolean;
  canDuplicate: boolean;
  canPin: boolean;
  closeOthersDisabled: boolean;
  closeRightDisabled: boolean;
  onAction: (action: RightSidebarTabMenuAction) => void;
  onOpenChange: (isOpen: boolean) => void;
  pinned: boolean;
  pointerOffsets: MenuPointerOffsets | null;
  triggerRef: RefObject<HTMLElement | null>;
}) {
  const messages = useCommaMessages();
  const keep = [
    canPin
      ? pinned
        ? item("unpin", messages.shell_sidebar_tab_unpin())
        : item("pin", messages.shell_sidebar_tab_pin())
      : null,
    canDuplicate ? item("duplicate", messages.shell_sidebar_tab_duplicate()) : null,
  ].filter(Boolean);
  const close = [
    canClose ? item("close", messages.shell_sidebar_tab_close()) : null,
    item("close-others", messages.shell_sidebar_tab_close_others()),
    item("close-right", messages.shell_sidebar_tab_close_right()),
  ].filter(Boolean);
  const disabledKeys = [
    closeOthersDisabled && "close-others",
    closeRightDisabled && "close-right",
  ].filter((key): key is RightSidebarTabMenuAction => Boolean(key));

  return (
    <MenuPopover
      className="min-w-52 motion-reduce:animate-none"
      crossOffset={pointerOffsets?.crossOffset ?? 0}
      dismissControlledNonModalOnInteractOutside
      isNonModal
      isOpen
      offset={pointerOffsets?.offset ?? 0}
      onOpenChange={onOpenChange}
      placement={pointerOffsets ? "right top" : "bottom start"}
      triggerRef={triggerRef}
    >
      <NativeSurfaceSuppressor />
      <Menu
        aria-label={messages.shell_sidebar_tab_actions()}
        autoFocus="first"
        className="bg-popup-secondary px-sm py-sm shadow-2xl"
        disabledKeys={disabledKeys}
        onAction={(key) => onAction(String(key) as RightSidebarTabMenuAction)}
        onClose={() => onOpenChange(false)}
      >
        {keep}
        {keep.length > 0 ? <MenuSeparator /> : null}
        {close}
      </Menu>
    </MenuPopover>
  );
}
