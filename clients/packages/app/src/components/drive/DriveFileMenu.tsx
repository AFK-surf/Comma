/* oxlint-disable jsx-a11y/no-autofocus -- A newly opened context menu must receive keyboard focus. */
import {
  CloudCheckIcon,
  Cursor1Icon,
  DownloadIcon,
  Menu,
  MenuItem,
  MenuPopover,
  MenuSeparator,
  TrashCanIcon,
  type MenuPointerOffsets,
} from "@comma/ui";
import type { RefObject } from "react";

export type DriveFileMenuAction =
  | "ask-comma-agent"
  | "delete"
  | "download"
  | "keep-offline";

export type DriveSelectionMenuAction =
  | "ask-comma-agent"
  | "delete"
  | "download-all"
  | "keep-offline";

/**
 * The context menu of a row that is part of a multi-selection: the selection
 * bar's actions plus Keep Offline, on the whole selection, so a right click
 * and the bar never disagree about what "Delete" means right now.
 */
export function DriveSelectionMenuPopover({
  askCommaAgentLabel,
  deleteLabel,
  downloadAllLabel,
  isOpen,
  keepOfflineLabel,
  onAction,
  onOpenChange,
  pointerOffsets,
  triggerRef,
  writable,
}: {
  askCommaAgentLabel: string;
  deleteLabel: string;
  downloadAllLabel: string;
  isOpen: boolean;
  /** Already reflects the selection: pin them all, or unpin them all. */
  keepOfflineLabel: string;
  onAction: (action: DriveSelectionMenuAction) => void;
  onOpenChange: (isOpen: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  triggerRef: RefObject<HTMLElement | null>;
  writable: boolean;
}) {
  if (!isOpen) return null;
  return (
    <MenuPopover
      className="min-w-60 motion-reduce:animate-none"
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
        autoFocus="first"
        onAction={(key) => onAction(key as DriveSelectionMenuAction)}
        onClose={() => onOpenChange(false)}
      >
        <MenuItem icon={<Cursor1Icon />} id="ask-comma-agent">
          {askCommaAgentLabel}
        </MenuItem>
        <MenuItem icon={<DownloadIcon />} id="download-all">
          {downloadAllLabel}
        </MenuItem>
        <MenuItem icon={<CloudCheckIcon />} id="keep-offline">
          {keepOfflineLabel}
        </MenuItem>
        {writable ? (
          <>
            <MenuSeparator />
            <MenuItem icon={<TrashCanIcon />} id="delete" tone="destructive">
              {deleteLabel}
            </MenuItem>
          </>
        ) : null}
      </Menu>
    </MenuPopover>
  );
}

/**
 * A file row's context menu (macOS Synchronicity's file menu, minus Quick
 * Look and Show Versions): hand it to the assistant, get the bytes now, keep
 * them on this device, or remove the file from the space. Delete sits alone
 * below a separator and in the destructive tone, so a hand aiming for Keep
 * Offline cannot land on it.
 */
export function DriveFileMenuPopover({
  askCommaAgentLabel,
  deleteLabel,
  downloadLabel,
  isOpen,
  keepOfflineLabel,
  onAction,
  onOpenChange,
  pointerOffsets,
  triggerRef,
  writable,
}: {
  askCommaAgentLabel: string;
  deleteLabel: string;
  downloadLabel: string;
  isOpen: boolean;
  /** Already reflects the file's pin state ("Keep Offline" / "Stop Keeping Offline"). */
  keepOfflineLabel: string;
  onAction: (action: DriveFileMenuAction) => void;
  onOpenChange: (isOpen: boolean) => void;
  pointerOffsets: MenuPointerOffsets | null;
  triggerRef: RefObject<HTMLElement | null>;
  writable: boolean;
}) {
  if (!isOpen) return null;
  return (
    <MenuPopover
      className="min-w-60 motion-reduce:animate-none"
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
        autoFocus="first"
        onAction={(key) => onAction(key as DriveFileMenuAction)}
        onClose={() => onOpenChange(false)}
      >
        <MenuItem icon={<Cursor1Icon />} id="ask-comma-agent">
          {askCommaAgentLabel}
        </MenuItem>
        <MenuItem icon={<DownloadIcon />} id="download">
          {downloadLabel}
        </MenuItem>
        {/* The same checked cloud the list paints on a pinned row, so the
            action and the mark it leaves behind read as one thing. */}
        <MenuItem icon={<CloudCheckIcon />} id="keep-offline">
          {keepOfflineLabel}
        </MenuItem>
        {writable ? (
          <>
            <MenuSeparator />
            <MenuItem icon={<TrashCanIcon />} id="delete" tone="destructive">
              {deleteLabel}
            </MenuItem>
          </>
        ) : null}
      </Menu>
    </MenuPopover>
  );
}
